# Chapter 8: Shell Tool & Code Execution

## Running Commands

The agent can read files and browse the web. Now we give it the ability to *do things* — run shell commands and execute code. These are the most powerful tools, and the most dangerous.

## The Shell Tool

Create `src/tools/shell.rs`:

```rust
use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::process::Command;
use std::time::Duration;

use crate::agent::tool_registry::Tool;
use crate::api::types::{FunctionDefinition, ToolDefinition};

// ─── RunCommand ───────────────────────────────────────────

pub struct RunCommandTool;

impl Tool for RunCommandTool {
    fn name(&self) -> &str {
        "run_command"
    }

    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            tool_type: "function".into(),
            function: FunctionDefinition {
                name: "run_command".into(),
                description: "Execute a shell command and return its output. \
                              Use this for system operations, running scripts, \
                              installing packages, etc."
                    .into(),
                parameters: json!({
                    "type": "object",
                    "properties": {
                        "command": {
                            "type": "string",
                            "description": "The shell command to execute"
                        }
                    },
                    "required": ["command"]
                }),
            },
        }
    }

    fn execute(&self, args: Value) -> Result<String> {
        let command = args["command"]
            .as_str()
            .context("Missing 'command' argument")?;

        let output = Command::new("sh")
            .arg("-c")
            .arg(command)
            .output();

        match output {
            Ok(result) => {
                let stdout = String::from_utf8_lossy(&result.stdout);
                let stderr = String::from_utf8_lossy(&result.stderr);

                let mut response = String::new();

                if !stdout.is_empty() {
                    response.push_str(&stdout);
                }

                if !stderr.is_empty() {
                    if !response.is_empty() {
                        response.push('\n');
                    }
                    response.push_str("STDERR:\n");
                    response.push_str(&stderr);
                }

                if response.is_empty() {
                    response = format!(
                        "Command completed with exit code {}",
                        result.status.code().unwrap_or(-1)
                    );
                }

                Ok(response)
            }
            Err(e) => Ok(format!("Error executing command: {e}")),
        }
    }

    fn requires_approval(&self) -> bool {
        true
    }
}
```

### `std::process::Command` vs `tokio::process::Command`

We use the synchronous `std::process::Command`, not `tokio::process::Command`. Our `Tool::execute` method is synchronous (`fn execute(&self, args: Value) -> Result<String>`). Why?

1. **Simplicity** — Most tools are synchronous operations. Making the trait async adds complexity to every tool implementation.
2. **Blocking** — Yes, `Command::new` blocks the thread. For short-lived commands (the common case), this is fine. For long-running commands, we'd need a different approach — but that's a production concern (Chapter 10).

The tradeoff: if the LLM asks to run `sleep 30`, it blocks the tokio runtime for 30 seconds. In production, you'd spawn the command on a blocking thread with `tokio::task::spawn_blocking`. For our learning agent, synchronous is simpler.

### Shell Injection

Note that we pass the command string directly to `sh -c`. This is intentional — the LLM generates the command, and the user approves it via HITL. But it means the tool can run *any* shell command, including pipes, redirects, and subshells. The safety layer is human approval, not input sanitization.

## The Code Execution Tool

For running code snippets, we create a composite tool that writes code to a temp file and executes it:

```rust
// ─── CodeExecution ────────────────────────────────────────

pub struct CodeExecutionTool;

impl Tool for CodeExecutionTool {
    fn name(&self) -> &str {
        "execute_code"
    }

    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            tool_type: "function".into(),
            function: FunctionDefinition {
                name: "execute_code".into(),
                description: "Execute a code snippet in the specified language. \
                              Supports python, javascript/node, ruby, and bash."
                    .into(),
                parameters: json!({
                    "type": "object",
                    "properties": {
                        "language": {
                            "type": "string",
                            "description": "The programming language",
                            "enum": ["python", "javascript", "ruby", "bash"]
                        },
                        "code": {
                            "type": "string",
                            "description": "The code to execute"
                        }
                    },
                    "required": ["language", "code"]
                }),
            },
        }
    }

    fn execute(&self, args: Value) -> Result<String> {
        let language = args["language"]
            .as_str()
            .context("Missing 'language' argument")?;
        let code = args["code"]
            .as_str()
            .context("Missing 'code' argument")?;

        let (cmd, extension) = match language {
            "python" => ("python3", "py"),
            "javascript" => ("node", "js"),
            "ruby" => ("ruby", "rb"),
            "bash" => ("bash", "sh"),
            _ => return Ok(format!("Unsupported language: {language}")),
        };

        // Write to a temp file
        let temp_dir = std::env::temp_dir();
        let temp_file = temp_dir.join(format!("agent_code.{extension}"));
        std::fs::write(&temp_file, code)
            .context("Failed to write temp file")?;

        let output = Command::new(cmd)
            .arg(&temp_file)
            .output();

        // Clean up
        let _ = std::fs::remove_file(&temp_file);

        match output {
            Ok(result) => {
                let stdout = String::from_utf8_lossy(&result.stdout);
                let stderr = String::from_utf8_lossy(&result.stderr);

                if result.status.success() {
                    if stdout.is_empty() {
                        Ok("Code executed successfully (no output)".into())
                    } else {
                        Ok(stdout.to_string())
                    }
                } else {
                    Ok(format!(
                        "Error (exit {}):\n{}{}",
                        result.status.code().unwrap_or(-1),
                        stderr,
                        if !stdout.is_empty() {
                            format!("\nStdout:\n{stdout}")
                        } else {
                            String::new()
                        }
                    ))
                }
            }
            Err(e) => Ok(format!("Failed to execute {cmd}: {e}")),
        }
    }

    fn requires_approval(&self) -> bool {
        true
    }
}
```

### The `enum` in JSON Schema

```json
"enum": ["python", "javascript", "ruby", "bash"]
```

This constrains the LLM's `language` argument to one of four values. Without it, the model might generate `"lang": "py"` or `"language": "Python"`, which would hit our `_ => unsupported` branch. The `enum` field in JSON Schema tells the LLM exactly which values are valid.

### Temp File Pattern

```rust
let temp_dir = std::env::temp_dir();
let temp_file = temp_dir.join(format!("agent_code.{extension}"));
std::fs::write(&temp_file, code)?;
// ... execute ...
let _ = std::fs::remove_file(&temp_file);
```

We write to a temp file, execute it, and clean up. `let _ =` on the remove is intentional — if cleanup fails, we don't care. The OS cleans temp files eventually.

A more robust approach would use the `tempfile` crate for automatic cleanup, but `std::env::temp_dir` is sufficient and adds no dependencies.

## Registering All Tools

Update `src/main.rs`:

```rust
use tools::file::{ReadFileTool, ListFilesTool, WriteFileTool, DeleteFileTool};
use tools::shell::{RunCommandTool, CodeExecutionTool};
use tools::web_search::WebSearchTool;

// In main():
let mut registry = ToolRegistry::new();
registry.register(Box::new(ReadFileTool));
registry.register(Box::new(ListFilesTool));
registry.register(Box::new(WriteFileTool));
registry.register(Box::new(DeleteFileTool));
registry.register(Box::new(RunCommandTool));
registry.register(Box::new(CodeExecutionTool));
registry.register(Box::new(WebSearchTool));
```

Update `src/tools/mod.rs`:

```rust
pub mod file;
pub mod shell;
pub mod web_search;
```

## Adding Shell Tool Evals

Create `eval_data/shell_tools.json`:

```json
[
    {
        "input": "Run ls to see files in the current directory",
        "expected_tool": "run_command"
    },
    {
        "input": "Write a Python script that prints hello world and run it",
        "expected_tool": "execute_code",
        "secondary_tools": ["run_command"]
    },
    {
        "input": "Check the git status of this repo",
        "expected_tool": "run_command"
    },
    {
        "input": "What is 2 + 2?",
        "expected_tool": "none"
    }
]
```

## Summary

In this chapter you:

- Built a shell command tool using `std::process::Command`
- Created a code execution tool with temp file management
- Used JSON Schema `enum` to constrain LLM arguments
- Registered all seven tools in the agent
- Understood the tradeoffs between sync and async command execution

The agent now has a complete toolset: file I/O, web search, shell commands, and code execution. In the next chapter, we build the terminal UI and add human approval for dangerous operations.

---

**Next: [Chapter 9: Terminal UI with Ratatui →](./09-terminal-ui.md)**
