# Appendix D: Error Handling Patterns

**Read before Chapter 1** if you're still `.unwrap()`-ing everything.

## The Error Landscape

Rust has two main error handling crates used in our agent:

- **`anyhow`** — For application code. Any error type, with context. "Something went wrong, here's what."
- **`thiserror`** — For library code. Custom error enums with derived `Display` and `Error` implementations.

We use `anyhow` throughout the agent because it's application code. `thiserror` would be useful if we were publishing the agent as a library crate.

## `Result<T, E>` Basics

Every function that can fail returns `Result`:

```rust
fn read_file(path: &str) -> Result<String, std::io::Error> {
    std::fs::read_to_string(path)
}
```

The caller must handle both cases:

```rust
match read_file("config.toml") {
    Ok(content) => println!("{content}"),
    Err(e) => eprintln!("Failed: {e}"),
}
```

## The `?` Operator

`?` propagates errors up the call stack:

```rust
fn process() -> Result<String, std::io::Error> {
    let content = std::fs::read_to_string("input.txt")?;
    let parsed = parse(&content)?;
    Ok(parsed)
}
```

If `read_to_string` returns `Err`, the function returns immediately with that error. If it returns `Ok`, the value is unwrapped and assigned to `content`.

`?` works with both `Result` and `Option`:

```rust
fn get_name(data: &Value) -> Option<&str> {
    data.get("user")?.get("name")?.as_str()
}
```

## `anyhow::Result`

`anyhow::Result<T>` is shorthand for `Result<T, anyhow::Error>`, where `anyhow::Error` can hold any error type:

```rust
use anyhow::Result;

fn do_stuff() -> Result<String> {
    let content = std::fs::read_to_string("file.txt")?;  // io::Error → anyhow::Error
    let data: Value = serde_json::from_str(&content)?;    // serde::Error → anyhow::Error
    let name = data["name"].as_str()
        .context("missing name field")?;                   // None → anyhow::Error
    Ok(name.to_string())
}
```

Different error types (`io::Error`, `serde_json::Error`) are automatically converted. No need to define a custom error enum.

### `context()` and `with_context()`

Add human-readable context to errors:

```rust
use anyhow::Context;

let response = self.client
    .post(API_URL)
    .json(&request)
    .send()
    .await
    .context("Failed to send request to OpenAI")?;
```

If the underlying error is "connection refused", the full error becomes:
```
Failed to send request to OpenAI: connection refused
```

This is crucial for debugging — the context tells you *what we were trying to do*, the underlying error tells you *what went wrong*.

### `bail!`

Return an error immediately:

```rust
if !response.status().is_success() {
    let status = response.status();
    let body = response.text().await.unwrap_or_default();
    anyhow::bail!("OpenAI API error ({}): {}", status, body);
}
```

Equivalent to `return Err(anyhow::anyhow!("..."))` but more concise.

## Error Patterns in Our Agent

### Pattern 1: Propagate with Context

For unexpected errors that indicate a bug or system issue:

```rust
let response = client.chat_completion(request)
    .await
    .context("LLM call failed")?;
```

### Pattern 2: Return Error as Tool Result

For expected tool failures that the LLM can handle:

```rust
fn execute(&self, args: Value) -> Result<String> {
    let path = args["path"].as_str()
        .context("Missing 'path' argument")?;

    match fs::read_to_string(path) {
        Ok(content) => Ok(content),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Ok(format!("Error: File not found: {path}"))  // LLM can recover
        }
        Err(e) => Ok(format!("Error reading file: {e}")),  // LLM can try another approach
    }
}
```

The `Result` return type is still there for truly unexpected errors (like malformed arguments from the LLM), but filesystem errors are returned as `Ok(String)` so the LLM can adapt.

### Pattern 3: Ignore Errors

For cleanup operations where failure doesn't matter:

```rust
let _ = std::fs::remove_file(&temp_file);  // We don't care if cleanup fails
```

`let _ =` explicitly discards the `Result`. Without it, Rust warns about an unused `Result`.

## When to `unwrap()`

`unwrap()` panics on error. Use it only when:

1. **You've already validated** — `if path.exists() { fs::read_to_string(path).unwrap() }`
2. **In tests** — Tests should panic on unexpected errors
3. **For invariants** — `"123".parse::<i32>().unwrap()` — this literally cannot fail

Never use `unwrap()` on:
- Network calls
- File I/O
- User input parsing
- JSON deserialization of external data

## `thiserror` (For Reference)

If you were building the agent as a library, you'd define error types:

```rust
use thiserror::Error;

#[derive(Error, Debug)]
pub enum AgentError {
    #[error("API error ({status}): {body}")]
    ApiError { status: u16, body: String },

    #[error("Tool not found: {0}")]
    ToolNotFound(String),

    #[error("Context window exceeded: {used}/{limit} tokens")]
    ContextOverflow { used: usize, limit: usize },

    #[error(transparent)]
    Http(#[from] reqwest::Error),

    #[error(transparent)]
    Json(#[from] serde_json::Error),
}
```

`thiserror` derives `Display` and `Error` from the `#[error("...")]` attributes. `#[from]` generates `From` implementations for automatic conversion with `?`.

We don't use `thiserror` in this book because `anyhow` is simpler for application code. Use `thiserror` when you need callers to match on specific error variants.

## Summary

| Situation | Pattern |
|-----------|---------|
| Application function that can fail | `anyhow::Result<T>` |
| Add context to errors | `.context("what we were doing")?` |
| Return error immediately | `anyhow::bail!("message")` |
| Tool error the LLM can handle | `Ok(format!("Error: ..."))`  |
| Cleanup that might fail | `let _ = operation()` |
| Library error types | `thiserror::Error` derive |
| Known-good operations | `.unwrap()` (sparingly) |
