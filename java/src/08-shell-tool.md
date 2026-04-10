# Chapter 8: Shell Tool & Code Execution

## The Most Dangerous Tool

A shell tool turns the agent from "a thing that reads and writes files" into "a thing that can do anything you can do at a terminal." That's an enormous capability boost — and the source of every horror story you've heard about agents wiping their authors' machines.

This chapter is short on lines of code and long on guardrails. We'll add two tools:

- **`Shell`** — Run an arbitrary shell command. Requires approval. Has a timeout.
- **`RunCode`** — Write a snippet to a temp file and execute it with a chosen interpreter. Requires approval.

Both lean heavily on `ProcessBuilder` and `Process.waitFor(timeout, unit)`.

## The Shell Tool

Create `tools/Shell.java`:

```java
package com.example.agents.tools;

import com.example.agents.agent.Tool;
import com.example.agents.api.Messages.FunctionDefinition;
import com.example.agents.api.Messages.ToolDefinition;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

public record Shell(ObjectMapper mapper) implements Tool {

    private static final int TIMEOUT_SECONDS = 30;
    private static final int MAX_OUTPUT_BYTES = 16 * 1024;

    @Override public String name() { return "shell"; }
    @Override public boolean requiresApproval() { return true; }

    @Override
    public ToolDefinition definition() {
        JsonNode params = mapper.valueToTree(Map.of(
                "type", "object",
                "properties", Map.of(
                        "command", Map.of("type", "string", "description", "The shell command to execute")
                ),
                "required", List.of("command")
        ));
        return new ToolDefinition("function", new FunctionDefinition(
                "shell",
                "Execute a shell command and return its combined stdout and stderr. Use for running build tools, tests, git, and other CLI utilities. The command runs with a 30 second timeout.",
                params
        ));
    }

    @Override
    public String execute(String arguments) throws Exception {
        JsonNode args = mapper.readTree(arguments);
        String command = args.path("command").asText("").trim();
        if (command.isEmpty()) return "Error: missing 'command' argument";

        ProcessBuilder pb = new ProcessBuilder("sh", "-c", command)
                .redirectErrorStream(true);
        Process process = pb.start();

        byte[] output;
        try (InputStream in = process.getInputStream()) {
            output = in.readNBytes(MAX_OUTPUT_BYTES);
        }

        boolean finished = process.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS);
        if (!finished) {
            process.destroyForcibly();
            return "Error: command timed out after " + TIMEOUT_SECONDS + "s";
        }

        String text = new String(output, StandardCharsets.UTF_8);
        if (output.length == MAX_OUTPUT_BYTES) {
            text += "\n\n[output truncated at " + MAX_OUTPUT_BYTES + " bytes]";
        }

        int exit = process.exitValue();
        if (exit != 0) {
            return "Exit code " + exit + "\n\n" + text;
        }
        return text.isEmpty() ? "(no output)" : text;
    }
}
```

A handful of patterns are doing real work:

- **`ProcessBuilder` with `sh -c`** — Runs the command through a shell so the model can use pipes, redirects, and environment variables naturally. The downside is that everything happens in one process tree the model controls — there's no sandboxing here. We'll talk about that in Chapter 10.
- **`redirectErrorStream(true)`** — Merges stderr into stdout. Tools like `mvn test` print results to stdout but errors to stderr; the model needs to see both interleaved to make sense of failures.
- **`readNBytes(MAX_OUTPUT_BYTES)`** — Caps the amount we read into memory. A `find /` left running could fill the context window with garbage.
- **`waitFor(timeout, unit)` returning a boolean** — `true` if the process exited within the timeout, `false` if it didn't. We `destroyForcibly` on timeout.

## The Code Execution Tool

`Shell` can already run scripts via `python -c "..."`, but escaping multi-line code through JSON arguments is painful. `RunCode` makes the common case clean: write the code to a temp file and run it.

Create `tools/RunCode.java`:

```java
package com.example.agents.tools;

import com.example.agents.agent.Tool;
import com.example.agents.api.Messages.FunctionDefinition;
import com.example.agents.api.Messages.ToolDefinition;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

public record RunCode(ObjectMapper mapper) implements Tool {

    private static final int TIMEOUT_SECONDS = 30;
    private static final int MAX_OUTPUT_BYTES = 16 * 1024;

    private record Runner(String binary, List<String> extraArgs, String extension) {}

    private static final Map<String, Runner> RUNNERS = Map.of(
            "python", new Runner("python3", List.of(), ".py"),
            "node",   new Runner("node",    List.of(), ".js"),
            "bash",   new Runner("bash",    List.of(), ".sh"),
            "java",   new Runner("java",    List.of(), ".java")  // single-file source-code mode
    );

    @Override public String name() { return "run_code"; }
    @Override public boolean requiresApproval() { return true; }

    @Override
    public ToolDefinition definition() {
        JsonNode params = mapper.valueToTree(Map.of(
                "type", "object",
                "properties", Map.of(
                        "language", Map.of(
                                "type", "string",
                                "description", "Language to run. Supported: python, node, bash, java.",
                                "enum", List.of("python", "node", "bash", "java")
                        ),
                        "code", Map.of("type", "string", "description", "The source code to execute")
                ),
                "required", List.of("language", "code")
        ));
        return new ToolDefinition("function", new FunctionDefinition(
                "run_code",
                "Write a code snippet to a temp file and execute it with the given interpreter. Useful for quick computations, experiments, or one-off scripts. 30 second timeout.",
                params
        ));
    }

    @Override
    public String execute(String arguments) throws Exception {
        JsonNode args = mapper.readTree(arguments);
        String language = args.path("language").asText("");
        String code = args.path("code").asText("");
        if (code.isEmpty()) return "Error: missing 'code' argument";

        Runner runner = RUNNERS.get(language);
        if (runner == null) return "Error: unsupported language '" + language + "'";

        Path tmp = Files.createTempFile("agent-run-", runner.extension());
        try {
            Files.writeString(tmp, code);

            List<String> command = new ArrayList<>();
            command.add(runner.binary());
            command.addAll(runner.extraArgs());
            command.add(tmp.toString());

            ProcessBuilder pb = new ProcessBuilder(command).redirectErrorStream(true);
            Process process = pb.start();

            byte[] output;
            try (InputStream in = process.getInputStream()) {
                output = in.readNBytes(MAX_OUTPUT_BYTES);
            }

            boolean finished = process.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (!finished) {
                process.destroyForcibly();
                return "Error: code execution timed out after " + TIMEOUT_SECONDS + "s";
            }

            String text = new String(output, StandardCharsets.UTF_8);
            if (output.length == MAX_OUTPUT_BYTES) {
                text += "\n\n[output truncated at " + MAX_OUTPUT_BYTES + " bytes]";
            }

            int exit = process.exitValue();
            if (exit != 0) {
                return "Exit code " + exit + "\n\n" + text;
            }
            return text.isEmpty() ? "(no output)" : text;
        } finally {
            try { Files.deleteIfExists(tmp); } catch (Exception ignored) {}
        }
    }
}
```

Notes:

- **`Files.createTempFile` with prefix and suffix** — Guarantees a unique name. The suffix preserves the file extension so interpreters know what they're looking at.
- **Java single-file source mode** — Since Java 11, `java Hello.java` runs a single source file directly without a separate compile step. Perfect for `RunCode`.
- **Try / finally for cleanup** — If anything throws between `createTempFile` and the end of `execute`, the `finally` block still removes the file. Cheap insurance.

## Registering the Tools

Update `Main.java`:

```java
registry.register(new Shell(mapper));
registry.register(new RunCode(mapper));
```

A prompt that exercises both:

```java
Message.user("Write a Python script that prints the first ten Fibonacci numbers, run it, and tell me the output.")
```

Expected output (abbreviated):

```
[tool] run_code({"language":"python","code":"a, b = 0, 1\nfor _ in range(10):\n    print(a)\n    a, b = b, a + b\n"})
[result] 0
1
1
2
3
5
8
13
21
34

The first ten Fibonacci numbers are 0, 1, 1, 2, 3, 5, 8, 13, 21, 34.
```

## Why You Should Be Nervous

Right now there is **no sandboxing**. A misbehaving model can:

- Delete your home directory with `rm -rf ~`
- Exfiltrate secrets via `curl ... < ~/.aws/credentials`
- Mine cryptocurrency in the background
- Install software, modify your shell config, ...

The mitigations we already have are real but limited:

- `requiresApproval() == true` — In Chapter 9 the user will approve every shell call before it runs.
- `waitFor(timeout, unit)` — Caps wall-clock damage of any single call.
- `readNBytes` cap — Caps token-budget damage.

The mitigations we **don't** have are:

- A chroot, container, or VM around the agent process
- A read-only filesystem layer
- Network egress blocking
- A user with reduced privileges

We'll talk about each of those in Chapter 10. For now: only run this agent in a directory you wouldn't mind losing, on a machine you wouldn't mind reinstalling, and approve every tool call by hand.

## A Brief Word on `ProcessBuilder` Pitfalls

A few things that bite people writing shell tools:

- **Don't read from `process.getInputStream()` *after* `waitFor()`** — On some platforms the OS pipe has a fixed buffer (often 64KB). If the child writes more than that and nobody is draining the pipe, the child blocks forever and `waitFor` never returns. Read first, wait second. (Or use `ProcessBuilder.Redirect.to(file)` to avoid the pipe entirely.)
- **`destroyForcibly` is `SIGKILL` on Linux** — The killed process won't flush buffers, run shutdown hooks, or clean up its own temp files. For anything more complicated than these tools, prefer `destroy()` (SIGTERM) first, wait briefly, then escalate.
- **Watch out for `PATH`** — `ProcessBuilder` inherits the parent process's environment. If the agent is launched from a context that doesn't see `python3` or `node`, `RunCode` will fail with "No such file or directory."
- **Don't leak processes on exception** — If an exception is thrown between `start()` and `waitFor`, the child can survive after the agent exits. Wrap with try/finally and `destroyForcibly` if needed.

## Summary

In this chapter you:

- Wrote a `shell` tool that runs commands through `sh -c` with a timeout
- Wrote a `run_code` tool that writes snippets to temp files for several languages
- Used `ProcessBuilder.waitFor(timeout, unit)` to bound subprocess wall time
- Capped output size with `InputStream.readNBytes` to keep runaway commands from blowing up the context window
- Marked both tools as requiring approval — and faced up to how dangerous they still are without sandboxing

Next we'll build the terminal UI and finally wire that approval flow into something a human can actually click through.

---

**Next: [Chapter 9: Terminal UI with Lanterna →](./09-terminal-ui.md)**
