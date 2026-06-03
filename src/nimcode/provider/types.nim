import std/[json, strutils]

type
  ## Thinking/reasoning level for reasoning models (o1, o3, DeepSeek, etc.)
  ThinkingLevel* = enum
    tlOff = "off"
    tlMinimal = "minimal"
    tlLow = "low"
    tlMedium = "medium"
    tlHigh = "high"
    tlXHigh = "xhigh"

  ContentBlockType* = enum
    cbtText = "text"
    cbtImage = "image"
    cbtToolCall = "toolCall"
    cbtThinking = "thinking"

  ImageData* = object
    mimeType*: string  ## e.g. "image/png", "image/jpeg"
    data*: string      ## base64-encoded image data

  CacheControl* = object
    kind*: string      ## e.g. "ephemeral"

  ContentBlock* = object
    case kind*: ContentBlockType
    of cbtText:
      text*: string
      textCacheControl*: ptr CacheControl  ## nil if no cache control
    of cbtImage:
      image*: ImageData
    of cbtToolCall:
      toolCallId*: string
      toolName*: string
      toolArgs*: JsonNode
    of cbtThinking:
      thinking*: string       ## Reasoning/thinking text
      signature*: string      ## Thinking signature (Anthropic extended thinking)

  MessageRole* = enum
    mrUser = "user"
    mrAssistant = "assistant"
    mrToolResult = "toolResult"

  Message* = object
    role*: MessageRole
    content*: string
    contents*: seq[ContentBlock]  ## Rich content blocks (images, tool calls, etc.)
    toolCallId*: string
    toolName*: string
    isError*: bool
    cacheControl*: ptr CacheControl  ## Message-level cache control

  ToolDefinitionKind* = enum
    tdkFunction = "function"    ## Regular function tool
    tdkHosted = "hosted"        ## Provider-hosted tool (e.g. web_search)

  ToolDefinition* = object
    name*: string
    description*: string
    parameters*: JsonNode
    case kind*: ToolDefinitionKind
    of tdkFunction:
      discard
    of tdkHosted:
      providerType*: string   ## "responses" or "messages" — determines wire format

  StreamEventType* = enum
    setStart = "start"
    setTextDelta = "text_delta"
    setThinkDelta = "think_delta"
    setToolCall = "tool_call"
    setUsage = "usage"
    setDone = "done"
    setError = "error"
    setRetry = "retry"

  StreamEvent* = object
    case kind*: StreamEventType
    of setStart:
      discard
    of setTextDelta:
      textDelta*: string
    of setThinkDelta:
      thinkDelta*: string
    of setToolCall:
      toolCallId*: string
      toolName*: string
      toolArgs*: JsonNode
    of setUsage:
      inputTokens*: int
      outputTokens*: int
      cacheReadTokens*: int
      cacheWriteTokens*: int
      reasoningTokens*: int
    of setDone:
      stopReason*: string
    of setError:
      error*: string
    of setRetry:
      retryAttempt*: int
      retryMax*: int
      retryError*: string

  StreamCallback* = proc(event: StreamEvent) {.closure.}
    ## Callback invoked for each streaming event as it arrives.

  ChatParams* = object
    messages*: seq[Message]
    tools*: seq[ToolDefinition]
    systemPrompt*: string
    maxTokens*: int
    modelId*: string
    thinkingLevel*: ThinkingLevel   ## Thinking/reasoning level
    temperature*: float             ## 0.0 means default
    topP*: float                    ## 0.0 means default

  Provider* = ref object of RootObj
    name*: string

  ## Retry configuration shared across providers
  RetryConfig* = object
    enabled*: bool
    maxRetries*: int
    baseDelayMs*: int

  ## Model pricing info
  ModelPricing* = object
    input*: float        ## Per million tokens
    output*: float
    cacheRead*: float
    cacheWrite*: float

  ## Model info
  ModelInfo* = object
    id*: string
    name*: string
    reasoning*: bool
    contextWindow*: int
    maxTokens*: int
    pricing*: ModelPricing

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

## Create a hosted tool definition (e.g. web_search)
proc newHostedTool*(name, providerType: string): ToolDefinition =
  ToolDefinition(
    name: name,
    description: "",
    parameters: newJObject(),
    kind: tdkHosted,
    providerType: providerType,
  )

## Create a function tool definition
proc newFunctionTool*(name, description: string, parameters: JsonNode): ToolDefinition =
  ToolDefinition(
    name: name,
    description: description,
    parameters: parameters,
    kind: tdkFunction,
  )

## Resolve thinking level string to enum
proc parseThinkingLevel*(s: string): ThinkingLevel =
  case s.toLowerAscii()
  of "off": tlOff
  of "minimal": tlMinimal
  of "low": tlLow
  of "medium": tlMedium
  of "high": tlHigh
  of "xhigh", "x-high": tlXHigh
  else: tlOff

## Get reasoning effort string for OpenAI-style APIs
proc openaiReasoningEffort*(level: ThinkingLevel): string =
  case level
  of tlOff: ""
  of tlMinimal: "low"
  of tlLow: "low"
  of tlMedium: "medium"
  of tlHigh: "high"
  of tlXHigh: "high"

## Get reasoning effort for Anthropic-style (budget tokens)
proc anthropicThinkingBudget*(level: ThinkingLevel): int =
  case level
  of tlOff: 0
  of tlMinimal: 1024
  of tlLow: 4096
  of tlMedium: 8192
  of tlHigh: 16384
  of tlXHigh: 32768

## Get reasoning effort string for Responses API
proc responsesReasoningEffort*(level: ThinkingLevel): string =
  case level
  of tlOff: ""
  of tlMinimal: "minimal"
  of tlLow: "low"
  of tlMedium: "medium"
  of tlHigh: "high"
  of tlXHigh: "high"

## Hosted web search tool type mapping (matching vibecoding's HostedWebSearchToolType)
proc hostedWebSearchToolType*(providerType, name: string): string =
  if name != "web_search":
    return ""
  case providerType
  of "responses": "web_search"
  of "messages": "web_search_20250305"
  else: ""
