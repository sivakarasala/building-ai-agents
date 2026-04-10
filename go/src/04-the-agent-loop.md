# Chapter 4: The Agent Loop — SSE Streaming

## What Streaming Buys You

So far our calls have been blocking: send a request, wait for the entire response, print it. That works, but it feels dead. Real agents stream tokens as they're generated — text appears word-by-word, tool calls surface the instant the model commits to them, and long responses don't make the user stare at a blank screen.

OpenAI streams responses using **Server-Sent Events (SSE)**. It's a dead-simple protocol on top of HTTP: the server keeps the connection open and writes lines like `data: {...}\n\n` for each chunk. We parse those lines with `bufio.Scanner` — no SSE library needed.

This chapter has two halves:

1. **Stream parsing** — Turn an HTTP response body into a channel of typed events.
2. **The agent loop** — Read events, capture the final response, execute tool calls, feed results back, repeat.

## The Responses API SSE Wire Format

The Responses API streams a sequence of typed events. Each `data:` payload is a JSON object with a `type` field telling you which kind of event it is:

```
data: {"type":"response.created","response":{"id":"resp_123","status":"in_progress"}}

data: {"type":"response.output_text.delta","delta":"An"}

data: {"type":"response.output_text.delta","delta":" AI"}

data: {"type":"response.output_text.delta","delta":" agent"}

data: {"type":"response.completed","response":{"id":"resp_123","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"An AI agent is..."}]}]}}

data: [DONE]
```

Three rules:

- Each event starts with `data: ` followed by JSON.
- Events are separated by blank lines.
- The stream ends with the literal sentinel `data: [DONE]`.

There are many event types (`response.created`, `response.output_item.added`, `response.function_call_arguments.delta`, etc.) but for our agent we only need two:

- **`response.output_text.delta`** — incremental text to print as it arrives.
- **`response.completed`** — the final response, including the full `output` array with any function calls already assembled for us.

That's a meaningful simplification over Chat Completions: we don't need to glue together fragmented tool call argument deltas ourselves. The terminal `response.completed` event hands us complete `function_call` items in one shot.

## Stream Types

Create `api/sse.go`:

```go
package api

import "encoding/json"

// StreamEvent is one Server-Sent Event from the Responses API stream.
//
// Every payload has a `type` discriminator. We capture the two fields we
// actually consume in the agent loop:
//   - `delta`: text chunk from "response.output_text.delta" events
//   - `response`: the final response object from "response.completed"
type StreamEvent struct {
    Type     string             `json:"type"`
    Delta    string             `json:"delta,omitempty"`
    Response *ResponsesResponse `json:"response,omitempty"`

    // Raw is the original JSON payload, kept for events we don't handle
    // structurally but might want to log or extend later.
    Raw json.RawMessage `json:"-"`
}
```

Most other event types (`response.created`, `response.output_item.added`, ...) flow through as `StreamEvent{Type: ..., Raw: ...}` and the agent loop simply ignores them.

## The Streaming Client

Add this method to `api/client.go`:

```go
// CreateResponseStream sends a streaming Responses API request and returns a
// channel of events. The channel is closed when the stream ends or an error
// occurs. Errors are sent on the errs channel.
func (c *Client) CreateResponseStream(ctx context.Context, req ResponsesRequest) (<-chan StreamEvent, <-chan error) {
    events := make(chan StreamEvent)
    errs := make(chan error, 1)

    req.Stream = true

    go func() {
        defer close(events)
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
        // Default buffer is 64KB; bump it for large response.completed payloads.
        scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

        for scanner.Scan() {
            line := scanner.Text()
            if !strings.HasPrefix(line, "data: ") {
                continue
            }
            payload := strings.TrimPrefix(line, "data: ")
            if payload == "[DONE]" {
                return
            }

            var ev StreamEvent
            if err := json.Unmarshal([]byte(payload), &ev); err != nil {
                errs <- fmt.Errorf("decode event: %w", err)
                return
            }
            ev.Raw = json.RawMessage(payload)

            select {
            case events <- ev:
            case <-ctx.Done():
                errs <- ctx.Err()
                return
            }
        }

        if err := scanner.Err(); err != nil {
            errs <- fmt.Errorf("scan stream: %w", err)
        }
    }()

    return events, errs
}
```

Add `bufio` and `strings` to the imports at the top of `client.go`.

A few things worth pausing on:

- **Two channels, one goroutine** — `events` for happy-path data, `errs` (buffered, capacity 1) for the terminal error. Both are closed by `defer` when the goroutine exits.
- **`bufio.Scanner` with a bigger buffer** — A `response.completed` payload can be tens or hundreds of KB once the model has produced lots of output. We bump the max token to 4 MB.
- **Context cancellation in the select** — If the caller cancels mid-stream, we abandon the read instead of blocking on a full channel.
- **No retries** — Streaming + retries is a rabbit hole. Crash loud, fix the bug.

## Events From the Loop

The agent loop needs to surface multiple kinds of events to the caller: text deltas, completed tool calls, tool results, errors, and "we're done." A discriminated event type is the cleanest way:

Create `agent/events.go`:

```go
package agent

// EventKind describes the kind of an Event.
type EventKind int

const (
    EventTextDelta EventKind = iota
    EventToolCall
    EventToolResult
    EventDone
    EventError
)

// ToolCall is a single function call requested by the model.
type ToolCall struct {
    CallID    string
    Name      string
    Arguments string // JSON-encoded arguments
}

// Event is a single update emitted by the agent loop.
type Event struct {
    Kind     EventKind
    Text     string
    ToolCall ToolCall
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
    "strings"

    "github.com/yourname/agents-go/api"
)

// Agent runs a streaming Responses API loop with tool use.
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
        model:    "gpt-5-mini",
    }
}

// Run drives the agent loop and returns a channel of events.
// The channel is closed when the loop terminates.
func (a *Agent) Run(ctx context.Context, history []api.InputItem) <-chan Event {
    events := make(chan Event)

    go func() {
        defer close(events)

        // Make a private copy so we can append without affecting the caller.
        input := append([]api.InputItem(nil), history...)

        for {
            req := api.ResponsesRequest{
                Model:        a.model,
                Instructions: SystemPrompt,
                Input:        input,
                Tools:        a.registry.Definitions(),
            }

            stream, errs := a.client.CreateResponseStream(ctx, req)

            var final *api.ResponsesResponse

        readStream:
            for {
                select {
                case ev, ok := <-stream:
                    if !ok {
                        break readStream
                    }
                    switch ev.Type {
                    case "response.output_text.delta":
                        if ev.Delta != "" {
                            events <- Event{Kind: EventTextDelta, Text: ev.Delta}
                        }
                    case "response.completed":
                        final = ev.Response
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

            // Drain any error that arrived after the events channel closed.
            select {
            case err := <-errs:
                if err != nil {
                    events <- Event{Kind: EventError, Err: err}
                    return
                }
            default:
            }

            if final == nil {
                events <- Event{Kind: EventError, Err: fmt.Errorf("stream ended without response.completed")}
                return
            }

            // Append every output item from the model back into the input
            // history (function_call items are required for the model to
            // accept matching function_call_output items on the next turn).
            var toolCalls []ToolCall
            for _, item := range final.Output {
                input = append(input, outputToInput(item))
                if item.Type == "function_call" {
                    toolCalls = append(toolCalls, ToolCall{
                        CallID:    item.CallID,
                        Name:      item.Name,
                        Arguments: item.Arguments,
                    })
                }
            }

            // No tool calls → conversation is done.
            if len(toolCalls) == 0 {
                events <- Event{Kind: EventDone}
                return
            }

            // Execute each tool call and append a function_call_output item.
            for _, tc := range toolCalls {
                events <- Event{Kind: EventToolCall, ToolCall: tc}

                result, err := a.registry.Execute(tc.Name, json.RawMessage(tc.Arguments))
                if err != nil {
                    result = fmt.Sprintf("Error: %v", err)
                }

                events <- Event{Kind: EventToolResult, ToolCall: tc, Result: result}
                input = append(input, api.NewFunctionCallOutput(tc.CallID, result))
            }
            // Loop again — feed tool results back to the model.
        }
    }()

    return events
}

// outputToInput converts a Responses API output item into an input item
// suitable for the next turn's `input` array.
func outputToInput(item api.OutputItem) api.InputItem {
    switch item.Type {
    case "function_call":
        return api.InputItem{
            Type:      "function_call",
            CallID:    item.CallID,
            Name:      item.Name,
            Arguments: item.Arguments,
        }
    case "message":
        var sb strings.Builder
        for _, part := range item.Content {
            if part.Type == "output_text" {
                sb.WriteString(part.Text)
            }
        }
        return api.InputItem{Role: "assistant", Content: sb.String()}
    }
    // Other typed items (reasoning, web_search_call, ...) are dropped on
    // the floor — the model regenerates whatever it needs.
    return api.InputItem{}
}
```

The shape is the standard agent loop:

1. Send the conversation to the model.
2. Stream the response, printing text deltas as they arrive and capturing the final `response.completed` event.
3. Append every output item to history (so `function_call` items are paired with their `function_call_output` siblings).
4. If there are no tool calls, emit `Done` and exit.
5. Otherwise, execute each tool call, append the results as `function_call_output` items, and loop.

The `select` over `stream`, `errs`, and `ctx.Done()` is the heart of it. Channels make the concurrency story almost boring — there's no `Pin<Box<dyn Future>>` or `async fn` ceremony, just "read whichever thing is ready next."

### Why Append Function Calls to History?

The Responses API requires every `function_call_output` item to be paired with its matching `function_call` item earlier in the same `input` array. If you only append the output, the next request fails with `No tool call found for function call output`. That's why we replay the model's `function_call` items verbatim.

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

    history := []api.InputItem{
        api.NewUserMessage("List the files in the current directory, then read go.mod and tell me the module name."),
    }

    ctx := context.Background()
    for ev := range a.Run(ctx, history) {
        switch ev.Kind {
        case agent.EventTextDelta:
            fmt.Print(ev.Text)
        case agent.EventToolCall:
            fmt.Printf("\n[tool call] %s(%s)\n", ev.ToolCall.Name, ev.ToolCall.Arguments)
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

- Parsed Responses API Server-Sent Events with `bufio.Scanner` and a `data: ` prefix check
- Modeled streamed events as a single typed `StreamEvent` struct with a `type` discriminator
- Captured complete `function_call` items from the terminal `response.completed` event — no fragment accumulator required
- Designed the loop's output as a typed `Event` channel
- Wrote the core agent loop using `select` over events, errors, and context cancellation
- Watched the model call multiple tools across multiple turns

Next, we'll write evals that grade *full conversations* — not just whether the first tool call is right, but whether the agent eventually arrives at the correct answer.

---

**Next: [Chapter 5: Multi-Turn Evaluations →](./05-multi-turn-evals.md)**
