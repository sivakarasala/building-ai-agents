# Chapter 4: The Agent Loop — SSE Streaming

## What Streaming Buys You

So far our calls have been blocking: send a request, wait for the entire response, print it. That works, but it feels dead. Real agents stream tokens as they're generated — text appears word-by-word, tool calls surface the instant the model commits to them, and long responses don't make the user stare at a blank screen.

OpenAI streams responses using **Server-Sent Events (SSE)**. It's a simple protocol on top of HTTP: the server keeps the connection open and writes lines like `data: {...}\n\n` for each chunk. We parse those lines using `HttpResponse.BodyHandlers.ofLines()`, which gives us a `Stream<String>` of lines we can iterate.

This chapter has two halves:

1. **Stream parsing** — Turn an HTTP response into a sequence of typed chunks.
2. **The agent loop** — Read chunks, accumulate tool call arguments, execute tools, feed results back, repeat.

## The SSE Wire Format

Here's what a streamed response looks like on the wire:

```
data: {"choices":[{"delta":{"role":"assistant","content":""}}]}

data: {"choices":[{"delta":{"content":"An"}}]}

data: {"choices":[{"delta":{"content":" AI"}}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

Three rules:

- Each event line starts with `data: ` followed by JSON.
- Events are separated by blank lines.
- The stream ends with the literal sentinel `data: [DONE]`.

Tool calls arrive the same way, but they're **fragmented**. The model streams the function name first, then the arguments JSON one chunk at a time:

```
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":""}}]}}]}
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"pa"}}]}}]}
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"x\"}"}}]}}]}
```

We need to **accumulate** those argument fragments by `index` until the stream finishes.

## Stream Records

Add to `api/Messages.java` (or create `api/Stream.java`):

```java
package com.example.agents.api;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

@JsonInclude(JsonInclude.Include.NON_NULL)
public final class Stream {
    private Stream() {}

    public record StreamChunk(
            String id,
            List<StreamChoice> choices
    ) {}

    public record StreamChoice(
            int index,
            Delta delta,
            @JsonProperty("finish_reason") String finishReason
    ) {}

    public record Delta(
            String role,
            String content,
            @JsonProperty("tool_calls") List<StreamToolCall> toolCalls
    ) {}

    public record StreamToolCall(
            int index,
            String id,
            String type,
            StreamFunction function
    ) {}

    public record StreamFunction(
            String name,
            String arguments
    ) {}
}
```

These mirror the non-streaming records but everything is nullable — any field can be missing on any chunk. Since records can't have nullable annotations cleanly, we just rely on Jackson leaving fields as `null` when absent.

## The Streaming Client

Add a streaming method to `OpenAiClient.java`:

```java
import com.example.agents.api.Stream.StreamChunk;
import java.io.IOException;
import java.net.http.HttpResponse.BodyHandlers;
import java.util.function.Consumer;

public void chatCompletionStream(ChatCompletionRequest req, Consumer<StreamChunk> onChunk) throws Exception {
    // Force streaming on.
    ChatCompletionRequest streamReq = new ChatCompletionRequest(
            req.model(), req.messages(), req.tools(), Boolean.TRUE);

    String body = mapper.writeValueAsString(streamReq);

    HttpRequest httpReq = HttpRequest.newBuilder()
            .uri(API_URL)
            .timeout(Duration.ofMinutes(5))
            .header("Authorization", "Bearer " + apiKey)
            .header("Content-Type", "application/json")
            .header("Accept", "text/event-stream")
            .POST(HttpRequest.BodyPublishers.ofString(body))
            .build();

    HttpResponse<java.util.stream.Stream<String>> resp =
            http.send(httpReq, BodyHandlers.ofLines());

    if (resp.statusCode() >= 400) {
        // Drain the lines into an error message before bailing.
        StringBuilder errBody = new StringBuilder();
        resp.body().forEach(line -> errBody.append(line).append('\n'));
        throw new IOException("OpenAI API error (" + resp.statusCode() + "): " + errBody);
    }

    try (var lines = resp.body()) {
        for (var iter = lines.iterator(); iter.hasNext();) {
            String line = iter.next();
            if (!line.startsWith("data: ")) continue;
            String payload = line.substring("data: ".length());
            if ("[DONE]".equals(payload)) break;

            StreamChunk chunk = mapper.readValue(payload, StreamChunk.class);
            onChunk.accept(chunk);
        }
    }
}
```

A few things worth pausing on:

- **`BodyHandlers.ofLines()`** — The JDK ships a body handler that exposes the response body as a `Stream<String>` of lines. No `BufferedReader` boilerplate.
- **Try-with-resources on the line stream** — Closes the underlying connection when we break out of the loop. Important for `[DONE]` and error cases.
- **`Consumer<StreamChunk>` callback** — Simpler than a `Flow.Subscriber` for this use case. The agent loop will turn the callbacks into a queue when it needs to.
- **No retries** — Streaming + retries is a rabbit hole. Crash loud, fix the bug.

## The Tool Call Accumulator

Tool call fragments need to be glued together. Create `agent/ToolCallAccumulator.java`:

```java
package com.example.agents.agent;

import com.example.agents.api.Messages.FunctionCall;
import com.example.agents.api.Messages.ToolCall;
import com.example.agents.api.Stream.StreamToolCall;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class ToolCallAccumulator {
    private final Map<Integer, Builder> byIndex = new LinkedHashMap<>();

    public void add(StreamToolCall delta) {
        Builder b = byIndex.computeIfAbsent(delta.index(), i -> new Builder());
        if (delta.id() != null) b.id = delta.id();
        if (delta.type() != null) b.type = delta.type();
        if (delta.function() != null) {
            if (delta.function().name() != null) {
                b.name.append(delta.function().name());
            }
            if (delta.function().arguments() != null) {
                b.arguments.append(delta.function().arguments());
            }
        }
    }

    public List<ToolCall> toolCalls() {
        List<ToolCall> out = new ArrayList<>(byIndex.size());
        for (Builder b : byIndex.values()) {
            out.add(new ToolCall(
                    b.id,
                    b.type == null ? "function" : b.type,
                    new FunctionCall(b.name.toString(), b.arguments.toString())
            ));
        }
        return out;
    }

    public boolean isEmpty() {
        return byIndex.isEmpty();
    }

    private static final class Builder {
        String id;
        String type;
        StringBuilder name = new StringBuilder();
        StringBuilder arguments = new StringBuilder();
    }
}
```

Two design choices:

- **`LinkedHashMap`** — Preserves first-seen order so deterministic output is free.
- **`StringBuilder` for arguments** — The fragments are JSON characters, not JSON values. We don't try to parse them until the stream is complete.

## Events From the Loop

The agent loop needs to surface multiple kinds of events to the caller: text deltas, completed tool calls, tool results, errors, and "we're done." A sealed type is the cleanest way:

Create `agent/Events.java`:

```java
package com.example.agents.agent;

import com.example.agents.api.Messages.ToolCall;

public sealed interface Events {
    record TextDelta(String text) implements Events {}
    record ToolCallEvent(ToolCall call) implements Events {}
    record ToolResult(ToolCall call, String result) implements Events {}
    record Done() implements Events {}
    record ErrorEvent(Exception error) implements Events {}
}
```

Sealed records give us exhaustive switching: in the UI we'll write `switch (event) { case TextDelta t -> ...; case ToolCallEvent c -> ...; ... }` and the compiler will tell us when we forget one.

## The Agent Loop

Create `agent/Agent.java`:

```java
package com.example.agents.agent;

import com.example.agents.api.Messages.ChatCompletionRequest;
import com.example.agents.api.Messages.Message;
import com.example.agents.api.Messages.ToolCall;
import com.example.agents.api.OpenAiClient;
import com.example.agents.api.Stream.Delta;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.function.Predicate;

public final class Agent {
    private final OpenAiClient client;
    private final Registry registry;
    private final String model;

    public Agent(OpenAiClient client, Registry registry) {
        this(client, registry, "gpt-4.1-mini");
    }

    public Agent(OpenAiClient client, Registry registry, String model) {
        this.client = client;
        this.registry = registry;
        this.model = model;
    }

    /**
     * Run the agent loop on a virtual thread and return a queue of events.
     * The queue is closed (via a Done or ErrorEvent) when the loop terminates.
     */
    public BlockingQueue<Events> run(List<Message> messages) {
        return run(messages, call -> true);
    }

    /**
     * Like run, but consults askApproval before executing any tool whose
     * requiresApproval() returns true.
     */
    public BlockingQueue<Events> run(List<Message> messages, Predicate<ToolCall> askApproval) {
        BlockingQueue<Events> events = new LinkedBlockingQueue<>();

        Thread.ofVirtual().name("agent-loop").start(() -> {
            try {
                List<Message> history = new ArrayList<>(messages);

                while (true) {
                    ChatCompletionRequest req = new ChatCompletionRequest(
                            model, history, registry.definitions(), null);

                    StringBuilder content = new StringBuilder();
                    ToolCallAccumulator acc = new ToolCallAccumulator();

                    client.chatCompletionStream(req, chunk -> {
                        if (chunk.choices() == null || chunk.choices().isEmpty()) return;
                        Delta delta = chunk.choices().get(0).delta();
                        if (delta == null) return;

                        if (delta.content() != null && !delta.content().isEmpty()) {
                            content.append(delta.content());
                            events.add(new Events.TextDelta(delta.content()));
                        }
                        if (delta.toolCalls() != null) {
                            for (var tc : delta.toolCalls()) {
                                acc.add(tc);
                            }
                        }
                    });

                    List<ToolCall> toolCalls = acc.toolCalls();

                    history.add(new Message(
                            "assistant",
                            content.toString(),
                            toolCalls.isEmpty() ? null : toolCalls,
                            null
                    ));

                    if (toolCalls.isEmpty()) {
                        events.add(new Events.Done());
                        return;
                    }

                    for (ToolCall tc : toolCalls) {
                        events.add(new Events.ToolCallEvent(tc));

                        String result;
                        if (registry.requiresApproval(tc.function().name()) && !askApproval.test(tc)) {
                            result = "User denied this tool call.";
                        } else {
                            try {
                                result = registry.execute(tc.function().name(), tc.function().arguments());
                            } catch (Exception e) {
                                result = "Error: " + e.getMessage();
                            }
                        }

                        events.add(new Events.ToolResult(tc, result));
                        history.add(Message.tool(tc.id(), result));
                    }
                    // Loop again — feed tool results back to the model.
                }
            } catch (Exception e) {
                events.add(new Events.ErrorEvent(e));
            }
        });

        return events;
    }
}
```

The shape is the standard agent loop:

1. Send the conversation to the model.
2. Stream the response, accumulating text and tool calls.
3. Append the assistant message to history.
4. If there are no tool calls, emit `Done` and exit.
5. Otherwise, execute each tool call (asking for approval if needed), append results, and loop.

### Virtual Threads

`Thread.ofVirtual().start(...)` is the headline Java 21 feature. The agent runs on a *virtual* thread — a lightweight thread scheduled on top of a small pool of carrier OS threads. Blocking calls inside (`HttpClient.send`, queue puts) park the virtual thread, freeing its carrier for other work. We get the simplicity of "just write blocking code" without paying for a thousand OS threads.

For our agent loop, this means we can use a plain `BlockingQueue` to talk to the UI thread, write straight-line code with a `while (true)`, and not worry about colored functions or `CompletableFuture` chains.

### Why a Queue?

We could have used callbacks or `Flow.Subscriber`, but a `BlockingQueue` composes better:

- The terminal UI in Chapter 9 is a single thread that pulls events on its own schedule.
- Tests can `drainTo` a list and assert on the sequence.
- Cancellation is just "stop reading the queue and let the producer be GC'd."

`Done` and `ErrorEvent` act as terminal markers. The consumer reads until it sees one of them.

## Wiring It Up

Replace `Main.java` with a streaming version:

```java
package com.example.agents;

import com.example.agents.agent.Agent;
import com.example.agents.agent.Events;
import com.example.agents.agent.Prompts;
import com.example.agents.agent.Registry;
import com.example.agents.api.Messages.Message;
import com.example.agents.api.OpenAiClient;
import com.example.agents.tools.ListFiles;
import com.example.agents.tools.ReadFile;
import io.github.cdimascio.dotenv.Dotenv;

import java.util.List;
import java.util.concurrent.BlockingQueue;

public class Main {
    public static void main(String[] args) throws Exception {
        Dotenv env = Dotenv.configure().ignoreIfMissing().load();
        String apiKey = env.get("OPENAI_API_KEY", System.getenv("OPENAI_API_KEY"));
        if (apiKey == null || apiKey.isBlank()) {
            System.err.println("OPENAI_API_KEY must be set");
            System.exit(1);
        }

        OpenAiClient client = new OpenAiClient(apiKey);
        Registry registry = new Registry();
        registry.register(new ReadFile(client.mapper()));
        registry.register(new ListFiles(client.mapper()));

        Agent agent = new Agent(client, registry);

        List<Message> messages = List.of(
                Message.system(Prompts.SYSTEM),
                Message.user("List the files in the current directory, then read build.gradle.kts and tell me what plugins are applied.")
        );

        BlockingQueue<Events> events = agent.run(messages);

        while (true) {
            Events ev = events.take();
            switch (ev) {
                case Events.TextDelta t -> System.out.print(t.text());
                case Events.ToolCallEvent c -> System.out.printf(
                        "%n[tool] %s(%s)%n", c.call().function().name(), c.call().function().arguments());
                case Events.ToolResult r -> {
                    String preview = r.result();
                    if (preview.length() > 120) preview = preview.substring(0, 120) + "...";
                    System.out.println("[result] " + preview);
                }
                case Events.Done d -> { System.out.println(); return; }
                case Events.ErrorEvent e -> {
                    System.err.println("agent error: " + e.error().getMessage());
                    return;
                }
            }
        }
    }
}
```

The `switch` is **exhaustive** thanks to the sealed `Events` interface — if you add a new event kind, the compiler forces you to handle it here. That's a quiet but enormous improvement over the C-style enum-and-switch pattern.

Run it:

```bash
./gradlew run
```

You should see something like:

```
[tool] list_files({"directory":"."})
[result] [dir] build
[file] build.gradle.kts
[file] settings.gradle.kts
[dir] src...
[tool] read_file({"path":"build.gradle.kts"})
[result] plugins {
    application
    id("com.github.johnrengelman.shadow") version "8.1.1"
}...
The build applies the application plugin and the Shadow plugin (8.1.1).
```

The model called `list_files`, saw the result, decided it needed `read_file`, called that, saw *its* result, and finally emitted plain text. Two model turns, two tool executions, all wired through one queue.

## Summary

In this chapter you:

- Parsed Server-Sent Events with `HttpResponse.BodyHandlers.ofLines()`
- Modeled streamed deltas as records
- Built a tool call accumulator that merges fragmented arguments by index
- Designed the loop's output as a sealed `Events` interface
- Ran the loop on a virtual thread and bridged it to the caller via `BlockingQueue`
- Used pattern matching on the sealed event type for an exhaustive consumer

Next, we'll write evals that grade *full conversations* — not just whether the first tool call is right, but whether the agent eventually arrives at the correct answer.

---

**Next: [Chapter 5: Multi-Turn Evaluations →](./05-multi-turn-evals.md)**
