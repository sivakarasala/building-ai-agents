# Chapter 9: Terminal UI with Bubble Tea

## From `fmt.Println` to a Real UI

Up to now we've been printing to stdout. That works for one-shot prompts but falls apart the moment you want:

- A persistent input box at the bottom
- Streaming text that doesn't fight scrollback
- An approval prompt that pauses the agent while the user thinks
- Colors, spacing, and structure that don't look like a CI log

Bubble Tea gives us all of that with the **Elm Architecture**: state, messages, an `Update` function, a `View` function. If you've never written Elm or Redux, the mental model is "every interaction is a message; the model handles messages and produces a new model and possibly more messages."

The hard part for us isn't Bubble Tea itself — it's bridging Bubble Tea's single-threaded `Update` loop with our agent loop's goroutine and channel.

## Installing the Charm Stack

```bash
go get github.com/charmbracelet/bubbletea
go get github.com/charmbracelet/lipgloss
go get github.com/charmbracelet/bubbles/textinput
```

Three packages:

- **`bubbletea`** — The runtime and the `Model`/`Update`/`View` interfaces.
- **`lipgloss`** — Style definitions: colors, padding, borders.
- **`bubbles/textinput`** — A reusable text-input widget so we don't reinvent cursor handling.

## Styles

Create `ui/styles.go`:

```go
package ui

import "github.com/charmbracelet/lipgloss"

var (
    userStyle      = lipgloss.NewStyle().Foreground(lipgloss.Color("12")).Bold(true)
    assistantStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("10"))
    toolCallStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("13"))
    toolResultStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
    errorStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("9")).Bold(true)
    approvalStyle  = lipgloss.NewStyle().
        Foreground(lipgloss.Color("11")).
        Bold(true).
        Border(lipgloss.RoundedBorder()).
        Padding(0, 1)
)
```

The numbers are ANSI palette indices. They render reasonably on every terminal without requiring true color support.

## The Model

Bubble Tea calls the application state a `Model`. Ours holds the conversation transcript, the input field, the current streaming buffer, and the pending approval (if any).

Create `ui/app.go`:

```go
package ui

import (
    "context"
    "fmt"
    "strings"

    "github.com/charmbracelet/bubbles/textinput"
    tea "github.com/charmbracelet/bubbletea"

    "github.com/yourname/agents-go/agent"
    "github.com/yourname/agents-go/api"
)

type lineKind int

const (
    lineUser lineKind = iota
    lineAssistant
    lineToolCall
    lineToolResult
    lineError
)

type line struct {
    kind lineKind
    text string
}

// pendingApproval holds a tool call that needs user confirmation.
type pendingApproval struct {
    call agent.ToolCall
    resp chan bool
}

// Model is the Bubble Tea application state.
type Model struct {
    agent    *agent.Agent
    history  []api.InputItem
    lines    []line
    input    textinput.Model
    streaming strings.Builder

    events   chan agent.Event
    approval chan pendingApproval
    pending  *pendingApproval

    busy bool
    quit bool
}

// NewModel constructs the UI model. The system prompt is held by the agent
// itself (via the Responses API `instructions` field), so the UI only tracks
// the input array.
func NewModel(a *agent.Agent) Model {
    ti := textinput.New()
    ti.Placeholder = "Ask the agent something..."
    ti.Focus()
    ti.CharLimit = 4096
    ti.Width = 80

    return Model{
        agent:    a,
        input:    ti,
        approval: make(chan pendingApproval),
    }
}

func (m Model) Init() tea.Cmd {
    return textinput.Blink
}
```

A few things worth pointing at:

- **`lines` is the rendered transcript.** We don't try to re-render `history` from scratch each frame; we keep a parallel slice of `line` records that already know how they should be styled.
- **`streaming` is a separate buffer for the in-progress assistant turn.** When the model finishes streaming, we flush it into `lines` as one assistant entry.
- **`approval` is an unbuffered channel.** The agent loop sends a `pendingApproval` and *blocks* on `resp`. The UI receives it, renders the prompt, and unblocks the agent only after the user presses `y` or `n`.

## Bridging the Agent Loop to Bubble Tea

Bubble Tea's `Update` function is single-threaded. To get events from a channel into `Update`, we wrap each receive in a `tea.Cmd` that returns a `tea.Msg`.

Add to `ui/app.go`:

```go
type agentEventMsg struct{ ev agent.Event }
type agentDoneMsg struct{}
type approvalRequestMsg struct{ pending pendingApproval }

func waitForEvent(events <-chan agent.Event) tea.Cmd {
    return func() tea.Msg {
        ev, ok := <-events
        if !ok {
            return agentDoneMsg{}
        }
        return agentEventMsg{ev: ev}
    }
}

func waitForApproval(ch <-chan pendingApproval) tea.Cmd {
    return func() tea.Msg {
        p, ok := <-ch
        if !ok {
            return nil
        }
        return approvalRequestMsg{pending: p}
    }
}
```

Each `tea.Cmd` is a function Bubble Tea runs on a goroutine of its own. When the function returns a message, Bubble Tea delivers it to `Update`. We chain them: every time we handle an event, we issue another `waitForEvent` so the next event lands as a new message.

## Approval-Gating the Agent

The agent loop in Chapter 4 ran every tool unconditionally. We need to teach it to check `RequiresApproval` and ask first. Add a new method to `agent/run.go`:

```go
// RunWithApproval is like Run but consults askApproval before executing any
// tool whose RequiresApproval returns true.
func (a *Agent) RunWithApproval(
    ctx context.Context,
    history []api.InputItem,
    askApproval func(ToolCall) bool,
) <-chan Event {
    events := make(chan Event)

    go func() {
        defer close(events)
        input := append([]api.InputItem(nil), history...)

        for {
            // ... same compaction + streaming code as Run ...
            // After collecting toolCalls from response.completed:

            for _, tc := range toolCalls {
                events <- Event{Kind: EventToolCall, ToolCall: tc}

                if a.registry.RequiresApproval(tc.Name) {
                    if !askApproval(tc) {
                        result := "User denied this tool call."
                        events <- Event{Kind: EventToolResult, ToolCall: tc, Result: result}
                        input = append(input, api.NewFunctionCallOutput(tc.CallID, result))
                        continue
                    }
                }

                result, err := a.registry.Execute(tc.Name, json.RawMessage(tc.Arguments))
                if err != nil {
                    result = fmt.Sprintf("Error: %v", err)
                }
                events <- Event{Kind: EventToolResult, ToolCall: tc, Result: result}
                input = append(input, api.NewFunctionCallOutput(tc.CallID, result))
            }
        }
    }()

    return events
}
```

(For brevity I'm showing only the diff against `Run`. In your code, copy `Run` to `RunWithApproval` and add the `RequiresApproval` check.)

The `askApproval` callback is the boundary between the agent goroutine and the UI. It takes a `ToolCall`, blocks until the user decides, and returns `true` to run or `false` to deny. The UI implements it with the `approval` channel.

## The `Update` Function

This is the meatiest function in the chapter. It handles three kinds of messages: keys, agent events, and approval requests.

Add to `ui/app.go`:

```go
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.KeyMsg:
        return m.handleKey(msg)
    case agentEventMsg:
        return m.handleAgentEvent(msg.ev)
    case agentDoneMsg:
        m.busy = false
        return m, nil
    case approvalRequestMsg:
        m.pending = &msg.pending
        return m, waitForApproval(m.approval)
    }
    var cmd tea.Cmd
    m.input, cmd = m.input.Update(msg)
    return m, cmd
}

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
    // Approval prompt takes precedence over normal input.
    if m.pending != nil {
        switch msg.String() {
        case "y", "Y":
            m.pending.resp <- true
            m.pending = nil
            return m, nil
        case "n", "N", "esc":
            m.pending.resp <- false
            m.pending = nil
            return m, nil
        }
        return m, nil
    }

    switch msg.Type {
    case tea.KeyCtrlC, tea.KeyEsc:
        m.quit = true
        return m, tea.Quit
    case tea.KeyEnter:
        if m.busy {
            return m, nil
        }
        text := strings.TrimSpace(m.input.Value())
        if text == "" {
            return m, nil
        }
        m.input.SetValue("")
        m.lines = append(m.lines, line{kind: lineUser, text: text})
        m.history = append(m.history, api.NewUserMessage(text))
        m.busy = true
        // Note: m.history is the []api.InputItem accumulated across turns.

        ctx := context.Background()
        m.events = m.agent.RunWithApproval(ctx, m.history, m.askApproval)
        return m, tea.Batch(waitForEvent(m.events), waitForApproval(m.approval))
    }

    var cmd tea.Cmd
    m.input, cmd = m.input.Update(msg)
    return m, cmd
}

func (m Model) handleAgentEvent(ev agent.Event) (tea.Model, tea.Cmd) {
    switch ev.Kind {
    case agent.EventTextDelta:
        m.streaming.WriteString(ev.Text)
    case agent.EventToolCall:
        if m.streaming.Len() > 0 {
            m.lines = append(m.lines, line{kind: lineAssistant, text: m.streaming.String()})
            m.streaming.Reset()
        }
        m.lines = append(m.lines, line{
            kind: lineToolCall,
            text: fmt.Sprintf("%s(%s)", ev.ToolCall.Name, ev.ToolCall.Arguments),
        })
    case agent.EventToolResult:
        preview := ev.Result
        if len(preview) > 200 {
            preview = preview[:200] + "..."
        }
        m.lines = append(m.lines, line{kind: lineToolResult, text: preview})
    case agent.EventDone:
        if m.streaming.Len() > 0 {
            m.lines = append(m.lines, line{kind: lineAssistant, text: m.streaming.String()})
            m.streaming.Reset()
        }
        m.busy = false
        return m, nil
    case agent.EventError:
        m.lines = append(m.lines, line{kind: lineError, text: ev.Err.Error()})
        m.busy = false
        return m, nil
    }
    return m, waitForEvent(m.events)
}

// askApproval is the callback the agent loop calls when a destructive tool
// fires. It blocks until the UI decides.
func (m *Model) askApproval(tc agent.ToolCall) bool {
    resp := make(chan bool, 1)
    m.approval <- pendingApproval{call: tc, resp: resp}
    return <-resp
}
```

The control flow is the part that's worth re-reading:

1. User presses Enter → we kick off the agent and issue **two** waiting commands at once: one for events, one for approval requests.
2. Each event arrives, we update state, and we re-issue `waitForEvent`. The approval waiter is still parked.
3. If the loop hits a destructive tool, the agent goroutine sends an approval request and blocks. The waiter unblocks and a `approvalRequestMsg` lands in `Update`. We stash it in `m.pending`.
4. The view shows the prompt; the next key press resolves it.
5. We send the result back on `resp`, the agent goroutine resumes, and events flow again.

`tea.Batch` running both waiters in parallel is what makes the approval prompt asynchronous to the event stream. Without it, the UI would have to choose to wait for one thing at a time.

## The `View` Function

Rendering is straightforward — walk the `lines`, style each kind, then append the streaming buffer and the input box.

Add to `ui/app.go`:

```go
func (m Model) View() string {
    if m.quit {
        return ""
    }

    var sb strings.Builder
    for _, l := range m.lines {
        sb.WriteString(renderLine(l))
        sb.WriteByte('\n')
    }
    if m.streaming.Len() > 0 {
        sb.WriteString(assistantStyle.Render("> " + m.streaming.String()))
        sb.WriteByte('\n')
    }
    if m.pending != nil {
        sb.WriteString(approvalStyle.Render(fmt.Sprintf(
            "Approve %s(%s)? [y/N]",
            m.pending.call.Name,
            m.pending.call.Arguments,
        )))
        sb.WriteByte('\n')
    }

    sb.WriteString(m.input.View())
    return sb.String()
}

func renderLine(l line) string {
    switch l.kind {
    case lineUser:
        return userStyle.Render("you> ") + l.text
    case lineAssistant:
        return assistantStyle.Render("> ") + l.text
    case lineToolCall:
        return toolCallStyle.Render("[tool] ") + l.text
    case lineToolResult:
        return toolResultStyle.Render("[result] ") + l.text
    case lineError:
        return errorStyle.Render("[error] ") + l.text
    }
    return l.text
}
```

This is naive — it renders the whole transcript on every frame instead of using a scrolling viewport. For a real terminal app you'd reach for `bubbles/viewport`. For learning purposes, the naive version makes the data flow obvious.

## Wiring `main.go`

Replace `main.go` with the UI version:

```go
package main

import (
    "log"
    "os"

    tea "github.com/charmbracelet/bubbletea"
    "github.com/joho/godotenv"

    "github.com/yourname/agents-go/agent"
    "github.com/yourname/agents-go/api"
    "github.com/yourname/agents-go/tools"
    "github.com/yourname/agents-go/ui"
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
    registry.Register(tools.WriteFile{})
    registry.Register(tools.EditFile{})
    registry.Register(tools.DeleteFile{})
    registry.Register(tools.NewWebSearch())
    registry.Register(tools.Shell{})
    registry.Register(tools.RunCode{})

    a := agent.NewAgent(client, registry)
    model := ui.NewModel(a)

    p := tea.NewProgram(model, tea.WithAltScreen())
    if _, err := p.Run(); err != nil {
        log.Fatalf("ui: %v", err)
    }
}
```

`tea.WithAltScreen` flips the terminal into alt-screen mode (the same mode `vim` and `less` use), giving us a clean canvas that's restored on exit.

Run it:

```bash
go run .
```

You should see the input box at the bottom of an empty screen. Type a request, press Enter, watch the agent stream its way through tool calls. When it tries to write a file, the approval prompt pops up and the loop pauses until you decide.

## The Concurrency Story, Reviewed

Three goroutines are running together:

1. **The Bubble Tea event loop** — Owns the model. Single-threaded. Handles `Update` and `View`.
2. **Bubble Tea's command runners** — Run our `waitForEvent` and `waitForApproval` cmds, each on their own goroutine, and ferry messages back to the event loop.
3. **The agent goroutine** — Runs streaming and tool execution. Sends `Event`s on its channel. Blocks on the approval channel when it needs the user.

They communicate exclusively through channels. No mutexes, no shared mutable state. This is the Go concurrency story working exactly as advertised: each goroutine has one job, and the channels make hand-offs explicit.

## Summary

In this chapter you:

- Learned the Elm Architecture as Bubble Tea expresses it
- Bridged the agent's `Event` channel to Bubble Tea via `tea.Cmd` waiters
- Built an approval flow with an unbuffered channel that blocks the agent until the user decides
- Rendered a styled transcript with `lipgloss`
- Ran the whole thing as a real terminal application

One chapter to go: hardening the agent for use by people who aren't you.

---

**Next: [Chapter 10: Going to Production →](./10-going-to-production.md)**
