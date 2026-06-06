# Package
version       = "0.1.2"
author        = "NimCode"
description   = "NimCode - AI coding assistant in terminal"
license       = "MIT"
srcDir        = "src"
bin           = @["nimcode"]

# Dependencies
requires "nim >= 2.0.0"

# Tasks
task build_release, "Build release binary":
  exec "nim c -d:release -o:bin/nimcode src/nimcode.nim"
