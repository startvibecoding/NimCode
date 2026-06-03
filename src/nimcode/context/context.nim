import std/[strutils, options]
import ../provider/types

type
  ContextUsage* = object
    tokens*: int           ## Current estimated context tokens
    contextWindow*: int    ## Maximum context window size
    percent*: Option[float] ## Usage percentage, none if unknown

proc estimateTokens*(msg: Message): int =
  ## Estimates token count for a message using chars/4 heuristic.
  ## This is conservative (overestimates tokens).
  var chars = 0
  
  if msg.content != "":
    chars += msg.content.len
  
  # Estimate images as ~4800 chars (~1200 tokens)
  # (not implemented in minimal version)
  
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
