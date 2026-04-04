# Appendix B: Serde Deep Dive

**Read before Chapter 2** if you've only used serde for simple structs.

## What Serde Does

Serde (Serialize + Deserialize) converts between Rust types and data formats (JSON, TOML, YAML, etc.). For our agent, it's the bridge between Rust structs and the JSON that the OpenAI API speaks.

## Derive Macros

The simplest usage:

```rust
use serde::{Serialize, Deserialize};

#[derive(Serialize, Deserialize)]
struct User {
    name: String,
    age: u32,
}
```

This generates `Serialize` and `Deserialize` implementations automatically. The struct serializes to:

```json
{"name": "Alice", "age": 30}
```

And deserializes back from the same JSON.

## Field Attributes

### `#[serde(rename = "...")]`

Map a Rust field name to a different JSON key:

```rust
#[derive(Serialize, Deserialize)]
struct ToolCall {
    #[serde(rename = "type")]
    call_type: String,  // JSON: "type", Rust: call_type
}
```

`type` is a reserved keyword in Rust, so we use `call_type` and rename it for JSON. This is used extensively in our API types.

### `#[serde(skip_serializing_if = "Option::is_none")]`

Omit a field from JSON when it's `None`:

```rust
#[derive(Serialize)]
struct Message {
    role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_calls: Option<Vec<ToolCall>>,
}
```

Without this attribute, a user message would serialize as:

```json
{"role": "user", "content": "Hello", "tool_calls": null}
```

With it:

```json
{"role": "user", "content": "Hello"}
```

The OpenAI API is strict about unexpected fields, so this matters.

### `#[serde(default)]`

Use the type's `Default` implementation when the field is missing during deserialization:

```rust
#[derive(Deserialize)]
struct EvalCase {
    input: String,
    expected_tool: String,
    #[serde(default)]
    secondary_tools: Vec<String>,  // Defaults to empty vec if missing
}
```

This lets our eval JSON files omit `secondary_tools` when there are none.

## `serde_json::Value`

When you don't know the JSON shape at compile time, use `Value`:

```rust
use serde_json::Value;

let data: Value = serde_json::from_str(r#"{"key": [1, 2, 3]}"#)?;

// Access fields dynamically
let key = &data["key"];           // Value::Array([1, 2, 3])
let first = &data["key"][0];     // Value::Number(1)
let missing = &data["nope"];     // Value::Null (no panic!)

// Convert to concrete types
let n: Option<i64> = data["key"][0].as_i64();  // Some(1)
let s: Option<&str> = data["key"][0].as_str();  // None (it's a number)
```

We use `Value` for two things:
1. **JSON Schema** — Tool parameters are arbitrary JSON objects
2. **Tool arguments** — The LLM generates JSON that we parse per-tool

### The `json!` Macro

Create `Value` from JSON-like syntax:

```rust
use serde_json::json;

let schema = json!({
    "type": "object",
    "properties": {
        "path": {
            "type": "string",
            "description": "The file path"
        }
    },
    "required": ["path"]
});
```

This is compile-time checked for JSON syntax (missing commas, unmatched braces) but produces a dynamic `Value` at runtime. It's how we build JSON Schema without defining a struct for every possible schema shape.

## Serialization Patterns in Our Agent

### Request Serialization

```rust
#[derive(Serialize)]
struct ChatCompletionRequest {
    model: String,
    messages: Vec<Message>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tools: Option<Vec<ToolDefinition>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    stream: Option<bool>,
}
```

`reqwest` calls `serde_json::to_string` internally when you use `.json(&request)`. The struct maps directly to the OpenAI API's expected JSON format.

### Response Deserialization

```rust
#[derive(Deserialize)]
struct ChatCompletionResponse {
    id: String,
    choices: Vec<Choice>,
    usage: Option<Usage>,
}
```

`reqwest` calls `serde_json::from_str` internally when you use `.json::<T>()`. If the response has extra fields we didn't define, serde ignores them by default. If a required field is missing, deserialization fails with a clear error.

### Streaming Chunks — Pervasive `Option`

```rust
#[derive(Deserialize)]
struct Delta {
    role: Option<String>,
    content: Option<String>,
    tool_calls: Option<Vec<StreamToolCall>>,
}
```

Every field is `Option` because stream chunks only contain changed fields. Serde handles this naturally — missing JSON keys become `None`.

## `from_str` vs `from_value`

```rust
// Parse a JSON string into a type
let msg: Message = serde_json::from_str(json_string)?;

// Convert a Value into a type
let msg: Message = serde_json::from_value(json_value)?;

// Convert a type into a Value
let value: Value = serde_json::to_value(&msg)?;

// Serialize to a JSON string
let json: String = serde_json::to_string(&msg)?;
let pretty: String = serde_json::to_string_pretty(&msg)?;
```

## Error Handling

Serde errors are descriptive:

```
Error("missing field `role`", line: 1, column: 23)
Error("invalid type: integer `42`, expected a string", line: 1, column: 10)
```

In our agent, deserialization errors from the API response usually mean the API changed its format or returned an error response we tried to parse as a success response. The error message tells you exactly what field was wrong.

## Summary

| Pattern | Usage in Agent |
|---------|---------------|
| `#[derive(Serialize)]` | Request types sent to OpenAI |
| `#[derive(Deserialize)]` | Response types from OpenAI |
| `skip_serializing_if` | Omit `None` fields in requests |
| `rename` | Map `call_type` → `"type"` |
| `default` | Optional eval case fields |
| `Value` | JSON Schema, tool arguments |
| `json!` | Building JSON Schema inline |
