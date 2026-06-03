import std/[json, httpclient, streams, strutils, sequtils, options, times, os]
import ./types

type
  AnthropicProvider* = ref object of Provider
    apiKey: string
    baseUrl: string
    client: HttpClient
    retryEnabled*: bool
    maxRetries*: int
    baseDelayMs*: int
    cacheControlEnabled*: bool
    thinkingFormat*: string ## "", "anthropic", "deepseek", "xiaomi"

proc newAnthropicProvider*(apiKey, baseUrl: string, retryEnabled: bool = true, maxRetries: int = 3, baseDelayMs: int = 2000): AnthropicProvider =
  let base = if baseUrl == "": "https://api.anthropic.com" else: baseUrl.strip(chars = {'/'})
  result = AnthropicProvider(
    name: "anthropic",
    apiKey: apiKey,
    baseUrl: base,
    client: newHttpClient(timeout = 300_000),
    retryEnabled: retryEnabled,
    maxRetries: maxRetries,
    baseDelayMs: baseDelayMs,
  )

proc isRetryable(statusCode: int, errMsg: string): bool =
  if statusCode == 429 or statusCode == 502 or statusCode == 503 or statusCode == 504:
    return true
  let lower = errMsg.toLower
  if lower.contains("timeout") or lower.contains("connection reset") or
     lower.contains("connection refused") or lower.contains("eof") or
     lower.contains("broken pipe"):
    return true
  return false

proc retryDelay(attempt, baseDelayMs: int): int =
  result = baseDelayMs * (1 shl attempt)
  if result > 30000:
    result = 30000

proc thinkingFormatForModel(p: AnthropicProvider): string =
  if p.thinkingFormat != "":
    return p.thinkingFormat
  return "anthropic"

proc convertMessages(params: ChatParams, cacheEnabled: bool): JsonNode =
  result = newJArray()
  for msg in params.messages:
    var jmsg = newJObject()
    case msg.role
    of mrUser:
      var blocks = newJArray()
      if msg.contents.len > 0:
        for c in msg.contents:
          case c.kind
          of cbtText:
            var blk = %*{"type": "text", "text": c.text}
            if cacheEnabled and c.textCacheControl != nil:
              blk["cache_control"] = %*{"type": c.textCacheControl[].kind}
            blocks.add(blk)
          of cbtImage:
            blocks.add(%*{
              "type": "image",
              "source": {"type": "base64", "media_type": c.image.mimeType, "data": c.image.data}
            })
          else:
            discard
      else:
        blocks.add(%*{"type": "text", "text": msg.content})
      if blocks.len == 1 and blocks[0]{"type"}.getStr("") == "text":
        jmsg["role"] = %"user"
        jmsg["content"] = blocks[0]{"text"}
      else:
        jmsg["role"] = %"user"
        jmsg["content"] = blocks
    of mrAssistant:
      # Check if we have rich content (tool calls, thinking)
      if msg.contents.len > 0:
        var blocks = newJArray()
        for c in msg.contents:
          case c.kind
          of cbtText:
            blocks.add(%*{"type": "text", "text": c.text})
          of cbtToolCall:
            blocks.add(%*{
              "type": "tool_use",
              "id": c.toolCallId,
              "name": c.toolName,
              "input": (if c.toolArgs != nil: c.toolArgs else: newJObject())
            })
          of cbtThinking:
            var thinkBlk = %*{"type": "thinking", "thinking": c.thinking}
            if c.signature != "":
              thinkBlk["signature"] = %c.signature
            blocks.add(thinkBlk)
          else:
            discard
        jmsg["role"] = %"assistant"
        jmsg["content"] = blocks
      else:
        jmsg["role"] = %"assistant"
        jmsg["content"] = %msg.content
    of mrToolResult:
      # Anthropic uses tool_result blocks in a user message
      var toolBlk = %*{
        "type": "tool_result",
        "tool_use_id": msg.toolCallId,
        "content": msg.content,
        "is_error": msg.isError
      }
      if cacheEnabled:
        toolBlk["cache_control"] = %*{"type": "ephemeral"}
      jmsg["role"] = %"user"
      jmsg["content"] = %[toolBlk]
    result.add(jmsg)

proc convertTools(tools: seq[ToolDefinition]): JsonNode =
  result = newJArray()
  for t in tools:
    if t.kind == tdkHosted:
      let wireType = hostedWebSearchToolType(t.providerType, t.name)
      if wireType != "":
        result.add(%*{"type": wireType})
      continue
    result.add(%*{
      "name": t.name,
      "description": t.description,
      "input_schema": t.parameters
    })

proc doChatStream(p: AnthropicProvider, params: ChatParams, callback: StreamCallback) =
  ## Single streaming attempt
  let messages = convertMessages(params, p.cacheControlEnabled)
  let tools = convertTools(params.tools)
  
  var body = %*{
    "model": params.modelId,
    "messages": messages,
    "max_tokens": (if params.maxTokens > 0: params.maxTokens else: 8192),
    "stream": true
  }
  
  # System prompt
  if params.systemPrompt != "":
    if p.cacheControlEnabled:
      body["system"] = %*[{
        "type": "text",
        "text": params.systemPrompt,
        "cache_control": {"type": "ephemeral"}
      }]
    else:
      body["system"] = %params.systemPrompt
  
  if params.tools.len > 0:
    body["tools"] = tools
  if params.temperature > 0:
    body["temperature"] = %params.temperature
  if params.topP > 0:
    body["top_p"] = %params.topP
  
  # Thinking/reasoning (extended thinking)
  if params.thinkingLevel != tlOff:
    let format = p.thinkingFormatForModel()
    if format == "anthropic":
      let budget = anthropicThinkingBudget(params.thinkingLevel)
      body["thinking"] = %*{
        "type": "enabled",
        "budget_tokens": budget
      }
      # Extended thinking requires higher max_tokens
      if params.maxTokens <= budget:
        body["max_tokens"] = %(budget + 4096)
  
  let url = p.baseUrl & "/v1/messages"
  var headers = newHttpHeaders([
    ("Content-Type", "application/json"),
    ("x-api-key", p.apiKey),
    ("anthropic-version", "2023-06-01"),
    ("Accept", "text/event-stream"),
  ])
  
  let response = p.client.request(url, httpMethod = HttpPost, body = $body, headers = headers)
  
  if response.status != "200 OK":
    let errBody = response.body
    callback(StreamEvent(kind: setError, error: "API error " & response.status & ": " & errBody))
    return
  
  callback(StreamEvent(kind: setStart))
  
  # Parse SSE stream
  let bodyStream = response.bodyStream
  var toolCallIdx = -1
  var toolCalls: seq[tuple[id, name, args: string]] = @[]
  var toolCallBuffers: seq[string] = @[]
  var currentBlockType = ""
  var thinkingSignature = ""
  
  while not bodyStream.atEnd:
    let line = bodyStream.readLine()
    
    if not line.startsWith("data: "):
      continue
    
    let data = line[6 .. ^1]
    
    try:
      let event = parseJson(data)
      let eventType = event{"type"}.getStr("")
      
      case eventType
      of "message_start":
        let message = event{"message"}
        if message.kind == JObject:
          let usage = message{"usage"}
          if usage.kind == JObject:
            callback(StreamEvent(
              kind: setUsage,
              inputTokens: usage{"input_tokens"}.getInt(0),
              outputTokens: usage{"output_tokens"}.getInt(0),
              cacheReadTokens: usage{"cache_read_input_tokens"}.getInt(0),
              cacheWriteTokens: usage{"cache_creation_input_tokens"}.getInt(0),
            ))
      
      of "content_block_start":
        let contentBlock = event{"content_block"}
        if contentBlock.kind == JObject:
          let blockType = contentBlock{"type"}.getStr("")
          currentBlockType = blockType
          if blockType == "tool_use":
            toolCallIdx = toolCalls.len
            toolCalls.add((
              contentBlock{"id"}.getStr(""),
              contentBlock{"name"}.getStr(""),
              ""
            ))
            toolCallBuffers.add("")
      
      of "content_block_delta":
        let delta = event{"delta"}
        if delta.kind == JObject:
          let deltaType = delta{"type"}.getStr("")
          case deltaType
          of "text_delta":
            let text = delta{"text"}.getStr("")
            if text != "":
              callback(StreamEvent(kind: setTextDelta, textDelta: text))
          of "thinking_delta":
            let thinking = delta{"thinking"}.getStr("")
            if thinking != "":
              callback(StreamEvent(kind: setThinkDelta, thinkDelta: thinking))
          of "signature_delta":
            thinkingSignature &= delta{"signature"}.getStr("")
          of "input_json_delta":
            if toolCallIdx >= 0 and toolCallIdx < toolCallBuffers.len:
              toolCallBuffers[toolCallIdx] &= delta{"partial_json"}.getStr("")
          else:
            discard
      
      of "content_block_stop":
        if currentBlockType == "tool_use" and toolCallIdx >= 0 and toolCallIdx < toolCalls.len:
          var args: JsonNode
          try:
            args = parseJson(toolCallBuffers[toolCallIdx])
          except:
            args = newJObject()
          callback(StreamEvent(kind: setToolCall, toolCallId: toolCalls[toolCallIdx].id, toolName: toolCalls[toolCallIdx].name, toolArgs: args))
        toolCallIdx = -1
        currentBlockType = ""
      
      of "message_delta":
        let delta = event{"delta"}
        if delta.kind == JObject and delta.hasKey("stop_reason"):
          discard  # stop_reason handled at stream end
        let usage = event{"usage"}
        if usage.kind == JObject:
          callback(StreamEvent(
            kind: setUsage,
            inputTokens: 0,
            outputTokens: usage{"output_tokens"}.getInt(0),
          ))
      
      of "message_stop":
        discard
      
      of "ping":
        discard
      
      of "error":
        let errMsg = event{"error"}{"message"}.getStr("stream error")
        let errType = event{"error"}{"type"}.getStr("")
        callback(StreamEvent(kind: setError, error: (if errType != "": errType & ": " else: "") & errMsg))
        return
      
      else:
        discard
    
    except JsonParsingError:
      continue
  
  callback(StreamEvent(kind: setDone, stopReason: "stop"))

method chatStream*(p: AnthropicProvider, params: ChatParams, callback: StreamCallback) =
  ## Streaming chat with automatic retry
  if not p.retryEnabled:
    try:
      p.doChatStream(params, callback)
    except CatchableError as e:
      callback(StreamEvent(kind: setError, error: e.msg))
    return
  
  var lastError = ""
  for attempt in 0 .. p.maxRetries:
    try:
      p.doChatStream(params, callback)
      return
    except CatchableError as e:
      lastError = e.msg
      var statusCode = 0
      try:
        let parts = lastError.split(" ")
        if parts.len >= 3 and parts[0] == "API" and parts[1] == "error":
          statusCode = parseInt(parts[2])
      except:
        discard
      
      if not isRetryable(statusCode, lastError):
        callback(StreamEvent(kind: setError, error: lastError))
        return
      
      if attempt < p.maxRetries:
        let delay = retryDelay(attempt, p.baseDelayMs)
        callback(StreamEvent(kind: setRetry, retryAttempt: attempt + 1, retryMax: p.maxRetries, retryError: lastError))
        sleep(delay)
  
  callback(StreamEvent(kind: setError, error: lastError))

method chat*(p: AnthropicProvider, params: ChatParams): seq[StreamEvent] =
  ## Non-streaming fallback
  var events: seq[StreamEvent] = @[]
  proc collect(event: StreamEvent) =
    events.add(event)
  p.chatStream(params, collect)
  return events
