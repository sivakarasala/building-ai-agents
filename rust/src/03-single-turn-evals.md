# Chapter 3: Single-Turn Evaluations

## Why Evals?

You have tools. The LLM can call them. But *does it call the right ones*? If you ask "What files are in this directory?", does the model pick `list_files` or `read_file`? If you ask "What's the weather?", does it correctly use *no* tools?

Evaluations answer these questions systematically. Instead of testing by hand each time you change a prompt or add a tool, you run a suite of test cases that verify tool selection.

This chapter builds a single-turn eval framework — one user message in, one tool call out, scored automatically.

## Eval Types

Create `src/eval/types.rs`:

```rust
use serde::{Deserialize, Serialize};

/// A single evaluation test case.
#[derive(Debug, Clone, Deserialize)]
pub struct EvalCase {
    pub input: String,
    pub expected_tool: String,
    #[serde(default)]
    pub secondary_tools: Vec<String>,
}

/// The result of running one eval case.
#[derive(Debug, Clone, Serialize)]
pub struct EvalResult {
    pub input: String,
    pub expected_tool: String,
    pub actual_tool: Option<String>,
    pub passed: bool,
    pub score: f64,
    pub reason: String,
}

/// Summary of an entire eval suite.
#[derive(Debug, Clone, Serialize)]
pub struct EvalSummary {
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    pub average_score: f64,
    pub results: Vec<EvalResult>,
}
```

Three case types drive the scoring:

- **Golden tool** (`expected_tool`) — The best tool for this input. Full marks.
- **Secondary tools** (`secondary_tools`) — Acceptable alternatives. Partial credit.
- **Negative cases** — Set `expected_tool` to `"none"`. The model should respond with text, not a tool call.

## Evaluators

Create `src/eval/evaluators.rs`:

```rust
use super::types::{EvalCase, EvalResult};

/// Score a single tool call against an eval case.
pub fn evaluate_tool_call(case: &EvalCase, actual_tool: Option<&str>) -> EvalResult {
    let (passed, score, reason) = match actual_tool {
        // Model called a tool
        Some(tool) => {
            if tool == case.expected_tool {
                (true, 1.0, format!("Correct: selected {tool}"))
            } else if case.secondary_tools.contains(&tool.to_string()) {
                (true, 0.5, format!("Acceptable: selected {tool} (secondary)"))
            } else if case.expected_tool == "none" {
                (false, 0.0, format!("Expected no tool call, got {tool}"))
            } else {
                (
                    false,
                    0.0,
                    format!(
                        "Wrong tool: expected {}, got {tool}",
                        case.expected_tool
                    ),
                )
            }
        }
        // Model didn't call any tool
        None => {
            if case.expected_tool == "none" {
                (true, 1.0, "Correct: no tool call".into())
            } else {
                (
                    false,
                    0.0,
                    format!("Expected {}, got no tool call", case.expected_tool),
                )
            }
        }
    };

    EvalResult {
        input: case.input.clone(),
        expected_tool: case.expected_tool.clone(),
        actual_tool: actual_tool.map(String::from),
        passed,
        score,
        reason,
    }
}

/// Summarize a batch of eval results.
pub fn summarize(results: Vec<EvalResult>) -> super::types::EvalSummary {
    let total = results.len();
    let passed = results.iter().filter(|r| r.passed).count();
    let failed = total - passed;
    let average_score = if total > 0 {
        results.iter().map(|r| r.score).sum::<f64>() / total as f64
    } else {
        0.0
    };

    super::types::EvalSummary {
        total,
        passed,
        failed,
        average_score,
        results,
    }
}
```

### Why `Option<&str>` for `actual_tool`?

The model might not call any tool — it might just respond with text. `None` represents that case. We borrow the string (`&str`) because we don't need to own it; the caller holds the data.

## The Executor

The executor sends a single message to the API and extracts which tool was called. Create `src/eval/executors.rs`:

```rust
use anyhow::Result;

use crate::api::client::OpenAIClient;
use crate::api::types::{ChatCompletionRequest, Message, ToolDefinition};
use crate::agent::system_prompt::SYSTEM_PROMPT;

/// Send a single user message and return the tool name the model chose.
pub async fn run_single_turn(
    client: &OpenAIClient,
    tools: &[ToolDefinition],
    input: &str,
) -> Result<Option<String>> {
    let request = ChatCompletionRequest {
        model: "gpt-4.1-mini".into(),
        messages: vec![
            Message::system(SYSTEM_PROMPT),
            Message::user(input),
        ],
        tools: Some(tools.to_vec()),
        stream: None,
    };

    let response = client.chat_completion(request).await?;

    let tool_name = response
        .choices
        .first()
        .and_then(|c| c.message.tool_calls.as_ref())
        .and_then(|calls| calls.first())
        .map(|tc| tc.function.name.clone());

    Ok(tool_name)
}
```

Note the chain of `and_then` calls. This is Rust's way of navigating nested `Option`s without nested `if let` blocks:

1. Get the first choice (might not exist)
2. Get its tool_calls (might be `None`)
3. Get the first tool call (might be empty)
4. Extract the function name

Each step returns `Option`, and `and_then` short-circuits on `None`.

## Test Data

Create `eval_data/file_tools.json`:

```json
[
    {
        "input": "What files are in the current directory?",
        "expected_tool": "list_files"
    },
    {
        "input": "Show me the contents of src/main.rs",
        "expected_tool": "read_file"
    },
    {
        "input": "Read the Cargo.toml file",
        "expected_tool": "read_file",
        "secondary_tools": ["list_files"]
    },
    {
        "input": "What is Rust?",
        "expected_tool": "none"
    },
    {
        "input": "Tell me a joke",
        "expected_tool": "none"
    },
    {
        "input": "List everything in the src directory",
        "expected_tool": "list_files"
    }
]
```

## Running Evals

Create `src/eval/mod.rs`:

```rust
pub mod evaluators;
pub mod executors;
pub mod types;
```

Now add an eval binary. Create `src/bin/eval_single.rs`:

```rust
use anyhow::Result;
use std::fs;

use agents_v2::api::client::OpenAIClient;
use agents_v2::agent::tool_registry::ToolRegistry;
use agents_v2::eval::evaluators::{evaluate_tool_call, summarize};
use agents_v2::eval::executors::run_single_turn;
use agents_v2::eval::types::EvalCase;
use agents_v2::tools::file::{ReadFileTool, ListFilesTool};

#[tokio::main]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();

    let api_key = std::env::var("OPENAI_API_KEY")
        .expect("OPENAI_API_KEY must be set");

    let client = OpenAIClient::new(api_key);

    // Build registry
    let mut registry = ToolRegistry::new();
    registry.register(Box::new(ReadFileTool));
    registry.register(Box::new(ListFilesTool));

    let definitions = registry.definitions();

    // Load test data
    let data = fs::read_to_string("eval_data/file_tools.json")?;
    let cases: Vec<EvalCase> = serde_json::from_str(&data)?;

    println!("Running {} eval cases...\n", cases.len());

    let mut results = Vec::new();

    for case in &cases {
        let actual = run_single_turn(&client, &definitions, &case.input).await?;
        let result = evaluate_tool_call(case, actual.as_deref());

        let status = if result.passed { "PASS" } else { "FAIL" };
        println!("[{status}] \"{}\" → {}", result.input, result.reason);

        results.push(result);
    }

    let summary = summarize(results);

    println!("\n--- Summary ---");
    println!(
        "Passed: {}/{} ({:.0}%)",
        summary.passed,
        summary.total,
        summary.average_score * 100.0
    );
    if summary.failed > 0 {
        println!("Failed: {}", summary.failed);
    }

    Ok(())
}
```

For the binary to access your library code, update `Cargo.toml` to include a `[lib]` section:

```toml
[lib]
name = "agents_v2"
path = "src/lib.rs"

[[bin]]
name = "agents-v2"
path = "src/main.rs"

[[bin]]
name = "eval-single"
path = "src/bin/eval_single.rs"
```

And create `src/lib.rs` to re-export modules:

```rust
pub mod api;
pub mod agent;
pub mod tools;
pub mod eval;
```

Run the evals:

```bash
cargo run --bin eval-single
```

Expected output:

```
Running 6 eval cases...

[PASS] "What files are in the current directory?" → Correct: selected list_files
[PASS] "Show me the contents of src/main.rs" → Correct: selected read_file
[PASS] "Read the Cargo.toml file" → Correct: selected read_file
[PASS] "What is Rust?" → Correct: no tool call
[PASS] "Tell me a joke" → Correct: no tool call
[PASS] "List everything in the src directory" → Correct: selected list_files

--- Summary ---
Passed: 6/6 (100%)
```

### Why a Separate Binary?

We use `src/bin/eval_single.rs` instead of a test. Tests are for deterministic assertions. Evals hit a real API with non-deterministic results — a test that fails 5% of the time is worse than useless. Evals are run manually, examined by humans, and tracked over time.

## The `as_deref` Pattern

```rust
let result = evaluate_tool_call(case, actual.as_deref());
```

`actual` is `Option<String>`. The evaluator takes `Option<&str>`. The `as_deref()` method converts `Option<String>` to `Option<&str>` — it dereferences the inner value without consuming the `Option`. You'll see this pattern constantly when working with `Option<String>`.

## Summary

In this chapter you:

- Defined eval types with `serde::Deserialize` for loading from JSON
- Built a scoring system with golden, secondary, and negative cases
- Created a single-turn executor that calls the API and extracts tool names
- Used `Option` chaining with `and_then` for safe nested access
- Set up a separate binary for running evals

Next, we build the agent loop — the core `while` loop that streams responses, detects tool calls, executes them, and feeds results back to the LLM.

---

**Next: [Chapter 4: The Agent Loop — SSE Streaming →](./04-the-agent-loop.md)**
