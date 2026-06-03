import std/[os, strutils, times]

type
  Memory* = ref object
    path*: string       ## Path to memory.md
    content*: string    ## Current content

proc newMemory*(path: string): Memory =
  result = Memory(path: path)
  
  # Load existing content if file exists
  if fileExists(path):
    try:
      result.content = readFile(path)
    except:
      result.content = ""

proc append*(m: Memory, entry: string) =
  ## Appends a new memory entry
  let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
  let formattedEntry = "\n## " & timestamp & "\n\n" & entry & "\n"
  
  m.content.add(formattedEntry)
  
  try:
    let dir = m.path.parentDir
    if not dirExists(dir):
      createDir(dir)
    writeFile(m.path, m.content)
  except:
    discard

proc search*(m: Memory, query: string): seq[string] =
  ## Searches memory for entries containing the query
  result = @[]
  let queryLower = query.toLower
  
  var currentEntry = ""
  for line in m.content.splitLines():
    if line.startsWith("## "):
      if currentEntry != "" and currentEntry.toLower.contains(queryLower):
        result.add(currentEntry)
      currentEntry = line
    else:
      currentEntry.add("\n" & line)
  
  # Check last entry
  if currentEntry != "" and currentEntry.toLower.contains(queryLower):
    result.add(currentEntry)

proc getContext*(m: Memory, maxEntries: int = 10): string =
  ## Gets recent memory entries for context
  if m.content == "":
    return ""
  
  var entries: seq[string] = @[]
  var currentEntry = ""
  
  for line in m.content.splitLines():
    if line.startsWith("## "):
      if currentEntry != "":
        entries.add(currentEntry)
      currentEntry = line
    else:
      currentEntry.add("\n" & line)
  
  if currentEntry != "":
    entries.add(currentEntry)
  
  # Return most recent entries
  let startIdx = max(0, entries.len - maxEntries)
  result = "\n## Memory (Recent Context)\n\n"
  for i in startIdx ..< entries.len:
    result.add(entries[i] & "\n")
