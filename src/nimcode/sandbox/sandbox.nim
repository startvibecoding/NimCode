## Sandbox module for NimCode.
## Supports bwrap (bubblewrap) on Linux for process isolation.

import std/[os, osproc, strutils]

type
  SandboxLevel* = enum
    slStrict = "strict"    ## Plan mode: read-only project, no network
    slStandard = "standard" ## Agent mode: read-write project, no network
    slNone = "none"        ## YOLO mode: no restrictions

  Sandbox* = ref object
    level*: SandboxLevel
    projectDir*: string
    bwrapPath*: string

proc findBwrap*(): string =
  ## Locate the bwrap binary
  let candidates = @[
    "/usr/bin/bwrap",
    "/usr/local/bin/bwrap",
  ]
  for c in candidates:
    if fileExists(c):
      return c
  # Try PATH
  try:
    let (output, exitCode) = execCmdEx("which bwrap")
    if exitCode == 0 and output.strip() != "":
      return output.strip()
  except:
    discard
  return ""

proc newSandbox*(projectDir: string, level: SandboxLevel): Sandbox =
  result = Sandbox(
    level: level,
    projectDir: projectDir,
    bwrapPath: findBwrap(),
  )

proc isAvailable*(s: Sandbox): bool =
  ## Check if sandboxing is available
  if s.level == slNone:
    return false
  if s.bwrapPath == "":
    return false
  # bwrap is Linux only
  when defined(linux):
    return true
  else:
    return false

proc wrapCommand*(s: Sandbox, shell, cmd: string, timeout: int = 120): seq[string] =
  ## Wrap a command for sandboxed execution. Returns the full command line.
  if s.level == slNone or not s.isAvailable():
    return @[shell, "-c", cmd]
  
  var args: seq[string] = @[
    s.bwrapPath,
    "--unshare-all",          # Unshare all namespaces
    "--die-with-parent",      # Die when parent dies
    "--new-session",          # New session
    "--ro-bind", "/usr", "/usr",
    "--ro-bind", "/bin", "/bin",
    "--ro-bind", "/lib", "/lib",
    "--ro-bind", "/lib64", "/lib64",
    "--ro-bind", "/etc", "/etc",
    "--dev", "/dev",
    "--proc", "/proc",
    "--tmpfs", "/tmp",
  ]
  
  # Bind the project directory
  case s.level
  of slStrict:
    args.add(@["--ro-bind", s.projectDir, s.projectDir])
  of slStandard:
    args.add(@["--bind", s.projectDir, s.projectDir])
  of slNone:
    discard
  
  # Add home directory (read-only for strict, read-write for standard)
  let home = getHomeDir()
  if s.level == slStrict:
    args.add(@["--ro-bind", home, home])
  else:
    args.add(@["--bind", home, home])
  
  args.add(@["--chdir", s.projectDir])
  args.add(@["--", shell, "-c", cmd])
  
  return args

proc execute*(s: Sandbox, shell, cmd: string, timeout: int = 120): tuple[output: string, exitCode: int] =
  ## Execute a command in the sandbox
  let fullCmd = s.wrapCommand(shell, cmd, timeout)
  if fullCmd.len == 0:
    return ("Failed to build sandbox command", 1)
  
  try:
    let (output, exitCode) = execCmdEx(fullCmd.join(" "), options = {poStdErrToStdOut})
    return (output, exitCode)
  except CatchableError as e:
    return ("Sandbox execution error: " & e.msg, 1)
