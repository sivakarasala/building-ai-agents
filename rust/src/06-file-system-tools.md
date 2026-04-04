# Chapter 6: File System Tools

## Expanding the Toolbox

In Chapter 2, we built `ReadFileTool` and `ListFilesTool`. Now we add `WriteFileTool` and `DeleteFileTool` — tools that modify the filesystem. These are the first *dangerous* tools, which matters when we add human-in-the-loop approval in Chapter 9.

## WriteFile

Add to `src/tools/file.rs`:

```rust
// ─── WriteFile ────────────────────────────────────────────

pub struct WriteFileTool;

impl Tool for WriteFileTool {
    fn name(&self) -> &str {
        "write_file"
    }

    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            tool_type: "function".into(),
            function: FunctionDefinition {
                name: "write_file".into(),
                description: "Write content to a file at the specified path. \
                              Creates parent directories if they don't exist. \
                              Overwrites the file if it already exists."
                    .into(),
                parameters: json!({
                    "type": "object",
                    "properties": {
                        "path": {
                            "type": "string",
                            "description": "The file path to write to"
                        },
                        "content": {
                            "type": "string",
                            "description": "The content to write"
                        }
                    },
                    "required": ["path", "content"]
                }),
            },
        }
    }

    fn execute(&self, args: Value) -> Result<String> {
        let path = args["path"]
            .as_str()
            .context("Missing 'path' argument")?;
        let content = args["content"]
            .as_str()
            .context("Missing 'content' argument")?;

        // Create parent directories
        if let Some(parent) = std::path::Path::new(path).parent() {
            if !parent.exists() {
                fs::create_dir_all(parent)
                    .context("Failed to create parent directories")?;
            }
        }

        match fs::write(path, content) {
            Ok(()) => Ok(format!(
                "Successfully wrote {} bytes to {path}",
                content.len()
            )),
            Err(e) => Ok(format!("Error writing file: {e}")),
        }
    }
}
```

### `create_dir_all` — The Recursive Mkdir

`fs::create_dir_all` is Rust's equivalent of `mkdir -p`. If you write to `src/deep/nested/file.rs`, it creates `src/deep/nested/` first. This is the only operation where we propagate `Err` with `?` — failing to create directories is unexpected (usually a permissions issue), not a normal tool error like "file not found."

## DeleteFile

```rust
// ─── DeleteFile ───────────────────────────────────────────

pub struct DeleteFileTool;

impl Tool for DeleteFileTool {
    fn name(&self) -> &str {
        "delete_file"
    }

    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            tool_type: "function".into(),
            function: FunctionDefinition {
                name: "delete_file".into(),
                description: "Delete a file at the specified path.".into(),
                parameters: json!({
                    "type": "object",
                    "properties": {
                        "path": {
                            "type": "string",
                            "description": "The path to the file to delete"
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

        match fs::remove_file(path) {
            Ok(()) => Ok(format!("Successfully deleted {path}")),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Ok(format!("Error: File not found: {path}"))
            }
            Err(e) => Ok(format!("Error deleting file: {e}")),
        }
    }
}
```

## Registering All File Tools

Update `src/main.rs` to include the new tools:

```rust
use tools::file::{ReadFileTool, ListFilesTool, WriteFileTool, DeleteFileTool};

// In main():
let mut registry = ToolRegistry::new();
registry.register(Box::new(ReadFileTool));
registry.register(Box::new(ListFilesTool));
registry.register(Box::new(WriteFileTool));
registry.register(Box::new(DeleteFileTool));
```

## Tool Safety Classification

Not all tools are equal. `read_file` is safe — it can't break anything. `delete_file` is dangerous. We'll use this classification in Chapter 9 for human-in-the-loop approval. For now, let's add a method to the `Tool` trait.

Update `src/agent/tool_registry.rs`:

```rust
pub trait Tool: Send + Sync {
    fn name(&self) -> &str;
    fn definition(&self) -> ToolDefinition;
    fn execute(&self, args: Value) -> Result<String>;

    /// Whether this tool requires human approval before execution.
    /// Override to return true for dangerous tools.
    fn requires_approval(&self) -> bool {
        false
    }
}
```

Default methods in traits — tools are safe by default. Override for dangerous ones:

```rust
// In WriteFileTool
impl Tool for WriteFileTool {
    // ... other methods ...

    fn requires_approval(&self) -> bool {
        true
    }
}

// In DeleteFileTool
impl Tool for DeleteFileTool {
    // ... other methods ...

    fn requires_approval(&self) -> bool {
        true
    }
}
```

Add a lookup method to `ToolRegistry`:

```rust
impl ToolRegistry {
    // ... existing methods ...

    /// Check if a tool requires approval.
    pub fn requires_approval(&self, name: &str) -> bool {
        self.tools
            .get(name)
            .map(|t| t.requires_approval())
            .unwrap_or(false)
    }
}
```

## Error Handling Philosophy

Look at the two error paths in `WriteFileTool`:

```rust
// Propagated with ? — unexpected, indicates a bug or system issue
fs::create_dir_all(parent)
    .context("Failed to create parent directories")?;

// Returned as Ok(String) — expected, the LLM can recover
Err(e) => Ok(format!("Error writing file: {e}")),
```

The rule: if the LLM can do something useful with the error (try a different path, ask the user), return `Ok(error_message)`. If the error means something is fundamentally wrong (permissions failure, disk full), propagate with `?`.

## Testing the Tools

```bash
cargo run
```

Try asking: "Create a file called test.txt with 'Hello from the agent', then read it back to verify."

The agent should:
1. Call `write_file` to create the file
2. Call `read_file` to verify its contents
3. Report that the file was created successfully

## Summary

In this chapter you:

- Added `WriteFileTool` with recursive directory creation
- Added `DeleteFileTool` with proper error handling
- Introduced the `requires_approval` trait method with default implementations
- Applied the error handling philosophy: `Ok(message)` for recoverable, `Err` for unexpected

Next, we add web search and solve the context window management problem.

---

**Next: [Chapter 7: Web Search & Context Management →](./07-web-search-context-management.md)**
