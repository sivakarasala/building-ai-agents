# Chapter 7: Web Search & Context Management

## Two Problems, One Chapter

1. **Web search** — The agent needs to look things up online.
2. **Context management** — Conversations grow. The LLM's context window doesn't. Eventually you hit the limit and need to compact.

These are linked: web search results are often large, accelerating context exhaustion.

## Web Search with OpenAI

OpenAI offers web search as a "provider tool" — instead of you executing a search locally, OpenAI executes it server-side. You include it in the tools array with `type: "function"`, but OpenAI handles the execution. The results appear as regular assistant messages.

However, this creates a compatibility issue. When you send the conversation history *back* to the API, you must filter out the web search tool call messages (they have a different structure). Let's handle this properly.

### The Web Search Tool Definition

Create `src/tools/web_search.rs`:

```rust
use anyhow::Result;
use serde_json::{json, Value};

use crate::agent::tool_registry::Tool;
use crate::api::types::{FunctionDefinition, ToolDefinition};

pub struct WebSearchTool;

impl Tool for WebSearchTool {
    fn name(&self) -> &str {
        "web_search"
    }

    fn definition(&self) -> ToolDefinition {
        // Note: This uses a special type for provider tools
        ToolDefinition {
            tool_type: "function".into(),
            function: FunctionDefinition {
                name: "web_search".into(),
                description: "Search the web for current information. \
                              Use this for questions about recent events, \
                              current facts, or anything that might have \
                              changed after your training data."
                    .into(),
                parameters: json!({
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "The search query"
                        }
                    },
                    "required": ["query"]
                }),
            },
        }
    }

    fn execute(&self, _args: Value) -> Result<String> {
        // Web search is a provider tool — OpenAI executes it server-side.
        // This method is never called directly.
        Ok("Web search is handled by the API provider.".into())
    }
}
```

### Message Filtering

When web search results come back in the stream, they include messages with `role: "tool"` and special content. Before sending the conversation history back, we need to filter messages that might confuse the API.

Create `src/agent/filter_messages.rs`:

```rust
use crate::api::types::Message;

/// Filter messages for API compatibility.
/// Removes tool results for provider tools (like web_search)
/// that the API handles internally.
pub fn filter_messages(messages: &[Message]) -> Vec<Message> {
    let provider_tool_names = ["web_search"];

    // Collect IDs of tool calls for provider tools
    let provider_call_ids: Vec<String> = messages
        .iter()
        .filter_map(|m| m.tool_calls.as_ref())
        .flatten()
        .filter(|tc| provider_tool_names.contains(&tc.function.name.as_str()))
        .map(|tc| tc.id.clone())
        .collect();

    messages
        .iter()
        .filter(|m| {
            // Keep all non-tool messages
            if m.role != "tool" {
                return true;
            }
            // Filter out tool results for provider tools
            if let Some(ref id) = m.tool_call_id {
                !provider_call_ids.contains(id)
            } else {
                true
            }
        })
        .cloned()
        .collect()
}
```

The iterator chain:
1. Find all tool calls whose function name is a provider tool
2. Collect their IDs
3. Filter out any `role: "tool"` messages whose `tool_call_id` matches

## Context Window Management

### The Problem

GPT-4.1-mini has a 128K token context window. That sounds like a lot, but:

- Each tool call + result can be 1-5K tokens
- Web search results can be 10K+ tokens
- After 10-20 tool calls, you're at 50K+ tokens
- The model's output quality degrades well before hitting the limit

### Token Estimation

Create `src/context/token_estimator.rs`:

```rust
use crate::api::types::Message;

/// Estimate token count for a message.
/// Uses the ~3.75 characters per token heuristic.
pub fn estimate_tokens(text: &str) -> usize {
    (text.len() as f64 / 3.75).ceil() as usize
}

/// Estimate total tokens for a conversation.
pub fn estimate_conversation_tokens(messages: &[Message]) -> usize {
    messages
        .iter()
        .map(|m| {
            let content_tokens = m
                .content
                .as_ref()
                .map(|c| estimate_tokens(c))
                .unwrap_or(0);

            let tool_call_tokens = m
                .tool_calls
                .as_ref()
                .map(|calls| {
                    calls.iter().map(|tc| {
                        estimate_tokens(&tc.function.name)
                            + estimate_tokens(&tc.function.arguments)
                    }).sum::<usize>()
                })
                .unwrap_or(0);

            // ~4 tokens overhead per message (role, separators)
            content_tokens + tool_call_tokens + 4
        })
        .sum()
}
```

Why estimate instead of using a proper tokenizer? The `tiktoken` tokenizer is a Python library. Rust ports exist but add complexity. The 3.75 chars/token heuristic is within 10% for English text — accurate enough for deciding when to compact.

### Model Limits

Create `src/context/model_limits.rs`:

```rust
/// Token limits for a model.
pub struct ModelLimits {
    pub context_window: usize,
    pub max_output: usize,
}

/// Threshold for triggering compaction (percentage of context used).
pub const COMPACTION_THRESHOLD: f64 = 0.75;

pub fn get_model_limits(model: &str) -> ModelLimits {
    match model {
        "gpt-4.1-mini" => ModelLimits {
            context_window: 128_000,
            max_output: 16_384,
        },
        "gpt-4.1" => ModelLimits {
            context_window: 128_000,
            max_output: 32_768,
        },
        _ => ModelLimits {
            context_window: 128_000,
            max_output: 16_384,
        },
    }
}

/// Check if compaction is needed.
pub fn should_compact(token_count: usize, model: &str) -> bool {
    let limits = get_model_limits(model);
    let threshold = (limits.context_window as f64 * COMPACTION_THRESHOLD) as usize;
    token_count > threshold
}

/// Token usage information for display.
pub struct TokenUsageInfo {
    pub used: usize,
    pub limit: usize,
    pub percentage: f64,
    pub threshold: f64,
}

pub fn get_token_usage(token_count: usize, model: &str) -> TokenUsageInfo {
    let limits = get_model_limits(model);
    TokenUsageInfo {
        used: token_count,
        limit: limits.context_window,
        percentage: (token_count as f64 / limits.context_window as f64) * 100.0,
        threshold: COMPACTION_THRESHOLD,
    }
}
```

### Conversation Compaction

When the conversation exceeds the threshold, we use the LLM itself to summarize it. Create `src/context/compaction.rs`:

```rust
use anyhow::Result;

use crate::api::client::OpenAIClient;
use crate::api::types::{ChatCompletionRequest, Message};

const COMPACTION_PROMPT: &str = "You are a conversation summarizer. \
    Summarize the following conversation, preserving all important details, \
    tool results, file contents, and decisions made. Be thorough but concise.";

/// Compact a conversation by summarizing it with the LLM.
pub async fn compact_conversation(
    client: &OpenAIClient,
    messages: &[Message],
) -> Result<Vec<Message>> {
    // Keep the system prompt
    let system_msg = messages
        .first()
        .filter(|m| m.role == "system")
        .cloned();

    // Build a summary of the conversation
    let conversation_text = messages
        .iter()
        .filter(|m| m.role != "system")
        .map(|m| {
            let content = m.content.as_deref().unwrap_or("");
            let tool_info = m.tool_calls.as_ref().map(|calls| {
                calls
                    .iter()
                    .map(|tc| format!("[tool: {}({})]", tc.function.name, tc.function.arguments))
                    .collect::<Vec<_>>()
                    .join(", ")
            });

            match tool_info {
                Some(info) => format!("{}: {} {}", m.role, content, info),
                None => format!("{}: {}", m.role, content),
            }
        })
        .collect::<Vec<_>>()
        .join("\n");

    let request = ChatCompletionRequest {
        model: "gpt-4.1-mini".into(),
        messages: vec![
            Message::system(COMPACTION_PROMPT),
            Message::user(&conversation_text),
        ],
        tools: None,
        stream: None,
    };

    let response = client.chat_completion(request).await?;

    let summary = response
        .choices
        .first()
        .and_then(|c| c.message.content.clone())
        .unwrap_or_else(|| "Conversation summary unavailable.".into());

    // Rebuild: system prompt + summary as assistant message
    let mut compacted = Vec::new();

    if let Some(sys) = system_msg {
        compacted.push(sys);
    }

    compacted.push(Message::assistant(&format!(
        "[Previous conversation summary]\n{summary}"
    )));

    Ok(compacted)
}
```

The compaction strategy:

1. Extract the system prompt (always keep it)
2. Flatten the entire conversation into text
3. Ask the LLM to summarize it
4. Replace the conversation with: system prompt + summary

This reduces a 50K-token conversation to ~2K tokens while preserving the important context.

### Module Structure

Create `src/context/mod.rs`:

```rust
pub mod compaction;
pub mod model_limits;
pub mod token_estimator;
```

## Integrating into the Agent Loop

Update the agent loop in `src/agent/run.rs` to check context usage and compact when needed:

```rust
use crate::context::compaction::compact_conversation;
use crate::context::model_limits::{get_token_usage, should_compact};
use crate::context::token_estimator::estimate_conversation_tokens;

// Add to AgentCallbacks:
pub struct AgentCallbacks {
    pub on_token: Box<dyn FnMut(&str)>,
    pub on_tool_call_start: Box<dyn FnMut(&str, &Value)>,
    pub on_tool_call_end: Box<dyn FnMut(&str, &str)>,
    pub on_complete: Box<dyn FnMut(&str)>,
    pub on_token_usage: Box<dyn FnMut(crate::context::model_limits::TokenUsageInfo)>,
}

// In the agent loop, before the API call:
pub async fn run_agent(/* ... */) -> Result<Vec<Message>> {
    // ...

    loop {
        // Check context usage
        let token_count = estimate_conversation_tokens(&messages);
        let model = "gpt-4.1-mini";

        let usage = get_token_usage(token_count, model);
        (callbacks.on_token_usage)(usage);

        if should_compact(token_count, model) {
            messages = compact_conversation(client, &messages).await?;

            // Re-add the latest user message if compaction removed it
            // (The user's most recent message is important context)
        }

        // ... rest of the loop (stream, execute tools, etc.)
    }
}
```

## Update Module Exports

Update `src/tools/mod.rs`:

```rust
pub mod file;
pub mod web_search;
```

Update `src/agent/mod.rs`:

```rust
pub mod filter_messages;
pub mod run;
pub mod system_prompt;
pub mod tool_registry;
```

Update `src/lib.rs`:

```rust
pub mod api;
pub mod agent;
pub mod context;
pub mod eval;
pub mod tools;
```

## Summary

In this chapter you:

- Added web search as a provider tool (executed server-side by OpenAI)
- Built message filtering to handle provider tool compatibility
- Implemented token estimation (~3.75 chars/token heuristic)
- Created model limits tracking with configurable thresholds
- Built LLM-powered conversation compaction
- Integrated context management into the agent loop

The context management system keeps long conversations viable without hitting token limits or degrading output quality.

---

**Next: [Chapter 8: Shell Tool & Code Execution →](./08-shell-tool.md)**
