# Chapter 9: Terminal UI with Ratatui

## The Second Hardest Chapter

Chapter 4 was hard because of streaming state accumulation. This chapter is hard because of *UI state management without a framework*. No React. No virtual DOM. No automatic re-rendering. Ratatui is an immediate-mode UI library — you redraw the entire screen every frame, and you manage all state yourself.

If you've used React or Ink (the TypeScript edition uses Ink), forget everything. Immediate-mode is a fundamentally different paradigm. See **Appendix E** for a primer.

## Quick Primer: Ratatui + Crossterm

**Ratatui** handles rendering — it draws widgets (text, blocks, lists, paragraphs) to a terminal buffer, then flushes the buffer to the screen. It doesn't handle input.

**Crossterm** handles input — keyboard events, terminal mode switching (raw mode), and screen management (alternate screen).

Together:

```rust
// Pseudocode of the ratatui event loop
loop {
    terminal.draw(|frame| {
        // Render widgets based on current state
        frame.render_widget(my_widget, area);
    })?;

    // Handle input
    if crossterm::event::poll(Duration::from_millis(50))? {
        if let Event::Key(key) = crossterm::event::read()? {
            // Update state based on key
        }
    }
}
```

Every frame:
1. **Draw** the entire screen from current state
2. **Poll** for input events
3. **Update** state based on events
4. Repeat

Ratatui diffs the terminal buffer internally, so only changed cells are actually written — but *your code* redraws everything conceptually.

## Application State

Create `src/ui/app.rs`:

```rust
use std::sync::{Arc, Mutex};
use crate::context::model_limits::TokenUsageInfo;

/// The full UI state.
pub struct AppState {
    /// Chat messages to display.
    pub messages: Vec<DisplayMessage>,
    /// Current user input.
    pub input: String,
    /// Cursor position in the input.
    pub cursor: usize,
    /// Whether the agent is processing.
    pub loading: bool,
    /// Current streaming text (not yet committed to messages).
    pub streaming_text: String,
    /// Active tool calls being displayed.
    pub active_tool: Option<ActiveTool>,
    /// Pending approval request.
    pub pending_approval: Option<ApprovalRequest>,
    /// Token usage info.
    pub token_usage: Option<TokenUsageInfo>,
    /// Whether the app should exit.
    pub should_exit: bool,
    /// Scroll offset for the message list.
    pub scroll_offset: u16,
}

#[derive(Debug, Clone)]
pub struct DisplayMessage {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Clone)]
pub struct ActiveTool {
    pub name: String,
    pub status: ToolStatus,
}

#[derive(Debug, Clone)]
pub enum ToolStatus {
    Running,
    Complete(String), // result preview
}

#[derive(Debug, Clone)]
pub struct ApprovalRequest {
    pub tool_name: String,
    pub args_preview: String,
    pub response: Arc<Mutex<Option<bool>>>,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            messages: Vec::new(),
            input: String::new(),
            cursor: 0,
            loading: false,
            streaming_text: String::new(),
            active_tool: None,
            pending_approval: None,
            token_usage: None,
            should_exit: false,
            scroll_offset: 0,
        }
    }
}
```

All UI state is in one struct. This is the immediate-mode way — no distributed state, no reducers, no context providers. The render function reads `AppState`; event handlers mutate it.

### The `ApprovalRequest` Dance

```rust
pub struct ApprovalRequest {
    pub tool_name: String,
    pub args_preview: String,
    pub response: Arc<Mutex<Option<bool>>>,
}
```

The approval flow is the trickiest part:

1. The agent loop (running on a background thread) needs approval
2. It creates an `ApprovalRequest` and writes it to shared state
3. The UI thread sees the request and renders the approval prompt
4. The user presses Y or N
5. The UI thread writes `true` or `false` to `response`
6. The agent loop reads the response and continues

`Arc<Mutex<Option<bool>>>` is the shared communication channel:
- `Arc` — Both threads hold a reference
- `Mutex` — Mutual exclusion for reads and writes
- `Option<bool>` — `None` means "waiting", `Some(true/false)` means "answered"

## Layout

Create `src/ui/layout.rs`:

```rust
use ratatui::layout::{Constraint, Direction, Layout, Rect};

/// Split the terminal into areas.
pub fn create_layout(area: Rect) -> (Rect, Rect, Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(5),        // Message area (flexible)
            Constraint::Length(3),      // Input area (fixed)
            Constraint::Length(1),      // Status bar (fixed)
        ])
        .split(area);

    (chunks[0], chunks[1], chunks[2])
}
```

Three regions: messages fill available space, input is 3 lines (1 for border top, 1 for text, 1 for border bottom), and a status bar for token usage.

## Message List Widget

Create `src/ui/message_list.rs`:

```rust
use ratatui::{
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
    widgets::{Block, Borders, Paragraph, Wrap},
    Frame,
    layout::Rect,
};

use super::app::{AppState, ToolStatus};

pub fn render_messages(frame: &mut Frame, area: Rect, state: &AppState) {
    let mut lines: Vec<Line> = Vec::new();

    // Render committed messages
    for msg in &state.messages {
        let (label, color) = match msg.role.as_str() {
            "user" => ("You", Color::Blue),
            "assistant" => ("Assistant", Color::Green),
            _ => ("System", Color::Gray),
        };

        lines.push(Line::from(vec![
            Span::styled(
                format!("› {label}"),
                Style::default().fg(color).add_modifier(Modifier::BOLD),
            ),
        ]));

        for content_line in msg.content.lines() {
            lines.push(Line::from(format!("  {content_line}")));
        }

        lines.push(Line::from("")); // spacing
    }

    // Render streaming text
    if !state.streaming_text.is_empty() {
        lines.push(Line::from(vec![
            Span::styled(
                "› Assistant",
                Style::default()
                    .fg(Color::Green)
                    .add_modifier(Modifier::BOLD),
            ),
        ]));

        for content_line in state.streaming_text.lines() {
            lines.push(Line::from(format!("  {content_line}")));
        }
    }

    // Render active tool
    if let Some(ref tool) = state.active_tool {
        let status_text = match &tool.status {
            ToolStatus::Running => "...".to_string(),
            ToolStatus::Complete(result) => {
                let preview = &result[..result.len().min(80)];
                format!("✓ {preview}")
            }
        };

        lines.push(Line::from(vec![
            Span::styled("  ⚡ ", Style::default().fg(Color::Yellow)),
            Span::styled(
                &tool.name,
                Style::default()
                    .fg(Color::Yellow)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(format!(" {status_text}")),
        ]));
    }

    // Render approval prompt
    if let Some(ref approval) = state.pending_approval {
        lines.push(Line::from(""));
        lines.push(Line::from(vec![
            Span::styled(
                "  ⚠ Approval Required: ",
                Style::default()
                    .fg(Color::Yellow)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                &approval.tool_name,
                Style::default().fg(Color::Cyan),
            ),
        ]));
        lines.push(Line::from(format!("    {}", approval.args_preview)));
        lines.push(Line::from(vec![
            Span::styled(
                "    [Y]es / [N]o",
                Style::default().fg(Color::Yellow),
            ),
        ]));
    }

    // Loading indicator
    if state.loading && state.streaming_text.is_empty() && state.active_tool.is_none() {
        lines.push(Line::from(vec![
            Span::styled("  Thinking...", Style::default().fg(Color::Gray)),
        ]));
    }

    let paragraph = Paragraph::new(Text::from(lines))
        .block(Block::default().borders(Borders::ALL).title(" Chat "))
        .wrap(Wrap { trim: false })
        .scroll((state.scroll_offset, 0));

    frame.render_widget(paragraph, area);
}
```

This is a single function, not a component class. It reads `AppState`, builds a list of `Line`s, and renders a `Paragraph` widget. Every frame, this runs from scratch.

## Input Widget

Create `src/ui/input.rs`:

```rust
use ratatui::{
    style::{Color, Style},
    widgets::{Block, Borders, Paragraph},
    Frame,
    layout::Rect,
};

use super::app::AppState;

pub fn render_input(frame: &mut Frame, area: Rect, state: &AppState) {
    let input = Paragraph::new(state.input.as_str())
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(" Input (Enter to send, Ctrl+C to quit) ")
                .border_style(Style::default().fg(
                    if state.loading { Color::Gray } else { Color::Cyan }
                )),
        );

    frame.render_widget(input, area);

    // Position the cursor
    if !state.loading {
        frame.set_cursor_position((
            area.x + state.cursor as u16 + 1, // +1 for border
            area.y + 1,                         // +1 for border
        ));
    }
}
```

## Status Bar

Create `src/ui/token_usage.rs`:

```rust
use ratatui::{
    style::{Color, Style},
    text::{Line, Span},
    widgets::Paragraph,
    Frame,
    layout::Rect,
};

use super::app::AppState;

pub fn render_status_bar(frame: &mut Frame, area: Rect, state: &AppState) {
    let status = if let Some(ref usage) = state.token_usage {
        let color = if usage.percentage >= usage.threshold * 100.0 {
            Color::Red
        } else if usage.percentage >= usage.threshold * 75.0 {
            Color::Yellow
        } else {
            Color::Green
        };

        Line::from(vec![
            Span::raw(" Tokens: "),
            Span::styled(
                format!("{:.1}%", usage.percentage),
                Style::default().fg(color),
            ),
            Span::styled(
                format!(" ({}/{})", usage.used, usage.limit),
                Style::default().fg(Color::Gray),
            ),
        ])
    } else {
        Line::from(Span::styled(" Ready", Style::default().fg(Color::Green)))
    };

    frame.render_widget(Paragraph::new(status), area);
}
```

## The Event Loop

Create `src/ui/event_loop.rs`:

```rust
use std::io;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::Result;
use crossterm::{
    event::{self, Event, KeyCode, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{backend::CrosstermBackend, Terminal};

use super::app::AppState;
use super::layout::create_layout;
use super::message_list::render_messages;
use super::input::render_input;
use super::token_usage::render_status_bar;

pub fn run_ui(state: Arc<Mutex<AppState>>) -> Result<()> {
    // Setup terminal
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    loop {
        // Draw
        {
            let state = state.lock().unwrap();
            terminal.draw(|frame| {
                let (msg_area, input_area, status_area) =
                    create_layout(frame.area());

                render_messages(frame, msg_area, &state);
                render_input(frame, input_area, &state);
                render_status_bar(frame, status_area, &state);
            })?;

            if state.should_exit {
                break;
            }
        }

        // Handle input
        if event::poll(Duration::from_millis(50))? {
            if let Event::Key(key) = event::read()? {
                let mut state = state.lock().unwrap();
                handle_key(&mut state, key);
            }
        }
    }

    // Restore terminal
    disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        LeaveAlternateScreen
    )?;

    Ok(())
}

fn handle_key(state: &mut AppState, key: event::KeyEvent) {
    // Handle approval prompts first
    if state.pending_approval.is_some() {
        match key.code {
            KeyCode::Char('y') | KeyCode::Char('Y') | KeyCode::Enter => {
                if let Some(ref approval) = state.pending_approval {
                    *approval.response.lock().unwrap() = Some(true);
                }
                state.pending_approval = None;
            }
            KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc => {
                if let Some(ref approval) = state.pending_approval {
                    *approval.response.lock().unwrap() = Some(false);
                }
                state.pending_approval = None;
            }
            _ => {}
        }
        return;
    }

    // Normal input handling
    match key.code {
        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            state.should_exit = true;
        }
        KeyCode::Char(c) if !state.loading => {
            state.input.insert(state.cursor, c);
            state.cursor += 1;
        }
        KeyCode::Backspace if !state.loading && state.cursor > 0 => {
            state.cursor -= 1;
            state.input.remove(state.cursor);
        }
        KeyCode::Left if state.cursor > 0 => {
            state.cursor -= 1;
        }
        KeyCode::Right if state.cursor < state.input.len() => {
            state.cursor += 1;
        }
        KeyCode::Enter if !state.loading && !state.input.is_empty() => {
            // Submit the input — handled by the main loop
            let text = state.input.clone();
            state.messages.push(super::app::DisplayMessage {
                role: "user".into(),
                content: text,
            });
            state.input.clear();
            state.cursor = 0;
            state.loading = true;
        }
        KeyCode::Up => {
            state.scroll_offset = state.scroll_offset.saturating_add(1);
        }
        KeyCode::Down => {
            state.scroll_offset = state.scroll_offset.saturating_sub(1);
        }
        _ => {}
    }
}
```

### Raw Mode and Alternate Screen

```rust
enable_raw_mode()?;
execute!(stdout, EnterAlternateScreen)?;
```

**Raw mode** — Disables line buffering and echo. Keypresses are delivered immediately, not after Enter. Required for real-time input handling.

**Alternate screen** — Switches to a separate terminal buffer. When the app exits, the original terminal content is restored. Without this, the UI would overwrite your shell history.

### The 50ms Poll

```rust
if event::poll(Duration::from_millis(50))? {
```

We poll for events every 50ms (20 FPS). This is the render rate — fast enough for smooth UI, slow enough to not waste CPU. Between polls, the draw phase runs, which reads the latest state including streaming updates from the agent thread.

## Bridging Async Agent and Sync UI

The agent loop is async (it uses `tokio`). The UI loop is synchronous (ratatui's draw loop). We bridge them with shared state and a dedicated thread.

Create `src/ui/bridge.rs`:

```rust
use std::sync::{Arc, Mutex};
use anyhow::Result;
use serde_json::Value;

use crate::agent::run::{run_agent, AgentCallbacks};
use crate::agent::tool_registry::ToolRegistry;
use crate::api::client::OpenAIClient;
use crate::api::types::ToolDefinition;

use super::app::{ActiveTool, ApprovalRequest, AppState, DisplayMessage, ToolStatus};

/// Run the agent on a background tokio task, updating shared state.
pub async fn run_agent_with_ui(
    input: String,
    history: Vec<crate::api::types::Message>,
    client: &OpenAIClient,
    registry: &ToolRegistry,
    tools: &[ToolDefinition],
    state: Arc<Mutex<AppState>>,
) -> Result<Vec<crate::api::types::Message>> {
    let state_token = Arc::clone(&state);
    let state_tool_start = Arc::clone(&state);
    let state_tool_end = Arc::clone(&state);
    let state_complete = Arc::clone(&state);
    let state_usage = Arc::clone(&state);

    let mut callbacks = AgentCallbacks {
        on_token: Box::new(move |token| {
            let mut s = state_token.lock().unwrap();
            s.streaming_text.push_str(token);
        }),
        on_tool_call_start: Box::new(move |name, args| {
            let mut s = state_tool_start.lock().unwrap();
            s.active_tool = Some(ActiveTool {
                name: name.to_string(),
                status: ToolStatus::Running,
            });
        }),
        on_tool_call_end: Box::new(move |name, result| {
            let mut s = state_tool_end.lock().unwrap();
            s.active_tool = Some(ActiveTool {
                name: name.to_string(),
                status: ToolStatus::Complete(result.to_string()),
            });
        }),
        on_complete: Box::new(move |text| {
            let mut s = state_complete.lock().unwrap();
            if !s.streaming_text.is_empty() {
                s.messages.push(DisplayMessage {
                    role: "assistant".into(),
                    content: s.streaming_text.clone(),
                });
                s.streaming_text.clear();
            }
            s.active_tool = None;
            s.loading = false;
        }),
        on_token_usage: Box::new(move |usage| {
            let mut s = state_usage.lock().unwrap();
            s.token_usage = Some(usage);
        }),
    };

    run_agent(
        &input,
        history,
        client,
        registry,
        tools,
        &mut callbacks,
    )
    .await
}
```

Each callback clones an `Arc` to the shared state, locks the `Mutex`, and mutates. The UI thread reads the same state every 50ms. The result is a reactive-feeling UI powered by shared mutable state and polling — the exact opposite of React's declarative model, but it works.

## HITL Approval Integration

To integrate human-in-the-loop approval, we need to modify the agent loop to check `requires_approval` before executing a tool. Update the tool execution section of `src/agent/run.rs`:

```rust
// Add to AgentCallbacks:
pub on_tool_approval: Box<dyn FnMut(&str, &Value) -> bool>,

// In the tool execution section of the agent loop:
for pt in &pending_tools {
    let args: Value = serde_json::from_str(&pt.arguments)
        .unwrap_or(Value::Null);

    // Check if approval is needed
    if registry.requires_approval(&pt.name) {
        let approved = (callbacks.on_tool_approval)(&pt.name, &args);
        if !approved {
            // User rejected — stop the loop
            messages.push(Message::tool_result(
                &pt.id,
                "Tool execution was rejected by the user.",
            ));
            return Ok(messages);
        }
    }

    (callbacks.on_tool_call_start)(&pt.name, &args);
    let result = registry.execute(&pt.name, args)?;
    (callbacks.on_tool_call_end)(&pt.name, &result);

    messages.push(Message::tool_result(&pt.id, &result));
}
```

The approval callback in the UI bridge would create an `ApprovalRequest`, write it to shared state, then busy-wait for the response:

```rust
// In the bridge, the approval callback:
let state_approval = Arc::clone(&state);

on_tool_approval: Box::new(move |name, args| {
    let response = Arc::new(Mutex::new(None));
    let response_clone = Arc::clone(&response);

    {
        let mut s = state_approval.lock().unwrap();
        s.pending_approval = Some(ApprovalRequest {
            tool_name: name.to_string(),
            args_preview: serde_json::to_string_pretty(args)
                .unwrap_or_default(),
            response: response_clone,
        });
    }

    // Wait for user response
    loop {
        std::thread::sleep(std::time::Duration::from_millis(50));
        if let Some(answer) = *response.lock().unwrap() {
            return answer;
        }
    }
}),
```

This is a spin-wait — not elegant, but simple. The agent thread sleeps 50ms, checks if the user responded, repeats. The UI thread renders the approval prompt and writes the response when the user presses Y or N.

## The Main Entry Point

Update `src/main.rs`:

```rust
mod api;
mod agent;
mod context;
mod eval;
mod tools;
mod ui;

use std::sync::{Arc, Mutex};
use std::thread;
use anyhow::Result;

use api::client::OpenAIClient;
use agent::tool_registry::ToolRegistry;
use tools::file::{ReadFileTool, ListFilesTool, WriteFileTool, DeleteFileTool};
use tools::shell::{RunCommandTool, CodeExecutionTool};
use tools::web_search::WebSearchTool;
use ui::app::AppState;

#[tokio::main]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();

    let api_key = std::env::var("OPENAI_API_KEY")
        .expect("OPENAI_API_KEY must be set");

    let client = OpenAIClient::new(api_key);

    let mut registry = ToolRegistry::new();
    registry.register(Box::new(ReadFileTool));
    registry.register(Box::new(ListFilesTool));
    registry.register(Box::new(WriteFileTool));
    registry.register(Box::new(DeleteFileTool));
    registry.register(Box::new(RunCommandTool));
    registry.register(Box::new(CodeExecutionTool));
    registry.register(Box::new(WebSearchTool));

    let definitions = registry.definitions();

    // Shared state between UI and agent
    let state = Arc::new(Mutex::new(AppState::new()));

    // Run the UI on the main thread
    let ui_state = Arc::clone(&state);
    ui::event_loop::run_ui(ui_state)?;

    Ok(())
}
```

## Module Structure

Create `src/ui/mod.rs`:

```rust
pub mod app;
pub mod bridge;
pub mod event_loop;
pub mod input;
pub mod layout;
pub mod message_list;
pub mod token_usage;
```

## Summary

In this chapter you:

- Built an immediate-mode terminal UI with ratatui and crossterm
- Managed all UI state in a single `AppState` struct
- Rendered messages, streaming text, tool calls, and approval prompts
- Handled keyboard input with raw mode and event polling
- Bridged async agent execution with synchronous UI rendering via `Arc<Mutex<_>>`
- Implemented human-in-the-loop approval with shared state and spin-waiting

The architecture — shared state + polling + background task — is the standard pattern for combining ratatui with async work. It's more manual than React, but the control is absolute.

---

**Next: [Chapter 10: Going to Production →](./10-going-to-production.md)**
