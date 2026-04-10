# Chapter 6: File System Tools

## Read Isn't Enough

`ReadFile` and `ListFiles` get the agent looking at the world, but a coding agent needs to *change* it: create files, edit them, delete them, move them around. This chapter rounds out the file system toolkit and introduces the first tools that need human approval before running.

We'll add three tools:

- **`WriteFile`** — Create or overwrite a file. Requires approval.
- **`EditFile`** — Replace a substring inside a file. Requires approval.
- **`DeleteFile`** — Remove a file. Requires approval.

By the end, the agent can build and modify a small project on its own.

## WriteFile

Append to `tools/file.go`:

```go
// ─── WriteFile ─────────────────────────────────────────────

type WriteFile struct{}

func (WriteFile) Name() string { return "write_file" }

// Writes can clobber data — always confirm with the user.
func (WriteFile) RequiresApproval() bool { return true }

func (WriteFile) Definition() api.ToolDefinition {
    return api.ToolDefinition{
        Type: "function",
        Function: api.FunctionDefinition{
            Name:        "write_file",
            Description: "Write content to a file at the specified path. Creates the file if it doesn't exist, overwrites it if it does. Parent directories are created as needed.",
            Parameters: json.RawMessage(`{
                "type": "object",
                "properties": {
                    "path":    {"type": "string", "description": "The path of the file to write"},
                    "content": {"type": "string", "description": "The content to write to the file"}
                },
                "required": ["path", "content"]
            }`),
        },
    }
}

func (WriteFile) Execute(args json.RawMessage) (string, error) {
    var params struct {
        Path    string `json:"path"`
        Content string `json:"content"`
    }
    if err := json.Unmarshal(args, &params); err != nil {
        return "", fmt.Errorf("invalid arguments: %w", err)
    }
    if params.Path == "" {
        return "", errors.New("missing 'path' argument")
    }

    if dir := filepath.Dir(params.Path); dir != "." && dir != "" {
        if err := os.MkdirAll(dir, 0o755); err != nil {
            return fmt.Sprintf("Error creating parent directories: %v", err), nil
        }
    }

    if err := os.WriteFile(params.Path, []byte(params.Content), 0o644); err != nil {
        return fmt.Sprintf("Error writing file: %v", err), nil
    }
    return fmt.Sprintf("Wrote %d bytes to %s", len(params.Content), params.Path), nil
}
```

Add `path/filepath` to the imports.

Two things matter here:

- **`MkdirAll` is idempotent** — Creates missing parents, no-ops if they already exist. The agent can write `docs/notes/today.md` without first calling some `make_dir` tool.
- **`RequiresApproval()` is `true`** — In Chapter 9 the UI will pause and ask the user before running any tool that returns `true` here. For now we just record the intent.

## EditFile

`WriteFile` is a sledgehammer — it replaces the whole file. For small edits the model would have to read the file, hold the entire content in its context, and rewrite it. That wastes tokens and is error-prone. `EditFile` lets the model say "find this exact substring, replace it with this other substring":

```go
// ─── EditFile ──────────────────────────────────────────────

type EditFile struct{}

func (EditFile) Name() string { return "edit_file" }

func (EditFile) RequiresApproval() bool { return true }

func (EditFile) Definition() api.ToolDefinition {
    return api.ToolDefinition{
        Type: "function",
        Function: api.FunctionDefinition{
            Name:        "edit_file",
            Description: "Replace an exact substring in a file with new content. The old_string must appear exactly once in the file.",
            Parameters: json.RawMessage(`{
                "type": "object",
                "properties": {
                    "path":       {"type": "string", "description": "The path to the file to edit"},
                    "old_string": {"type": "string", "description": "The exact text to find. Must match exactly once."},
                    "new_string": {"type": "string", "description": "The text to replace it with"}
                },
                "required": ["path", "old_string", "new_string"]
            }`),
        },
    }
}

func (EditFile) Execute(args json.RawMessage) (string, error) {
    var params struct {
        Path      string `json:"path"`
        OldString string `json:"old_string"`
        NewString string `json:"new_string"`
    }
    if err := json.Unmarshal(args, &params); err != nil {
        return "", fmt.Errorf("invalid arguments: %w", err)
    }
    if params.Path == "" || params.OldString == "" {
        return "Error: 'path' and 'old_string' are required", nil
    }

    contentBytes, err := os.ReadFile(params.Path)
    if err != nil {
        if errors.Is(err, os.ErrNotExist) {
            return fmt.Sprintf("Error: File not found: %s", params.Path), nil
        }
        return fmt.Sprintf("Error reading file: %v", err), nil
    }
    content := string(contentBytes)

    count := strings.Count(content, params.OldString)
    switch count {
    case 0:
        return fmt.Sprintf("Error: old_string not found in %s", params.Path), nil
    case 1:
        // ok
    default:
        return fmt.Sprintf("Error: old_string appears %d times in %s — make it more specific so it matches exactly once", count, params.Path), nil
    }

    updated := strings.Replace(content, params.OldString, params.NewString, 1)
    if err := os.WriteFile(params.Path, []byte(updated), 0o644); err != nil {
        return fmt.Sprintf("Error writing file: %v", err), nil
    }
    return fmt.Sprintf("Edited %s", params.Path), nil
}
```

Add `strings` to the imports.

The "must match exactly once" rule is the secret to making `EditFile` reliable. If the model tries to replace `func main` and there are two `func main` declarations, we *refuse* and tell it to be more specific. That feedback loop is much more reliable than hoping the model picks the right occurrence.

## DeleteFile

```go
// ─── DeleteFile ────────────────────────────────────────────

type DeleteFile struct{}

func (DeleteFile) Name() string { return "delete_file" }

func (DeleteFile) RequiresApproval() bool { return true }

func (DeleteFile) Definition() api.ToolDefinition {
    return api.ToolDefinition{
        Type: "function",
        Function: api.FunctionDefinition{
            Name:        "delete_file",
            Description: "Delete a file at the specified path. Use with care — this is not reversible.",
            Parameters: json.RawMessage(`{
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "The path of the file to delete"}
                },
                "required": ["path"]
            }`),
        },
    }
}

func (DeleteFile) Execute(args json.RawMessage) (string, error) {
    var params struct {
        Path string `json:"path"`
    }
    if err := json.Unmarshal(args, &params); err != nil {
        return "", fmt.Errorf("invalid arguments: %w", err)
    }
    if params.Path == "" {
        return "", errors.New("missing 'path' argument")
    }

    info, err := os.Stat(params.Path)
    if err != nil {
        if errors.Is(err, os.ErrNotExist) {
            return fmt.Sprintf("Error: File not found: %s", params.Path), nil
        }
        return fmt.Sprintf("Error stat'ing file: %v", err), nil
    }
    if info.IsDir() {
        return fmt.Sprintf("Error: %s is a directory; this tool only deletes files", params.Path), nil
    }

    if err := os.Remove(params.Path); err != nil {
        return fmt.Sprintf("Error deleting file: %v", err), nil
    }
    return fmt.Sprintf("Deleted %s", params.Path), nil
}
```

The `os.Stat` check before removing keeps the model from accidentally `rm -rf`-ing a directory. Directory removal is a separate operation that we deliberately don't expose — too much blast radius for too little upside.

## Registering the New Tools

Update `main.go` to register them:

```go
registry := agent.NewRegistry()
registry.Register(tools.ReadFile{})
registry.Register(tools.ListFiles{})
registry.Register(tools.WriteFile{})
registry.Register(tools.EditFile{})
registry.Register(tools.DeleteFile{})
```

Try a prompt that exercises all of them:

```go
api.NewUserMessage("Create a file hello.txt containing 'Hello, world!', then change 'world' to 'Go', then read the file back to confirm."),
```

Expected output:

```
[tool call] write_file({"path":"hello.txt","content":"Hello, world!"})
[tool result] Wrote 13 bytes to hello.txt
[tool call] edit_file({"path":"hello.txt","old_string":"world","new_string":"Go"})
[tool result] Edited hello.txt
[tool call] read_file({"path":"hello.txt"})
[tool result] Hello, Go!
The file now contains "Hello, Go!".
```

Three turns, three tools, all using only `os` and `path/filepath`.

## A Note on Approval

Every write-side tool returns `true` from `RequiresApproval()`. The registry exposes that via `RequiresApproval(name string)`, but we're not yet using it — the agent loop runs every tool unconditionally. That's fine for now: we're an agent owner running it on our own machine. In Chapter 9 we'll wire approval into the Bubble Tea UI so the user gets a `[y/n]` prompt before each destructive tool fires.

Until then, treat `RequiresApproval` as **declarative metadata** the tool author writes once. It says "this is dangerous"; the loop and UI decide what to do with that information.

## Idiomatic Go in This Chapter

A handful of patterns deserve callouts:

- **`os.WriteFile` and `os.ReadFile`** — Whole-file helpers in the standard `os` package since Go 1.16. No need for `ioutil` (which is deprecated).
- **Octal literals with `0o`** — `0o644`, `0o755`. Modern Go style; the old `0644` form still works but is harder to read.
- **`filepath.Dir`** — Cross-platform path manipulation. Always use `path/filepath`, not `path`, when dealing with OS paths. (`path` is for forward-slash URL paths.)
- **`errors.Is(err, os.ErrNotExist)`** — Sentinel-error matching that walks the wrap chain. More robust than `os.IsNotExist`, which is older and discouraged.
- **String error returns vs `error` returns** — Same pattern as Chapter 2: recoverable errors (file not found, conflict) become string results so the LLM can react. Unexpected errors (bad JSON args) become real `error` values.

## Summary

In this chapter you:

- Added `WriteFile`, `EditFile`, and `DeleteFile` to the tool set
- Used `filepath.Dir` + `os.MkdirAll` to make `WriteFile` create parents
- Made `EditFile` reliable by enforcing exactly-one matches
- Marked all destructive tools with `RequiresApproval() == true`
- Saw the agent compose write/edit/read into a working sequence

Next we'll add web search and start managing context length — once the agent is reading entire files and calling lots of tools, conversations get long fast.

---

**Next: [Chapter 7: Web Search & Context Management →](./07-web-search-context-management.md)**
