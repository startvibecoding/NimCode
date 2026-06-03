import std/[json, os, times, strutils, algorithm, sequtils, base64]
import ../provider/types

type
  SessionInfo* = object
    path*: string
    modTime*: DateTime
    name*: string

  Session* = ref object
    file*: string
    messages*: seq[Message]
    cwd*: string

proc encodePath*(p: string): string =
  ## Encode a directory path for use in a session directory name
  return encode(p)

proc sessionDir*(): string =
  let home = getHomeDir()
  result = home / ".nimcode" / "sessions"

proc getSessionDir*(cwd: string): string =
  return sessionDir()

proc newSession*(cwd: string): Session =
  let dir = sessionDir()
  createDir(dir)
  let timestamp = now().format("yyyyMMddHHmmss")
  let file = dir / "session_" & timestamp & ".jsonl"
  result = Session(file: file, messages: @[], cwd: cwd)
  
  # Write header
  try:
    let header = %*{
      "type": "session",
      "version": 1,
      "timestamp": $now(),
      "cwd": cwd
    }
    let f = open(file, fmWrite)
    f.writeLine($header)
    f.close()
  except:
    discard

proc loadSession*(file: string): Session =
  result = Session(file: file, messages: @[], cwd: getCurrentDir())
  if not fileExists(file):
    return
  
  try:
    let content = readFile(file)
    var isFirstLine = true
    for line in content.splitLines():
      if line.strip() == "":
        continue
      
      # Skip header line
      if isFirstLine:
        isFirstLine = false
        try:
          let j = parseJson(line)
          if j.hasKey("type") and j["type"].getStr() == "session":
            continue
        except:
          discard
      
      try:
        let j = parseJson(line)
        if j.hasKey("role"):
          let role = case j["role"].getStr()
            of "user": mrUser
            of "assistant": mrAssistant
            of "toolResult": mrToolResult
            else: mrUser
          
          result.messages.add(Message(
            role: role,
            content: j{"content"}.getStr(""),
            toolCallId: j{"toolCallId"}.getStr(""),
            toolName: j{"toolName"}.getStr(""),
            isError: j{"isError"}.getBool(false)
          ))
      except:
        continue
  except:
    discard

proc listSessionsForDir*(cwd: string): seq[SessionInfo] =
  ## Lists session files for a given working directory
  result = @[]
  let dir = sessionDir()
  
  if not dirExists(dir):
    return
  
  for kind, entry in walkDir(dir):
    if kind != pcFile:
      continue
    if not entry.endsWith(".jsonl"):
      continue
    
    try:
      let info = getFileInfo(entry)
      result.add(SessionInfo(
        path: entry,
        modTime: info.lastWriteTime.local,
        name: entry.extractFilename
      ))
    except:
      continue
  
  # Sort by modification time (newest first)
  result.sort(proc (a, b: SessionInfo): int = cmp(b.modTime, a.modTime))

proc continueRecent*(cwd: string): Session =
  ## Continues the most recent session for a directory, or creates new
  let sessions = listSessionsForDir(cwd)
  
  if sessions.len > 0:
    return loadSession(sessions[0].path)
  
  return newSession(cwd)

proc openByPathOrID*(cwd, value: string): Session =
  ## Opens a session using either an explicit file path or a session ID
  if value == "":
    raise newException(CatchableError, "session value is empty")
  
  if value.endsWith(".jsonl") or value.contains($DirSep):
    return loadSession(value)
  
  # Try to find by ID in filename
  let sessions = listSessionsForDir(cwd)
  for s in sessions:
    if s.name.contains(value):
      return loadSession(s.path)
  
  raise newException(CatchableError, "session not found: " & value)

proc appendMessage*(session: Session, msg: Message) =
  session.messages.add(msg)
  
  var j = %*{
    "role": $msg.role,
    "content": msg.content,
    "timestamp": $now()
  }
  
  if msg.toolCallId != "":
    j["toolCallId"] = %msg.toolCallId
  if msg.toolName != "":
    j["toolName"] = %msg.toolName
  if msg.isError:
    j["isError"] = %true
  
  try:
    let f = open(session.file, fmAppend)
    f.writeLine($j)
    f.close()
  except:
    discard

proc getMessages*(session: Session): seq[Message] =
  return session.messages

proc getFile*(session: Session): string =
  return session.file

proc getSessionInfo*(session: Session): string =
  ## Returns a human-readable session info string
  let fileName = session.file.extractFilename
  let msgCount = session.messages.len
  return "📂 Session: " & fileName & " (" & $msgCount & " messages)"
