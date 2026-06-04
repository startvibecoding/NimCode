import std/[terminal, strutils, json]

type
  ColorMode* = enum
    cmAuto    ## Auto-detect terminal capabilities
    cmAlways  ## Always use colors
    cmNever   ## Never use colors

var colorMode* = cmAuto

proc supportsColor*(): bool =
  ## Checks if the terminal supports color
  case colorMode
  of cmAuto:
    return isatty(stdout)
  of cmAlways:
    return true
  of cmNever:
    return false

proc colored*(text: string, fg: ForegroundColor = fgDefault, style: Style = styleBright): string =
  ## Returns colored text if terminal supports it
  if supportsColor():
    return ansiForegroundColorCode(fg) & ansiStyleCode(style) & text & ansiResetCode
  return text

proc bold*(text: string): string =
  return colored(text, style = styleBright)

proc dim*(text: string): string =
  return colored(text, fg = fgBlack)

proc italic*(text: string): string =
  return colored(text, style = styleItalic)

proc green*(text: string): string =
  return colored(text, fg = fgGreen)

proc red*(text: string): string =
  return colored(text, fg = fgRed)

proc yellow*(text: string): string =
  return colored(text, fg = fgYellow)

proc blue*(text: string): string =
  return colored(text, fg = fgBlue)

proc cyan*(text: string): string =
  return colored(text, fg = fgCyan)

proc magenta*(text: string): string =
  return colored(text, fg = fgMagenta)

proc truncateJson*(node: JsonNode, maxLen: int = 200): string =
  ## Truncate JSON string for display
  let s = $node
  if s.len <= maxLen:
    return s
  return s[0 ..< maxLen] & "..."

proc formatToolCall*(toolName: string, args: JsonNode): string =
  ## Formats a tool call for display with actual arguments
  let argsStr = truncateJson(args, 150)
  return "\n" & cyan(">>") & " " & bold(toolName) & " " & dim(argsStr)

proc formatToolCall*(toolName: string, args: string): string =
  ## Formats a tool call for display (string version)
  let argsPreview = if args.len > 150: args[0 ..< 150] & "..." else: args
  return "\n" & cyan(">>") & " " & bold(toolName) & " " & dim(argsPreview)

proc formatToolResult*(toolName: string, text: string, isError: bool = false): string =
  ## Formats a tool result for display
  let preview = if text.len > 200: text[0 ..< 200] & "..." else: text
  if isError:
    return "\n" & red("<<") & " " & bold(toolName) & " " & red("error: ") & preview & "\n"
  else:
    return "\n" & green("<<") & " " & bold(toolName) & " " & dim(preview) & "\n"

proc formatError*(msg: string): string =
  ## Formats an error message
  return red("\nError: ") & msg & "\n"

proc formatStatus*(msg: string): string =
  ## Formats a status message
  return dim(msg)

proc formatSession*(info: string): string =
  ## Formats session info
  return cyan(info)

proc formatContextFiles*(info: string): string =
  ## Formats context files info
  return yellow(info)

proc formatMode*(mode: string): string =
  ## Formats mode info
  case mode
  of "plan":
    return blue("Mode: PLAN")
  of "agent":
    return green("Mode: AGENT")
  of "yolo":
    return red("Mode: YOLO")
  else:
    return "Mode: " & mode.toUpper

proc formatPrompt*(): string =
  ## Formats the input prompt
  return "\n" & bold("> ")

proc formatStatusBar*(mode, model, workDir: string, usagePercent: float, contextWindow: int, lastDuration: float = 0): string =
  ## Formats the status bar below input
  var parts: seq[string] = @[]
  
  # Mode with emoji
  let modeStr = case mode
    of "plan": blue("📝 PLAN")
    of "agent": green("🤖 AGENT")
    of "yolo": red("🚀 YOLO")
    else: "⚙️ " & mode.toUpper
  parts.add(modeStr)
  
  # Model
  parts.add(cyan(model))
  
  # Working directory (short)
  let shortDir = if workDir.len > 30: "..." & workDir[^27..^1] else: workDir
  parts.add(dim(shortDir))
  
  # Context usage
  if contextWindow > 0:
    let percent = usagePercent
    let percentStr = formatFloat(percent, ffDecimal, 1) & "%"
    let windowStr = if contextWindow >= 1000:
      formatFloat(contextWindow.float / 1000.0, ffDecimal, 0) & "k"
    else:
      $contextWindow
    if percent > 80:
      parts.add(red(percentStr & "/" & windowStr))
    elif percent > 50:
      parts.add(yellow(percentStr & "/" & windowStr))
    else:
      parts.add(green(percentStr & "/" & windowStr))
  
  # Last response duration
  if lastDuration > 0:
    parts.add(dim("last " & formatFloat(lastDuration, ffDecimal, 0) & "s"))
  
  # Keyboard shortcuts
  parts.add(dim("Tab:mode Esc:abort Ctrl+C:exit"))
  
  # Use dim styling for the entire bar
  let bar = parts.join(dim(" │ "))
  return dim("├─ ") & bar & dim(" ─┤")

proc formatStatusBarWithLive*(mode, model, workDir: string, usagePercent: float, contextWindow: int, lastDuration: float = 0, isStreaming: bool = false): string =
  ## Formats status bar with live indicator
  var parts: seq[string] = @[]
  
  # Mode with emoji and live indicator
  let modeStr = case mode
    of "plan": blue("📝 PLAN")
    of "agent": green("🤖 AGENT")
    of "yolo": red("🚀 YOLO")
    else: "⚙️ " & mode.toUpper
  if isStreaming:
    parts.add(modeStr & " " & yellow("●"))  # Live indicator
  else:
    parts.add(modeStr)
  
  # Model
  parts.add(cyan(model))
  
  # Working directory (short)
  let shortDir = if workDir.len > 30: "..." & workDir[^27..^1] else: workDir
  parts.add(dim(shortDir))
  
  # Context usage
  if contextWindow > 0:
    let percent = usagePercent
    let percentStr = formatFloat(percent, ffDecimal, 1) & "%"
    let windowStr = if contextWindow >= 1000:
      formatFloat(contextWindow.float / 1000.0, ffDecimal, 0) & "k"
    else:
      $contextWindow
    if percent > 80:
      parts.add(red(percentStr & "/" & windowStr))
    elif percent > 50:
      parts.add(yellow(percentStr & "/" & windowStr))
    else:
      parts.add(green(percentStr & "/" & windowStr))
  
  # Last response duration
  if lastDuration > 0:
    parts.add(dim("last " & formatFloat(lastDuration, ffDecimal, 0) & "s"))
  
  # Keyboard shortcuts
  parts.add(dim("Tab:mode Esc:abort Ctrl+C:exit"))
  
  # Use dim styling for the entire bar
  let bar = parts.join(dim(" │ "))
  return dim("├─ ") & bar & dim(" ─┤")
