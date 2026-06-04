## Hermes daemon for NimCode.
## Provides a long-running HTTP server with webhook and WebSocket support.

import std/[json, os, strutils, times, tables, asynchttpserver, asyncdispatch, httpclient, net]

const hermesVersion* = "0.1.1"

type
  HermesConfig* = object
    listen*: string        ## e.g. ":8080"
    provider*: string
    model*: string
    workDir*: string
    webhookSecret*: string
    daemon*: bool

  WebhookPayload* = object
    event*: string         ## "message", "tool_call", "error"
    data*: JsonNode
    timestamp*: Time

  HermesServer* = ref object
    config*: HermesConfig
    running*: bool

proc defaultHermesConfig*(): HermesConfig =
  HermesConfig(
    listen: ":8080",
    workDir: getCurrentDir(),
  )

proc newHermesServer*(config: HermesConfig): HermesServer =
  result = HermesServer(
    config: config,
    running: false,
  )

proc handleHealth(server: HermesServer, req: Request) {.async.} =
  ## Handle GET /health
  let resp = %*{
    "status": "ok",
    "version": hermesVersion,
    "uptime": 0,
  }
  await req.respond(Http200, $resp, newHttpHeaders([("Content-Type", "application/json")]))

proc handleWebhook(server: HermesServer, req: Request) {.async.} =
  ## Handle POST /webhook
  try:
    let body = parseJson(req.body)
    let event = body{"event"}.getStr("")
    
    # Process webhook event
    case event
    of "message":
      let message = body{"data"}{"message"}.getStr("")
      echo "Hermes webhook: message received: " & message[0 ..< min(message.len, 100)]
    of "tool_call":
      let toolName = body{"data"}{"tool"}.getStr("")
      echo "Hermes webhook: tool call: " & toolName
    else:
      echo "Hermes webhook: unknown event: " & event
    
    let resp = %*{"status": "received", "event": event}
    await req.respond(Http200, $resp, newHttpHeaders([("Content-Type", "application/json")]))
  except CatchableError as e:
    let error = %*{"error": e.msg}
    await req.respond(Http400, $error, newHttpHeaders([("Content-Type", "application/json")]))

proc handleChat(server: HermesServer, req: Request) {.async.} =
  ## Handle POST /chat - send a message to the agent
  try:
    let body = parseJson(req.body)
    let message = body{"message"}.getStr("")
    let provider = body{"provider"}.getStr(server.config.provider)
    let model = body{"model"}.getStr(server.config.model)
    
    # In a full implementation, this would create an agent and process the message
    # For now, return a placeholder response
    let resp = %*{
      "status": "accepted",
      "message": "Chat request received (not yet implemented)",
      "provider": provider,
      "model": model,
    }
    await req.respond(Http200, $resp, newHttpHeaders([("Content-Type", "application/json")]))
  except CatchableError as e:
    let error = %*{"error": e.msg}
    await req.respond(Http400, $error, newHttpHeaders([("Content-Type", "application/json")]))

proc handleRequest(server: HermesServer, req: Request) {.async.} =
  ## Route incoming requests
  let path = req.url.path
  
  case req.reqMethod
  of HttpGet:
    if path == "/health":
      await server.handleHealth(req)
    else:
      await req.respond(Http404, "Not Found")
  of HttpPost:
    if path == "/webhook":
      await server.handleWebhook(req)
    elif path == "/chat":
      await server.handleChat(req)
    else:
      await req.respond(Http404, "Not Found")
  else:
    await req.respond(Http405, "Method Not Allowed")

proc start*(server: HermesServer) {.async.} =
  ## Start the Hermes daemon
  server.running = true
  
  let port = if server.config.listen.startsWith(":"):
    parseInt(server.config.listen[1..^1])
  else:
    8080
  
  var httpServer = newAsyncHttpServer()
  
  proc handler(req: Request) {.async.} =
    await server.handleRequest(req)
  
  echo "Hermes daemon v" & hermesVersion & " listening on port " & $port
  echo "  Provider: " & server.config.provider
  echo "  Model: " & server.config.model
  echo "  Work dir: " & server.config.workDir
  echo ""
  echo "Endpoints:"
  echo "  GET  /health    - Health check"
  echo "  POST /webhook   - Webhook receiver"
  echo "  POST /chat      - Chat with agent"
  
  await httpServer.serve(Port(port), handler)

proc stop*(server: HermesServer) =
  ## Stop the Hermes daemon
  server.running = false
  echo "Hermes daemon stopped"
