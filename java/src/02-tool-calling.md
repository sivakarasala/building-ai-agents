# Chapter 2: Tool Calling with JSON Schema

## The Tool Interface

In TypeScript, a tool is an object with a description and an execute function. In Python, it's a dict with a JSON Schema and a callable. In Java, we use a `sealed interface` so the compiler knows every tool implementation up front.

Create `agent/Tool.java`:

```java
package com.example.agents.agent;

import com.example.agents.api.Messages.ToolDefinition;
import com.example.agents.tools.*;

public sealed interface Tool
        permits ReadFile, ListFiles, WriteFile, EditFile, DeleteFile,
                Shell, RunCode, WebSearch {

    /** The tool's name as the API will see it. */
    String name();

    /** The full ToolDefinition sent to the API. */
    ToolDefinition definition();

    /** Execute the tool with raw JSON arguments and return a string result. */
    String execute(String arguments) throws Exception;

    /** Whether the tool needs human approval before executing. */
    default boolean requiresApproval() {
        return false;
    }
}
```

Four things to note:

- **`sealed` with a `permits` clause** — Lists every concrete implementation. New tools must be added to the permits list, which means the compiler can verify exhaustive switches. We don't yet need switches, but the discipline keeps tool authorship intentional.
- **Raw JSON `String` args** — The LLM generates arbitrary JSON that matches our schema, but Java can't know the shape at compile time. We parse it inside each tool's `execute` method.
- **Returns `String`, throws `Exception`** — String results travel back to the LLM. Exceptions are for genuinely unexpected failures (bad JSON args). Recoverable errors (file not found) are returned as plain strings the model can read.
- **`requiresApproval()` defaults to `false`** — Read-only tools opt out by accepting the default; destructive tools override.

If the `permits` list bothers you, the alternative is a non-sealed interface and trusting documentation. For a teaching project sealed wins; for a plugin architecture you'd skip the seal.

## The Tool Registry

Create `agent/Registry.java`:

```java
package com.example.agents.agent;

import com.example.agents.api.Messages.ToolDefinition;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class Registry {
    private final Map<String, Tool> tools = new LinkedHashMap<>();

    public void register(Tool tool) {
        tools.put(tool.name(), tool);
    }

    public List<ToolDefinition> definitions() {
        return tools.values().stream().map(Tool::definition).toList();
    }

    public String execute(String name, String arguments) throws Exception {
        Tool tool = tools.get(name);
        if (tool == null) {
            throw new IllegalArgumentException("unknown tool: " + name);
        }
        return tool.execute(arguments);
    }

    public boolean requiresApproval(String name) {
        Tool tool = tools.get(name);
        return tool != null && tool.requiresApproval();
    }
}
```

`LinkedHashMap` preserves insertion order so the API receives tool definitions in the order we registered them. Not strictly necessary, but it makes test fixtures stable.

## Your First Tools: ReadFile and ListFiles

Create `tools/ReadFile.java`:

```java
package com.example.agents.tools;

import com.example.agents.agent.Tool;
import com.example.agents.api.Messages.ToolDefinition;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;

public record ReadFile(ObjectMapper mapper) implements Tool {

    @Override public String name() { return "read_file"; }

    @Override
    public ToolDefinition definition() {
        JsonNode params = mapper.valueToTree(java.util.Map.of(
                "type", "object",
                "properties", java.util.Map.of(
                        "path", java.util.Map.of(
                                "type", "string",
                                "description", "The path to the file to read"
                        )
                ),
                "required", java.util.List.of("path")
        ));
        return new ToolDefinition(
                "function",
                "read_file",
                "Read the contents of a file at the specified path. Use this to examine file contents.",
                params
        );
    }

    @Override
    public String execute(String arguments) throws Exception {
        JsonNode args = mapper.readTree(arguments);
        String path = args.path("path").asText("");
        if (path.isEmpty()) {
            return "Error: missing 'path' argument";
        }
        try {
            return Files.readString(Path.of(path));
        } catch (NoSuchFileException e) {
            return "Error: File not found: " + path;
        } catch (Exception e) {
            return "Error reading file: " + e.getMessage();
        }
    }
}
```

Create `tools/ListFiles.java`:

```java
package com.example.agents.tools;

import com.example.agents.agent.Tool;
import com.example.agents.api.Messages.ToolDefinition;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Stream;

public record ListFiles(ObjectMapper mapper) implements Tool {

    @Override public String name() { return "list_files"; }

    @Override
    public ToolDefinition definition() {
        JsonNode params = mapper.valueToTree(java.util.Map.of(
                "type", "object",
                "properties", java.util.Map.of(
                        "directory", java.util.Map.of(
                                "type", "string",
                                "description", "The directory path to list contents of",
                                "default", "."
                        )
                )
        ));
        return new ToolDefinition(
                "function",
                "list_files",
                "List all files and directories in the specified directory path.",
                params
        );
    }

    @Override
    public String execute(String arguments) throws Exception {
        JsonNode args = mapper.readTree(arguments);
        String dir = args.path("directory").asText(".");

        Path target = Path.of(dir);
        if (!Files.exists(target)) {
            return "Error: Directory not found: " + dir;
        }
        if (!Files.isDirectory(target)) {
            return "Error: Not a directory: " + dir;
        }

        List<String> items = new ArrayList<>();
        try (Stream<Path> stream = Files.list(target)) {
            stream.sorted(Comparator.comparing(p -> p.getFileName().toString()))
                  .forEach(p -> {
                      String prefix = Files.isDirectory(p) ? "[dir]" : "[file]";
                      items.add(prefix + " " + p.getFileName());
                  });
        } catch (NoSuchFileException e) {
            return "Error: Directory not found: " + dir;
        }

        if (items.isEmpty()) {
            return "Directory " + dir + " is empty";
        }
        return String.join("\n", items);
    }
}
```

### Why Tools Return Strings Instead of Throwing

Notice the pattern:

```java
} catch (NoSuchFileException e) {
    return "Error: File not found: " + path;
}
```

We return a string with an error description rather than throwing. This is deliberate — tool results go back to the LLM. If `read_file` fails with "File not found", the LLM can try a different path. If we threw, the agent loop would need special handling to convert the exception to a tool result message. Keeping it as a string means every tool result, success or failure, follows the same path.

The `throws Exception` declaration is still useful for *unexpected* errors — JSON parse failures, programming bugs — that should bubble up and not be silently fed back to the model.

### Records as Tools

Each tool is a record. That has surprising mileage:

- **Free `equals`/`hashCode`** — Useful for unit tests.
- **One-line construction** — `new ReadFile(mapper)`.
- **Immutable by design** — A tool's only state is its dependencies (here, the shared `ObjectMapper`).
- **Pattern matching ready** — In Chapter 9 we'll match on tool types when rendering them.

## Making a Tool Call

Update `Main.java` to register tools and execute calls:

```java
package com.example.agents;

import com.example.agents.agent.Prompts;
import com.example.agents.agent.Registry;
import com.example.agents.api.Messages.InputItem;
import com.example.agents.api.Messages.OutputItem;
import com.example.agents.api.Messages.ResponsesRequest;
import com.example.agents.api.Messages.ResponsesResponse;
import com.example.agents.api.OpenAiClient;
import com.example.agents.tools.ListFiles;
import com.example.agents.tools.ReadFile;
import io.github.cdimascio.dotenv.Dotenv;

import java.util.List;

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

        ResponsesRequest req = new ResponsesRequest(
                "gpt-5-mini",
                Prompts.SYSTEM,
                List.of(InputItem.user("What files are in the current directory?")),
                registry.definitions(),
                null
        );

        ResponsesResponse resp = client.createResponse(req);

        if (resp.outputText() != null && !resp.outputText().isEmpty()) {
            System.out.println("Text: " + resp.outputText());
        }

        for (OutputItem item : resp.output()) {
            if (!"function_call".equals(item.type())) {
                continue;
            }
            System.out.println("Tool call: " + item.name() + "(" + item.arguments() + ")");
            String result = registry.execute(item.name(), item.arguments());
            if (result.length() > 200) {
                result = result.substring(0, 200) + "...";
            }
            System.out.println("Result: " + result);
        }
    }
}
```

Run it:

```bash
./gradlew run
```

You should see:

```
Tool call: list_files({"directory":"."})
Result: [dir] build
[file] build.gradle.kts
[file] settings.gradle.kts
[dir] src
...
```

The LLM chose `list_files`, we executed it, and got real filesystem results. But the LLM never saw those results — we need the agent loop for that.

## Summary

In this chapter you:

- Defined the `Tool` sealed interface for type-safe tool dispatch
- Built a `Registry` with `Map<String, Tool>` for dispatch by name
- Implemented `ReadFile` and `ListFiles` as records using `java.nio.file`
- Used a shared `ObjectMapper` for tool argument parsing
- Made your first tool call and execution

The LLM can select tools and we can execute them. In the next chapter, we'll build evaluations to test tool selection systematically.

---

**Next: [Chapter 3: Single-Turn Evaluations →](./03-single-turn-evals.md)**
