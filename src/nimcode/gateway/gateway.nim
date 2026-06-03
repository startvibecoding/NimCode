import std/[asynchttpserver, asyncdispatch, json, strutils, tables, options, os, times]
import ../config/config
import ../provider/types
import ../provider/openai
import ../provider/anthropic
import ../provider/google
import ../tools/tools
import ../session/session
import ../agent/agent
import ../contextfiles/contextfiles
import ../skills/skills
import ../memory/memory

type
  GatewayConfig* = object
    listen*: string
    provider*: string
    model*: string
    workDir*: string
    sandbox*: bool
    multiAgent*: bool
    verbose*: bool
    debug*: bool

  GatewayServer* = ref object
    config*: GatewayConfig
    settings*: Settings
    provider*: Provider
    agent*: Agent
    sessions*: Table[string, Session]

proc loadGatewayConfig*(): GatewayConfig =
  result = GatewayConfig(
    listen: ":8080",
    provider: "",
    model: "",
    workDir: getCurrentDir(),
    sandbox: false,
    multiAgent: false,
    verbose: false,
    debug: false
  )

proc handleRequest(req: Request, server: GatewayServer) {.async.} =
  case req.url.path
  of "/health":
    let response = %*{"status": "ok"}
    await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
  of "/v1/models":
    var models = newJArray()
    for name, provider in server.settings.providers:
      for model in provider.models:
        models.add(%*{
          "id": model.id,
          "name": model.name,
          "provider": name,
          "contextWindow": model.contextWindow,
          "maxTokens": model.maxTokens
        })
    let response = %*{"data": models}
    await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
  of "/v1/chat/completions":
    try:
      let body = req.body
      let jsonBody = parseJson(body)
      
      # Extract model and messages
      let modelId = jsonBody{"model"}.getStr("")
      let messagesNode = jsonBody{"messages"}
      
      if messagesNode.kind != JArray:
        await req.respond(Http400, "{\"error\": \"messages array required\"}", newHttpHeaders([("Content-Type", "application/json")]))
        return
      
      # Convert messages to our format
      var messages: seq[Message] = @[]
      for msgNode in messagesNode:
        let role = msgNode{"role"}.getStr("")
        let content = msgNode{"content"}.getStr("")
        
        case role
        of "user":
          messages.add(newUserMessage(content))
        of "assistant":
          messages.add(newAssistantMessage(content))
        of "system":
          # System messages are handled separately
          discard
        else:
          discard
      
      # Create agent if not exists
      var sessionId = "default"
      if req.headers.hasKey("x-session-id"):
        sessionId = $req.headers["x-session-id"]
      
      if sessionId notin server.sessions:
        server.sessions[sessionId] = newSession(server.config.workDir)
      
      let sess = server.sessions[sessionId]
      let agent = newAgent(
        server.provider, modelId, "agent", server.config.workDir, sess,
        settings = server.settings
      )
      
      # Process the last user message
      var lastUserMsg = ""
      for i in countdown(messages.len - 1, 0):
        if messages[i].role == mrUser:
          lastUserMsg = messages[i].content
          break
      
      if lastUserMsg == "":
        await req.respond(Http400, "{\"error\": \"no user message found\"}", newHttpHeaders([("Content-Type", "application/json")]))
        return
      
      # Non-streaming response
      var responseText = ""
      let events = agent.processAgentTurn(lastUserMsg)
      for event in events:
        case event.kind
        of aekTextDelta:
          responseText.add(event.textDelta)
        of aekDone:
          discard
        of aekError:
          await req.respond(Http500, "{\"error\": \"" & event.errorMsg & "\"}", newHttpHeaders([("Content-Type", "application/json")]))
          return
        else:
          discard
      
      let response = %*{
        "id": "chatcmpl-" & $epochTime().int,
        "object": "chat.completion",
        "created": epochTime().int,
        "model": modelId,
        "choices": [{
          "index": 0,
          "message": {
            "role": "assistant",
            "content": responseText
          },
          "finish_reason": "stop"
        }],
        "usage": {
          "prompt_tokens": 0,
          "completion_tokens": 0,
          "total_tokens": 0
        }
      }
      
      await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
    
    except CatchableError as e:
      await req.respond(Http500, "{\"error\": \"" & e.msg & "\"}", newHttpHeaders([("Content-Type", "application/json")]))
  else:
    await req.respond(Http404, "{\"error\": \"not found\"}", newHttpHeaders([("Content-Type", "application/json")]))

proc run*(config: GatewayConfig) {.async.} =
  # Load settings
  let settings = loadSettings()
  
  # Create provider
  let providerName = if config.provider != "": config.provider else: settings.defaultProvider
  let providerConfig = settings.getProviderConfig(providerName)
  if providerConfig.isNone:
    echo "Error: Provider not found: " & providerName
    return
  
  let pc = providerConfig.get()
  let apiKey = resolveKey(pc)
  
  var provider: Provider
  # Supports: openai-chat, openai-responses (OpenAI-compatible),
  #           anthropic-messages, google-gemini
  # Any other api type defaults to OpenAI-compatible
  if pc.api == "anthropic-messages":
    provider = newAnthropicProvider(apiKey, pc.baseUrl)
  elif pc.api == "google-gemini":
    provider = newGoogleGeminiProvider(apiKey, pc.baseUrl)
  else:
    # openai-chat, openai-responses, or any other OpenAI-compatible API
    provider = newOpenAiProvider(apiKey, pc.baseUrl)
  
  # Create server
  let server = GatewayServer(
    config: config,
    settings: settings,
    provider: provider,
    sessions: initTable[string, Session]()
  )
  
  # Start HTTP server
  let httpServer = newAsyncHttpServer()
  
  proc handler(req: Request): Future[void] {.gcsafe, async.} =
    {.gcsafe.}:
      await handleRequest(req, server)
  
  echo "NimCode Gateway listening on " & config.listen
  echo "Provider: " & providerName
  echo "Model: " & config.model
  
  await httpServer.serve(Port(config.listen.split(":")[1].parseInt), handler)

proc runGateway*(config: GatewayConfig) =
  waitFor run(config)
