import std/[json, strutils, os]
import ./types
import ../net/streamhttp

type
  GoogleGeminiProvider* = ref object of Provider
    apiKey: string
    baseUrl: string
    streamClient: StreamHttpClient
    retryEnabled*: bool
    maxRetries*: int
    baseDelayMs*: int

proc newGoogleGeminiProvider*(apiKey, baseUrl: string, retryEnabled: bool = true, maxRetries: int = 3, baseDelayMs: int = 2000, proxyUrl: string = ""): GoogleGeminiProvider =
  let defaultBaseUrl = "https://generativelanguage.googleapis.com/v1beta/models"
  result = GoogleGeminiProvider(
    name: "google-gemini",
    apiKey: apiKey,
    baseUrl: if baseUrl == "": defaultBaseUrl else: baseUrl.strip(chars = {'/'}),
    streamClient: newStreamHttpClient(timeout = 300_000, proxyUrl = proxyUrl),
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

proc convertMessages(params: ChatParams): tuple[system: string, contents: JsonNode] =
  ## Convert messages to Google Gemini format
  var systemParts: seq[string] = @[]
  var contents = newJArray()

  if params.systemPrompt != "":
    systemParts.add(params.systemPrompt)

  for msg in params.messages:
    var jmsg = newJObject()
    case msg.role
    of mrUser:
      var parts = newJArray()
      if msg.contents.len > 0:
        for c in msg.contents:
          case c.kind
          of cbtText:
            parts.add(%*{"text": c.text})
          of cbtImage:
            parts.add(%*{
              "inline_data": {
                "mime_type": c.image.mimeType,
                "data": c.image.data
              }
            })
          else:
            discard
      if parts.len == 0:
        parts.add(%*{"text": msg.content})
      jmsg["role"] = %"user"
      jmsg["parts"] = parts
    of mrAssistant:
      jmsg["role"] = %"model"
      jmsg["parts"] = %*[{"text": msg.content}]
    of mrToolResult:
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
  var decls = newJArray()
  for t in tools:
    if t.kind == tdkHosted:
      continue  # Hosted tools not supported in Gemini
    decls.add(%*{
      "name": t.name,
      "description": t.description,
      "parameters": t.parameters
    })
  if decls.len == 0:
    return newJArray()
  result = %*[{"function_declarations": decls}]

proc parseGeminiLine(data: string, callback: StreamCallback,
  toolCalls: var seq[tuple[id, name, args: string]],
  toolCallBuffers: var seq[string]) =
  ## Parse a single SSE data line for Google Gemini
  try:
    let chunk = parseJson(data)

    # Usage metadata
    if chunk.hasKey("usageMetadata") and chunk["usageMetadata"].kind == JObject:
      let usage = chunk["usageMetadata"]
      callback(StreamEvent(
        kind: setUsage,
        inputTokens: usage{"promptTokenCount"}.getInt(0),
        outputTokens: usage{"candidatesTokenCount"}.getInt(0),
        reasoningTokens: usage{"thoughtsTokenCount"}.getInt(0),
      ))

    # Candidates
    if chunk.hasKey("candidates") and chunk["candidates"].kind == JArray:
      for candidate in chunk["candidates"]:
        if candidate.hasKey("content") and candidate["content"].kind == JObject:
          let content = candidate["content"]
          if content.hasKey("parts") and content["parts"].kind == JArray:
            for part in content["parts"]:
              # Text content (skip thoughts)
              if part.hasKey("text"):
                let text = part{"text"}.getStr("")
                if text != "":
                  if part.hasKey("thought") and part["thought"].getBool(false):
                    callback(StreamEvent(kind: setThinkDelta, thinkDelta: text))
                  else:
                    callback(StreamEvent(kind: setTextDelta, textDelta: text))

              # Function call
              if part.hasKey("functionCall") and part["functionCall"].kind == JObject:
                let fc = part["functionCall"]
                let name = fc{"name"}.getStr("")
                let argsNode = fc{"args"}
                let argsStr = if argsNode.kind != JNull: $argsNode else: ""
                toolCalls.add(("", name, ""))
                toolCallBuffers.add(argsStr)

        # Tool calls can also be surfaced at candidate level on finish
        if candidate.hasKey("finishReason") and candidate{"finishReason"}.getStr("") != "":
          discard

  except JsonParsingError:
    discard

proc doChatStream(p: GoogleGeminiProvider, params: ChatParams, callback: StreamCallback) =
  ## Single streaming attempt using pure Nim socket streaming
  let (system, contents) = convertMessages(params)
  let tools = convertTools(params.tools)

  var body = %*{
    "contents": contents,
    "generationConfig": {
      "maxOutputTokens": (if params.maxTokens > 0: params.maxTokens else: 8192)
    }
  }

  if system != "":
    body["systemInstruction"] = %*{"parts": [{"text": system}]}

  if params.tools.len > 0 and tools.len > 0:
    body["tools"] = tools

  # Thinking/reasoning support (Gemini 2.5 thinking models)
  if params.thinkingLevel != tlOff:
    let thinkingConfig = case params.thinkingLevel
      of tlMinimal: 1024
      of tlLow: 4096
      of tlMedium: 8192
      of tlHigh: 16384
      of tlXHigh: 32768
      else: 8192
    body["generationConfig"]["thinkingConfig"] = %*{
      "thinkingBudget": thinkingConfig
    }

  let url = parseStreamUrl(p.baseUrl & "/" & params.modelId & ":streamGenerateContent?key=" & p.apiKey & "&alt=sse")
  let headers: seq[(string, string)] = @[
    ("Content-Type", "application/json"),
  ]

  var toolCalls: seq[tuple[id, name, args: string]] = @[]
  var toolCallBuffers: seq[string] = @[]

  callback(StreamEvent(kind: setStart))

  proc onLine(line: string) =
    if p.interruptCheck != nil and p.interruptCheck():
      raise newException(CatchableError, "Interrupted by user")
    if not line.startsWith("data: "):
      return
    let data = line[6 .. ^1]
    parseGeminiLine(data, callback, toolCalls, toolCallBuffers)

  let resp = p.streamClient.performRequest(url, "POST", $body, headers, onLine)

  if resp.statusCode != 200:
    callback(StreamEvent(kind: setError, error: "API error " & $resp.statusCode & ": " & resp.statusText))
    return

  # Emit tool calls
  for i, tc in toolCalls:
    var args: JsonNode
    try:
      args = parseJson(toolCallBuffers[i])
    except:
      args = newJObject()
    let id = if tc.id == "": "toolcall_" & $i else: tc.id
    callback(StreamEvent(kind: setToolCall, toolCallId: id, toolName: tc.name, toolArgs: args))

  callback(StreamEvent(kind: setDone, stopReason: "stop"))

method chatStream*(p: GoogleGeminiProvider, params: ChatParams, callback: StreamCallback) =
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

method chat*(p: GoogleGeminiProvider, params: ChatParams): seq[StreamEvent] =
  ## Non-streaming fallback
  var events: seq[StreamEvent] = @[]
  proc collect(event: StreamEvent) =
    events.add(event)
  p.chatStream(params, collect)
  return events
