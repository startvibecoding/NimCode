## NimCode - AI coding assistant
## Main entry point

import std/[os, strutils, parseopt, options, json, tables, sequtils, asyncdispatch, times]
when defined(posix):
  import std/[posix, termios]
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
import nimcode/tui/commands
import nimcode/cli/stream
import nimcode/gateway/gateway
import nimcode/mcp/mcp as mcpModule
import nimcode/cron/cron as cronModule
import nimcode/a2a/a2a as a2aModule

const VERSION = "0.1.2"

# Global state
var gInterruptRequested* = false

when defined(posix):
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
else:
  proc checkEscKey(): bool =
    ## ESC-key detection is POSIX-only; on other platforms users can use Ctrl+C.
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

  # Set approval callback for TUI interactive mode (not in print mode)
  if not printMode:
    agent.approvalRequest = proc(toolName: string, args: JsonNode): tuple[approved: ApprovalResult, modifiedArgs: JsonNode] =
      disableRawMode()
      echo ""
      echo "╭─────────────────────────────────────────── Approval Required ───────────────────────────────────────────╮"
      echo "│ Tool: " & toolName
      if toolName == "bash":
        echo "│ Command: " & args{"command"}.getStr("")
      elif toolName == "write":
        echo "│ File: " & args{"path"}.getStr("")
      elif toolName == "edit":
        echo "│ File: " & args{"path"}.getStr("")
      elif toolName == "spawn":
        echo "│ Prompt: " & args{"prompt"}.getStr("")[0 ..< min(args{"prompt"}.getStr("").len, 80)]
      elif toolName == "cron":
        echo "│ Action: " & args{"action"}.getStr("")
      elif toolName == "a2a_dispatch":
        echo "│ Server: " & args{"serverUrl"}.getStr("")
        echo "│ Message: " & args{"message"}.getStr("")[0 ..< min(args{"message"}.getStr("").len, 80)]
      elif toolName == "memory_write":
        echo "│ Content: " & args{"content"}.getStr("")[0 ..< min(args{"content"}.getStr("").len, 80)]
      echo "├─────────────────────────────────────────────────────────────────────────────────────────────────────────┤"
      echo "│ [y] yes  [n] no  [e] edit"
      stdout.write "│ Approve? "
      stdout.flushFile()
      var response = ""
      while true:
        var ch = ""
        if stdin.readLine(response):
          response = response.strip.toLower
          case response
          of "y", "yes":
            return (arApproved, args)
          of "n", "no":
            return (arDenied, args)
          of "e", "edit":
            if toolName == "bash":
              stdout.write "│ New command: "
              stdout.flushFile()
              var newCmd = ""
              if stdin.readLine(newCmd):
                var newArgs = args
                newArgs["command"] = %newCmd
                return (arEdited, newArgs)
              else:
                return (arDenied, args)
            else:
              echo "│ Editing not supported for this tool, treating as denied."
              return (arDenied, args)
          else:
            stdout.write "│ Please enter y/n/e: "
            stdout.flushFile()
        else:
          return (arDenied, args)

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
      let modeDesc = case mode
        of "plan": "Read-Only (no write/bash/edit)"
        of "agent": "Semi-Auto (bash needs approval)"
        of "yolo": "Full Auto (all tools auto-execute)"
        else: mode
      tui.addContentLine("Mode: " & mode & " - " & modeDesc)
      statusBar.updateStatusBar()
      continue

    if input.strip() == "":
      continue
    
    # Add user input to content
    tui.addContentLine("> " & input)
    tui.clearInput()
    tui.renderTui()
    
    let cmd = input.strip
    let result = handleCommand(
      cmd, agent, tui, statusBar, sess, mcpClients, cwd,
      mode, modelName, providerName, thinkingLevel
    )
    case result
    of crBreak:
      break
    of crContinue:
      continue
    of crProcessInput:
      discard
    
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
