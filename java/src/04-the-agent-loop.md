# Chapter 4: The Agent Loop — SSE Streaming

## What Streaming Buys You

So far our calls have been blocking: send a request, wait for the entire response, print it. That works, but it feels dead. Real agents stream tokens as they're generated — text appears word-by-word, tool calls surface the instant the model commits to them, and long responses don't make the user stare at a blank screen.

The Responses API streams using **Server-Sent Events (SSE)**. It's a simple protocol on top of HTTP: the server keeps the connection open and writes blocks of `event:` and `data:` lines. We parse those lines using `HttpResponse.BodyHandlers.ofLines()`, which gives us a `Stream<String>` we can iterate.

This chapter has two halves:

1. **Stream parsing** — Turn an HTTP response into a sequence of typed events.
2. **The agent loop** — Read events, execute tools as the model calls them, feed results back, repeat.

## The SSE Wire Format

Here's what a streamed Responses API call looks like on the wire:

```
event: response.created
data: {"type":"response.created","response":{"id":"resp_123",...}}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"An"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":" AI"}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_123","output":[...],"output_text":"An AI..."}}
```

Three rules:

- Each event is a block of lines terminated by a blank line.
- The block has an `event:` line giving the event type, and a `data:` line carrying a JSON payload.
- The terminal `response.completed` event carries the **entire** finished response — including a complete `output` array with any `function_call` items already fully assembled. We don't need to glue argument fragments back together.

That's the big simplification compared to Chat Completions: the API already does the accumulation for us. We just listen for text deltas to display in real time and wait for `response.completed` to learn what tools (if any) the model wants to call.

## Stream Records

Add a small holder for streaming events to `api/`. Create `api/Stream.java`:

```java
package com.example.agents.api;

import com.example.agents.api.Messages.ResponsesResponse;
import com.fasterxml.jackson.annotation.JsonInclude;

@JsonInclude(JsonInclude.Include.NON_NULL)
public final class Stream {
    private Stream() {}

    /**
     * One streaming event from the Responses API.
     *
     * <p>Only a few event types matter to us:
     * <ul>
     *   <li>{@code response.output_text.delta} — incremental text to display</li>
     *   <li>{@code response.completed} — terminal event carrying the full response</li>
     * </ul>
     * Other events (created, in_progress, output_item.added, ...) are ignored.
     */
    public record StreamEvent(
            String type,
            String delta,
            ResponsesResponse response
    ) {}
}
```

We model only what we use. Other event types (`response.created`, `response.output_item.added`, reasoning summaries, ...) are dropped on the floor without ceremony.

## The Streaming Client

Add a streaming method to `OpenAiClient.java`:

```java
import com.example.agents.api.Messages.ResponsesRequest;
import com.example.agents.api.Messages.ResponsesResponse;
import com.example.agents.api.Stream.StreamEvent;
import com.fasterxml.jackson.databind.JsonNode;

import java.io.IOException;
import java.net.http.HttpResponse.BodyHandlers;
import java.util.function.Consumer;

public void createResponseStream(ResponsesRequest req, Consumer<StreamEvent> onEvent) throws Exception {
    // Force streaming on.
    ResponsesRequest streamReq = new ResponsesRequest(
            req.model(), req.instructions(), req.input(), req.tools(), Boolean.TRUE);

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
        StringBuilder errBody = new StringBuilder();
        resp.body().forEach(line -> errBody.append(line).append('\n'));
        throw new IOException("OpenAI API error (" + resp.statusCode() + "): " + errBody);
    }

    try (var lines = resp.body()) {
        String currentEvent = null;
        for (var iter = lines.iterator(); iter.hasNext();) {
            String line = iter.next();
            if (line.isEmpty()) {
                currentEvent = null;
                continue;
            }
            if (line.startsWith("event: ")) {
                currentEvent = line.substring("event: ".length());
                continue;
            }
            if (!line.startsWith("data: ")) continue;
            String payload = line.substring("data: ".length());
            if ("[DONE]".equals(payload)) break;

            JsonNode node = mapper.readTree(payload);
            String type = currentEvent != null
                    ? currentEvent
                    : node.path("type").asText(null);

            switch (type) {
                case "response.output_text.delta" -> {
                    String delta = node.path("delta").asText("");
                    onEvent.accept(new StreamEvent(type, delta, null));
                }
                case "response.completed" -> {
                    ResponsesResponse full = mapper.treeToValue(
                            node.path("response"), ResponsesResponse.class);
                    onEvent.accept(new StreamEvent(type, null, full));
                }
                default -> { /* ignore */ }
            }
        }
    }
}
```

A few things worth pausing on:

- **`BodyHandlers.ofLines()`** — The JDK ships a body handler that exposes the response body as a `Stream<String>` of lines. No `BufferedReader` boilerplate.
- **Two-line parsing** — Each SSE event is an `event:` line followed by a `data:` line. We track the most recent event name and pair it with the next data payload.
- **Tree-then-deserialize** — `readTree` first lets us peek at the `type` field, then `treeToValue` materializes the full `ResponsesResponse` only for the `response.completed` event we actually care about.
- **Try-with-resources on the line stream** — Closes the underlying connection when we break out of the loop. Important for `[DONE]` and error cases.
- **`Consumer<StreamEvent>` callback** — Simpler than a `Flow.Subscriber` for this use case. The agent loop will turn the callbacks into a queue when it needs to.

## The Agent's Tool Call Type

The Responses API returns function calls inside `OutputItem`, but inside the agent loop we want a small, focused type that doesn't drag along all the message machinery. Create `agent/ToolCall.java`:

```java
package com.example.agents.agent;

/**
 * A function call extracted from the Responses API output.
 *
 * <p>{@code callId} is the API-assigned identifier we must echo back when
 * we send the result, so the model can match outputs to calls.
 */
public record ToolCall(String callId, String name, String arguments) {}
```

That's it — no separate `function` wrapper, no `type` field. The Responses API already flattens it.

## Events From the Loop

The agent loop needs to surface multiple kinds of events to the caller: text deltas, completed tool calls, tool results, errors, and "we're done." A sealed type is the cleanest way:

Create `agent/Events.java`:

```java
package com.example.agents.agent;

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

import com.example.agents.api.Messages.InputItem;
import com.example.agents.api.Messages.OutputItem;
import com.example.agents.api.Messages.ResponsesRequest;
import com.example.agents.api.Messages.ResponsesResponse;
import com.example.agents.api.OpenAiClient;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.function.Predicate;

public final class Agent {
    private final OpenAiClient client;
    private final Registry registry;
    private final String model;
    private final String instructions;

    public Agent(OpenAiClient client, Registry registry) {
        this(client, registry, "gpt-5-mini", Prompts.SYSTEM);
    }

    public Agent(OpenAiClient client, Registry registry, String model, String instructions) {
        this.client = client;
        this.registry = registry;
        this.model = model;
        this.instructions = instructions;
    }

    /**
     * Run the agent loop on a virtual thread and return a queue of events.
     * The queue is closed (via a Done or ErrorEvent) when the loop terminates.
     */
    public BlockingQueue<Events> run(List<InputItem> history) {
        return run(history, call -> true);
    }

    /**
     * Like run, but consults askApproval before executing any tool whose
     * requiresApproval() returns true.
     */
    public BlockingQueue<Events> run(List<InputItem> history, Predicate<ToolCall> askApproval) {
        BlockingQueue<Events> events = new LinkedBlockingQueue<>();

        Thread.ofVirtual().name("agent-loop").start(() -> {
            try {
                List<InputItem> input = new ArrayList<>(history);

                while (true) {
                    ResponsesRequest req = new ResponsesRequest(
                            model, instructions, input, registry.definitions(), null);

                    final ResponsesResponse[] finalResponse = new ResponsesResponse[1];

                    client.createResponseStream(req, ev -> {
                        switch (ev.type()) {
                            case "response.output_text.delta" -> {
                                if (ev.delta() != null && !ev.delta().isEmpty()) {
                                    events.add(new Events.TextDelta(ev.delta()));
                                }
                            }
                            case "response.completed" -> finalResponse[0] = ev.response();
                            default -> { /* ignore */ }
                        }
                    });

                    ResponsesResponse resp = finalResponse[0];
                    if (resp == null || resp.output() == null) {
                        events.add(new Events.Done());
                        return;
                    }

                    // Append every output item to the input so the next turn
                    // sees the assistant's full prior turn — including any
                    // function_call items that need their outputs paired below.
                    List<ToolCall> toolCalls = new ArrayList<>();
                    for (OutputItem item : resp.output()) {
                        InputItem replay = outputToInput(item);
                        if (replay != null) input.add(replay);
                        if ("function_call".equals(item.type())) {
                            toolCalls.add(new ToolCall(
                                    item.callId(), item.name(), item.arguments()));
                        }
                    }

                    if (toolCalls.isEmpty()) {
                        events.add(new Events.Done());
                        return;
                    }

                    for (ToolCall tc : toolCalls) {
                        events.add(new Events.ToolCallEvent(tc));

                        String result;
                        if (registry.requiresApproval(tc.name()) && !askApproval.test(tc)) {
                            result = "User denied this tool call.";
                        } else {
                            try {
                                result = registry.execute(tc.name(), tc.arguments());
                            } catch (Exception e) {
                                result = "Error: " + e.getMessage();
                            }
                        }

                        events.add(new Events.ToolResult(tc, result));
                        input.add(InputItem.functionCallOutput(tc.callId(), result));
                    }
                    // Loop again — feed tool results back to the model.
                }
            } catch (Exception e) {
                events.add(new Events.ErrorEvent(e));
            }
        });

        return events;
    }

    /**
     * Convert an output item into an input item for the next turn. Returns
     * null for output types we don't need to replay (e.g. {@code reasoning}).
     */
    private static InputItem outputToInput(OutputItem item) {
        return switch (item.type()) {
            case "function_call" -> InputItem.functionCall(
                    item.callId(), item.name(), item.arguments());
            case "message" -> {
                StringBuilder sb = new StringBuilder();
                if (item.content() != null) {
                    item.content().forEach(c -> sb.append(c.text() == null ? "" : c.text()));
                }
                yield InputItem.assistant(sb.toString());
            }
            default -> null;
        };
    }
}
```

The shape is the standard agent loop:

1. Send the conversation to the model.
2. Stream the response, surfacing text deltas and waiting for `response.completed`.
3. Walk the completed `output` array, replaying each item into `input` so the next turn keeps full context.
4. If there are no `function_call` items, emit `Done` and exit.
5. Otherwise, execute each tool call (asking for approval if needed), append `function_call_output` items, and loop.

### Why We Replay Function Calls Into the Input

The Responses API enforces a pairing rule: every `function_call_output` item in `input` must be preceded by its matching `function_call` item with the same `call_id`. If you only append the outputs and forget to replay the calls, the next request errors out with `No tool call found for function call output`. The `outputToInput` helper handles both halves of the pair.

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
import com.example.agents.agent.Registry;
import com.example.agents.api.Messages.InputItem;
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

        List<InputItem> history = List.of(
                InputItem.user("List the files in the current directory, then read build.gradle.kts and tell me what plugins are applied.")
        );

        BlockingQueue<Events> events = agent.run(history);

        while (true) {
            Events ev = events.take();
            switch (ev) {
                case Events.TextDelta t -> System.out.print(t.text());
                case Events.ToolCallEvent c -> System.out.printf(
                        "%n[tool] %s(%s)%n", c.call().name(), c.call().arguments());
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

- Parsed Server-Sent Events with `HttpResponse.BodyHandlers.ofLines()`, pairing `event:` and `data:` lines
- Modeled the only two events that matter — `response.output_text.delta` and `response.completed` — as a small `StreamEvent` record
- Walked the terminal `response.completed` payload to extract complete `function_call` items, no fragment accumulator required
- Designed the loop's output as a sealed `Events` interface
- Ran the loop on a virtual thread and bridged it to the caller via `BlockingQueue`
- Used pattern matching on the sealed event type for an exhaustive consumer

Next, we'll write evals that grade *full conversations* — not just whether the first tool call is right, but whether the agent eventually arrives at the correct answer.

---

**Next: [Chapter 5: Multi-Turn Evaluations →](./05-multi-turn-evals.md)**
