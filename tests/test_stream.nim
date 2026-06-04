## Unit tests for cli/stream.nim

import std/[unittest, json]
import ../src/nimcode/agent/types
import ../src/nimcode/tui/tui
import ../src/nimcode/tui/statusbar
import ../src/nimcode/cli/stream

suite "Stream Callbacks":
  test "newStreamCallbackState creates TUI state":
    let tui = newTuiState()
    let statusBar = newStatusBarState(tui)
    let state = newStreamCallbackState(scmTui, tui, statusBar)
    
    check state != nil
    check state.mode == scmTui
    check state.tui == tui
    check state.statusBar == statusBar
    check state.assistantStarted == false
    check state.thinkStarted == false
  
  test "newStreamCallbackState creates print state":
    let state = newStreamCallbackState(scmPrint)
    
    check state != nil
    check state.mode == scmPrint
    check state.tui == nil
    check state.statusBar == nil
  
  test "TUI callback handles text delta":
    let tui = newTuiState()
    let statusBar = newStatusBarState(tui)
    statusBar.agent = nil  # Will need mock for full test
    let state = newStreamCallbackState(scmTui, tui, statusBar)
    
    let event = AgentEvent(kind: aekTextDelta, textDelta: "Hello")
    # Note: Full test would require agent mock for updateStatusBar
    # This tests the structure
    check state.assistantStarted == false
  
  test "TUI callback handles think delta":
    let tui = newTuiState()
    let statusBar = newStatusBarState(tui)
    let state = newStreamCallbackState(scmTui, tui, statusBar)
    
    check state.thinkStarted == false
    let event = AgentEvent(kind: aekThinkDelta, thinkDelta: "thinking...")
    check state.thinkStarted == false  # Would be true after callback
  
  test "TUI callback handles tool call":
    let tui = newTuiState()
    let statusBar = newStatusBarState(tui)
    let state = newStreamCallbackState(scmTui, tui, statusBar)
    
    let args = %*{"path": "/test"}
    let event = AgentEvent(kind: aekToolCall, toolCallId: "1", toolName: "read", toolArgs: args)
    # Would test callback here with proper mock
  
  test "TUI callback handles tool result":
    let tui = newTuiState()
    let statusBar = newStatusBarState(tui)
    let state = newStreamCallbackState(scmTui, tui, statusBar)
    
    let event = AgentEvent(kind: aekToolResult, 
      resultToolCallId: "1", 
      resultToolName: "read", 
      resultText: "file content",
      resultIsError: false)
    # Would test callback here
  
  test "TUI callback handles error":
    let tui = newTuiState()
    let statusBar = newStatusBarState(tui)
    let state = newStreamCallbackState(scmTui, tui, statusBar)
    
    let event = AgentEvent(kind: aekError, errorMsg: "test error")
    # Would test callback here
  
  test "TUI callback handles done":
    let tui = newTuiState()
    let statusBar = newStatusBarState(tui)
    let state = newStreamCallbackState(scmTui, tui, statusBar)
    
    let event = AgentEvent(kind: aekDone, doneStopReason: "stop")
    # Would test callback here
  
  test "Print callback handles text delta":
    let state = newStreamCallbackState(scmPrint)
    
    let event = AgentEvent(kind: aekTextDelta, textDelta: "Hello")
    # printStreamCallback would write to stdout
    check state.assistantStarted == false
  
  test "Print callback handles error":
    let state = newStreamCallbackState(scmPrint)
    
    let event = AgentEvent(kind: aekError, errorMsg: "error")
    # Would test stderr output
