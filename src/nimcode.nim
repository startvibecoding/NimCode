import std/[os, strutils, parseopt, options, json, tables, sequtils]
import nimcode/config/config
import nimcode/provider/types
import nimcode/provider/factory
import nimcode/tools/tools
import nimcode/session/session
import nimcode/agent/agent
import nimcode/contextfiles/contextfiles
import nimcode/skills/skills
import nimcode/memory/memory
import nimcode/tui/format
import nimcode/gateway/gateway
import nimcode/mcp/mcp as mcpModule
import nimcode/sandbox/sandbox as sandboxModule
import nimcode/cron/cron as cronModule

const VERSION = "0.1.1"

proc printHelp() =
  echo "NimCode - AI coding assistant v" & VERSION
  echo ""
  echo "Usage: nimcode [options] [message...]"
  echo ""
  echo "Options:"
  echo "  -p, --provider <name>   Provider name (as defined in settings.json)"
  echo "  -m, --model <id>        Model ID"
  echo "  -M, --mode <mode>       Mode (plan, agent, yolo)"
  echo "  -t, --thinking <level>  Thinking level (off, minimal, low, medium, high, xhigh)"
  echo "  -c, --continue          Continue most recent session"
  echo "  -r, --resume <id>       Resume session by ID or path"
  echo "  --session <file>        Use specific session file"
  echo "  -P, --print             Print response and exit (non-interactive)"
  echo "  --verbose               Verbose output"
  echo "  --debug                 Enable debug logging"
  echo "  -h, --help              Show this help"
  echo "  -v, --version           Show version"
  echo ""
  echo "Examples:"
  echo "  nimcode                        Start interactive mode"
  echo "  nimcode -m gpt-4o              Use specific model"
  echo "  nimcode -M yolo                YOLO mode (all tools auto-execute)"
  echo "  nimcode -p deepseek -m mimo-v2.5-pro  Use DeepSeek"
  echo "  nimcode -t high                Enable high thinking level"
  echo "  nimcode -P \"explain this\"      Print response and exit"
  echo "  nimcode -c                     Continue last session"
  echo "  nimcode -r <session-id>        Resume specific session"
  echo ""

proc printVersion() =
  echo "NimCode v" & VERSION

proc resolveProviderConfig*(settings: Settings, name: string): ProviderConfig =
  let opt = settings.getProviderConfig(name)
  if opt.isSome:
    return opt.get()
  let defaultOpt = settings.getProviderConfig(settings.defaultProvider)
  if defaultOpt.isSome:
    return defaultOpt.get()
  raise newException(CatchableError, "Provider not found: " & name)

## Stream callback for CLI — writes each token immediately with flush
proc cliStreamCallback(event: AgentEvent) =
  case event.kind
  of aekTextDelta:
    stdout.write(event.textDelta)
    stdout.flushFile()
  of aekThinkDelta:
    stderr.write(event.thinkDelta)
    stderr.flushFile()
  of aekToolCall:
    stdout.write("\n")
    stdout.write(formatToolCall(event.toolName, "{}"))
    stdout.flushFile()
  of aekToolResult:
    stdout.write(formatToolResult(event.resultToolName, event.resultText, event.resultIsError))
    stdout.flushFile()
  of aekError:
    stderr.writeLine(formatError(event.errorMsg))
    stderr.flushFile()
  of aekDone:
    stdout.write("\n")
    stdout.flushFile()

proc loadAndConnectMCP*(settings: Settings, registry: ToolRegistry, cwd: string): seq[MCPClient] =
  ## Load MCP config from global and project paths, connect servers, register tools
  result = @[]
  let paths = @[globalMCPPath(), cwd / projectMCPPath()]
  
  for path in paths:
    if not fileExists(path):
      continue
    let mcpConfig = loadMCPConfig(path)
    for srv in mcpConfig.servers:
      if srv.kind != "stdio" and srv.kind != "":
        continue  # Only stdio transport for now
      if srv.command == "":
        continue
      try:
        let envPairs = srv.env.mapIt((it.name, it.value))
        let client = newMCPClient(srv.name, srv.command, srv.args, envPairs)
        result.add(client)
        
        # Register MCP tools
        let tools = client.listTools()
        var registeredNames = initTable[string, bool]()
        for t in registry.tools:
          registeredNames[t.name] = true
        
        for toolInfo in tools:
          if toolInfo.name == "":
            continue
          let baseName = "mcp_" & srv.name & "_" & toolInfo.name
          var uniqueName = baseName
          var counter = 1
          while registeredNames.hasKey(uniqueName):
            uniqueName = baseName & "_" & $counter
            counter += 1
          
          registeredNames[uniqueName] = true
          let mcpTool = Tool(
            name: uniqueName,
            description: if toolInfo.description != "": toolInfo.description else: "MCP tool from " & srv.name,
            parameters: toolInfo.inputSchema,
            workDir: cwd,
          )
          # Store the MCP tool info for execution
          registry.mcpTools[uniqueName] = MCPTuple(client: client, toolName: toolInfo.name)
          registry.tools.add(mcpTool)
        
        if tools.len > 0:
          stderr.writeLine("MCP: Connected " & srv.name & " (" & $tools.len & " tools)")
      except CatchableError as e:
        stderr.writeLine("MCP: Failed to connect " & srv.name & ": " & e.msg)

proc closeMCP*(clients: seq[MCPClient]) =
  for client in clients:
    try:
      client.close()
    except:
      discard

proc run(args: seq[string], opts: var OptParser) =
  var providerName = ""
  var modelName = ""
  var mode = ""
  var thinkingLevel = ""
  var continueSession = false
  var resumeSession = ""
  var sessionFile = ""
  var printMode = false
  var gatewayMode = false
  var gatewayPort = "8080"
  var verbose = false
  var debug = false
  var messages: seq[string] = @[]
  
  # Parse options
  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "p", "provider":
        providerName = p.val
      of "m", "model":
        modelName = p.val
      of "M", "mode":
        mode = p.val
      of "t", "thinking":
        thinkingLevel = p.val
      of "c", "continue":
        continueSession = true
      of "r", "resume":
        resumeSession = p.val
      of "session":
        sessionFile = p.val
      of "P", "print":
        printMode = true
      of "verbose":
        verbose = true
      of "debug":
        debug = true
      of "gateway":
        gatewayMode = true
      of "port":
        gatewayPort = p.val
      of "h", "help":
        printHelp()
        return
      of "v", "version":
        printVersion()
        return
      else:
        echo "Unknown option: " & p.key
        return
    of cmdArgument:
      messages.add(p.key)
  
  # Load settings
  let settings = loadSettings()
  
  # Gateway mode
  if gatewayMode:
    var gwConfig = loadGatewayConfig()
    gwConfig.listen = ":" & gatewayPort
    gwConfig.provider = providerName
    gwConfig.model = modelName
    gwConfig.workDir = getCurrentDir()
    runGateway(gwConfig)
    return
  
  # Determine provider
  if providerName == "":
    providerName = settings.defaultProvider
  
  # Determine model
  if modelName == "":
    modelName = settings.defaultModel
  
  # Determine mode
  if mode == "":
    mode = settings.defaultMode
  if mode == "":
    mode = "agent"
  
  # Determine thinking level
  if thinkingLevel == "":
    thinkingLevel = settings.defaultThinkingLevel
  
  # Create provider using factory
  var provider: Provider
  try:
    provider = createProviderFromSettings(settings, providerName)
  except CatchableError as e:
    echo "Error: " & e.msg
    echo "Set the environment variable or configure in ~/.nimcode/settings.json"
    quit(1)
  
  let cwd = getCurrentDir()
  
  # Load context files
  let globalConfigDir = configDir()
  let cfResult = loadContextFiles(cwd, globalConfigDir)
  let contextStr = buildContextString(cfResult)
  let contextFilesInfo = buildContextFilesInfo(cfResult)
  
  # Load skills
  let skillsPath = if settings.skillsDir != "": settings.skillsDir else: globalConfigDir / "skills"
  let projectSkillsDir = cwd / ".skills"
  let skillsMgr = newManager(skillsPath, projectSkillsDir)
  skillsMgr.load()
  let skillsContext = skillsMgr.buildAllSkillsContext()
  
  # Load memory
  let memoryPath = globalConfigDir / "memory.md"
  let mem = newMemory(memoryPath)
  let memoryContext = mem.getContext()
  
  let extraContext = contextStr & skillsContext & memoryContext
  
  # Setup session
  let sessionPath = if settings.sessionDir != "": settings.sessionDir else: ""
  var sess: Session
  var sessionInfo = ""
  if continueSession:
    sess = continueRecent(cwd)
    sessionInfo = sess.getSessionInfo()
  elif resumeSession != "":
    sess = openByPathOrID(cwd, resumeSession)
    sessionInfo = sess.getSessionInfo()
  elif sessionFile != "":
    sess = openByPathOrID(cwd, sessionFile)
    sessionInfo = sess.getSessionInfo()
  else:
    sess = newSession(cwd)
  
  # Parse thinking level
  let parsedThinkingLevel = if thinkingLevel != "": parseThinkingLevel(thinkingLevel) else: tlOff
  
  # Create agent
  let agent = newAgent(
    provider, modelName, mode, cwd, sess,
    extraContext = extraContext,
    settings = settings,
    thinkingLevel = parsedThinkingLevel,
    sandboxEnabled = settings.sandbox.enabled,
    sandboxLevel = settings.sandbox.level
  )
  
  # Load and connect MCP servers
  let mcpClients = loadAndConnectMCP(settings, agent.registry, cwd)
  
  # Add web-search hosted tool if enabled
  if settings.webSearch.enabled:
    let providerType = if settings.webSearch.providerType != "": settings.webSearch.providerType else: "responses"
    agent.registry.tools.add(Tool(
      name: "web_search",
      description: "Search the web for information. Returns relevant search results.",
      parameters: %*{
        "type": "object",
        "properties": {
          "query": {"type": "string", "description": "Search query"}
        },
        "required": ["query"]
      },
      workDir: cwd,
    ))
    agent.registry.webSearchProviderType = providerType
  
  # Print mode: stream directly to stdout
  if printMode:
    let userMsg = messages.join(" ")
    if userMsg == "":
      echo "Error: Message required in print mode"
      quit(1)
    agent.processAgentTurnStream(userMsg, cliStreamCallback)
    closeMCP(mcpClients)
    return
  
  # Interactive mode
  echo "NimCode v" & VERSION
  echo formatMode(mode)
  echo "Provider: " & providerName
  echo "Model: " & modelName
  if thinkingLevel != "":
    echo "Thinking: " & thinkingLevel
  echo "Working directory: " & cwd
  echo ""
  
  if contextFilesInfo != "":
    echo formatContextFiles(contextFilesInfo)
  if sessionInfo != "":
    echo formatSession(sessionInfo)
  
  # Process initial message with streaming
  if messages.len > 0:
    let userMsg = messages.join(" ")
    agent.processAgentTurnStream(userMsg, cliStreamCallback)
  
  # Interactive loop
  while true:
    stdout.write(formatPrompt())
    stdout.flushFile()
    
    let input = stdin.readLine()
    if input.strip() == "":
      continue
    
    let cmd = input.strip
    if cmd == "exit" or cmd == "quit":
      break
    elif cmd == "clear":
      agent.clearMessages()
      echo "Conversation cleared"
      continue
    elif cmd == "help":
      echo "Commands:"
      echo "  clear    - Clear conversation history"
      echo "  exit     - Exit NimCode"
      echo "  help     - Show this help"
      echo "  mode     - Show current mode"
      echo "  provider - Show current provider"
      echo "  model    - Show current model"
      echo "  thinking - Show thinking level"
      echo "  session  - Show session info"
      echo "  sessions - List recent sessions"
      echo "  usage    - Show context usage"
      echo "  mcp      - Show MCP server status"
      echo "  sandbox  - Show sandbox status"
      echo "  cron     - List cron jobs"
      echo "  tools    - List available tools"
      continue
    elif cmd == "mode":
      echo "Mode: " & mode
      continue
    elif cmd == "provider":
      echo "Provider: " & providerName
      continue
    elif cmd == "model":
      echo "Model: " & modelName
      continue
    elif cmd == "thinking":
      echo "Thinking: " & thinkingLevel
      continue
    elif cmd == "session":
      echo sess.getSessionInfo()
      continue
    elif cmd == "sessions":
      let sessions = listSessionsForDir(cwd)
      if sessions.len == 0:
        echo "No sessions found"
      else:
        echo "Recent sessions:"
        for s in sessions:
          if sessions.find(s) >= 10: break
          echo "  " & s.id & "  " & s.name
      continue
    elif cmd == "usage":
      let usage = agent.getContextUsage()
      echo "Context: " & $usage.tokens & " tokens"
      if usage.contextWindow > 0:
        echo "Window: " & $usage.contextWindow & " tokens"
      if usage.percent.isSome:
        echo "Usage: " & formatFloat(usage.percent.get, ffDecimal, 1) & "%"
      continue
    elif cmd == "mcp":
      if mcpClients.len == 0:
        echo "No MCP servers connected"
      else:
        echo "MCP servers:"
        for client in mcpClients:
          let status = if client.isConnected(): "connected" else: "disconnected"
          echo "  " & client.name & " (" & status & ")"
      continue
    elif cmd == "sandbox":
      if agent.registry.sandbox == nil:
        echo "Sandbox: disabled"
      else:
        echo "Sandbox: enabled (level: " & $agent.registry.sandboxLevel & ")"
        echo "  bwrap: " & (if agent.registry.sandbox.isAvailable(): "available" else: "not available")
      continue
    elif cmd == "cron":
      echo agent.registry.cronStore.formatJobs()
      continue
    elif cmd == "tools":
      echo "Available tools:"
      for t in agent.registry.tools:
        echo "  " & t.name & " - " & t.description[0 ..< min(t.description.len, 60)]
      continue
    elif cmd.startsWith("mode "):
      let newMode = cmd[5 .. ^1].strip
      if newMode in ["plan", "agent", "yolo"]:
        mode = newMode
        echo "Mode changed to: " & mode
      else:
        echo "Invalid mode: " & newMode
      continue
    elif cmd.startsWith("/"):
      echo "Unknown command: " & cmd
      echo "Type 'help' for available commands"
      continue
    
    # Process with real-time streaming
    agent.processAgentTurnStream(input, cliStreamCallback)
  
  # Cleanup
  closeMCP(mcpClients)

when isMainModule:
  try:
    var p = initOptParser()
    run(@[], p)
  except CatchableError as e:
    stderr.writeLine("Error: " & e.msg)
    quit(1)
