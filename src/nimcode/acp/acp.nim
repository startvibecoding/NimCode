## ACP (Agent Client Protocol) for NimCode.
## Provides a stdin/stdout protocol for external tool integration.
## Supports sessions, resource reading, and prompt templates.

import std/[json, streams, strutils, os, tables, times]

const acpProtocolVersion* = 2

type
  ACPRequest* = object
    id*: int
    method*: string
    params*: JsonNode

  ACPResponse* = object
    id*: int
    result*: JsonNode
    error*: JsonNode

  ResourceContent* = object
    uri*: string
    mimeType*: string
    text*: string
    blob*: string  ## base64 encoded

  PromptTemplate* = object
    name*: string
    description*: string
    arguments*: seq[PromptArgument]

  PromptArgument* = object
    name*: string
    description*: string
    required*: bool

  SessionInfo* = object
    id*: string
    created*: string
    workDir*: string
    messageCount*: int

  ToolCallHandler* = proc(toolName: string, args: JsonNode): string {.closure.}
  ResourceReadHandler* = proc(uri: string): ResourceContent {.closure.}
  PromptGetHandler* = proc(name: string, args: JsonNode): JsonNode {.closure.}

  ACPServer* = ref object
    toolHandler*: ToolCallHandler
    resourceHandler*: ResourceReadHandler
    promptHandler*: PromptGetHandler
    inputStream*: Stream
    outputStream*: Stream
    sessions*: Table[string, SessionInfo]
    tools*: seq[JsonNode]
    resources*: seq[JsonNode]
    prompts*: seq[PromptTemplate]

proc newACPServer*(
  toolHandler: ToolCallHandler = nil,
  resourceHandler: ResourceReadHandler = nil,
  promptHandler: PromptGetHandler = nil
): ACPServer =
  result = ACPServer(
    toolHandler: toolHandler,
    resourceHandler: resourceHandler,
    promptHandler: promptHandler,
    inputStream: newFileStream(stdin),
    outputStream: newFileStream(stdout),
    sessions: initTable[string, SessionInfo](),
    tools: @[],
    resources: @[],
    prompts: @[],
  )

proc sendResponse(server: ACPServer, resp: ACPResponse) =
  let json = %*{
    "jsonrpc": "2.0",
    "id": resp.id,
  }
  if resp.error != nil:
    json["error"] = resp.error
  else:
    json["result"] = resp.result

  server.outputStream.writeLine($json)
  server.outputStream.flush()

proc registerTool*(server: ACPServer, name, description: string, parameters: JsonNode) =
  ## Register a tool that can be called via ACP
  server.tools.add(%*{
    "name": name,
    "description": description,
    "inputSchema": parameters,
  })

proc registerResource*(server: ACPServer, uri, name, mimeType: string) =
  ## Register a resource that can be read via ACP
  server.resources.add(%*{
    "uri": uri,
    "name": name,
    "mimeType": mimeType,
  })

proc registerPrompt*(server: ACPServer, name, description: string, args: seq[PromptArgument]) =
  ## Register a prompt template
  var argsJson = newJArray()
  for arg in args:
    argsJson.add(%*{
      "name": arg.name,
      "description": arg.description,
      "required": arg.required,
    })
  server.prompts.add(PromptTemplate(name: name, description: description, arguments: args))

proc handleInitialize(server: ACPServer, req: ACPRequest) =
  ## Handle initialize request
  server.sendResponse(ACPResponse(
    id: req.id,
    result: %*{
      "protocolVersion": acpProtocolVersion,
      "capabilities": {
        "tools": {"listChanged": false},
        "resources": {"subscribe": false, "listChanged": false},
        "prompts": {"listChanged": false},
      },
      "serverInfo": {"name": "nimcode", "version": "0.1.2"},
    },
  ))

proc handleToolsList(server: ACPServer, req: ACPRequest) =
  ## Handle tools/list request
  server.sendResponse(ACPResponse(
    id: req.id,
    result: %*{"tools": server.tools},
  ))

proc handleToolsCall(server: ACPServer, req: ACPRequest) =
  ## Handle tools/call request
  let toolName = req.params{"name"}.getStr("")
  let args = req.params{"arguments"}

  if toolName == "":
    server.sendResponse(ACPResponse(
      id: req.id,
      error: %*{"code": -32602, "message": "tool name is required"},
    ))
    return

  if server.toolHandler == nil:
    server.sendResponse(ACPResponse(
      id: req.id,
      error: %*{"code": -32601, "message": "No tool handler registered"},
    ))
    return

  try:
    let result = server.toolHandler(toolName, args)
    server.sendResponse(ACPResponse(
      id: req.id,
      result: %*{"content": [{"type": "text", "text": result}]},
    ))
  except CatchableError as e:
    server.sendResponse(ACPResponse(
      id: req.id,
      error: %*{"code": -32603, "message": e.msg},
    ))

proc handleResourcesList(server: ACPServer, req: ACPRequest) =
  ## Handle resources/list request
  server.sendResponse(ACPResponse(
    id: req.id,
    result: %*{"resources": server.resources},
  ))

proc handleResourcesRead(server: ACPServer, req: ACPRequest) =
  ## Handle resources/read request
  let uri = req.params{"uri"}.getStr("")

  if uri == "":
    server.sendResponse(ACPResponse(
      id: req.id,
      error: %*{"code": -32602, "message": "uri is required"},
    ))
    return

  if server.resourceHandler == nil:
    # Default: read file from filesystem
    if uri.startsWith("file://"):
      let path = uri[7 .. ^1]
      if fileExists(path):
        try:
          let content = readFile(path)
          let ext = path.splitFile.ext.toLower
          let mimeType = case ext
            of ".json": "application/json"
            of ".md": "text/markdown"
            of ".txt": "text/plain"
            of ".nim": "text/x-nim"
            of ".go": "text/x-go"
            of ".py": "text/x-python"
            of ".js": "text/javascript"
            of ".ts": "text/typescript"
            else: "text/plain"

          server.sendResponse(ACPResponse(
            id: req.id,
            result: %*{
              "contents": [{
                "uri": uri,
                "mimeType": mimeType,
                "text": content,
              }],
            },
          ))
        except CatchableError as e:
          server.sendResponse(ACPResponse(
            id: req.id,
            error: %*{"code": -32603, "message": "Error reading resource: " & e.msg},
          ))
      else:
        server.sendResponse(ACPResponse(
          id: req.id,
          error: %*{"code": -32602, "message": "Resource not found: " & uri},
        ))
    else:
      server.sendResponse(ACPResponse(
        id: req.id,
        error: %*{"code": -32602, "message": "Unsupported URI scheme: " & uri},
      ))
    return

  try:
    let content = server.resourceHandler(uri)
    server.sendResponse(ACPResponse(
      id: req.id,
      result: %*{
        "contents": [{
          "uri": content.uri,
          "mimeType": content.mimeType,
          "text": content.text,
          "blob": content.blob,
        }],
      },
    ))
  except CatchableError as e:
    server.sendResponse(ACPResponse(
      id: req.id,
      error: %*{"code": -32603, "message": e.msg},
    ))

proc handlePromptsList(server: ACPServer, req: ACPRequest) =
  ## Handle prompts/list request
  var promptsJson = newJArray()
  for p in server.prompts:
    var argsJson = newJArray()
    for arg in p.arguments:
      argsJson.add(%*{
        "name": arg.name,
        "description": arg.description,
        "required": arg.required,
      })
    promptsJson.add(%*{
      "name": p.name,
      "description": p.description,
      "arguments": argsJson,
    })

  server.sendResponse(ACPResponse(
    id: req.id,
    result: %*{"prompts": promptsJson},
  ))

proc handlePromptsGet(server: ACPServer, req: ACPRequest) =
  ## Handle prompts/get request
  let name = req.params{"name"}.getStr("")
  let args = req.params{"arguments"}

  if name == "":
    server.sendResponse(ACPResponse(
      id: req.id,
      error: %*{"code": -32602, "message": "prompt name is required"},
    ))
    return

  if server.promptHandler == nil:
    server.sendResponse(ACPResponse(
      id: req.id,
      error: %*{"code": -32601, "message": "No prompt handler registered"},
    ))
    return

  try:
    let result = server.promptHandler(name, args)
    server.sendResponse(ACPResponse(
      id: req.id,
      result: result,
    ))
  except CatchableError as e:
    server.sendResponse(ACPResponse(
      id: req.id,
      error: %*{"code": -32603, "message": e.msg},
    ))

proc handleSessionCreate(server: ACPServer, req: ACPRequest) =
  ## Handle session/create request
  let workDir = req.params{"workDir"}.getStr(getCurrentDir())
  let id = "session-" & $getTime().toUnix() & "-" & $(rand(9999))

  let session = SessionInfo(
    id: id,
    created: $getTime(),
    workDir: workDir,
    messageCount: 0,
  )
  server.sessions[id] = session

  server.sendResponse(ACPResponse(
    id: req.id,
    result: %*{
      "sessionId": id,
      "workDir": workDir,
    },
  ))

proc handleSessionClose(server: ACPServer, req: ACPRequest) =
  ## Handle session/close request
  let sessionId = req.params{"sessionId"}.getStr("")

  if sessionId == "":
    server.sendResponse(ACPResponse(
      id: req.id,
      error: %*{"code": -32602, "message": "sessionId is required"},
    ))
    return

  if server.sessions.hasKey(sessionId):
    server.sessions.del(sessionId)
    server.sendResponse(ACPResponse(
      id: req.id,
      result: %*{"closed": true},
    ))
  else:
    server.sendResponse(ACPResponse(
      id: req.id,
      error: %*{"code": -32000, "message": "Session not found: " & sessionId},
    ))

proc handleRequest(server: ACPServer, req: ACPRequest) =
  case req.method
  of "initialize":
    server.handleInitialize(req)
  of "tools/list":
    server.handleToolsList(req)
  of "tools/call":
    server.handleToolsCall(req)
  of "resources/list":
    server.handleResourcesList(req)
  of "resources/read":
    server.handleResourcesRead(req)
  of "prompts/list":
    server.handlePromptsList(req)
  of "prompts/get":
    server.handlePromptsGet(req)
  of "session/create":
    server.handleSessionCreate(req)
  of "session/close":
    server.handleSessionClose(req)
  else:
    server.sendResponse(ACPResponse(
      id: req.id,
      error: %*{"code": -32601, "message": "Method not found: " & req.method},
    ))

proc run*(server: ACPServer) =
  ## Run the ACP server, reading requests from stdin
  while true:
    try:
      let line = server.inputStream.readLine()
      if line.strip() == "":
        continue

      let j = parseJson(line)
      var req = ACPRequest(
        id: j{"id"}.getInt(0),
        method: j{"method"}.getStr(""),
        params: j{"params"},
      )

      server.handleRequest(req)
    except EOFError:
      break
    except JsonParsingError:
      continue
    except CatchableError:
      break
