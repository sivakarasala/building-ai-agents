# Chapter 2: Tool Calling with JSON Schema

## The Tool Trait

In TypeScript, a tool is an object with a description and an execute function. In Python, it's a dict with a JSON Schema and a callable. In Rust, we use a **trait**.

The `Tool` trait defines what every tool must provide:

```rust
// src/agent/tool_registry.rs

use anyhow::Result;
use serde_json::Value;

use crate::api::types::ToolDefinition;

/// Every tool implements this trait.
pub trait Tool: Send + Sync {
    /// The tool's name (matches the API).
    fn name(&self) -> &str;

    /// The OpenAI tool definition (sent to the API).
    fn definition(&self) -> ToolDefinition;

    /// Execute the tool with the given arguments.
    fn execute(&self, args: Value) -> Result<String>;
}
```

Three things to note:

- **`Send + Sync`** — Required because tools are shared across async tasks. The agent loop runs on `tokio`, which may move tasks between threads.
- **`args: Value`** — We accept `serde_json::Value` rather than typed args. The LLM generates arbitrary JSON that matches our schema, but Rust can't know the shape at compile time. We parse it inside each tool's `execute` method.
- **Returns `Result<String>`** — Tools can fail. We propagate errors up to the agent loop, which converts them to error messages for the LLM.

## The Tool Registry

```rust
// continued in src/agent/tool_registry.rs

use std::collections::HashMap;

pub struct ToolRegistry {
    tools: HashMap<String, Box<dyn Tool>>,
}

impl ToolRegistry {
    pub fn new() -> Self {
        Self {
            tools: HashMap::new(),
        }
    }

    pub fn register(&mut self, tool: Box<dyn Tool>) {
        self.tools.insert(tool.name().to_string(), tool);
    }

    /// Get all tool definitions for the API.
    pub fn definitions(&self) -> Vec<ToolDefinition> {
        self.tools.values().map(|t| t.definition()).collect()
    }

    /// Execute a tool by name.
    pub fn execute(&self, name: &str, args: Value) -> Result<String> {
        match self.tools.get(name) {
            Some(tool) => tool.execute(args),
            None => Ok(format!("Unknown tool: {name}")),
        }
    }
}
```

`Box<dyn Tool>` is the key design choice. We can't use generics here (like `ToolRegistry<T: Tool>`) because the registry holds *different* tool types — `ReadFileTool`, `ListFilesTool`, etc. Trait objects let us store heterogeneous types behind a common interface. See **Appendix C** if this pattern is new to you.

## Your First Tool: ReadFile

Create `src/tools/file.rs`:

```rust
use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::fs;

use crate::agent::tool_registry::Tool;
use crate::api::types::{FunctionDefinition, ToolDefinition};

// ─── ReadFile ──────────────────────────────────────────────

pub struct ReadFileTool;

impl Tool for ReadFileTool {
    fn name(&self) -> &str {
        "read_file"
    }

    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            tool_type: "function".into(),
            function: FunctionDefinition {
                name: "read_file".into(),
                description: "Read the contents of a file at the specified path. \
                              Use this to examine file contents."
                    .into(),
                parameters: json!({
                    "type": "object",
                    "properties": {
                        "path": {
                            "type": "string",
                            "description": "The path to the file to read"
                        }
                    },
                    "required": ["path"]
                }),
            },
        }
    }

    fn execute(&self, args: Value) -> Result<String> {
        let path = args["path"]
            .as_str()
            .context("Missing 'path' argument")?;

        match fs::read_to_string(path) {
            Ok(content) => Ok(content),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Ok(format!("Error: File not found: {path}"))
            }
            Err(e) => Ok(format!("Error reading file: {e}")),
        }
    }
}

// ─── ListFiles ─────────────────────────────────────────────

pub struct ListFilesTool;

impl Tool for ListFilesTool {
    fn name(&self) -> &str {
        "list_files"
    }

    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            tool_type: "function".into(),
            function: FunctionDefinition {
                name: "list_files".into(),
                description: "List all files and directories in the specified \
                              directory path."
                    .into(),
                parameters: json!({
                    "type": "object",
                    "properties": {
                        "directory": {
                            "type": "string",
                            "description": "The directory path to list contents of",
                            "default": "."
                        }
                    }
                }),
            },
        }
    }

    fn execute(&self, args: Value) -> Result<String> {
        let directory = args["directory"].as_str().unwrap_or(".");

        match fs::read_dir(directory) {
            Ok(entries) => {
                let mut items: Vec<String> = Vec::new();
                for entry in entries {
                    let entry = entry?;
                    let file_type = if entry.file_type()?.is_dir() {
                        "[dir]"
                    } else {
                        "[file]"
                    };
                    let name = entry.file_name().to_string_lossy().to_string();
                    items.push(format!("{file_type} {name}"));
                }
                items.sort();
                if items.is_empty() {
                    Ok(format!("Directory {directory} is empty"))
                } else {
                    Ok(items.join("\n"))
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Ok(format!("Error: Directory not found: {directory}"))
            }
            Err(e) => Ok(format!("Error listing directory: {e}")),
        }
    }
}
```

### Why Tools Return `Ok(error_message)` Instead of `Err`

Notice the pattern:

```rust
Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
    Ok(format!("Error: File not found: {path}"))
}
```

We return `Ok` with an error description rather than propagating `Err`. This is deliberate — tool results go back to the LLM. If `read_file` fails with "File not found", the LLM can try a different path. If we returned `Err`, the agent loop would need special error handling to convert it to a tool result message. Keeping it as `Ok(String)` means every tool result, success or failure, follows the same path.

The `Result` return type is still useful for *unexpected* errors — things like "args is not valid JSON" that indicate a bug, not a normal failure.

### The `json!` Macro

```rust
parameters: json!({
    "type": "object",
    "properties": {
        "path": {
            "type": "string",
            "description": "The path to the file to read"
        }
    },
    "required": ["path"]
}),
```

`serde_json::json!` creates a `Value` from JSON-like syntax. This is how we build JSON Schema without defining a struct for every possible schema shape. It's dynamic but compile-time checked for syntax.

## Module Structure

Create `src/tools/mod.rs`:

```rust
pub mod file;
```

Update `src/agent/mod.rs`:

```rust
pub mod system_prompt;
pub mod tool_registry;
```

## Making a Tool Call

Update `src/main.rs` to include tools:

```rust
mod api;
mod agent;
mod tools;

use anyhow::Result;
use api::{
    client::OpenAIClient,
    types::{ChatCompletionRequest, Message},
};
use agent::{system_prompt::SYSTEM_PROMPT, tool_registry::ToolRegistry};
use tools::file::{ReadFileTool, ListFilesTool};

#[tokio::main]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();

    let api_key = std::env::var("OPENAI_API_KEY")
        .expect("OPENAI_API_KEY must be set");

    let client = OpenAIClient::new(api_key);

    // Build the tool registry
    let mut registry = ToolRegistry::new();
    registry.register(Box::new(ReadFileTool));
    registry.register(Box::new(ListFilesTool));

    let request = ChatCompletionRequest {
        model: "gpt-5-mini".into(),
        messages: vec![
            Message::system(SYSTEM_PROMPT),
            Message::user("What files are in the current directory?"),
        ],
        tools: Some(registry.definitions()),
        stream: None,
    };

    let response = client.chat_completion(request).await?;

    if let Some(choice) = response.choices.first() {
        let msg = &choice.message;

        if let Some(content) = &msg.content {
            println!("Text: {content}");
        }

        if let Some(tool_calls) = &msg.tool_calls {
            for tc in tool_calls {
                println!(
                    "Tool call: {} ({})",
                    tc.function.name, tc.function.arguments
                );

                // Actually execute the tool
                let args: serde_json::Value =
                    serde_json::from_str(&tc.function.arguments)?;
                let result = registry.execute(&tc.function.name, args)?;
                println!("Result: {}", &result[..result.len().min(200)]);
            }
        }
    }

    Ok(())
}
```

Run it:

```bash
cargo run
```

You should see:

```
Tool call: list_files ({"directory":"."})
Result: [dir] src
[dir] target
[file] Cargo.lock
[file] Cargo.toml
...
```

The LLM chose `list_files`, we executed it, and got real filesystem results. But the LLM never saw those results — we need the agent loop for that.

## Summary

In this chapter you:

- Defined the `Tool` trait for type-safe, dynamic tool dispatch
- Built a `ToolRegistry` with `Box<dyn Tool>` for heterogeneous tool storage
- Implemented `ReadFileTool` and `ListFilesTool`
- Used `serde_json::json!` for JSON Schema generation
- Made your first tool call and execution

The LLM can select tools and we can execute them. In the next chapter, we'll build evaluations to test tool selection systematically.

---

**Next: [Chapter 3: Single-Turn Evaluations →](./03-single-turn-evals.md)**
