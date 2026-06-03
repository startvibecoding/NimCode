import std/[json, httpclient, streams, strutils, times, os]
import ./types

type
  OpenAiProvider* = ref object of Provider
    apiKey: string
    baseUrl: string
    client: HttpClient
    retryEnabled*: bool
    maxRetries*: int
    baseDelayMs*: int

proc newOpenAiProvider*(apiKey, baseUrl: string, retryEnabled: bool = true, maxRetries: int = 3, baseDelayMs: int = 2000): OpenAiProvider =
  result = OpenAiProvider(
    name: "openai",
    apiKey: apiKey,
    baseUrl: baseUrl.strip(chars = {'/'}),
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

proc convertMessages(params: ChatParams): JsonNode =
  result = newJArray()
  if params.systemPrompt != "":
    result.add(%*{"role": "system", "content": params.systemPrompt})
  for msg in params.messages:
    var jmsg = newJObject()
    case msg.role
    of mrUser:
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
    result.add(%*{
      "type": "function",
      "function": {
        "name": t.name,
        "description": t.description,
        "parameters": t.parameters
      }
    })

proc doChatStream(p: OpenAiProvider, params: ChatParams, callback: StreamCallback) =
  ## Single streaming chat attempt — invokes callback for each event as it arrives
  let messages = convertMessages(params)
  let tools = convertTools(params.tools)
  
  var body = %*{
    "model": params.modelId,
    "messages": messages,
    "stream": true,
    "stream_options": {"include_usage": true}
  }
  
  if params.tools.len > 0:
    body["tools"] = tools
  if params.maxTokens > 0:
    body["max_tokens"] = %params.maxTokens
  
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
  
  # Parse SSE stream — emit events as they arrive
  let bodyStream = response.bodyStream
  var toolCalls: seq[tuple[id, name, args: string]] = @[]
  
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
      if chunk.hasKey("usage"):
        let usage = chunk["usage"]
        callback(StreamEvent(
          kind: setUsage,
          inputTokens: usage{"prompt_tokens"}.getInt(0),
          outputTokens: usage{"completion_tokens"}.getInt(0)
        ))
      
      # Choices
      if chunk.hasKey("choices") and chunk["choices"].kind == JArray:
        for choice in chunk["choices"]:
          if choice.hasKey("delta"):
            let delta = choice["delta"]
            
            # Text content — emit immediately
            if delta.hasKey("content") and delta["content"].kind != JNull:
              let text = delta["content"].getStr("")
              if text != "":
                callback(StreamEvent(kind: setTextDelta, textDelta: text))
            
            # Tool calls
            if delta.hasKey("tool_calls") and delta["tool_calls"].kind == JArray:
              for tc in delta["tool_calls"]:
                let idx = tc{"index"}.getInt(0)
                while toolCalls.len <= idx:
                  toolCalls.add(("", "", ""))
                if tc.hasKey("id") and tc["id"].kind != JNull:
                  toolCalls[idx].id = tc["id"].getStr("")
                if tc.hasKey("function"):
                  let fn = tc["function"]
                  if fn.hasKey("name") and fn["name"].kind != JNull:
                    toolCalls[idx].name = fn["name"].getStr("")
                  if fn.hasKey("arguments") and fn["arguments"].kind != JNull:
                    toolCalls[idx].args &= fn["arguments"].getStr("")
          
          # Finish reason
          if choice.hasKey("finish_reason") and choice["finish_reason"].kind != JNull:
            let reason = choice["finish_reason"].getStr("")
            if reason == "tool_calls":
              for tc in toolCalls:
                var args: JsonNode
                try:
                  args = parseJson(tc.args)
                except:
                  args = newJObject()
                callback(StreamEvent(
                  kind: setToolCall,
                  toolCallId: tc.id,
                  toolName: tc.name,
                  toolArgs: args
                ))
              toolCalls = @[]
    
    except JsonParsingError:
      continue
  
  callback(StreamEvent(kind: setDone, stopReason: "stop"))

method chatStream*(p: OpenAiProvider, params: ChatParams, callback: StreamCallback) =
  ## Streaming chat with automatic retry on transient errors
  proc doAttempt() =
    p.doChatStream(params, callback)
  
  if not p.retryEnabled:
    try:
      doAttempt()
    except CatchableError as e:
      callback(StreamEvent(kind: setError, error: e.msg))
    return
  
  var lastError = ""
  for attempt in 0 .. p.maxRetries:
    try:
      doAttempt()
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
        callback(StreamEvent(kind: setError, error: "Retrying (" & $(attempt+1) & "/" & $p.maxRetries & "): " & lastError & " — waiting " & $(delay div 1000) & "s..."))
        sleep(delay)
  
  callback(StreamEvent(kind: setError, error: lastError))

method chat*(p: OpenAiProvider, params: ChatParams): seq[StreamEvent] =
  ## Non-streaming fallback: collects all events into a seq
  var events: seq[StreamEvent] = @[]
  proc collect(event: StreamEvent) =
    events.add(event)
  p.chatStream(params, collect)
  return events
