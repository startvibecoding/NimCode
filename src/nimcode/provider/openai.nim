import std/[json, httpclient, streams, strutils, times, os, sequtils, tables]
import ./types

type
  OpenAiProvider* = ref object of Provider
    apiKey: string
    baseUrl: string
    client: HttpClient
    retryEnabled*: bool
    maxRetries*: int
    baseDelayMs*: int
    useResponsesApi*: bool  ## Use OpenAI Responses API (for o1/o3/reasoning models)
    disableReasoning*: bool ## Disable reasoning_content support for incompatible APIs
    thinkingFormat*: string ## "", "openai", "deepseek", "xiaomi"

proc newOpenAiProvider*(apiKey, baseUrl: string, retryEnabled: bool = true, maxRetries: int = 3, baseDelayMs: int = 2000): OpenAiProvider =
  let base = if baseUrl == "": "https://api.openai.com/v1" else: baseUrl.strip(chars = {'/'})
  result = OpenAiProvider(
    name: "openai",
    apiKey: apiKey,
    baseUrl: base,
    client: newHttpClient(timeout = 300_000),
    retryEnabled: retryEnabled,
    maxRetries: maxRetries,
    baseDelayMs: baseDelayMs,
    useResponsesApi: false,
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

# ---- Chat Completions API ----

proc convertMessages(params: ChatParams): JsonNode =
  result = newJArray()
  if params.systemPrompt != "":
    result.add(%*{"role": "system", "content": params.systemPrompt})
  for msg in params.messages:
    var jmsg = newJObject()
    case msg.role
    of mrUser:
      # Check for image content blocks
      var hasImage = false
      for c in msg.contents:
        if c.kind == cbtImage:
          hasImage = true
          break
      if hasImage:
        var parts = newJArray()
        for c in msg.contents:
          case c.kind
          of cbtText:
            parts.add(%*{"type": "text", "text": c.text})
          of cbtImage:
            parts.add(%*{"type": "image_url", "image_url": {"url": "data:" & c.image.mimeType & ";base64," & c.image.data}})
          else:
            discard
        if msg.content != "" and parts.len == 0:
          parts.add(%*{"type": "text", "text": msg.content})
        jmsg["role"] = %"user"
        jmsg["content"] = parts
      else:
        jmsg["role"] = %"user"
        jmsg["content"] = %msg.content
    of mrAssistant:
      jmsg["role"] = %"assistant"
      jmsg["content"] = %msg.content
    of mrToolResult:
      jmsg["role"] = %"tool"
      jmsg["content"] = %msg.content
      jmsg["tool_call_id"] = %msg.toolCallId
    result.add(jmsg)

proc convertTools(tools: seq[ToolDefinition]): JsonNode =
  result = newJArray()
  for t in tools:
    if t.kind == tdkHosted:
      continue  # Hosted tools not supported in chat completions
    result.add(%*{
      "type": "function",
      "function": {
        "name": t.name,
        "description": t.description,
        "parameters": t.parameters
      }
    })

proc thinkingFormatForModel(p: OpenAiProvider): string =
  if p.thinkingFormat != "":
    return p.thinkingFormat
  # Auto-detect from base URL
  let lower = p.baseUrl.toLower
  if lower.contains("deepseek"):
    return "deepseek"
  if lower.contains("xiaomi") or lower.contains("mimo"):
    return "xiaomi"
  return "openai"

proc doChatCompletionsStream(p: OpenAiProvider, params: ChatParams, callback: StreamCallback) =
  ## Single Chat Completions streaming attempt
  let messages = convertMessages(params)
  let tools = convertTools(params.tools)
  
  var body = %*{
    "model": params.modelId,
    "messages": messages,
    "stream": true,
    "stream_options": {"include_usage": true}
  }
  
  if params.tools.len > 0 and tools.len > 0:
    body["tools"] = tools
  if params.maxTokens > 0:
    body["max_tokens"] = %params.maxTokens
  if params.temperature > 0:
    body["temperature"] = %params.temperature
  if params.topP > 0:
    body["top_p"] = %params.topP
  
  # Thinking/reasoning support
  if params.thinkingLevel != tlOff:
    let format = p.thinkingFormatForModel()
    case format
    of "deepseek":
      body["thinking"] = %*{"type": "enabled"}
    of "xiaomi":
      body["thinking"] = %*{"type": "enabled"}
    of "openai":
      let effort = openaiReasoningEffort(params.thinkingLevel)
      if effort != "":
        body["reasoning_effort"] = %effort
    else:
      discard
  
  let url = p.baseUrl & "/chat/completions"
  var headers = newHttpHeaders([
    ("Content-Type", "application/json"),
    ("Authorization", "Bearer " & p.apiKey),
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
  var toolCalls: seq[tuple[id, name, args: string]] = @[]
  var toolCallBuffers: seq[string] = @[]
  
  while not bodyStream.atEnd:
    let line = bodyStream.readLine()
    
    if not line.startsWith("data: "):
      continue
    
    let data = line[6 .. ^1]
    if data == "[DONE]":
      break
    
    try:
      let chunk = parseJson(data)
      
      # Usage
      if chunk.hasKey("usage") and chunk["usage"].kind != JNull:
        let usage = chunk["usage"]
        callback(StreamEvent(
          kind: setUsage,
          inputTokens: usage{"prompt_tokens"}.getInt(0),
          outputTokens: usage{"completion_tokens"}.getInt(0),
          reasoningTokens: usage{"completion_tokens_details"}{"reasoning_tokens"}.getInt(0),
        ))
      
      # Choices
      if chunk.hasKey("choices") and chunk["choices"].kind == JArray:
        for choice in chunk["choices"]:
          if choice.hasKey("delta"):
            let delta = choice["delta"]
            
            # Text content
            if delta.hasKey("content") and delta["content"].kind != JNull:
              let text = delta["content"].getStr("")
              if text != "":
                callback(StreamEvent(kind: setTextDelta, textDelta: text))
            
            # Reasoning/thinking content
            if not p.disableReasoning and delta.hasKey("reasoning_content") and delta["reasoning_content"].kind != JNull:
              let thinking = delta["reasoning_content"].getStr("")
              if thinking != "":
                callback(StreamEvent(kind: setThinkDelta, thinkDelta: thinking))
            
            # Tool calls
            if delta.hasKey("tool_calls") and delta["tool_calls"].kind == JArray:
              for tc in delta["tool_calls"]:
                let idx = tc{"index"}.getInt(0)
                while toolCalls.len <= idx:
                  toolCalls.add(("", "", ""))
                while toolCallBuffers.len <= idx:
                  toolCallBuffers.add("")
                if tc.hasKey("id") and tc["id"].kind != JNull:
                  toolCalls[idx].id = tc["id"].getStr("")
                if tc.hasKey("function"):
                  let fn = tc["function"]
                  if fn.hasKey("name") and fn["name"].kind != JNull:
                    toolCalls[idx].name = fn["name"].getStr("")
                  if fn.hasKey("arguments") and fn["arguments"].kind != JNull:
                    toolCallBuffers[idx] &= fn["arguments"].getStr("")
          
          # Finish reason
          if choice.hasKey("finish_reason") and choice["finish_reason"].kind != JNull:
            let reason = choice["finish_reason"].getStr("")
            if reason == "tool_calls":
              for i, tc in toolCalls:
                var args: JsonNode
                try:
                  args = parseJson(toolCallBuffers[i])
                except:
                  args = newJObject()
                let id = if tc.id == "": "toolcall_" & $i else: tc.id
                callback(StreamEvent(
                  kind: setToolCall,
                  toolCallId: id,
                  toolName: tc.name,
                  toolArgs: args
                ))
              toolCalls = @[]
              toolCallBuffers = @[]
    
    except JsonParsingError:
      continue
  
  # Emit any remaining tool calls
  for i, tc in toolCalls:
    if i < toolCallBuffers.len and toolCallBuffers[i] != "":
      var args: JsonNode
      try:
        args = parseJson(toolCallBuffers[i])
      except:
        args = newJObject()
      let id = if tc.id == "": "toolcall_" & $i else: tc.id
      callback(StreamEvent(kind: setToolCall, toolCallId: id, toolName: tc.name, toolArgs: args))
  
  callback(StreamEvent(kind: setDone, stopReason: "stop"))

# ---- Responses API ----

proc convertResponsesInput(params: ChatParams): JsonNode =
  ## Convert messages to Responses API input format
  result = newJArray()
  for msg in params.messages:
    case msg.role
    of mrToolResult:
      result.add(%*{
        "type": "function_call_output",
        "call_id": msg.toolCallId,
        "output": msg.content
      })
    of mrAssistant:
      # Text content
      if msg.content != "":
        result.add(%*{
          "type": "message",
          "role": "assistant",
          "content": [{"type": "output_text", "text": msg.content}]
        })
      # Tool calls from contents
      for c in msg.contents:
        if c.kind == cbtToolCall:
          result.add(%*{
            "type": "function_call",
            "call_id": c.toolCallId,
            "name": c.toolName,
            "arguments": $c.toolArgs
          })
    else: # user
      var contentBlocks = newJArray()
      if msg.contents.len > 0:
        for c in msg.contents:
          case c.kind
          of cbtText:
            contentBlocks.add(%*{"type": "input_text", "text": c.text})
          of cbtImage:
            contentBlocks.add(%*{"type": "input_image", "image_url": "data:" & c.image.mimeType & ";base64," & c.image.data})
          else:
            discard
      else:
        contentBlocks.add(%*{"type": "input_text", "text": msg.content})
      result.add(%*{
        "type": "message",
        "role": "user",
        "content": contentBlocks
      })

proc convertResponsesTools(tools: seq[ToolDefinition]): JsonNode =
  result = newJArray()
  for t in tools:
    if t.kind == tdkHosted:
      let wireType = hostedWebSearchToolType(t.providerType, t.name)
      if wireType != "":
        result.add(%*{"type": wireType})
      continue
    result.add(%*{
      "type": "function",
      "name": t.name,
      "description": t.description,
      "parameters": t.parameters
    })

proc doResponsesStream(p: OpenAiProvider, params: ChatParams, callback: StreamCallback) =
  ## Single Responses API streaming attempt
  let input = convertResponsesInput(params)
  let tools = convertResponsesTools(params.tools)
  
  var body = %*{
    "model": params.modelId,
    "input": input,
    "stream": true,
    "max_output_tokens": (if params.maxTokens > 0: params.maxTokens else: 16384),
  }
  
  if params.systemPrompt != "":
    body["instructions"] = %params.systemPrompt
  if tools.len > 0:
    body["tools"] = tools
  if params.temperature > 0:
    body["temperature"] = %params.temperature
  if params.topP > 0:
    body["top_p"] = %params.topP
  
  # Thinking/reasoning support
  if params.thinkingLevel != tlOff:
    let effort = responsesReasoningEffort(params.thinkingLevel)
    if effort != "":
      body["reasoning"] = %*{"effort": effort, "summary": "auto"}
  
  let url = p.baseUrl & "/responses"
  var headers = newHttpHeaders([
    ("Content-Type", "application/json"),
    ("Authorization", "Bearer " & p.apiKey),
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
  var argumentBuffers = initTable[string, string]()
  var toolCallOrder: seq[string] = @[]
  var toolCallsByKey = initTable[string, tuple[id, name, args: string]]()
  
  while not bodyStream.atEnd:
    let line = bodyStream.readLine()
    
    if not line.startsWith("data: "):
      continue
    
    let data = line[6 .. ^1]
    if data == "[DONE]":
      break
    
    try:
      let event = parseJson(data)
      let eventType = event{"type"}.getStr("")
      
      case eventType
      of "response.output_text.delta":
        let delta = event{"delta"}.getStr("")
        if delta != "":
          callback(StreamEvent(kind: setTextDelta, textDelta: delta))
      
      of "response.reasoning_text.delta":
        let delta = event{"delta"}.getStr("")
        if delta != "":
          callback(StreamEvent(kind: setThinkDelta, thinkDelta: delta))
      
      of "response.function_call_arguments.delta":
        let itemId = event{"item_id"}.getStr("")
        let outputIndex = event{"output_index"}.getInt(0)
        let key = if itemId != "": itemId else: $outputIndex
        if key notin argumentBuffers:
          argumentBuffers[key] = ""
        argumentBuffers[key] &= event{"delta"}.getStr("")
      
      of "response.output_item.done":
        let item = event{"item"}
        if item.kind == JObject and item{"type"}.getStr("") == "function_call":
          let itemId = item{"id"}.getStr("")
          let outputIndex = event{"output_index"}.getInt(0)
          let key = if itemId != "": itemId else: $outputIndex
          var callId = item{"call_id"}.getStr("")
          if callId == "":
            callId = itemId
          if callId == "":
            callId = "toolcall_" & $toolCallOrder.len
          let name = item{"name"}.getStr("")
          var argsStr = item{"arguments"}.getStr("")
          if argsStr == "" and key in argumentBuffers:
            argsStr = argumentBuffers[key]
          if key notin toolCallsByKey:
            toolCallOrder.add(key)
          toolCallsByKey[key] = (callId, name, argsStr)
      
      of "response.completed":
        let resp = event{"response"}
        if resp.kind == JObject:
          let usage = resp{"usage"}
          if usage.kind == JObject:
            callback(StreamEvent(
              kind: setUsage,
              inputTokens: usage{"input_tokens"}.getInt(0),
              outputTokens: usage{"output_tokens"}.getInt(0),
              reasoningTokens: usage{"output_tokens_details"}{"reasoning_tokens"}.getInt(0),
            ))
          let error = resp{"error"}
          if error.kind == JObject:
            callback(StreamEvent(kind: setError, error: "Responses error: " & error{"message"}.getStr("")))
            return
      
      of "response.failed", "error":
        let errMsg = event{"error"}{"message"}.getStr("stream error")
        callback(StreamEvent(kind: setError, error: "Responses error: " & errMsg))
        return
      
      else:
        discard
    
    except JsonParsingError:
      continue
  
  # Emit tool calls
  for key in toolCallOrder:
    if key in toolCallsByKey:
      let tc = toolCallsByKey[key]
      var args: JsonNode
      try:
        args = parseJson(tc.args)
      except:
        args = newJObject()
      callback(StreamEvent(kind: setToolCall, toolCallId: tc.id, toolName: tc.name, toolArgs: args))
  
  callback(StreamEvent(kind: setDone, stopReason: "stop"))

# ---- Public API with retry ----

proc doChatStream(p: OpenAiProvider, params: ChatParams, callback: StreamCallback) =
  ## Single streaming attempt — routes to chat completions or responses API
  if p.useResponsesApi:
    p.doResponsesStream(params, callback)
  else:
    p.doChatCompletionsStream(params, callback)

method chatStream*(p: OpenAiProvider, params: ChatParams, callback: StreamCallback) =
  ## Streaming chat with automatic retry on transient errors
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

method chat*(p: OpenAiProvider, params: ChatParams): seq[StreamEvent] =
  ## Non-streaming fallback
  var events: seq[StreamEvent] = @[]
  proc collect(event: StreamEvent) =
    events.add(event)
  p.chatStream(params, collect)
  return events
