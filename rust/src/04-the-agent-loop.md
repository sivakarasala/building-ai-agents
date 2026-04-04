# Chapter 4: The Agent Loop — SSE Streaming

## The Hardest Chapter

This is the chapter where Rust makes you work for it. In Python, streaming is `for chunk in response:`. In TypeScript, it's `for await (const chunk of stream)`. In Rust, you parse raw SSE bytes, accumulate fragmented tool call arguments across chunks, and fight the borrow checker over mutable state inside an async loop.

The reward: you'll understand every byte flowing between your agent and the API. No SDK magic. No hidden allocations. Full control.

## Server-Sent Events (SSE)

When you set `stream: true`, OpenAI doesn't return a single JSON response. It opens a persistent HTTP connection and sends a stream of events:

```
data: {"id":"chatcmpl-abc","choices":[{"delta":{"role":"assistant"},"index":0}]}

data: {"id":"chatcmpl-abc","choices":[{"delta":{"content":"Hello"},"index":0}]}

data: {"id":"chatcmpl-abc","choices":[{"delta":{"content":" world"},"index":0}]}

data: [DONE]
```

Each line starts with `data: ` followed by a JSON object. The `delta` field contains *incremental* content — a few tokens at a time. `[DONE]` signals the stream is finished.

For tool calls, the stream is more complex. The function name and arguments arrive in fragments:

```
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"read_file","arguments":""}}]}}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"pa"}}]}}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\""}}]}}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"src/main"}}]}}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":".rs\"}"}}]}}]}

data: [DONE]
```

The arguments `{"path":"src/main.rs"}` arrive as five separate fragments. We must accumulate them.

## SSE Types

Create `src/api/sse.rs`:

```rust
use serde::Deserialize;

/// A single chunk from the SSE stream.
#[derive(Debug, Deserialize)]
pub struct StreamChunk {
    pub id: Option<String>,
    pub choices: Vec<StreamChoice>,
}

#[derive(Debug, Deserialize)]
pub struct StreamChoice {
    pub index: usize,
    pub delta: Delta,
    pub finish_reason: Option<String>,
}

/// The incremental content in a stream chunk.
#[derive(Debug, Deserialize)]
pub struct Delta {
    pub role: Option<String>,
    pub content: Option<String>,
    pub tool_calls: Option<Vec<StreamToolCall>>,
}

/// A tool call fragment from the stream.
#[derive(Debug, Deserialize)]
pub struct StreamToolCall {
    pub index: usize,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(rename = "type")]
    pub call_type: Option<String>,
    pub function: Option<StreamFunction>,
}

#[derive(Debug, Deserialize)]
pub struct StreamFunction {
    pub name: Option<String>,
    pub arguments: Option<String>,
}
```

Every field is `Option` because each chunk only contains the fields that changed. The first chunk might have `role: "assistant"` and `name: "read_file"`. Subsequent chunks only have `arguments` fragments.

## Streaming HTTP Client

Add a streaming method to `OpenAIClient`. Update `src/api/client.rs`:

```rust
use anyhow::{Context, Result};
use futures_util::StreamExt;
use reqwest::Client;

use super::sse::StreamChunk;
use super::types::{ChatCompletionRequest, ChatCompletionResponse};

const API_URL: &str = "https://api.openai.com/v1/chat/completions";

pub struct OpenAIClient {
    client: Client,
    api_key: String,
}

impl OpenAIClient {
    pub fn new(api_key: String) -> Self {
        Self {
            client: Client::new(),
            api_key,
        }
    }

    /// Non-streaming request (from Chapter 1).
    pub async fn chat_completion(
        &self,
        request: ChatCompletionRequest,
    ) -> Result<ChatCompletionResponse> {
        let response = self
            .client
            .post(API_URL)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .header("Content-Type", "application/json")
            .json(&request)
            .send()
            .await
            .context("Failed to send request to OpenAI")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!("OpenAI API error ({}): {}", status, body);
        }

        response
            .json::<ChatCompletionResponse>()
            .await
            .context("Failed to parse OpenAI response")
    }

    /// Streaming request — returns chunks via a callback.
    pub async fn chat_completion_stream(
        &self,
        mut request: ChatCompletionRequest,
        mut on_chunk: impl FnMut(StreamChunk),
    ) -> Result<()> {
        request.stream = Some(true);

        let response = self
            .client
            .post(API_URL)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .header("Content-Type", "application/json")
            .json(&request)
            .send()
            .await
            .context("Failed to send streaming request")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!("OpenAI API error ({}): {}", status, body);
        }

        let mut stream = response.bytes_stream();
        let mut buffer = String::new();

        while let Some(chunk) = stream.next().await {
            let bytes = chunk.context("Stream read error")?;
            buffer.push_str(&String::from_utf8_lossy(&bytes));

            // Process complete lines
            while let Some(line_end) = buffer.find('\n') {
                let line = buffer[..line_end].trim().to_string();
                buffer = buffer[line_end + 1..].to_string();

                if line.is_empty() {
                    continue;
                }

                if let Some(data) = line.strip_prefix("data: ") {
                    if data == "[DONE]" {
                        return Ok(());
                    }

                    match serde_json::from_str::<StreamChunk>(data) {
                        Ok(chunk) => on_chunk(chunk),
                        Err(e) => {
                            eprintln!("Failed to parse SSE chunk: {e}");
                        }
                    }
                }
            }
        }

        Ok(())
    }
}
```

### Line-by-Line SSE Parsing

The key section:

```rust
let mut stream = response.bytes_stream();
let mut buffer = String::new();

while let Some(chunk) = stream.next().await {
    let bytes = chunk?;
    buffer.push_str(&String::from_utf8_lossy(&bytes));

    while let Some(line_end) = buffer.find('\n') {
        let line = buffer[..line_end].trim().to_string();
        buffer = buffer[line_end + 1..].to_string();
        // ...
    }
}
```

HTTP chunks don't align with SSE lines. A single `bytes_stream()` chunk might contain half a line, two full lines, or a line and a half. The buffer accumulates bytes until we find complete newline-delimited lines.

This is the inner loop:
1. Append raw bytes to `buffer`
2. While `buffer` contains a `\n`, extract the line before it
3. If the line starts with `data: `, parse the JSON
4. If the data is `[DONE]`, we're finished

### Why `FnMut` and Not a Channel?

```rust
pub async fn chat_completion_stream(
    &self,
    mut request: ChatCompletionRequest,
    mut on_chunk: impl FnMut(StreamChunk),
) -> Result<()> {
```

We use a callback (`FnMut`) rather than returning a channel or iterator. This is simpler — the caller processes each chunk inline. `FnMut` (not `Fn`) because the callback will mutate state (accumulating tool call arguments, building text content).

## The Tool Call Accumulator

Tool call arguments arrive in fragments. We need state to accumulate them. Create `src/agent/run.rs`:

```rust
use anyhow::Result;
use serde_json::Value;

use crate::api::client::OpenAIClient;
use crate::api::types::{
    ChatCompletionRequest, FunctionCall, Message, ToolCall, ToolDefinition,
};
use crate::agent::system_prompt::SYSTEM_PROMPT;
use crate::agent::tool_registry::ToolRegistry;

/// Accumulated state for a tool call being streamed.
#[derive(Debug, Clone)]
struct PendingToolCall {
    id: String,
    name: String,
    arguments: String,
}

/// Callbacks for the agent loop.
pub struct AgentCallbacks {
    pub on_token: Box<dyn FnMut(&str)>,
    pub on_tool_call_start: Box<dyn FnMut(&str, &Value)>,
    pub on_tool_call_end: Box<dyn FnMut(&str, &str)>,
    pub on_complete: Box<dyn FnMut(&str)>,
}
```

`PendingToolCall` holds the in-progress state for a single tool call. As argument fragments arrive, we append them to `arguments`. When the stream ends, we parse the accumulated JSON string.

## The Agent Loop

Here's the core loop — the heart of the agent:

```rust
/// Run the agent loop.
pub async fn run_agent(
    user_message: &str,
    history: Vec<Message>,
    client: &OpenAIClient,
    registry: &ToolRegistry,
    tools: &[ToolDefinition],
    callbacks: &mut AgentCallbacks,
) -> Result<Vec<Message>> {
    let mut messages = history;

    // Add system prompt if not present
    if messages.is_empty() || messages[0].role != "system" {
        messages.insert(0, Message::system(SYSTEM_PROMPT));
    }

    // Add the user's message
    messages.push(Message::user(user_message));

    loop {
        // --- Accumulation state for this iteration ---
        let mut text_content = String::new();
        let mut pending_tools: Vec<PendingToolCall> = Vec::new();
        let mut finish_reason = None;

        // --- Stream the response ---
        let request = ChatCompletionRequest {
            model: "gpt-4.1-mini".into(),
            messages: messages.clone(),
            tools: Some(tools.to_vec()),
            stream: Some(true),
        };

        client
            .chat_completion_stream(request, |chunk| {
                if let Some(choice) = chunk.choices.first() {
                    // Capture finish reason
                    if let Some(ref reason) = choice.finish_reason {
                        finish_reason = Some(reason.clone());
                    }

                    let delta = &choice.delta;

                    // Text content
                    if let Some(ref content) = delta.content {
                        text_content.push_str(content);
                        (callbacks.on_token)(content);
                    }

                    // Tool calls
                    if let Some(ref tool_calls) = delta.tool_calls {
                        for tc in tool_calls {
                            let idx = tc.index;

                            // Ensure we have a slot for this tool call
                            while pending_tools.len() <= idx {
                                pending_tools.push(PendingToolCall {
                                    id: String::new(),
                                    name: String::new(),
                                    arguments: String::new(),
                                });
                            }

                            // Fill in fields as they arrive
                            if let Some(ref id) = tc.id {
                                pending_tools[idx].id = id.clone();
                            }
                            if let Some(ref func) = tc.function {
                                if let Some(ref name) = func.name {
                                    pending_tools[idx].name = name.clone();
                                }
                                if let Some(ref args) = func.arguments {
                                    pending_tools[idx].arguments.push_str(args);
                                }
                            }
                        }
                    }
                }
            })
            .await?;

        // --- Process the completed response ---

        // If the model just returned text, we're done
        if finish_reason.as_deref() == Some("stop") || pending_tools.is_empty() {
            // Add assistant message to history
            if !text_content.is_empty() {
                messages.push(Message::assistant(&text_content));
            }
            (callbacks.on_complete)(&text_content);
            return Ok(messages);
        }

        // --- Execute tool calls ---

        // Build the assistant message with tool calls
        let tool_calls: Vec<ToolCall> = pending_tools
            .iter()
            .map(|pt| ToolCall {
                id: pt.id.clone(),
                call_type: "function".into(),
                function: FunctionCall {
                    name: pt.name.clone(),
                    arguments: pt.arguments.clone(),
                },
            })
            .collect();

        messages.push(Message {
            role: "assistant".into(),
            content: if text_content.is_empty() {
                None
            } else {
                Some(text_content.clone())
            },
            tool_calls: Some(tool_calls),
            tool_call_id: None,
        });

        // Execute each tool and add results
        for pt in &pending_tools {
            let args: Value = serde_json::from_str(&pt.arguments)
                .unwrap_or(Value::Null);

            (callbacks.on_tool_call_start)(&pt.name, &args);

            let result = registry.execute(&pt.name, args)?;

            (callbacks.on_tool_call_end)(&pt.name, &result);

            messages.push(Message::tool_result(&pt.id, &result));
        }

        // Loop back — the LLM will see the tool results and continue
    }
}
```

### The Loop Structure

```
loop {
    1. Stream a response, accumulating text and tool call fragments
    2. If finish_reason is "stop" → return (conversation is done)
    3. If there are tool calls:
       a. Add the assistant message (with tool_calls) to history
       b. Execute each tool
       c. Add tool results to history
    4. Go back to step 1
}
```

This is the **agentic loop**. The LLM can chain multiple tool calls before giving a final answer. Ask "What's in main.rs?" and the loop might:

1. LLM calls `list_files` → we execute → add result
2. LLM calls `read_file` → we execute → add result
3. LLM responds with a summary → loop ends

### The `messages.clone()` Problem

```rust
let request = ChatCompletionRequest {
    messages: messages.clone(),
    // ...
};
```

We clone the entire message history every iteration. This is the price of Rust's ownership model — we can't move `messages` into the request because we need it after the stream completes. We could use `Arc<Vec<Message>>` or restructure to avoid the clone, but for message histories (which are small relative to the LLM's context window), cloning is simple and correct.

### Why `pending_tools` Uses Index-Based Access

```rust
while pending_tools.len() <= idx {
    pending_tools.push(PendingToolCall { ... });
}
pending_tools[idx].arguments.push_str(args);
```

The API can stream *multiple* tool calls simultaneously, identified by `index`. Index 0 might get argument fragments interleaved with index 1 fragments. We use the index to slot each fragment into the right accumulator.

## Update Module Exports

Update `src/agent/mod.rs`:

```rust
pub mod run;
pub mod system_prompt;
pub mod tool_registry;
```

Update `src/api/mod.rs`:

```rust
pub mod client;
pub mod sse;
pub mod types;
```

## Wire It Into Main

Update `src/main.rs`:

```rust
mod api;
mod agent;
mod tools;
mod eval;

use anyhow::Result;
use api::client::OpenAIClient;
use agent::{
    run::{run_agent, AgentCallbacks},
    tool_registry::ToolRegistry,
};
use tools::file::{ReadFileTool, ListFilesTool};

#[tokio::main]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();

    let api_key = std::env::var("OPENAI_API_KEY")
        .expect("OPENAI_API_KEY must be set");

    let client = OpenAIClient::new(api_key);

    let mut registry = ToolRegistry::new();
    registry.register(Box::new(ReadFileTool));
    registry.register(Box::new(ListFilesTool));

    let definitions = registry.definitions();

    let mut callbacks = AgentCallbacks {
        on_token: Box::new(|token| print!("{token}")),
        on_tool_call_start: Box::new(|name, _args| {
            println!("\n[calling {name}...]");
        }),
        on_tool_call_end: Box::new(|name, result| {
            let preview = &result[..result.len().min(100)];
            println!("[{name} done: {preview}]");
        }),
        on_complete: Box::new(|_| println!()),
    };

    let messages = run_agent(
        "What files are in this project? Then read the Cargo.toml.",
        Vec::new(),
        &client,
        &registry,
        &definitions,
        &mut callbacks,
    )
    .await?;

    println!("\n--- Conversation: {} messages ---", messages.len());

    Ok(())
}
```

Run it:

```bash
cargo run
```

You should see streaming text with tool calls executing inline — the LLM lists files, reads Cargo.toml, then summarizes what it found.

## Understanding Ownership in the Loop

The most Rust-specific aspect of this chapter is ownership management. Let's trace who owns what:

| Data | Owner | Why |
|------|-------|-----|
| `messages` | `run_agent` function | Grows over the loop's lifetime |
| `text_content` | Loop iteration | Reset each iteration |
| `pending_tools` | Loop iteration | Reset each iteration |
| `callbacks` | Caller (via `&mut`) | Borrowed for the loop's duration |
| `client` | Caller (via `&`) | Shared reference, never mutated |
| `registry` | Caller (via `&`) | Shared reference, never mutated |

The key insight: `messages` is the only state that persists across loop iterations. Everything else is created fresh each time through the loop. This is clean — each iteration produces a complete response, which either ends the conversation or adds tool results for the next iteration.

## Summary

In this chapter you:

- Parsed raw SSE streams with a byte buffer and line splitter
- Accumulated fragmented tool call arguments across stream chunks
- Built the core agent loop: stream → detect → execute → loop
- Managed mutable state across async streaming with `FnMut` callbacks
- Understood ownership patterns in the loop

This is the foundation. Every remaining chapter adds tools, context management, or UI on top of this loop.

---

**Next: [Chapter 5: Multi-Turn Evaluations →](./05-multi-turn-evals.md)**
