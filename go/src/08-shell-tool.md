# Chapter 8: Shell Tool & Code Execution

## The Most Dangerous Tool

A shell tool turns the agent from "a thing that reads and writes files" into "a thing that can do anything you can do at a terminal." That's an enormous capability boost — and the source of every horror story you've heard about agents wiping their authors' machines.

This chapter is short on lines of code and long on guardrails. We'll add two tools:

- **`Shell`** — Run an arbitrary shell command. Requires approval. Has a timeout.
- **`RunCode`** — Write a snippet to a temp file and execute it with a chosen interpreter. Requires approval.

Both lean heavily on `os/exec` and `context.WithTimeout`.

## The Shell Tool

Create `tools/shell.go`:

```go
package tools

import (
    "context"
    "encoding/json"
    "errors"
    "fmt"
    "os/exec"
    "strings"
    "time"

    "github.com/yourname/agents-go/api"
)

const (
    defaultShellTimeout = 30 * time.Second
    maxOutputBytes      = 16 * 1024
)

type Shell struct{}

func (Shell) Name() string             { return "shell" }
func (Shell) RequiresApproval() bool   { return true }

func (Shell) Definition() api.ToolDefinition {
    return api.ToolDefinition{
        Type: "function",
        Function: api.FunctionDefinition{
            Name:        "shell",
            Description: "Execute a shell command and return its combined stdout and stderr. Use for running build tools, tests, git, and other CLI utilities. The command runs with a 30 second timeout.",
            Parameters: json.RawMessage(`{
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "The shell command to execute"}
                },
                "required": ["command"]
            }`),
        },
    }
}

func (Shell) Execute(args json.RawMessage) (string, error) {
    var params struct {
        Command string `json:"command"`
    }
    if err := json.Unmarshal(args, &params); err != nil {
        return "", fmt.Errorf("invalid arguments: %w", err)
    }
    if strings.TrimSpace(params.Command) == "" {
        return "", errors.New("missing 'command' argument")
    }

    ctx, cancel := context.WithTimeout(context.Background(), defaultShellTimeout)
    defer cancel()

    cmd := exec.CommandContext(ctx, "sh", "-c", params.Command)
    output, err := cmd.CombinedOutput()

    if errors.Is(ctx.Err(), context.DeadlineExceeded) {
        return fmt.Sprintf("Error: command timed out after %s", defaultShellTimeout), nil
    }

    truncated := truncate(string(output), maxOutputBytes)

    if err != nil {
        var exitErr *exec.ExitError
        if errors.As(err, &exitErr) {
            return fmt.Sprintf("Exit code %d\n\n%s", exitErr.ExitCode(), truncated), nil
        }
        return fmt.Sprintf("Error running command: %v\n\n%s", err, truncated), nil
    }

    if truncated == "" {
        return "(no output)", nil
    }
    return truncated, nil
}

func truncate(s string, max int) string {
    if len(s) <= max {
        return s
    }
    return s[:max] + fmt.Sprintf("\n\n[output truncated — %d bytes total]", len(s))
}
```

A handful of patterns are doing real work:

- **`exec.CommandContext`** — Binds the command to a `context.Context`. When the context's deadline expires, Go sends `SIGKILL` to the process and `cmd.Wait` returns. No goroutine plumbing required.
- **`sh -c`** — Runs the command through a shell so the model can use pipes, redirects, and environment variables naturally. The downside is that everything happens in one process tree the model controls — there's no sandboxing here. We'll talk about that in Chapter 10.
- **`CombinedOutput`** — Captures stdout and stderr together. Tools like `go test` print results to stdout but errors to stderr; the model needs to see both interleaved to make sense of failures.
- **`exec.ExitError`** — A non-zero exit isn't a Go error in the bug sense. We surface the exit code and the output as a normal tool result so the model can react.
- **Output truncation** — A `find /` left running could fill the context window with garbage. We cap at 16KB and tell the model when we did.

## The Code Execution Tool

`Shell` can already run scripts via `python -c "..."`, but escaping multi-line code through JSON arguments is painful. `RunCode` makes the common case clean: write the code to a temp file and run it.

```go
// continued in tools/shell.go

type RunCode struct{}

func (RunCode) Name() string             { return "run_code" }
func (RunCode) RequiresApproval() bool   { return true }

func (RunCode) Definition() api.ToolDefinition {
    return api.ToolDefinition{
        Type: "function",
        Function: api.FunctionDefinition{
            Name:        "run_code",
            Description: "Write a code snippet to a temp file and execute it with the given interpreter. Useful for quick computations, experiments, or one-off scripts. 30 second timeout.",
            Parameters: json.RawMessage(`{
                "type": "object",
                "properties": {
                    "language": {
                        "type": "string",
                        "description": "Language to run. Supported: python, node, bash, go.",
                        "enum": ["python", "node", "bash", "go"]
                    },
                    "code": {"type": "string", "description": "The source code to execute"}
                },
                "required": ["language", "code"]
            }`),
        },
    }
}

func (RunCode) Execute(args json.RawMessage) (string, error) {
    var params struct {
        Language string `json:"language"`
        Code     string `json:"code"`
    }
    if err := json.Unmarshal(args, &params); err != nil {
        return "", fmt.Errorf("invalid arguments: %w", err)
    }
    if params.Code == "" {
        return "", errors.New("missing 'code' argument")
    }

    cfg, ok := languageRunners[params.Language]
    if !ok {
        return fmt.Sprintf("Error: unsupported language %q", params.Language), nil
    }

    tmpFile, err := writeTemp(cfg.extension, params.Code)
    if err != nil {
        return fmt.Sprintf("Error writing temp file: %v", err), nil
    }
    defer removeTemp(tmpFile)

    ctx, cancel := context.WithTimeout(context.Background(), defaultShellTimeout)
    defer cancel()

    cmdArgs := append(append([]string(nil), cfg.args...), tmpFile)
    cmd := exec.CommandContext(ctx, cfg.binary, cmdArgs...)
    output, err := cmd.CombinedOutput()

    if errors.Is(ctx.Err(), context.DeadlineExceeded) {
        return fmt.Sprintf("Error: code execution timed out after %s", defaultShellTimeout), nil
    }

    truncated := truncate(string(output), maxOutputBytes)

    if err != nil {
        var exitErr *exec.ExitError
        if errors.As(err, &exitErr) {
            return fmt.Sprintf("Exit code %d\n\n%s", exitErr.ExitCode(), truncated), nil
        }
        return fmt.Sprintf("Error running code: %v\n\n%s", err, truncated), nil
    }
    if truncated == "" {
        return "(no output)", nil
    }
    return truncated, nil
}

type runner struct {
    binary    string
    args      []string
    extension string
}

var languageRunners = map[string]runner{
    "python": {binary: "python3", extension: ".py"},
    "node":   {binary: "node", extension: ".js"},
    "bash":   {binary: "bash", extension: ".sh"},
    "go":     {binary: "go", args: []string{"run"}, extension: ".go"},
}
```

Add the temp file helpers:

```go
import (
    "os"
)

func writeTemp(extension, content string) (string, error) {
    f, err := os.CreateTemp("", "agent-run-*"+extension)
    if err != nil {
        return "", err
    }
    if _, err := f.WriteString(content); err != nil {
        f.Close()
        os.Remove(f.Name())
        return "", err
    }
    if err := f.Close(); err != nil {
        os.Remove(f.Name())
        return "", err
    }
    return f.Name(), nil
}

func removeTemp(path string) {
    _ = os.Remove(path)
}
```

Notes:

- **`os.CreateTemp` with a `*` in the pattern** — The `*` is replaced by random characters, guaranteeing a unique name. We pass the extension after the `*` so the file ends with `.py`, `.go`, etc.
- **Cleanup on every error path** — If we fail mid-write, we remove the partial file. If `Execute` returns normally, the deferred `removeTemp` handles it.
- **Append-with-copy for `cmdArgs`** — `append(append([]string(nil), cfg.args...), tmpFile)` builds a fresh slice instead of mutating `cfg.args` in the map. A subtle Go gotcha: `append` may or may not reuse the underlying array, so mutating shared slices is a bug waiting to happen.

## Registering the Tools

Update `main.go`:

```go
registry.Register(tools.Shell{})
registry.Register(tools.RunCode{})
```

A prompt that exercises both:

```go
api.NewUserMessage("Write a Python script that prints the first ten Fibonacci numbers, run it, and tell me the output."),
```

Expected output (abbreviated):

```
[tool call] run_code({"language":"python","code":"a, b = 0, 1\nfor _ in range(10):\n    print(a)\n    a, b = b, a + b\n"})
[tool result] 0
1
1
2
3
5
8
13
21
34

The first ten Fibonacci numbers are 0, 1, 1, 2, 3, 5, 8, 13, 21, 34.
```

## Why You Should Be Nervous

Right now there is **no sandboxing**. A misbehaving model can:

- Delete your home directory with `rm -rf ~`
- Exfiltrate secrets via `curl ... < ~/.aws/credentials`
- Mine cryptocurrency in the background
- Install software, modify your shell config, ...

The mitigations we already have are real but limited:

- `RequiresApproval() == true` — In Chapter 9 the user will approve every shell call before it runs.
- `context.WithTimeout` — Caps wall-clock damage of any single call.
- Output truncation — Caps token-budget damage.

The mitigations we **don't** have are:

- A chroot, container, or VM around the agent process
- A read-only filesystem layer
- Network egress blocking
- A user with reduced privileges

We'll talk about each of those in Chapter 10. For now: only run this agent in a directory you wouldn't mind losing, on a machine you wouldn't mind reinstalling, and approve every tool call by hand.

## A Brief Word on `os/exec` Pitfalls

A few things that bite people writing shell tools:

- **Don't call `cmd.Output()` and `cmd.CombinedOutput()` after `cmd.Start()`** — They internally call `Run`. Pick one entry point.
- **Don't reuse a `Cmd`** — `exec.Cmd` is one-shot. Build a new one per execution.
- **Watch out for `PATH`** — `exec.LookPath` (which `exec.Command` calls) uses the parent process's `PATH`. If the agent is launched from an environment that doesn't see `python3` or `node`, `RunCode` will fail.
- **`SIGKILL` on timeout means no graceful shutdown** — The killed process won't flush buffers, run defers, or clean up its own temp files. For anything more complicated than these tools, prefer `context.WithCancel` plus an explicit `SIGTERM` first.

## Summary

In this chapter you:

- Wrote a `shell` tool that runs commands through `sh -c` with a timeout
- Wrote a `run_code` tool that writes snippets to temp files for several languages
- Used `exec.CommandContext` to bind subprocesses to deadlines
- Truncated output to keep runaway commands from blowing up the context window
- Marked both tools as requiring approval — and faced up to how dangerous they still are without sandboxing

Next we'll build the terminal UI and finally wire that approval flow into something a human can actually click through.

---

**Next: [Chapter 9: Terminal UI with Bubble Tea →](./09-terminal-ui.md)**
