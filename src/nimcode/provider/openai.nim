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
  ## Check if an error is retryable (429, 5xx, network errors)
  if statusCode == 429 or statusCode == 502 or statusCode == 503 or statusCode == 504:
    return true
  let lower = errMsg.toLower
  if lower.contains("timeout") or lower.contains("connection reset") or
     lower.contains("connection refused") or lower.contains("eof") or
     lower.contains("broken pipe"):
    return true
  return false

proc retryDelay(attempt, baseDelayMs: int): int =
  ## Exponential backoff with cap at 30s
  result = baseDelayMs * (1 shl attempt)
  if result > 30000:
    result = 30000

proc convertMessages(params: ChatParams): JsonNode =
  result = newJArray()
  
  # System prompt
  if params.systemPrompt != "":
    result.add(%*{"role": "system", "content": params.systemPrompt})
  
  # Conversation messages
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

proc doChat(p: OpenAiProvider, params: ChatParams): seq[StreamEvent] =
  ## Single chat attempt (no retry)
  result = @[]
  
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
    raise newException(CatchableError, "API error " & response.status & ": " & errBody)
  
  # Parse SSE stream
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
        result.add(StreamEvent(
          kind: setUsage,
          inputTokens: usage{"prompt_tokens"}.getInt(0),
          outputTokens: usage{"completion_tokens"}.getInt(0)
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
                result.add(StreamEvent(kind: setTextDelta, textDelta: text))
            
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
              # Emit tool calls
              for tc in toolCalls:
                var args: JsonNode
                try:
                  args = parseJson(tc.args)
                except:
                  args = newJObject()
                result.add(StreamEvent(
                  kind: setToolCall,
                  toolCallId: tc.id,
                  toolName: tc.name,
                  toolArgs: args
                ))
              toolCalls = @[]
    
    except JsonParsingError:
      continue
  
  result.add(StreamEvent(kind: setDone, stopReason: "stop"))

method chat*(p: OpenAiProvider, params: ChatParams): seq[StreamEvent] =
  ## Chat with automatic retry on transient errors
  if not p.retryEnabled:
    try:
      return p.doChat(params)
    except CatchableError as e:
      return @[StreamEvent(kind: setError, error: e.msg)]
  
  var lastError = ""
  for attempt in 0 .. p.maxRetries:
    try:
      return p.doChat(params)
    except CatchableError as e:
      lastError = e.msg
      # Check if retryable
      var statusCode = 0
      try:
        # Extract status code from error message like "API error 429 Too Many Requests: ..."
        let parts = lastError.split(" ")
        if parts.len >= 3 and parts[0] == "API" and parts[1] == "error":
          statusCode = parseInt(parts[2])
      except:
        discard
      
      if not isRetryable(statusCode, lastError):
        return @[StreamEvent(kind: setError, error: lastError)]
      
      if attempt < p.maxRetries:
        let delay = retryDelay(attempt, p.baseDelayMs)
        # Emit retry event for UI
        result.add(StreamEvent(kind: setError, error: "Retrying (" & $(attempt+1) & "/" & $p.maxRetries & "): " & lastError & " — waiting " & $(delay div 1000) & "s..."))
        sleep(delay)
        result = @[]  # Clear retry message
  
  return @[StreamEvent(kind: setError, error: lastError)]
