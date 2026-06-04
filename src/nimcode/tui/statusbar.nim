## Status bar and TUI state management for NimCode
## Provides fixed bottom layout with status bar and input

import std/[strutils, times, options]
import ./tui
import ./format
import ../agent/agent

type
  StatusBarState* = ref object
    tui*: TuiState
    agent*: Agent
    mode*: string
    modelName*: string
    cwd*: string
    lastDuration*: float
    startTime*: float
    isStreaming*: bool

proc newStatusBarState*(tui: TuiState): StatusBarState =
  result = StatusBarState(
    tui: tui,
    lastDuration: 0,
    startTime: 0,
    isStreaming: false,
  )

proc getUsageInfo(agent: Agent): tuple[percent: float, window: int] =
  let usage = agent.getContextUsage()
  let percent = if usage.percent.isSome: usage.percent.get else: 0.0
  let window = if usage.contextWindow > 0: usage.contextWindow else: 128000
  return (percent, window)

proc buildStatusBarText*(mode, modelName, cwd: string, usagePercent: float, contextWindow: int, elapsed: float = 0, isStreaming: bool = false): string =
  var parts: seq[string] = @[]
  
  # Mode with emoji
  let modeStr = case mode
    of "plan": "📝 PLAN"
    of "agent": "🤖 AGENT"
    of "yolo": "🚀 YOLO"
    else: "⚙️ " & mode.toUpper
  if isStreaming:
    parts.add(modeStr & " ●")
  else:
    parts.add(modeStr)
  
  parts.add(modelName)
  
  let shortDir = if cwd.len > 25: "..." & cwd[^22..^1] else: cwd
  parts.add(shortDir)
  
  if contextWindow > 0:
    let percentStr = formatFloat(usagePercent, ffDecimal, 1) & "%"
    let windowStr = if contextWindow >= 1000:
      formatFloat(contextWindow.float / 1000.0, ffDecimal, 0) & "k"
    else:
      $contextWindow
    parts.add(percentStr & "/" & windowStr)
  
  # Show elapsed time (live during streaming, last after done)
  if elapsed > 0:
    if isStreaming:
      parts.add(formatFloat(elapsed, ffDecimal, 0) & "s")
    else:
      parts.add("last " & formatFloat(elapsed, ffDecimal, 0) & "s")
  
  parts.add("Tab:mode Esc:abort Ctrl+C:exit")
  
  return parts.join(" │ ")

proc updateStatusBar*(state: StatusBarState) =
  ## Update and render the status bar
  let (percent, window) = getUsageInfo(state.agent)
  let elapsed = if state.isStreaming and state.startTime > 0:
    epochTime() - state.startTime
  else:
    state.lastDuration
  let statusText = buildStatusBarText(
    state.mode, state.modelName, state.cwd,
    percent, window, elapsed, state.isStreaming
  )
  state.tui.setStatus(statusText)
  state.tui.renderTui()

proc startTimer*(state: StatusBarState) =
  ## Start the elapsed time timer
  state.startTime = epochTime()
  state.isStreaming = true

proc stopTimer*(state: StatusBarState) =
  ## Stop the timer and record duration
  if state.startTime > 0:
    state.lastDuration = epochTime() - state.startTime
    state.startTime = 0
  state.isStreaming = false

proc getElapsed*(state: StatusBarState): float =
  ## Get current elapsed time
  if state.isStreaming and state.startTime > 0:
    return epochTime() - state.startTime
  return state.lastDuration
