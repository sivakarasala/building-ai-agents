# Chapter 5: Multi-Turn Evaluations

## Beyond Tool Selection

Single-turn evals answer a narrow question: *given this user message, did the model pick the right tool?* That's necessary but not sufficient. Real agents take multiple turns. They call a tool, look at the result, call another tool, and eventually answer. A multi-turn eval grades the **whole trajectory** — did the agent end up giving a correct answer, regardless of which exact path it took?

This chapter has two ingredients:

1. **Mocked tools** — So evals are fast, deterministic, and free.
2. **An LLM judge** — A second model call that reads the transcript and grades the final answer.

## Mocked Tools

Real tools touch the filesystem, the network, the shell. Evals shouldn't. We want to drop in fakes that return canned data so we can test agent behavior without flakiness or cost.

The catch is our `Tool` interface is sealed. To add a `MockTool` we either widen the seal or wrap real tools. Widening is the cleaner option for our use case — the eval package becomes a permitted subtype.

Update `agent/Tool.java`:

```java
public sealed interface Tool
        permits ReadFile, ListFiles, WriteFile, EditFile, DeleteFile,
                Shell, RunCode, WebSearch,
                com.example.agents.eval.MockTool {
    // ... unchanged ...
}
```

Then create `eval/MockTool.java`:

```java
package com.example.agents.eval;

import com.example.agents.agent.Tool;
import com.example.agents.api.Messages.FunctionDefinition;
import com.example.agents.api.Messages.ToolDefinition;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public final class MockTool implements Tool {
    private final String name;
    private final String description;
    private final String response;
    private final ObjectMapper mapper;
    private final List<MockCall> calls;

    public record MockCall(String name, String args) {}

    public MockTool(String name, String description, String response,
                    ObjectMapper mapper, List<MockCall> calls) {
        this.name = name;
        this.description = description;
        this.response = response;
        this.mapper = mapper;
        this.calls = calls != null ? calls : new ArrayList<>();
    }

    @Override public String name() { return name; }

    @Override
    public ToolDefinition definition() {
        JsonNode params = mapper.valueToTree(Map.of(
                "type", "object",
                "properties", Map.of(),
                "additionalProperties", true
        ));
        return new ToolDefinition("function", new FunctionDefinition(name, description, params));
    }

    @Override
    public String execute(String arguments) {
        calls.add(new MockCall(name, arguments));
        return response;
    }

    public List<MockCall> calls() { return calls; }
}
```

Mocks satisfy the same `Tool` interface as real tools, so we can register them in a normal `Registry` and run the agent loop unchanged. The shared `List<MockCall>` lets each test inspect which tools were called and with what arguments.

## Multi-Turn Case Records

Add to `eval/Cases.java`:

```java
public record MockToolSpec(
        String name,
        String description,
        String response
) {}

public record MultiTurnCase(
        String name,
        String userMessage,
        List<MockToolSpec> mockTools,
        String rubric,
        List<String> expectedCalls
) {}

public record MultiTurnResult(
        String name,
        boolean passed,
        double score,
        String reason,
        String finalText,
        List<MockTool.MockCall> toolCalls
) {}
```

The `rubric` is a plain-English description of what a correct final answer looks like. The judge uses it. `expectedCalls` is an optional sanity check.

## The Multi-Turn Runner

Add to `eval/Runner.java`:

```java
import com.example.agents.agent.Agent;
import com.example.agents.agent.Events;
import com.example.agents.agent.Prompts;
import com.example.agents.api.Messages.Message;
import com.example.agents.eval.Cases.MultiTurnCase;
import com.example.agents.eval.Cases.MultiTurnResult;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.BlockingQueue;

public static MultiTurnResult runMultiTurn(OpenAiClient client, MultiTurnCase c) throws Exception {
    List<MockTool.MockCall> calls = new ArrayList<>();

    Registry registry = new Registry();
    for (var spec : c.mockTools()) {
        registry.register(new MockTool(
                spec.name(), spec.description(), spec.response(), client.mapper(), calls));
    }

    Agent agent = new Agent(client, registry);
    BlockingQueue<Events> events = agent.run(List.of(
            Message.system(Prompts.SYSTEM),
            Message.user(c.userMessage())
    ));

    StringBuilder finalText = new StringBuilder();
    while (true) {
        Events ev = events.take();
        if (ev instanceof Events.TextDelta t) {
            finalText.append(t.text());
        } else if (ev instanceof Events.ErrorEvent err) {
            return new MultiTurnResult(c.name(), false, 0.0,
                    "agent error: " + err.error().getMessage(),
                    finalText.toString(), calls);
        } else if (ev instanceof Events.Done) {
            break;
        }
    }

    return new MultiTurnResult(c.name(), false, 0.0, "ungraded",
            finalText.toString(), calls);
}
```

We register the mocks, kick off the agent, drain the event queue into a single final-text string and a slice of recorded calls. No grading yet — that's the judge's job.

## The LLM Judge

The judge is itself a model call. We hand it the rubric, the user message, the agent's final answer, and the list of tool calls, and ask for a JSON verdict.

Create `eval/Judge.java`:

```java
package com.example.agents.eval;

import com.example.agents.api.Messages.ChatCompletionRequest;
import com.example.agents.api.Messages.ChatCompletionResponse;
import com.example.agents.api.Messages.Message;
import com.example.agents.api.OpenAiClient;
import com.example.agents.eval.Cases.MultiTurnCase;
import com.example.agents.eval.Cases.MultiTurnResult;
import com.fasterxml.jackson.databind.JsonNode;

import java.util.List;
import java.util.stream.Collectors;

public final class Judge {
    private Judge() {}

    private static final String JUDGE_SYSTEM = """
            You grade AI agent transcripts. You are strict but fair.

            You will be given:
            - A user message
            - A rubric describing what a correct final answer looks like
            - The agent's final answer
            - The sequence of tool calls the agent made

            Respond with a JSON object on a single line, no markdown:
            {"passed": true|false, "score": 0.0-1.0, "reason": "short explanation"}

            Pass if the final answer satisfies the rubric. Partial credit is allowed.
            """;

    public static MultiTurnResult judge(OpenAiClient client, MultiTurnCase c, MultiTurnResult r) throws Exception {
        String callsBlock = r.toolCalls().isEmpty()
                ? "(none)"
                : r.toolCalls().stream()
                    .map(call -> "- " + call.name() + "(" + call.args() + ")")
                    .collect(Collectors.joining("\n"));

        String prompt = """
                User message:
                %s

                Rubric:
                %s

                Agent final answer:
                %s

                Tool calls:
                %s
                """.formatted(c.userMessage(), c.rubric(), r.finalText(), callsBlock);

        ChatCompletionRequest req = new ChatCompletionRequest(
                "gpt-4.1-mini",
                List.of(
                        Message.system(JUDGE_SYSTEM),
                        Message.user(prompt)
                ),
                null,
                null
        );

        ChatCompletionResponse resp = client.chatCompletion(req);
        if (resp.choices().isEmpty()) {
            throw new RuntimeException("judge returned no choices");
        }

        String raw = resp.choices().get(0).message().content().strip();
        // Strip ```json fences if the model added them.
        if (raw.startsWith("```")) {
            int firstNewline = raw.indexOf('\n');
            raw = firstNewline >= 0 ? raw.substring(firstNewline + 1) : raw;
            if (raw.endsWith("```")) {
                raw = raw.substring(0, raw.length() - 3);
            }
            raw = raw.strip();
        }

        JsonNode verdict = client.mapper().readTree(raw);
        return new MultiTurnResult(
                c.name(),
                verdict.path("passed").asBoolean(false),
                verdict.path("score").asDouble(0.0),
                verdict.path("reason").asText(""),
                r.finalText(),
                r.toolCalls()
        );
    }
}
```

Two pragmatic notes:

- **Markdown fence stripping** — Models love to wrap JSON in ```` ```json ```` even when told not to. Stripping fences is cheaper than fighting the model.
- **Same model as the agent** — Using a stronger judge model is reasonable in production. For learning, the symmetry keeps things simple.

## Test Data and Runner

Create `eval-data/agent_multiturn.json`:

```json
[
    {
        "name": "find_module_name",
        "userMessage": "What is the project name for this build?",
        "mockTools": [
            {
                "name": "list_files",
                "description": "List all files and directories in the specified directory path.",
                "response": "[file] settings.gradle.kts\n[file] build.gradle.kts\n[dir] src"
            },
            {
                "name": "read_file",
                "description": "Read the contents of a file at the specified path.",
                "response": "rootProject.name = \"agents-java\"\n"
            }
        ],
        "rubric": "The answer must include the project name 'agents-java'.",
        "expectedCalls": ["list_files", "read_file"]
    },
    {
        "name": "no_tools_needed",
        "userMessage": "What does CLI stand for?",
        "mockTools": [
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

Create `eval/EvalMultiMain.java`:

```java
package com.example.agents.eval;

import com.example.agents.api.OpenAiClient;
import com.example.agents.eval.Cases.MultiTurnCase;
import com.example.agents.eval.Cases.MultiTurnResult;
import com.fasterxml.jackson.core.type.TypeReference;
import io.github.cdimascio.dotenv.Dotenv;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

public class EvalMultiMain {
    public static void main(String[] args) throws Exception {
        Dotenv env = Dotenv.configure().ignoreIfMissing().load();
        String apiKey = env.get("OPENAI_API_KEY", System.getenv("OPENAI_API_KEY"));
        if (apiKey == null) { System.err.println("OPENAI_API_KEY required"); System.exit(1); }

        OpenAiClient client = new OpenAiClient(apiKey);

        String json = Files.readString(Path.of("eval-data/agent_multiturn.json"));
        List<MultiTurnCase> cases = client.mapper().readValue(json, new TypeReference<>() {});

        System.out.printf("Running %d multi-turn cases...%n%n", cases.size());

        int passed = 0, failed = 0;
        double scoreSum = 0;

        for (MultiTurnCase c : cases) {
            MultiTurnResult r = Runner.runMultiTurn(client, c);
            r = Judge.judge(client, c, r);

            String status = r.passed() ? "PASS" : "FAIL";
            if (r.passed()) passed++; else failed++;
            scoreSum += r.score();

            System.out.printf("[%s] %s — %.2f%n", status, r.name(), r.score());
            System.out.println("    reason: " + r.reason());
            System.out.println("    calls : " + r.toolCalls().size());
            System.out.println();
        }

        System.out.println("--- Summary ---");
        System.out.printf("Passed: %d / %d%n", passed, passed + failed);
        if (passed + failed > 0) {
            System.out.printf("Average score: %.2f%n", scoreSum / (passed + failed));
        }
    }
}
```

Add a Gradle task next to the single-turn one:

```kotlin
tasks.register<JavaExec>("evalMulti") {
    group = "verification"
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass.set("com.example.agents.eval.EvalMultiMain")
}
```

Run it:

```bash
./gradlew evalMulti
```

Expected output:

```
Running 2 multi-turn cases...

[PASS] find_module_name — 1.00
    reason: The agent listed files, read settings.gradle.kts, and reported the correct project name.
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
- Designed multi-turn case and result types as records
- Wired the existing agent loop into an eval runner with no changes to the loop itself
- Built an LLM judge that returns a strict JSON verdict
- Ran a small suite end-to-end with mocked tools and a rubric

Next up: real file system tools — write, delete, and the safety checks that come with them.

---

**Next: [Chapter 6: File System Tools →](./06-file-system-tools.md)**
