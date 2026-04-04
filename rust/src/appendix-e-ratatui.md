# Appendix E: Ratatui & Immediate-Mode UI

**Read before Chapter 9** if you've never used an immediate-mode UI framework.

## What Is Immediate-Mode UI?

There are two paradigms for building UIs:

**Retained mode** (React, SwiftUI, Flutter): You declare a tree of components. The framework tracks state, diffs changes, and updates the screen. You say *what* the UI should look like, and the framework figures out *how* to update it.

**Immediate mode** (ratatui, Dear ImGui, egui): You redraw the entire screen every frame. There's no component tree, no virtual DOM, no diffing. You say "draw this text at these coordinates" 60 times per second. Your code *is* the render loop.

### The Mental Model

```
Retained mode (React):
  State changes → Framework diffs → Minimal DOM updates

Immediate mode (ratatui):
  State + render function → Full screen redraw every frame
  (ratatui internally diffs terminal cells, but YOU redraw everything)
```

## Ratatui Basics

### Terminal Setup

```rust
use std::io;
use crossterm::{
    execute,
    terminal::{enable_raw_mode, disable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{backend::CrosstermBackend, Terminal};

// Setup
enable_raw_mode()?;
let mut stdout = io::stdout();
execute!(stdout, EnterAlternateScreen)?;
let backend = CrosstermBackend::new(stdout);
let mut terminal = Terminal::new(backend)?;

// ... your app loop ...

// Teardown
disable_raw_mode()?;
execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
```

**Raw mode**: Keypresses are delivered immediately (no line buffering, no echo).
**Alternate screen**: A fresh terminal buffer; your original content is restored on exit.

### The Draw Loop

```rust
loop {
    terminal.draw(|frame| {
        // frame is a mutable reference to the terminal buffer
        // You render widgets onto it

        let area = frame.area();  // Full terminal size as Rect

        let paragraph = Paragraph::new("Hello, ratatui!");
        frame.render_widget(paragraph, area);
    })?;

    // Handle events
    if crossterm::event::poll(Duration::from_millis(50))? {
        if let Event::Key(key) = crossterm::event::read()? {
            if key.code == KeyCode::Char('q') {
                break;
            }
        }
    }
}
```

Every iteration:
1. **Draw** — Call `terminal.draw()` with a closure that renders widgets
2. **Poll** — Check for input events (non-blocking, with timeout)
3. **Handle** — Update state based on events

Ratatui internally double-buffers: it compares the new frame to the previous frame and only sends the changed terminal cells. So while *your code* redraws everything, the actual I/O is minimal.

## Widgets

### `Paragraph`

The most common widget — renders text:

```rust
use ratatui::widgets::{Paragraph, Block, Borders, Wrap};
use ratatui::text::{Line, Span};
use ratatui::style::{Style, Color, Modifier};

let lines = vec![
    Line::from(vec![
        Span::styled("Bold ", Style::default().add_modifier(Modifier::BOLD)),
        Span::raw("and normal"),
    ]),
    Line::from("Plain text"),
];

let paragraph = Paragraph::new(lines)
    .block(Block::default().borders(Borders::ALL).title(" Chat "))
    .wrap(Wrap { trim: false })
    .scroll((scroll_offset, 0));

frame.render_widget(paragraph, area);
```

### `Block`

A container with borders and title:

```rust
let block = Block::default()
    .borders(Borders::ALL)
    .title(" My Panel ")
    .border_style(Style::default().fg(Color::Cyan));
```

Blocks don't render content — they're wrappers. You pass them to other widgets via `.block()`.

### Text Styling

```rust
// Single styled span
Span::styled("Error", Style::default().fg(Color::Red).add_modifier(Modifier::BOLD))

// A line with mixed styles
Line::from(vec![
    Span::styled("› You", Style::default().fg(Color::Blue).add_modifier(Modifier::BOLD)),
    Span::raw(": Hello there"),
])

// Multiple lines
Text::from(vec![
    Line::from("First line"),
    Line::from("Second line"),
])
```

The hierarchy: `Span` → `Line` → `Text` → `Paragraph`

## Layout

Ratatui provides a constraint-based layout system:

```rust
use ratatui::layout::{Layout, Direction, Constraint, Rect};

let chunks = Layout::default()
    .direction(Direction::Vertical)
    .constraints([
        Constraint::Min(5),        // Messages: at least 5 lines, takes remaining space
        Constraint::Length(3),     // Input: exactly 3 lines
        Constraint::Length(1),     // Status: exactly 1 line
    ])
    .split(frame.area());

// chunks[0] = message area
// chunks[1] = input area
// chunks[2] = status bar
```

Constraint types:
- `Length(n)` — Exactly n cells
- `Min(n)` — At least n cells
- `Max(n)` — At most n cells
- `Percentage(n)` — n% of available space
- `Ratio(a, b)` — a/b of available space

## Handling Input

Crossterm provides keyboard events:

```rust
use crossterm::event::{self, Event, KeyCode, KeyModifiers};

if event::poll(Duration::from_millis(50))? {
    if let Event::Key(key) = event::read()? {
        match key.code {
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                // Ctrl+C — exit
                break;
            }
            KeyCode::Char(c) => {
                // Regular character
                input.push(c);
            }
            KeyCode::Backspace => {
                input.pop();
            }
            KeyCode::Enter => {
                // Submit
                submit(&input);
                input.clear();
            }
            KeyCode::Up => scroll_up(),
            KeyCode::Down => scroll_down(),
            _ => {}
        }
    }
}
```

The `poll` timeout controls your frame rate. 50ms = 20 FPS. Lower values give smoother animation but use more CPU.

## State Management

In React, you'd use `useState` or a state management library. In ratatui, it's just a struct:

```rust
struct AppState {
    messages: Vec<String>,
    input: String,
    cursor: usize,
    scroll: u16,
    loading: bool,
}

// In the draw loop:
terminal.draw(|frame| {
    render_messages(frame, &state.messages, state.scroll);
    render_input(frame, &state.input, state.cursor);
})?;

// In the event handler:
match key.code {
    KeyCode::Char(c) => {
        state.input.insert(state.cursor, c);
        state.cursor += 1;
    }
    // ...
}
```

There's no reactivity, no observers, no subscriptions. The draw loop reads the current state, the event handler mutates it, and the next draw loop reflects the changes. Simple.

### Shared State with Background Tasks

When you have a background async task (like our agent loop), you need shared state:

```rust
use std::sync::{Arc, Mutex};

let state = Arc::new(Mutex::new(AppState::new()));

// Background task writes to state
let bg_state = Arc::clone(&state);
tokio::spawn(async move {
    let result = expensive_work().await;
    bg_state.lock().unwrap().result = Some(result);
});

// UI loop reads from state
loop {
    let state = state.lock().unwrap();
    terminal.draw(|frame| {
        render(&state, frame);
    })?;
    drop(state);  // Release lock before polling
    // ... handle events ...
}
```

The `Arc<Mutex<T>>` pattern is the standard way to share mutable state between the UI thread and background tasks. The important rule: **don't hold the lock while polling** — release it before `event::poll` so the background task can update state.

## Cursor Positioning

For text input, you need to position the terminal cursor:

```rust
frame.set_cursor_position((
    input_area.x + cursor_position as u16 + 1,  // +1 for border
    input_area.y + 1,                              // +1 for border
));
```

Ratatui hides the cursor by default. `set_cursor_position` shows it at the specified coordinates. This is how we show a blinking cursor in the input field.

## Scrolling

Paragraphs support scrolling:

```rust
let paragraph = Paragraph::new(text)
    .scroll((vertical_offset, 0));  // (vertical, horizontal)
```

You manage the scroll offset in your state and update it on Up/Down key events:

```rust
KeyCode::Up => state.scroll = state.scroll.saturating_add(1),
KeyCode::Down => state.scroll = state.scroll.saturating_sub(1),
```

`saturating_add/sub` prevents underflow — `0u16.saturating_sub(1)` is `0`, not a panic.

## Comparison with React/Ink

| Concept | React/Ink | Ratatui |
|---------|-----------|---------|
| Rendering | Declarative components | Imperative draw calls |
| State | `useState`, `useReducer` | Mutable struct fields |
| Updates | Automatic re-render on state change | Manual redraw every frame |
| Layout | Flexbox (Ink uses Yoga) | Constraint-based `Layout` |
| Styling | JSX with style props | `Style` struct with `fg`/`bg`/modifiers |
| Events | `useInput` hook | `crossterm::event::read()` |
| Components | Functions returning JSX | Functions taking `(Frame, Rect, &State)` |

The biggest difference: in React, you think about *what* the UI should look like. In ratatui, you think about *how* to draw it. Both approaches work — ratatui just makes every step explicit.

## Summary

Ratatui is a low-level, high-control terminal UI library:

1. **Draw everything every frame** — No component lifecycle, no diffing logic
2. **Manage state manually** — A plain struct, mutated by event handlers
3. **Use constraints for layout** — `Length`, `Min`, `Percentage`
4. **Style with `Span` and `Style`** — Colors, bold, dim, etc.
5. **Share state with `Arc<Mutex<T>>`** — For background async tasks

It's more work than React/Ink, but the code is straightforward — no framework magic, no hidden re-renders, no stale closure bugs. What you write is what runs.
