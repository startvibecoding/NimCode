## NimCode - AI coding assistant
## Main entry point

import std/[os, strutils, parseopt, options, json, tables, sequtils, asyncdispatch, times, posix, termios]
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
import nimcode/tui/tui
import nimcode/tui/input
import nimcode/tui/statusbar
import nimcode/cli/stream
import nimcode/gateway/gateway
import nimcode/mcp/mcp as mcpModule
import nimcode/sandbox/sandbox as sandboxModule
import nimcode/cron/cron as cronModule
import nimcode/a2a/a2a as a2aModule

const VERSION = "0.1.2"

# Global state
var gInterruptRequested* = false

proc checkEscKey(): bool =
  ## Non-blocking check for ESC key press on stdin
  ## Returns true if standalone ESC was pressed (not part of escape sequence)
  var pfd: TPollfd
  pfd.fd = 0
  pfd.events = POLLIN
  if poll(addr pfd, 1, 0) > 0 and (pfd.revents and POLLIN) != 0:
    var buf: array[1, char]
    if read(0, addr buf[0], 1) == 1:
      if buf[0] == '\x1b':
        # Wait briefly to distinguish standalone ESC from escape sequence
        var pfd2: TPollfd
        pfd2.fd = 0
        pfd2.events = POLLIN
        if poll(addr pfd2, 1, 50) > 0 and (pfd2.revents and POLLIN) != 0:
          # More chars follow = escape sequence (arrow key, etc.), not ESC
          discard tcflush(0, TCIFLUSH)
          return false
        return true
      # Not ESC, flush any pending input
      discard tcflush(0, TCIFLUSH)
  return false

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
  echo "  --gateway               Start HTTP gateway mode"
  echo "  --port <port>           Gateway port (default: 8080)"
  echo "  --a2a                   Start A2A (Agent-to-Agent) server"
  echo "  --a2a-port <port>       A2A server port (default: 8181)"
  echo "  --cron                  Start cron daemon mode"
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
        continue
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
    except CatchableError as e:
      stderr.writeLine("Warning: MCP close failed: " & e.msg)

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
  var a2aMode = false
  var a2aPort = "8181"
  var cronMode = false
  var verbose = false
  var debug = false
  var messages: seq[string] = @[]
  
  # Parse options
  var p = opts
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
      of "a2a":
        a2aMode = true
      of "a2a-port":
        a2aPort = p.val
      of "cron":
        cronMode = true
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
  
  # A2A server mode
  if a2aMode:
    let card = defaultAgentCard(VERSION, "http://localhost:" & a2aPort)
    let config = A2AServerConfig(
      listen: ":" & a2aPort,
      agentCard: card,
    )
    proc taskStreamHandler(task: Task): (Task, seq[TaskEvent]) =
      var t = task
      t.state = tsCompleted
      t.artifacts.add(Artifact(
        name: "response",
        description: "Agent response",
        parts: @[MessagePart(kind: "text", text: "Task received: " & t.message.parts.mapIt(it.text).join(" "))]
      ))
      var events = @[TaskEvent(taskId: t.id, state: tsCompleted, timestamp: getTime())]
      return (t, events)
    let server = newA2AServer(config, taskStreamHandler)
    echo "Starting A2A server..."
    waitFor server.start()
    return
  
  # Cron daemon mode
  if cronMode:
    let cronPath = configDir() / "cron.json"
    let store = newCronStore(cronPath)
    let binPath = getCurrentDir() / "bin" / "nimcode"
    let scheduler = newCronScheduler(store, nimcodeBin = binPath)
    scheduler.start()
    echo "Cron daemon started. Press Ctrl+C to stop."
    while true:
      sleep(1000)
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
  
  # Set interrupt check callback (agent-level and provider-level)
  agent.interruptCheck = proc(): bool =
    return gInterruptRequested

  provider.interruptCheck = proc(): bool =
    if checkEscKey():
      gInterruptRequested = true
    return gInterruptRequested

  # Reset interrupt flag
  gInterruptRequested = false
  
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
  
  # Print mode: stream directly to stdout (no TUI)
  if printMode:
    let userMsg = messages.join(" ")
    if userMsg == "":
      echo "Error: Message required in print mode"
      quit(1)
    
    let callbackState = newStreamCallbackState(scmPrint)
    proc printCallback(event: AgentEvent) =
      callbackState.printStreamCallback(event)
    
    agent.processAgentTurnStream(userMsg, printCallback)
    closeMCP(mcpClients)
    return
  
  # Interactive mode - initialize TUI
  let tui = newTuiState()
  let statusBar = newStatusBarState(tui)
  statusBar.agent = agent
  statusBar.mode = mode
  statusBar.modelName = modelName
  statusBar.cwd = cwd
  
  # Add initial content
  tui.addContentLine("NimCode v" & VERSION)
  tui.addContentLine(formatMode(mode))
  tui.addContentLine("Provider: " & providerName)
  tui.addContentLine("Model: " & modelName)
  if thinkingLevel != "":
    tui.addContentLine("Thinking: " & thinkingLevel)
  tui.addContentLine("Working directory: " & cwd)
  tui.addContentLine("")
  
  if contextFilesInfo != "":
    tui.addContentLine(contextFilesInfo)
  if sessionInfo != "":
    tui.addContentLine(sessionInfo)
  
  # Initialize status bar
  statusBar.updateStatusBar()
  
  # Create TUI stream callback
  let callbackState = newStreamCallbackState(scmTui, tui, statusBar)
  proc tuiCallback(event: AgentEvent) =
    callbackState.tuiStreamCallback(event)
  
  # Process initial message with streaming
  if messages.len > 0:
    let userMsg = messages.join(" ")
    gInterruptRequested = false
    statusBar.startTimer()
    enableRawMode()
    agent.processAgentTurnStream(userMsg, tuiCallback)
    disableRawMode()
    statusBar.stopTimer()
    statusBar.updateStatusBar()
  
  # Interactive loop
  while true:
    # Reset interrupt flag
    gInterruptRequested = false
    
    # Update status bar
    statusBar.updateStatusBar()
    
    # Read input with Tab handling
    let (input, tabPressed) = readLineWithTab()
    
    # Handle Tab for mode cycling
    if tabPressed:
      case mode
      of "plan": mode = "agent"
      of "agent": mode = "yolo"
      of "yolo": mode = "plan"
      else: mode = "agent"
      agent.mode = mode
      statusBar.mode = mode
      tui.addContentLine("Mode: " & mode)
      statusBar.updateStatusBar()
      continue

    if input.strip() == "":
      continue
    
    # Add user input to content
    tui.addContentLine("> " & input)
    tui.clearInput()
    tui.renderTui()
    
    let cmd = input.strip
    if cmd == "exit" or cmd == "quit":
      break
    elif cmd == "clear":
      agent.clearMessages()
      tui.clearContent()
      tui.addContentLine("Conversation cleared")
      tui.renderTui()
      continue
    elif cmd == "help":
      tui.addContentLine("Commands:")
      tui.addContentLine("  clear    - Clear conversation history")
      tui.addContentLine("  exit     - Exit NimCode")
      tui.addContentLine("  help     - Show this help")
      tui.addContentLine("  mode     - Show current mode")
      tui.addContentLine("  mode <m> - Set mode (plan, agent, yolo)")
      tui.addContentLine("  provider - Show current provider")
      tui.addContentLine("  model    - Show current model")
      tui.addContentLine("  thinking - Show thinking level")
      tui.addContentLine("  session  - Show session info")
      tui.addContentLine("  sessions - List recent sessions")
      tui.addContentLine("  usage    - Show context usage")
      tui.addContentLine("  mcp      - Show MCP server status")
      tui.addContentLine("  sandbox  - Show sandbox status")
      tui.addContentLine("  cron     - List cron jobs")
      tui.addContentLine("  tools    - List available tools")
      tui.addContentLine("")
      tui.addContentLine("Keyboard shortcuts:")
      tui.addContentLine("  Tab      - Cycle through modes")
      tui.addContentLine("  ESC      - Interrupt running agent")
      tui.addContentLine("  Ctrl+C   - Exit NimCode")
      tui.renderTui()
      continue
    elif cmd == "mode":
      tui.addContentLine("Mode: " & mode)
      tui.addContentLine("Use 'mode <name>' to change (plan, agent, yolo)")
      tui.renderTui()
      continue
    elif cmd == "mode plan" or cmd == "mode agent" or cmd == "mode yolo":
      mode = cmd.split(" ")[1]
      agent.mode = mode
      statusBar.mode = mode
      tui.addContentLine("Mode changed to: " & mode)
      statusBar.updateStatusBar()
      continue
    elif cmd == "provider":
      tui.addContentLine("Provider: " & providerName)
      tui.renderTui()
      continue
    elif cmd == "model":
      tui.addContentLine("Model: " & modelName)
      tui.renderTui()
      continue
    elif cmd == "thinking":
      tui.addContentLine("Thinking: " & thinkingLevel)
      tui.renderTui()
      continue
    elif cmd == "session":
      tui.addContentLine(sess.getSessionInfo())
      tui.renderTui()
      continue
    elif cmd == "sessions":
      let sessions = listSessionsForDir(cwd)
      if sessions.len == 0:
        tui.addContentLine("No sessions found")
      else:
        tui.addContentLine("Recent sessions:")
        for s in sessions:
          if sessions.find(s) >= 10: break
          tui.addContentLine("  " & s.id & "  " & s.name)
      tui.renderTui()
      continue
    elif cmd == "usage":
      let usage = agent.getContextUsage()
      tui.addContentLine("Context: " & $usage.tokens & " tokens")
      if usage.contextWindow > 0:
        tui.addContentLine("Window: " & $usage.contextWindow & " tokens")
      if usage.percent.isSome:
        tui.addContentLine("Usage: " & formatFloat(usage.percent.get, ffDecimal, 1) & "%")
      tui.renderTui()
      continue
    elif cmd == "mcp":
      if mcpClients.len == 0:
        tui.addContentLine("No MCP servers connected")
      else:
        tui.addContentLine("MCP servers:")
        for client in mcpClients:
          let status = if client.isConnected(): "connected" else: "disconnected"
          tui.addContentLine("  " & client.name & " (" & status & ")")
      tui.renderTui()
      continue
    elif cmd == "sandbox":
      if agent.registry.sandbox == nil:
        tui.addContentLine("Sandbox: disabled")
      else:
        tui.addContentLine("Sandbox: enabled (level: " & $agent.registry.sandboxLevel & ")")
        tui.addContentLine("  bwrap: " & (if agent.registry.sandbox.isAvailable(): "available" else: "not available"))
      tui.renderTui()
      continue
    elif cmd == "cron":
      tui.addContentLine(agent.registry.cronStore.formatJobs())
      tui.renderTui()
      continue
    elif cmd == "tools":
      tui.addContentLine("Available tools:")
      for t in agent.registry.tools:
        tui.addContentLine("  " & t.name & " - " & t.description[0 ..< min(t.description.len, 60)])
      tui.renderTui()
      continue
    elif cmd.startsWith("mode "):
      let newMode = cmd[5 .. ^1].strip
      if newMode in ["plan", "agent", "yolo"]:
        mode = newMode
        agent.mode = mode
        statusBar.mode = mode
        tui.addContentLine("Mode changed to: " & mode)
        statusBar.updateStatusBar()
      else:
        tui.addContentLine("Invalid mode: " & newMode)
      tui.renderTui()
      continue
    elif cmd.startsWith("/"):
      # Slash commands
      let parts = cmd.split(" ")
      let slashCmd = parts[0]
      case slashCmd
      of "/clear":
        agent.clearMessages()
        tui.clearContent()
        tui.addContentLine("Conversation cleared")
        tui.renderTui()
      of "/mode":
        if parts.len > 1:
          let newMode = parts[1].strip
          if newMode in ["plan", "agent", "yolo"]:
            mode = newMode
            agent.mode = mode
            statusBar.mode = mode
            tui.addContentLine("Mode changed to: " & mode)
            statusBar.updateStatusBar()
          else:
            tui.addContentLine("Invalid mode: " & newMode)
        else:
          tui.addContentLine("Current mode: " & mode)
        tui.renderTui()
      of "/compact":
        let summary = agent.compactContext()
        if summary != "":
          tui.addContentLine("Context compacted (" & $summary.len & " chars summary)")
        else:
          tui.addContentLine("No compaction needed")
        tui.renderTui()
      of "/model":
        if parts.len > 1:
          modelName = parts[1].strip
          statusBar.modelName = modelName
          tui.addContentLine("Model changed to: " & modelName)
          statusBar.updateStatusBar()
        else:
          tui.addContentLine("Current model: " & modelName)
        tui.renderTui()
      of "/provider":
        if parts.len > 1:
          providerName = parts[1].strip
          tui.addContentLine("Provider changed to: " & providerName)
          statusBar.updateStatusBar()
        else:
          tui.addContentLine("Current provider: " & providerName)
        tui.renderTui()
      of "/thinking":
        if parts.len > 1:
          thinkingLevel = parts[1].strip
          tui.addContentLine("Thinking level changed to: " & thinkingLevel)
        else:
          tui.addContentLine("Current thinking level: " & thinkingLevel)
        tui.renderTui()
      of "/help":
        tui.addContentLine("Slash commands:")
        tui.addContentLine("  /clear       - Clear conversation history")
        tui.addContentLine("  /mode [mode] - Show or change mode (plan, agent, yolo)")
        tui.addContentLine("  /cycle       - Cycle through modes (plan -> agent -> yolo -> plan)")
        tui.addContentLine("  /compact     - Compact context (summarize old messages)")
        tui.addContentLine("  /model [id]  - Show or change model")
        tui.addContentLine("  /provider [name] - Show or change provider")
        tui.addContentLine("  /thinking [level] - Show or change thinking level")
        tui.addContentLine("  /help        - Show this help")
        tui.renderTui()
      of "/cycle":
        case mode
        of "plan": mode = "agent"
        of "agent": mode = "yolo"
        of "yolo": mode = "plan"
        else: mode = "agent"
        agent.mode = mode
        statusBar.mode = mode
        tui.addContentLine("Mode changed to: " & mode)
        statusBar.updateStatusBar()
        tui.renderTui()
      else:
        tui.addContentLine("Unknown command: " & slashCmd)
        tui.addContentLine("Type '/help' for available slash commands")
        tui.renderTui()
      continue
    
    # Process with real-time streaming
    statusBar.startTimer()
    enableRawMode()
    agent.processAgentTurnStream(input, tuiCallback)
    disableRawMode()
    statusBar.stopTimer()
    statusBar.updateStatusBar()
  
  # Cleanup
  disableRawMode()
  closeMCP(mcpClients)

when isMainModule:
  try:
    var p = initOptParser()
    run(@[], p)
  except CatchableError as e:
    disableRawMode()
    stderr.writeLine("Error: " & e.msg)
    quit(1)
