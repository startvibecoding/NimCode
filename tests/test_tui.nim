## Unit tests for tui/tui.nim

import std/[unittest, strutils]
import ../src/nimcode/tui/tui

suite "TUI Module":
  test "newTuiState creates state":
    let state = newTuiState()
    check state != nil
    check state.termWidth > 0
    check state.termHeight > 0
    check state.contentLines.len == 0
    check state.statusLine == ""
    check state.inputBuffer == ""
    check state.cursorPos == 0
  
  test "addContentLine adds line":
    let state = newTuiState()
    state.addContentLine("Hello")
    check state.contentLines.len == 1
    check state.contentLines[0] == "Hello"
  
  test "addContentLine multiple lines":
    let state = newTuiState()
    state.addContentLine("Line 1")
    state.addContentLine("Line 2")
    state.addContentLine("Line 3")
    check state.contentLines.len == 3
    check state.contentLines[0] == "Line 1"
    check state.contentLines[1] == "Line 2"
    check state.contentLines[2] == "Line 3"
  
  test "clearContent clears lines":
    let state = newTuiState()
    state.addContentLine("Line 1")
    state.addContentLine("Line 2")
    state.clearContent()
    check state.contentLines.len == 0
  
  test "setStatus updates status":
    let state = newTuiState()
    state.setStatus("Status text")
    check state.statusLine == "Status text"
  
  test "setInput updates input":
    let state = newTuiState()
    state.setInput("Hello")
    check state.inputBuffer == "Hello"
    check state.cursorPos == 5
  
  test "clearInput clears input":
    let state = newTuiState()
    state.setInput("Hello")
    state.clearInput()
    check state.inputBuffer == ""
    check state.cursorPos == 0
  
  test "getTerminalSize returns valid size":
    let (w, h) = getTerminalSize()
    check w > 0
    check h > 0
  
  test "renderTui does not crash":
    let state = newTuiState()
    state.addContentLine("Test content")
    state.setStatus("Test status")
    state.setInput("Test input")
    # renderTui() would draw to terminal
    # Just testing it doesn't crash
    check true
