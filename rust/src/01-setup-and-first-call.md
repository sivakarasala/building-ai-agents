# Chapter 1: Setup and Your First LLM Call

## No SDK. Just HTTP.

Most AI agent tutorials start with `pip install openai` or `npm install ai`. We're starting with `reqwest` — an HTTP client. OpenAI's API is just a REST endpoint. You send JSON, you get JSON back. Everything between is HTTP.

This matters because when something breaks — and it will — you'll know exactly which layer failed. Was it the HTTP connection? The JSON serialization? The API response format? There's no SDK to blame, no magic to debug through.

## Project Setup

```bash
cargo init agents-v2
cd agents-v2
```

### Dependencies

Add to `Cargo.toml`:

```toml
[package]
name = "agents-v2"
version = "0.1.0"
edition = "2021"

[dependencies]
# Async runtime
tokio = { version = "1", features = ["full"] }

# HTTP client with streaming
reqwest = { version = "0.12", features = ["json", "stream"] }

# Serialization
serde = { version = "1", features = ["derive"] }
serde_json = "1"

# Terminal UI (later chapters)
ratatui = "0.29"
crossterm = "0.28"

# CLI
clap = { version = "4", features = ["derive"] }

# Error handling
anyhow = "1"
thiserror = "2"

# Environment variables
dotenvy = "0.15"

# Streaming
futures-util = "0.3"
```

### Environment

Create `.env`:

```
OPENAI_API_KEY=your-openai-api-key-here
```

And `.gitignore`:

```
target/
.env
```

## The OpenAI Chat Completions API

Before writing code, let's understand the API we're calling. At its core:

```
POST https://api.openai.com/v1/chat/completions
Authorization: Bearer <your-api-key>
Content-Type: application/json

{
  "model": "gpt-5-mini",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What is an AI agent?"}
  ]
}
```

Response:

```json
{
  "id": "chatcmpl-abc123",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "An AI agent is..."
    },
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 25,
    "completion_tokens": 42,
    "total_tokens": 67
  }
}
```

That's it. JSON in, JSON out. Let's model this in Rust.

## API Types

Create `src/api/types.rs`:

```rust
use serde::{Deserialize, Serialize};

/// A single message in a conversation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ToolCall>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

impl Message {
    pub fn system(content: &str) -> Self {
        Self {
            role: "system".into(),
            content: Some(content.into()),
            tool_calls: None,
            tool_call_id: None,
        }
    }

    pub fn user(content: &str) -> Self {
        Self {
            role: "user".into(),
            content: Some(content.into()),
            tool_calls: None,
            tool_call_id: None,
        }
    }

    pub fn assistant(content: &str) -> Self {
        Self {
            role: "assistant".into(),
            content: Some(content.into()),
            tool_calls: None,
            tool_call_id: None,
        }
    }

    pub fn tool_result(tool_call_id: &str, content: &str) -> Self {
        Self {
            role: "tool".into(),
            content: Some(content.into()),
            tool_calls: None,
            tool_call_id: Some(tool_call_id.into()),
        }
    }
}

/// A tool call requested by the assistant.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    #[serde(rename = "type")]
    pub call_type: String,
    pub function: FunctionCall,
}

/// The function name and arguments for a tool call.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionCall {
    pub name: String,
    pub arguments: String, // JSON string — parsed later
}

/// Tool definition sent to the API.
#[derive(Debug, Clone, Serialize)]
pub struct ToolDefinition {
    #[serde(rename = "type")]
    pub tool_type: String,
    pub function: FunctionDefinition,
}

/// Function metadata within a tool definition.
#[derive(Debug, Clone, Serialize)]
pub struct FunctionDefinition {
    pub name: String,
    pub description: String,
    pub parameters: serde_json::Value, // JSON Schema
}

/// Request body for chat completions.
#[derive(Debug, Serialize)]
pub struct ChatCompletionRequest {
    pub model: String,
    pub messages: Vec<Message>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<ToolDefinition>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stream: Option<bool>,
}

/// Non-streaming response.
#[derive(Debug, Deserialize)]
pub struct ChatCompletionResponse {
    pub id: String,
    pub choices: Vec<Choice>,
    pub usage: Option<Usage>,
}

#[derive(Debug, Deserialize)]
pub struct Choice {
    pub index: usize,
    pub message: Message,
    pub finish_reason: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct Usage {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub total_tokens: u32,
}
```

A few Rust-specific notes:

- **`#[serde(skip_serializing_if = "Option::is_none")]`** — Omits fields from JSON when they're `None`. The API doesn't expect `"tool_calls": null` on user messages.
- **`#[serde(rename = "type")]`** — Maps Rust's `call_type` to JSON's `"type"` (since `type` is a reserved keyword in Rust).
- **`arguments: String`** — Tool call arguments are a JSON string within JSON. We'll parse them separately.
- **`parameters: serde_json::Value`** — JSON Schema is dynamic, so we use `Value` rather than a concrete type.

## The HTTP Client

Create `src/api/client.rs`:

```rust
use anyhow::{Context, Result};
use reqwest::Client;

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

    /// Make a non-streaming chat completion request.
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

        let body = response
            .json::<ChatCompletionResponse>()
            .await
            .context("Failed to parse OpenAI response")?;

        Ok(body)
    }
}
```

This is deliberately minimal. No retries, no streaming (yet), no fancy error types. Just `reqwest` calling a URL with a bearer token.

The `anyhow::Context` trait lets us add human-readable context to errors: "Failed to send request to OpenAI" wraps the underlying `reqwest` error so you know which layer failed.

### Module Structure

Create `src/api/mod.rs`:

```rust
pub mod client;
pub mod types;
```

## The System Prompt

Create `src/agent/system_prompt.rs`:

```rust
pub const SYSTEM_PROMPT: &str = "You are a helpful AI assistant. You provide clear, accurate, and concise responses to user questions.

Guidelines:
- Be direct and helpful
- If you don't know something, say so honestly
- Provide explanations when they add value
- Stay focused on the user's actual question";
```

Create `src/agent/mod.rs`:

```rust
pub mod system_prompt;
```

## Your First LLM Call

Now wire it together. Replace `src/main.rs`:

```rust
mod api;
mod agent;

use anyhow::Result;
use api::{
    client::OpenAIClient,
    types::{ChatCompletionRequest, Message},
};
use agent::system_prompt::SYSTEM_PROMPT;

#[tokio::main]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();

    let api_key = std::env::var("OPENAI_API_KEY")
        .expect("OPENAI_API_KEY must be set");

    let client = OpenAIClient::new(api_key);

    let request = ChatCompletionRequest {
        model: "gpt-5-mini".into(),
        messages: vec![
            Message::system(SYSTEM_PROMPT),
            Message::user("What is an AI agent in one sentence?"),
        ],
        tools: None,
        stream: None,
    };

    let response = client.chat_completion(request).await?;

    if let Some(choice) = response.choices.first() {
        if let Some(content) = &choice.message.content {
            println!("{content}");
        }
    }

    Ok(())
}
```

Run it:

```bash
cargo run
```

You should see something like:

```
An AI agent is an autonomous system that perceives its environment,
makes decisions, and takes actions to achieve specific goals.
```

That's a raw HTTP call to OpenAI, deserialized into Rust structs. No SDK involved.

## What We Built

Look at what's happening:

1. `dotenvy::dotenv()` loads the `.env` file
2. We construct a `ChatCompletionRequest` — a plain Rust struct
3. `serde_json` serializes it to JSON automatically via `reqwest`'s `.json(&request)`
4. `reqwest` sends the HTTP POST with our bearer token
5. The response JSON is deserialized into `ChatCompletionResponse`
6. We extract the text from the first choice

Every step is explicit. If the API changes its response format, the `Deserialize` derive will catch it at runtime with a clear error. If we send a malformed request, the API returns an error and we surface the response body.

## Summary

In this chapter you:

- Set up a Rust project with `reqwest`, `serde`, and `tokio`
- Modeled the OpenAI API types as Rust structs
- Built an HTTP client that calls the chat completions endpoint
- Made your first LLM call from raw HTTP

In the next chapter, we'll add tool definitions and teach the LLM to call our functions.

---

**Next: [Chapter 2: Tool Calling →](./02-tool-calling.md)**
