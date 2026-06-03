import std/[strutils, options]
import ../provider/types

type
  ContextUsage* = object
    tokens*: int           ## Current estimated context tokens
    contextWindow*: int    ## Maximum context window size
    percent*: Option[float] ## Usage percentage, none if unknown

  CompactionSettings* = object
    enabled*: bool
    reserveTokens*: int     ## Tokens reserved for output
    keepRecentTokens*: int  ## Tokens worth of recent messages to keep

  CompactionResult* = object
    summary*: string        ## Generated summary of old messages
    firstKeptIndex*: int    ## Index of first message to keep
    tokensBefore*: int      ## Token count before compaction

proc estimateTokens*(msg: Message): int =
  ## Estimates token count for a message using chars/4 heuristic.
  ## This is conservative (overestimates tokens).
  var chars = 0
  
  if msg.content != "":
    chars += msg.content.len
  
  return (chars + 3) div 4  # ceil(chars/4)

proc estimateContextTokens*(messages: seq[Message]): int =
  ## Estimates context tokens from messages.
  var total = 0
  for msg in messages:
    total += estimateTokens(msg)
  return total

proc shouldCompact*(contextTokens: int, contextWindow: int, reserveTokens: int): bool =
  ## Checks if compaction should trigger based on context usage.
  if contextWindow <= 0:
    return false
  return contextTokens > contextWindow - reserveTokens

proc getContextUsage*(messages: seq[Message], contextWindow: int): ContextUsage =
  ## Calculates and returns the current context usage.
  let tokens = estimateContextTokens(messages)
  
  if contextWindow <= 0:
    return ContextUsage(
      tokens: tokens,
      contextWindow: 0,
      percent: none(float)
    )
  
  let percent = tokens.float / contextWindow.float * 100.0
  return ContextUsage(
    tokens: tokens,
    contextWindow: contextWindow,
    percent: some(percent)
  )

proc findCutPoint*(messages: seq[Message], keepRecentTokens: int): int =
  ## Finds the cut point that keeps approximately keepRecentTokens worth of recent messages.
  ## Returns the index of the first message to KEEP (everything before is summarized).
  ## Never cuts at tool result messages.
  if messages.len == 0:
    return 0
  
  # Find valid cut points (user/assistant messages, not tool results)
  var validCutPoints: seq[int] = @[]
  for i in 0 ..< messages.len:
    if messages[i].role in [mrUser, mrAssistant]:
      validCutPoints.add(i)
  
  if validCutPoints.len == 0:
    return 0
  
  # Walk backwards, accumulating token sizes
  var accumulated = 0
  var cutIndex = validCutPoints[0]
  
  for i in countdown(messages.len - 1, 0):
    accumulated += estimateTokens(messages[i])
    if accumulated >= keepRecentTokens:
      # Find closest valid cut point
      var bestCut = validCutPoints[0]
      var bestDist = abs(bestCut - i)
      for c in validCutPoints:
        let dist = abs(c - i)
        if dist < bestDist:
          bestDist = dist
          bestCut = c
      cutIndex = bestCut
      break
  
  return cutIndex

proc serializeMessages*(messages: seq[Message]): string =
  ## Serializes messages to text for summarization.
  result = ""
  for msg in messages:
    case msg.role
    of mrUser:
      result.add("User: " & msg.content & "\n\n")
    of mrAssistant:
      result.add("Assistant: " & msg.content & "\n\n")
    of mrToolResult:
      result.add("Tool [" & msg.toolName & "]: " & msg.content & "\n\n")

proc defaultCompactionSettings*(): CompactionSettings =
  CompactionSettings(
    enabled: true,
    reserveTokens: 16384,
    keepRecentTokens: 20000,
  )
