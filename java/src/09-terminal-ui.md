# Chapter 9: Terminal UI with Lanterna

## From `System.out.println` to a Real UI

Up to now we've been printing to stdout. That works for one-shot prompts but falls apart the moment you want:

- A persistent input box at the bottom
- Streaming text that doesn't fight scrollback
- An approval prompt that pauses the agent while the user thinks
- Colors, spacing, and structure that don't look like a CI log

[Lanterna](https://github.com/mabe02/lanterna) is a pure-Java library for building terminal UIs. It speaks ANSI escape codes (and falls back to `Console` on Windows), gives you a screen abstraction with cells and styles, and ships a small widget library on top. We'll use the low-level screen API directly — for a teaching project, it's easier to read than the widget tree.

## What We're Building

A simple split screen:

- The top region scrolls a transcript of the conversation: user prompts, streamed assistant text, tool calls, tool results, errors.
- The bottom region is an input box and, when the agent is asking for approval, an inline `[y/n]` banner.

Three threads cooperate:

- **The agent thread** — A virtual thread running `Agent.run`. Pushes events into a `BlockingQueue`.
- **The UI input thread** — A platform thread that blocks on `screen.readInput()` for keystrokes.
- **The render thread** — A platform thread that pulls events and keystrokes from a single `BlockingQueue<UiEvent>` and updates the model.

This is the same pattern as Chapter 4, just with a UI on top.

## A Single Event Type

To keep the rendering loop simple, we wrap both agent events and UI events in one sealed type. Create `ui/UiEvent.java`:

```java
package com.example.agents.ui;

import com.example.agents.agent.Events;
import com.example.agents.agent.ToolCall;
import com.googlecode.lanterna.input.KeyStroke;

public sealed interface UiEvent {
    record Agent(Events event) implements UiEvent {}
    record Key(KeyStroke stroke) implements UiEvent {}
    record ApprovalRequest(ToolCall call,
                           java.util.concurrent.CompletableFuture<Boolean> response) implements UiEvent {}
}
```

The render loop will pull `UiEvent`s out of one queue. Two background threads push into it.

## The Transcript Model

The on-screen transcript is just a list of styled lines. Create `ui/Transcript.java`:

```java
package com.example.agents.ui;

import java.util.ArrayList;
import java.util.List;

public final class Transcript {
    public enum Kind { USER, ASSISTANT, TOOL_CALL, TOOL_RESULT, ERROR }

    public record Line(Kind kind, String text) {}

    private final List<Line> lines = new ArrayList<>();
    private final StringBuilder streaming = new StringBuilder();

    public List<Line> lines() { return lines; }

    public void addUser(String text)        { lines.add(new Line(Kind.USER, text)); }
    public void addToolCall(String text)    { flushStreaming(); lines.add(new Line(Kind.TOOL_CALL, text)); }
    public void addToolResult(String text)  { lines.add(new Line(Kind.TOOL_RESULT, text)); }
    public void addError(String text)       { flushStreaming(); lines.add(new Line(Kind.ERROR, text)); }

    public void appendStreaming(String text) {
        streaming.append(text);
    }

    public void flushStreaming() {
        if (streaming.length() == 0) return;
        lines.add(new Line(Kind.ASSISTANT, streaming.toString()));
        streaming.setLength(0);
    }

    public String currentStreaming() {
        return streaming.toString();
    }
}
```

We keep streaming text in a separate buffer and only "flush" it into the transcript when the model finishes its turn (or starts a tool call). That way the in-progress text can render with a different style or marker.

## The Terminal App

Create `ui/TerminalApp.java`. This is the longest file in the book — we'll walk through it in pieces.

```java
package com.example.agents.ui;

import com.example.agents.agent.Agent;
import com.example.agents.agent.Events;
import com.example.agents.agent.ToolCall;
import com.example.agents.api.Messages.InputItem;
import com.googlecode.lanterna.TerminalSize;
import com.googlecode.lanterna.TextCharacter;
import com.googlecode.lanterna.TextColor;
import com.googlecode.lanterna.input.KeyStroke;
import com.googlecode.lanterna.input.KeyType;
import com.googlecode.lanterna.screen.Screen;
import com.googlecode.lanterna.screen.TerminalScreen;
import com.googlecode.lanterna.terminal.DefaultTerminalFactory;
import com.googlecode.lanterna.terminal.Terminal;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.LinkedBlockingQueue;

public final class TerminalApp {
    private final Agent agent;
    private final Transcript transcript = new Transcript();
    private final List<InputItem> history = new ArrayList<>();
    private final BlockingQueue<UiEvent> uiQueue = new LinkedBlockingQueue<>();

    private StringBuilder input = new StringBuilder();
    private boolean busy = false;
    private UiEvent.ApprovalRequest pending;

    public TerminalApp(Agent agent) {
        this.agent = agent;
    }
```

The model fields:

- `transcript` — what we render at the top.
- `history` — the OpenAI message list we send to the API.
- `uiQueue` — the single queue that both agent events and keystrokes flow through.
- `input` — current input buffer.
- `busy` — true while the agent is working; we ignore input while busy.
- `pending` — set when the agent is blocked on approval.

Now the main loop. Lanterna's `Screen` is double-buffered: you draw into a back buffer and call `refresh()` to flip.

```java
    public void run() throws Exception {
        Terminal terminal = new DefaultTerminalFactory().createTerminal();
        try (Screen screen = new TerminalScreen(terminal)) {
            screen.startScreen();
            screen.clear();

            // Background thread: read keystrokes and feed them into the UI queue.
            Thread.ofPlatform().daemon().name("input-reader").start(() -> {
                try {
                    while (true) {
                        KeyStroke key = screen.readInput();
                        if (key == null) continue;
                        uiQueue.put(new UiEvent.Key(key));
                    }
                } catch (Exception ignored) {}
            });

            render(screen);

            while (true) {
                UiEvent ev = uiQueue.take();
                boolean quit = handle(ev);
                render(screen);
                if (quit) return;
            }
        }
    }
```

A few things to call out:

- **`Thread.ofPlatform().daemon()`** — Lanterna's `readInput()` is a blocking native call, not a friendly candidate for a virtual thread. A platform daemon thread is fine.
- **One main loop, no locks** — Every state mutation happens on the render thread. The agent thread only writes to `uiQueue`. That's the entire concurrency story.

## Handling Events

```java
    private boolean handle(UiEvent ev) {
        return switch (ev) {
            case UiEvent.Key k -> handleKey(k.stroke());
            case UiEvent.Agent a -> { handleAgentEvent(a.event()); yield false; }
            case UiEvent.ApprovalRequest r -> { pending = r; yield false; }
        };
    }

    private boolean handleKey(KeyStroke key) {
        // Approval prompt takes precedence over normal input.
        if (pending != null) {
            if (key.getCharacter() != null) {
                char c = key.getCharacter();
                if (c == 'y' || c == 'Y') {
                    pending.response().complete(true);
                    pending = null;
                } else if (c == 'n' || c == 'N') {
                    pending.response().complete(false);
                    pending = null;
                }
            } else if (key.getKeyType() == KeyType.Escape) {
                pending.response().complete(false);
                pending = null;
            }
            return false;
        }

        if (key.getKeyType() == KeyType.EOF) return true;
        if (key.getKeyType() == KeyType.Escape) return true;
        if (key.isCtrlDown() && key.getCharacter() != null && key.getCharacter() == 'c') return true;

        if (busy) return false;

        switch (key.getKeyType()) {
            case Enter -> submit();
            case Backspace -> { if (input.length() > 0) input.setLength(input.length() - 1); }
            case Character -> input.append(key.getCharacter());
            default -> {}
        }
        return false;
    }

    private void submit() {
        String text = input.toString().trim();
        if (text.isEmpty()) return;
        input.setLength(0);
        transcript.addUser(text);
        history.add(InputItem.user(text));
        busy = true;

        // Kick off the agent on a virtual thread, push its events into uiQueue.
        BlockingQueue<Events> events = agent.run(history, this::askApproval);
        Thread.ofVirtual().name("agent-pump").start(() -> {
            try {
                while (true) {
                    Events e = events.take();
                    uiQueue.put(new UiEvent.Agent(e));
                    if (e instanceof Events.Done || e instanceof Events.ErrorEvent) return;
                }
            } catch (InterruptedException ignored) {}
        });
    }

    private boolean askApproval(ToolCall call) {
        CompletableFuture<Boolean> resp = new CompletableFuture<>();
        try {
            uiQueue.put(new UiEvent.ApprovalRequest(call, resp));
            return resp.get();
        } catch (Exception e) {
            return false;
        }
    }

    private void handleAgentEvent(Events ev) {
        switch (ev) {
            case Events.TextDelta t -> transcript.appendStreaming(t.text());
            case Events.ToolCallEvent c -> transcript.addToolCall(
                    c.call().name() + "(" + c.call().arguments() + ")");
            case Events.ToolResult r -> {
                String preview = r.result();
                if (preview.length() > 200) preview = preview.substring(0, 200) + "...";
                transcript.addToolResult(preview);
            }
            case Events.Done d -> { transcript.flushStreaming(); busy = false; }
            case Events.ErrorEvent e -> {
                transcript.addError(e.error().getMessage());
                busy = false;
            }
        }
    }
```

The control flow worth re-reading:

1. User presses Enter → `submit()` queues the user message, kicks off the agent loop on a virtual thread, and starts a "pump" thread that copies agent events into the UI queue.
2. Agent events arrive as `UiEvent.Agent`. The render loop applies them to the transcript.
3. If the agent hits an approval-gated tool, `Agent.run` calls `askApproval`, which puts an `ApprovalRequest` on the UI queue and blocks on a `CompletableFuture`.
4. The render loop sees the request, sets `pending`, and the next render shows the prompt.
5. The user presses `y` or `n`. `handleKey` completes the future. The agent thread unblocks and the pump goes back to forwarding events.

One queue, one render thread, three producers. The discipline is that **only the render thread mutates state**.

## Rendering

```java
    private void render(Screen screen) throws Exception {
        screen.clear();
        TerminalSize size = screen.getTerminalSize();
        int width = size.getColumns();
        int height = size.getRows();

        int row = 0;
        int maxLines = height - 4;
        List<Transcript.Line> lines = transcript.lines();
        int start = Math.max(0, lines.size() - maxLines);
        for (int i = start; i < lines.size() && row < maxLines; i++) {
            Transcript.Line line = lines.get(i);
            row = drawLine(screen, row, width, line.kind(), line.text());
        }
        // Streaming buffer (current assistant turn in progress)
        String streaming = transcript.currentStreaming();
        if (!streaming.isEmpty() && row < maxLines) {
            row = drawLine(screen, row, width, Transcript.Kind.ASSISTANT, "> " + streaming);
        }

        if (pending != null) {
            String prompt = "Approve " + pending.call().name()
                    + "(" + pending.call().arguments() + ")? [y/N]";
            putString(screen, 0, height - 3, prompt, TextColor.ANSI.YELLOW);
        }

        // Input line at the bottom.
        String prompt = busy ? "[busy] " : "> ";
        putString(screen, 0, height - 1, prompt + input, TextColor.ANSI.DEFAULT);

        screen.setCursorPosition(new com.googlecode.lanterna.TerminalPosition(
                prompt.length() + input.length(), height - 1));
        screen.refresh();
    }

    private int drawLine(Screen screen, int row, int width, Transcript.Kind kind, String text) {
        TextColor color = switch (kind) {
            case USER         -> TextColor.ANSI.BLUE;
            case ASSISTANT    -> TextColor.ANSI.GREEN;
            case TOOL_CALL    -> TextColor.ANSI.MAGENTA;
            case TOOL_RESULT  -> TextColor.ANSI.WHITE;
            case ERROR        -> TextColor.ANSI.RED;
        };
        String prefix = switch (kind) {
            case USER         -> "you> ";
            case ASSISTANT    -> "> ";
            case TOOL_CALL    -> "[tool] ";
            case TOOL_RESULT  -> "[result] ";
            case ERROR        -> "[error] ";
        };
        putString(screen, 0, row, prefix + text, color);
        return row + 1;
    }

    private void putString(Screen screen, int col, int row, String text, TextColor color) {
        if (row < 0) return;
        for (int i = 0; i < text.length() && col + i < screen.getTerminalSize().getColumns(); i++) {
            screen.setCharacter(col + i, row,
                    TextCharacter.fromCharacter(text.charAt(i))[0].withForegroundColor(color));
        }
    }
}
```

This is naive — every keystroke redraws the entire screen. For a real app you'd track dirty regions or use Lanterna's `MultiWindowTextGUI`. For learning purposes, the naive version makes the data flow obvious.

## Wiring `Main.java`

Replace `Main.java` with the UI version:

```java
package com.example.agents;

import com.example.agents.agent.Agent;
import com.example.agents.agent.Registry;
import com.example.agents.api.OpenAiClient;
import com.example.agents.tools.*;
import com.example.agents.ui.TerminalApp;
import io.github.cdimascio.dotenv.Dotenv;

public class Main {
    public static void main(String[] args) throws Exception {
        Dotenv env = Dotenv.configure().ignoreIfMissing().load();
        String apiKey = env.get("OPENAI_API_KEY", System.getenv("OPENAI_API_KEY"));
        if (apiKey == null || apiKey.isBlank()) {
            System.err.println("OPENAI_API_KEY must be set");
            System.exit(1);
        }

        OpenAiClient client = new OpenAiClient(apiKey);
        var mapper = client.mapper();

        Registry registry = new Registry();
        registry.register(new ReadFile(mapper));
        registry.register(new ListFiles(mapper));
        registry.register(new WriteFile(mapper));
        registry.register(new EditFile(mapper));
        registry.register(new DeleteFile(mapper));
        registry.register(new WebSearch(mapper));
        registry.register(new Shell(mapper));
        registry.register(new RunCode(mapper));

        Agent agent = new Agent(client, registry);
        new TerminalApp(agent).run();
    }
}
```

Run it:

```bash
./gradlew run
```

You should see the input prompt at the bottom of the screen. Type a request, press Enter, watch the agent stream its way through tool calls. When it tries to write a file, the approval banner pops up and the loop pauses until you press `y` or `n`.

## The Concurrency Story, Reviewed

Three threads are running together:

1. **The render thread** — Owns the model. Single-threaded. Pulls from `uiQueue` and updates the screen.
2. **The input reader thread** — Blocks on `screen.readInput()`. Pushes keystrokes into `uiQueue`.
3. **The agent virtual thread (and a pump)** — Runs streaming and tool execution. Sends `Events` on its own queue, which a small pump thread forwards into `uiQueue`. Blocks on a `CompletableFuture` when it needs approval.

They communicate exclusively through queues and one `CompletableFuture`. No mutexes, no shared mutable state. Java 21's virtual threads make this almost free — we don't need to think about thread pools or executor sizing.

## Summary

In this chapter you:

- Used Lanterna's low-level `Screen` API to draw a styled transcript
- Modeled keystrokes, agent events, and approval requests as a single sealed `UiEvent`
- Drove the UI from a single render thread that consumes a single queue
- Wired the approval flow as a `CompletableFuture` the render thread completes when the user decides
- Built the whole thing on virtual threads + blocking queues, no callback hell

One chapter to go: hardening the agent for use by people who aren't you.

---

**Next: [Chapter 10: Going to Production →](./10-going-to-production.md)**
