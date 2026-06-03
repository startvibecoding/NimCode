# NimCode

NimCode is an AI coding assistant that runs in your terminal, written in pure Nim with no external dependencies.

## Features

- **Pure Nim** — Uses only the Nim standard library, no external dependencies
- **Multiple providers** — Supports OpenAI-compatible APIs (OpenAI, DeepSeek, etc.)
- **Built-in tools** — read, write, edit, bash, ls, grep, find
- **Session persistence** — JSONL session storage for conversation history
- **Multiple modes** — plan (read-only), agent (default), yolo (unrestricted)

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd nimcode

# Compile
nim c -o:bin/nimcode src/nimcode.nim

# Or with release optimizations
nim c -d:release -o:bin/nimcode src/nimcode.nim
```

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
