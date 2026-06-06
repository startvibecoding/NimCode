## Unit tests for tui/statusbar.nim

import std/[unittest, strutils, times, options, os]
import ../src/nimcode/tui/tui
import ../src/nimcode/tui/statusbar
import ../src/nimcode/tui/format

import std/unicode

proc hasBraille(s: string): bool =
  for r in s.runes:
    let code = int(r)
    if code >= 0x2800 and code <= 0x28FF:
      return true
  return false

suite "Status Bar":
  test "buildStatusBarText basic format":
    let text = buildStatusBarText(
      "yolo", "test-model", "/home/test",
      50.0, 128000, 0, false
    )
    check "YOLO" in text
    check "test-model" in text
    check "50.0%" in text
    check "Tab:mode" in text
  
  test "buildStatusBarText shows elapsed during streaming":
    let text = buildStatusBarText(
      "agent", "model", "/dir",
      10.0, 100000, 5.0, true
    )
    check ".s" in text  # Format is "5.s"
    check hasBraille(text)  # Streaming spinner indicator

  test "buildStatusBarText shows last after done":
    let text = buildStatusBarText(
      "agent", "model", "/dir",
      10.0, 100000, 30.0, false
    )
    check "last" in text
    check ".s" in text  # Format is "last 30.s"
    check not hasBraille(text)  # No spinner when not streaming
  
  test "buildStatusBarText truncates long directory":
    let longDir = "/home/user/very/long/path/that/should/be/truncated"
    let text = buildStatusBarText(
      "plan", "model", longDir,
      0.0, 0, 0, false
    )
    check "..." in text
  
  test "buildStatusBarText plan mode":
    let text = buildStatusBarText("plan", "m", "/d", 0, 0, 0, false)
    check "PLAN" in text
  
  test "buildStatusBarText agent mode":
    let text = buildStatusBarText("agent", "m", "/d", 0, 0, 0, false)
    check "AGENT" in text
  
  test "buildStatusBarText yolo mode":
    let text = buildStatusBarText("yolo", "m", "/d", 0, 0, 0, false)
    check "YOLO" in text
  
  test "buildStatusBarText context window formatting":
    let text = buildStatusBarText("agent", "m", "/d", 25.5, 128000, 0, false)
    check "25.5" in text
    check ".k" in text  # Format is "128.k"
  
  test "buildStatusBarText small context window":
    let text = buildStatusBarText("agent", "m", "/d", 50.0, 500, 0, false)
    check "500" in text
  
  test "newStatusBarState creates state":
    let tui = newTuiState()
    let state = newStatusBarState(tui)
    check state != nil
    check state.tui == tui
    check state.lastDuration == 0
    check state.startTime == 0
    check state.isStreaming == false
  
  test "startTimer and stopTimer":
    let tui = newTuiState()
    let state = newStatusBarState(tui)
    
    state.startTimer()
    check state.isStreaming == true
    check state.startTime > 0
    
    sleep(10)  # Small delay
    state.stopTimer()
    check state.isStreaming == false
    check state.lastDuration > 0
  
  test "getElapsed during streaming":
    let tui = newTuiState()
    let state = newStatusBarState(tui)
    
    state.startTimer()
    sleep(10)
    let elapsed = state.getElapsed()
    check elapsed > 0
  
  test "getElapsed after stop":
    let tui = newTuiState()
    let state = newStatusBarState(tui)
    
    state.startTimer()
    sleep(10)
    state.stopTimer()
    let elapsed = state.getElapsed()
    check elapsed > 0
