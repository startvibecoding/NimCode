import std/[json, httpclient, streams, strutils, options]
import ./types

type
  AnthropicProvider* = ref object of Provider
    apiKey: string
    baseUrl: string
    client: HttpClient

proc newAnthropicProvider*(apiKey, baseUrl: string): AnthropicProvider =
  result = AnthropicProvider(
    name: "anthropic",
    apiKey: apiKey,
    baseUrl: baseUrl.strip(chars = {'/'}),
    client: newHttpClient(timeout = 300_000),
  )

proc convertMessages(params: ChatParams): tuple[system: string, messages: JsonNode] =
  ## Convert messages to Anthropic format
  var systemParts: seq[string] = @[]
  var messages = newJArray()
  
  # System prompt
  if params.systemPrompt != "":
    systemParts.add(params.systemPrompt)
  
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
      # Anthropic uses tool_result content blocks
      jmsg["role"] = %"user"
      jmsg["content"] = %*[{
        "type": "tool_result",
        "tool_use_id": msg.toolCallId,
        "content": msg.content,
        "is_error": msg.isError
      }]
    messages.add(jmsg)
  
  return (systemParts.join("\n"), messages)

proc convertTools(tools: seq[ToolDefinition]): JsonNode =
  result = newJArray()
  for t in tools:
    result.add(%*{
      "name": t.name,
      "description": t.description,
      "input_schema": t.parameters
    })

method chat*(p: AnthropicProvider, params: ChatParams): seq[StreamEvent] =
  result = @[]
  
  let (system, messages) = convertMessages(params)
  let tools = convertTools(params.tools)
  
  var body = %*{
    "model": params.modelId,
    "messages": messages,
    "max_tokens": params.maxTokens,
    "stream": true
  }
  
  if system != "":
    body["system"] = %system
  
  if params.tools.len > 0:
    body["tools"] = tools
  
  let url = p.baseUrl & "/v1/messages"
  
  var headers = newHttpHeaders([
    ("Content-Type", "application/json"),
    ("x-api-key", p.apiKey),
    ("anthropic-version", "2023-06-01"),
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
    var currentToolCallIdx = -1
    
    while not bodyStream.atEnd:
      let line = bodyStream.readLine()
      
      if not line.startsWith("data: "):
        continue
      
      let data = line[6 .. ^1]
      if data == "[DONE]":
        break
      
      try:
        let chunk = parseJson(data)
        let eventType = chunk{"type"}.getStr("")
        
        case eventType
        of "message_start":
          discard
        of "content_block_start":
          let contentBlock = chunk{"content_block"}
          if contentBlock{"type"}.getStr("") == "tool_use":
            currentToolCallIdx = toolCalls.len
            toolCalls.add((
              contentBlock{"id"}.getStr(""),
              contentBlock{"name"}.getStr(""),
              ""
            ))
        of "content_block_delta":
          let delta = chunk{"delta"}
          let deltaType = delta{"type"}.getStr("")
          
          case deltaType
          of "text_delta":
            let text = delta{"text"}.getStr("")
            if text != "":
              result.add(StreamEvent(kind: setTextDelta, textDelta: text))
          of "input_json_delta":
            if currentToolCallIdx >= 0 and currentToolCallIdx < toolCalls.len:
              let partialJson = delta{"partial_json"}.getStr("")
              toolCalls[currentToolCallIdx].args &= partialJson
          else:
            discard
        of "content_block_stop":
          currentToolCallIdx = -1
        of "message_delta":
          let delta = chunk{"delta"}
          if delta.hasKey("stop_reason"):
            let stopReason = delta{"stop_reason"}.getStr("")
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
        of "message_stop":
          discard
        of "ping":
          discard
        else:
          discard
      
      except JsonParsingError:
        continue
    
    result.add(StreamEvent(kind: setDone, stopReason: "stop"))
  
  except CatchableError as e:
    result.add(StreamEvent(kind: setError, error: e.msg))
