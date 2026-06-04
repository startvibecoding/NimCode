## MCP (Model Context Protocol) client for NimCode.
## Supports stdio transport for local MCP servers.

import std/[json, os, osproc, streams, strutils, tables, times]

const mcpProtocolVersion* = "2024-11-05"

type
  MCPResponse* = object
    id*: JsonNode
    result*: JsonNode
    error*: JsonNode

  MCPToolInfo* = object
    name*: string
    description*: string
    inputSchema*: JsonNode

  MCPClient* = ref object
    name*: string
    process: Process
    stdinStream: Stream
    stdoutStream: Stream
    nextId: int
    closed*: bool

proc sendRequest(client: MCPClient, mcpMethod: string, params: JsonNode): int =
  ## Send a JSON-RPC request, return the request ID
  client.nextId += 1
  result = client.nextId
  
  var request = %*{
    "jsonrpc": "2.0",
    "id": result,
    "method": mcpMethod,
  }
  if params != nil:
    request["params"] = params
  
  let line = $request & "\n"
  client.stdinStream.write(line)
  client.stdinStream.flush()

proc readResponse(client: MCPClient, timeout: int = 15000): MCPResponse =
  ## Read a JSON-RPC response from stdout with timeout
  let startTime = getTime()
  while not client.closed:
    let elapsed = (getTime() - startTime).inMilliseconds
    if elapsed > timeout:
      raise newException(CatchableError, "MCP read timeout")
    
    # Check if data is available
    if client.stdoutStream.atEnd():
      sleep(10)
      continue
    
    try:
      let line = client.stdoutStream.readLine()
      if line.strip() == "":
        continue
      
      let j = parseJson(line)
      result.id = j{"id"}
      result.result = j{"result"}
      result.error = j{"error"}
      return
    except JsonParsingError:
      continue
    except:
      if client.closed:
        raise newException(CatchableError, "MCP client closed")
      sleep(10)
      continue
  
  raise newException(CatchableError, "MCP client closed")

proc call*(client: MCPClient, mcpMethod: string, params: JsonNode, timeout: int = 15000): JsonNode =
  ## Call an MCP method and wait for the response
  if client.closed:
    raise newException(CatchableError, "MCP client is closed")
  
  let id = client.sendRequest(mcpMethod, params)
  
  # Read responses until we get one matching our ID
  let startTime = getTime()
  while not client.closed:
    let elapsed = (getTime() - startTime).inMilliseconds
    if elapsed > timeout:
      raise newException(CatchableError, "MCP call timeout: " & mcpMethod)
    
    try:
      let resp = client.readResponse(timeout = min(timeout - int(elapsed), 1000))
      
      # Check if this response matches our request
      if resp.id != nil and resp.id.kind == JInt and resp.id.getInt() == id:
        if resp.error != nil:
          let errMsg = resp.error{"message"}.getStr("unknown error")
          let errCode = resp.error{"code"}.getInt(0)
          raise newException(CatchableError, "MCP error " & $errCode & ": " & errMsg)
        return resp.result
      
      # If it's a notification or different response, skip it
    except CatchableError as e:
      if "timeout" in e.msg.toLower:
        continue
      raise
  
  raise newException(CatchableError, "MCP client closed")

proc notify*(client: MCPClient, mcpMethod: string, params: JsonNode) =
  ## Send a JSON-RPC notification (no response expected)
  var request = %*{
    "jsonrpc": "2.0",
    "method": mcpMethod,
  }
  if params != nil:
    request["params"] = params
  let line = $request & "\n"
  client.stdinStream.write(line)
  client.stdinStream.flush()

proc listTools*(client: MCPClient): seq[MCPToolInfo] =
  ## List available tools from the MCP server
  result = @[]
  let res = client.call("tools/list", nil)
  if res == nil or not res.hasKey("tools"):
    return
  for toolNode in res["tools"]:
    var info = MCPToolInfo()
    info.name = toolNode{"name"}.getStr("")
    info.description = toolNode{"description"}.getStr("")
    info.inputSchema = toolNode{"input_schema"}
    if info.inputSchema == nil:
      info.inputSchema = toolNode{"inputSchema"}
    if info.inputSchema == nil:
      info.inputSchema = newJObject()
    result.add(info)

proc callTool*(client: MCPClient, toolName: string, args: JsonNode): string =
  ## Call an MCP tool and return the text result
  let params = %*{
    "name": toolName,
    "arguments": (if args != nil: args else: newJObject())
  }
  let res = client.call("tools/call", params, timeout = 60000)
  if res == nil:
    return ""
  
  # Extract text from content blocks
  var parts: seq[string] = @[]
  if res.hasKey("content") and res["content"].kind == JArray:
    for content in res["content"]:
      let contentType = content{"type"}.getStr("text")
      if contentType == "text":
        parts.add(content{"text"}.getStr(""))
  
  let isError = res{"isError"}.getBool(false)
  result = parts.join("\n")
  if isError and result == "":
    result = "MCP tool error"

proc newMCPClient*(name: string, command: string, args: seq[string] = @[], env: seq[tuple[name, value: string]] = @[]): MCPClient =
  ## Create a new MCP client using stdio transport
  if command == "":
    raise newException(CatchableError, "MCP server command is required")
  
  let process = startProcess(
    command,
    args = args,
    options = {poStdErrToStdOut, poUsePath, poParentStreams}
  )
  
  result = MCPClient(
    name: name,
    process: process,
    stdinStream: process.inputStream(),
    stdoutStream: process.outputStream(),
    nextId: 0,
    closed: false,
  )
  
  # Initialize MCP
  let initParams = %*{
    "protocolVersion": mcpProtocolVersion,
    "capabilities": {},
    "clientInfo": {
      "name": "nimcode",
      "version": "0.1.1"
    }
  }
  let initResult = result.call("initialize", initParams)
  
  # Send initialized notification
  result.notify("notifications/initialized", nil)

proc close*(client: MCPClient) =
  ## Close the MCP client and terminate the server process
  if client.closed:
    return
  client.closed = true
  try:
    client.process.terminate()
  except:
    discard
  try:
    client.process.close()
  except:
    discard

proc isConnected*(client: MCPClient): bool =
  ## Check if the MCP client is still connected
  not client.closed and client.process.running()
