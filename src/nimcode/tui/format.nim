import std/[terminal, strutils]

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

proc formatToolCall*(toolName: string, args: string): string =
  ## Formats a tool call for display
  let argsPreview = if args.len > 100: args[0 ..< 100] & "..." else: args
  return "[" & bold(toolName) & "] " & dim(argsPreview)

proc formatToolResult*(toolName: string, text: string, isError: bool = false): string =
  ## Formats a tool result for display
  if isError:
    return "[" & red(toolName) & "] " & red(text)
  else:
    let preview = if text.len > 100: text[0 ..< 100] & "..." else: text
    return "[" & green(toolName) & "] " & dim(preview)

proc formatError*(msg: string): string =
  ## Formats an error message
  return red("Error: ") & msg

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
