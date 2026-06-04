## Stream callbacks for NimCode CLI
## Handles TUI and print mode output

import std/[json]
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

proc newStreamCallbackState*(mode: StreamCallbackMode, tui: TuiState = nil, statusBar: StatusBarState = nil): StreamCallbackState =
  result = StreamCallbackState(
    mode: mode,
    tui: tui,
    statusBar: statusBar,
    assistantStarted: false,
    thinkStarted: false,
  )

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
      if state.tui.contentLines.len > 0:
        state.tui.contentLines[^1].add(event.textDelta)
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
      if state.tui.contentLines.len > 0:
        state.tui.contentLines[^1].add(event.thinkDelta)
    state.statusBar.updateStatusBar()
  
  of aekToolCall:
    state.assistantStarted = false
    state.thinkStarted = false
    state.tui.addContentLine("")
    state.tui.addContentLine(">> " & event.toolName & " " & $event.toolArgs)
    state.tui.addContentLine("")
    state.statusBar.updateStatusBar()
  
  of aekToolResult:
    let preview = if event.resultText.len > 100: event.resultText[0 ..< 100] & "..." else: event.resultText
    if event.resultIsError:
      state.tui.addContentLine("<< " & event.resultToolName & " error: " & preview)
    else:
      state.tui.addContentLine("<< " & event.resultToolName & " " & preview)
    state.tui.addContentLine("")
    state.statusBar.updateStatusBar()
  
  of aekError:
    state.assistantStarted = false
    state.thinkStarted = false
    state.statusBar.stopTimer()
    state.tui.addContentLine("Error: " & event.errorMsg)
    state.tui.addContentLine("")
    state.statusBar.updateStatusBar()
  
  of aekDone:
    state.assistantStarted = false
    state.thinkStarted = false
    state.statusBar.stopTimer()
    state.tui.addContentLine("")
    state.statusBar.updateStatusBar()

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
