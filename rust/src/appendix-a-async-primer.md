# Appendix A: Rust Async Primer

**Read before Chapter 4** if you've only written synchronous Rust.

## Why Async Matters for Agents

Our agent makes HTTP calls that take 100ms–5s each. In synchronous code, the program blocks — doing nothing — while waiting for the network. Async lets us start the HTTP call, do other work (process UI events, handle input), and resume when the response arrives.

For our agent specifically:
- **SSE streaming** — We read chunks from an HTTP stream as they arrive
- **UI rendering** — The UI needs to update while the agent waits for the API
- **Concurrent callbacks** — Multiple subsystems react to stream events

## The Tokio Runtime

Rust doesn't have a built-in async runtime. You need one. `tokio` is the standard:

```rust
#[tokio::main]
async fn main() {
    let result = do_something().await;
    println!("{result}");
}

async fn do_something() -> String {
    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    "done".to_string()
}
```

`#[tokio::main]` transforms `main` into a synchronous function that creates a tokio runtime and blocks on the async body. Without it, you'd write:

```rust
fn main() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        do_something().await;
    });
}
```

## `async` and `.await`

`async fn` doesn't execute immediately — it returns a `Future`. The future only runs when you `.await` it:

```rust
async fn fetch_data() -> String {
    // This doesn't run until someone awaits it
    reqwest::get("https://example.com")
        .await
        .unwrap()
        .text()
        .await
        .unwrap()
}

// This creates a future but doesn't execute it:
let future = fetch_data();

// This executes it:
let data = future.await;
```

### The `Future` Trait

Every `async fn` returns a type that implements `Future`:

```rust
pub trait Future {
    type Output;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>;
}

pub enum Poll<T> {
    Ready(T),
    Pending,
}
```

When you `.await` a future, tokio calls `poll()`. If it returns `Pending`, tokio parks the task and does other work. When the underlying I/O is ready, tokio wakes the task and polls again. This is how thousands of concurrent tasks run on a few OS threads.

You rarely implement `Future` directly. `async/await` handles it. But understanding the model explains why:

- `.await` is a yield point — the runtime can switch to another task
- Between `.await`s, code runs synchronously on a single thread
- Holding a `Mutex` lock across an `.await` can deadlock (the runtime might schedule another task that needs the same lock on the same thread)

## `tokio::spawn`

`spawn` runs a future on the tokio runtime concurrently:

```rust
let handle = tokio::spawn(async {
    // This runs concurrently with the caller
    expensive_computation().await
});

// Do other work while it runs
do_other_stuff().await;

// Wait for the result
let result = handle.await.unwrap();
```

### `Send` Bound

`tokio::spawn` requires the future to be `Send` — it might run on a different thread. This is why our `Tool` trait requires `Send + Sync`:

```rust
pub trait Tool: Send + Sync {
    // ...
}
```

If a tool holds non-`Send` data (like `Rc<T>`), it can't be used across async tasks. Use `Arc<T>` instead.

## `tokio::task::spawn_blocking`

For synchronous, CPU-heavy work that would block the async runtime:

```rust
let result = tokio::task::spawn_blocking(|| {
    // This runs on a dedicated thread pool,
    // not the async worker threads
    std::fs::read_to_string("big_file.txt")
}).await.unwrap();
```

This is relevant for our tools — `Tool::execute` is synchronous, and some operations (like running a shell command) block for a long time. In production, wrap them in `spawn_blocking`.

## Streams

A `Stream` is the async equivalent of `Iterator`:

```rust
use futures_util::StreamExt;

let mut stream = response.bytes_stream();

while let Some(chunk) = stream.next().await {
    let bytes = chunk?;
    process(bytes);
}
```

`StreamExt::next()` returns `Option<Item>` — `Some(item)` for each element, `None` when the stream ends. This is exactly how we consume SSE streams in Chapter 4.

## `select!`

`tokio::select!` waits for the first of multiple futures to complete:

```rust
tokio::select! {
    result = api_call() => {
        handle_response(result);
    }
    _ = tokio::time::sleep(Duration::from_secs(30)) => {
        println!("Timeout!");
    }
    _ = cancellation_token.cancelled() => {
        println!("Cancelled!");
    }
}
```

Useful for timeouts and cancellation in the agent loop.

## Common Pitfalls

### Holding Locks Across `.await`

```rust
// BAD — can deadlock
let mut guard = mutex.lock().unwrap();
expensive_async_call().await;  // Other tasks can't acquire the lock
guard.value = result;

// GOOD — release lock before await
{
    let mut guard = mutex.lock().unwrap();
    guard.value = initial;
}  // Lock released
expensive_async_call().await;
{
    let mut guard = mutex.lock().unwrap();
    guard.value = result;
}
```

### Blocking the Runtime

```rust
// BAD — blocks an async worker thread
async fn bad() {
    std::thread::sleep(Duration::from_secs(5));
}

// GOOD — yields to the runtime
async fn good() {
    tokio::time::sleep(Duration::from_secs(5)).await;
}

// GOOD — for sync blocking operations
async fn also_good() {
    tokio::task::spawn_blocking(|| {
        std::thread::sleep(Duration::from_secs(5));
    }).await.unwrap();
}
```

### Moving Owned Data Into Async Blocks

```rust
let data = String::from("hello");

// This moves `data` into the spawned task
tokio::spawn(async move {
    println!("{data}");
});

// `data` is no longer available here
// println!("{data}"); // Compile error!
```

Use `clone()` before the move if you need the data in both places, or use `Arc` for shared ownership.

## Summary

| Concept | What It Does | Used In |
|---------|-------------|---------|
| `async fn` | Returns a `Future` that runs when awaited | All async functions |
| `.await` | Executes a future, yielding to runtime while waiting | Every async call |
| `tokio::spawn` | Runs a future concurrently | Background agent tasks |
| `spawn_blocking` | Runs sync code on a thread pool | Tool execution |
| `Stream` | Async iterator | SSE parsing (Chapter 4) |
| `select!` | Race multiple futures | Timeouts, cancellation |
| `Arc<Mutex<T>>` | Shared mutable state across tasks | UI bridge (Chapter 9) |

This is enough async Rust to build the agent. For deeper understanding, read [Asynchronous Programming in Rust](https://rust-lang.github.io/async-book/) (the official async book).
