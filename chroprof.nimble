mode = ScriptMode.Verbose

packageName = "chroprof"
version     = "0.1.0"
author      = "Status Research & Development GmbH"
description = "A profiling tool for the Chronos networking framework"
license     = "MIT or Apache License 2.0"
skipDirs    = @["tests"]

requires  "nim >= 1.6.16",
          "https://github.com/codex-storage/nim-chronos#feature/profiler-v4",
          "metrics >= 0.1.0"

task test, "Run tests":
  exec "nim c --out:./build/testall -r tests/testall.nim"