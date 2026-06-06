## Stream callbacks for NimCode CLI
## Handles TUI and print mode output

import std/[json, times]
import ../agent/agent
import ../tui/tui
import ../tui/statusbar

type
  StreamCallbackMode* = enum
    scmTui    ## TUI mode with fixed bottom layout
    scmPrint  ## Simple print mode for -P flag

  StreamCallbackState* = ref object
    mode*: StreamCallbackMode
    tui*: TuiState
    statusBar*: StatusBarState
    # Track output state
    assistantStarted*: bool
    thinkStarted*: bool
    lastRenderTime*: float  ## Throttle TUI renders to avoid flicker

proc newStreamCallbackState*(mode: StreamCallbackMode, tui: TuiState = nil, statusBar: StatusBarState = nil): StreamCallbackState =
  result = StreamCallbackState(
    mode: mode,
    tui: tui,
    statusBar: statusBar,
    assistantStarted: false,
    thinkStarted: false,
    lastRenderTime: 0,
  )

proc shouldRender(state: StreamCallbackState): bool =
  ## Throttle renders to ~50ms to avoid overwhelming the terminal
  ## when tokens arrive faster than the display can refresh
  let now = epochTime()
  if now - state.lastRenderTime > 0.05:
    state.lastRenderTime = now
    return true
  return false

proc forceRender(state: StreamCallbackState) =
  state.lastRenderTime = epochTime()
  state.statusBar.updateStatusBar()

proc tuiStreamCallback*(state: StreamCallbackState, event: AgentEvent) =
  ## TUI mode callback - renders to fixed bottom layout
  case event.kind
  of aekTextDelta:
    if not state.assistantStarted:
      if state.thinkStarted:
        state.tui.addContentLine("")
        state.thinkStarted = false
      state.tui.addContentLine("Assistant: " & event.textDelta)
      state.assistantStarted = true
      if state.statusBar.startTime == 0:
        state.statusBar.startTimer()
    else:
      state.tui.appendToLastLine(event.textDelta)
    if shouldRender(state):
      state.statusBar.updateStatusBar()

  of aekThinkDelta:
    if not state.thinkStarted:
      if state.assistantStarted:
        state.tui.addContentLine("")
        state.assistantStarted = false
      state.tui.addContentLine("think: " & event.thinkDelta)
      state.thinkStarted = true
      if state.statusBar.startTime == 0:
        state.statusBar.startTimer()
    else:
      state.tui.appendToLastLine(event.thinkDelta)
    if shouldRender(state):
      state.statusBar.updateStatusBar()

  of aekToolCall:
    state.assistantStarted = false
    state.thinkStarted = false
    state.tui.addContentLine("")
    state.tui.addContentLine(">> " & event.toolName & " " & $event.toolArgs)
    state.tui.addContentLine("")
    forceRender(state)

  of aekToolResult:
    state.tui.addContentLine("")
    if event.resultIsError:
      state.tui.addContentLine("<< " & event.resultToolName & " error:")
    else:
      state.tui.addContentLine("<< " & event.resultToolName & " result:")
    state.tui.addContentLine(event.resultText)
    state.tui.addContentLine("")
    forceRender(state)

  of aekError:
    state.assistantStarted = false
    state.thinkStarted = false
    state.statusBar.stopTimer()
    state.tui.addContentLine("Error: " & event.errorMsg)
    state.tui.addContentLine("")
    forceRender(state)

  of aekDone:
    state.assistantStarted = false
    state.thinkStarted = false
    state.statusBar.stopTimer()
    state.tui.addContentLine("")
    forceRender(state)

proc printStreamCallback*(state: StreamCallbackState, event: AgentEvent) =
  ## Print mode callback - simple stdout output for -P flag
  case event.kind
  of aekTextDelta:
    if not state.assistantStarted:
      if state.thinkStarted:
        stdout.write("\n")
        state.thinkStarted = false
      stdout.write("\nAssistant: ")
      state.assistantStarted = true
    stdout.write(event.textDelta)
    stdout.flushFile()

  of aekThinkDelta:
    if not state.thinkStarted:
      if state.assistantStarted:
        stdout.write("\n")
        state.assistantStarted = false
      stdout.write("think: ")
      state.thinkStarted = true
    stdout.write(event.thinkDelta)
    stdout.flushFile()

  of aekToolCall:
    state.assistantStarted = false
    state.thinkStarted = false
    stdout.write("\n>> " & event.toolName & " " & $event.toolArgs & "\n")
    stdout.flushFile()

  of aekToolResult:
    let preview = if event.resultText.len > 200: event.resultText[0 ..< 200] & "..." else: event.resultText
    if event.resultIsError:
      stdout.write("<< " & event.resultToolName & " error: " & preview & "\n")
    else:
      stdout.write("<< " & event.resultToolName & " " & preview & "\n")
    stdout.flushFile()

  of aekError:
    state.assistantStarted = false
    state.thinkStarted = false
    stderr.writeLine("\nError: " & event.errorMsg)
    stderr.flushFile()

  of aekDone:
    state.assistantStarted = false
    state.thinkStarted = false
    stdout.write("\n")
    stdout.flushFile()
