# Building AI Agents in Go

A hands-on guide to building a fully functional CLI AI agent in Go — from raw HTTP calls to a polished terminal UI. No SDK, no framework, just the standard library and a few well-chosen modules.

> Inspired by and adapted from [Hendrixer/agents-v2](https://github.com/Hendrixer/agents-v2) and the [AI Agents v2 course on Frontend Masters](https://frontendmasters.com/courses/ai-agents-v2/) by Scott Moss. The original course builds the agent in TypeScript; this edition reimagines the same architecture in idiomatic Go.

---

## Why Go for AI Agents?

Most AI agent code is Python or TypeScript. Those are fine languages, but Go has advantages that matter for production agents:

- **Concurrency** — Goroutines and channels are built for the agent loop. Streaming SSE, executing tools, and rendering UI all happen concurrently with no async/await ceremony.
- **Single binary** — `go build` produces one executable. No interpreter, no virtual environment, no `node_modules`. Drop it on any machine and run.
- **Standard library** — `net/http`, `encoding/json`, and `bufio` are enough for everything in this book except the TUI. Minimal dependency surface.
- **Operational fit** — Most cloud and infrastructure tooling is Go. If your agent needs to drive Kubernetes, Terraform, or any of a thousand cloud-native tools, Go is the lingua franca.
- **Readability** — Go code looks the same whether it was written by you or by someone else. Great for teams.

This book is not about convincing you to rewrite your Python agent in Go. It's about building an agent the Go way — concurrent, simple, and practical — and learning something about both AI agents and Go in the process.

## What You'll Build

By the end of this book, you'll have a working CLI AI agent that can:

- Call OpenAI's API directly via `net/http` (no SDK)
- Parse Server-Sent Events (SSE) with `bufio.Scanner`
- Define tools with structs and a `Tool` interface
- Execute tools: file I/O, shell commands, code execution, web search
- Manage long conversations with token estimation and compaction
- Ask for human approval via a Bubble Tea terminal UI
- Be tested with a custom evaluation framework

## Tech Stack

- **Go 1.22+** — Generics, error wrapping, modern stdlib
- **`net/http`** — HTTP client with streaming support
- **`encoding/json`** — JSON serialization with struct tags
- **`bufio`** — SSE line parsing
- **`bubbletea` + `lipgloss`** — Terminal UI (Charm libraries)
- **`godotenv`** — Loading `.env` files

No OpenAI SDK. No LangChain. No framework. Just the standard library and a few well-known modules.

## Prerequisites

**Required:**
- Comfortable writing Go (structs, interfaces, goroutines, channels, error handling)
- An OpenAI API key
- Familiarity with the terminal

**Not required:**
- AI/ML background — we explain agent concepts from first principles
- Prior experience with SSE, Bubble Tea, or terminal UIs
- Experience with any AI SDK or framework

**This book assumes Go fluency.** We won't explain what an interface is or how channels work. If you're learning Go, start elsewhere and come back. If you've shipped Go code before, you're ready.

---

## Table of Contents

### [Chapter 1: Setup and Your First LLM Call](./01-setup-and-first-call.md)
Set up the project. Call OpenAI's chat completions API with raw `net/http`. Parse the JSON response. Understand the API contract.

### [Chapter 2: Tool Calling with JSON Schema](./02-tool-calling.md)
Define tools as structs implementing a `Tool` interface. Build a registry with `map[string]Tool`. Generate JSON Schema for the API.

### [Chapter 3: Single-Turn Evaluations](./03-single-turn-evals.md)
Build an evaluation framework from scratch. Test tool selection with golden, secondary, and negative cases.

### [Chapter 4: The Agent Loop — SSE Streaming](./04-the-agent-loop.md)
Parse Server-Sent Events with `bufio.Scanner`. Accumulate fragmented tool call arguments. Build the core agent loop with goroutines and channels.

### [Chapter 5: Multi-Turn Evaluations](./05-multi-turn-evals.md)
Test full agent conversations with mocked tools. Build an LLM-as-judge evaluator.

### [Chapter 6: File System Tools](./06-file-system-tools.md)
Implement file read/write/list/delete using `os` and `path/filepath`. Idiomatic Go error handling.

### [Chapter 7: Web Search & Context Management](./07-web-search-context-management.md)
Add web search. Build a token estimator. Implement conversation compaction with LLM summarization.

### [Chapter 8: Shell Tool & Code Execution](./08-shell-tool.md)
Run shell commands with `os/exec`. Build a code execution tool with temp files. Handle process timeouts with `context.Context`.

### [Chapter 9: Terminal UI with Bubble Tea](./09-terminal-ui.md)
Build a terminal UI with the Elm Architecture. Render messages, tool calls, streaming text, and approval prompts. Bridge concurrent agent execution with the UI loop via channels.

### [Chapter 10: Going to Production](./10-going-to-production.md)
Error recovery, sandboxing, rate limiting, and the production readiness checklist.

---

## How This Book Differs

If you've read the TypeScript, Python, or Rust editions, here's what's different in the Go edition:

| Aspect | Other Editions | Go Edition |
|--------|---------------|-----------|
| **HTTP** | Various | `net/http` stdlib |
| **Concurrency** | async/await or callbacks | goroutines + channels |
| **JSON** | Various | `encoding/json` with struct tags |
| **Tool registry** | Various | `map[string]Tool` |
| **Error handling** | Exceptions or `Result` | Multi-return + `errors.Is/As` |
| **Terminal UI** | Various | Bubble Tea (Elm Architecture) |
| **Build artifact** | Source + runtime | Single static binary |

The concepts are identical. The implementation is idiomatic Go.

## Project Structure

By the end, your project will look like this:

```
agents-go/
├── go.mod
├── go.sum
├── main.go
├── api/
│   ├── client.go         # net/http client
│   ├── types.go          # Request/response structs
│   └── sse.go            # SSE stream parser
├── agent/
│   ├── run.go            # Core agent loop
│   ├── registry.go       # Tool interface + registry
│   └── prompt.go         # System prompt
├── tools/
│   ├── file.go           # File operations
│   ├── shell.go          # Shell commands
│   └── web.go            # Web search
├── context/
│   ├── tokens.go         # Token estimator
│   └── compact.go        # Conversation compaction
├── ui/
│   ├── app.go            # Bubble Tea app
│   ├── update.go         # Update function
│   └── view.go           # View function
├── eval/
│   ├── types.go
│   ├── runner.go
│   └── judge.go
└── eval_data/
    ├── file_tools.json
    └── agent_multiturn.json
```

---

Let's get started.
