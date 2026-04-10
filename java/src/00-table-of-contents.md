# Building AI Agents in Java

A hands-on guide to building a fully functional CLI AI agent in Java 21 — from raw HTTP calls to a polished terminal UI. No AI SDK, no framework, just modern Java and a few well-chosen libraries.

> Inspired by and adapted from [Hendrixer/agents-v2](https://github.com/Hendrixer/agents-v2) and the [AI Agents v2 course on Frontend Masters](https://frontendmasters.com/courses/ai-agents-v2/) by Scott Moss. The original course builds the agent in TypeScript; this edition reimagines the same architecture in modern Java.

---

## Why Java for AI Agents?

Most AI agent code is Python or TypeScript. Those are fine languages, but Java has been quietly evolving into a serious choice for this kind of work:

- **`java.net.http.HttpClient`** — A fluent, modern HTTP client built into the JDK since Java 11. Streaming, async, no third-party dependency.
- **Records and pattern matching** — JSON-shaped data maps cleanly to records. Sealed types give you exhaustive switches over event kinds.
- **Virtual threads** — Java 21's headline feature. Treat every concurrent task as a thread, write blocking code, get the scalability of async without the colored-function pain.
- **Structured concurrency** (preview) — Bound the lifetimes of related concurrent operations. Cancellation actually works.
- **The JVM ecosystem** — If your team already lives in Spring, Gradle, Kotlin, or any of the JVM observability tools, your agent fits in without a foreign-runtime detour.

This book is not about convincing you to rewrite your Python agent in Java. It's about building an agent the modern Java way and learning something about both AI agents and Java 21 in the process.

## What You'll Build

By the end of this book, you'll have a working CLI AI agent that can:

- Call OpenAI's API directly via `java.net.http.HttpClient` (no SDK)
- Parse Server-Sent Events (SSE) using the built-in `Flow.Subscriber` API
- Define tools as records implementing a `Tool` sealed interface
- Execute tools: file I/O, shell commands, code execution, web search
- Manage long conversations with token estimation and compaction
- Ask for human approval via a Lanterna terminal UI
- Be tested with a custom evaluation framework

## Tech Stack

- **Java 21** — Records, sealed types, pattern matching, virtual threads, text blocks
- **`java.net.http.HttpClient`** — Standard-library HTTP client with streaming
- **Jackson** — JSON serialization (`jackson-databind`)
- **Lanterna** — Terminal UI library
- **Gradle (Kotlin DSL)** — Build tool

No OpenAI SDK. No Spring AI. No LangChain4j. Just the JDK and a few well-known libraries.

## Prerequisites

**Required:**
- Comfortable writing Java (records, generics, lambdas, streams)
- Java 21 installed (`sdk install java 21-tem` if you use SDKMAN)
- An OpenAI API key
- Familiarity with the terminal and Gradle

**Not required:**
- AI/ML background — we explain agent concepts from first principles
- Prior experience with SSE, Lanterna, or terminal UIs
- Spring, Quarkus, or any specific framework

**This book assumes Java fluency.** We won't explain what an interface is or how a `CompletableFuture` works. If you're learning Java, start elsewhere and come back. If you've shipped Java code before, you're ready.

---

## Table of Contents

### [Chapter 1: Setup and Your First LLM Call](./01-setup-and-first-call.md)
Set up the Gradle project. Call OpenAI's chat completions API with `java.net.http.HttpClient`. Model the request and response with records. Parse JSON with Jackson.

### [Chapter 2: Tool Calling with JSON Schema](./02-tool-calling.md)
Define tools as records implementing a `Tool` interface. Build a registry with `Map<String, Tool>`. Generate JSON Schema for the API.

### [Chapter 3: Single-Turn Evaluations](./03-single-turn-evals.md)
Build an evaluation framework from scratch. Test tool selection with golden, secondary, and negative cases.

### [Chapter 4: The Agent Loop — SSE Streaming](./04-the-agent-loop.md)
Stream Server-Sent Events with `HttpClient.send` and a line-by-line `BodySubscribers` adapter. Accumulate fragmented tool call arguments. Build the core agent loop on virtual threads.

### [Chapter 5: Multi-Turn Evaluations](./05-multi-turn-evals.md)
Test full agent conversations with mocked tools. Build an LLM-as-judge evaluator.

### [Chapter 6: File System Tools](./06-file-system-tools.md)
Implement file read/write/list/delete using `java.nio.file`. Idiomatic Java error handling.

### [Chapter 7: Web Search & Context Management](./07-web-search-context-management.md)
Add web search. Build a token estimator. Implement conversation compaction with LLM summarization.

### [Chapter 8: Shell Tool & Code Execution](./08-shell-tool.md)
Run shell commands with `ProcessBuilder`. Build a code execution tool with temp files. Handle process timeouts and destruction.

### [Chapter 9: Terminal UI with Lanterna](./09-terminal-ui.md)
Build a terminal UI with Lanterna. Render messages, tool calls, streaming text, and approval prompts. Bridge the agent's virtual thread with the UI thread via blocking queues.

### [Chapter 10: Going to Production](./10-going-to-production.md)
Error recovery, sandboxing, rate limiting, and the production readiness checklist.

---

## How This Book Differs

If you've read the TypeScript, Python, Rust, or Go editions, here's what's different in the Java edition:

| Aspect | Other Editions | Java Edition |
|--------|---------------|--------------|
| **HTTP** | Various | `java.net.http.HttpClient` |
| **Concurrency** | async/await, goroutines | Virtual threads + `BlockingQueue` |
| **JSON** | Various | Jackson with records |
| **Tool registry** | Various | `Map<String, Tool>` over a sealed interface |
| **Error handling** | Various | Checked + unchecked exceptions, sealed result types |
| **Terminal UI** | Various | Lanterna |
| **Build artifact** | Various | Fat JAR via Gradle Shadow |

The concepts are identical. The implementation is idiomatic modern Java.

## Project Structure

By the end, your project will look like this:

```
agents-java/
├── build.gradle.kts
├── settings.gradle.kts
└── src/main/java/com/example/agents/
    ├── Main.java
    ├── api/
    │   ├── OpenAiClient.java
    │   ├── Messages.java         // records: Message, ToolCall, etc.
    │   └── Sse.java              // SSE line subscriber
    ├── agent/
    │   ├── Agent.java            // core loop
    │   ├── Tool.java             // sealed interface
    │   ├── Registry.java
    │   ├── Prompts.java
    │   └── Events.java           // sealed event types
    ├── tools/
    │   ├── ReadFile.java
    │   ├── ListFiles.java
    │   ├── WriteFile.java
    │   ├── EditFile.java
    │   ├── DeleteFile.java
    │   ├── Shell.java
    │   ├── RunCode.java
    │   └── WebSearch.java
    ├── context/
    │   ├── Tokens.java
    │   └── Compact.java
    ├── ui/
    │   └── TerminalApp.java
    └── eval/
        ├── Cases.java
        ├── Runner.java
        └── Judge.java
```

---

Let's get started.
