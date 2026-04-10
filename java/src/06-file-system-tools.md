# Chapter 6: File System Tools

## Read Isn't Enough

`ReadFile` and `ListFiles` get the agent looking at the world, but a coding agent needs to *change* it: create files, edit them, delete them, move them around. This chapter rounds out the file system toolkit and introduces the first tools that need human approval before running.

We'll add three tools:

- **`WriteFile`** — Create or overwrite a file. Requires approval.
- **`EditFile`** — Replace a substring inside a file. Requires approval.
- **`DeleteFile`** — Remove a file. Requires approval.

By the end, the agent can build and modify a small project on its own.

## WriteFile

Create `tools/WriteFile.java`:

```java
package com.example.agents.tools;

import com.example.agents.agent.Tool;
import com.example.agents.api.Messages.FunctionDefinition;
import com.example.agents.api.Messages.ToolDefinition;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

public record WriteFile(ObjectMapper mapper) implements Tool {

    @Override public String name() { return "write_file"; }

    // Writes can clobber data — always confirm with the user.
    @Override public boolean requiresApproval() { return true; }

    @Override
    public ToolDefinition definition() {
        JsonNode params = mapper.valueToTree(Map.of(
                "type", "object",
                "properties", Map.of(
                        "path",    Map.of("type", "string", "description", "The path of the file to write"),
                        "content", Map.of("type", "string", "description", "The content to write to the file")
                ),
                "required", List.of("path", "content")
        ));
        return new ToolDefinition("function", new FunctionDefinition(
                "write_file",
                "Write content to a file at the specified path. Creates the file if it doesn't exist, overwrites it if it does. Parent directories are created as needed.",
                params
        ));
    }

    @Override
    public String execute(String arguments) throws Exception {
        JsonNode args = mapper.readTree(arguments);
        String pathStr = args.path("path").asText("");
        String content = args.path("content").asText("");
        if (pathStr.isEmpty()) return "Error: missing 'path' argument";

        try {
            Path path = Path.of(pathStr);
            if (path.getParent() != null) {
                Files.createDirectories(path.getParent());
            }
            Files.writeString(path, content);
            return "Wrote " + content.length() + " bytes to " + pathStr;
        } catch (Exception e) {
            return "Error writing file: " + e.getMessage();
        }
    }
}
```

Two things matter here:

- **`Files.createDirectories` is idempotent** — Creates missing parents, no-ops if they already exist. The agent can write `docs/notes/today.md` without first calling some `make_dir` tool.
- **`requiresApproval()` returns `true`** — The agent loop in Chapter 4 already calls our approval predicate before running tools that opt in. The terminal UI in Chapter 9 will show the user a `[y/n]` prompt.

## EditFile

`WriteFile` is a sledgehammer — it replaces the whole file. For small edits the model would have to read the file, hold the entire content in its context, and rewrite it. That wastes tokens and is error-prone. `EditFile` lets the model say "find this exact substring, replace it with this other substring":

Create `tools/EditFile.java`:

```java
package com.example.agents.tools;

import com.example.agents.agent.Tool;
import com.example.agents.api.Messages.FunctionDefinition;
import com.example.agents.api.Messages.ToolDefinition;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

public record EditFile(ObjectMapper mapper) implements Tool {

    @Override public String name() { return "edit_file"; }
    @Override public boolean requiresApproval() { return true; }

    @Override
    public ToolDefinition definition() {
        JsonNode params = mapper.valueToTree(Map.of(
                "type", "object",
                "properties", Map.of(
                        "path",       Map.of("type", "string", "description", "The path to the file to edit"),
                        "old_string", Map.of("type", "string", "description", "The exact text to find. Must match exactly once."),
                        "new_string", Map.of("type", "string", "description", "The text to replace it with")
                ),
                "required", List.of("path", "old_string", "new_string")
        ));
        return new ToolDefinition("function", new FunctionDefinition(
                "edit_file",
                "Replace an exact substring in a file with new content. The old_string must appear exactly once in the file.",
                params
        ));
    }

    @Override
    public String execute(String arguments) throws Exception {
        JsonNode args = mapper.readTree(arguments);
        String pathStr = args.path("path").asText("");
        String oldString = args.path("old_string").asText("");
        String newString = args.path("new_string").asText("");
        if (pathStr.isEmpty() || oldString.isEmpty()) {
            return "Error: 'path' and 'old_string' are required";
        }

        Path path = Path.of(pathStr);
        String content;
        try {
            content = Files.readString(path);
        } catch (NoSuchFileException e) {
            return "Error: File not found: " + pathStr;
        }

        int count = countOccurrences(content, oldString);
        if (count == 0) {
            return "Error: old_string not found in " + pathStr;
        }
        if (count > 1) {
            return "Error: old_string appears " + count + " times in " + pathStr
                    + " — make it more specific so it matches exactly once";
        }

        String updated = content.replace(oldString, newString);
        Files.writeString(path, updated);
        return "Edited " + pathStr;
    }

    private static int countOccurrences(String haystack, String needle) {
        int count = 0;
        int idx = 0;
        while ((idx = haystack.indexOf(needle, idx)) != -1) {
            count++;
            idx += needle.length();
        }
        return count;
    }
}
```

The "must match exactly once" rule is the secret to making `EditFile` reliable. If the model tries to replace `public static void main` and there are two occurrences, we *refuse* and tell it to be more specific. That feedback loop is much more reliable than hoping the model picks the right occurrence.

We avoid `String.replaceFirst` because it interprets its first argument as a regex — exactly the kind of subtle bug you don't want when the model is generating the input.

## DeleteFile

Create `tools/DeleteFile.java`:

```java
package com.example.agents.tools;

import com.example.agents.agent.Tool;
import com.example.agents.api.Messages.FunctionDefinition;
import com.example.agents.api.Messages.ToolDefinition;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

public record DeleteFile(ObjectMapper mapper) implements Tool {

    @Override public String name() { return "delete_file"; }
    @Override public boolean requiresApproval() { return true; }

    @Override
    public ToolDefinition definition() {
        JsonNode params = mapper.valueToTree(Map.of(
                "type", "object",
                "properties", Map.of(
                        "path", Map.of("type", "string", "description", "The path of the file to delete")
                ),
                "required", List.of("path")
        ));
        return new ToolDefinition("function", new FunctionDefinition(
                "delete_file",
                "Delete a file at the specified path. Use with care — this is not reversible.",
                params
        ));
    }

    @Override
    public String execute(String arguments) throws Exception {
        JsonNode args = mapper.readTree(arguments);
        String pathStr = args.path("path").asText("");
        if (pathStr.isEmpty()) return "Error: missing 'path' argument";

        Path path = Path.of(pathStr);
        try {
            if (!Files.exists(path)) {
                return "Error: File not found: " + pathStr;
            }
            if (Files.isDirectory(path)) {
                return "Error: " + pathStr + " is a directory; this tool only deletes files";
            }
            Files.delete(path);
            return "Deleted " + pathStr;
        } catch (NoSuchFileException e) {
            return "Error: File not found: " + pathStr;
        } catch (Exception e) {
            return "Error deleting file: " + e.getMessage();
        }
    }
}
```

The directory check before deletion keeps the model from accidentally trying to remove a directory. Directory removal is a separate operation that we deliberately don't expose — too much blast radius for too little upside.

## Registering the New Tools

Update `Main.java`:

```java
Registry registry = new Registry();
registry.register(new ReadFile(mapper));
registry.register(new ListFiles(mapper));
registry.register(new WriteFile(mapper));
registry.register(new EditFile(mapper));
registry.register(new DeleteFile(mapper));
```

Try a prompt that exercises all of them:

```java
Message.user("Create a file hello.txt containing 'Hello, world!', then change 'world' to 'Java', then read the file back to confirm.")
```

Expected output (approval prompts skipped for now since we're passing the default `call -> true` predicate to `Agent.run`):

```
[tool] write_file({"path":"hello.txt","content":"Hello, world!"})
[result] Wrote 13 bytes to hello.txt
[tool] edit_file({"path":"hello.txt","old_string":"world","new_string":"Java"})
[result] Edited hello.txt
[tool] read_file({"path":"hello.txt"})
[result] Hello, Java!
The file now contains "Hello, Java!".
```

Three turns, three tools, all using only `java.nio.file`.

## A Note on Approval

Every write-side tool returns `true` from `requiresApproval()`. Right now `Agent.run(messages)` passes the default predicate `call -> true`, which says "approve everything." In Chapter 9 the terminal UI will pass a real predicate that pauses and asks the user. Until then, treat `requiresApproval` as **declarative metadata** the tool author writes once. It says "this is dangerous"; the loop and UI decide what to do with that information.

## Idiomatic Java in This Chapter

A handful of patterns deserve callouts:

- **`java.nio.file.Files`** — The modern file I/O API. Methods like `Files.readString`, `Files.writeString`, `Files.createDirectories`, and `Files.delete` cover almost everything you'd want without reaching for streams. Avoid `java.io.File` unless you need legacy API compatibility.
- **`Path.of(...)`** — The factory for `Path` instances. Cleaner than the older `Paths.get(...)`.
- **`String.replace` not `String.replaceFirst`** — `replace` does literal string replacement; `replaceFirst` and `replaceAll` interpret their first argument as a regex. For tool inputs the literal version is what you almost always want.
- **`NoSuchFileException` is checked** — Java forces us to either declare or catch it. Catching it lets us return a friendly string error to the LLM instead of throwing.

## Summary

In this chapter you:

- Added `WriteFile`, `EditFile`, and `DeleteFile` to the tool set
- Used `Files.createDirectories` to make `WriteFile` create parents
- Made `EditFile` reliable by enforcing exactly-one matches
- Marked all destructive tools with `requiresApproval() == true`
- Saw the agent compose write/edit/read into a working sequence

Next we'll add web search and start managing context length — once the agent is reading entire files and calling lots of tools, conversations get long fast.

---

**Next: [Chapter 7: Web Search & Context Management →](./07-web-search-context-management.md)**
