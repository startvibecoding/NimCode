import std/[strutils, options]
import ../provider/types
import ../provider/openai

type
  CompactionSettings* = object
    enabled*: bool
    reserveTokens*: int
    keepRecentTokens*: int

  CompactionResult* = object
    summary*: string
    firstKeptIndex*: int
    tokensBefore*: int

proc defaultCompactionSettings*(): CompactionSettings =
  result = CompactionSettings(
    enabled: true,
    reserveTokens: 16384,
    keepRecentTokens: 20000
  )

proc estimateTokens*(msg: Message): int =
  ## Estimates token count for a message using chars/4 heuristic
  var chars = 0
  if msg.content != "":
    chars += msg.content.len
  return (chars + 3) div 4

proc findCutPoint(messages: seq[Message], keepRecentTokens: int): int =
  ## Finds the cut point that keeps approximately keepRecentTokens
  var accumulatedTokens = 0
  
  for i in countdown(messages.len - 1, 0):
    accumulatedTokens += estimateTokens(messages[i])
    if accumulatedTokens >= keepRecentTokens:
      # Find the nearest user or assistant message (never cut at tool results)
      for j in i ..< messages.len:
        if messages[j].role in [mrUser, mrAssistant]:
          return j
      return i
  
  return 0

proc serializeConversation(messages: seq[Message]): string =
  ## Serializes messages to text for summarization
  result = ""
  
  for msg in messages:
    case msg.role
    of mrUser:
      result.add("User: " & msg.content & "\n\n")
    of mrAssistant:
      result.add("Assistant: " & msg.content & "\n\n")
    of mrToolResult:
      let content = if msg.content.len > 500: msg.content[0 ..< 500] & "..." else: msg.content
      result.add("Tool Result [" & msg.toolName & "]: " & content & "\n\n")

proc generateSummary(
  messages: seq[Message],
  provider: Provider,
  modelId: string,
  maxTokens: int
): string =
  ## Generates a summary of the conversation
  let conversation = serializeConversation(messages)
  
  let instruction = """Please create a structured context checkpoint summary of our conversation so far.

Use this EXACT format:

## Goal
[What is the user trying to accomplish?]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- Or "(none)" if none were mentioned

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Any data, examples, or references needed to continue]
- Or "(none)" if not applicable

Keep each section concise. Preserve exact file paths, function names, and error messages."""
  
  let params = ChatParams(
    messages: @[newUserMessage(conversation & "\n\n" & instruction)],
    tools: @[],
    systemPrompt: "",
    maxTokens: maxTokens,
    modelId: modelId
  )
  
  let events = provider.chat(params)
  
  for event in events:
    case event.kind
    of setTextDelta:
      result.add(event.textDelta)
    of setError:
      return ""
    else:
      discard

proc compact*(
  messages: seq[Message],
  provider: Provider,
  modelId: string,
  settings: CompactionSettings,
  previousSummary: string = ""
): CompactionResult =
  ## Performs context compaction on the messages
  if messages.len == 0:
    return CompactionResult(summary: "", firstKeptIndex: 0, tokensBefore: 0)
  
  var tokensBefore = 0
  for msg in messages:
    tokensBefore += estimateTokens(msg)
  
  # Find cut point
  let cutPoint = findCutPoint(messages, settings.keepRecentTokens)
  
  # Messages to summarize
  let messagesToSummarize = messages[0 ..< cutPoint]
  if messagesToSummarize.len == 0:
    return CompactionResult(summary: "", firstKeptIndex: 0, tokensBefore: tokensBefore)
  
  # Calculate max tokens for summary
  let maxTokens = int(settings.reserveTokens.float * 0.8)
  
  # Generate summary
  let summary = generateSummary(messagesToSummarize, provider, modelId, maxTokens)
  
  return CompactionResult(
    summary: summary,
    firstKeptIndex: cutPoint,
    tokensBefore: tokensBefore
  )
