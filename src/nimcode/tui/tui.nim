## Simple TUI module for NimCode
## Provides a fixed bottom status bar and input area

import std/[terminal, strutils, os]

type
  TuiState* = ref object
    termWidth*: int
    termHeight*: int
    contentLines*: seq[string]  ## Scrolling content above
    statusLine*: string         ## Status bar text
    inputBuffer*: string        ## Current input text
    cursorPos*: int             ## Cursor position in input

proc newTuiState*(): TuiState =
  let (w, h) = terminalSize()
  result = TuiState(
    termWidth: w,
    termHeight: h,
    contentLines: @[],
    statusLine: "",
    inputBuffer: "",
    cursorPos: 0,
  )

proc clearLine() =
  stdout.write("\r")
  stdout.write("\x1b[2K")  # Clear entire line
  stdout.flushFile()

proc moveCursorTo(row, col: int) =
  stdout.write("\x1b[" & $row & ";" & $col & "H")
  stdout.flushFile()

proc saveCursorPos() =
  stdout.write("\x1b[s")
  stdout.flushFile()

proc restoreCursorPos() =
  stdout.write("\x1b[u")
  stdout.flushFile()

proc hideCursor() =
  stdout.write("\x1b[?25l")
  stdout.flushFile()

proc showCursor() =
  stdout.write("\x1b[?25h")
  stdout.flushFile()

proc getTerminalSize*(): tuple[width, height: int] =
  let (w, h) = terminalSize()
  return (w, h)

proc renderTui*(state: TuiState) =
  ## Render the TUI with content, status bar, and input at bottom
  let (w, h) = terminalSize()
  state.termWidth = w
  state.termHeight = h
  
  # Calculate positions
  # Bottom 2 lines: input + status bar
  let inputRow = h - 1
  let statusRow = h
  let contentEndRow = h - 2
  
  # Save cursor and hide it during render
  hideCursor()
  
  # Render content (scrolling area)
  let startLine = max(0, state.contentLines.len - contentEndRow)
  for i in 0 ..< contentEndRow:
    moveCursorTo(i + 1, 1)
    clearLine()
    let lineIdx = startLine + i
    if lineIdx < state.contentLines.len:
      let line = state.contentLines[lineIdx]
      if line.len > w:
        stdout.write(line[0 ..< w])
      else:
        stdout.write(line)
  
  # Render status bar (second to last line)
  moveCursorTo(statusRow, 1)
  clearLine()
  stdout.write("\x1b[7m")  # Reverse video for status bar
  let statusText = if state.statusLine.len > w: state.statusLine[0 ..< w] else: state.statusLine
  stdout.write(statusText)
  # Pad to fill width
  if statusText.len < w:
    stdout.write(" ".repeat(w - statusText.len))
  stdout.write("\x1b[0m")  # Reset attributes
  
  # Render input line (last line)
  moveCursorTo(inputRow, 1)
  clearLine()
  stdout.write("> " & state.inputBuffer)
  
  # Show cursor at input position
  showCursor()
  moveCursorTo(inputRow, 3 + state.cursorPos)
  
  stdout.flushFile()

proc addContentLine*(state: TuiState, line: string) =
  ## Add a line to the scrolling content area, splitting on newlines
  ## so each terminal row is exactly one content line
  if line.len == 0:
    state.contentLines.add("")
    return
  let parts = line.splitLines()
  for part in parts:
    state.contentLines.add(part)

proc appendToLastLine*(state: TuiState, text: string) =
  ## Append text to the last content line, splitting on newlines.
  ## Used for streaming text deltas that may contain embedded newlines.
  if text.len == 0:
    return
  if state.contentLines.len == 0:
    state.addContentLine(text)
    return
  let parts = text.splitLines()
  state.contentLines[^1].add(parts[0])
  for i in 1 ..< parts.len:
    state.contentLines.add(parts[i])

proc clearContent*(state: TuiState) =
  ## Clear all content
  state.contentLines = @[]

proc setStatus*(state: TuiState, status: string) =
  ## Update the status bar text
  state.statusLine = status

proc setInput*(state: TuiState, text: string) =
  ## Set the input buffer text
  state.inputBuffer = text
  state.cursorPos = text.len

proc clearInput*(state: TuiState) =
  ## Clear the input buffer
  state.inputBuffer = ""
  state.cursorPos = 0
