import std/[os, strutils, sequtils]

type
  FileContent* = object
    path*: string      ## Absolute path
    name*: string      ## File name
    content*: string   ## File content

  LoadResult* = object
    globalFiles*: seq[FileContent]   ## Files from ~/.nimcode/
    parentFiles*: seq[FileContent]   ## Files from parent directories
    projectFiles*: seq[FileContent]  ## Files from current directory

## Well-known context file names used by various AI coding tools
const wellKnownFiles* = [
  # NimCode / VibeCoding
  "AGENTS.md",
  "CLAUDE.md",
  
  # Cursor
  ".cursorrules",
  
  # Windsurf
  ".windsurfrules",
  
  # Cline/Roo
  ".clinerules",
  
  # GitHub Copilot
  ".github/copilot-instructions.md",
  
  # Generic
  "CONVENTIONS.md",
  "CONTRIBUTING.md",
  "INSTRUCTIONS.md",
]

proc safeContextFilePath(baseDir, name: string): tuple[path: string, ok: bool] =
  ## Safely join base dir and name, preventing path traversal
  if name.isAbsolute:
    return ("", false)
  
  let base = baseDir.normalizedPath
  let path = (base / name).normalizedPath
  
  # Check that path is under base
  let rel = path.relativePath(base)
  if rel == ".." or rel.startsWith(".." & $DirSep):
    return ("", false)
  
  return (path, true)

proc loadContextFiles*(cwd: string, globalConfigDir: string, extraFiles: seq[string] = @[]): LoadResult =
  ## Discovers and loads context files from all relevant locations
  ## Walks up from cwd to the root, then checks the global config directory
  
  result = LoadResult()
  
  # Combine well-known files with user-configured extra files
  var fileNames: seq[string] = @[]
  for name in wellKnownFiles:
    fileNames.add(name)
  for name in extraFiles:
    fileNames.add(name)
  
  # Deduplicate
  var seen: seq[string] = @[]
  var uniqueNames: seq[string] = @[]
  for name in fileNames:
    if name notin seen:
      seen.add(name)
      uniqueNames.add(name)
  
  # 1. Load from current directory (highest priority)
  # Only the first matching file is loaded per directory
  for name in uniqueNames:
    let (path, ok) = safeContextFilePath(cwd, name)
    if not ok:
      continue
    if fileExists(path):
      try:
        let content = readFile(path)
        result.projectFiles.add(FileContent(
          path: path,
          name: name,
          content: content
        ))
        break
      except:
        continue
  
  # 2. Walk up from cwd to root, loading context files from parent directories
  var dir = cwd
  while true:
    let parent = dir.parentDir
    if parent == dir:
      break  # reached root
    
    # Don't load from root or home directories to avoid noise
    if parent == "/" or parent == "":
      break
    
    # Only the first matching file is loaded per parent directory
    for name in uniqueNames:
      let (path, ok) = safeContextFilePath(parent, name)
      if not ok:
        continue
      if fileExists(path):
        try:
          let content = readFile(path)
          result.parentFiles.add(FileContent(
            path: path,
            name: name,
            content: content
          ))
          break
        except:
          continue
    
    dir = parent
  
  # 3. Load from global config directory (~/.nimcode/)
  # Only the first matching file is loaded
  if globalConfigDir != "":
    for name in uniqueNames:
      let (path, ok) = safeContextFilePath(globalConfigDir, name)
      if not ok:
        continue
      if fileExists(path):
        try:
          let content = readFile(path)
          result.globalFiles.add(FileContent(
            path: path,
            name: name,
            content: content
          ))
          break
        except:
          continue

proc formatContextFile(f: FileContent, scope: string): string =
  ## Format a single context file for inclusion in system prompt
  result = "---\n"
  result.add("File: `" & f.path & "` (scope: " & scope & ")\n")
  result.add("---\n")
  result.add(f.content)
  if not f.content.endsWith("\n"):
    result.add("\n")
  result.add("\n")

proc buildContextString*(loadResult: LoadResult): string =
  ## Concatenates all context files into a single string
  ## suitable for appending to the system prompt.
  ## Order: global -> parent (root to cwd) -> project (current dir)
  
  if loadResult.globalFiles.len == 0 and loadResult.parentFiles.len == 0 and loadResult.projectFiles.len == 0:
    return ""
  
  var sb = ""
  sb.add("\n## Project Context\n\n")
  sb.add("The following context files have been loaded from the project and configuration directories.\n")
  sb.add("IMPORTANT: These files contain project-specific conventions, architecture details, and coding guidelines.\n")
  sb.add("Always consult them first before exploring the codebase with commands like ls, find, or grep.\n\n")
  
  # Global files (lowest priority)
  for f in loadResult.globalFiles:
    sb.add(formatContextFile(f, "global"))
  
  # Parent files (medium priority, root to cwd order)
  # Reverse so closer parents have higher priority
  for i in countdown(loadResult.parentFiles.len - 1, 0):
    sb.add(formatContextFile(loadResult.parentFiles[i], "parent"))
  
  # Project files (highest priority)
  for f in loadResult.projectFiles:
    sb.add(formatContextFile(f, "project"))
  
  return sb

proc buildContextFilesInfo*(loadResult: LoadResult): string =
  ## Build a human-readable summary of loaded context files
  if loadResult.globalFiles.len == 0 and loadResult.parentFiles.len == 0 and loadResult.projectFiles.len == 0:
    return ""
  
  var sb = ""
  sb.add("📄 Loaded context files:\n")
  
  for f in loadResult.globalFiles:
    sb.add("  ✓ " & f.name & " (global)\n")
  
  for f in loadResult.parentFiles:
    sb.add("  ✓ " & f.name & " (parent: " & f.path.parentDir & ")\n")
  
  for f in loadResult.projectFiles:
    sb.add("  ✓ " & f.name & " (project)\n")
  
  return sb
