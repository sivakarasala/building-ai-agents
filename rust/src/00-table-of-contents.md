# Building AI Agents in Rust: A Systems Programmer's Guide

Build a fully functional CLI AI agent from raw HTTP calls — no SDK abstractions. Parse SSE streams by hand, manage ownership across async tool execution, and build a terminal UI with immediate-mode rendering.

---

## Why Rust for AI Agents?

Most AI agent code is Python or TypeScript. There are good reasons for that — rapid prototyping, rich ecosystems, forgiving runtimes. So why Rust?

- **Performance** — Sub-millisecond tool dispatch. Zero-cost abstractions for the agent loop. No GC pauses during streaming.
- **Reliability** — The type system catches entire categories of bugs at compile time. If it compiles, your tool registry won't crash at runtime with "undefined is not a function."
- **Resource efficiency** — A Rust agent uses 10-50x less memory than a Python equivalent. Matters when running multiple agents, embedding in other systems, or deploying on constrained hardware.
- **Understanding** — Building from `reqwest` + raw SSE means you understand every byte flowing between your agent and the LLM. No magic. No hidden abstractions.

This book is not about convincing you to rewrite your Python agent in Rust. It's about building an agent the Rust way — with full control, zero overhead, and compile-time guarantees — and learning something about both AI agents and Rust in the process.

## What You'll Build

By the end of this book, you'll have a working CLI AI agent that can:

- Call OpenAI's API directly via `reqwest` (no SDK)
- Parse Server-Sent Events (SSE) streams by hand
- Define tools with `serde`-based JSON Schema generation
- Execute tools: file I/O, shell commands, code execution, web search
- Manage long conversations with token estimation and compaction
- Ask for human approval via a `ratatui` terminal UI
- Be tested with a custom evaluation framework

## Tech Stack

- **Rust 1.75+** — Stable, with async/await
- **tokio** — Async runtime
- **reqwest** — HTTP client with streaming support
- **serde / serde_json** — Serialization and JSON handling
- **ratatui + crossterm** — Immediate-mode terminal UI
- **clap** — CLI argument parsing

No OpenAI SDK. No LangChain. No framework. Just crates and the standard library.

## Prerequisites

**Required:**
- Comfortable writing Rust (ownership, borrowing, lifetimes, traits, async/await)
- An OpenAI API key ([platform.openai.com](https://platform.openai.com))
- Familiarity with the terminal

**Not required:**
- AI/ML background — we explain agent concepts from first principles
- Prior experience with SSE, `ratatui`, or HTTP streaming
- Experience with any AI SDK or framework

**This book assumes Rust fluency.** We won't explain what `&str` vs `String` means or how `Result` works. If you're learning Rust, start elsewhere and come back. If you've shipped Rust code before, you're ready.

---

## Table of Contents

### [Chapter 1: Setup and Your First LLM Call](./01-setup-and-first-call.md)
Set up the project. Call OpenAI's chat completions API with raw `reqwest`. Parse the JSON response. Understand the API contract you'll be working with.

### [Chapter 2: Tool Calling with JSON Schema](./02-tool-calling.md)
Define tools as Rust structs. Generate JSON Schema from types using `serde`. Send tool definitions to the API. Parse tool call responses. Build a tool registry with trait objects.

### [Chapter 3: Single-Turn Evaluations](./03-single-turn-evals.md)
Build an evaluation framework from scratch. Test tool selection with golden, secondary, and negative cases. Score results with precision/recall metrics.

### [Chapter 4: The Agent Loop — SSE Streaming](./04-the-agent-loop.md)
Parse Server-Sent Events by hand. Accumulate fragmented tool call arguments across stream chunks. Build the core while loop with async streaming. Handle ownership of growing message history.

### [Chapter 5: Multi-Turn Evaluations](./05-multi-turn-evals.md)
Test full agent conversations with mocked tools. Build an LLM-as-judge evaluator. Evaluate tool ordering with subsequence matching.

### [Chapter 6: File System Tools](./06-file-system-tools.md)
Implement file read/write/list/delete using `std::fs` and `tokio::fs`. Handle errors with `Result`. Understand why tools return `String` instead of `Result`.

### [Chapter 7: Web Search & Context Management](./07-web-search-context-management.md)
Add web search via OpenAI's API. Build a token estimator. Track context window usage. Implement conversation compaction with LLM summarization.

### [Chapter 8: Shell Tool & Code Execution](./08-shell-tool.md)
Run shell commands with `std::process::Command`. Build a code execution tool with temp files. Handle process timeouts with `tokio::time`.

### [Chapter 9: Terminal UI with Ratatui](./09-terminal-ui.md)
Build an immediate-mode terminal UI. Render messages, tool calls, streaming text, and approval prompts. Handle keyboard input with crossterm. Bridge async agent execution with synchronous rendering.

### [Chapter 10: Going to Production](./10-going-to-production.md)
Error recovery, sandboxing, rate limiting, and the production readiness checklist. Recommended reading for going deeper.

---

## How This Book Differs

If you've read the TypeScript or Python editions of this book, here's what's different:

| Aspect | TS/Python Editions | Rust Edition |
|--------|-------------------|--------------|
| **HTTP** | SDK handles it | Raw `reqwest` + SSE parsing |
| **Streaming** | SDK iterator | Manual SSE line parsing |
| **Tool schemas** | Zod / JSON dicts | `serde` + derive macros |
| **Tool registry** | Object/dict | `HashMap<String, Box<dyn Tool>>` |
| **Error handling** | try/catch / exceptions | `Result<T, E>` everywhere |
| **Terminal UI** | React + Ink / Rich | `ratatui` (immediate mode) |
| **Async** | Implicit (JS) / optional (Python) | Explicit `tokio` runtime |
| **Memory management** | GC / RC | Ownership + borrowing |

The concepts are identical. The implementation is fundamentally different. You'll fight the borrow checker in Chapter 4 (streaming state accumulation) and Chapter 9 (UI state management). That's the point — those fights teach you something.

## Project Structure

By the end, your project will look like this:

```
agents-v2/
├── Cargo.toml
├── src/
│   ├── main.rs
│   ├── api/
│   │   ├── mod.rs
│   │   ├── client.rs          # Raw reqwest HTTP client
│   │   ├── types.rs           # API request/response types
│   │   └── sse.rs             # SSE stream parser
│   ├── agent/
│   │   ├── mod.rs
│   │   ├── run.rs             # Core agent loop
│   │   ├── tool_registry.rs   # Tool trait + registry
│   │   └── system_prompt.rs
│   ├── tools/
│   │   ├── mod.rs
│   │   ├── file.rs            # File operations
│   │   ├── shell.rs           # Shell commands
│   │   ├── code_execution.rs  # Code runner
│   │   └── web_search.rs      # Web search
│   ├── context/
│   │   ├── mod.rs
│   │   ├── token_estimator.rs
│   │   ├── compaction.rs
│   │   └── model_limits.rs
│   ├── ui/
│   │   ├── mod.rs
│   │   ├── app.rs             # Main ratatui app
│   │   ├── message_list.rs
│   │   ├── tool_call.rs
│   │   ├── tool_approval.rs
│   │   ├── input.rs
│   │   └── token_usage.rs
│   └── eval/
│       ├── mod.rs
│       ├── types.rs
│       ├── evaluators.rs
│       ├── executors.rs
│       └── mocks.rs
├── eval_data/
│   ├── file_tools.json
│   ├── shell_tools.json
│   └── agent_multiturn.json
└── .env
```

## Appendices

These appendices cover Rust concepts used heavily in the book. If you're comfortable with async, serde, and trait objects, skip them. If any chapter feels like it's fighting you on Rust mechanics rather than agent concepts, the relevant appendix will get you unstuck.

### [Appendix A: Rust Async Primer](./appendix-a-async-primer.md)
`tokio` runtime, `async/await`, `Future` trait, `tokio::spawn`, `select!`, and why async matters for SSE streaming. **Read before Chapter 4** if you've only written synchronous Rust.

### [Appendix B: Serde Deep Dive](./appendix-b-serde.md)
`Serialize`/`Deserialize`, rename attributes, `serde_json::Value` for dynamic JSON, flattening, and custom serializers. **Read before Chapter 2** if you've only used serde for simple structs.

### [Appendix C: Trait Objects & Dynamic Dispatch](./appendix-c-trait-objects.md)
`dyn Trait`, `Box<dyn Tool>`, object safety rules, and why we can't use generics for the tool registry. **Read before Chapter 2** if you haven't built plugin-style architectures.

### [Appendix D: Error Handling Patterns](./appendix-d-error-handling.md)
`thiserror`, `anyhow`, the `?` operator, custom error enums, and when to `unwrap` vs propagate. **Read before Chapter 1** if you're still `.unwrap()`-ing everything.

### [Appendix E: Ratatui & Immediate-Mode UI](./appendix-e-ratatui.md)
The immediate-mode rendering model, `Widget` trait, `Frame::render_widget`, state management without React, and the event loop pattern. **Read before Chapter 9** if you've never used an immediate-mode UI framework.

---

Let's get started.
