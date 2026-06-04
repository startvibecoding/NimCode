## A2A (Agent-to-Agent) protocol for NimCode.
## Implements the Google A2A specification for agent interoperability.

import std/[json, os, times, strutils, tables, asynchttpserver, asyncdispatch, httpclient]

const a2aProtocolVersion* = "0.1"

type
  TaskState* = enum
    tsSubmitted = "submitted"
    tsWorking = "working"
    tsCompleted = "completed"
    tsFailed = "failed"
    tsCanceled = "canceled"

  MessagePart* = object
    kind*: string  ## "text"
    text*: string

  A2AMessage* = object
    role*: string  ## "user" or "agent"
    parts*: seq[MessagePart]

  Artifact* = object
    name*: string
    description*: string
    parts*: seq[MessagePart]

  TaskError* = object
    code*: int
    message*: string

  Task* = object
    id*: string
    state*: TaskState
    message*: A2AMessage
    artifacts*: seq[Artifact]
    error*: TaskError
    createdAt*: Time
    updatedAt*: Time

  AgentCard* = object
    name*: string
    description*: string
    url*: string
    version*: string
    capabilities*: AgentCapabilities

  AgentCapabilities* = object
    streaming*: bool
    pushNotifications*: bool

  A2AServerConfig* = object
    listen*: string  ## e.g. ":8181"
    agentCard*: AgentCard

  TaskHandler* = proc(task: Task): Task {.closure.}

  A2AServer* = ref object
    config*: A2AServerConfig
    handler*: TaskHandler
    tasks*: Table[string, Task]

proc defaultAgentCard*(version: string, serverUrl: string): AgentCard =
  AgentCard(
    name: "NimCode",
    description: "AI coding assistant",
    url: serverUrl,
    version: version,
    capabilities: AgentCapabilities(streaming: false, pushNotifications: false),
  )

proc newA2AServer*(config: A2AServerConfig, handler: TaskHandler): A2AServer =
  result = A2AServer(
    config: config,
    handler: handler,
    tasks: initTable[string, Task](),
  )

proc generateTaskId(): string =
  let now = getTime().toUnix()
  result = "task-" & $now & "-" & $(rand(9999))

proc handleAgentCard(server: A2AServer, req: Request) {.async.} =
  ## Handle GET /.well-known/agent.json
  let cardJson = %*{
    "name": server.config.agentCard.name,
    "description": server.config.agentCard.description,
    "url": server.config.agentCard.url,
    "version": server.config.agentCard.version,
    "capabilities": {
      "streaming": server.config.agentCard.capabilities.streaming,
      "pushNotifications": server.config.agentCard.capabilities.pushNotifications,
    },
    "skills": [],
  }
  await req.respond(Http200, $cardJson, newHttpHeaders([("Content-Type", "application/json")]))

proc handleTasksSend(server: A2AServer, req: Request) {.async.} =
  ## Handle POST / (tasks/send)
  try:
    let body = parseJson(req.body)
    let method = body{"method"}.getStr("")
    
    if method == "tasks/send":
      let params = body{"params"}
      let taskId = params{"id"}.getStr("")
      let message = params{"message"}
      
      var task = Task(
        id: if taskId != "": taskId else: generateTaskId(),
        state: tsWorking,
        createdAt: getTime(),
        updatedAt: getTime(),
      )
      
      # Extract message
      if message.kind == JObject:
        task.message.role = message{"role"}.getStr("user")
        if message.hasKey("parts") and message["parts"].kind == JArray:
          for part in message["parts"]:
            task.message.parts.add(MessagePart(
              kind: part{"type"}.getStr("text"),
              text: part{"text"}.getStr(""),
            ))
      
      # Process task
      if server.handler != nil:
        task = server.handler(task)
      
      task.updatedAt = getTime()
      server.tasks[task.id] = task
      
      let response = %*{
        "jsonrpc": "2.0",
        "id": body{"id"},
        "result": {
          "id": task.id,
          "state": $task.state,
          "artifacts": task.artifacts.mapIt(%*{
            "name": it.name,
            "description": it.description,
            "parts": it.parts.mapIt(%*{"type": it.kind, "text": it.text}),
          }),
        },
      }
      await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
    else:
      let error = %*{
        "jsonrpc": "2.0",
        "id": body{"id"},
        "error": {"code": -32601, "message": "Method not found: " & method},
      }
      await req.respond(Http400, $error, newHttpHeaders([("Content-Type", "application/json")]))
  except CatchableError as e:
    let error = %*{
      "jsonrpc": "2.0",
      "error": {"code": -32603, "message": e.msg},
    }
    await req.respond(Http500, $error, newHttpHeaders([("Content-Type", "application/json")]))

proc handleRequest(server: A2AServer, req: Request) {.async.} =
  ## Route incoming requests
  let path = req.url.path
  
  case req.reqMethod
  of HttpGet:
    if path == "/.well-known/agent.json":
      await server.handleAgentCard(req)
    else:
      await req.respond(Http404, "Not Found")
  of HttpPost:
    if path == "/":
      await server.handleTasksSend(req)
    else:
      await req.respond(Http404, "Not Found")
  else:
    await req.respond(Http405, "Method Not Allowed")

proc start*(server: A2AServer) {.async.} =
  ## Start the A2A HTTP server
  let port = if server.config.listen.startsWith(":"):
    parseInt(server.config.listen[1..^1])
  else:
    8181
  
  var httpServer = newAsyncHttpServer()
  
  proc handler(req: Request) {.async.} =
    await server.handleRequest(req)
  
  echo "A2A server listening on port " & $port
  await httpServer.serve(Port(port), handler)

## Client for calling other A2A servers
proc sendTask*(serverUrl: string, task: Task): Task =
  ## Send a task to an A2A server
  let client = newHttpClient()
  client.headers = newHttpHeaders([("Content-Type", "application/json")])
  
  let request = %*{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tasks/send",
    "params": {
      "id": task.id,
      "message": {
        "role": task.message.role,
        "parts": task.message.parts.mapIt(%*{"type": it.kind, "text": it.text}),
      },
    },
  }
  
  try:
    let response = client.postContent(serverUrl, $request)
    let respJson = parseJson(response)
    
    var result_task = task
    if respJson.hasKey("result"):
      let r = respJson["result"]
      result_task.state = parseEnum[TaskState](r{"state"}.getStr("submitted"))
      if r.hasKey("artifacts") and r["artifacts"].kind == JArray:
        for art in r["artifacts"]:
          var artifact = Artifact()
          artifact.name = art{"name"}.getStr("")
          artifact.description = art{"description"}.getStr("")
          if art.hasKey("parts") and art["parts"].kind == JArray:
            for part in art["parts"]:
              artifact.parts.add(MessagePart(kind: part{"type"}.getStr("text"), text: part{"text"}.getStr("")))
          result_task.artifacts.add(artifact)
    
    return result_task
  except CatchableError as e:
    var failed = task
    failed.state = tsFailed
    failed.error = TaskError(code: -1, message: e.msg)
    return failed
