# Building AI Agents from Scratch

A hands-on guide to building a fully functional CLI AI agent with tool calling, streaming, evaluations, context management, and human-in-the-loop safety. Available in five languages — plus a vibe-coding edition for product roles.

**[Read Online →](https://sivakarasala.github.io/building-ai-agents/)**

> This book series is inspired by and adapted from [Hendrixer/agents-v2](https://github.com/Hendrixer/agents-v2) and the [AI Agents v2 course on Frontend Masters](https://frontendmasters.com/courses/ai-agents-v2/) by Scott Moss. The original course builds the agent in TypeScript; these editions reimagine the same architecture across five languages.

---

## Editions

### [TypeScript Edition](https://sivakarasala.github.io/building-ai-agents/typescript/)

Built with the Vercel AI SDK, Zod schemas, and React + Ink for the terminal UI.

| Chapter | Topic |
|---------|-------|
| 1 | [Intro to Agents](https://sivakarasala.github.io/building-ai-agents/typescript/01-intro-to-agents.html) |
| 2 | [Tool Calling](https://sivakarasala.github.io/building-ai-agents/typescript/02-tool-calling.html) |
| 3 | [Single-Turn Evaluations](https://sivakarasala.github.io/building-ai-agents/typescript/03-single-turn-evals.html) |
| 4 | [The Agent Loop](https://sivakarasala.github.io/building-ai-agents/typescript/04-the-agent-loop.html) |
| 5 | [Multi-Turn Evaluations](https://sivakarasala.github.io/building-ai-agents/typescript/05-multi-turn-evals.html) |
| 6 | [File System Tools](https://sivakarasala.github.io/building-ai-agents/typescript/06-file-system-tools.html) |
| 7 | [Web Search & Context Management](https://sivakarasala.github.io/building-ai-agents/typescript/07-web-search-context-management.html) |
| 8 | [Shell Tool & Code Execution](https://sivakarasala.github.io/building-ai-agents/typescript/08-shell-tool.html) |
| 9 | [Human-in-the-Loop](https://sivakarasala.github.io/building-ai-agents/typescript/09-human-in-the-loop.html) |
| 10 | [Going to Production](https://sivakarasala.github.io/building-ai-agents/typescript/10-going-to-production.html) |

### [Python Edition](https://sivakarasala.github.io/building-ai-agents/python/)

Uses the OpenAI SDK, dataclasses, and Rich + Prompt Toolkit for the terminal UI.

**Companion code repo:** [sivakarasala/building-ai-agents-python](https://github.com/sivakarasala/building-ai-agents-python) — one branch per chapter (`01-intro-to-agents` … `09-hitl`, plus `done` for the finished app).

| Chapter | Topic |
|---------|-------|
| 1 | [Intro to Agents](https://sivakarasala.github.io/building-ai-agents/python/01-intro-to-agents.html) |
| 2 | [Tool Calling](https://sivakarasala.github.io/building-ai-agents/python/02-tool-calling.html) |
| 3 | [Single-Turn Evaluations](https://sivakarasala.github.io/building-ai-agents/python/03-single-turn-evals.html) |
| 4 | [The Agent Loop](https://sivakarasala.github.io/building-ai-agents/python/04-the-agent-loop.html) |
| 5 | [Multi-Turn Evaluations](https://sivakarasala.github.io/building-ai-agents/python/05-multi-turn-evals.html) |
| 6 | [File System Tools](https://sivakarasala.github.io/building-ai-agents/python/06-file-system-tools.html) |
| 7 | [Web Search & Context Management](https://sivakarasala.github.io/building-ai-agents/python/07-web-search-context-management.html) |
| 8 | [Shell Tool & Code Execution](https://sivakarasala.github.io/building-ai-agents/python/08-shell-tool.html) |
| 9 | [Human-in-the-Loop](https://sivakarasala.github.io/building-ai-agents/python/09-human-in-the-loop.html) |
| 10 | [Going to Production](https://sivakarasala.github.io/building-ai-agents/python/10-going-to-production.html) |

### [Rust Edition](https://sivakarasala.github.io/building-ai-agents/rust/)

Raw HTTP with reqwest. Manual SSE parsing. Trait objects for tool dispatch. Ratatui for terminal UI. No SDK, full control.

| Chapter | Topic |
|---------|-------|
| 1 | [Setup and Your First LLM Call](https://sivakarasala.github.io/building-ai-agents/rust/01-setup-and-first-call.html) |
| 2 | [Tool Calling with JSON Schema](https://sivakarasala.github.io/building-ai-agents/rust/02-tool-calling.html) |
| 3 | [Single-Turn Evaluations](https://sivakarasala.github.io/building-ai-agents/rust/03-single-turn-evals.html) |
| 4 | [The Agent Loop — SSE Streaming](https://sivakarasala.github.io/building-ai-agents/rust/04-the-agent-loop.html) |
| 5 | [Multi-Turn Evaluations](https://sivakarasala.github.io/building-ai-agents/rust/05-multi-turn-evals.html) |
| 6 | [File System Tools](https://sivakarasala.github.io/building-ai-agents/rust/06-file-system-tools.html) |
| 7 | [Web Search & Context Management](https://sivakarasala.github.io/building-ai-agents/rust/07-web-search-context-management.html) |
| 8 | [Shell Tool & Code Execution](https://sivakarasala.github.io/building-ai-agents/rust/08-shell-tool.html) |
| 9 | [Terminal UI with Ratatui](https://sivakarasala.github.io/building-ai-agents/rust/09-terminal-ui.html) |
| 10 | [Going to Production](https://sivakarasala.github.io/building-ai-agents/rust/10-going-to-production.html) |

**Appendices:**
[Async Primer](https://sivakarasala.github.io/building-ai-agents/rust/appendix-a-async-primer.html) · [Serde Deep Dive](https://sivakarasala.github.io/building-ai-agents/rust/appendix-b-serde.html) · [Trait Objects](https://sivakarasala.github.io/building-ai-agents/rust/appendix-c-trait-objects.html) · [Error Handling](https://sivakarasala.github.io/building-ai-agents/rust/appendix-d-error-handling.html) · [Ratatui & Immediate-Mode UI](https://sivakarasala.github.io/building-ai-agents/rust/appendix-e-ratatui.html)

### [Go Edition](https://sivakarasala.github.io/building-ai-agents/go/)

Standard library `net/http`. Goroutines and channels for the agent loop. Bubble Tea for terminal UI. Single static binary, no framework.

| Chapter | Topic |
|---------|-------|
| 1 | [Setup and Your First LLM Call](https://sivakarasala.github.io/building-ai-agents/go/01-setup-and-first-call.html) |
| 2 | [Tool Calling with JSON Schema](https://sivakarasala.github.io/building-ai-agents/go/02-tool-calling.html) |
| 3 | [Single-Turn Evaluations](https://sivakarasala.github.io/building-ai-agents/go/03-single-turn-evals.html) |
| 4 | [The Agent Loop — SSE Streaming](https://sivakarasala.github.io/building-ai-agents/go/04-the-agent-loop.html) |
| 5 | [Multi-Turn Evaluations](https://sivakarasala.github.io/building-ai-agents/go/05-multi-turn-evals.html) |
| 6 | [File System Tools](https://sivakarasala.github.io/building-ai-agents/go/06-file-system-tools.html) |
| 7 | [Web Search & Context Management](https://sivakarasala.github.io/building-ai-agents/go/07-web-search-context-management.html) |
| 8 | [Shell Tool & Code Execution](https://sivakarasala.github.io/building-ai-agents/go/08-shell-tool.html) |
| 9 | [Terminal UI with Bubble Tea](https://sivakarasala.github.io/building-ai-agents/go/09-terminal-ui.html) |
| 10 | [Going to Production](https://sivakarasala.github.io/building-ai-agents/go/10-going-to-production.html) |

### [Java Edition](https://sivakarasala.github.io/building-ai-agents/java/)

Java 21 with `java.net.http.HttpClient` and Jackson. Sealed types and records. Virtual threads for concurrency. Lanterna for terminal UI.

| Chapter | Topic |
|---------|-------|
| 1 | [Setup and Your First LLM Call](https://sivakarasala.github.io/building-ai-agents/java/01-setup-and-first-call.html) |
| 2 | [Tool Calling with JSON Schema](https://sivakarasala.github.io/building-ai-agents/java/02-tool-calling.html) |
| 3 | [Single-Turn Evaluations](https://sivakarasala.github.io/building-ai-agents/java/03-single-turn-evals.html) |
| 4 | [The Agent Loop — SSE Streaming](https://sivakarasala.github.io/building-ai-agents/java/04-the-agent-loop.html) |
| 5 | [Multi-Turn Evaluations](https://sivakarasala.github.io/building-ai-agents/java/05-multi-turn-evals.html) |
| 6 | [File System Tools](https://sivakarasala.github.io/building-ai-agents/java/06-file-system-tools.html) |
| 7 | [Web Search & Context Management](https://sivakarasala.github.io/building-ai-agents/java/07-web-search-context-management.html) |
| 8 | [Shell Tool & Code Execution](https://sivakarasala.github.io/building-ai-agents/java/08-shell-tool.html) |
| 9 | [Terminal UI with Lanterna](https://sivakarasala.github.io/building-ai-agents/java/09-terminal-ui.html) |
| 10 | [Going to Production](https://sivakarasala.github.io/building-ai-agents/java/10-going-to-production.html) |

### [Vibe Coding Edition](https://sivakarasala.github.io/building-ai-agents/vibe-coding/)

For product managers, owners, designers, and analysts. Build the same Python agent by guiding a coding agent (Claude Code, Cursor, etc.) through a sequence of prompts. No programming required — the coding agent writes the code, you drive.

| Chapter | Topic |
|---------|-------|
| 0 | [Setting Up Your Coding Agent](https://sivakarasala.github.io/building-ai-agents/vibe-coding/00-setup-coding-agent.html) |
| 1 | [Your First LLM Call](https://sivakarasala.github.io/building-ai-agents/vibe-coding/01-first-llm-call.html) |
| 2 | [Tool Calling](https://sivakarasala.github.io/building-ai-agents/vibe-coding/02-tool-calling.html) |
| 3 | [Single-Turn Evaluations](https://sivakarasala.github.io/building-ai-agents/vibe-coding/03-single-turn-evals.html) |

Chapters 4–10 follow the same prompt-driven format and are in progress.

---

## What You'll Build

A CLI AI agent that can:

- Call LLM APIs with tool definitions (JSON Schema)
- Stream responses via SSE and execute tools inline
- Read, write, list, and delete files
- Run shell commands and execute code
- Search the web for current information
- Manage context windows with token estimation and compaction
- Ask for human approval before dangerous operations
- Be tested with single-turn and multi-turn evaluations

## Local Development

Requires [mdBook](https://rust-lang.github.io/mdBook/):

```bash
cargo install mdbook
./build.sh
# Open docs/index.html
```

## License

MIT
