import std/[json, os, osproc, strutils, options, algorithm, sequtils, times, streams, base64, tables, httpclient]
import ../provider/types
import ../cron/cron as cronModule
import ../mcp/mcp as mcpModule
import ../sandbox/sandbox as sandboxModule
import ./jobs as jobsModule

# Plan Step
type
  PlanStep* = object
    title*: string
    status*: string  ## "pending", "running", "done", "failed"

  TaskPlan* = object
    title*: string
    steps*: seq[PlanStep]
    note*: string

  FileDiff* = object
    path*: string
    added*: int
    deleted*: int

  ToolResult* = object
    text*: string
    isError*: bool
    plan*: Option[TaskPlan]  ## Optional structured task plan
    diff*: Option[FileDiff]  ## Optional file diff info

  Tool* = ref object of RootObj
    name*: string
    description*: string
    parameters*: JsonNode
    workDir*: string

proc newToolResult*(text: string, isError: bool = false, plan: Option[TaskPlan] = none(TaskPlan), diff: Option[FileDiff] = none(FileDiff)): ToolResult =
  ToolResult(text: text, isError: isError, plan: plan, diff: diff)

# Diff helpers
proc buildDiffSummary(oldContent, newContent: string): string =
  ## Build a compact diff summary showing added/removed line counts
  let oldLines = if oldContent == "": @[] else: oldContent.splitLines()
  let newLines = if newContent == "": @[] else: newContent.splitLines()
  let deleted = oldLines.len
  let added = newLines.len
  result = "Diff: +" & $added & " -" & $deleted

proc formatDiffResult(path, oldContent, newContent: string): string =
  result = "Applied edit to " & path & "\n" & buildDiffSummary(oldContent, newContent)

proc formatWriteDiffResult(path: string, oldContent, newContent: string, bytes: int): string =
  result = "File written: " & path & " (" & $bytes & " bytes)\n" & buildDiffSummary(oldContent, newContent)

# Path resolution and security
proc resolvePath*(workDir: string, path: string): tuple[path: string, ok: bool] =
  ## Resolves a user-provided path to an absolute path constrained to the work directory
  var resolvedPath = path
  
  # Expand ~ (only ~/ prefix, not arbitrary ~user)
  if resolvedPath == "~":
    resolvedPath = getHomeDir()
  elif resolvedPath.startsWith("~/"):
    resolvedPath = getHomeDir() / resolvedPath[2 .. ^1]
  
  # Convert relative paths to absolute within workDir
  if not resolvedPath.isAbsolute:
    resolvedPath = workDir / resolvedPath
  
  # Clean to resolve .. segments
  resolvedPath = resolvedPath.normalizedPath
  
  # Validate: path must not escape workDir
  let cleanWorkDir = workDir.normalizedPath
  let rel = resolvedPath.relativePath(cleanWorkDir)
  if rel == ".." or rel.startsWith(".."):
    return ("", false)
  
  return (resolvedPath, true)

# Plan Tool
proc planToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "title": {"type": "string", "description": "Short title for the current task plan"},
      "steps": {
        "type": "array",
        "description": "Ordered task steps with statuses",
        "items": {
          "type": "object",
          "properties": {
            "title": {"type": "string", "description": "Concise step description"},
            "status": {"type": "string", "enum": ["pending", "running", "done", "failed"], "description": "Current step status"}
          },
          "required": ["title", "status"]
        }
      },
      "note": {"type": "string", "description": "Optional short note about risks, blockers, or next action"}
    },
    "required": ["steps"]
  }

proc normalizePlanStatus(status: string): string =
  case status.toLower.strip
  of "pending", "running", "done", "failed":
    return status.toLower.strip
  else:
    return ""

proc formatTaskPlan(plan: TaskPlan): string =
  if plan.title != "":
    result = "Plan: " & plan.title & "\n"
  else:
    result = "Plan updated:\n"
  for step in plan.steps:
    result.add("- [" & step.status & "] " & step.title & "\n")
  if plan.note != "":
    result.add("Note: " & plan.note)

proc executePlan(tool: Tool, params: JsonNode): ToolResult =
  let title = params{"title"}.getStr("")
  let note = params{"note"}.getStr("")
  let stepsRaw = params{"steps"}
  
  if stepsRaw.kind != JArray or stepsRaw.len == 0:
    return newToolResult("steps array is required and must not be empty", true)
  
  var plan = TaskPlan(
    title: title.strip,
    note: note.strip,
    steps: @[]
  )
  
  for i in 0 ..< stepsRaw.len:
    let stepNode = stepsRaw[i]
    let stepTitle = stepNode{"title"}.getStr("").strip
    if stepTitle == "":
      return newToolResult("step " & $i & ": title is required", true)
    let status = normalizePlanStatus(stepNode{"status"}.getStr(""))
    if status == "":
      return newToolResult("step " & $i & ": status must be pending, running, done, or failed", true)
    plan.steps.add(PlanStep(title: stepTitle, status: status))
  
  return newToolResult(formatTaskPlan(plan), false, some(plan))

# Read Tool (with image support)
const imageExtensions* = [".jpg", ".jpeg", ".png", ".gif", ".webp"]

proc isImageFile(path: string): bool =
  let lower = path.toLower
  for ext in imageExtensions:
    if lower.endsWith(ext):
      return true
  return false

proc readToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "path": {"type": "string", "description": "Path to the file to read"},
      "offset": {"type": "integer", "description": "Line number to start reading from (1-indexed)"},
      "limit": {"type": "integer", "description": "Maximum number of lines to read"}
    },
    "required": ["path"]
  }

proc executeRead(tool: Tool, params: JsonNode): ToolResult =
  let path = params{"path"}.getStr("")
  if path == "":
    return newToolResult("path is required", true)
  
  let (fullPath, ok) = resolvePath(tool.workDir, path)
  if not ok:
    return newToolResult("Invalid path: " & path, true)
  
  if not fileExists(fullPath):
    return newToolResult("File not found: " & fullPath, true)
  
  # Image file: return base64 encoded content
  if fullPath.isImageFile:
    try:
      let content = readFile(fullPath)
      let encoded = content.encode()
      let ext = fullPath.splitFile.ext.toLower
      var mimeType = "image/png"
      case ext
      of ".jpg", ".jpeg": mimeType = "image/jpeg"
      of ".png": mimeType = "image/png"
      of ".gif": mimeType = "image/gif"
      of ".webp": mimeType = "image/webp"
      else: discard
      return newToolResult("[image] " & fullPath & " (" & mimeType & ", " & $content.len & " bytes)\n" & encoded)
    except CatchableError as e:
      return newToolResult("Error reading image: " & e.msg, true)
  
  try:
    let content = readFile(fullPath)
    let lines = content.splitLines()
    
    var offset = params{"offset"}.getInt(1) - 1
    var limit = params{"limit"}.getInt(lines.len)
    
    if offset >= lines.len:
      return newToolResult("(end of file)")
    
    let endIndex = min(offset + limit, lines.len)
    let selected = lines[offset ..< endIndex]
    
    var result = ""
    for i, line in selected:
      result.add($(offset + i + 1) & "\t" & line & "\n")
    
    if result.len > 50000:
      result = result[0 ..< 50000] & "\n... (truncated)"
    
    return newToolResult(result)
  except CatchableError as e:
    return newToolResult("Error reading file: " & e.msg, true)

# Write Tool (with diff)
proc writeToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "path": {"type": "string", "description": "Path to the file to write"},
      "content": {"type": "string", "description": "Content to write to the file"}
    },
    "required": ["path", "content"]
  }

proc executeWrite(tool: Tool, params: JsonNode): ToolResult =
  let path = params{"path"}.getStr("")
  let content = params{"content"}.getStr("")
  
  if path == "":
    return newToolResult("path is required", true)
  if content == "":
    return newToolResult("content is required", true)
  
  let (fullPath, ok) = resolvePath(tool.workDir, path)
  if not ok:
    return newToolResult("Invalid path: " & path, true)
  
  try:
    var oldContent = ""
    if fileExists(fullPath):
      oldContent = readFile(fullPath)
    createDir(fullPath.parentDir)
    writeFile(fullPath, content)
    let diff = FileDiff(path: fullPath, added: content.splitLines.len, deleted: oldContent.splitLines.len)
    return newToolResult(formatWriteDiffResult(fullPath, oldContent, content, content.len), false, none(TaskPlan), some(diff))
  except CatchableError as e:
    return newToolResult("Error writing file: " & e.msg, true)

# Edit Tool (support both old format and new edits[] format)
proc editToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Path to the file to edit"
      },
      "edits": {
        "type": "array",
        "description": "Array of edits. Each edit has oldText (exact match) and newText (replacement).",
        "items": {
          "type": "object",
          "properties": {
            "oldText": {"type": "string", "description": "Exact text to find and replace"},
            "newText": {"type": "string", "description": "Replacement text"}
          },
          "required": ["oldText", "newText"]
        }
      },
      "oldText": {"type": "string", "description": "Exact text to find (legacy single-edit mode)"},
      "newText": {"type": "string", "description": "Replacement text (legacy single-edit mode)"}
    },
    "required": ["path"]
  }

proc executeEdit(tool: Tool, params: JsonNode): ToolResult =
  let path = params{"path"}.getStr("")
  
  if path == "":
    return newToolResult("path is required", true)
  
  let (fullPath, ok) = resolvePath(tool.workDir, path)
  if not ok:
    return newToolResult("Invalid path: " & path, true)
  
  if not fileExists(fullPath):
    return newToolResult("File not found: " & fullPath, true)
  
  # Collect edits from either format
  type EditEntry = object
    oldText: string
    newText: string
  
  var edits: seq[EditEntry] = @[]
  
  # New format: edits[] array
  let editsRaw = params{"edits"}
  if editsRaw.kind == JArray and editsRaw.len > 0:
    for i in 0 ..< editsRaw.len:
      let e = editsRaw[i]
      let ot = e{"oldText"}.getStr("")
      let nt = e{"newText"}.getStr("")
      if ot == "":
        return newToolResult("edit " & $i & ": oldText is required", true)
      edits.add(EditEntry(oldText: ot, newText: nt))
  else:
    # Legacy format: oldText/newText
    let oldText = params{"oldText"}.getStr("")
    let newText = params{"newText"}.getStr("")
    if oldText == "":
      return newToolResult("oldText or edits[] is required", true)
    edits.add(EditEntry(oldText: oldText, newText: newText))
  
  try:
    var content = readFile(fullPath)
    let originalContent = content
    
    # Validate all edits before applying
    for i, e in edits:
      let count = content.count(e.oldText)
      if count == 0:
        return newToolResult("edit " & $i & ": oldText not found in file", true)
      if count > 1:
        return newToolResult("edit " & $i & ": oldText matches " & $count & " times (must be unique)", true)
    
    # Apply all edits
    for i, e in edits:
      content = content.replace(e.oldText, e.newText)
    
    writeFile(fullPath, content)
    let diff = FileDiff(path: fullPath, added: edits.len, deleted: edits.len)
    return newToolResult("Applied " & $edits.len & " edit(s) to " & fullPath & "\n" & buildDiffSummary(originalContent, content), false, none(TaskPlan), some(diff))
  except CatchableError as e:
    return newToolResult("Error editing file: " & e.msg, true)

# Bash Tool (with timeout and async support)
proc bashToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "command": {"type": "string", "description": "Shell command to execute"},
      "timeout": {"type": "integer", "description": "Timeout in seconds (default 120, max 600)"},
      "async": {"type": "boolean", "description": "Run command in background (for long-running services like servers). Returns immediately with a job ID. Use 'jobs' tool to check status."}
    },
    "required": ["command"]
  }

proc executeBash(tool: Tool, params: JsonNode, sandbox: sandboxModule.Sandbox = nil): ToolResult =
  let command = params{"command"}.getStr("")
  if command == "":
    return newToolResult("command is required", true)
  
  let timeout = min(params{"timeout"}.getInt(120), 600)
  let asyncMode = params{"async"}.getBool(false)
  
  if asyncMode:
    # Background execution
    try:
      let process = startProcess(command, options = {poStdErrToStdOut, poDaemon}, workingDir = tool.workDir)
      let job = jobsModule.globalJobManager.addJob(process, command)
      return newToolResult("Started background job [" & $job.id & "] (PID: " & $job.pid & ")\nCommand: " & command & "\nUse 'jobs' to check status, 'kill' to stop.")
    except CatchableError as e:
      return newToolResult("Error starting background command: " & e.msg, true)
  
  try:
    var output: string
    var exitCode: int
    
    # Use sandbox if available and enabled
    if sandbox != nil and sandbox.isAvailable():
      let shell = getEnv("SHELL", "/bin/sh")
      let wrappedCmd = sandbox.wrapCommand(shell, command, timeout)
      if wrappedCmd.len > 0:
        let process = startProcess(
          wrappedCmd[0],
          args = wrappedCmd[1 .. ^1],
          options = {poStdErrToStdOut},
          workingDir = tool.workDir
        )
        output = process.outputStream().readAll()
        exitCode = process.waitForExit()
        process.close()
      else:
        # Fallback to normal execution
        (output, exitCode) = execCmdEx(command, options = {}, workingDir = tool.workDir)
    else:
      (output, exitCode) = execCmdEx(command, options = {}, workingDir = tool.workDir)
    
    var result = "[command]\n" & command & "\n[cwd]\n" & tool.workDir & "\n[stdout]\n" & output & "\n[exit_code]\n" & $exitCode
    
    if result.len > 50000:
      result = result[0 ..< 50000] & "\n... (truncated)"
    
    return newToolResult(result)
  except CatchableError as e:
    return newToolResult("Error executing command: " & e.msg, true)

# Ls Tool
proc lsToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "path": {"type": "string", "description": "Directory to list (default: current directory)"}
    }
  }

proc executeLs(tool: Tool, params: JsonNode): ToolResult =
  var path = params{"path"}.getStr("")
  if path == "":
    path = tool.workDir
  
  let fullPath = if path.isAbsolute: path else: tool.workDir / path
  
  if not dirExists(fullPath):
    return newToolResult("Directory not found: " & fullPath, true)
  
  try:
    var entries: seq[string] = @[]
    for kind, entry in walkDir(fullPath):
      let name = entry.extractFilename
      case kind
      of pcFile:
        let size = getFileSize(entry)
        entries.add("- " & name & " (" & $size & " bytes)")
      of pcDir:
        entries.add("d " & name & "/")
      of pcLinkToFile:
        entries.add("l " & name & " -> file")
      of pcLinkToDir:
        entries.add("l " & name & " -> dir")
    
    entries.sort()
    return newToolResult(entries.join("\n"))
  except CatchableError as e:
    return newToolResult("Error listing directory: " & e.msg, true)

# Grep Tool (with include and maxResults)
proc grepToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "pattern": {"type": "string", "description": "Regex pattern to search for"},
      "path": {"type": "string", "description": "Directory or file to search in (default: current directory)"},
      "include": {"type": "string", "description": "File pattern to include (e.g., '*.nim')"},
      "maxResults": {"type": "integer", "description": "Maximum number of results (default 100)"}
    },
    "required": ["pattern"]
  }

proc executeGrep(tool: Tool, params: JsonNode): ToolResult =
  let pattern = params{"pattern"}.getStr("")
  if pattern == "":
    return newToolResult("pattern is required", true)
  
  var path = params{"path"}.getStr("")
  if path == "":
    path = tool.workDir
  
  let fullPath = if path.isAbsolute: path else: tool.workDir / path
  let includePattern = params{"include"}.getStr("")
  let maxResults = params{"maxResults"}.getInt(100)
  
  try:
    var cmd = "grep -rn"
    if includePattern != "":
      # Use --include for file pattern filtering
      cmd.add(" --include=\"" & includePattern & "\"")
    cmd.add(" \"" & pattern & "\" " & fullPath)
    cmd.add(" 2>/dev/null | head -" & $maxResults)
    let (output, exitCode) = execCmdEx(cmd)
    
    if exitCode != 0 and output.len == 0:
      return newToolResult("No matches found")
    
    var result = output
    if result.len > 50000:
      result = result[0 ..< 50000] & "\n... (truncated)"
    
    return newToolResult(result)
  except CatchableError as e:
    return newToolResult("Error searching: " & e.msg, true)

# Find Tool (with maxResults)
proc findToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "pattern": {"type": "string", "description": "Glob pattern to match file names"},
      "path": {"type": "string", "description": "Directory to search in (default: current directory)"},
      "maxResults": {"type": "integer", "description": "Maximum number of results (default 200)"}
    },
    "required": ["pattern"]
  }

proc executeFind(tool: Tool, params: JsonNode): ToolResult =
  let pattern = params{"pattern"}.getStr("")
  if pattern == "":
    return newToolResult("pattern is required", true)
  
  var path = params{"path"}.getStr("")
  if path == "":
    path = tool.workDir
  
  let fullPath = if path.isAbsolute: path else: tool.workDir / path
  let maxResults = params{"maxResults"}.getInt(200)
  
  try:
    let cmd = "find " & fullPath & " -name \"" & pattern & "\" 2>/dev/null | head -" & $maxResults
    let (output, exitCode) = execCmdEx(cmd)
    
    if output.len == 0:
      return newToolResult("No files found matching: " & pattern)
    
    var result = output
    if result.len > 50000:
      result = result[0 ..< 50000] & "\n... (truncated)"
    
    return newToolResult(result)
  except CatchableError as e:
    return newToolResult("Error finding files: " & e.msg, true)

# Jobs Tool
proc executeJobs(tool: Tool, params: JsonNode): ToolResult =
  let jobs = jobsModule.globalJobManager.listJobs()
  if jobs.len == 0:
    return newToolResult("No background jobs running")
  
  var result = ""
  for job in jobs:
    result.add(jobsModule.formatJobStatus(job) & "\n")
  return newToolResult(result.strip)

# Kill Tool
proc executeKill(tool: Tool, params: JsonNode): ToolResult =
  let jobId = params{"jobId"}.getInt(0)
  if jobId == 0:
    return newToolResult("jobId is required", true)
  
  if jobsModule.globalJobManager.killJob(jobId):
    return newToolResult("Job " & $jobId & " killed")
  return newToolResult("Job " & $jobId & " not found or already finished", true)

# Skill Ref Tool
proc skillRefToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "skill": {"type": "string", "description": "The skill name (directory name)"},
      "ref": {"type": "string", "description": "The reference file path relative to the skill directory (e.g. 'references/audio.md')"}
    },
    "required": ["skill", "ref"]
  }

# Spawn Tool (multi-agent)
proc spawnToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "prompt": {"type": "string", "description": "Task description for the sub-agent"},
      "mode": {"type": "string", "description": "Sub-agent mode: agent, yolo (default: yolo)", "enum": ["agent", "yolo"]},
      "working_directory": {"type": "string", "description": "Working directory for the sub-agent (default: current directory)"}
    },
    "required": ["prompt"]
  }

# Cron Tool
proc cronToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "action": {"type": "string", "description": "Action: list, create, enable, disable, remove", "enum": ["list", "create", "enable", "disable", "remove"]},
      "id": {"type": "string", "description": "Job ID (required for enable, disable, remove)"},
      "name": {"type": "string", "description": "Short task name (required for create)"},
      "prompt": {"type": "string", "description": "Task prompt for the sub-agent (required for create)"},
      "schedule": {"type": "string", "description": "Schedule: @daily, @weekly, @monthly, @hourly, @every 30m, @every 2h, or empty for one-shot"},
      "oneshot": {"type": "boolean", "description": "If true, run once then auto-disable (default: false)"},
      "mode": {"type": "string", "description": "Agent mode for the task: agent, yolo (default: yolo)", "enum": ["agent", "yolo"]}
    },
    "required": ["action"]
  }

proc executeCron(tool: Tool, params: JsonNode, cronStore: cronModule.CronStore): ToolResult =
  let action = params{"action"}.getStr("")
  try:
    case action
    of "list":
      return newToolResult(cronStore.formatJobs())
    of "create":
      let name = params{"name"}.getStr("")
      let prompt = params{"prompt"}.getStr("")
      let schedule = params{"schedule"}.getStr("")
      let oneShot = params{"oneshot"}.getBool(false)
      let mode = params{"mode"}.getStr("yolo")
      let job = cronStore.create(name, prompt, schedule, oneShot, mode)
      let kind = if job.oneShot: "one-shot" else: "periodic"
      return newToolResult("Cron job created (" & kind & "):\n  ID: " & job.id & "\n  Name: " & job.name & "\n  Schedule: " & cronModule.formatSchedule(job.schedule, job.oneShot) & "\n  Mode: " & job.mode & "\n  Prompt: " & job.prompt[0 ..< min(job.prompt.len, 100)])
    of "enable":
      let id = params{"id"}.getStr("")
      cronStore.setEnabled(id, true)
      return newToolResult("Cron job enabled: " & id)
    of "disable":
      let id = params{"id"}.getStr("")
      cronStore.setEnabled(id, false)
      return newToolResult("Cron job disabled: " & id)
    of "remove":
      let id = params{"id"}.getStr("")
      cronStore.remove(id)
      return newToolResult("Cron job removed: " & id)
    else:
      return newToolResult("Unknown cron action: " & action & " (use: list, create, enable, disable, remove)", true)
  except CatchableError as e:
    return newToolResult("Cron error: " & e.msg, true)

# Spawn Tool (multi-agent)
proc executeSpawn(tool: Tool, params: JsonNode): ToolResult =
  let prompt = params{"prompt"}.getStr("")
  if prompt == "":
    return newToolResult("prompt is required", true)
  
  let subMode = params{"mode"}.getStr("yolo")
  let subWorkDir = params{"working_directory"}.getStr(tool.workDir)
  
  # Execute sub-agent via nimcode CLI
  let args = @["-M", subMode, "-P", prompt]
  try:
    let (output, exitCode) = execCmdEx("nimcode " & args.mapIt("'" & it & "'").join(" "))
    if exitCode == 0:
      return newToolResult(output.strip())
    else:
      return newToolResult("Sub-agent failed (exit " & $exitCode & "): " & output.strip(), true)
  except CatchableError as e:
    return newToolResult("Spawn error: " & e.msg, true)

# Memory Tools
proc memoryReadToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "query": {"type": "string", "description": "Optional search query to filter memory entries"},
      "maxEntries": {"type": "integer", "description": "Maximum number of entries to return (default: 20)"}
    },
    "required": []
  }

proc memoryWriteToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "content": {"type": "string", "description": "Content to write to memory"},
      "append": {"type": "boolean", "description": "If true, append to existing memory. If false, replace. Default: true"}
    },
    "required": ["content"]
  }

proc executeMemoryRead(tool: Tool, params: JsonNode): ToolResult =
  let memoryPath = getHomeDir() / ".nimcode" / "memory.md"
  let query = params{"query"}.getStr("")
  let maxEntries = params{"maxEntries"}.getInt(20)
  
  if not fileExists(memoryPath):
    return newToolResult("No memory file found at: " & memoryPath)
  
  try:
    let content = readFile(memoryPath)
    if content.strip() == "":
      return newToolResult("Memory is empty")
    
    if query != "":
      # Search for matching entries
      var entries: seq[string] = @[]
      var currentEntry = ""
      for line in content.splitLines():
        if line.startsWith("## "):
          if currentEntry != "" and currentEntry.toLower.contains(query.toLower):
            entries.add(currentEntry)
          currentEntry = line
        else:
          currentEntry.add("\n" & line)
      if currentEntry != "" and currentEntry.toLower.contains(query.toLower):
        entries.add(currentEntry)
      
      if entries.len == 0:
        return newToolResult("No memory entries matching: " & query)
      
      let resultEntries = entries[max(0, entries.len - maxEntries) .. ^1]
      return newToolResult(resultEntries.join("\n\n"))
    else:
      # Return all entries (limited)
      var entries: seq[string] = @[]
      var currentEntry = ""
      for line in content.splitLines():
        if line.startsWith("## "):
          if currentEntry != "":
            entries.add(currentEntry)
          currentEntry = line
        else:
          currentEntry.add("\n" & line)
      if currentEntry != "":
        entries.add(currentEntry)
      
      let resultEntries = entries[max(0, entries.len - maxEntries) .. ^1]
      return newToolResult(resultEntries.join("\n\n"))
  except CatchableError as e:
    return newToolResult("Error reading memory: " & e.msg, true)

proc executeMemoryWrite(tool: Tool, params: JsonNode): ToolResult =
  let memoryPath = getHomeDir() / ".nimcode" / "memory.md"
  let content = params{"content"}.getStr("")
  let append = params{"append"}.getBool(true)
  
  if content == "":
    return newToolResult("content is required", true)
  
  try:
    let dir = memoryPath.parentDir()
    if not dirExists(dir):
      createDir(dir)
    
    let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
    let formattedEntry = "\n## " & timestamp & "\n\n" & content & "\n"
    
    if append and fileExists(memoryPath):
      let existing = readFile(memoryPath)
      writeFile(memoryPath, existing & formattedEntry)
    else:
      writeFile(memoryPath, "# Memory\n" & formattedEntry)
    
    return newToolResult("Memory written successfully to: " & memoryPath)
  except CatchableError as e:
    return newToolResult("Error writing memory: " & e.msg, true)

# A2A Dispatch Tool
proc a2aDispatchToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "serverUrl": {"type": "string", "description": "URL of the A2A server (e.g., http://localhost:8181)"},
      "message": {"type": "string", "description": "Message/task to send to the remote agent"},
      "taskId": {"type": "string", "description": "Optional task ID (auto-generated if empty)"}
    },
    "required": ["serverUrl", "message"]
  }

proc executeA2ADispatch(tool: Tool, params: JsonNode): ToolResult =
  let serverUrl = params{"serverUrl"}.getStr("")
  let message = params{"message"}.getStr("")
  let taskId = params{"taskId"}.getStr("")
  
  if serverUrl == "":
    return newToolResult("serverUrl is required", true)
  if message == "":
    return newToolResult("message is required", true)
  
  let client = newHttpClient()
  client.headers = newHttpHeaders([("Content-Type", "application/json")])
  
  let request = %*{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tasks/send",
    "params": {
      "id": taskId,
      "message": {
        "role": "user",
        "parts": [{"type": "text", "text": message}]
      }
    }
  }
  
  try:
    let response = client.postContent(serverUrl, $request)
    let respJson = parseJson(response)
    
    if respJson.hasKey("error"):
      let error = respJson["error"]
      return newToolResult("A2A error: " & error{"message"}.getStr("Unknown error"), true)
    
    if respJson.hasKey("result"):
      let result = respJson["result"]
      let state = result{"state"}.getStr("unknown")
      var responseText = "Task state: " & state
      
      if result.hasKey("artifacts") and result["artifacts"].kind == JArray:
        for art in result["artifacts"]:
          let artName = art{"name"}.getStr("")
          if art.hasKey("parts") and art["parts"].kind == JArray:
            for part in art["parts"]:
              let partText = part{"text"}.getStr("")
              if partText != "":
                responseText.add("\n\n" & (if artName != "": artName & ": " else: "") & partText)
      
      return newToolResult(responseText)
    
    return newToolResult("A2A response: " & response)
  except CatchableError as e:
    return newToolResult("A2A dispatch error: " & e.msg, true)

# Tool Registry
type
# MCP tool info for execution
  MCPTuple* = object
    client*: mcpModule.MCPClient
    toolName*: string

  ToolRegistry* = ref object
    tools*: seq[Tool]
    skillsDir*: string  ## Global skills directory for skill_ref
    cronStore*: cronModule.CronStore  ## Cron job store
    mcpTools*: Table[string, MCPTuple]  ## MCP tool name -> client+toolName
    webSearchProviderType*: string  ## Provider type for web_search hosted tool
    sandbox*: sandboxModule.Sandbox  ## Sandbox for bash execution
    sandboxLevel*: sandboxModule.SandboxLevel

proc newToolRegistry*(workDir: string, skillsDir: string = "", sandboxEnabled: bool = false, sandboxLevel: string = "none"): ToolRegistry =
  let cronPath = getHomeDir() / ".nimcode" / "cron.json"
  let sbLevel = case sandboxLevel
    of "strict": sandboxModule.slStrict
    of "standard": sandboxModule.slStandard
    else: sandboxModule.slNone
  let sb = if sandboxEnabled and sbLevel != sandboxModule.slNone:
    sandboxModule.newSandbox(workDir, sbLevel)
  else:
    nil
  result = ToolRegistry(
    tools: @[],
    skillsDir: skillsDir,
    cronStore: cronModule.newCronStore(cronPath),
    mcpTools: initTable[string, MCPTuple](),
    webSearchProviderType: "",
    sandbox: sb,
    sandboxLevel: sbLevel
  )
  
  result.tools.add(Tool(name: "read", description: "Read file contents (supports text and images)", parameters: readToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "write", description: "Write content to a file", parameters: writeToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "edit", description: "Edit a file using exact text replacement", parameters: editToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "bash", description: "Execute a shell command", parameters: bashToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "ls", description: "List directory contents", parameters: lsToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "grep", description: "Search file contents using regex", parameters: grepToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "find", description: "Find files by name pattern", parameters: findToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "plan", description: "Publish or update a structured task plan", parameters: planToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "jobs", description: "List background jobs", parameters: listJobsToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "kill", description: "Kill a running background job", parameters: killToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "cron", description: "Manage scheduled tasks (cron jobs). Create one-time or periodic background tasks.", parameters: cronToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "spawn", description: "Spawn a sub-agent to handle a task in parallel. The sub-agent runs independently and returns results.", parameters: spawnToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "skill_ref", description: "Load a reference file from an active skill. Use this to access on-demand knowledge from skills that have reference files.", parameters: skillRefToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "memory_read", description: "Read from persistent memory (memory.md). Search or list recent entries.", parameters: memoryReadToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "memory_write", description: "Write to persistent memory (memory.md). Store important information for future reference.", parameters: memoryWriteToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "a2a_dispatch", description: "Send a task to a remote A2A (Agent-to-Agent) server. Enables inter-agent communication.", parameters: a2aDispatchToolParams(), workDir: workDir))

proc getTool*(registry: ToolRegistry, name: string): Option[Tool] =
  for t in registry.tools:
    if t.name == name:
      return some(t)
  return none(Tool)

proc definitions*(registry: ToolRegistry): seq[ToolDefinition] =
  result = @[]
  for t in registry.tools:
    result.add(ToolDefinition(
      name: t.name,
      description: t.description,
      parameters: t.parameters
    ))

proc execute*(registry: ToolRegistry, toolName: string, params: JsonNode): ToolResult =
  let toolOpt = registry.getTool(toolName)
  if toolOpt.isNone:
    return newToolResult("Unknown tool: " & toolName, true)
  
  let tool = toolOpt.get()
  case tool.name
  of "read": return tool.executeRead(params)
  of "write": return tool.executeWrite(params)
  of "edit": return tool.executeEdit(params)
  of "bash": return tool.executeBash(params, registry.sandbox)
  of "ls": return tool.executeLs(params)
  of "grep": return tool.executeGrep(params)
  of "find": return tool.executeFind(params)
  of "plan": return tool.executePlan(params)
  of "jobs": return tool.executeJobs(params)
  of "kill": return tool.executeKill(params)
  of "cron": return tool.executeCron(params, registry.cronStore)
  of "spawn": return tool.executeSpawn(params)
  of "skill_ref":
    # Skill ref: load reference file from skills directory
    let skillName = params{"skill"}.getStr("")
    let refPath = params{"ref"}.getStr("")
    if skillName == "" or refPath == "":
      return newToolResult("skill and ref are required", true)
    if registry.skillsDir == "":
      return newToolResult("No skills directory configured", true)
    let fullPath = registry.skillsDir / skillName / refPath
    if not fileExists(fullPath):
      return newToolResult("Reference file not found: " & fullPath, true)
    try:
      return newToolResult(readFile(fullPath))
    except CatchableError as e:
      return newToolResult("Error reading reference: " & e.msg, true)
  of "memory_read":
    return tool.executeMemoryRead(params)
  of "memory_write":
    return tool.executeMemoryWrite(params)
  of "a2a_dispatch":
    return tool.executeA2ADispatch(params)
  else:
    # Check if it's an MCP tool
    if registry.mcpTools.hasKey(toolName):
      let mcpTuple = registry.mcpTools[toolName]
      try:
        let result = mcpModule.callTool(mcpTuple.client, mcpTuple.toolName, params)
        return newToolResult(result)
      except CatchableError as e:
        return newToolResult("MCP tool error: " & e.msg, true)
    return newToolResult("Unknown tool: " & toolName, true)
