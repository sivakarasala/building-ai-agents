# Chapter 5: Multi-Turn Evaluations

## Beyond Single Turns

Single-turn evals verify tool *selection*. But agents have conversations — the LLM might call three tools in sequence, and the order matters. Multi-turn evals test the full agent loop with mocked tools, then judge whether the final answer is correct.

This chapter introduces two new concepts:

1. **Mock tools** — Fake tool implementations that return predictable data
2. **LLM-as-judge** — Using a second LLM call to evaluate the agent's answer

## Mock Tools

We don't want evals hitting real files or running real shell commands. Mock tools return canned responses that are deterministic and fast. Create `src/eval/mocks.rs`:

```rust
use std::collections::HashMap;
use anyhow::Result;
use serde_json::Value;

use crate::agent::tool_registry::Tool;
use crate::api::types::{FunctionDefinition, ToolDefinition};

/// A mock tool that returns a fixed response based on input patterns.
pub struct MockTool {
    tool_name: String,
    description: String,
    parameters: Value,
    responses: HashMap<String, String>,
    default_response: String,
}

impl MockTool {
    pub fn new(
        name: &str,
        description: &str,
        parameters: Value,
        responses: HashMap<String, String>,
        default_response: &str,
    ) -> Self {
        Self {
            tool_name: name.into(),
            description: description.into(),
            parameters,
            responses,
            default_response: default_response.into(),
        }
    }
}

impl Tool for MockTool {
    fn name(&self) -> &str {
        &self.tool_name
    }

    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            tool_type: "function".into(),
            function: FunctionDefinition {
                name: self.tool_name.clone(),
                description: self.description.clone(),
                parameters: self.parameters.clone(),
            },
        }
    }

    fn execute(&self, args: Value) -> Result<String> {
        // Check each response pattern against the args
        let args_str = args.to_string();
        for (pattern, response) in &self.responses {
            if args_str.contains(pattern) {
                return Ok(response.clone());
            }
        }
        Ok(self.default_response.clone())
    }
}
```

The mock tool matches input arguments against string patterns. If `args` contains `"Cargo.toml"`, return the mock Cargo.toml content. This is deliberately simple — pattern matching on stringified args is fragile but good enough for evals.

### Building Mock Registries

```rust
use serde_json::json;

/// Create a mock registry for file tool evals.
pub fn mock_file_registry() -> crate::agent::tool_registry::ToolRegistry {
    let mut registry = crate::agent::tool_registry::ToolRegistry::new();

    let mut list_responses = HashMap::new();
    list_responses.insert(
        ".".into(),
        "[dir] src\n[file] Cargo.toml\n[file] README.md".into(),
    );
    list_responses.insert(
        "src".into(),
        "[file] main.rs\n[file] lib.rs".into(),
    );

    registry.register(Box::new(MockTool::new(
        "list_files",
        "List files in a directory",
        json!({
            "type": "object",
            "properties": {
                "directory": { "type": "string" }
            }
        }),
        list_responses,
        "[file] unknown.txt",
    )));

    let mut read_responses = HashMap::new();
    read_responses.insert(
        "Cargo.toml".into(),
        "[package]\nname = \"agents-v2\"\nversion = \"0.1.0\"".into(),
    );
    read_responses.insert(
        "main.rs".into(),
        "fn main() {\n    println!(\"Hello, world!\");\n}".into(),
    );

    registry.register(Box::new(MockTool::new(
        "read_file",
        "Read file contents",
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string" }
            },
            "required": ["path"]
        }),
        read_responses,
        "Error: File not found",
    )));

    registry
}
```

## Multi-Turn Eval Types

Update `src/eval/types.rs`:

```rust
use serde::{Deserialize, Serialize};

// ... (keep existing types) ...

/// A multi-turn evaluation case.
#[derive(Debug, Clone, Deserialize)]
pub struct MultiTurnEvalCase {
    pub input: String,
    pub expected_tools: Vec<String>,
    pub expected_content: String,
}

/// Result of a multi-turn evaluation.
#[derive(Debug, Clone, Serialize)]
pub struct MultiTurnEvalResult {
    pub input: String,
    pub expected_tools: Vec<String>,
    pub actual_tools: Vec<String>,
    pub tool_order_correct: bool,
    pub content_score: f64,
    pub judge_reasoning: String,
    pub passed: bool,
}
```

## Multi-Turn Executor

The executor runs the full agent loop with mock tools, then collects which tools were called and what the final response was. Add to `src/eval/executors.rs`:

```rust
use std::sync::{Arc, Mutex};

// ... (keep existing run_single_turn) ...

/// Run a full agent loop and collect tool calls + final response.
pub async fn run_multi_turn(
    client: &OpenAIClient,
    registry: &ToolRegistry,
    tools: &[ToolDefinition],
    input: &str,
) -> Result<(Vec<String>, String)> {
    let tool_names: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let final_text: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));

    let tool_names_clone = Arc::clone(&tool_names);
    let final_text_clone = Arc::clone(&final_text);

    let mut callbacks = crate::agent::run::AgentCallbacks {
        on_token: Box::new(move |token| {
            final_text_clone.lock().unwrap().push_str(token);
        }),
        on_tool_call_start: Box::new(move |name, _args| {
            tool_names_clone.lock().unwrap().push(name.to_string());
        }),
        on_tool_call_end: Box::new(|_, _| {}),
        on_complete: Box::new(|_| {}),
    };

    crate::agent::run::run_agent(
        input,
        Vec::new(),
        client,
        registry,
        tools,
        &mut callbacks,
    )
    .await?;

    let tools_used = tool_names.lock().unwrap().clone();
    let response = final_text.lock().unwrap().clone();

    Ok((tools_used, response))
}
```

### Why `Arc<Mutex<_>>`?

The callbacks are `FnMut` closures that capture mutable state. But multiple closures can't each have exclusive (`&mut`) access to the same data. `Arc<Mutex<T>>` solves this:

- `Arc` — Reference-counted pointer, so multiple closures can share ownership
- `Mutex` — Ensures only one closure accesses the data at a time

This is slightly over-engineered for our use case (callbacks execute sequentially, not concurrently), but it satisfies Rust's ownership rules. The `Mutex` lock is uncontended, so the runtime cost is negligible.

## Tool Order Checking

Eval cases specify `expected_tools: ["list_files", "read_file"]`. The agent might call them in that order, or it might call additional tools. We check if the expected tools appear as a subsequence of the actual tools:

```rust
// In src/eval/evaluators.rs

/// Check if `expected` appears as a subsequence of `actual`.
/// Additional tools in `actual` are allowed.
pub fn is_subsequence(expected: &[String], actual: &[String]) -> bool {
    let mut expected_iter = expected.iter();
    let mut current = expected_iter.next();

    for actual_tool in actual {
        if let Some(expected_tool) = current {
            if actual_tool == expected_tool {
                current = expected_iter.next();
            }
        }
    }

    current.is_none()
}
```

If the agent called `[list_files, read_file, read_file]` and we expected `[list_files, read_file]`, that passes — the expected sequence is present in order, even though there's an extra call.

## LLM-as-Judge

For evaluating the *content* of the agent's response, we use a second LLM call. The judge sees the user's question, the expected answer, and the actual answer, then scores on a 0-1 scale.

Add to `src/eval/evaluators.rs`:

```rust
use anyhow::Result;
use serde::Deserialize;

use crate::api::client::OpenAIClient;
use crate::api::types::{ChatCompletionRequest, Message};

#[derive(Debug, Deserialize)]
struct JudgeResponse {
    score: f64,
    reasoning: String,
}

/// Use an LLM to judge whether the actual response matches expectations.
pub async fn llm_judge(
    client: &OpenAIClient,
    input: &str,
    expected: &str,
    actual: &str,
) -> Result<(f64, String)> {
    let prompt = format!(
        r#"You are an evaluation judge. Score how well the actual response answers the user's question compared to the expected response.

User question: {input}

Expected response should contain: {expected}

Actual response: {actual}

Respond with JSON only:
{{"score": <0.0 to 1.0>, "reasoning": "<brief explanation>"}}"#
    );

    let request = ChatCompletionRequest {
        model: "gpt-4.1-mini".into(),
        messages: vec![Message::user(&prompt)],
        tools: None,
        stream: None,
    };

    let response = client.chat_completion(request).await?;

    let content = response
        .choices
        .first()
        .and_then(|c| c.message.content.as_ref())
        .unwrap_or(&String::new())
        .clone();

    // Parse the JSON response
    match serde_json::from_str::<JudgeResponse>(&content) {
        Ok(judge) => Ok((judge.score, judge.reasoning)),
        Err(_) => Ok((0.5, "Could not parse judge response".into())),
    }
}
```

### Why Not Structured Output?

We ask the judge to return JSON and parse it with `serde_json`. This works 95% of the time. When it doesn't, we return a default score of 0.5. Production evals would use OpenAI's structured output feature (`response_format: { type: "json_object" }`) — but we haven't added that to our API types yet, and 95% reliability is fine for development evals.

## Test Data

Create `eval_data/agent_multiturn.json`:

```json
[
    {
        "input": "What files are in this project?",
        "expected_tools": ["list_files"],
        "expected_content": "The project contains Cargo.toml, README.md, and a src directory"
    },
    {
        "input": "Read the Cargo.toml and tell me the project name",
        "expected_tools": ["read_file"],
        "expected_content": "The project is named agents-v2"
    },
    {
        "input": "List all files then read main.rs",
        "expected_tools": ["list_files", "read_file"],
        "expected_content": "main.rs contains a Hello World program"
    }
]
```

## The Eval Runner

Create `src/bin/eval_multi.rs`:

```rust
use anyhow::Result;
use std::fs;

use agents_v2::api::client::OpenAIClient;
use agents_v2::eval::evaluators::{is_subsequence, llm_judge};
use agents_v2::eval::executors::run_multi_turn;
use agents_v2::eval::mocks::mock_file_registry;
use agents_v2::eval::types::MultiTurnEvalCase;

#[tokio::main]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();

    let api_key = std::env::var("OPENAI_API_KEY")
        .expect("OPENAI_API_KEY must be set");
    let client = OpenAIClient::new(api_key);

    let registry = mock_file_registry();
    let definitions = registry.definitions();

    let data = fs::read_to_string("eval_data/agent_multiturn.json")?;
    let cases: Vec<MultiTurnEvalCase> = serde_json::from_str(&data)?;

    println!("Running {} multi-turn eval cases...\n", cases.len());

    let mut total_score = 0.0;
    let mut passed = 0;

    for case in &cases {
        let (actual_tools, response) =
            run_multi_turn(&client, &registry, &definitions, &case.input).await?;

        let order_ok = is_subsequence(&case.expected_tools, &actual_tools);

        let (content_score, reasoning) =
            llm_judge(&client, &case.input, &case.expected_content, &response).await?;

        let overall_passed = order_ok && content_score >= 0.5;

        let status = if overall_passed { "PASS" } else { "FAIL" };
        println!("[{status}] \"{}\"", case.input);
        println!("  Tools: {:?} (order {})",
            actual_tools,
            if order_ok { "OK" } else { "WRONG" }
        );
        println!("  Content score: {:.1} — {reasoning}", content_score);
        println!();

        if overall_passed {
            passed += 1;
        }
        total_score += content_score;
    }

    println!("--- Summary ---");
    println!("Passed: {}/{}", passed, cases.len());
    println!("Avg content score: {:.2}", total_score / cases.len() as f64);

    Ok(())
}
```

Add to `Cargo.toml`:

```toml
[[bin]]
name = "eval-multi"
path = "src/bin/eval_multi.rs"
```

Run it:

```bash
cargo run --bin eval-multi
```

## Update Module Exports

Update `src/eval/mod.rs`:

```rust
pub mod evaluators;
pub mod executors;
pub mod mocks;
pub mod types;
```

## Summary

In this chapter you:

- Built mock tools with pattern-based responses for deterministic testing
- Implemented subsequence matching for tool order verification
- Used LLM-as-judge for evaluating response content quality
- Combined tool order and content scoring for multi-turn eval cases
- Used `Arc<Mutex<T>>` to share mutable state across closures

With evals in place, we can now add tools with confidence that they integrate correctly with the agent loop.

---

**Next: [Chapter 6: File System Tools →](./06-file-system-tools.md)**
