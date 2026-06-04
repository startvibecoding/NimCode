## A2A (Agent-to-Agent) protocol for NimCode.
## Implements the Google A2A specification for agent interoperability.
## Supports streaming via SSE, task management, and subscriptions.

import std/[json, os, times, strutils, tables, asynchttpserver, asyncdispatch, asyncnet, httpclient, random, sequtils]

const a2aProtocolVersion* = "0.2"

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

  TaskEvent* = object
    taskId*: string
    state*: TaskState
    artifact*: Artifact
    error*: TaskError
    timestamp*: Time

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

  ## Task handler that returns a channel of events for streaming
  TaskStreamHandler* = proc(task: Task): (Task, seq[TaskEvent]) {.closure.}

  ## Subscriber for task events
  TaskSubscriber* = ref object
    id*: string
    events*: seq[TaskEvent]

  TaskStore* = ref object
    tasks*: Table[string, Task]
    subscribers*: Table[string, seq[TaskSubscriber]]

  A2AServer* = ref object
    config*: A2AServerConfig
    handler*: TaskStreamHandler
    store*: TaskStore

proc newTaskStore*(): TaskStore =
  result = TaskStore(
    tasks: initTable[string, Task](),
    subscribers: initTable[string, seq[TaskSubscriber]](),
  )

proc get*(store: TaskStore, taskId: string): Task =
  if store.tasks.hasKey(taskId):
    return store.tasks[taskId]
  raise newException(CatchableError, "Task not found: " & taskId)

proc update*(store: TaskStore, task: Task) =
  store.tasks[task.id] = task
  # Notify subscribers
  if store.subscribers.hasKey(task.id):
    let event = TaskEvent(
      taskId: task.id,
      state: task.state,
      error: task.error,
      timestamp: getTime(),
    )
    for sub in store.subscribers[task.id]:
      sub.events.add(event)

proc subscribe*(store: TaskStore, taskId: string): TaskSubscriber =
  result = TaskSubscriber(id: taskId & "-" & $rand(99999), events: @[])
  if not store.subscribers.hasKey(taskId):
    store.subscribers[taskId] = @[]
  store.subscribers[taskId].add(result)

proc unsubscribe*(store: TaskStore, taskId: string, sub: TaskSubscriber) =
  if store.subscribers.hasKey(taskId):
    var subs = store.subscribers[taskId]
    for i in 0 ..< subs.len:
      if subs[i].id == sub.id:
        subs.delete(i)
        store.subscribers[taskId] = subs
        break

proc defaultAgentCard*(version: string, serverUrl: string): AgentCard =
  AgentCard(
    name: "NimCode",
    description: "AI coding assistant",
    url: serverUrl,
    version: version,
    capabilities: AgentCapabilities(streaming: true, pushNotifications: false),
  )

proc newA2AServer*(config: A2AServerConfig, handler: TaskStreamHandler = nil): A2AServer =
  result = A2AServer(
    config: config,
    handler: handler,
    store: newTaskStore(),
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

proc handleSendMessage(server: A2AServer, req: Request, body: JsonNode, isSse: bool) {.async.} =
  ## Handle message/send - process a task with optional SSE streaming
  let params = body{"params"}
  let taskId = params{"id"}.getStr("")
  let message = params{"message"}

  var task = Task(
    id: if taskId != "": taskId else: generateTaskId(),
    state: tsSubmitted,
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

  task.state = tsWorking
  server.store.update(task)

  if isSse:
    # SSE streaming response
    var headers = newHttpHeaders([
      ("Content-Type", "text/event-stream"),
      ("Cache-Control", "no-cache"),
      ("Connection", "keep-alive"),
    ])
    await req.respond(Http200, "", headers)

    # Send initial event
    let startEvent = %*{
      "taskId": task.id,
      "state": "working",
      "timestamp": $getTime(),
    }
    try:
      await req.client.send("data: " & $startEvent & "\n\n")
    except:
      return

    # Process task
    if server.handler != nil:
      var finalTask: Task
      var events: seq[TaskEvent]
      (finalTask, events) = server.handler(task)

      # Send events
      for event in events:
        let eventJson = %*{
          "taskId": event.taskId,
          "state": $event.state,
          "timestamp": $event.timestamp,
        }
        if event.artifact.name != "":
          eventJson["artifact"] = %*{
            "name": event.artifact.name,
            "description": event.artifact.description,
            "parts": event.artifact.parts.mapIt(%*{"type": it.kind, "text": it.text}),
          }
        try:
          await req.client.send("data: " & $eventJson & "\n\n")
        except:
          break

      finalTask.updatedAt = getTime()
      server.store.update(finalTask)

      # Send final event
      let finalEvent = %*{
        "taskId": finalTask.id,
        "state": $finalTask.state,
        "timestamp": $getTime(),
      }
      try:
        await req.client.send("data: " & $finalEvent & "\n\n")
      except:
        discard
    else:
      # No handler - complete immediately
      task.state = tsCompleted
      task.updatedAt = getTime()
      server.store.update(task)
      let completeEvent = %*{
        "taskId": task.id,
        "state": "completed",
        "timestamp": $getTime(),
      }
      try:
        await req.client.send("data: " & $completeEvent & "\n\n")
      except:
        discard
  else:
    # Non-streaming JSON response
    if server.handler != nil:
      var finalTask: Task
      var events: seq[TaskEvent]
      (finalTask, events) = server.handler(task)
      finalTask.updatedAt = getTime()
      server.store.update(finalTask)

      let response = %*{
        "jsonrpc": "2.0",
        "id": body{"id"},
        "result": {
          "id": finalTask.id,
          "state": $finalTask.state,
          "artifacts": finalTask.artifacts.mapIt(%*{
            "name": it.name,
            "description": it.description,
            "parts": it.parts.mapIt(%*{"type": it.kind, "text": it.text}),
          }),
        },
      }
      await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
    else:
      task.state = tsCompleted
      task.updatedAt = getTime()
      server.store.update(task)
      let response = %*{
        "jsonrpc": "2.0",
        "id": body{"id"},
        "result": {
          "id": task.id,
          "state": "completed",
          "artifacts": [],
        },
      }
      await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))

proc handleGetTask(server: A2AServer, req: Request, body: JsonNode) {.async.} =
  ## Handle task/get - get current state of a task
  let params = body{"params"}
  let taskId = params{"task_id"}.getStr("")

  if taskId == "":
    let error = %*{
      "jsonrpc": "2.0",
      "id": body{"id"},
      "error": {"code": -32602, "message": "task_id is required"},
    }
    await req.respond(Http400, $error, newHttpHeaders([("Content-Type", "application/json")]))
    return

  try:
    let task = server.store.get(taskId)
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
        "createdAt": $task.createdAt,
        "updatedAt": $task.updatedAt,
      },
    }
    await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
  except CatchableError as e:
    let error = %*{
      "jsonrpc": "2.0",
      "id": body{"id"},
      "error": {"code": -32000, "message": e.msg},
    }
    await req.respond(Http404, $error, newHttpHeaders([("Content-Type", "application/json")]))

proc handleCancelTask(server: A2AServer, req: Request, body: JsonNode) {.async.} =
  ## Handle task/cancel - cancel a running task
  let params = body{"params"}
  let taskId = params{"task_id"}.getStr("")

  if taskId == "":
    let error = %*{
      "jsonrpc": "2.0",
      "id": body{"id"},
      "error": {"code": -32602, "message": "task_id is required"},
    }
    await req.respond(Http400, $error, newHttpHeaders([("Content-Type", "application/json")]))
    return

  try:
    var task = server.store.get(taskId)
    if task.state != tsWorking and task.state != tsSubmitted:
      let error = %*{
        "jsonrpc": "2.0",
        "id": body{"id"},
        "error": {"code": -32000, "message": "Task cannot be canceled in state: " & $task.state},
      }
      await req.respond(Http400, $error, newHttpHeaders([("Content-Type", "application/json")]))
      return

    task.state = tsCanceled
    task.updatedAt = getTime()
    server.store.update(task)

    let response = %*{
      "jsonrpc": "2.0",
      "id": body{"id"},
      "result": {
        "id": task.id,
        "state": "canceled",
      },
    }
    await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
  except CatchableError as e:
    let error = %*{
      "jsonrpc": "2.0",
      "id": body{"id"},
      "error": {"code": -32000, "message": e.msg},
    }
    await req.respond(Http404, $error, newHttpHeaders([("Content-Type", "application/json")]))

proc handleSubscribeSSE(server: A2AServer, req: Request) {.async.} =
  ## Handle GET /a2a/events?task_id=xxx - SSE subscription for task events
  let taskId = req.url.query.split("=")[^1]  # Simple parsing
  if taskId == "":
    await req.respond(Http400, "task_id is required", newHttpHeaders([("Content-Type", "text/plain")]))
    return

  var headers = newHttpHeaders([
    ("Content-Type", "text/event-stream"),
    ("Cache-Control", "no-cache"),
    ("Connection", "keep-alive"),
  ])
  await req.respond(Http200, "", headers)

  let sub = server.store.subscribe(taskId)
  defer: server.store.unsubscribe(taskId, sub)

  # Send existing events
  for event in sub.events:
    let eventJson = %*{
      "taskId": event.taskId,
      "state": $event.state,
      "timestamp": $event.timestamp,
    }
    try:
      await req.client.send("data: " & $eventJson & "\n\n")
    except:
      return

  # Wait for new events
  var lastIdx = sub.events.len
  while server.store.tasks.hasKey(taskId):
    let task = server.store.tasks[taskId]
    if task.state in {tsCompleted, tsFailed, tsCanceled}:
      # Task is done, send final event and close
      if sub.events.len > lastIdx:
        for i in lastIdx ..< sub.events.len:
          let event = sub.events[i]
          let eventJson = %*{
            "taskId": event.taskId,
            "state": $event.state,
            "timestamp": $event.timestamp,
          }
          try:
            await req.client.send("data: " & $eventJson & "\n\n")
          except:
            return
      break

    # Check for new events
    if sub.events.len > lastIdx:
      for i in lastIdx ..< sub.events.len:
        let event = sub.events[i]
        let eventJson = %*{
          "taskId": event.taskId,
          "state": $event.state,
          "timestamp": $event.timestamp,
        }
        try:
          await req.client.send("data: " & $eventJson & "\n\n")
        except:
          return
      lastIdx = sub.events.len

    await sleepAsync(100)

proc handleRequest(server: A2AServer, req: Request) {.async.} =
  ## Route incoming requests
  let path = req.url.path

  case req.reqMethod
  of HttpGet:
    if path == "/.well-known/agent.json":
      await server.handleAgentCard(req)
    elif path == "/a2a/events":
      await server.handleSubscribeSSE(req)
    else:
      await req.respond(Http404, "Not Found")
  of HttpPost:
    if path == "/" or path == "/a2a":
      try:
        let body = parseJson(req.body)
        let methodName = body{"method"}.getStr("")
        let isSse = req.headers.hasKey("accept") and req.headers["accept"].contains("text/event-stream")

        case methodName
        of "message/send":
          await server.handleSendMessage(req, body, isSse)
        of "task/get":
          await server.handleGetTask(req, body)
        of "task/cancel":
          await server.handleCancelTask(req, body)
        else:
          let error = %*{
            "jsonrpc": "2.0",
            "id": body{"id"},
            "error": {"code": -32601, "message": "Method not found: " & methodName},
          }
          await req.respond(Http400, $error, newHttpHeaders([("Content-Type", "application/json")]))
      except CatchableError as e:
        let error = %*{
          "jsonrpc": "2.0",
          "error": {"code": -32603, "message": e.msg},
        }
        await req.respond(Http500, $error, newHttpHeaders([("Content-Type", "application/json")]))
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

  proc handler(req: Request): Future[void] {.gcsafe, async.} =
    {.gcsafe.}:
      await server.handleRequest(req)

  echo "A2A server v" & a2aProtocolVersion & " listening on port " & $port
  echo "  Agent: " & server.config.agentCard.name
  echo "  Streaming: " & $server.config.agentCard.capabilities.streaming
  echo ""
  echo "Endpoints:"
  echo "  GET  /.well-known/agent.json  - Agent Card"
  echo "  POST /a2a                     - JSON-RPC (message/send, task/get, task/cancel)"
  echo "  GET  /a2a/events?task_id=xxx  - SSE subscription for task events"

  await httpServer.serve(Port(port), handler)

## Client for calling other A2A servers
proc sendTask*(serverUrl: string, task: Task, sse: bool = false): Task =
  ## Send a task to an A2A server
  let client = newHttpClient()
  var headers = newHttpHeaders([("Content-Type", "application/json")])
  if sse:
    headers["Accept"] = "text/event-stream"

  let request = %*{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "message/send",
    "params": {
      "id": task.id,
      "message": {
        "role": task.message.role,
        "parts": task.message.parts.mapIt(%*{"type": it.kind, "text": it.text}),
      },
    },
  }

  try:
    let response = client.request(serverUrl, httpMethod = HttpPost, body = $request, headers = headers)

    if sse and response.status == "200 OK":
      # Parse SSE stream - simplified, read all body
      let respBody = response.body
      var resultTask = task
      
      for line in respBody.splitLines():
        if not line.startsWith("data: "):
          continue
        let data = line[6 .. ^1]
        try:
          let event = parseJson(data)
          let state = event{"state"}.getStr("")
          if state != "":
            try:
              resultTask.state = parseEnum[TaskState](state)
            except:
              discard
        except:
          discard

      return resultTask
    else:
      # Non-streaming response
      let respBody = response.body
      let respJson = parseJson(respBody)

      var resultTask = task
      if respJson.hasKey("result"):
        let r = respJson["result"]
        resultTask.state = parseEnum[TaskState](r{"state"}.getStr("submitted"))
        if r.hasKey("artifacts") and r["artifacts"].kind == JArray:
          for art in r["artifacts"]:
            var artifact = Artifact()
            artifact.name = art{"name"}.getStr("")
            artifact.description = art{"description"}.getStr("")
            if art.hasKey("parts") and art["parts"].kind == JArray:
              for part in art["parts"]:
                artifact.parts.add(MessagePart(kind: part{"type"}.getStr("text"), text: part{"text"}.getStr("")))
            resultTask.artifacts.add(artifact)

      return resultTask
  except CatchableError as e:
    var failed = task
    failed.state = tsFailed
    failed.error = TaskError(code: -1, message: e.msg)
    return failed

proc getTask*(serverUrl: string, taskId: string): Task =
  ## Get task state from an A2A server
  let client = newHttpClient()
  client.headers = newHttpHeaders([("Content-Type", "application/json")])

  let request = %*{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "task/get",
    "params": {
      "task_id": taskId,
    },
  }

  try:
    let response = client.postContent(serverUrl, $request)
    let respJson = parseJson(response)

    var task = Task(id: taskId)
    if respJson.hasKey("result"):
      let r = respJson["result"]
      task.state = parseEnum[TaskState](r{"state"}.getStr("submitted"))
      if r.hasKey("artifacts") and r["artifacts"].kind == JArray:
        for art in r["artifacts"]:
          var artifact = Artifact()
          artifact.name = art{"name"}.getStr("")
          artifact.description = art{"description"}.getStr("")
          if art.hasKey("parts") and art["parts"].kind == JArray:
            for part in art["parts"]:
              artifact.parts.add(MessagePart(kind: part{"type"}.getStr("text"), text: part{"text"}.getStr("")))
          task.artifacts.add(artifact)

    return task
  except CatchableError as e:
    var failed = Task(id: taskId)
    failed.state = tsFailed
    failed.error = TaskError(code: -1, message: e.msg)
    return failed

proc cancelTask*(serverUrl: string, taskId: string): Task =
  ## Cancel a task on an A2A server
  let client = newHttpClient()
  client.headers = newHttpHeaders([("Content-Type", "application/json")])

  let request = %*{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "task/cancel",
    "params": {
      "task_id": taskId,
    },
  }

  try:
    let response = client.postContent(serverUrl, $request)
    let respJson = parseJson(response)

    var task = Task(id: taskId)
    if respJson.hasKey("result"):
      let r = respJson["result"]
      task.state = parseEnum[TaskState](r{"state"}.getStr("canceled"))

    return task
  except CatchableError as e:
    var failed = Task(id: taskId)
    failed.state = tsFailed
    failed.error = TaskError(code: -1, message: e.msg)
    return failed
