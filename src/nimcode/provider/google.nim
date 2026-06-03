import std/[json, httpclient, streams, strutils, sequtils, options]
import ./types

type
  GoogleGeminiProvider* = ref object of Provider
    apiKey: string
    baseUrl: string
    client: HttpClient

proc newGoogleGeminiProvider*(apiKey, baseUrl: string): GoogleGeminiProvider =
  let defaultBaseUrl = "https://generativelanguage.googleapis.com/v1beta/models"
  result = GoogleGeminiProvider(
    name: "google-gemini",
    apiKey: apiKey,
    baseUrl: if baseUrl == "": defaultBaseUrl else: baseUrl.strip(chars = {'/'}),
    client: newHttpClient(timeout = 300_000),
  )

proc convertMessages(params: ChatParams): tuple[system: string, contents: JsonNode] =
  ## Convert messages to Google Gemini format
  var systemParts: seq[string] = @[]
  var contents = newJArray()
  
  # System prompt
  if params.systemPrompt != "":
    systemParts.add(params.systemPrompt)
  
  # Conversation messages
  for msg in params.messages:
    var jmsg = newJObject()
    case msg.role
    of mrUser:
      jmsg["role"] = %"user"
      jmsg["parts"] = %*[{"text": msg.content}]
    of mrAssistant:
      jmsg["role"] = %"model"
      jmsg["parts"] = %*[{"text": msg.content}]
    of mrToolResult:
      # Google Gemini uses functionResponse
      jmsg["role"] = %"user"
      jmsg["parts"] = %*[{
        "functionResponse": {
          "name": msg.toolName,
          "response": {
            "content": msg.content
          }
        }
      }]
    contents.add(jmsg)
  
  return (systemParts.join("\n"), contents)

proc convertTools(tools: seq[ToolDefinition]): JsonNode =
  result = %*[{
    "function_declarations": tools.mapIt(%*{
      "name": it.name,
      "description": it.description,
      "parameters": it.parameters
    })
  }]

method chat*(p: GoogleGeminiProvider, params: ChatParams): seq[StreamEvent] =
  result = @[]
  
  let (system, contents) = convertMessages(params)
  let tools = convertTools(params.tools)
  
  var body = %*{
    "contents": contents,
    "generationConfig": {
      "maxOutputTokens": params.maxTokens
    }
  }
  
  if system != "":
    body["systemInstruction"] = %*{"parts": [{"text": system}]}
  
  if params.tools.len > 0:
    body["tools"] = tools
  
  let url = p.baseUrl & "/" & params.modelId & ":streamGenerateContent?key=" & p.apiKey
  
  var headers = newHttpHeaders([
    ("Content-Type", "application/json"),
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
      
      # Google uses SSE format
      if not line.startsWith("data: "):
        continue
      
      let data = line[6 .. ^1]
      if data == "[DONE]":
        break
      
      try:
        let chunk = parseJson(data)
        
        # Parse candidates
        if chunk.hasKey("candidates") and chunk["candidates"].kind == JArray:
          for candidate in chunk["candidates"]:
            if candidate.hasKey("content"):
              let content = candidate["content"]
              if content.hasKey("parts") and content["parts"].kind == JArray:
                for part in content["parts"]:
                  # Text content
                  if part.hasKey("text"):
                    let text = part["text"].getStr("")
                    if text != "":
                      result.add(StreamEvent(kind: setTextDelta, textDelta: text))
                  
                  # Function call
                  if part.hasKey("functionCall"):
                    let fc = part["functionCall"]
                    let name = fc{"name"}.getStr("")
                    let args = fc{"args"}
                    toolCalls.add(("", name, $args))
        
        # Usage metadata
        if chunk.hasKey("usageMetadata"):
          let usage = chunk["usageMetadata"]
          result.add(StreamEvent(
            kind: setUsage,
            inputTokens: usage{"promptTokenCount"}.getInt(0),
            outputTokens: usage{"candidatesTokenCount"}.getInt(0)
          ))
      
      except JsonParsingError:
        continue
    
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
    
    result.add(StreamEvent(kind: setDone, stopReason: "stop"))
  
  except CatchableError as e:
    result.add(StreamEvent(kind: setError, error: e.msg))
