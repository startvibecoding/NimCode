# NimCode

NimCode is an AI coding assistant that runs in your terminal, written in pure Nim with no external dependencies.

## Features

- **Pure Nim** — Uses only the Nim standard library, no external dependencies
- **Multiple providers** — Supports OpenAI-compatible APIs (OpenAI, DeepSeek, etc.)
- **Built-in tools** — read, write, edit, bash, ls, grep, find
- **Session persistence** — JSONL session storage for conversation history
- **Multiple modes** — plan (read-only), agent (default), yolo (unrestricted)

## Supported Platforms

| Platform | amd64 | arm64 | Notes |
|----------|-------|-------|-------|
| Linux | ✓ | ✓ | Primary targets |
| Windows | ✓ | ○ | amd64 ready; arm64 needs cross-compiler |
| macOS | ○ | ○ | Cross-compilation requires Zig or osxcross |
| Linux (loongarch64) | ○ | — | `--cpu:loongarch64` supported by Nim 2.2+ |

## Prerequisites

### Required

- [Nim](https://nim-lang.org/) >= 2.0.0
- `gcc` (for Linux amd64 native builds)

### For cross-compilation (release builds)

The following packages provide the cross-compilers used by `./scripts/build-cross-platform.sh`:

**Debian 12 / Ubuntu 22.04+:**

```bash
# Linux amd64 (native) + arm64 (cross)
sudo apt-get install -y gcc gcc-aarch64-linux-gnu libc6-dev-arm64-cross

# Windows amd64 (cross)
sudo apt-get install -y mingw-w64

# Optional: all platforms with one tool (recommended)
# Install Zig and it will handle linux-arm64, windows-arm64, macOS, loongarch64
wget https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz
tar -xf zig-linux-x86_64-0.14.0.tar.xz
sudo mv zig-linux-x86_64-0.14.0 /opt/zig
sudo ln -s /opt/zig/zig /usr/local/bin/zig
```

**Package reference by target:**

| Target | Debian/Ubuntu Package |
|--------|----------------------|
| linux-amd64 | `gcc` (native) |
| linux-arm64 | `gcc-aarch64-linux-gnu` + `libc6-dev-arm64-cross` |
| linux-arm | `gcc-arm-linux-gnueabihf` + `libc6-dev-armhf-cross` |
| linux-loongarch64 | `gcc-loongarch64-linux-gnu` (Debian 13+/unstable) |
| windows-amd64 | `mingw-w64` |
| windows-arm64 | `mingw-w64` (>= 10.0, Debian 12+) |
| macos-amd64/arm64 | No Debian package; use **Zig** or [osxcross](https://github.com/tpoechtrager/osxcross) |

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd nimcode

# Compile (native Linux amd64)
nim c -d:ssl -o:bin/nimcode src/nimcode.nim

# Or with release optimizations
nim c -d:ssl -d:release --opt:size -o:bin/nimcode src/nimcode.nim
```

## Release Build (cross-platform)

Build binaries for all supported platforms, plus `.deb` and npm packages:

```bash
# Build everything
make release

# Or individual targets
make cross-compile   # Cross-platform binaries
make package-deb     # Debian package (host arch)
make package-npm     # npm tarball (no publish)
```

Outputs are placed in `dist/`.

## Configuration

Create a configuration file at `~/.nimcode/settings.json`:

```json
{
  "defaultProvider": "deepseek",
  "defaultModel": "deepseek-chat",
  "defaultMode": "agent"
}
```

Or use environment variables:
- `NIMCODE_PROVIDER` — Default provider
- `NIMCODE_MODEL` — Default model
- `OPENAI_API_KEY` — OpenAI API key
- `DEEPSEEK_API_KEY` — DeepSeek API key

## Usage

```bash
# Interactive mode
./bin/nimcode

# With specific provider and model
./bin/nimcode -p deepseek -m deepseek-chat

# YOLO mode (all tools auto-execute)
./bin/nimcode -M yolo

# Print mode (non-interactive)
./bin/nimcode --print "explain this code"

# Continue most recent session
./bin/nimcode -c
```

## Built-in Tools

- **read** — Read file contents (supports text and images)
- **write** — Write content to files
- **edit** — Edit files using exact text replacement
- **bash** — Execute shell commands
- **ls** — List directory contents
- **grep** — Search file contents using regex
- **find** — Find files by name pattern

## Modes

- **plan** — Read-only mode. Analyze code and create plans without modifying files.
- **agent** — Default mode. Read/write files and execute commands.
- **yolo** — Unrestricted mode. All tools auto-execute without approval.

## Development

```bash
# Compile
nim c src/nimcode.nim

# Run tests
nim c -r tests/test_xxx.nim
```

## License

MIT
