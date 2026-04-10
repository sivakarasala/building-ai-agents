# Chapter 7: Web Search & Context Management

## Two Problems, One Chapter

Two things get in the way of long-running agents:

1. **The agent only knows what's in its training data.** It can't tell you what shipped in Go 1.23 or what the current price of an API call is. It needs to search the web.
2. **Conversations grow without bound.** Every tool result, every assistant turn, every user message gets appended to the history. Eventually you blow past the context window and the model errors out — or, worse, silently truncates and starts hallucinating.

The first problem is a new tool. The second is a new module that watches token counts and compacts old turns into a summary when the conversation gets too long.

## The Web Search Tool

We'll use Tavily, a search API designed for LLM agents. It returns clean summaries instead of raw HTML, which is exactly what we want.

Sign up for a free key at [tavily.com](https://tavily.com) and add it to `.env`:

```
TAVILY_API_KEY=tvly-...
```

Create `tools/web.go`:

```go
package tools

import (
    "bytes"
    "encoding/json"
    "errors"
    "fmt"
    "io"
    "net/http"
    "os"
    "strings"
    "time"

    "github.com/yourname/agents-go/api"
)

const tavilyURL = "https://api.tavily.com/search"

type WebSearch struct {
    httpClient *http.Client
}

func NewWebSearch() WebSearch {
    return WebSearch{httpClient: &http.Client{Timeout: 30 * time.Second}}
}

func (WebSearch) Name() string             { return "web_search" }
func (WebSearch) RequiresApproval() bool   { return false }

func (WebSearch) Definition() api.ToolDefinition {
    return api.ToolDefinition{
        Type: "function",
        Function: api.FunctionDefinition{
            Name:        "web_search",
            Description: "Search the web for current information. Returns a summarized answer plus the top result snippets. Use this when you need information beyond your training data.",
            Parameters: json.RawMessage(`{
                "type": "object",
                "properties": {
                    "query":       {"type": "string", "description": "The search query"},
                    "max_results": {"type": "integer", "description": "Maximum number of results", "default": 5}
                },
                "required": ["query"]
            }`),
        },
    }
}

func (w WebSearch) Execute(args json.RawMessage) (string, error) {
    var params struct {
        Query      string `json:"query"`
        MaxResults int    `json:"max_results"`
    }
    if err := json.Unmarshal(args, &params); err != nil {
        return "", fmt.Errorf("invalid arguments: %w", err)
    }
    if params.Query == "" {
        return "", errors.New("missing 'query' argument")
    }
    if params.MaxResults == 0 {
        params.MaxResults = 5
    }

    apiKey := os.Getenv("TAVILY_API_KEY")
    if apiKey == "" {
        return "Error: TAVILY_API_KEY is not set", nil
    }

    body, _ := json.Marshal(map[string]any{
        "api_key":        apiKey,
        "query":          params.Query,
        "max_results":    params.MaxResults,
        "include_answer": true,
    })

    httpClient := w.httpClient
    if httpClient == nil {
        httpClient = http.DefaultClient
    }

    httpReq, err := http.NewRequest(http.MethodPost, tavilyURL, bytes.NewReader(body))
    if err != nil {
        return "", fmt.Errorf("build request: %w", err)
    }
    httpReq.Header.Set("Content-Type", "application/json")

    resp, err := httpClient.Do(httpReq)
    if err != nil {
        return fmt.Sprintf("Error calling Tavily: %v", err), nil
    }
    defer resp.Body.Close()

    if resp.StatusCode >= 400 {
        respBody, _ := io.ReadAll(resp.Body)
        return fmt.Sprintf("Tavily error (%d): %s", resp.StatusCode, respBody), nil
    }

    var result struct {
        Answer  string `json:"answer"`
        Results []struct {
            Title   string `json:"title"`
            URL     string `json:"url"`
            Content string `json:"content"`
        } `json:"results"`
    }
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return "", fmt.Errorf("decode tavily response: %w", err)
    }

    var sb strings.Builder
    if result.Answer != "" {
        sb.WriteString("Answer: ")
        sb.WriteString(result.Answer)
        sb.WriteString("\n\n")
    }
    sb.WriteString("Sources:\n")
    for i, r := range result.Results {
        fmt.Fprintf(&sb, "%d. %s\n   %s\n   %s\n", i+1, r.Title, r.URL, r.Content)
    }
    return sb.String(), nil
}
```

A few details worth noting:

- **Constructor returns a value, not a pointer** — `WebSearch` holds an `*http.Client`, which is itself a pointer. Wrapping it in another pointer adds nothing. The other tools are zero-sized structs, so they can be used as values directly.
- **`map[string]any` for the request body** — When you only need to build a small JSON object once, an inline map is fine. For anything larger or reused, define a struct.
- **Tavily's `include_answer`** — Asks Tavily to use its own LLM to write a one-paragraph summary. That summary is often all the agent needs, which keeps the response small.

Register it in `main.go`:

```go
registry.Register(tools.NewWebSearch())
```

## Why Token Counting Matters

Each model has a context window — the maximum number of tokens it'll accept in one request. `gpt-4.1-mini` has 128k tokens, which sounds enormous until you start reading entire files into context. A single 5000-line file is ~50k tokens. Two of those plus a long conversation plus tool definitions and you're in trouble.

We need to:

1. Estimate how many tokens the current history holds.
2. When that estimate crosses a threshold, replace the oldest messages with a one-paragraph LLM-generated summary.

Real token counters (like `tiktoken`) require porting BPE tables. For an agent loop, an estimator is enough — we only need to know *roughly* when to compact.

## The Token Estimator

Create `context/tokens.go`:

```go
package context

import "github.com/yourname/agents-go/api"

// EstimateTokens returns a rough token count for a string.
// The 1 token ≈ 4 characters heuristic is good enough to drive compaction.
func EstimateTokens(s string) int {
    if s == "" {
        return 0
    }
    return (len(s) + 3) / 4
}

// EstimateMessages returns a rough total token count for a slice of messages.
// Each message has a small per-message overhead for role and metadata.
func EstimateMessages(messages []api.Message) int {
    total := 0
    for _, m := range messages {
        total += 4 // role + framing
        total += EstimateTokens(m.Content)
        for _, tc := range m.ToolCalls {
            total += 4
            total += EstimateTokens(tc.Function.Name)
            total += EstimateTokens(tc.Function.Arguments)
        }
    }
    return total
}
```

Yes, this is wildly approximate. It's also fast, allocation-free, and good enough to decide *when* to compact. If the threshold is 60k and we're estimating 58k vs 62k, the worst case is one extra compaction we didn't strictly need — not a crash.

## Conversation Compaction

Compaction works in three steps:

1. Decide which messages are "old" enough to summarize. Always keep the system prompt, the most recent user message, and the assistant turns that respond to it.
2. Send the old messages to the model with a "summarize this" prompt.
3. Replace the old messages with one new message: `system` role, content = summary.

Create `context/compact.go`:

```go
package context

import (
    "context"
    "fmt"
    "strings"

    "github.com/yourname/agents-go/api"
)

// DefaultMaxTokens is the soft limit we compact toward.
const DefaultMaxTokens = 60000

// KeepRecent is the number of trailing messages we always preserve verbatim.
const KeepRecent = 6

const compactSystemPrompt = `You are summarizing the early portion of an AI agent conversation so it fits in a smaller context window.

Produce a concise summary that preserves:
- What the user originally asked for and any constraints
- Key facts the agent learned from tool calls
- Files the agent has read or modified
- Decisions the agent has already made

Aim for under 300 words. Write in plain prose, no markdown.`

// MaybeCompact compacts the message history if its estimated token count exceeds the limit.
// It always keeps the system prompt and the trailing KeepRecent messages.
// Returns the (possibly unchanged) history.
func MaybeCompact(ctx context.Context, client *api.Client, messages []api.Message, maxTokens int) ([]api.Message, error) {
    if maxTokens <= 0 {
        maxTokens = DefaultMaxTokens
    }
    if EstimateMessages(messages) < maxTokens {
        return messages, nil
    }
    if len(messages) <= KeepRecent+1 {
        return messages, nil // not enough room to compact safely
    }

    var systemMsg *api.Message
    start := 0
    if messages[0].Role == "system" {
        m := messages[0]
        systemMsg = &m
        start = 1
    }

    cutoff := len(messages) - KeepRecent
    if cutoff <= start {
        return messages, nil
    }
    toSummarize := messages[start:cutoff]
    keep := messages[cutoff:]

    summary, err := summarize(ctx, client, toSummarize)
    if err != nil {
        return nil, err
    }

    out := make([]api.Message, 0, 2+len(keep))
    if systemMsg != nil {
        out = append(out, *systemMsg)
    }
    out = append(out, api.Message{
        Role:    "system",
        Content: "Summary of earlier conversation:\n" + summary,
    })
    out = append(out, keep...)
    return out, nil
}

func summarize(ctx context.Context, client *api.Client, messages []api.Message) (string, error) {
    var transcript strings.Builder
    for _, m := range messages {
        fmt.Fprintf(&transcript, "[%s] %s\n", m.Role, m.Content)
        for _, tc := range m.ToolCalls {
            fmt.Fprintf(&transcript, "  tool_call: %s(%s)\n", tc.Function.Name, tc.Function.Arguments)
        }
    }

    req := api.ChatCompletionRequest{
        Model: "gpt-4.1-mini",
        Messages: []api.Message{
            api.NewSystemMessage(compactSystemPrompt),
            api.NewUserMessage(transcript.String()),
        },
    }
    resp, err := client.ChatCompletion(ctx, req)
    if err != nil {
        return "", fmt.Errorf("compact summary call: %w", err)
    }
    if len(resp.Choices) == 0 {
        return "", fmt.Errorf("compact summary returned no choices")
    }
    return resp.Choices[0].Message.Content, nil
}
```

The key invariants:

- **System prompt is sacred.** We never summarize it — the model needs the original instructions verbatim to keep behaving correctly.
- **Recent turns are preserved verbatim.** The assistant just decided to call a tool; if we summarized that out, the next loop iteration would reach for the wrong context.
- **The summary becomes a new system message.** Marking it as `system` makes it clear the model didn't say this — it's metadata about what *did* happen.

## Wiring Compaction Into the Loop

Update `agent/run.go`. Right at the top of the `for` loop in the goroutine, before building the request, add:

```go
import contextpkg "github.com/yourname/agents-go/context"

// ... inside the for loop, before constructing req:
compacted, err := contextpkg.MaybeCompact(ctx, a.client, history, contextpkg.DefaultMaxTokens)
if err != nil {
    events <- Event{Kind: EventError, Err: err}
    return
}
history = compacted
```

The import alias dodges a clash with the standard library's `context` package, which we already use in this file. (Naming a package `context` is a sin we're committing for didactic clarity — in a real project you'd call this package `convo` or `history` to avoid the alias.)

That's the whole integration. Compaction is invisible to the rest of the loop: a step that occasionally rewrites `history` between turns.

## Trying It Out

You don't easily hit the compaction threshold by hand, but you can lower it temporarily to watch it fire:

```go
compacted, err := contextpkg.MaybeCompact(ctx, a.client, history, 2000)
```

Now run a session that reads a couple of files. After the second or third turn you'll see the assistant continue working as if nothing happened — but if you log `len(history)` before and after `MaybeCompact`, you'll see it shrink.

## Summary

In this chapter you:

- Added a `web_search` tool backed by Tavily
- Built a cheap token estimator with the `1 token ≈ 4 chars` heuristic
- Wrote `MaybeCompact` to summarize old messages into a single system message
- Wired compaction into the agent loop without touching the streaming code

Next up: shell commands and arbitrary code execution. The agent gets significantly more powerful — and significantly more dangerous.

---

**Next: [Chapter 8: Shell Tool & Code Execution →](./08-shell-tool.md)**
