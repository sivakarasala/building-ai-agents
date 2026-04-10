# Chapter 7: Web Search & Context Management

## Two Problems, One Chapter

Two things get in the way of long-running agents:

1. **The agent only knows what's in its training data.** It can't tell you what shipped in Java 22 or what the current price of an API call is. It needs to search the web.
2. **Conversations grow without bound.** Every tool result, every assistant turn, every user message gets appended to the history. Eventually you blow past the context window and the model errors out — or, worse, silently truncates and starts hallucinating.

The first problem is a new tool. The second is a new package that watches token counts and compacts old turns into a summary when the conversation gets too long.

## The Web Search Tool

We'll use Tavily, a search API designed for LLM agents. It returns clean summaries instead of raw HTML, which is exactly what we want.

Sign up for a free key at [tavily.com](https://tavily.com) and add it to `.env`:

```
TAVILY_API_KEY=tvly-...
```

Create `tools/WebSearch.java`:

```java
package com.example.agents.tools;

import com.example.agents.agent.Tool;
import com.example.agents.api.Messages.ToolDefinition;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class WebSearch implements Tool {
    private static final URI TAVILY_URL = URI.create("https://api.tavily.com/search");

    private final ObjectMapper mapper;
    private final HttpClient http;

    public WebSearch(ObjectMapper mapper) {
        this.mapper = mapper;
        this.http = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .build();
    }

    @Override public String name() { return "web_search"; }

    @Override
    public ToolDefinition definition() {
        JsonNode params = mapper.valueToTree(Map.of(
                "type", "object",
                "properties", Map.of(
                        "query",       Map.of("type", "string", "description", "The search query"),
                        "max_results", Map.of("type", "integer", "description", "Maximum number of results", "default", 5)
                ),
                "required", List.of("query")
        ));
        return new ToolDefinition(
                "function",
                "web_search",
                "Search the web for current information. Returns a summarized answer plus the top result snippets. Use this when you need information beyond your training data.",
                params
        );
    }

    @Override
    public String execute(String arguments) throws Exception {
        JsonNode args = mapper.readTree(arguments);
        String query = args.path("query").asText("");
        int maxResults = args.path("max_results").asInt(5);
        if (query.isEmpty()) return "Error: missing 'query' argument";

        String apiKey = System.getenv("TAVILY_API_KEY");
        if (apiKey == null || apiKey.isEmpty()) {
            return "Error: TAVILY_API_KEY is not set";
        }

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("api_key", apiKey);
        body.put("query", query);
        body.put("max_results", maxResults);
        body.put("include_answer", true);

        HttpRequest req = HttpRequest.newBuilder()
                .uri(TAVILY_URL)
                .timeout(Duration.ofSeconds(30))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(mapper.writeValueAsString(body)))
                .build();

        HttpResponse<String> resp;
        try {
            resp = http.send(req, HttpResponse.BodyHandlers.ofString());
        } catch (Exception e) {
            return "Error calling Tavily: " + e.getMessage();
        }

        if (resp.statusCode() >= 400) {
            return "Tavily error (" + resp.statusCode() + "): " + resp.body();
        }

        JsonNode root = mapper.readTree(resp.body());
        StringBuilder sb = new StringBuilder();
        String answer = root.path("answer").asText("");
        if (!answer.isEmpty()) {
            sb.append("Answer: ").append(answer).append("\n\n");
        }
        sb.append("Sources:\n");
        JsonNode results = root.path("results");
        for (int i = 0; i < results.size(); i++) {
            JsonNode r = results.get(i);
            sb.append(i + 1).append(". ").append(r.path("title").asText()).append('\n');
            sb.append("   ").append(r.path("url").asText()).append('\n');
            sb.append("   ").append(r.path("content").asText()).append('\n');
        }
        return sb.toString();
    }
}
```

A few details worth noting:

- **Plain class, not a record** — `WebSearch` holds a non-trivial `HttpClient`, and we want it to be a singleton-style component constructed once. Records can do this, but the equality semantics get weird when one of the fields is a thread-pool-owning client.
- **`Map<String, Object>` for the request body** — When you only need to build a small JSON object once, an inline map is fine. For anything larger or reused, define a record.
- **Tavily's `include_answer`** — Asks Tavily to use its own LLM to write a one-paragraph summary. That summary is often all the agent needs, which keeps the response small.

Add `WebSearch` to the `permits` list in `agent/Tool.java` if you haven't already, then register it in `Main.java`:

```java
registry.register(new WebSearch(mapper));
```

## Why Token Counting Matters

Each model has a context window — the maximum number of tokens it'll accept in one request. `gpt-4.1-mini` has 128k tokens, which sounds enormous until you start reading entire files into context. A single 5000-line file is ~50k tokens. Two of those plus a long conversation plus tool definitions and you're in trouble.

We need to:

1. Estimate how many tokens the current history holds.
2. When that estimate crosses a threshold, replace the oldest messages with a one-paragraph LLM-generated summary.

Real token counters (like `jtokkit`) require porting BPE tables. For an agent loop, an estimator is enough — we only need to know *roughly* when to compact.

## The Token Estimator

Create `context/Tokens.java`:

```java
package com.example.agents.context;

import com.example.agents.api.Messages.InputItem;

import java.util.List;

public final class Tokens {
    private Tokens() {}

    /** Rough token estimate for a string: 1 token ≈ 4 characters. */
    public static int estimate(String s) {
        if (s == null || s.isEmpty()) return 0;
        return (s.length() + 3) / 4;
    }

    /** Rough total token count for a list of input items. */
    public static int estimateMessages(List<InputItem> items) {
        int total = 0;
        for (InputItem m : items) {
            total += 4; // role/type framing
            total += estimate(m.content());
            total += estimate(m.name());
            total += estimate(m.arguments());
            total += estimate(m.output());
        }
        return total;
    }
}
```

Yes, this is wildly approximate. It's also fast, allocation-light, and good enough to decide *when* to compact. If the threshold is 60k and we're estimating 58k vs 62k, the worst case is one extra compaction we didn't strictly need — not a crash.

## Conversation Compaction

Compaction works in three steps:

1. Decide which input items are "old" enough to summarize. Always keep the most recent user message and the assistant turns that respond to it.
2. Send the old items to the model with a "summarize this" prompt.
3. Replace the old items with a single user-role item containing the summary.

Note that the system prompt isn't part of the `input` list — it lives in the top-level `instructions` field of the request, so we never have to worry about preserving it during compaction.

Create `context/Compact.java`:

```java
package com.example.agents.context;

import com.example.agents.api.Messages.InputItem;
import com.example.agents.api.Messages.ResponsesRequest;
import com.example.agents.api.Messages.ResponsesResponse;
import com.example.agents.api.OpenAiClient;

import java.util.ArrayList;
import java.util.List;

public final class Compact {
    private Compact() {}

    public static final int DEFAULT_MAX_TOKENS = 60_000;
    public static final int KEEP_RECENT = 6;

    private static final String COMPACT_SYSTEM = """
            You are summarizing the early portion of an AI agent conversation so it fits in a smaller context window.

            Produce a concise summary that preserves:
            - What the user originally asked for and any constraints
            - Key facts the agent learned from tool calls
            - Files the agent has read or modified
            - Decisions the agent has already made

            Aim for under 300 words. Write in plain prose, no markdown.
            """;

    /**
     * Compacts the input history if its estimated token count exceeds maxTokens.
     * Always keeps the trailing KEEP_RECENT items verbatim. The top-level
     * `instructions` (system prompt) is not part of the input, so it's untouched.
     */
    public static List<InputItem> maybeCompact(OpenAiClient client, List<InputItem> input, int maxTokens) throws Exception {
        if (maxTokens <= 0) maxTokens = DEFAULT_MAX_TOKENS;
        if (Tokens.estimateMessages(input) < maxTokens) return input;
        if (input.size() <= KEEP_RECENT + 1) return input;

        int cutoff = input.size() - KEEP_RECENT;
        List<InputItem> toSummarize = input.subList(0, cutoff);
        List<InputItem> keep = input.subList(cutoff, input.size());

        String summary = summarize(client, toSummarize);

        List<InputItem> out = new ArrayList<>(1 + keep.size());
        out.add(InputItem.user("Summary of earlier conversation:\n" + summary));
        out.addAll(keep);
        return out;
    }

    private static String summarize(OpenAiClient client, List<InputItem> items) throws Exception {
        StringBuilder transcript = new StringBuilder();
        for (InputItem m : items) {
            if ("function_call".equals(m.type())) {
                transcript.append("[tool_call] ").append(m.name())
                          .append('(').append(m.arguments() == null ? "" : m.arguments()).append(")\n");
            } else if ("function_call_output".equals(m.type())) {
                transcript.append("[tool_result] ").append(m.output() == null ? "" : m.output()).append('\n');
            } else {
                transcript.append('[').append(m.role()).append("] ")
                          .append(m.content() == null ? "" : m.content()).append('\n');
            }
        }

        ResponsesRequest req = new ResponsesRequest(
                "gpt-5-mini",
                COMPACT_SYSTEM,
                List.of(InputItem.user(transcript.toString())),
                null,
                null
        );
        ResponsesResponse resp = client.createResponse(req);
        return resp.outputText() == null ? "" : resp.outputText();
    }
}
```

The key invariants:

- **System prompt is untouched.** It lives in the top-level `instructions` field, not in the `input` list, so compaction never sees it.
- **Recent turns are preserved verbatim.** The assistant just decided to call a tool; if we summarized that out, the next loop iteration would reach for the wrong context.
- **The summary becomes a new user-role item.** A user-framed summary reads as "here's what happened" without claiming the model said it.

## Wiring Compaction Into the Loop

Update `Agent.java`. At the top of the `while (true)` loop in the virtual thread, before constructing the request, add:

```java
import com.example.agents.context.Compact;

// inside the while loop, before constructing req:
input = new ArrayList<>(Compact.maybeCompact(client, input, Compact.DEFAULT_MAX_TOKENS));
```

The `new ArrayList<>` wrap is defensive: `subList` returns a view backed by the original, and we want to be sure we own the list we're appending to.

That's the whole integration. Compaction is invisible to the rest of the loop: a step that occasionally rewrites `input` between turns.

## Trying It Out

You don't easily hit the compaction threshold by hand, but you can lower it temporarily to watch it fire:

```java
input = new ArrayList<>(Compact.maybeCompact(client, input, 2000));
```

Now run a session that reads a couple of files. After the second or third turn the agent will continue working as if nothing happened — but if you log `history.size()` before and after the call, you'll see it shrink.

## Summary

In this chapter you:

- Added a `web_search` tool backed by Tavily
- Built a cheap token estimator with the `1 token ≈ 4 chars` heuristic
- Wrote `maybeCompact` to summarize old messages into a single system message
- Wired compaction into the agent loop without touching the streaming code

Next up: shell commands and arbitrary code execution. The agent gets significantly more powerful — and significantly more dangerous.

---

**Next: [Chapter 8: Shell Tool & Code Execution →](./08-shell-tool.md)**
