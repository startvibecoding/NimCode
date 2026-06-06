import std/[json, os, times, strutils, algorithm, sequtils, base64, random]
import ../provider/types

type
  SessionInfo* = object
    path*: string
    modTime*: DateTime
    name*: string
    id*: string
    messageCount*: int
    preview*: string

  Session* = ref object
    file*: string
    messages*: seq[Message]
    cwd*: string
    id*: string

proc encodePath*(p: string): string =
  ## Encode a directory path for use in a session directory name
  return encode(p)

proc generateId*(): string =
  ## Generate a random 8-char hex session ID from secure random bytes
  randomize()
  var bytes: array[4, uint8]
  for i in 0 ..< bytes.len:
    bytes[i] = uint8(rand(256))
  result = ""
  for b in bytes:
    result.add(toHex(b.int))

proc sessionDir*(): string =
  let home = getHomeDir()
  result = home / ".nimcode" / "sessions"

proc getSessionDir*(cwd: string): string =
  return sessionDir()

proc sessionFileId*(path: string): string =
  ## Extract session ID from filename: session_TIMESTAMP_ID.jsonl
  let base = path.extractFilename
  let noExt = base.changeFileExt("")
  let idx = noExt.find("_session_")
  if idx >= 0:
    return noExt[idx + 9 .. ^1]
  return ""

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
      let sessId = sessionFileId(entry)
      result.add(SessionInfo(
        path: entry,
        modTime: info.lastWriteTime.local,
        name: entry.extractFilename,
        id: sessId
      ))
    except CatchableError:
      continue
  
  # Sort by modification time (newest first)
  result.sort(proc (a, b: SessionInfo): int = cmp(b.modTime, a.modTime))

proc loadSession*(file: string): Session =
  result = Session(file: file, messages: @[], cwd: getCurrentDir(), id: sessionFileId(file))
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
            if j.hasKey("cwd"):
              result.cwd = j["cwd"].getStr()
            continue
        except CatchableError:
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
      except CatchableError:
        continue
  except:
    discard

proc newSession*(cwd: string): Session =
  let dir = sessionDir()
  createDir(dir)
  let timestamp = now().format("yyyyMMddHHmmss")
  let id = generateId()
  let file = dir / "session_" & timestamp & "_" & id & ".jsonl"
  result = Session(file: file, messages: @[], cwd: cwd, id: id)
  
  # Write header
  try:
    let header = %*{
      "type": "session",
      "version": 1,
      "id": id,
      "timestamp": $now(),
      "cwd": cwd
    }
    let f = open(file, fmWrite)
    f.writeLine($header)
    f.close()
  except:
    discard

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
  
  # Try to find by ID prefix in filename
  let sessions = listSessionsForDir(cwd)
  var matchIdx = -1
  for i, s in sessions:
    if s.id == value or s.id.startsWith(value):
      if matchIdx >= 0:
        raise newException(CatchableError, "session ID " & value & " is ambiguous")
      matchIdx = i
  
  if matchIdx >= 0:
    return loadSession(sessions[matchIdx].path)
  
  raise newException(CatchableError, "session not found: " & value)

proc deleteSession*(path: string): bool =
  ## Deletes a session file
  try:
    if fileExists(path):
      removeFile(path)
      return true
  except:
    discard
  return false

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

proc getId*(session: Session): string =
  return session.id

proc getSessionInfo*(session: Session): string =
  ## Returns a human-readable session info string
  let fileName = session.file.extractFilename
  let msgCount = session.messages.len
  result = "Session: " & fileName & " (" & $msgCount & " messages)"
  if session.id != "":
    result.add(" [" & session.id & "]")
