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

## The OpenAI Responses API

Before writing code, let's understand the API we're calling. We're using OpenAI's **Responses API** — the modern replacement for Chat Completions. It's built around a list of "input items" (roles or typed items like function calls) and returns a list of "output items".

```
POST https://api.openai.com/v1/responses
Authorization: Bearer <your-api-key>
Content-Type: application/json

{
  "model": "gpt-5-mini",
  "instructions": "You are a helpful assistant.",
  "input": [
    {"role": "user", "content": "What is an AI agent?"}
  ]
}
```

Response:

```json
{
  "id": "resp_abc123",
  "output": [
    {
      "type": "message",
      "role": "assistant",
      "content": [
        {"type": "output_text", "text": "An AI agent is..."}
      ]
    }
  ],
  "output_text": "An AI agent is...",
  "usage": {
    "input_tokens": 25,
    "output_tokens": 42,
    "total_tokens": 67
  }
}
```

A few things to notice that differ from Chat Completions:

- The system prompt is a top-level **`instructions`** field, not a message in the array.
- The conversation is **`input`**, a list of "input items". They can be role-based messages or typed items (function calls, function call outputs).
- The result is **`output`**, a list of "output items" — assistant messages, function calls, reasoning blocks, etc.
- A convenience **`output_text`** field concatenates all assistant text in `output`.

That's it. JSON in, JSON out. Let's model this in Go.

## API Types

Create `api/types.go`:

```go
package api

import "encoding/json"

// InputItem is a single item in a Responses API `input` array.
//
// It is intentionally a single struct that can represent either a
// role-based message ({role, content}) or a typed item like
// {type:"function_call", call_id, name, arguments} and
// {type:"function_call_output", call_id, output}. Empty fields are
// omitted via `omitempty`.
type InputItem struct {
    // Role-based message fields
    Role    string `json:"role,omitempty"`
    Content string `json:"content,omitempty"`

    // Typed item fields (function_call / function_call_output)
    Type      string `json:"type,omitempty"`
    CallID    string `json:"call_id,omitempty"`
    Name      string `json:"name,omitempty"`
    Arguments string `json:"arguments,omitempty"` // JSON string — parsed later
    Output    string `json:"output,omitempty"`
}

// NewUserMessage creates a user input item.
func NewUserMessage(content string) InputItem {
    return InputItem{Role: "user", Content: content}
}

// NewAssistantMessage creates an assistant input item. Use this when
// replaying prior assistant text back into the next request.
func NewAssistantMessage(content string) InputItem {
    return InputItem{Role: "assistant", Content: content}
}

// NewFunctionCall creates a typed function_call input item.
func NewFunctionCall(callID, name, argumentsJSON string) InputItem {
    return InputItem{
        Type:      "function_call",
        CallID:    callID,
        Name:      name,
        Arguments: argumentsJSON,
    }
}

// NewFunctionCallOutput creates a typed function_call_output input item.
// This is how we feed a tool's result back to the model.
func NewFunctionCallOutput(callID, output string) InputItem {
    return InputItem{
        Type:   "function_call_output",
        CallID: callID,
        Output: output,
    }
}

// ToolDefinition is a tool definition sent to the API.
//
// The Responses API uses a flat shape — name/description/parameters live
// directly on the tool, not nested under a "function" object.
type ToolDefinition struct {
    Type        string          `json:"type"`
    Name        string          `json:"name,omitempty"`
    Description string          `json:"description,omitempty"`
    Parameters  json.RawMessage `json:"parameters,omitempty"` // JSON Schema
}

// ResponsesRequest is the request body for /v1/responses.
type ResponsesRequest struct {
    Model        string           `json:"model"`
    Instructions string           `json:"instructions,omitempty"`
    Input        []InputItem      `json:"input"`
    Tools        []ToolDefinition `json:"tools,omitempty"`
    Stream       bool             `json:"stream,omitempty"`
}

// ResponsesResponse is the non-streaming response.
type ResponsesResponse struct {
    ID         string       `json:"id"`
    Output     []OutputItem `json:"output"`
    OutputText string       `json:"output_text,omitempty"`
    Usage      *Usage       `json:"usage,omitempty"`
}

// OutputItem is one item in the model's `output` array.
//
// Common types: "message", "function_call", "reasoning", "web_search_call".
type OutputItem struct {
    Type    string        `json:"type"`
    ID      string        `json:"id,omitempty"`
    Status  string        `json:"status,omitempty"`

    // For type == "message"
    Role    string        `json:"role,omitempty"`
    Content []ContentPart `json:"content,omitempty"`

    // For type == "function_call"
    CallID    string `json:"call_id,omitempty"`
    Name      string `json:"name,omitempty"`
    Arguments string `json:"arguments,omitempty"` // JSON string
}

// ContentPart is a single content block inside a message output item.
type ContentPart struct {
    Type string `json:"type"` // e.g. "output_text"
    Text string `json:"text,omitempty"`
}

type Usage struct {
    InputTokens  int `json:"input_tokens"`
    OutputTokens int `json:"output_tokens"`
    TotalTokens  int `json:"total_tokens"`
}
```

A few Go-specific notes:

- **`omitempty`** — Omits fields from JSON when they're zero values. The API doesn't expect `"role": ""` on a typed function_call item, or `"type": ""` on a plain user message.
- **`json.RawMessage`** — A raw JSON byte slice that's neither marshaled nor unmarshaled. Perfect for JSON Schema, which is dynamic.
- **`Arguments string`** — Function call arguments are a JSON string within JSON. We'll parse them separately in each tool.
- **One `InputItem` struct, two shapes** — Role-based messages and typed items share a struct. `omitempty` keeps the wire format clean. The alternative (an interface with multiple concrete types and a custom marshaler) is more "type-safe" but a lot more code for the same effect.
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

const apiURL = "https://api.openai.com/v1/responses"

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

// CreateResponse makes a non-streaming Responses API request.
func (c *Client) CreateResponse(ctx context.Context, req ResponsesRequest) (*ResponsesResponse, error) {
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

    var result ResponsesResponse
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
func (c *Client) CreateResponse(ctx context.Context, req ResponsesRequest) (*ResponsesResponse, error)
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

In the Responses API the system prompt is passed via the top-level `instructions` field, not as a message in the input array.

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

    req := api.ResponsesRequest{
        Model:        "gpt-5-mini",
        Instructions: agent.SystemPrompt,
        Input: []api.InputItem{
            api.NewUserMessage("What is an AI agent in one sentence?"),
        },
    }

    resp, err := client.CreateResponse(ctx, req)
    if err != nil {
        log.Fatalf("create response: %v", err)
    }

    fmt.Println(resp.OutputText)
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
2. We construct a `ResponsesRequest` — a plain Go struct
3. `json.Marshal` serializes it to JSON via the struct tags
4. `http.Client.Do` sends the HTTP POST with our bearer token
5. The response JSON is decoded into `ResponsesResponse`
6. We print the convenience `OutputText` field

Every step is explicit. If the API changes its response format, the JSON decoder will fail with a clear error. If we send a malformed request, the API returns an error and we surface the response body.

## Summary

In this chapter you:

- Set up a Go module with minimal dependencies
- Modeled the OpenAI Responses API as Go structs with JSON tags
- Built an HTTP client using only the standard library
- Made your first LLM call from raw HTTP

In the next chapter, we'll add tool definitions and teach the LLM to call our functions.

---

**Next: [Chapter 2: Tool Calling →](./02-tool-calling.md)**
