# Chapter 3: Single-Turn Evaluations

## Why Evals?

You have tools. The LLM can call them. But *does it call the right ones*? If you ask "What files are in this directory?", does the model pick `list_files` or `read_file`? If you ask "What's the weather?", does it correctly use *no* tools?

Evaluations answer these questions systematically. Instead of testing by hand each time you change a prompt or add a tool, you run a suite of test cases that verify tool selection.

This chapter builds a single-turn eval framework — one user message in, one tool call out, scored automatically.

## Eval Types

Create `eval/types.go`:

```go
package eval

// Case is a single evaluation test case.
type Case struct {
    Input          string   `json:"input"`
    ExpectedTool   string   `json:"expected_tool"`
    SecondaryTools []string `json:"secondary_tools,omitempty"`
}

// Result is the result of running one eval case.
type Result struct {
    Input        string  `json:"input"`
    ExpectedTool string  `json:"expected_tool"`
    ActualTool   string  `json:"actual_tool"`
    Passed       bool    `json:"passed"`
    Score        float64 `json:"score"`
    Reason       string  `json:"reason"`
}

// Summary aggregates a batch of results.
type Summary struct {
    Total        int      `json:"total"`
    Passed       int      `json:"passed"`
    Failed       int      `json:"failed"`
    AverageScore float64  `json:"average_score"`
    Results      []Result `json:"results"`
}
```

Three case types drive the scoring:

- **Golden tool** (`ExpectedTool`) — The best tool for this input. Full marks.
- **Secondary tools** (`SecondaryTools`) — Acceptable alternatives. Partial credit.
- **Negative cases** — Set `ExpectedTool` to `"none"`. The model should respond with text, not a tool call.

## Evaluators

Create `eval/evaluators.go`:

```go
package eval

import "fmt"

// Evaluate scores a single tool call against an eval case.
func Evaluate(c Case, actualTool string) Result {
    r := Result{
        Input:        c.Input,
        ExpectedTool: c.ExpectedTool,
        ActualTool:   actualTool,
    }

    switch {
    case actualTool != "" && actualTool == c.ExpectedTool:
        r.Passed = true
        r.Score = 1.0
        r.Reason = "Correct: selected " + actualTool
    case actualTool != "" && contains(c.SecondaryTools, actualTool):
        r.Passed = true
        r.Score = 0.5
        r.Reason = "Acceptable: selected " + actualTool + " (secondary)"
    case actualTool == "" && c.ExpectedTool == "none":
        r.Passed = true
        r.Score = 1.0
        r.Reason = "Correct: no tool call"
    case actualTool != "" && c.ExpectedTool == "none":
        r.Reason = fmt.Sprintf("Expected no tool call, got %s", actualTool)
    case actualTool == "":
        r.Reason = fmt.Sprintf("Expected %s, got no tool call", c.ExpectedTool)
    default:
        r.Reason = fmt.Sprintf("Wrong tool: expected %s, got %s", c.ExpectedTool, actualTool)
    }

    return r
}

// Summarize aggregates results into a summary.
func Summarize(results []Result) Summary {
    s := Summary{Total: len(results), Results: results}
    var scoreSum float64
    for _, r := range results {
        if r.Passed {
            s.Passed++
        } else {
            s.Failed++
        }
        scoreSum += r.Score
    }
    if s.Total > 0 {
        s.AverageScore = scoreSum / float64(s.Total)
    }
    return s
}

func contains(haystack []string, needle string) bool {
    for _, h := range haystack {
        if h == needle {
            return true
        }
    }
    return false
}
```

The empty string `""` represents "no tool was called" — a clean Go idiom that avoids the need for a pointer or sentinel type.

## The Executor

The executor sends a single message to the API and extracts which tool was called. Create `eval/runner.go`:

```go
package eval

import (
    "context"

    "github.com/yourname/agents-go/agent"
    "github.com/yourname/agents-go/api"
)

// RunSingleTurn sends a single user message and returns the tool name the model chose.
// Returns "" if no tool was called.
func RunSingleTurn(ctx context.Context, client *api.Client, defs []api.ToolDefinition, input string) (string, error) {
    req := api.ChatCompletionRequest{
        Model: "gpt-4.1-mini",
        Messages: []api.Message{
            api.NewSystemMessage(agent.SystemPrompt),
            api.NewUserMessage(input),
        },
        Tools: defs,
    }

    resp, err := client.ChatCompletion(ctx, req)
    if err != nil {
        return "", err
    }

    if len(resp.Choices) == 0 {
        return "", nil
    }
    if len(resp.Choices[0].Message.ToolCalls) == 0 {
        return "", nil
    }
    return resp.Choices[0].Message.ToolCalls[0].Function.Name, nil
}
```

## Test Data

Create `eval_data/file_tools.json`:

```json
[
    {
        "input": "What files are in the current directory?",
        "expected_tool": "list_files"
    },
    {
        "input": "Show me the contents of main.go",
        "expected_tool": "read_file"
    },
    {
        "input": "Read the go.mod file",
        "expected_tool": "read_file",
        "secondary_tools": ["list_files"]
    },
    {
        "input": "What is Go?",
        "expected_tool": "none"
    },
    {
        "input": "Tell me a joke",
        "expected_tool": "none"
    },
    {
        "input": "List everything in the api directory",
        "expected_tool": "list_files"
    }
]
```

## Running Evals

Create `cmd/eval-single/main.go`:

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
    "github.com/yourname/agents-go/eval"
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
    defs := registry.Definitions()

    data, err := os.ReadFile("eval_data/file_tools.json")
    if err != nil {
        log.Fatalf("read eval data: %v", err)
    }

    var cases []eval.Case
    if err := json.Unmarshal(data, &cases); err != nil {
        log.Fatalf("parse eval data: %v", err)
    }

    fmt.Printf("Running %d eval cases...\n\n", len(cases))

    var results []eval.Result
    ctx := context.Background()

    for _, c := range cases {
        actual, err := eval.RunSingleTurn(ctx, client, defs, c.Input)
        if err != nil {
            log.Printf("run %q: %v", c.Input, err)
            continue
        }

        result := eval.Evaluate(c, actual)
        status := "FAIL"
        if result.Passed {
            status = "PASS"
        }
        fmt.Printf("[%s] %q → %s\n", status, result.Input, result.Reason)
        results = append(results, result)
    }

    s := eval.Summarize(results)
    fmt.Printf("\n--- Summary ---\n")
    fmt.Printf("Passed: %d/%d (%.0f%%)\n", s.Passed, s.Total, s.AverageScore*100)
    if s.Failed > 0 {
        fmt.Printf("Failed: %d\n", s.Failed)
    }
}
```

Run the evals:

```bash
go run ./cmd/eval-single
```

Expected output:

```
Running 6 eval cases...

[PASS] "What files are in the current directory?" → Correct: selected list_files
[PASS] "Show me the contents of main.go" → Correct: selected read_file
[PASS] "Read the go.mod file" → Correct: selected read_file
[PASS] "What is Go?" → Correct: no tool call
[PASS] "Tell me a joke" → Correct: no tool call
[PASS] "List everything in the api directory" → Correct: selected list_files

--- Summary ---
Passed: 6/6 (100%)
```

### Why a Separate `cmd/` Binary?

We use `cmd/eval-single/main.go` instead of a `_test.go` file. Tests are for deterministic assertions. Evals hit a real API with non-deterministic results — a test that fails 5% of the time is worse than useless. Evals are run manually, examined by humans, and tracked over time.

The `cmd/` directory is the standard Go convention for multiple binaries in one module. Each subdirectory is its own `main` package.

## Summary

In this chapter you:

- Defined eval types as plain Go structs with JSON tags
- Built a scoring system with golden, secondary, and negative cases
- Created a single-turn executor that calls the API and extracts tool names
- Set up a separate `cmd/` binary for running evals
- Used the empty string idiom to represent "no tool called"

Next, we build the agent loop — the core for-loop that streams responses, detects tool calls, executes them, and feeds results back to the LLM.

---

**Next: [Chapter 4: The Agent Loop →](./04-the-agent-loop.md)**
