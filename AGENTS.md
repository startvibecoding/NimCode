# NimCode Agent Guide

This file is for AI agents working in this repository. Keep changes aligned with the current codebase and prefer concise, minimal edits.

## Project Snapshot

- Language: Nim (pure std library, no external dependencies)
- UI: Terminal-first interactive CLI
- Default working style: terminal-first, tool-driven
- Main purpose: a terminal AI coding assistant with provider abstraction, sessions, and built-in tools

## Important Directories

- `src/nimcode.nim` — CLI entry point
- `src/nimcode/config/` — settings and defaults
- `src/nimcode/provider/` — provider abstraction (OpenAI, Anthropic compatible)
- `src/nimcode/agent/` — agent loop, events, system prompt
- `src/nimcode/tools/` — built-in tools (read, write, edit, bash, ls, grep, find, plan, jobs, kill)
- `src/nimcode/session/` — JSONL session storage
- `src/nimcode/contextfiles/` — AGENTS.md / CLAUDE.md discovery
- `src/nimcode/context/` — token estimation and context management
- `src/nimcode/skills/` — skills loading
- `src/nimcode/memory/` — persistent memory (memory.md)
- `tests/` — test files
- `bin/` — compiled binaries

## Architecture Notes

- Providers stream responses through the provider abstraction.
- The agent loop builds a system prompt, sends messages, handles stream events, executes tools, and continues until completion.
- Tools should stay stateless when possible; shared execution state belongs in registries.
- Sessions are stored as JSONL.
- Context files (AGENTS.md, CLAUDE.md, .cursorrules) are automatically loaded from project, parent, and global directories.
- Skills are loaded from `.skills/` (project) and `~/.nimcode/skills/` (global).
- Memory is stored in `~/.nimcode/memory.md`.

## Working Rules

- **Minimize external dependencies.** Prefer Nim std library (`std/httpclient`, `std/json`, `std/strutils`, `std/os`, `std/options`, etc.) over third-party Nimble packages. Only introduce an external dependency when the std lib genuinely cannot accomplish the task, and document the reason.
- Read before editing.
- Prefer small, targeted changes.
- Keep behavior consistent with existing patterns.
- Do not introduce broad refactors unless requested.
- Do not add license headers unless the repository already uses them.
- Do not auto-commit. Commit only when the user explicitly asks.

## Nim Conventions

- Use `result` or explicit return; avoid implicit returns for clarity.
- Prefer `let` over `var` when values don't change.
- Use `proc` for functions, `func` for pure functions (no side effects).
- Use `method` only for dynamic dispatch on object types.
- Follow existing naming: `camelCase` for procs/vars, `PascalCase` for types/objects, `SCREAMING_SNAKE_CASE` for constants.
- Use `Option[T]` from `std/options` for nullable values instead of nil pointers.
- Prefer `seq[T]` over arrays for dynamic collections.
- Use `string` for text; avoid `cstring` unless interfacing with C.
- Keep modules focused — one primary concern per file.
- Use `import` for standard library, `from ... import` for selective imports.
- Handle errors with `try`/`except` or `Result` types; do not use `quit` for normal error handling.
- Add doc comments with `##` for public procs and types.

## Tooling Notes

Built-in tools include:
- `read` — Read file contents (supports text and images)
- `write` — Write content to files
- `edit` — Edit files using exact text replacement
- `bash` — Execute shell commands
- `ls` — List directory contents
- `grep` — Search file contents using regex
- `find` — Find files by name pattern
- `plan` — Publish or update a structured task plan
- `jobs` — List background jobs
- `kill` — Kill a running background job

## Modes and Safety

- `plan`: read-only tools
- `agent`: all tools allowed
- `yolo`: all tools auto-execute (same as agent for now)

When changing code, prefer the least risky approach that satisfies the request.

## Validation

When appropriate, verify with the smallest useful scope first.
Examples:
- `nim c src/nimcode.nim` to verify compilation
- `./bin/nimcode --help` to verify the binary works

## Build / Test

Common commands:
- `nim c src/nimcode.nim` — compile the project
- `nim c -o:bin/nimcode src/nimcode.nim` — compile to bin/nimcode
- `nim c -d:release -o:bin/nimcode src/nimcode.nim` — release build
- `./bin/nimcode --help` — show help
- `./bin/nimcode --version` — show version

## Versioning Note

Current version: `v0.1.0`
Next version: `v0.1.1`
