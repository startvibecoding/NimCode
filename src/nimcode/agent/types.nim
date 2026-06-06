import std/[json]

type
  ApprovalResult* = enum
    arApproved
    arDenied
    arEdited

  AgentEventKind* = enum
    aekTextDelta = "text_delta"
    aekThinkDelta = "think_delta"
    aekToolCall = "tool_call"
    aekToolResult = "tool_result"
    aekDone = "done"
    aekError = "error"

  AgentEvent* = object
    case kind*: AgentEventKind
    of aekTextDelta:
      textDelta*: string
    of aekThinkDelta:
      thinkDelta*: string
    of aekToolCall:
      toolCallId*: string
      toolName*: string
      toolArgs*: JsonNode
    of aekToolResult:
      resultToolCallId*: string
      resultToolName*: string
      resultText*: string
      resultIsError*: bool
    of aekDone:
      doneStopReason*: string
    of aekError:
      errorMsg*: string

  AgentEventCallback* = proc(event: AgentEvent) {.closure.}
    ## Callback for real-time streaming of agent events

  ApprovalRequestCallback* = proc(toolName: string, args: JsonNode): tuple[approved: ApprovalResult, modifiedArgs: JsonNode] {.closure.}
    ## Callback for requesting user approval before executing a tool
