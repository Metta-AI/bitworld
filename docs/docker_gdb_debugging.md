# Debugging Bots with GDB in Docker

When a bot crashes inside its Docker container, the default behavior is a
silent exit or a truncated Nim stack trace. This guide shows how to run bots
under GDB so that crashes produce a full native backtrace automatically.

## Overview

Three changes to a bot's Dockerfile:

1. Compile with debug symbols and line tracing enabled.
2. Install GDB in the runtime image.
3. Replace the CMD with a GDB wrapper that runs the binary and prints a
   backtrace on crash.

## Step-by-step

### 1. Add debug flags to the build stage

In the `RUN nim c ...` command, add these flags:

```dockerfile
RUN nim c \
  -d:release \
  --stackTrace:on \
  --lineTrace:on \
  --debugger:native \
  --nimcache:/tmp/bitworld-nimcache \
  --out:mybot \
  mybot.nim
```

- `--stackTrace:on` keeps Nim stack trace metadata in the binary.
- `--lineTrace:on` includes source file and line numbers.
- `--debugger:native` emits DWARF debug info so GDB can show symbols.

These can coexist with `-d:release` and `--opt:speed`. The binary will be
slightly larger but still optimized.

### 2. Install GDB in the runtime image

For Debian-based images:

```dockerfile
FROM debian:bookworm-slim
RUN apt-get update && \
  apt-get install -y --no-install-recommends gdb && \
  rm -rf /var/lib/apt/lists/*
```

For Alpine-based images:

```dockerfile
FROM alpine
RUN apk add --no-cache gdb
```

### 3. Replace CMD with GDB wrapper

Instead of running the bot directly:

```dockerfile
CMD ["/bin/mybot", "--address:host.docker.internal", "--port:8080"]
```

Wrap it with GDB in batch mode:

```dockerfile
CMD ["gdb", "-batch", "-ex", "run", "-ex", "bt full", "--args", "/bin/mybot", "--address:host.docker.internal", "--port:8080"]
```

This runs the bot normally. If it crashes, GDB catches the signal and prints
a full backtrace with local variables before exiting.

## Example diff

```diff
 RUN nim c \
   -d:release \
+  --stackTrace:on \
+  --lineTrace:on \
+  --debugger:native \
   --nimcache:/tmp/bitworld-nimcache \
   --out:mybot \
   mybot.nim

 FROM alpine
-RUN apk add --no-cache libcurl
+RUN apk add --no-cache libcurl gdb

-CMD ["/bin/mybot", "--address:host.docker.internal", "--port:8080"]
+CMD ["gdb", "-batch", "-ex", "run", "-ex", "bt full", "--args", "/bin/mybot", "--address:host.docker.internal", "--port:8080"]
```

## Reading the output

When the bot crashes, `docker logs <container>` will show GDB output:

```
Program received signal SIGSEGV, Segmentation fault.
0x0000000000401234 in processFrame (bot=..., data=...) at mybot.nim:142
142       let value = data[offset]
#0  0x0000000000401234 in processFrame (bot=..., data=...) at mybot.nim:142
#1  0x0000000000401567 in runBot (address=...) at mybot.nim:200
#2  0x0000000000401890 in NimMainModule () at mybot.nim:250
```

## When to use this

- Bot crashes with no output or just "Error: unhandled exception".
- Investigating segfaults from unsafe Nim code or FFI calls.
- Tournament/validator runs where you only see container logs after the fact.

## Reverting for production

Remove the three debug flags, remove GDB from the runtime image, and restore
the direct CMD. The debug build is slightly larger and GDB adds ~20MB to the
image, so production images should not include it.
