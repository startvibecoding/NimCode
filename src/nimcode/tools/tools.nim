import std/[json, os, osproc, strutils, options, algorithm]
import ../provider/types
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

  ToolResult* = object
    text*: string
    isError*: bool
    plan*: Option[TaskPlan]  ## Optional structured task plan

  Tool* = ref object of RootObj
    name*: string
    description*: string
    parameters*: JsonNode
    workDir*: string

proc newToolResult*(text: string, isError: bool = false, plan: Option[TaskPlan] = none(TaskPlan)): ToolResult =
  ToolResult(text: text, isError: isError, plan: plan)

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

# Read Tool
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

# Write Tool
proc writeToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "path": {"type": "string", "description": "Path to the file to write"},
      "content": {"type": "string", "description": "Content to write"}
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
    createDir(fullPath.parentDir)
    writeFile(fullPath, content)
    return newToolResult("File written: " & fullPath & " (" & $content.len & " bytes)")
  except CatchableError as e:
    return newToolResult("Error writing file: " & e.msg, true)

# Edit Tool
proc editToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "path": {"type": "string", "description": "Path to the file to edit"},
      "oldText": {"type": "string", "description": "Exact text to find"},
      "newText": {"type": "string", "description": "Replacement text"}
    },
    "required": ["path", "oldText", "newText"]
  }

proc executeEdit(tool: Tool, params: JsonNode): ToolResult =
  let path = params{"path"}.getStr("")
  let oldText = params{"oldText"}.getStr("")
  let newText = params{"newText"}.getStr("")
  
  if path == "":
    return newToolResult("path is required", true)
  if oldText == "":
    return newToolResult("oldText is required", true)
  
  let (fullPath, ok) = resolvePath(tool.workDir, path)
  if not ok:
    return newToolResult("Invalid path: " & path, true)
  
  if not fileExists(fullPath):
    return newToolResult("File not found: " & fullPath, true)
  
  try:
    var content = readFile(fullPath)
    let count = content.count(oldText)
    
    if count == 0:
      return newToolResult("oldText not found in file", true)
    if count > 1:
      return newToolResult("oldText matches " & $count & " times (must be unique)", true)
    
    content = content.replace(oldText, newText)
    writeFile(fullPath, content)
    return newToolResult("Applied edit to " & fullPath)
  except CatchableError as e:
    return newToolResult("Error editing file: " & e.msg, true)

# Bash Tool
proc bashToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "command": {"type": "string", "description": "Shell command to execute"},
      "timeout": {"type": "integer", "description": "Timeout in seconds (default 120)"}
    },
    "required": ["command"]
  }

proc executeBash(tool: Tool, params: JsonNode): ToolResult =
  let command = params{"command"}.getStr("")
  if command == "":
    return newToolResult("command is required", true)
  
  let timeout = params{"timeout"}.getInt(120)
  
  try:
    let (output, exitCode) = execCmdEx(command, options = {}, workingDir = tool.workDir)
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

# Grep Tool
proc grepToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "pattern": {"type": "string", "description": "Regex pattern to search for"},
      "path": {"type": "string", "description": "Directory or file to search in"},
      "include": {"type": "string", "description": "File pattern to include (e.g., '*.nim')"}
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
  
  try:
    let cmd = "grep -rn \"" & pattern & "\" " & fullPath
    let (output, exitCode) = execCmdEx(cmd)
    
    if exitCode != 0 and output.len == 0:
      return newToolResult("No matches found")
    
    var result = output
    if result.len > 50000:
      result = result[0 ..< 50000] & "\n... (truncated)"
    
    return newToolResult(result)
  except CatchableError as e:
    return newToolResult("Error searching: " & e.msg, true)

# Find Tool
proc findToolParams(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "pattern": {"type": "string", "description": "Glob pattern to match file names"},
      "path": {"type": "string", "description": "Directory to search in"}
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
  
  try:
    let cmd = "find " & fullPath & " -name \"" & pattern & "\" 2>/dev/null | head -200"
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
  # This is a placeholder - in a real implementation, this would list background jobs
  return newToolResult("No background jobs running")

# Kill Tool
proc executeKill(tool: Tool, params: JsonNode): ToolResult =
  let jobId = params{"jobId"}.getInt(0)
  if jobId == 0:
    return newToolResult("jobId is required", true)
  # This is a placeholder - in a real implementation, this would kill a background job
  return newToolResult("Job " & $jobId & " not found", true)

# Tool Registry
type
  ToolRegistry* = ref object
    tools*: seq[Tool]

proc newToolRegistry*(workDir: string): ToolRegistry =
  result = ToolRegistry(tools: @[])
  
  result.tools.add(Tool(name: "read", description: "Read file contents", parameters: readToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "write", description: "Write content to a file", parameters: writeToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "edit", description: "Edit a file using exact text replacement", parameters: editToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "bash", description: "Execute a shell command", parameters: bashToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "ls", description: "List directory contents", parameters: lsToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "grep", description: "Search file contents using regex", parameters: grepToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "find", description: "Find files by name pattern", parameters: findToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "plan", description: "Publish or update a structured task plan", parameters: planToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "jobs", description: "List background jobs", parameters: listJobsToolParams(), workDir: workDir))
  result.tools.add(Tool(name: "kill", description: "Kill a running background job", parameters: killToolParams(), workDir: workDir))

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
  of "bash": return tool.executeBash(params)
  of "ls": return tool.executeLs(params)
  of "grep": return tool.executeGrep(params)
  of "find": return tool.executeFind(params)
  of "plan": return tool.executePlan(params)
  of "jobs": return tool.executeJobs(params)
  of "kill": return tool.executeKill(params)
  else: return newToolResult("Unknown tool: " & toolName, true)
