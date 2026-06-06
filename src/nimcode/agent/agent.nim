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
    compactionSettings*: contextModule.CompactionSettings
    thinkingLevel*: ThinkingLevel  ## Thinking/reasoning level
    interruptCheck*: proc(): bool {.closure.}  ## Optional interrupt check callback
    approvalRequest*: ApprovalRequestCallback  ## Optional approval callback for TUI

proc newAgent*(
  provider: Provider,
  modelId: string,
  mode: string,
  workDir: string,
  session: Session,
  maxTokens: int = 8192,
  extraContext: string = "",
  contextWindow: int = 128000,
  settings: Settings = nil,
  thinkingLevel: ThinkingLevel = tlOff,
  sandboxEnabled: bool = false,
  sandboxLevel: string = "none"
): Agent =
  var compaction = defaultCompactionSettings()
  if settings != nil:
    compaction.reserveTokens = settings.maxOutputTokens
  result = Agent(
    provider: provider,
    modelId: modelId,
    mode: mode,
    workDir: workDir,
    registry: newToolRegistry(workDir, sandboxEnabled = sandboxEnabled, sandboxLevel = sandboxLevel),
    session: session,
    messages: @[],
    maxTokens: maxTokens,
    extraContext: extraContext,
    contextWindow: contextWindow,
    settings: settings,
    compactionSettings: compaction,
    thinkingLevel: thinkingLevel,
  )

proc clearMessages*(agent: Agent) =
  agent.messages = @[]

## Tools allowed in read-only plan mode
const PlanModeReadOnlyTools* = ["read", "ls", "grep", "find", "plan", "memory_read", "skill_ref"]

proc isReadOnlyTool*(toolName: string): bool =
  for t in PlanModeReadOnlyTools:
    if t == toolName:
      return true
  return false

proc getAllowedToolNames*(agent: Agent): seq[string] =
  ## Return list of tool names allowed for current mode
  if agent.mode == "plan":
    return @PlanModeReadOnlyTools
  else:
    return agent.registry.definitions().mapIt(it.name)

proc needsApproval*(agent: Agent, toolName: string, args: JsonNode): bool =
  ## Determine if a tool call needs user approval before execution
  if agent.settings == nil:
    return false

  # Plan mode: read-only tools never need approval (already filtered)
  if agent.mode == "plan":
    return false

  # YOLO mode: never needs approval
  if agent.mode == "yolo":
    return false

  # Agent mode: selective approval
  if agent.mode == "agent":
    # Bash commands require approval unless whitelisted
    if toolName == "bash":
      let command = args{"command"}.getStr("")
      # Check blacklist first
      for prefix in agent.settings.approval.bashBlacklist:
        if command.startsWith(prefix):
          return true
      # Then check whitelist
      for prefix in agent.settings.approval.bashWhitelist:
        if command.startsWith(prefix):
          return false
      return true

    # Potentially destructive write/edit operations
    if agent.settings.approval.confirmBeforeWrite:
      if toolName in ["write", "edit"]:
        return true

    # Other sensitive operations
    if toolName in ["spawn", "cron", "memory_write", "a2a_dispatch"]:
      return true

  return false

proc getContextUsage*(agent: Agent): ContextUsage =
  return contextModule.getContextUsage(agent.messages, agent.contextWindow)

proc compactContext*(agent: Agent): string =
  if not agent.compactionSettings.enabled:
    return ""
  let contextTokens = estimateContextTokens(agent.messages)
  if not shouldCompact(contextTokens, agent.contextWindow, agent.compactionSettings.reserveTokens):
    return ""
  let cutIndex = findCutPoint(agent.messages, agent.compactionSettings.keepRecentTokens)
  if cutIndex <= 0:
    return ""
  let oldMessages = agent.messages[0 ..< cutIndex]
  let conversationText = serializeMessages(oldMessages)
  if conversationText.strip() == "":
    return ""
  let summaryPrompt = "Summarize the following conversation concisely, preserving all important context, decisions, file paths, and code changes.\n\n" & conversationText
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
      return ""
    else:
      discard
  summary = summary.strip()
  if summary == "":
    return ""
  let summaryMsg = newAssistantMessage("[Context Summary]\n" & summary)
  agent.messages = @[summaryMsg] & agent.messages[cutIndex .. ^1]
  if agent.session != nil:
    agent.session.appendMessage(summaryMsg)
  return summary

proc processAgentTurnStream*(agent: Agent, userMsg: string, callback: AgentEventCallback)
  ## Forward declaration

proc processAgentTurn*(agent: Agent, userMsg: string): seq[AgentEvent] =
  ## Non-streaming fallback: collects all events
  var events: seq[AgentEvent] = @[]
  proc collect(event: AgentEvent) =
    events.add(event)
  agent.processAgentTurnStream(userMsg, collect)
  return events

proc processAgentTurnStream*(agent: Agent, userMsg: string, callback: AgentEventCallback) =
  ## Streaming agent turn: invokes callback for each event as it arrives from the LLM.
  
  # Add user message
  agent.messages.add(newUserMessage(userMsg))
  if agent.session != nil:
    agent.session.appendMessage(newUserMessage(userMsg))
  
  # Check if compaction is needed
  let compactionSummary = agent.compactContext()
  if compactionSummary != "":
    callback(AgentEvent(kind: aekTextDelta, textDelta: "[Context compacted: " & $(compactionSummary.len) & " chars summary]\n"))
  
  # Build system prompt
  let toolNames = agent.registry.definitions().mapIt(it.name)
  let systemPrompt = buildSystemPrompt(agent.mode, toolNames, agent.workDir, agent.extraContext)
  
  # Main agent loop
  var iterations = 0
  const maxIterations = 50
  
  while iterations < maxIterations:
    iterations += 1
    
    # Filter tools based on current mode
    let allowedToolNames = agent.getAllowedToolNames()
    let allDefs = agent.registry.definitions()
    var filteredDefs: seq[ToolDefinition] = @[]
    for d in allDefs:
      if d.name in allowedToolNames:
        filteredDefs.add(d)

    let params = ChatParams(
      messages: agent.messages,
      tools: filteredDefs,
      systemPrompt: systemPrompt,
      maxTokens: agent.maxTokens,
      modelId: agent.modelId,
      thinkingLevel: agent.thinkingLevel,
    )
    
    # Stream events from provider — callback is invoked per-token
    var textContent = ""
    var toolCalls: seq[tuple[id, name: string, args: JsonNode]] = @[]
    var hasError = false
    var isDone = false
    
    proc onStreamEvent(event: StreamEvent) =
      case event.kind
      of setTextDelta:
        textContent.add(event.textDelta)
        callback(AgentEvent(kind: aekTextDelta, textDelta: event.textDelta))
      of setThinkDelta:
        callback(AgentEvent(kind: aekThinkDelta, thinkDelta: event.thinkDelta))
      of setToolCall:
        toolCalls.add((event.toolCallId, event.toolName, event.toolArgs))
        callback(AgentEvent(kind: aekToolCall, toolCallId: event.toolCallId, toolName: event.toolName, toolArgs: event.toolArgs))
      of setError:
        callback(AgentEvent(kind: aekError, errorMsg: event.error))
        hasError = true
      of setRetry:
        # Report retry attempts to the user
        callback(AgentEvent(kind: aekTextDelta, textDelta: "[Retry " & $event.retryAttempt & "/" & $event.retryMax & ": " & event.retryError & "]\n"))
      of setDone:
        isDone = true
      of setUsage, setStart:
        discard
    
    agent.provider.chatStream(params, onStreamEvent)
    
    # Check for interrupt
    if agent.interruptCheck != nil and agent.interruptCheck():
      callback(AgentEvent(kind: aekTextDelta, textDelta: "\n[Interrupted]\n"))
      return
    
    if hasError:
      return
    
    # Build assistant message
    let assistantMsg = newAssistantMessage(textContent)
    agent.messages.add(assistantMsg)
    if agent.session != nil:
      agent.session.appendMessage(assistantMsg)
    
    # If no tool calls, we're done
    if toolCalls.len == 0:
      callback(AgentEvent(kind: aekDone, doneStopReason: "stop"))
      return
    
    # Execute tool calls (with approval check in agent mode)
    for tc in toolCalls:
      var finalArgs = tc.args
      var toolResult: ToolResult
      var wasDenied = false

      # Check if approval is needed
      if agent.needsApproval(tc.name, tc.args):
        if agent.approvalRequest != nil:
          let approval = agent.approvalRequest(tc.name, tc.args)
          case approval.approved
          of arDenied:
            wasDenied = true
            toolResult = newToolResult("Tool execution denied by user: " & tc.name, true)
          of arEdited:
            finalArgs = approval.modifiedArgs
          of arApproved:
            discard
        else:
          # No approval callback registered but needs approval - deny by default
          wasDenied = true
          toolResult = newToolResult("Tool execution denied (no approval handler): " & tc.name, true)

      if not wasDenied:
        toolResult = agent.registry.execute(tc.name, finalArgs)

      let resultMsg = newToolResultMessage(tc.id, tc.name, toolResult.text, toolResult.isError)

      agent.messages.add(resultMsg)
      if agent.session != nil:
        agent.session.appendMessage(resultMsg)

      callback(AgentEvent(
        kind: aekToolResult,
        resultToolCallId: tc.id,
        resultToolName: tc.name,
        resultText: toolResult.text,
        resultIsError: toolResult.isError
      ))
  
  let errMsg = "Max iterations exceeded"
  let errAssistMsg = newAssistantMessage("[Error: " & errMsg & "]")
  agent.messages.add(errAssistMsg)
  if agent.session != nil:
    agent.session.appendMessage(errAssistMsg)
  callback(AgentEvent(kind: aekError, errorMsg: errMsg))
