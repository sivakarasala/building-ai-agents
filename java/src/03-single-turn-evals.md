# Chapter 3: Single-Turn Evaluations

## Why Evals?

You have tools. The LLM can call them. But *does it call the right ones*? If you ask "What files are in this directory?", does the model pick `list_files` or `read_file`? If you ask "What's the weather?", does it correctly use *no* tools?

Evaluations answer these questions systematically. Instead of testing by hand each time you change a prompt or add a tool, you run a suite of test cases that verify tool selection.

This chapter builds a single-turn eval framework — one user message in, one tool call out, scored automatically.

## Eval Records

Create `eval/Cases.java`:

```java
package com.example.agents.eval;

import java.util.List;

public final class Cases {
    private Cases() {}

    public record Case(
            String input,
            String expectedTool,
            List<String> secondaryTools
    ) {
        public Case(String input, String expectedTool) {
            this(input, expectedTool, List.of());
        }
    }

    public record Result(
            String input,
            String expectedTool,
            String actualTool,
            boolean passed,
            double score,
            String reason
    ) {}

    public record Summary(
            int total,
            int passed,
            int failed,
            double averageScore,
            List<Result> results
    ) {}
}
```

Three case types drive the scoring:

- **Golden tool** (`expectedTool`) — The best tool for this input. Full marks.
- **Secondary tools** (`secondaryTools`) — Acceptable alternatives. Partial credit.
- **Negative cases** — Set `expectedTool` to `"none"`. The model should respond with text, not a tool call.

## Evaluators

Create `eval/Evaluator.java`:

```java
package com.example.agents.eval;

import com.example.agents.eval.Cases.Case;
import com.example.agents.eval.Cases.Result;
import com.example.agents.eval.Cases.Summary;

import java.util.List;

public final class Evaluator {
    private Evaluator() {}

    /**
     * Score a single tool call against an eval case.
     * Pass actualTool == null when no tool was called.
     */
    public static Result evaluate(Case c, String actualTool) {
        boolean expectsNone = "none".equals(c.expectedTool());

        if (actualTool != null && actualTool.equals(c.expectedTool())) {
            return new Result(c.input(), c.expectedTool(), actualTool,
                    true, 1.0, "Correct: selected " + actualTool);
        }
        if (actualTool != null && c.secondaryTools().contains(actualTool)) {
            return new Result(c.input(), c.expectedTool(), actualTool,
                    true, 0.5, "Acceptable: selected " + actualTool + " (secondary)");
        }
        if (actualTool == null && expectsNone) {
            return new Result(c.input(), c.expectedTool(), null,
                    true, 1.0, "Correct: no tool call");
        }
        if (actualTool != null && expectsNone) {
            return new Result(c.input(), c.expectedTool(), actualTool,
                    false, 0.0, "Expected no tool call, got " + actualTool);
        }
        if (actualTool == null) {
            return new Result(c.input(), c.expectedTool(), null,
                    false, 0.0, "Expected " + c.expectedTool() + ", got no tool call");
        }
        return new Result(c.input(), c.expectedTool(), actualTool,
                false, 0.0, "Wrong tool: expected " + c.expectedTool() + ", got " + actualTool);
    }

    public static Summary summarize(List<Result> results) {
        int passed = 0;
        double scoreSum = 0;
        for (Result r : results) {
            if (r.passed()) passed++;
            scoreSum += r.score();
        }
        int total = results.size();
        double avg = total == 0 ? 0 : scoreSum / total;
        return new Summary(total, passed, total - passed, avg, results);
    }
}
```

`null` represents "no tool was called." A sentinel `"none"` would also work but `null` is more honest about absence — and lets the calling code use `Objects.equals` naturally.

## The Executor

The executor sends a single message to the API and extracts which tool was called. Create `eval/Runner.java`:

```java
package com.example.agents.eval;

import com.example.agents.agent.Prompts;
import com.example.agents.agent.Registry;
import com.example.agents.api.Messages.ChatCompletionRequest;
import com.example.agents.api.Messages.ChatCompletionResponse;
import com.example.agents.api.Messages.Message;
import com.example.agents.api.OpenAiClient;

import java.util.List;

public final class Runner {
    private Runner() {}

    /**
     * Send a single user message and return the tool name the model chose,
     * or null if no tool was called.
     */
    public static String runSingleTurn(OpenAiClient client, Registry registry, String input) throws Exception {
        ChatCompletionRequest req = new ChatCompletionRequest(
                "gpt-4.1-mini",
                List.of(
                        Message.system(Prompts.SYSTEM),
                        Message.user(input)
                ),
                registry.definitions(),
                null
        );

        ChatCompletionResponse resp = client.chatCompletion(req);
        if (resp.choices().isEmpty()) return null;

        var msg = resp.choices().get(0).message();
        if (msg.toolCalls() == null || msg.toolCalls().isEmpty()) return null;
        return msg.toolCalls().get(0).function().name();
    }
}
```

## Test Data

Create `app/eval-data/file_tools.json`:

```json
[
    {
        "input": "What files are in the current directory?",
        "expectedTool": "list_files"
    },
    {
        "input": "Show me the contents of build.gradle.kts",
        "expectedTool": "read_file"
    },
    {
        "input": "Read the settings.gradle.kts file",
        "expectedTool": "read_file",
        "secondaryTools": ["list_files"]
    },
    {
        "input": "What is Java?",
        "expectedTool": "none"
    },
    {
        "input": "Tell me a joke",
        "expectedTool": "none"
    },
    {
        "input": "List everything in the src directory",
        "expectedTool": "list_files"
    }
]
```

## Running Evals

Create `eval/EvalSingleMain.java`:

```java
package com.example.agents.eval;

import com.example.agents.agent.Registry;
import com.example.agents.api.OpenAiClient;
import com.example.agents.eval.Cases.Case;
import com.example.agents.eval.Cases.Result;
import com.example.agents.eval.Cases.Summary;
import com.example.agents.tools.ListFiles;
import com.example.agents.tools.ReadFile;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.cdimascio.dotenv.Dotenv;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

public class EvalSingleMain {
    public static void main(String[] args) throws Exception {
        Dotenv env = Dotenv.configure().ignoreIfMissing().load();
        String apiKey = env.get("OPENAI_API_KEY", System.getenv("OPENAI_API_KEY"));
        if (apiKey == null || apiKey.isBlank()) {
            System.err.println("OPENAI_API_KEY must be set");
            System.exit(1);
        }

        OpenAiClient client = new OpenAiClient(apiKey);
        ObjectMapper mapper = client.mapper();

        Registry registry = new Registry();
        registry.register(new ReadFile(mapper));
        registry.register(new ListFiles(mapper));

        String json = Files.readString(Path.of("eval-data/file_tools.json"));
        List<Case> cases = mapper.readValue(json, new TypeReference<List<Case>>() {});

        System.out.printf("Running %d eval cases...%n%n", cases.size());

        List<Result> results = new ArrayList<>();
        for (Case c : cases) {
            String actual = Runner.runSingleTurn(client, registry, c.input());
            Result r = Evaluator.evaluate(c, actual);
            String status = r.passed() ? "PASS" : "FAIL";
            System.out.printf("[%s] %s -> %s%n", status, c.input(), r.reason());
            results.add(r);
        }

        Summary s = Evaluator.summarize(results);
        System.out.println();
        System.out.println("--- Summary ---");
        System.out.printf("Passed: %d/%d (%.0f%%)%n", s.passed(), s.total(), s.averageScore() * 100);
        if (s.failed() > 0) {
            System.out.printf("Failed: %d%n", s.failed());
        }
    }
}
```

Run it from the project root:

```bash
./gradlew run -PmainClass=com.example.agents.eval.EvalSingleMain
```

Or, more practically, register a Gradle task so this becomes `./gradlew evalSingle`. Add to `build.gradle.kts`:

```kotlin
tasks.register<JavaExec>("evalSingle") {
    group = "verification"
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass.set("com.example.agents.eval.EvalSingleMain")
}
```

Expected output:

```
Running 6 eval cases...

[PASS] What files are in the current directory? -> Correct: selected list_files
[PASS] Show me the contents of build.gradle.kts -> Correct: selected read_file
[PASS] Read the settings.gradle.kts file -> Correct: selected read_file
[PASS] What is Java? -> Correct: no tool call
[PASS] Tell me a joke -> Correct: no tool call
[PASS] List everything in the src directory -> Correct: selected list_files

--- Summary ---
Passed: 6/6 (100%)
```

### Why a Separate Main Class?

We use a dedicated `EvalSingleMain` instead of a JUnit test. JUnit is for deterministic assertions. Evals hit a real API with non-deterministic results — a test that fails 5% of the time is worse than useless. Evals are run manually, examined by humans, and tracked over time. Putting them behind a Gradle task that says "this calls the API" keeps them out of `./gradlew test`.

## Summary

In this chapter you:

- Defined eval types as records
- Built a scoring system with golden, secondary, and negative cases
- Created a single-turn executor that calls the API and extracts tool names
- Set up a Gradle task to run evals separately from unit tests
- Used `null` to represent "no tool called"

Next, we build the agent loop — the core method that streams responses, detects tool calls, executes them, and feeds results back to the LLM.

---

**Next: [Chapter 4: The Agent Loop →](./04-the-agent-loop.md)**
