import std/[json]

type
  ContentBlockType* = enum
    cbtText = "text"
    cbtToolCall = "toolCall"

  ContentBlock* = object
    case kind*: ContentBlockType
    of cbtText:
      text*: string
    of cbtToolCall:
      toolCallId*: string
      toolName*: string
      toolArgs*: JsonNode

  MessageRole* = enum
    mrUser = "user"
    mrAssistant = "assistant"
    mrToolResult = "toolResult"

  Message* = object
    role*: MessageRole
    content*: string
    toolCallId*: string
    toolName*: string
    isError*: bool

  ToolDefinition* = object
    name*: string
    description*: string
    parameters*: JsonNode

  StreamEventType* = enum
    setStart = "start"
    setTextDelta = "text_delta"
    setToolCall = "tool_call"
    setUsage = "usage"
    setDone = "done"
    setError = "error"

  StreamEvent* = object
    case kind*: StreamEventType
    of setStart:
      discard
    of setTextDelta:
      textDelta*: string
    of setToolCall:
      toolCallId*: string
      toolName*: string
      toolArgs*: JsonNode
    of setUsage:
      inputTokens*: int
      outputTokens*: int
    of setDone:
      stopReason*: string
    of setError:
      error*: string

  StreamCallback* = proc(event: StreamEvent) {.closure.}
    ## Callback invoked for each streaming event as it arrives.

  ChatParams* = object
    messages*: seq[Message]
    tools*: seq[ToolDefinition]
    systemPrompt*: string
    maxTokens*: int
    modelId*: string

  Provider* = ref object of RootObj
    name*: string

method chat*(p: Provider, params: ChatParams): seq[StreamEvent] {.base.} =
  raise newException(CatchableError, "Not implemented")

method chatStream*(p: Provider, params: ChatParams, callback: StreamCallback) {.base.} =
  ## Streaming chat: invokes callback for each event as it arrives.
  ## Default implementation falls back to non-streaming chat.
  let events = p.chat(params)
  for event in events:
    callback(event)

proc newUserMessage*(text: string): Message =
  Message(role: mrUser, content: text)

proc newAssistantMessage*(content: string): Message =
  Message(role: mrAssistant, content: content)

proc newToolResultMessage*(toolCallId, toolName, content: string, isError: bool = false): Message =
  Message(role: mrToolResult, content: content, toolCallId: toolCallId, toolName: toolName, isError: isError)
