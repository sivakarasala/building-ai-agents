# Chapter 2: Tool Calling with JSON Schema

## The Tool Interface

In TypeScript, a tool is an object with a description and an execute function. In Python, it's a dict with a JSON Schema and a callable. In Go, we use an **interface**.

The `Tool` interface defines what every tool must provide:

```go
// agent/registry.go

package agent

import (
    "encoding/json"

    "github.com/yourname/agents-go/api"
)

// Tool is the interface every tool must implement.
type Tool interface {
    // Name returns the tool's name (matches the API).
    Name() string

    // Definition returns the OpenAI tool definition (sent to the API).
    Definition() api.ToolDefinition

    // Execute runs the tool with the given JSON arguments.
    Execute(args json.RawMessage) (string, error)

    // RequiresApproval returns true if this tool needs human approval.
    RequiresApproval() bool
}
```

Four things to note:

- **`json.RawMessage` for args** — We accept raw JSON rather than typed args. The LLM generates arbitrary JSON that matches our schema, but Go can't know the shape at compile time. We unmarshal it inside each tool's `Execute` method.
- **Returns `(string, error)`** — Idiomatic Go: result + error. Tools can fail. We propagate errors up to the agent loop.
- **`RequiresApproval()` defaults to dangerous** — We'll override this in tools that modify the system. Read-only tools return `false`.
- **No generics needed** — Interfaces give us heterogeneous storage in collections. A `map[string]Tool` can hold any tool type.

## The Tool Registry

```go
// continued in agent/registry.go

// Registry holds and dispatches tools by name.
type Registry struct {
    tools map[string]Tool
}

// NewRegistry creates an empty tool registry.
func NewRegistry() *Registry {
    return &Registry{tools: make(map[string]Tool)}
}

// Register adds a tool to the registry.
func (r *Registry) Register(t Tool) {
    r.tools[t.Name()] = t
}

// Definitions returns all tool definitions for the API.
func (r *Registry) Definitions() []api.ToolDefinition {
    defs := make([]api.ToolDefinition, 0, len(r.tools))
    for _, t := range r.tools {
        defs = append(defs, t.Definition())
    }
    return defs
}

// Execute runs a tool by name.
func (r *Registry) Execute(name string, args json.RawMessage) (string, error) {
    t, ok := r.tools[name]
    if !ok {
        return "", fmt.Errorf("unknown tool: %s", name)
    }
    return t.Execute(args)
}

// RequiresApproval reports whether a tool requires approval.
func (r *Registry) RequiresApproval(name string) bool {
    if t, ok := r.tools[name]; ok {
        return t.RequiresApproval()
    }
    return false
}
```

Don't forget to import `fmt` at the top.

## Your First Tools: ReadFile and ListFiles

Create `tools/file.go`:

```go
package tools

import (
    "encoding/json"
    "errors"
    "fmt"
    "os"
    "sort"

    "github.com/yourname/agents-go/api"
)

// ─── ReadFile ──────────────────────────────────────────────

type ReadFile struct{}

func (ReadFile) Name() string { return "read_file" }

func (ReadFile) RequiresApproval() bool { return false }

func (ReadFile) Definition() api.ToolDefinition {
    return api.ToolDefinition{
        Type:        "function",
        Name:        "read_file",
        Description: "Read the contents of a file at the specified path. Use this to examine file contents.",
        Parameters: json.RawMessage(`{
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "The path to the file to read"
                }
            },
            "required": ["path"]
        }`),
    }
}

func (ReadFile) Execute(args json.RawMessage) (string, error) {
    var params struct {
        Path string `json:"path"`
    }
    if err := json.Unmarshal(args, &params); err != nil {
        return "", fmt.Errorf("invalid arguments: %w", err)
    }
    if params.Path == "" {
        return "", errors.New("missing 'path' argument")
    }

    content, err := os.ReadFile(params.Path)
    if err != nil {
        if errors.Is(err, os.ErrNotExist) {
            return fmt.Sprintf("Error: File not found: %s", params.Path), nil
        }
        return fmt.Sprintf("Error reading file: %v", err), nil
    }
    return string(content), nil
}

// ─── ListFiles ─────────────────────────────────────────────

type ListFiles struct{}

func (ListFiles) Name() string { return "list_files" }

func (ListFiles) RequiresApproval() bool { return false }

func (ListFiles) Definition() api.ToolDefinition {
    return api.ToolDefinition{
        Type:        "function",
        Name:        "list_files",
        Description: "List all files and directories in the specified directory path.",
        Parameters: json.RawMessage(`{
            "type": "object",
            "properties": {
                "directory": {
                    "type": "string",
                    "description": "The directory path to list contents of",
                    "default": "."
                }
            }
        }`),
    }
}

func (ListFiles) Execute(args json.RawMessage) (string, error) {
    var params struct {
        Directory string `json:"directory"`
    }
    if err := json.Unmarshal(args, &params); err != nil {
        return "", fmt.Errorf("invalid arguments: %w", err)
    }
    if params.Directory == "" {
        params.Directory = "."
    }

    entries, err := os.ReadDir(params.Directory)
    if err != nil {
        if errors.Is(err, os.ErrNotExist) {
            return fmt.Sprintf("Error: Directory not found: %s", params.Directory), nil
        }
        return fmt.Sprintf("Error listing directory: %v", err), nil
    }

    items := make([]string, 0, len(entries))
    for _, e := range entries {
        prefix := "[file]"
        if e.IsDir() {
            prefix = "[dir]"
        }
        items = append(items, fmt.Sprintf("%s %s", prefix, e.Name()))
    }
    sort.Strings(items)

    if len(items) == 0 {
        return fmt.Sprintf("Directory %s is empty", params.Directory), nil
    }

    result := items[0]
    for _, item := range items[1:] {
        result += "\n" + item
    }
    return result, nil
}
```

### Why Tools Return `(string, nil)` Instead of an Error

Notice the pattern:

```go
if errors.Is(err, os.ErrNotExist) {
    return fmt.Sprintf("Error: File not found: %s", params.Path), nil
}
```

We return a string with an error description rather than an error value. This is deliberate — tool results go back to the LLM. If `read_file` fails with "File not found", the LLM can try a different path. If we returned `error`, the agent loop would need special handling to convert it to a tool result message. Keeping it as a string means every tool result, success or failure, follows the same path.

The `error` return is still useful for *unexpected* errors — things like "args is not valid JSON" that indicate a bug, not a normal failure.

### Embedded Anonymous Struct for Args

```go
var params struct {
    Path string `json:"path"`
}
if err := json.Unmarshal(args, &params); err != nil {
    return "", fmt.Errorf("invalid arguments: %w", err)
}
```

Each tool defines its own anonymous struct for arguments and unmarshals into it. This gives us type safety inside the tool while keeping the registry interface generic. No reflection, no codegen.

### `errors.Is` for Error Type Checks

```go
if errors.Is(err, os.ErrNotExist) {
```

`errors.Is` walks the error chain (via `%w` wrapping) to find a matching sentinel error. This is more robust than string matching and works even when errors are wrapped.

## Making a Tool Call

Update `main.go` to include tools:

```go
package main

import (
    "context"
    "encoding/json"
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

    // Build the tool registry
    registry := agent.NewRegistry()
    registry.Register(tools.ReadFile{})
    registry.Register(tools.ListFiles{})

    req := api.ResponsesRequest{
        Model:        "gpt-5-mini",
        Instructions: agent.SystemPrompt,
        Input: []api.InputItem{
            api.NewUserMessage("What files are in the current directory?"),
        },
        Tools: registry.Definitions(),
    }

    resp, err := client.CreateResponse(context.Background(), req)
    if err != nil {
        log.Fatalf("create response: %v", err)
    }

    if resp.OutputText != "" {
        fmt.Println("Text:", resp.OutputText)
    }

    // Walk the output items looking for function calls.
    for _, item := range resp.Output {
        if item.Type != "function_call" {
            continue
        }
        fmt.Printf("Tool call: %s(%s)\n", item.Name, item.Arguments)

        // Actually execute the tool
        result, err := registry.Execute(item.Name, json.RawMessage(item.Arguments))
        if err != nil {
            log.Printf("execute %s: %v", item.Name, err)
            continue
        }

        // Print first 200 chars
        if len(result) > 200 {
            result = result[:200] + "..."
        }
        fmt.Println("Result:", result)
    }
}
```

Run it:

```bash
go run .
```

You should see:

```
Tool call: list_files({"directory":"."})
Result: [dir] api
[dir] agent
[dir] tools
[file] go.mod
[file] go.sum
[file] main.go
...
```

The LLM chose `list_files`, we executed it, and got real filesystem results. But the LLM never saw those results — we need the agent loop for that.

## Summary

In this chapter you:

- Defined the `Tool` interface for type-safe tool dispatch
- Built a `Registry` with `map[string]Tool` for heterogeneous tool storage
- Implemented `ReadFile` and `ListFiles` as zero-sized struct types
- Used `json.RawMessage` to defer parameter parsing to each tool
- Made your first tool call and execution

The LLM can select tools and we can execute them. In the next chapter, we'll build evaluations to test tool selection systematically.

---

**Next: [Chapter 3: Single-Turn Evaluations →](./03-single-turn-evals.md)**
