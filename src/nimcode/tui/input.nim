## Terminal raw mode input handling for NimCode
## Supports Tab key interception and Chinese IME via UTF-8

import std/[posix, termios]

# Terminal raw mode state
var gOrigTermios: Termios
var gRawModeEnabled = false

proc enableRawMode*() =
  ## Enable terminal raw mode for non-blocking input
  if isatty(0) == 0: return
  if tcgetattr(0, addr gOrigTermios) == -1: return
  var raw = gOrigTermios
  raw.c_iflag = raw.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  raw.c_oflag = raw.c_oflag and not OPOST
  raw.c_cflag = raw.c_cflag or CS8
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or IEXTEN or ISIG)
  raw.c_cc[VMIN] = 1.char
  raw.c_cc[VTIME] = 0.char
  if tcsetattr(0, TCSAFLUSH, addr raw) == -1: return
  gRawModeEnabled = true

proc disableRawMode*() =
  ## Disable terminal raw mode, restore original settings
  if gRawModeEnabled:
    discard tcsetattr(0, TCSAFLUSH, addr gOrigTermios)
    gRawModeEnabled = false

proc readUtf8Char*(): string =
  ## Read one UTF-8 character (may be multi-byte for Chinese, etc.)
  var buf: array[4, char]
  if read(0, addr buf[0], 1) != 1: return ""
  
  let b = buf[0].ord
  var len = 1
  if (b and 0xE0) == 0xC0: len = 2
  elif (b and 0xF0) == 0xE0: len = 3
  elif (b and 0xF8) == 0xF0: len = 4
  
  for i in 1 ..< len:
    if read(0, addr buf[i], 1) != 1: break
  
  result = newString(len)
  for i in 0 ..< len:
    result[i] = buf[i]

proc readLineWithTab*(): tuple[line: string, tabPressed: bool] =
  ## Read line with raw mode, intercept Tab for mode cycling
  ## Supports Chinese IME via proper UTF-8 handling
  enableRawMode()
  defer: disableRawMode()
  
  var buffer = ""
  while true:
    let ch = readUtf8Char()
    if ch.len == 0: continue
    
    # Single byte special keys
    if ch.len == 1:
      case ch[0]
      of '\t':  # Tab - mode cycling
        return ("", true)
      of '\n', '\r':  # Enter - submit
        return (buffer, false)
      of '\x7f', '\b':  # Backspace
        if buffer.len > 0:
          # Find last UTF-8 character boundary
          var lastLen = 1
          var i = buffer.len - 1
          while i > 0 and (buffer[i].ord and 0xC0) == 0x80:
            dec i
            inc lastLen
          buffer.setLen(buffer.len - lastLen)
          stdout.write("\b \b")
          stdout.flushFile()
      of '\x03':  # Ctrl+C
        disableRawMode()
        quit(0)
      of '\x04':  # Ctrl+D
        if buffer.len == 0:
          disableRawMode()
          quit(0)
      of '\x1b':  # ESC or escape sequence
        discard  # Ignore for now
      else:
        if ch[0] >= ' ':
          buffer.add(ch)
          stdout.write(ch)
          stdout.flushFile()
    else:
      # Multi-byte UTF-8 (Chinese, Japanese, Korean, emoji, etc.)
      buffer.add(ch)
      stdout.write(ch)
      stdout.flushFile()
