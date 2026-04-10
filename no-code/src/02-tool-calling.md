# Chapter 2: Tool Calling

This is the chapter where your program stops being a chatbot and starts being an agent.

## What You're Building and Why

In Chapter 1, you sent a question and got an answer. The model couldn't *do* anything — it could only talk about doing things.

In this chapter, you'll teach the model two **tools**:

- `read_file(path)` — read the contents of a file
- `list_files(directory)` — list what's in a folder

You won't write a loop yet, and the model won't actually call the tools and see the results — that's Chapter 4. What you *will* do is hand the model a list of available tools and watch it choose the right one.

**The single most important concept in this chapter:** the LLM does not run your tools. It outputs structured JSON saying *"please call `list_files` with directory `.`"*. Your code reads that JSON and decides whether to actually run anything. The LLM is the brain. Your code is the hands. This separation is what makes agents safe to operate — your code is always the gatekeeper.

By the end of this chapter, when you ask the model "what files are in this folder?", instead of saying "I can't see your files," it'll output a tool call. That's the moment it stops being a chatbot.

## The Prompt

In the same Claude Code session, paste this:

```
Continuing the agent build. I want to add tool calling — defining two file
tools and showing they get selected by the LLM. We are NOT building the agent
loop yet. We just want to see the LLM pick a tool.

Please make these changes:

1. Create src/agent/system/__init__.py (empty) and src/agent/system/prompt.py
   containing a SYSTEM_PROMPT constant. Make it short — about 5 lines —
   describing a helpful AI assistant that's direct, honest, and stays focused.

2. Create src/agent/__init__.py (empty), src/agent/tools/__init__.py, and
   src/agent/tools/file.py.

3. In src/agent/tools/file.py define:
     - read_file_execute(args: dict) -> str  that opens args["path"] and
       returns its contents. On FileNotFoundError return a clear error string.
       On any other Exception return "Error reading file: <message>".
     - list_files_execute(args: dict) -> str  that lists args.get("directory", ".")
       and returns one entry per line. Prefix directories with "[dir] " and
       files with "[file] ". Sort alphabetically. Handle FileNotFoundError and
       generic Exception with clear strings.
     - READ_FILE_TOOL — an OpenAI-format tool definition with type "function",
       name "read_file", a description that tells the LLM exactly when to use
       it, and a single required string parameter "path".
     - LIST_FILES_TOOL — same shape, name "list_files", a single string
       parameter "directory" with default "." and NOT required.

4. In src/agent/tools/__init__.py expose:
     - ALL_TOOLS = [READ_FILE_TOOL, LIST_FILES_TOOL]
     - TOOL_EXECUTORS = {"read_file": read_file_execute,
                         "list_files": list_files_execute}

5. Create src/agent/execute_tool.py with one function:
     execute_tool(name: str, args: dict) -> str
   that looks up the executor in TOOL_EXECUTORS, runs it, and returns the
   string. If the tool name is unknown, return "Unknown tool: <name>".
   Catch exceptions during execution and return "Error executing <name>: <e>".

6. Update src/main.py so it:
     - Loads .env
     - Imports SYSTEM_PROMPT and ALL_TOOLS
     - Calls client.chat.completions.create with model "gpt-5-mini",
       messages = [system, user], where the user message is
       "What files are in the current directory?"
     - Passes tools=ALL_TOOLS
     - Prints message.content (which will likely be None)
     - Prints any tool calls as JSON: name + parsed arguments

Do NOT add an agent loop. Do NOT execute the tool result. We just want to see
that the LLM responds with a tool call instead of text.

Important: tool descriptions matter a lot. Make them specific about WHAT the
tool does and WHEN to use it — not just "file tool".
```

## What You Should See

After the agent finishes, your project should look like:

```
agents-v2/
├── .env
├── .gitignore
├── pyproject.toml
├── requirements.txt
├── src/
│   ├── __init__.py
│   ├── main.py
│   └── agent/
│       ├── __init__.py
│       ├── execute_tool.py
│       ├── system/
│       │   ├── __init__.py
│       │   └── prompt.py
│       └── tools/
│           ├── __init__.py
│           └── file.py
```

`src/agent/tools/file.py` should have two `_execute` functions and two `_TOOL` dictionaries. The dictionaries follow OpenAI's tool format — you'll see keys like `type`, `function`, `name`, `description`, `parameters`.

`src/main.py` should be a bit longer than Chapter 1 — maybe 25–30 lines now — because it imports the tools and prints both `content` and `tool_calls`.

## How to Verify

Activate your venv and run:

```bash
python -m src.main
```

You should see something like:

```
Text: None
Tool calls: [
  {
    "name": "list_files",
    "args": {
      "directory": "."
    }
  }
]
```

The two things to check:

1. **`Text` is `None` (or empty)** — the LLM did not respond with prose. It chose to call a tool instead.
2. **`Tool calls` has exactly one entry, and it's `list_files`** — the LLM picked the right tool for the question.

If both of those are true, tool calling is working. The LLM has *understood* that to answer "what files are in the current directory?" it needs to call a tool, and it has *chosen* the correct one of the two you offered.

Try asking it to read a specific file too. Edit the user message in `src/main.py` to:

```python
{"role": "user", "content": "What does the file pyproject.toml contain?"}
```

…and run again. You should now see a `read_file` call with `{"path": "pyproject.toml"}`.

## If It Didn't Work

**`Text` is not `None` — the LLM responded with prose like "I can't access your files."**
The tool descriptions are probably weak. Tell your coding agent: *"The LLM is responding with text instead of calling a tool. Make the descriptions in READ_FILE_TOOL and LIST_FILES_TOOL more specific about what they do and when to use them."* Good descriptions trigger tool use; vague ones don't.

**It calls the wrong tool (e.g., `read_file` when the question was about listing).**
Same fix — sharper descriptions. Each description should make it obvious when *not* to use it. You can also tell the agent: *"The LLM picks read_file when I ask about listing. Update the descriptions so they're clearly distinct."*

**`KeyError: 'path'` or similar when the agent tries to actually run the tool.**
Don't worry about this in this chapter. We're not executing tools yet. You should only be printing the tool call, not running it. If your `main.py` is trying to execute the tool, tell the coding agent: *"Don't execute the tool. Just print the tool call. We'll add execution in the agent loop chapter."*

**It calls multiple tools at once.**
Some models will call several tools in parallel. That's fine and expected behavior — the API supports it. Just print all of them.

**`ImportError` after the changes.**
Your coding agent forgot to add an `__init__.py` somewhere. Run:

```bash
find src -type d
```

…and tell the agent: *"There's an ImportError. Make sure every folder under src/ has an __init__.py."*

## Reference Code

<details>
<summary>src/agent/tools/file.py (click to expand)</summary>

```python
import os
from typing import Any


def read_file_execute(args: dict[str, Any]) -> str:
    file_path = args["path"]
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return f"Error: File not found: {file_path}"
    except Exception as e:
        return f"Error reading file: {e}"


def list_files_execute(args: dict[str, Any]) -> str:
    directory = args.get("directory", ".")
    try:
        entries = os.listdir(directory)
        items = []
        for entry in sorted(entries):
            full_path = os.path.join(directory, entry)
            entry_type = "[dir]" if os.path.isdir(full_path) else "[file]"
            items.append(f"{entry_type} {entry}")
        return "\n".join(items) if items else f"Directory {directory} is empty"
    except FileNotFoundError:
        return f"Error: Directory not found: {directory}"
    except Exception as e:
        return f"Error listing directory: {e}"


READ_FILE_TOOL = {
    "type": "function",
    "function": {
        "name": "read_file",
        "description": "Read the contents of a file at the specified path. Use this to examine file contents.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "The path to the file to read",
                }
            },
            "required": ["path"],
        },
    },
}

LIST_FILES_TOOL = {
    "type": "function",
    "function": {
        "name": "list_files",
        "description": "List all files and directories in the specified directory path.",
        "parameters": {
            "type": "object",
            "properties": {
                "directory": {
                    "type": "string",
                    "description": "The directory path to list contents of",
                    "default": ".",
                }
            },
        },
    },
}
```
</details>

The full canonical version (with the registry and dispatcher) is in the [Python edition Chapter 2](https://sivakarasala.github.io/building-ai-agents/python/02-tool-calling.html).

## What You Just Learned About Agents

Three takeaways, in priority order.

**1. The LLM is a planner. Your code is the executor.** The most important architectural fact about agents is this separation. The LLM never touches your file system, your database, your API. It outputs structured JSON saying what it *wants* to do. Your code decides whether to actually do it. This is why you can build safe agents on top of unsafe-sounding capabilities like "run shell commands": you control the execution layer, and you can refuse, modify, or audit any tool call before it runs. You'll feel this directly in Chapter 9 when you add a "yes/no" approval prompt for dangerous operations.

**2. Tool descriptions are product copy.** The single most underrated skill in building agents is writing tool descriptions. They're not documentation for humans — they're prompts for the LLM that determine whether your tools get used at all. A tool with a vague description ("file utility") will be ignored. A tool with a sharp description ("Read the contents of a file at the specified path. Use this to examine file contents.") will be picked correctly. When your engineering team is building agents, ask to see the tool descriptions. They tell you more about reliability than the code.

**3. The LLM can fail the *task* even when the *call* is perfect.** Your model might pick the wrong tool, hallucinate a parameter, or call a tool when it should have just answered with text. There is no compiler that catches this. The only way to know if your agent reliably picks the right tool is to **test** it on lots of inputs. That's what Chapter 3 is about — building an automated test harness for tool selection. It's the most "engineering-y" chapter in the book, and it's the one that separates demo agents from production agents.

---

**Next: [Chapter 3: Single-Turn Evaluations →](./03-single-turn-evals.md)**
