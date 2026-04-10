# Chapter 5: Multi-Turn Evaluations

## Beyond Tool Selection

Single-turn evals answer a narrow question: *given this user message, did the model pick the right tool?* That's necessary but not sufficient. Real agents take multiple turns. They call a tool, look at the result, call another tool, and eventually answer. A multi-turn eval grades the **whole trajectory** — did the agent end up giving a correct answer, regardless of which exact path it took?

This chapter has two ingredients:

1. **Mocked tools** — So evals are fast, deterministic, and free.
2. **An LLM judge** — A second model call that reads the transcript and grades the final answer.

## Mocked Tools

Real tools touch the filesystem, the network, the shell. Evals shouldn't. We want to drop in fakes that return canned data so we can test agent behavior without flakiness or cost.

Create `eval/mocks.go`:

```go
package eval

import (
    "encoding/json"
    "fmt"

    "github.com/yourname/agents-go/api"
)

// MockTool is a tool whose Execute returns a canned response.
type MockTool struct {
    name        string
    description string
    parameters  json.RawMessage
    response    string
    calls       *[]MockCall
}

// MockCall records one invocation of a mock tool.
type MockCall struct {
    Name string
    Args string
}

// NewMockTool builds a mock tool with the given name and canned response.
func NewMockTool(name, description, response string, calls *[]MockCall) *MockTool {
    return &MockTool{
        name:        name,
        description: description,
        parameters:  json.RawMessage(`{"type":"object","properties":{},"additionalProperties":true}`),
        response:    response,
        calls:       calls,
    }
}

func (m *MockTool) Name() string             { return m.name }
func (m *MockTool) RequiresApproval() bool   { return false }

func (m *MockTool) Definition() api.ToolDefinition {
    return api.ToolDefinition{
        Type:        "function",
        Name:        m.name,
        Description: m.description,
        Parameters:  m.parameters,
    }
}

func (m *MockTool) Execute(args json.RawMessage) (string, error) {
    if m.calls != nil {
        *m.calls = append(*m.calls, MockCall{Name: m.name, Args: string(args)})
    }
    return m.response, nil
}

// MustResponse returns the canned response or panics.
func (m *MockTool) MustResponse() string { return m.response }

// String for debug printing.
func (m *MockTool) String() string {
    return fmt.Sprintf("MockTool(%s)", m.name)
}
```

Mocks satisfy the same `agent.Tool` interface as real tools, so we can register them in a normal `Registry` and run the agent loop unchanged. The shared `*[]MockCall` slice lets each test inspect which tools were called and with what arguments.

## Multi-Turn Case Types

Add to `eval/types.go` (or create a new file `eval/multiturn.go`):

```go
package eval

// MultiTurnCase describes a multi-turn eval scenario.
type MultiTurnCase struct {
    Name         string            `json:"name"`
    UserMessage  string            `json:"user_message"`
    MockTools    []MockToolSpec    `json:"mock_tools"`
    Rubric       string            `json:"rubric"`
    ExpectedCalls []string         `json:"expected_calls,omitempty"`
}

// MockToolSpec defines one mock tool for a multi-turn case.
type MockToolSpec struct {
    Name        string `json:"name"`
    Description string `json:"description"`
    Response    string `json:"response"`
}

// MultiTurnResult is the outcome of one multi-turn eval.
type MultiTurnResult struct {
    Name        string     `json:"name"`
    Passed      bool       `json:"passed"`
    Score       float64    `json:"score"`
    Reason      string     `json:"reason"`
    FinalText   string     `json:"final_text"`
    ToolCalls   []MockCall `json:"tool_calls"`
}
```

The `Rubric` is a plain-English description of what a correct final answer looks like. The judge uses it. `ExpectedCalls` is an optional sanity check — if you care that a particular tool was called, list it.

## The Multi-Turn Runner

Create `eval/multiturn_runner.go`:

```go
package eval

import (
    "context"
    "strings"

    "github.com/yourname/agents-go/agent"
    "github.com/yourname/agents-go/api"
)

// RunMultiTurn executes one multi-turn case end-to-end against the agent loop.
func RunMultiTurn(ctx context.Context, client *api.Client, c MultiTurnCase) (MultiTurnResult, error) {
    var calls []MockCall
    registry := agent.NewRegistry()
    for _, spec := range c.MockTools {
        registry.Register(NewMockTool(spec.Name, spec.Description, spec.Response, &calls))
    }

    a := agent.NewAgent(client, registry)
    history := []api.InputItem{
        api.NewUserMessage(c.UserMessage),
    }

    var finalText strings.Builder
    for ev := range a.Run(ctx, history) {
        switch ev.Kind {
        case agent.EventTextDelta:
            finalText.WriteString(ev.Text)
        case agent.EventError:
            return MultiTurnResult{
                Name:      c.Name,
                Reason:    "agent error: " + ev.Err.Error(),
                ToolCalls: calls,
            }, nil
        }
    }

    return MultiTurnResult{
        Name:      c.Name,
        FinalText: finalText.String(),
        ToolCalls: calls,
    }, nil
}
```

We register the mocks, kick off the agent, drain the event channel into a single final-text string and a slice of recorded calls. No grading yet — that's the judge's job.

## The LLM Judge

The judge is itself a model call. We hand it the rubric, the user message, the agent's final answer, and the list of tool calls, and ask for a JSON verdict.

Create `eval/judge.go`:

```go
package eval

import (
    "context"
    "encoding/json"
    "fmt"
    "strings"

    "github.com/yourname/agents-go/api"
)

const judgeSystemPrompt = `You grade AI agent transcripts. You are strict but fair.

You will be given:
- A user message
- A rubric describing what a correct final answer looks like
- The agent's final answer
- The sequence of tool calls the agent made

Respond with a JSON object on a single line, no markdown:
{"passed": true|false, "score": 0.0-1.0, "reason": "short explanation"}

Pass if the final answer satisfies the rubric. Partial credit is allowed.`

// Judge grades one multi-turn result against the rubric.
func Judge(ctx context.Context, client *api.Client, c MultiTurnCase, r MultiTurnResult) (MultiTurnResult, error) {
    var callLines []string
    for _, call := range r.ToolCalls {
        callLines = append(callLines, fmt.Sprintf("- %s(%s)", call.Name, call.Args))
    }
    callsBlock := "(none)"
    if len(callLines) > 0 {
        callsBlock = strings.Join(callLines, "\n")
    }

    userPrompt := fmt.Sprintf(
        "User message:\n%s\n\nRubric:\n%s\n\nAgent final answer:\n%s\n\nTool calls:\n%s",
        c.UserMessage, c.Rubric, r.FinalText, callsBlock,
    )

    req := api.ResponsesRequest{
        Model:        "gpt-5-mini",
        Instructions: judgeSystemPrompt,
        Input: []api.InputItem{
            api.NewUserMessage(userPrompt),
        },
    }

    resp, err := client.CreateResponse(ctx, req)
    if err != nil {
        return r, fmt.Errorf("judge call: %w", err)
    }

    var verdict struct {
        Passed bool    `json:"passed"`
        Score  float64 `json:"score"`
        Reason string  `json:"reason"`
    }
    raw := strings.TrimSpace(resp.OutputText)
    // Strip ```json fences if the model added them.
    raw = strings.TrimPrefix(raw, "```json")
    raw = strings.TrimPrefix(raw, "```")
    raw = strings.TrimSuffix(raw, "```")
    raw = strings.TrimSpace(raw)

    if err := json.Unmarshal([]byte(raw), &verdict); err != nil {
        return r, fmt.Errorf("parse judge verdict %q: %w", raw, err)
    }

    r.Passed = verdict.Passed
    r.Score = verdict.Score
    r.Reason = verdict.Reason
    return r, nil
}
```

Two pragmatic notes:

- **Markdown fence stripping** — Models love to wrap JSON in ```` ```json ```` even when told not to. Stripping fences is cheaper than fighting the model.
- **Same model as the agent** — Using a stronger judge model is reasonable in production. For learning, the symmetry keeps things simple.

## Test Data

Create `eval_data/agent_multiturn.json`:

```json
[
    {
        "name": "find_module_name",
        "user_message": "What is the Go module name for this project?",
        "mock_tools": [
            {
                "name": "list_files",
                "description": "List all files and directories in the specified directory path.",
                "response": "[file] go.mod\n[file] main.go\n[dir] api\n[dir] agent"
            },
            {
                "name": "read_file",
                "description": "Read the contents of a file at the specified path.",
                "response": "module github.com/example/agents-go\n\ngo 1.22\n"
            }
        ],
        "rubric": "The answer must include the module name 'github.com/example/agents-go'.",
        "expected_calls": ["list_files", "read_file"]
    },
    {
        "name": "no_tools_needed",
        "user_message": "What does CLI stand for?",
        "mock_tools": [
            {
                "name": "read_file",
                "description": "Read the contents of a file at the specified path.",
                "response": "(should not be called)"
            }
        ],
        "rubric": "The answer must explain that CLI stands for command-line interface. The agent should not call any tools."
    }
]
```

## Running Multi-Turn Evals

Create `cmd/eval-multi/main.go`:

```go
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "log"
    "os"

    "github.com/joho/godotenv"
    "github.com/yourname/agents-go/api"
    "github.com/yourname/agents-go/eval"
)

func main() {
    _ = godotenv.Load()

    apiKey := os.Getenv("OPENAI_API_KEY")
    if apiKey == "" {
        log.Fatal("OPENAI_API_KEY must be set")
    }

    client := api.NewClient(apiKey)

    data, err := os.ReadFile("eval_data/agent_multiturn.json")
    if err != nil {
        log.Fatalf("read eval data: %v", err)
    }

    var cases []eval.MultiTurnCase
    if err := json.Unmarshal(data, &cases); err != nil {
        log.Fatalf("parse eval data: %v", err)
    }

    fmt.Printf("Running %d multi-turn cases...\n\n", len(cases))

    ctx := context.Background()
    var passed, failed int
    var scoreSum float64

    for _, c := range cases {
        r, err := eval.RunMultiTurn(ctx, client, c)
        if err != nil {
            log.Printf("run %s: %v", c.Name, err)
            continue
        }
        r, err = eval.Judge(ctx, client, c, r)
        if err != nil {
            log.Printf("judge %s: %v", c.Name, err)
            continue
        }

        status := "FAIL"
        if r.Passed {
            status = "PASS"
            passed++
        } else {
            failed++
        }
        scoreSum += r.Score

        fmt.Printf("[%s] %s — %.2f\n", status, r.Name, r.Score)
        fmt.Printf("    reason: %s\n", r.Reason)
        fmt.Printf("    calls : %d\n", len(r.ToolCalls))
        fmt.Println()
    }

    fmt.Printf("--- Summary ---\n")
    fmt.Printf("Passed: %d / %d\n", passed, passed+failed)
    if total := passed + failed; total > 0 {
        fmt.Printf("Average score: %.2f\n", scoreSum/float64(total))
    }
}
```

Run it:

```bash
go run ./cmd/eval-multi
```

Expected output:

```
Running 2 multi-turn cases...

[PASS] find_module_name — 1.00
    reason: The agent listed files, read go.mod, and reported the correct module name.
    calls : 2

[PASS] no_tools_needed — 1.00
    reason: Agent answered correctly without calling any tools.
    calls : 0

--- Summary ---
Passed: 2 / 2
Average score: 1.00
```

## Tradeoffs of LLM-as-Judge

The judge is itself a model, which means:

- **It can be wrong.** A lenient judge passes bad answers; a strict judge fails good ones. Spot-check verdicts when scores look surprising.
- **It costs money.** Each eval is now two API calls (agent + judge). For a hundred-case suite, that's two hundred calls per run.
- **It's non-deterministic.** Run the same suite twice and you may get different scores. Track the average over many runs, not single-run pass/fail.

Despite all of that, judges work surprisingly well for grading freeform answers. Anything you'd otherwise grade with regex or substring matching is a candidate.

## Summary

In this chapter you:

- Built `MockTool` so evals can run without touching real systems
- Designed multi-turn case and result types around a rubric
- Wired the existing agent loop into an eval runner with no changes to the loop itself
- Built an LLM judge that returns a strict JSON verdict
- Ran a small suite end-to-end with mocked tools and a rubric

Next up: real file system tools — write, delete, and the safety checks that come with them.

---

**Next: [Chapter 6: File System Tools →](./06-file-system-tools.md)**
