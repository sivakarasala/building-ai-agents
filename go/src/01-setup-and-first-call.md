# Chapter 1: Setup and Your First LLM Call

## No SDK. Just `net/http`.

Most AI agent tutorials start with `pip install openai` or `npm install ai`. We're starting with `net/http` — Go's standard library HTTP client. OpenAI's API is just a REST endpoint. You send JSON, you get JSON back. Everything between is HTTP.

This matters because when something breaks — and it will — you'll know exactly which layer failed. Was it the HTTP connection? The JSON marshaling? The API response format? There's no SDK to blame, no magic to debug through.

## Project Setup

```bash
mkdir agents-go && cd agents-go
go mod init github.com/yourname/agents-go
```

### Dependencies

We only need a few external packages, and only later in the book. For Chapter 1, the standard library is enough. Add this to `go.mod` later as needed:

```bash
go get github.com/joho/godotenv
```

### Environment

Create `.env`:

```
OPENAI_API_KEY=your-openai-api-key-here
```

And `.gitignore`:

```
.env
agents-go
*.test
```

## The OpenAI Chat Completions API

Before writing code, let's understand the API we're calling. At its core:

```
POST https://api.openai.com/v1/chat/completions
Authorization: Bearer <your-api-key>
Content-Type: application/json

{
  "model": "gpt-4.1-mini",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What is an AI agent?"}
  ]
}
```

Response:

```json
{
  "id": "chatcmpl-abc123",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "An AI agent is..."
    },
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 25,
    "completion_tokens": 42,
    "total_tokens": 67
  }
}
```

That's it. JSON in, JSON out. Let's model this in Go.

## API Types

Create `api/types.go`:

```go
package api

import "encoding/json"

// Message is a single message in a conversation.
type Message struct {
    Role       string     `json:"role"`
    Content    string     `json:"content,omitempty"`
    ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
    ToolCallID string     `json:"tool_call_id,omitempty"`
}

// NewSystemMessage creates a system message.
func NewSystemMessage(content string) Message {
    return Message{Role: "system", Content: content}
}

// NewUserMessage creates a user message.
func NewUserMessage(content string) Message {
    return Message{Role: "user", Content: content}
}

// NewAssistantMessage creates an assistant message.
func NewAssistantMessage(content string) Message {
    return Message{Role: "assistant", Content: content}
}

// NewToolResultMessage creates a tool result message.
func NewToolResultMessage(toolCallID, content string) Message {
    return Message{
        Role:       "tool",
        Content:    content,
        ToolCallID: toolCallID,
    }
}

// ToolCall is a tool call requested by the assistant.
type ToolCall struct {
    ID       string       `json:"id"`
    Type     string       `json:"type"`
    Function FunctionCall `json:"function"`
}

// FunctionCall is the function name and arguments for a tool call.
type FunctionCall struct {
    Name      string `json:"name"`
    Arguments string `json:"arguments"` // JSON string — parsed later
}

// ToolDefinition is a tool definition sent to the API.
type ToolDefinition struct {
    Type     string             `json:"type"`
    Function FunctionDefinition `json:"function"`
}

// FunctionDefinition is the function metadata within a tool definition.
type FunctionDefinition struct {
    Name        string          `json:"name"`
    Description string          `json:"description"`
    Parameters  json.RawMessage `json:"parameters"` // JSON Schema
}

// ChatCompletionRequest is the request body for chat completions.
type ChatCompletionRequest struct {
    Model    string           `json:"model"`
    Messages []Message        `json:"messages"`
    Tools    []ToolDefinition `json:"tools,omitempty"`
    Stream   bool             `json:"stream,omitempty"`
}

// ChatCompletionResponse is the non-streaming response.
type ChatCompletionResponse struct {
    ID      string   `json:"id"`
    Choices []Choice `json:"choices"`
    Usage   *Usage   `json:"usage,omitempty"`
}

type Choice struct {
    Index        int     `json:"index"`
    Message      Message `json:"message"`
    FinishReason string  `json:"finish_reason,omitempty"`
}

type Usage struct {
    PromptTokens     int `json:"prompt_tokens"`
    CompletionTokens int `json:"completion_tokens"`
    TotalTokens      int `json:"total_tokens"`
}
```

A few Go-specific notes:

- **`omitempty`** — Omits fields from JSON when they're zero values. The API doesn't expect `"tool_calls": null` on user messages.
- **`json.RawMessage`** — A raw JSON byte slice that's neither marshaled nor unmarshaled. Perfect for JSON Schema, which is dynamic.
- **`Arguments string`** — Tool call arguments are a JSON string within JSON. We'll parse them separately in each tool.
- **No nullable types** — Go uses pointers (`*Usage`) when a field can be missing. For strings and slices, the zero value (`""`, `nil`) plus `omitempty` covers it.

## The HTTP Client

Create `api/client.go`:

```go
package api

import (
    "bytes"
    "context"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "time"
)

const apiURL = "https://api.openai.com/v1/chat/completions"

// Client is an OpenAI API client.
type Client struct {
    apiKey     string
    httpClient *http.Client
}

// NewClient creates a new OpenAI client.
func NewClient(apiKey string) *Client {
    return &Client{
        apiKey: apiKey,
        httpClient: &http.Client{
            Timeout: 60 * time.Second,
        },
    }
}

// ChatCompletion makes a non-streaming chat completion request.
func (c *Client) ChatCompletion(ctx context.Context, req ChatCompletionRequest) (*ChatCompletionResponse, error) {
    body, err := json.Marshal(req)
    if err != nil {
        return nil, fmt.Errorf("marshal request: %w", err)
    }

    httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, apiURL, bytes.NewReader(body))
    if err != nil {
        return nil, fmt.Errorf("build request: %w", err)
    }

    httpReq.Header.Set("Authorization", "Bearer "+c.apiKey)
    httpReq.Header.Set("Content-Type", "application/json")

    resp, err := c.httpClient.Do(httpReq)
    if err != nil {
        return nil, fmt.Errorf("send request: %w", err)
    }
    defer resp.Body.Close()

    if resp.StatusCode >= 400 {
        respBody, _ := io.ReadAll(resp.Body)
        return nil, fmt.Errorf("OpenAI API error (%d): %s", resp.StatusCode, respBody)
    }

    var result ChatCompletionResponse
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, fmt.Errorf("decode response: %w", err)
    }

    return &result, nil
}
```

This is deliberately minimal. No retries, no streaming (yet), no fancy error types. Just `net/http` calling a URL with a bearer token.

### Idiomatic Error Wrapping

```go
return nil, fmt.Errorf("marshal request: %w", err)
```

The `%w` verb wraps the underlying error so callers can use `errors.Is` and `errors.As` to check for specific error types. The string prefix tells you which layer failed.

### `context.Context` Everywhere

```go
func (c *Client) ChatCompletion(ctx context.Context, req ChatCompletionRequest) (*ChatCompletionResponse, error)
```

Every function that does I/O takes a `context.Context` as its first argument. This is Go's standard way to propagate cancellation, timeouts, and request-scoped values. When the caller cancels the context, the HTTP request is cancelled too.

## The System Prompt

Create `agent/prompt.go`:

```go
package agent

const SystemPrompt = `You are a helpful AI assistant. You provide clear, accurate, and concise responses to user questions.

Guidelines:
- Be direct and helpful
- If you don't know something, say so honestly
- Provide explanations when they add value
- Stay focused on the user's actual question`
```

## Your First LLM Call

Now wire it together. Create `main.go`:

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
)

func main() {
    _ = godotenv.Load()

    apiKey := os.Getenv("OPENAI_API_KEY")
    if apiKey == "" {
        log.Fatal("OPENAI_API_KEY must be set")
    }

    client := api.NewClient(apiKey)
    ctx := context.Background()

    req := api.ChatCompletionRequest{
        Model: "gpt-4.1-mini",
        Messages: []api.Message{
            api.NewSystemMessage(agent.SystemPrompt),
            api.NewUserMessage("What is an AI agent in one sentence?"),
        },
    }

    resp, err := client.ChatCompletion(ctx, req)
    if err != nil {
        log.Fatalf("chat completion: %v", err)
    }

    if len(resp.Choices) > 0 {
        fmt.Println(resp.Choices[0].Message.Content)
    }
}
```

Run it:

```bash
go run .
```

You should see something like:

```
An AI agent is an autonomous system that perceives its environment,
makes decisions, and takes actions to achieve specific goals.
```

That's a raw HTTP call to OpenAI, decoded into Go structs. No SDK involved.

## What We Built

Look at what's happening:

1. `godotenv.Load()` reads the `.env` file into environment variables
2. We construct a `ChatCompletionRequest` — a plain Go struct
3. `json.Marshal` serializes it to JSON via the struct tags
4. `http.Client.Do` sends the HTTP POST with our bearer token
5. The response JSON is decoded into `ChatCompletionResponse`
6. We extract the text from the first choice

Every step is explicit. If the API changes its response format, the JSON decoder will fail with a clear error. If we send a malformed request, the API returns an error and we surface the response body.

## Summary

In this chapter you:

- Set up a Go module with minimal dependencies
- Modeled the OpenAI API as Go structs with JSON tags
- Built an HTTP client using only the standard library
- Made your first LLM call from raw HTTP

In the next chapter, we'll add tool definitions and teach the LLM to call our functions.

---

**Next: [Chapter 2: Tool Calling →](./02-tool-calling.md)**
