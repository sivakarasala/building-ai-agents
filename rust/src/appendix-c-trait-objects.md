# Appendix C: Trait Objects & Dynamic Dispatch

**Read before Chapter 2** if you haven't built plugin-style architectures in Rust.

## The Problem

Our tool registry stores different tool types: `ReadFileTool`, `ListFilesTool`, `WriteFileTool`, etc. In Python, you'd store them in a list. In TypeScript, an array of objects with a common interface. In Rust, the type system needs to know the concrete type at compile time — unless you use trait objects.

## Generics vs Trait Objects

### The Generic Approach (Won't Work Here)

```rust
struct ToolRegistry<T: Tool> {
    tools: Vec<T>,
}
```

This only works if every tool is the *same type*. `ToolRegistry<ReadFileTool>` can only hold `ReadFileTool` instances. We can't mix `ReadFileTool` and `ListFilesTool` in one registry.

### The Trait Object Approach (What We Use)

```rust
struct ToolRegistry {
    tools: HashMap<String, Box<dyn Tool>>,
}
```

`Box<dyn Tool>` means "a heap-allocated value of some type that implements `Tool`." The concrete type is erased — at runtime, the registry just knows it has things that can do `name()`, `definition()`, and `execute()`.

## How `dyn Tool` Works

When you create a `Box<dyn Tool>`:

```rust
let tool: Box<dyn Tool> = Box::new(ReadFileTool);
```

Rust creates a **fat pointer** — two words:
1. A pointer to the data (`ReadFileTool` on the heap)
2. A pointer to a **vtable** — a table of function pointers for `name()`, `definition()`, `execute()`

When you call `tool.execute(args)`, Rust looks up `execute` in the vtable and calls it. This is **dynamic dispatch** — the method to call is determined at runtime, not compile time.

### Performance Cost

Dynamic dispatch adds one pointer indirection per method call. For our agent, this is negligible — tool execution takes milliseconds to seconds (file I/O, HTTP calls, shell commands). The nanosecond cost of dynamic dispatch is irrelevant.

## Object Safety

Not every trait can be used as `dyn Trait`. A trait is "object-safe" if:

1. **No generic methods** — `fn do_thing<T>(&self, val: T)` is not allowed (the vtable can't store infinite generic instantiations)
2. **No `Self` in return types** — `fn clone(&self) -> Self` is not allowed (the concrete type is erased)
3. **No associated constants or types that use `Self`**

Our `Tool` trait is object-safe:

```rust
pub trait Tool: Send + Sync {
    fn name(&self) -> &str;                    // OK — returns reference
    fn definition(&self) -> ToolDefinition;    // OK — returns concrete type
    fn execute(&self, args: Value) -> Result<String>; // OK — concrete types
    fn requires_approval(&self) -> bool { false }     // OK — default impl
}
```

If we tried to add a generic method:

```rust
fn execute_typed<T: DeserializeOwned>(&self) -> Result<T>;
// ERROR: method `execute_typed` has generic type parameters
// and cannot be made into an object
```

This is why `execute` takes `serde_json::Value` (dynamic JSON) rather than a generic type parameter.

## `Box<dyn Tool>` vs `&dyn Tool` vs `Arc<dyn Tool>`

| Type | Ownership | Use When |
|------|-----------|----------|
| `Box<dyn Tool>` | Owned, heap-allocated | Storing tools in a collection |
| `&dyn Tool` | Borrowed | Passing a tool to a function temporarily |
| `Arc<dyn Tool>` | Shared ownership | Multiple owners need the tool concurrently |

We use `Box<dyn Tool>` because the registry *owns* the tools. They live as long as the registry does.

## The `Send + Sync` Bounds

```rust
pub trait Tool: Send + Sync {
```

- **`Send`** — The tool can be moved between threads. Required because `tokio` may move tasks between worker threads.
- **`Sync`** — The tool can be referenced from multiple threads. Required because `&ToolRegistry` is shared across the agent loop (which is async and potentially multi-threaded).

Without these bounds, `Box<dyn Tool>` would not be `Send + Sync`, and you couldn't use the registry in async code:

```rust
// This wouldn't compile without Send + Sync:
let registry = ToolRegistry::new();
tokio::spawn(async move {
    registry.execute("read_file", args);
});
```

## Creating Trait Objects

```rust
// From a concrete type
let tool: Box<dyn Tool> = Box::new(ReadFileTool);

// Registering (the Box::new coercion happens implicitly)
registry.register(Box::new(ReadFileTool));
registry.register(Box::new(ListFilesTool));
registry.register(Box::new(WriteFileTool));
```

`Box::new(ReadFileTool)` creates a `Box<ReadFileTool>`, which is then coerced to `Box<dyn Tool>` because `ReadFileTool` implements `Tool`. This coercion happens automatically when the type context expects `Box<dyn Tool>`.

## Default Methods

```rust
pub trait Tool: Send + Sync {
    fn name(&self) -> &str;
    fn definition(&self) -> ToolDefinition;
    fn execute(&self, args: Value) -> Result<String>;

    // Default implementation — tools are safe by default
    fn requires_approval(&self) -> bool {
        false
    }
}
```

Default methods provide a base implementation. Types can override them:

```rust
impl Tool for DeleteFileTool {
    // Override the default
    fn requires_approval(&self) -> bool {
        true
    }
    // ... other methods ...
}
```

This is Rust's equivalent of a "mixin" or "abstract class with default methods." It keeps the tool implementations concise — safe tools don't need to mention `requires_approval` at all.

## Alternatives to Trait Objects

### Enum Dispatch

```rust
enum AnyTool {
    ReadFile(ReadFileTool),
    ListFiles(ListFilesTool),
    WriteFile(WriteFileTool),
}

impl AnyTool {
    fn execute(&self, args: Value) -> Result<String> {
        match self {
            AnyTool::ReadFile(t) => t.execute(args),
            AnyTool::ListFiles(t) => t.execute(args),
            AnyTool::WriteFile(t) => t.execute(args),
        }
    }
}
```

This uses static dispatch (no vtable indirection) but requires listing every tool type in the enum. Adding a new tool means modifying the enum and every `match`. Trait objects are more flexible for plugin-style architectures.

### Function Pointers

```rust
type ToolFn = Box<dyn Fn(Value) -> Result<String>>;

struct ToolRegistry {
    tools: HashMap<String, ToolFn>,
}
```

Simpler, but loses the ability to query tool metadata (`name()`, `definition()`). Each tool would need to be a closure, not a struct.

## Summary

Trait objects (`Box<dyn Tool>`) give us:
- **Heterogeneous collections** — Different tool types in one `HashMap`
- **Extensibility** — Add new tools by implementing the trait
- **Encapsulation** — Each tool manages its own state and logic
- **Minimal overhead** — One pointer indirection per call

The tradeoff is losing compile-time knowledge of the concrete type. For a tool registry, this is the right call.
