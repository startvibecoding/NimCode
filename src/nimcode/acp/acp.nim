## ACP (Agent Client Protocol) for NimCode.
## Provides a stdin/stdout protocol for external tool integration.
## External processes can send tool calls and receive results.

import std/[json, streams, strutils, os]

const acpProtocolVersion* = 1

type
  ACPRequest* = object
    id*: int
    method*: string
    params*: JsonNode

  ACPResponse* = object
    id*: int
    result*: JsonNode
    error*: JsonNode

  ToolCallHandler* = proc(toolName: string, args: JsonNode): string {.closure.}

  ACPServer* = ref object
    handler*: ToolCallHandler
    inputStream*: Stream
    outputStream*: Stream

proc newACPServer*(handler: ToolCallHandler): ACPServer =
  result = ACPServer(
    handler: handler,
    inputStream: newFileStream(stdin),
    outputStream: newFileStream(stdout),
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

proc handleRequest(server: ACPServer, req: ACPRequest) =
  case req.method
  of "tools/call":
    let toolName = req.params{"name"}.getStr("")
    let args = req.params{"arguments"}
    
    if toolName == "":
      server.sendResponse(ACPResponse(
        id: req.id,
        error: %*{"code": -32602, "message": "tool name is required"},
      ))
      return
    
    try:
      let result = server.handler(toolName, args)
      server.sendResponse(ACPResponse(
        id: req.id,
        result: %*{"content": [{"type": "text", "text": result}]},
      ))
    except CatchableError as e:
      server.sendResponse(ACPResponse(
        id: req.id,
        error: %*{"code": -32603, "message": e.msg},
      ))
  
  of "tools/list":
    # Return empty list - external tools are registered by the caller
    server.sendResponse(ACPResponse(
      id: req.id,
      result: %*{"tools": []},
    ))
  
  of "initialize":
    server.sendResponse(ACPResponse(
      id: req.id,
      result: %*{
        "protocolVersion": acpProtocolVersion,
        "capabilities": {"tools": {"listChanged": false}},
        "serverInfo": {"name": "nimcode", "version": "0.1.1"},
      },
    ))
  
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
