import std/[os, strutils, parseopt, options, json, tables, sequtils, asyncdispatch, times, terminal, posix, termios]
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
import nimcode/gateway/gateway
import nimcode/mcp/mcp as mcpModule
import nimcode/sandbox/sandbox as sandboxModule
import nimcode/cron/cron as cronModule
import nimcode/a2a/a2a as a2aModule

# Global flag for interrupting agent
var gInterruptRequested* = false

# TUI state
var gTui: TuiState

# Terminal raw mode
var gOrigTermios: Termios
var gRawModeEnabled = false

proc enableRawMode() =
  if not stdin.isatty(): return
  if tcgetattr(0, addr gOrigTermios) == -1: return
  var raw = gOrigTermios
  raw.c_iflag = raw.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  raw.c_oflag = raw.c_oflag and not OPOST
  raw.c_cflag = raw.c_cflag or CS8
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or IEXTEN or ISIG)
  raw.c_cc[VMIN] = 1.char
  raw.c_cc[VTIME] = 0.char
  if tcsetattr(0, TCSAFLUSH, addr raw) == -1: return
  gRawModeEnabled = true

proc disableRawMode() =
  if gRawModeEnabled:
    discard tcsetattr(0, TCSAFLUSH, addr gOrigTermios)
    gRawModeEnabled = false

proc readUtf8Char(): string =
  ## Read one UTF-8 character (may be multi-byte)
  var buf: array[4, char]
  if read(0, addr buf[0], 1) != 1: return ""
  
  let b = buf[0].ord
  var len = 1
  if (b and 0xE0) == 0xC0: len = 2
  elif (b and 0xF0) == 0xE0: len = 3
  elif (b and 0xF8) == 0xF0: len = 4
  
  for i in 1 ..< len:
    if read(0, addr buf[i], 1) != 1: break
  
  result = newString(len)
  for i in 0 ..< len:
    result[i] = buf[i]

proc readLineWithTab*(): tuple[line: string, tabPressed: bool] =
  ## Read line with raw mode, intercept Tab for mode cycling
  enableRawMode()
  defer: disableRawMode()
  
  var buffer = ""
  while true:
    let ch = readUtf8Char()
    if ch.len == 0: continue
    
    # Single byte special keys
    if ch.len == 1:
      case ch[0]
      of '\t':  # Tab
        return ("", true)
      of '\n', '\r':  # Enter
        return (buffer, false)
      of '\x7f', '\b':  # Backspace
        if buffer.len > 0:
          # Find last UTF-8 character boundary
          var lastLen = 1
          var i = buffer.len - 1
          while i > 0 and (buffer[i].ord and 0xC0) == 0x80:
            dec i
            inc lastLen
          buffer.setLen(buffer.len - lastLen)
          # Erase from screen
          stdout.write("\b \b")
          stdout.flushFile()
      of '\x03':  # Ctrl+C
        quit(0)
      of '\x04':  # Ctrl+D
        if buffer.len == 0: quit(0)
      of '\x1b':  # ESC or escape sequence
        discard  # Ignore for now
      else:
        if ch[0] >= ' ':
          buffer.add(ch)
          stdout.write(ch)
          stdout.flushFile()
    else:
      # Multi-byte UTF-8 (Chinese, etc.)
      buffer.add(ch)
      stdout.write(ch)
      stdout.flushFile()

proc checkForKeyPress(): char =
  ## Non-blocking check for key press
  if not stdin.isatty():
    return '\0'
  try:
    # Check if there's input available
    if not stdin.endOfFile():
      return stdin.readChar()
  except:
    discard
  return '\0'

proc handleKeyboardInput() =
  ## Non-blocking keyboard input check for ESC and Tab
  let ch = checkForKeyPress()
  case ch
  of '\x1b':  # ESC key
    gInterruptRequested = true
    stderr.writeLine("\n" & yellow("Interrupted by user"))
  of '\t':  # Tab key
    # Toggle mode - will be handled in main loop
    discard
  else:
    discard

const VERSION = "0.1.2"

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

# Track assistant output state
var gAssistantStarted = false
var gThinkStarted = false
var gLastDuration: float = 0
var gStartTime: float = 0
var gIsStreaming = false

# Status bar helpers
proc getUsageInfo(agent: Agent): tuple[percent: float, window: int] =
  let usage = agent.getContextUsage()
  let percent = if usage.percent.isSome: usage.percent.get else: 0.0
  let window = if usage.contextWindow > 0: usage.contextWindow else: 128000
  return (percent, window)

proc buildStatusBarText(mode, modelName, cwd: string, usagePercent: float, contextWindow: int, lastDuration: float = 0, isStreaming: bool = false): string =
  var parts: seq[string] = @[]
  
  # Mode with emoji
  let modeStr = case mode
    of "plan": "📝 PLAN"
    of "agent": "🤖 AGENT"
    of "yolo": "🚀 YOLO"
    else: "⚙️ " & mode.toUpper
  if isStreaming:
    parts.add(modeStr & " ●")
  else:
    parts.add(modeStr)
  
  parts.add(modelName)
  
  let shortDir = if cwd.len > 25: "..." & cwd[^22..^1] else: cwd
  parts.add(shortDir)
  
  if contextWindow > 0:
    let percentStr = formatFloat(usagePercent, ffDecimal, 1) & "%"
    let windowStr = if contextWindow >= 1000:
      formatFloat(contextWindow.float / 1000.0, ffDecimal, 0) & "k"
    else:
      $contextWindow
    parts.add(percentStr & "/" & windowStr)
  
  if lastDuration > 0:
    parts.add("last " & formatFloat(lastDuration, ffDecimal, 0) & "s")
  
  parts.add("Tab:mode Esc:abort Ctrl+C:exit")
  
  return parts.join(" │ ")

proc updateStatusBar(agent: Agent, mode, modelName, cwd: string, lastDuration: float = 0, isStreaming: bool = false) =
  let (percent, window) = getUsageInfo(agent)
  let statusText = buildStatusBarText(mode, modelName, cwd, percent, window, lastDuration, isStreaming)
  gTui.setStatus(statusText)
  gTui.renderTui()

## Stream callback for CLI — writes each token immediately with flush
proc cliStreamCallback(event: AgentEvent) =
  case event.kind
  of aekTextDelta:
    if not gAssistantStarted:
      if gThinkStarted:
        gTui.addContentLine("")
        gThinkStarted = false
      gTui.addContentLine("Assistant: " & event.textDelta)
      gAssistantStarted = true
      if gStartTime == 0:
        gStartTime = epochTime()
    else:
      # Append to last content line
      if gTui.contentLines.len > 0:
        gTui.contentLines[^1].add(event.textDelta)
    gTui.renderTui()
  of aekThinkDelta:
    # Show thinking with think: prefix
    if not gThinkStarted:
      if gAssistantStarted:
        gTui.addContentLine("")
        gAssistantStarted = false
      gTui.addContentLine("think: " & event.thinkDelta)
      gThinkStarted = true
      if gStartTime == 0:
        gStartTime = epochTime()
    else:
      # Append to last content line
      if gTui.contentLines.len > 0:
        gTui.contentLines[^1].add(event.thinkDelta)
    gTui.renderTui()
  of aekToolCall:
    gAssistantStarted = false
    gThinkStarted = false
    gTui.addContentLine("")
    gTui.addContentLine(">> " & event.toolName & " " & $event.toolArgs)
    gTui.addContentLine("")
    gTui.renderTui()
  of aekToolResult:
    let preview = if event.resultText.len > 100: event.resultText[0 ..< 100] & "..." else: event.resultText
    if event.resultIsError:
      gTui.addContentLine("<< " & event.resultToolName & " error: " & preview)
    else:
      gTui.addContentLine("<< " & event.resultToolName & " " & preview)
    gTui.addContentLine("")
    gTui.renderTui()
  of aekError:
    gAssistantStarted = false
    gThinkStarted = false
    if gStartTime > 0:
      gLastDuration = epochTime() - gStartTime
      gStartTime = 0
    gTui.addContentLine("Error: " & event.errorMsg)
    gTui.addContentLine("")
    gTui.renderTui()
  of aekDone:
    gAssistantStarted = false
    gThinkStarted = false
    if gStartTime > 0:
      gLastDuration = epochTime() - gStartTime
      gStartTime = 0
    gTui.addContentLine("")
    gTui.renderTui()

## Check for keyboard input (non-blocking)
proc checkKeyboard() =
  ## Check for ESC key to interrupt
  let ch = checkForKeyPress()
  if ch == '\x1b':  # ESC key
    gInterruptRequested = true
    stderr.writeLine("\n" & yellow("[Interrupted by user]"))
    stderr.flushFile()

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
  var a2aMode = false
  var a2aPort = "8181"
  var cronMode = false
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
    # Keep running
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
  
  # Set interrupt check callback
  agent.interruptCheck = proc(): bool =
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
  
  # Print mode: stream directly to stdout
  if printMode:
    let userMsg = messages.join(" ")
    if userMsg == "":
      echo "Error: Message required in print mode"
      quit(1)
    agent.processAgentTurnStream(userMsg, cliStreamCallback)
    closeMCP(mcpClients)
    return
  
  # Interactive mode - initialize TUI
  gTui = newTuiState()
  
  # Add initial content
  gTui.addContentLine("NimCode v" & VERSION)
  gTui.addContentLine(formatMode(mode))
  gTui.addContentLine("Provider: " & providerName)
  gTui.addContentLine("Model: " & modelName)
  if thinkingLevel != "":
    gTui.addContentLine("Thinking: " & thinkingLevel)
  gTui.addContentLine("Working directory: " & cwd)
  gTui.addContentLine("")
  
  if contextFilesInfo != "":
    gTui.addContentLine(contextFilesInfo)
  if sessionInfo != "":
    gTui.addContentLine(sessionInfo)
  
  # Initialize status bar
  updateStatusBar(agent, mode, modelName, cwd, 0, false)
  gTui.renderTui()
  
  # Process initial message with streaming
  if messages.len > 0:
    let userMsg = messages.join(" ")
    gInterruptRequested = false
    gStartTime = epochTime()
    gIsStreaming = true
    updateStatusBar(agent, mode, modelName, cwd, 0, true)
    agent.processAgentTurnStream(userMsg, cliStreamCallback)
    gIsStreaming = false
    gLastDuration = epochTime() - gStartTime
    updateStatusBar(agent, mode, modelName, cwd, gLastDuration, false)
  
  # Interactive loop
  while true:
    # Reset interrupt flag
    gInterruptRequested = false
    
    # Update status bar
    updateStatusBar(agent, mode, modelName, cwd, gLastDuration, false)
    
    # Read input with Tab handling
    let (input, tabPressed) = readLineWithTab()
    
    # Handle Tab for mode cycling
    if tabPressed:
      case mode
      of "plan": mode = "agent"
      of "agent": mode = "yolo"
      of "yolo": mode = "plan"
      else: mode = "agent"
      gTui.addContentLine("Mode: " & mode)
      updateStatusBar(agent, mode, modelName, cwd, gLastDuration, false)
      gTui.renderTui()
      continue
    
    if input.strip() == "":
      continue
    
    # Add user input to content
    gTui.addContentLine("> " & input)
    gTui.clearInput()
    gTui.renderTui()
    
    let cmd = input.strip
    if cmd == "exit" or cmd == "quit":
      break
    elif cmd == "clear":
      agent.clearMessages()
      gTui.clearContent()
      gTui.addContentLine("Conversation cleared")
      gTui.renderTui()
      continue
    elif cmd == "help":
      gTui.addContentLine("Commands:")
      gTui.addContentLine("  clear    - Clear conversation history")
      gTui.addContentLine("  exit     - Exit NimCode")
      gTui.addContentLine("  help     - Show this help")
      gTui.addContentLine("  mode     - Show current mode")
      gTui.addContentLine("  mode <m> - Set mode (plan, agent, yolo)")
      gTui.addContentLine("  provider - Show current provider")
      gTui.addContentLine("  model    - Show current model")
      gTui.addContentLine("  thinking - Show thinking level")
      gTui.addContentLine("  session  - Show session info")
      gTui.addContentLine("  sessions - List recent sessions")
      gTui.addContentLine("  usage    - Show context usage")
      gTui.addContentLine("  mcp      - Show MCP server status")
      gTui.addContentLine("  sandbox  - Show sandbox status")
      gTui.addContentLine("  cron     - List cron jobs")
      gTui.addContentLine("  tools    - List available tools")
      gTui.addContentLine("")
      gTui.addContentLine("Keyboard shortcuts:")
      gTui.addContentLine("  ESC      - Interrupt running agent")
      gTui.addContentLine("  Ctrl+C   - Exit NimCode")
      gTui.renderTui()
      continue
    elif cmd == "mode":
      gTui.addContentLine("Mode: " & mode)
      gTui.addContentLine("Use 'mode <name>' to change (plan, agent, yolo)")
      gTui.renderTui()
      continue
    elif cmd == "mode plan" or cmd == "mode agent" or cmd == "mode yolo":
      mode = cmd.split(" ")[1]
      gTui.addContentLine("Mode changed to: " & mode)
      updateStatusBar(agent, mode, modelName, cwd, gLastDuration, false)
      gTui.renderTui()
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
      gTui.addContentLine("Context: " & $usage.tokens & " tokens")
      if usage.contextWindow > 0:
        gTui.addContentLine("Window: " & $usage.contextWindow & " tokens")
      if usage.percent.isSome:
        gTui.addContentLine("Usage: " & formatFloat(usage.percent.get, ffDecimal, 1) & "%")
      gTui.renderTui()
      continue
    elif cmd == "mcp":
      if mcpClients.len == 0:
        gTui.addContentLine("No MCP servers connected")
      else:
        gTui.addContentLine("MCP servers:")
        for client in mcpClients:
          let status = if client.isConnected(): "connected" else: "disconnected"
          gTui.addContentLine("  " & client.name & " (" & status & ")")
      gTui.renderTui()
      continue
    elif cmd == "sandbox":
      if agent.registry.sandbox == nil:
        gTui.addContentLine("Sandbox: disabled")
      else:
        gTui.addContentLine("Sandbox: enabled (level: " & $agent.registry.sandboxLevel & ")")
        gTui.addContentLine("  bwrap: " & (if agent.registry.sandbox.isAvailable(): "available" else: "not available"))
      gTui.renderTui()
      continue
    elif cmd == "cron":
      gTui.addContentLine(agent.registry.cronStore.formatJobs())
      gTui.renderTui()
      continue
    elif cmd == "tools":
      gTui.addContentLine("Available tools:")
      for t in agent.registry.tools:
        gTui.addContentLine("  " & t.name & " - " & t.description[0 ..< min(t.description.len, 60)])
      gTui.renderTui()
      continue
    elif cmd.startsWith("mode "):
      let newMode = cmd[5 .. ^1].strip
      if newMode in ["plan", "agent", "yolo"]:
        mode = newMode
        gTui.addContentLine("Mode changed to: " & mode)
        updateStatusBar(agent, mode, modelName, cwd, gLastDuration, false)
      else:
        gTui.addContentLine("Invalid mode: " & newMode)
      gTui.renderTui()
      continue
    elif cmd.startsWith("/"):
      # Slash commands
      let parts = cmd.split(" ")
      let slashCmd = parts[0]
      case slashCmd
      of "/clear":
        agent.clearMessages()
        gTui.addContentLine "Conversation cleared"
      of "/mode":
        if parts.len > 1:
          let newMode = parts[1].strip
          if newMode in ["plan", "agent", "yolo"]:
            mode = newMode
            gTui.addContentLine "Mode changed to: " & mode
          else:
            gTui.addContentLine "Invalid mode: " & newMode
        else:
          gTui.addContentLine "Current mode: " & mode
      of "/compact":
        let summary = agent.compactContext()
        if summary != "":
          gTui.addContentLine "Context compacted (" & $summary.len & " chars summary)"
        else:
          gTui.addContentLine "No compaction needed"
      of "/model":
        if parts.len > 1:
          modelName = parts[1].strip
          gTui.addContentLine "Model changed to: " & modelName
        else:
          gTui.addContentLine "Current model: " & modelName
      of "/provider":
        if parts.len > 1:
          providerName = parts[1].strip
          gTui.addContentLine "Provider changed to: " & providerName
        else:
          gTui.addContentLine "Current provider: " & providerName
      of "/thinking":
        if parts.len > 1:
          thinkingLevel = parts[1].strip
          gTui.addContentLine "Thinking level changed to: " & thinkingLevel
        else:
          gTui.addContentLine "Current thinking level: " & thinkingLevel
      of "/help":
        gTui.addContentLine "Slash commands:"
        gTui.addContentLine "  /clear       - Clear conversation history"
        gTui.addContentLine "  /mode [mode] - Show or change mode (plan, agent, yolo)"
        gTui.addContentLine "  /cycle       - Cycle through modes (plan -> agent -> yolo -> plan)"
        gTui.addContentLine "  /compact     - Compact context (summarize old messages)"
        gTui.addContentLine "  /model [id]  - Show or change model"
        gTui.addContentLine "  /provider [name] - Show or change provider"
        gTui.addContentLine "  /thinking [level] - Show or change thinking level"
        gTui.addContentLine "  /help        - Show this help"
      of "/cycle":
        case mode
        of "plan":
          mode = "agent"
        of "agent":
          mode = "yolo"
        of "yolo":
          mode = "plan"
        else:
          mode = "agent"
        gTui.addContentLine "Mode changed to: " & mode
      else:
        gTui.addContentLine "Unknown command: " & slashCmd
        gTui.addContentLine "Type '/help' for available slash commands"
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
