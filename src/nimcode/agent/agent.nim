import std/[json, sequtils, strutils, options]
import ../provider/types
import ../tools/tools as toolsModule
import ../session/session
import ../context/context as contextModule
import ../config/config
import ./system_prompt
import ./types

export types

type
  Agent* = ref object
    provider*: Provider
    modelId*: string
    mode*: string
    workDir*: string
    registry*: ToolRegistry
    session*: Session
    messages*: seq[Message]
    maxTokens*: int
    extraContext*: string  ## Extra context from context files and skills
    contextWindow*: int    ## Maximum context window size
    settings*: Settings    ## Settings for approval rules
    compactionSettings*: CompactionSettings

proc newAgent*(
  provider: Provider,
  modelId: string,
  mode: string,
  workDir: string,
  session: Session,
  maxTokens: int = 8192,
  extraContext: string = "",
  contextWindow: int = 128000,
  settings: Settings = nil
): Agent =
  var compaction = defaultCompactionSettings()
  if settings != nil:
    compaction.reserveTokens = settings.maxOutputTokens
  result = Agent(
    provider: provider,
    modelId: modelId,
    mode: mode,
    workDir: workDir,
    registry: newToolRegistry(workDir),
    session: session,
    messages: @[],
    maxTokens: maxTokens,
    extraContext: extraContext,
    contextWindow: contextWindow,
    settings: settings,
    compactionSettings: compaction
  )

proc clearMessages*(agent: Agent) =
  agent.messages = @[]

proc needsApproval*(agent: Agent, toolName: string, args: JsonNode): bool =
  ## Checks if a tool call needs user approval based on the current mode
  if agent.settings == nil:
    return false
  
  # Plan mode: no tools should be executed
  if agent.mode == "plan":
    return false
  
  # Agent mode: bash requires approval unless whitelisted
  if agent.mode == "agent" and toolName == "bash":
    let command = args{"command"}.getStr("")
    # Check whitelist
    for prefix in agent.settings.approval.bashWhitelist:
      if command.startsWith(prefix):
        return false
    return true
  
  # ConfirmBeforeWrite: write/edit require approval in agent mode
  if agent.mode == "agent" and agent.settings.approval.confirmBeforeWrite:
    if toolName in ["write", "edit"]:
      return true
  
  return false

proc getContextUsage*(agent: Agent): ContextUsage =
  ## Returns the current context usage
  return contextModule.getContextUsage(agent.messages, agent.contextWindow)

proc compactContext*(agent: Agent): string =
  ## Performs context compaction: summarizes old messages, keeps recent ones.
  ## Returns the summary text, or empty string if compaction not needed.
  if not agent.compactionSettings.enabled:
    return ""
  
  let contextTokens = estimateContextTokens(agent.messages)
  if not shouldCompact(contextTokens, agent.contextWindow, agent.compactionSettings.reserveTokens):
    return ""
  
  let cutIndex = findCutPoint(agent.messages, agent.compactionSettings.keepRecentTokens)
  if cutIndex <= 0:
    return ""
  
  # Serialize old messages for summarization
  let oldMessages = agent.messages[0 ..< cutIndex]
  let conversationText = serializeMessages(oldMessages)
  
  if conversationText.strip() == "":
    return ""
  
  # Generate summary using the LLM itself
  let summaryPrompt = "Summarize the following conversation concisely, preserving all important context, decisions, file paths, and code changes. This summary will be used to replace the old messages while keeping recent ones intact.\n\n" & conversationText
  
  let summaryMessages = @[newUserMessage(summaryPrompt)]
  let params = ChatParams(
    messages: summaryMessages,
    tools: @[],
    systemPrompt: "You are a conversation summarizer. Be concise but preserve all critical information.",
    maxTokens: min(agent.compactionSettings.reserveTokens, 4096),
    modelId: agent.modelId
  )
  
  var summary = ""
  let events = agent.provider.chat(params)
  for event in events:
    case event.kind
    of setTextDelta:
      summary.add(event.textDelta)
    of setError:
      # If summarization fails, skip compaction
      return ""
    else:
      discard
  
  summary = summary.strip()
  if summary == "":
    return ""
  
  # Replace old messages with summary
  let summaryMsg = newAssistantMessage("[Context Summary]\n" & summary)
  agent.messages = @[summaryMsg] & agent.messages[cutIndex .. ^1]
  
  # Record in session
  if agent.session != nil:
    agent.session.appendMessage(summaryMsg)
  
  return summary

proc processAgentTurn*(agent: Agent, userMsg: string): seq[AgentEvent] =
  result = @[]
  
  # Add user message
  agent.messages.add(newUserMessage(userMsg))
  if agent.session != nil:
    agent.session.appendMessage(newUserMessage(userMsg))
  
  # Check if compaction is needed
  let compactionSummary = agent.compactContext()
  if compactionSummary != "":
    result.add(AgentEvent(kind: aekTextDelta, textDelta: "[Context compacted: " & $(compactionSummary.len) & " chars summary]\n"))
  
  # Build system prompt with extra context
  let toolNames = agent.registry.definitions().mapIt(it.name)
  let systemPrompt = buildSystemPrompt(agent.mode, toolNames, agent.workDir, agent.extraContext)
  
  # Main agent loop
  var iterations = 0
  const maxIterations = 50
  
  while iterations < maxIterations:
    iterations += 1
    
    # Chat with provider
    let params = ChatParams(
      messages: agent.messages,
      tools: agent.registry.definitions(),
      systemPrompt: systemPrompt,
      maxTokens: agent.maxTokens,
      modelId: agent.modelId
    )
    
    let events = agent.provider.chat(params)
    
    var textContent = ""
    var toolCalls: seq[tuple[id, name: string, args: JsonNode]] = @[]
    var hasError = false
    
    for event in events:
      case event.kind
      of setTextDelta:
        textContent.add(event.textDelta)
        result.add(AgentEvent(kind: aekTextDelta, textDelta: event.textDelta))
      of setToolCall:
        toolCalls.add((event.toolCallId, event.toolName, event.toolArgs))
        result.add(AgentEvent(kind: aekToolCall, toolCallId: event.toolCallId, toolName: event.toolName, toolArgs: event.toolArgs))
      of setError:
        result.add(AgentEvent(kind: aekError, errorMsg: event.error))
        hasError = true
      of setDone:
        discard
      of setUsage, setStart:
        discard
    
    if hasError:
      return
    
    # Build assistant message
    let assistantMsg = newAssistantMessage(textContent)
    agent.messages.add(assistantMsg)
    if agent.session != nil:
      agent.session.appendMessage(assistantMsg)
    
    # If no tool calls, we're done
    if toolCalls.len == 0:
      let usage = agent.getContextUsage()
      var percentStr = ""
      if usage.percent.isSome:
        percentStr = " (" & formatFloat(usage.percent.get, ffDecimal, 0) & "%)"
      result.add(AgentEvent(kind: aekDone, doneStopReason: "stop"))
      return
    
    # Execute tool calls
    for tc in toolCalls:
      let toolResult = agent.registry.execute(tc.name, tc.args)
      let resultMsg = newToolResultMessage(tc.id, tc.name, toolResult.text, toolResult.isError)
      
      agent.messages.add(resultMsg)
      if agent.session != nil:
        agent.session.appendMessage(resultMsg)
      
      result.add(AgentEvent(
        kind: aekToolResult,
        resultToolCallId: tc.id,
        resultToolName: tc.name,
        resultText: toolResult.text,
        resultIsError: toolResult.isError
      ))
  
  result.add(AgentEvent(kind: aekError, errorMsg: "Max iterations exceeded"))
