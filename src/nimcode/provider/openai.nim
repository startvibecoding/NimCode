import std/[json, httpclient, streams, strutils]
import ./types

type
  OpenAiProvider* = ref object of Provider
    apiKey: string
    baseUrl: string
    client: HttpClient

proc newOpenAiProvider*(apiKey, baseUrl: string): OpenAiProvider =
  result = OpenAiProvider(
    name: "openai",
    apiKey: apiKey,
    baseUrl: baseUrl.strip(chars = {'/'}),
    client: newHttpClient(timeout = 300_000),
  )

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

method chat*(p: OpenAiProvider, params: ChatParams): seq[StreamEvent] =
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
  
  try:
    let response = p.client.request(url, httpMethod = HttpPost, body = $body, headers = headers)
    
    if response.status != "200 OK":
      let errBody = response.body
      result.add(StreamEvent(kind: setError, error: "API error " & response.status & ": " & errBody))
      return
    
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
  
  except CatchableError as e:
    result.add(StreamEvent(kind: setError, error: e.msg))
