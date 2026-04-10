# Chapter 4: The Agent Loop — SSE Streaming

## What Streaming Buys You

So far our calls have been blocking: send a request, wait for the entire response, print it. That works, but it feels dead. Real agents stream tokens as they're generated — text appears word-by-word, tool calls surface the instant the model commits to them, and long responses don't make the user stare at a blank screen.

OpenAI streams responses using **Server-Sent Events (SSE)**. It's a dead-simple protocol on top of HTTP: the server keeps the connection open and writes lines like `data: {...}\n\n` for each chunk. We parse those lines with `bufio.Scanner` — no SSE library needed.

This chapter has two halves:

1. **Stream parsing** — Turn an HTTP response body into a channel of typed chunks.
2. **The agent loop** — Read chunks, accumulate tool call arguments, execute tools, feed results back, repeat.

## The SSE Wire Format

Here's what a streamed response looks like on the wire:

```
data: {"id":"chatcmpl-123","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}

data: {"id":"chatcmpl-123","choices":[{"index":0,"delta":{"content":"An"}}]}

data: {"id":"chatcmpl-123","choices":[{"index":0,"delta":{"content":" AI"}}]}

data: {"id":"chatcmpl-123","choices":[{"index":0,"delta":{"content":" agent"}}]}

data: {"id":"chatcmpl-123","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

Three rules:

- Each event starts with `data: ` followed by JSON.
- Events are separated by blank lines.
- The stream ends with the literal sentinel `data: [DONE]`.

Tool calls arrive the same way, but they're **fragmented**. The model streams the function name first, then the arguments JSON one chunk at a time:

```
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":""}}]}}]}
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"pa"}}]}}]}
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\""}}]}}]}
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"main.go\"}"}}]}}]}
```

We need to **accumulate** those argument fragments by `index` until the stream finishes. That's the trickiest part of the chapter.

## Stream Types

Create `api/sse.go`:

```go
package api

// StreamChunk is one event from a streaming chat completion.
type StreamChunk struct {
    ID      string         `json:"id"`
    Choices []StreamChoice `json:"choices"`
}

// StreamChoice is one choice within a stream chunk.
type StreamChoice struct {
    Index        int    `json:"index"`
    Delta        Delta  `json:"delta"`
    FinishReason string `json:"finish_reason,omitempty"`
}

// Delta is the incremental update for one choice.
type Delta struct {
    Role      string             `json:"role,omitempty"`
    Content   string             `json:"content,omitempty"`
    ToolCalls []StreamToolCall   `json:"tool_calls,omitempty"`
}

// StreamToolCall is a fragmented tool call from a stream.
type StreamToolCall struct {
    Index    int             `json:"index"`
    ID       string          `json:"id,omitempty"`
    Type     string          `json:"type,omitempty"`
    Function StreamFunction  `json:"function"`
}

// StreamFunction is the partial function name and arguments.
type StreamFunction struct {
    Name      string `json:"name,omitempty"`
    Arguments string `json:"arguments,omitempty"`
}
```

These mirror the non-streaming types but everything is optional — any field can be missing on any chunk.

## The Streaming Client

Add this method to `api/client.go`:

```go
// ChatCompletionStream sends a streaming chat completion request and returns a
// channel of chunks. The channel is closed when the stream ends or an error occurs.
// Errors are sent on the errs channel.
func (c *Client) ChatCompletionStream(ctx context.Context, req ChatCompletionRequest) (<-chan StreamChunk, <-chan error) {
    chunks := make(chan StreamChunk)
    errs := make(chan error, 1)

    req.Stream = true

    go func() {
        defer close(chunks)
        defer close(errs)

        body, err := json.Marshal(req)
        if err != nil {
            errs <- fmt.Errorf("marshal request: %w", err)
            return
        }

        httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, apiURL, bytes.NewReader(body))
        if err != nil {
            errs <- fmt.Errorf("build request: %w", err)
            return
        }
        httpReq.Header.Set("Authorization", "Bearer "+c.apiKey)
        httpReq.Header.Set("Content-Type", "application/json")
        httpReq.Header.Set("Accept", "text/event-stream")

        resp, err := c.httpClient.Do(httpReq)
        if err != nil {
            errs <- fmt.Errorf("send request: %w", err)
            return
        }
        defer resp.Body.Close()

        if resp.StatusCode >= 400 {
            respBody, _ := io.ReadAll(resp.Body)
            errs <- fmt.Errorf("OpenAI API error (%d): %s", resp.StatusCode, respBody)
            return
        }

        scanner := bufio.NewScanner(resp.Body)
        // Default buffer is 64KB; bump it for large tool call args.
        scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

        for scanner.Scan() {
            line := scanner.Text()
            if !strings.HasPrefix(line, "data: ") {
                continue
            }
            payload := strings.TrimPrefix(line, "data: ")
            if payload == "[DONE]" {
                return
            }

            var chunk StreamChunk
            if err := json.Unmarshal([]byte(payload), &chunk); err != nil {
                errs <- fmt.Errorf("decode chunk: %w", err)
                return
            }

            select {
            case chunks <- chunk:
            case <-ctx.Done():
                errs <- ctx.Err()
                return
            }
        }

        if err := scanner.Err(); err != nil {
            errs <- fmt.Errorf("scan stream: %w", err)
        }
    }()

    return chunks, errs
}
```

Add `bufio` and `strings` to the imports at the top of `client.go`.

A few things worth pausing on:

- **Two channels, one goroutine** — `chunks` for happy-path data, `errs` (buffered, capacity 1) for the terminal error. Both are closed by `defer` when the goroutine exits.
- **`bufio.Scanner` with a bigger buffer** — The default 64KB max-token size is fine for text, but a single chunk carrying a large tool call argument blob can exceed it.
- **Context cancellation in the select** — If the caller cancels mid-stream, we abandon the read instead of blocking on a full channel.
- **No retries** — Streaming + retries is a rabbit hole. Crash loud, fix the bug.

## The Tool Call Accumulator

Tool call fragments need to be glued together. Create `agent/accumulator.go`:

```go
package agent

import "github.com/yourname/agents-go/api"

// ToolCallAccumulator merges streamed tool call deltas into complete tool calls.
type ToolCallAccumulator struct {
    byIndex map[int]*api.ToolCall
    order   []int
}

// NewToolCallAccumulator creates an empty accumulator.
func NewToolCallAccumulator() *ToolCallAccumulator {
    return &ToolCallAccumulator{byIndex: make(map[int]*api.ToolCall)}
}

// Add merges a streamed tool call delta into the accumulator.
func (a *ToolCallAccumulator) Add(delta api.StreamToolCall) {
    tc, ok := a.byIndex[delta.Index]
    if !ok {
        tc = &api.ToolCall{Type: "function"}
        a.byIndex[delta.Index] = tc
        a.order = append(a.order, delta.Index)
    }
    if delta.ID != "" {
        tc.ID = delta.ID
    }
    if delta.Type != "" {
        tc.Type = delta.Type
    }
    if delta.Function.Name != "" {
        tc.Function.Name += delta.Function.Name
    }
    if delta.Function.Arguments != "" {
        tc.Function.Arguments += delta.Function.Arguments
    }
}

// ToolCalls returns the accumulated tool calls in order.
func (a *ToolCallAccumulator) ToolCalls() []api.ToolCall {
    out := make([]api.ToolCall, 0, len(a.order))
    for _, idx := range a.order {
        out = append(out, *a.byIndex[idx])
    }
    return out
}

// HasAny returns true if at least one tool call has been seen.
func (a *ToolCallAccumulator) HasAny() bool {
    return len(a.order) > 0
}
```

Two design choices:

- **Index-keyed map plus ordered slice** — The model can stream multiple tool calls in parallel, identified only by `index`. We track first-seen order separately so the output is deterministic.
- **String concatenation for arguments** — The fragments are JSON characters, not JSON values. We don't try to parse them until the stream is complete.

## Events From the Loop

The agent loop needs to surface multiple kinds of events to the caller: text deltas, completed tool calls, tool results, errors, and "we're done." A discriminated event type is the cleanest way:

Create `agent/events.go`:

```go
package agent

import "github.com/yourname/agents-go/api"

// EventKind describes the kind of an Event.
type EventKind int

const (
    EventTextDelta EventKind = iota
    EventToolCall
    EventToolResult
    EventDone
    EventError
)

// Event is a single update emitted by the agent loop.
type Event struct {
    Kind     EventKind
    Text     string
    ToolCall api.ToolCall
    Result   string
    Err      error
}
```

Go doesn't have sum types, so we use a struct with a discriminator and let only the relevant fields be populated. It's not as airtight as Rust's `enum`, but it's idiomatic and easy to work with in `for ev := range events { switch ev.Kind { ... } }`.

## The Agent Loop

Create `agent/run.go`:

```go
package agent

import (
    "context"
    "encoding/json"
    "fmt"

    "github.com/yourname/agents-go/api"
)

// Agent runs a streaming chat loop with tool use.
type Agent struct {
    client   *api.Client
    registry *Registry
    model    string
}

// NewAgent creates an agent with the given client and registry.
func NewAgent(client *api.Client, registry *Registry) *Agent {
    return &Agent{
        client:   client,
        registry: registry,
        model:    "gpt-4.1-mini",
    }
}

// Run drives the agent loop and returns a channel of events.
// The channel is closed when the loop terminates.
func (a *Agent) Run(ctx context.Context, messages []api.Message) <-chan Event {
    events := make(chan Event)

    go func() {
        defer close(events)

        // Make a private copy so we can append without affecting the caller.
        history := append([]api.Message(nil), messages...)

        for {
            req := api.ChatCompletionRequest{
                Model:    a.model,
                Messages: history,
                Tools:    a.registry.Definitions(),
            }

            chunks, errs := a.client.ChatCompletionStream(ctx, req)

            var content string
            acc := NewToolCallAccumulator()

        readStream:
            for {
                select {
                case chunk, ok := <-chunks:
                    if !ok {
                        break readStream
                    }
                    if len(chunk.Choices) == 0 {
                        continue
                    }
                    delta := chunk.Choices[0].Delta
                    if delta.Content != "" {
                        content += delta.Content
                        events <- Event{Kind: EventTextDelta, Text: delta.Content}
                    }
                    for _, tc := range delta.ToolCalls {
                        acc.Add(tc)
                    }
                case err := <-errs:
                    if err != nil {
                        events <- Event{Kind: EventError, Err: err}
                        return
                    }
                case <-ctx.Done():
                    events <- Event{Kind: EventError, Err: ctx.Err()}
                    return
                }
            }

            // Drain any error that arrived after the chunks channel closed.
            select {
            case err := <-errs:
                if err != nil {
                    events <- Event{Kind: EventError, Err: err}
                    return
                }
            default:
            }

            toolCalls := acc.ToolCalls()

            // Append the assistant turn to history.
            history = append(history, api.Message{
                Role:      "assistant",
                Content:   content,
                ToolCalls: toolCalls,
            })

            // No tool calls → conversation is done.
            if len(toolCalls) == 0 {
                events <- Event{Kind: EventDone}
                return
            }

            // Execute each tool call and append results.
            for _, tc := range toolCalls {
                events <- Event{Kind: EventToolCall, ToolCall: tc}

                result, err := a.registry.Execute(tc.Function.Name, json.RawMessage(tc.Function.Arguments))
                if err != nil {
                    result = fmt.Sprintf("Error: %v", err)
                }

                events <- Event{Kind: EventToolResult, ToolCall: tc, Result: result}
                history = append(history, api.NewToolResultMessage(tc.ID, result))
            }
            // Loop again — feed tool results back to the model.
        }
    }()

    return events
}
```

The shape is the standard agent loop:

1. Send the conversation to the model.
2. Stream the response, accumulating text and tool calls.
3. Append the assistant message to history.
4. If there are no tool calls, emit `Done` and exit.
5. Otherwise, execute each tool call, append the results as `tool` messages, and loop.

The `select` over `chunks`, `errs`, and `ctx.Done()` is the heart of it. Channels make the concurrency story almost boring — there's no `Pin<Box<dyn Future>>` or `async fn` ceremony, just "read whichever thing is ready next."

### Why a Channel of Events?

We could have called callbacks (`onText`, `onToolCall`, ...), but channels compose better:

- The terminal UI in Chapter 9 will be a Bubble Tea program that pulls events on its own schedule.
- Tests can drain the channel into a slice and assert on the sequence.
- `ctx.Done()` cancels both producer and consumer naturally.

## Wiring It Up

Replace `main.go` with a streaming version:

```go
package main

import (
    "context"
    "fmt"
    "log"
    "os"

    "github.com/joho/godotenv"
    "github.com/yourname/agents-go/agent"
    "github.com/yourname/agents-go/api"
    "github.com/yourname/agents-go/tools"
)

func main() {
    _ = godotenv.Load()

    apiKey := os.Getenv("OPENAI_API_KEY")
    if apiKey == "" {
        log.Fatal("OPENAI_API_KEY must be set")
    }

    client := api.NewClient(apiKey)

    registry := agent.NewRegistry()
    registry.Register(tools.ReadFile{})
    registry.Register(tools.ListFiles{})

    a := agent.NewAgent(client, registry)

    messages := []api.Message{
        api.NewSystemMessage(agent.SystemPrompt),
        api.NewUserMessage("List the files in the current directory, then read go.mod and tell me the module name."),
    }

    ctx := context.Background()
    for ev := range a.Run(ctx, messages) {
        switch ev.Kind {
        case agent.EventTextDelta:
            fmt.Print(ev.Text)
        case agent.EventToolCall:
            fmt.Printf("\n[tool call] %s(%s)\n", ev.ToolCall.Function.Name, ev.ToolCall.Function.Arguments)
        case agent.EventToolResult:
            preview := ev.Result
            if len(preview) > 120 {
                preview = preview[:120] + "..."
            }
            fmt.Printf("[tool result] %s\n", preview)
        case agent.EventDone:
            fmt.Println()
        case agent.EventError:
            log.Fatalf("agent error: %v", ev.Err)
        }
    }
}
```

Run it:

```bash
go run .
```

You should see something like:

```
[tool call] list_files({"directory":"."})
[tool result] [dir] agent
[dir] api
[dir] cmd
[dir] eval
[dir] eval_data
[dir] tools
[file] go.mod
[file] go.sum...
[tool call] read_file({"path":"go.mod"})
[tool result] module github.com/yourname/agents-go

go 1.22
...
The module is named github.com/yourname/agents-go.
```

The model called `list_files`, saw the result, decided it needed `read_file`, called that, saw *its* result, and finally emitted plain text. Two model turns, two tool executions, all wired through one channel.

## Summary

In this chapter you:

- Parsed Server-Sent Events with `bufio.Scanner` and a `data: ` prefix check
- Modeled streamed deltas as Go structs with everything `omitempty`
- Built a tool call accumulator that merges fragmented arguments by index
- Designed the loop's output as a typed `Event` channel
- Wrote the core agent loop using `select` over chunks, errors, and context cancellation
- Watched the model call multiple tools across multiple turns

Next, we'll write evals that grade *full conversations* — not just whether the first tool call is right, but whether the agent eventually arrives at the correct answer.

---

**Next: [Chapter 5: Multi-Turn Evaluations →](./05-multi-turn-evals.md)**
