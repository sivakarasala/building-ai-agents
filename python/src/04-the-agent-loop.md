# Chapter 4: The Agent Loop

## The Heart of an Agent

This is the most important chapter in the book. Everything before this was setup. Everything after builds on this.

The agent loop is what transforms a language model from a question-answering machine into an autonomous agent. Here's the pattern:

```
while True:
  1. Send messages to LLM (with tools)
  2. Stream the response
  3. If LLM wants to call tools:
     a. Execute each tool
     b. Add results to message history
     c. Continue the loop
  4. If LLM is done (no tool calls):
     a. Break out of the loop
     b. Return the final response
```

The LLM decides when to stop. It might call one tool, process the result, call another, and then respond with text. Or it might call three tools in one turn, process all results, and respond. The loop keeps going until the LLM says "I'm done — here's my answer."

## Streaming vs. Blocking

In Chapter 2, we used `client.chat.completions.create()` which waits for the complete response before returning. That's fine for evals, but terrible for UX. Users want to see tokens appear in real-time.

With `stream=True`, the SDK returns an iterator that yields chunks as they arrive:

```python
stream = client.chat.completions.create(
    model="gpt-5-mini",
    messages=messages,
    tools=tools,
    stream=True,
)

for chunk in stream:
    delta = chunk.choices[0].delta
    if delta.content:
        # A piece of text arrived
        print(delta.content, end="", flush=True)
    if delta.tool_calls:
        # The LLM wants to call a tool
        for tc in delta.tool_calls:
            print(f"Tool: {tc.function.name}")
```

Streaming with tool calls is trickier than plain text streaming. Tool calls arrive in pieces — the function name comes first, then the arguments arrive incrementally as JSON fragments. We need to accumulate these fragments and parse them when complete.

## Building the Agent Loop

Create `src/agent/run.py`:

```python
import json
from typing import Any
from openai import OpenAI
from dotenv import load_dotenv

from src.agent.tools import ALL_TOOLS, TOOL_EXECUTORS
from src.agent.execute_tool import execute_tool
from src.agent.system.prompt import SYSTEM_PROMPT
from src.types import AgentCallbacks, ToolCallInfo

load_dotenv()

client = OpenAI()
MODEL_NAME = "gpt-5-mini"


def run_agent(
    user_message: str,
    conversation_history: list[dict[str, Any]],
    callbacks: AgentCallbacks,
) -> list[dict[str, Any]]:
    """Run the agent loop. Returns the updated message history."""

    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        *conversation_history,
        {"role": "user", "content": user_message},
    ]

    full_response = ""

    while True:
        stream = client.chat.completions.create(
            model=MODEL_NAME,
            messages=messages,
            tools=ALL_TOOLS if ALL_TOOLS else None,
            stream=True,
        )

        # Accumulate the streamed response
        current_text = ""
        tool_calls_data: dict[int, dict[str, Any]] = {}
        current_role = "assistant"

        for chunk in stream:
            choice = chunk.choices[0]
            delta = choice.delta

            # Accumulate text content
            if delta.content:
                current_text += delta.content
                callbacks.on_token(delta.content)

            # Accumulate tool calls (they arrive in fragments)
            if delta.tool_calls:
                for tc_delta in delta.tool_calls:
                    idx = tc_delta.index

                    if idx not in tool_calls_data:
                        tool_calls_data[idx] = {
                            "id": "",
                            "name": "",
                            "arguments": "",
                        }

                    if tc_delta.id:
                        tool_calls_data[idx]["id"] = tc_delta.id
                    if tc_delta.function:
                        if tc_delta.function.name:
                            tool_calls_data[idx]["name"] = tc_delta.function.name
                        if tc_delta.function.arguments:
                            tool_calls_data[idx]["arguments"] += (
                                tc_delta.function.arguments
                            )

            # Check for finish reason
            if choice.finish_reason:
                finish_reason = choice.finish_reason

        full_response += current_text

        # Build tool calls list
        tool_calls: list[ToolCallInfo] = []
        for idx in sorted(tool_calls_data.keys()):
            tc_data = tool_calls_data[idx]
            try:
                args = json.loads(tc_data["arguments"]) if tc_data["arguments"] else {}
            except json.JSONDecodeError:
                args = {}

            tool_calls.append(
                ToolCallInfo(
                    tool_call_id=tc_data["id"],
                    tool_name=tc_data["name"],
                    args=args,
                )
            )
            callbacks.on_tool_call_start(tc_data["name"], args)

        # If no tool calls, we're done
        if finish_reason != "tool_calls" or not tool_calls:
            # Add the assistant's text response to history
            messages.append({"role": "assistant", "content": current_text or ""})
            break

        # Add the assistant message with tool calls to history
        assistant_message: dict[str, Any] = {
            "role": "assistant",
            "content": current_text or None,
            "tool_calls": [
                {
                    "id": tc.tool_call_id,
                    "type": "function",
                    "function": {
                        "name": tc.tool_name,
                        "arguments": json.dumps(tc.args),
                    },
                }
                for tc in tool_calls
            ],
        }
        messages.append(assistant_message)

        # Execute each tool and add results to message history
        import asyncio

        rejected = False
        for tc in tool_calls:
            # Check for approval
            approved = asyncio.get_event_loop().run_until_complete(
                callbacks.on_tool_approval(tc.tool_name, tc.args)
            )

            if not approved:
                rejected = True
                break

            result = execute_tool(tc.tool_name, tc.args)
            callbacks.on_tool_call_end(tc.tool_name, result)

            messages.append({
                "role": "tool",
                "tool_call_id": tc.tool_call_id,
                "content": result,
            })

        if rejected:
            break

    callbacks.on_complete(full_response)
    return messages
```

Let's walk through this step by step.

### Function Signature

```python
def run_agent(
    user_message: str,
    conversation_history: list[dict[str, Any]],
    callbacks: AgentCallbacks,
) -> list[dict[str, Any]]:
```

The function takes:
- **`user_message`** — The latest message from the user
- **`conversation_history`** — All previous messages (for multi-turn conversations)
- **`callbacks`** — Functions to notify the UI about streaming tokens, tool calls, etc.

It returns the updated message history, which the caller stores for the next turn.

### Streaming Tool Call Accumulation

This is the trickiest part. When the LLM calls a tool, the data arrives in fragments:

```
Chunk 1: tool_calls[0].id = "call_abc123"
Chunk 2: tool_calls[0].function.name = "list_files"
Chunk 3: tool_calls[0].function.arguments = '{"dir'
Chunk 4: tool_calls[0].function.arguments = 'ectory":'
Chunk 5: tool_calls[0].function.arguments = ' "."}'
```

We use a dict indexed by `tc_delta.index` to accumulate each tool call's fragments. The `id` and `name` come once, but `arguments` is concatenated from multiple chunks.

After streaming completes, we parse the accumulated JSON arguments and build `ToolCallInfo` objects.

### The Message Format

OpenAI's API requires a specific message format for tool calls:

```python
# Assistant message requesting tool calls
{
    "role": "assistant",
    "content": null,
    "tool_calls": [
        {
            "id": "call_abc123",
            "type": "function",
            "function": {
                "name": "list_files",
                "arguments": '{"directory": "."}'
            }
        }
    ]
}

# Tool result message
{
    "role": "tool",
    "tool_call_id": "call_abc123",
    "content": "[dir] src\n[file] README.md"
}
```

The `tool_call_id` links the result back to the request. Without it, the LLM can't match results to requests.

### The Loop

```python
while True:
    stream = client.chat.completions.create(...)
    # ... process stream ...

    if finish_reason != "tool_calls" or not tool_calls:
        break  # LLM is done

    # Execute tools, add results to messages, loop again
```

Each iteration:
1. Sends the current messages to the LLM
2. Streams the response, collecting text and tool calls
3. Checks the `finish_reason`:
   - `"tool_calls"` → The LLM wants tools executed. Do it and loop.
   - Anything else (`"stop"`, `"length"`, etc.) → The LLM is done. Break.

## Testing the Loop

Let's test with a simple script. Update `src/main.py`:

```python
import asyncio
from dotenv import load_dotenv
from src.agent.run import run_agent
from src.types import AgentCallbacks

load_dotenv()


async def approve_all(name: str, args) -> bool:
    return True


history: list = []

result = run_agent(
    "What files are in the current directory? Then read the pyproject.toml file.",
    history,
    AgentCallbacks(
        on_token=lambda token: print(token, end="", flush=True),
        on_tool_call_start=lambda name, args: print(f"\n[Tool] {name} {args}"),
        on_tool_call_end=lambda name, result: print(
            f"[Result] {name}: {result[:100]}..."
        ),
        on_complete=lambda response: print("\n[Done]"),
        on_tool_approval=approve_all,
    ),
)

print(f"\nTotal messages: {len(result)}")
```

Run it:

```bash
python -m src.main
```

You should see the agent:
1. Call `list_files` to see the directory contents
2. Call `read_file` to read `pyproject.toml`
3. Respond with a summary of what it found

That's the loop in action. The LLM made two tool calls across potentially multiple loop iterations, got the results, and synthesized a coherent response.

## The Message History

After the loop, the messages list looks something like:

```
[system]    "You are a helpful AI assistant..."
[user]      "What files are in the current directory? Then read..."
[assistant] (tool call: list_files)
[tool]      "[dir] src\n[file] pyproject.toml..."
[assistant] (tool call: read_file)
[tool]      "[project]\nname = 'agi'..."
[assistant] "Your project has the following files... The pyproject.toml shows..."
```

This is the full conversation history. The LLM sees all of it on each iteration, which is how it maintains context. This is also why context management (Chapter 7) becomes important — this history grows with every interaction.

## Summary

In this chapter you:

- Built the core agent loop with streaming
- Handled the complexity of accumulating fragmented tool calls from the stream
- Understood the OpenAI message format for tool calls and results
- Used callbacks to decouple agent logic from UI
- Added error handling and tool approval hooks

This is the engine of the agent. Everything else — more tools, context management, human approval — plugs into this loop. In the next chapter, we'll build multi-turn evaluations to test the full loop.

---

**Next: [Chapter 5: Multi-Turn Evaluations →](./05-multi-turn-evals.md)**
