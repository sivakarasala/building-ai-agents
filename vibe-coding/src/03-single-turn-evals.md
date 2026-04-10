# Chapter 3: Single-Turn Evaluations

This is the chapter that turns your project from "I built a thing once and it worked" into "I have a way to know if it still works tomorrow."

If you remember one chapter from this book by name, make it this one. Evals are the single most underrated part of building AI products, and they're the topic non-engineers most need to understand to be useful in agent conversations at work.

## What You're Building and Why

In Chapter 2, you saw the LLM correctly call `list_files` when you asked "what files are in the current directory?". Great. But what about:

- "show me what's in the project"
- "I want to read README.md"
- "what is the capital of France?" *(should NOT call any tool)*
- "tell me a joke" *(should also NOT call any tool)*

Will the LLM pick the right tool — or no tool — every single time? You don't actually know. You ran *one* test. You'd need to type each prompt manually, eyeball the output, and remember whether it was right.

That doesn't scale. Worse, every time you tweak a tool description, change the system prompt, or upgrade the model, all of your previous "yeah it worked" evidence becomes obsolete.

**Evals are an automated test runner for LLM behavior.** You write a list of test cases that look like:

```
prompt: "Read the contents of README.md"
expected: the LLM should call read_file
```

…and a script runs all of them and tells you what pass-rate you got. That's the entire concept.

In this chapter you'll build:

1. **A test dataset** — a JSON file with prompts and expectations
2. **An executor** — code that sends a prompt to the LLM and records which tool it picked (without actually running the tool)
3. **Evaluators** — three small scoring functions for three test categories
4. **A runner script** — prints pass/fail for each test and an overall score

The three test categories are:

| Category | Meaning | Example |
|---|---|---|
| **Golden** | The LLM MUST pick this exact tool | "Read README.md" → must pick `read_file` |
| **Secondary** | Ambiguous; LLM SHOULD pick a reasonable tool | "Show me the project" → probably `list_files` |
| **Negative** | The LLM MUST NOT pick any of these tools | "What's 2+2?" → must not call any file tool |

## The Prompt

In Claude Code, paste this:

```
Continuing the agent build. I want to add single-turn evaluations for tool
selection. We are NOT executing tools or building an agent loop. We are just
checking which tool the LLM picks for each test prompt.

Please make these changes:

1. First, expose FILE_TOOLS in src/agent/tools/__init__.py:
     FILE_TOOLS = [READ_FILE_TOOL, LIST_FILES_TOOL]
   (Plus the existing ALL_TOOLS and TOOL_EXECUTORS — keep those.)

2. Create the evals package: evals/__init__.py (empty), evals/data/.

3. Create evals/types.py with three dataclasses:
     - EvalData(prompt: str, tools: list[str], system_prompt: Optional[str] = None)
     - EvalTarget(category: str, expected_tools: Optional[list[str]] = None,
                  forbidden_tools: Optional[list[str]] = None)
       category is one of "golden", "secondary", "negative".
     - SingleTurnResult(tool_calls: list[dict], tool_names: list[str],
                        selected_any: bool)

4. Create evals/utils.py with one function build_messages(data: dict) that
   returns [{"role": "system", "content": SYSTEM_PROMPT or override},
             {"role": "user", "content": data["prompt"]}].
   Import SYSTEM_PROMPT from src.agent.system.prompt.

5. Create evals/executors.py with single_turn_executor(data: dict,
   available_tools: list[dict]) -> SingleTurnResult. It must:
     - Build messages from data
     - Filter available_tools to only those whose name is in data["tools"]
     - Call client.chat.completions.create with model "gpt-5-mini",
       messages, and tools (or None if empty)
     - Parse message.tool_calls into tool_calls (list of {tool_name, args})
       and tool_names (list of strings)
     - Return SingleTurnResult
   Use a module-level OpenAI() client.
   IMPORTANT: do NOT execute the tools. We only want which tool was selected.

6. Create evals/evaluators.py with three functions:
     - tools_selected(output, target) -> float
         Returns 1.0 if every tool in target.expected_tools appears in
         output.tool_names, else 0.0. If expected_tools is None/empty, return 1.0.
     - tools_avoided(output, target) -> float
         Returns 1.0 if NONE of target.forbidden_tools appears in
         output.tool_names, else 0.0. If forbidden_tools is None/empty, return 1.0.
     - tool_selection_score(output, target) -> float
         F1 score (precision + recall harmonic mean) of selected vs expected.
         Used for "secondary" category.

7. Create evals/data/file_tools.json with at least 5 test cases covering:
     - 2 golden cases (read_file and list_files specifically)
     - 1 secondary case (ambiguous prompt that should still pick a file tool)
     - 2 negative cases ("what is the capital of France?", "tell me a joke")
   Each case has shape:
     { "data": { "prompt": "...", "tools": ["read_file","write_file","list_files","delete_file"] },
       "target": { "category": "golden", "expected_tools": ["read_file"] } }
   For negative cases use forbidden_tools instead of expected_tools.
   Note: include "write_file" and "delete_file" in the available tools list
   even though we haven't built them yet — the evaluator only filters the
   ones that actually exist in FILE_TOOLS, so it's fine.

8. Create evals/file_tools_eval.py that:
     - Loads .env
     - Loads evals/data/file_tools.json
     - For each entry: builds an EvalTarget, calls single_turn_executor with
       FILE_TOOLS, and runs the right evaluator based on target.category
       (tools_selected for golden, tools_avoided for negative,
        tool_selection_score for secondary)
     - Prints a checkmark or X, the prompt, the selected tools, and the score
     - Prints an overall average at the end

9. Tell me the exact command to run the eval.

Do NOT integrate Laminar yet. Do NOT add multi-turn or LLM-as-judge. Pure
single-turn tool selection with local pass/fail.
```

## What You Should See

Your project should now have an `evals/` directory next to `src/`:

```
agents-v2/
├── src/
│   └── ...
└── evals/
    ├── __init__.py
    ├── types.py
    ├── utils.py
    ├── executors.py
    ├── evaluators.py
    ├── file_tools_eval.py
    └── data/
        └── file_tools.json
```

`file_tools.json` should have at least 5 entries. Open it and read it — it's just a list of `{data, target}` objects in plain English. This is the most important artifact in the chapter. It's the document you'd hand to a non-engineer stakeholder when they ask "how do you know your agent works?"

## How to Verify

Activate your venv and run:

```bash
python -m evals.file_tools_eval
```

You should see output like:

```
File Tools Evaluation
========================================
  ✓ [golden] Read the contents of README.md
    Selected: ['read_file']
    Scores: {'tools_selected': 1.0}

  ✓ [golden] What files are in the src directory?
    Selected: ['list_files']
    Scores: {'tools_selected': 1.0}

  ✓ [secondary] Show me what's in the project
    Selected: ['list_files']
    Scores: {'selection_score': 1.0}

  ✓ [negative] What is the capital of France?
    Selected: []
    Scores: {'tools_avoided': 1.0}

  ✓ [negative] Tell me a joke
    Selected: []
    Scores: {'tools_avoided': 1.0}

Average score: 1.00
```

Two things to check:

1. **Each test case has a checkmark.**
2. **The average score is at or near 1.00.**

If you see one or two failures, that's actually *good* — it means your eval is detecting real LLM unreliability. Read the failure carefully. Often you'll find the prompt was genuinely ambiguous, or the tool description needs tightening. Both are valid fixes.

Now do something interesting: change the description of `read_file` in `src/agent/tools/file.py` to something vague like `"A tool for files."` and re-run the eval. Watch what happens. (Then change it back.)

## If It Didn't Work

**`ModuleNotFoundError: No module named 'evals'`**
You're running it from the wrong place, or `evals/__init__.py` is missing. Make sure you're in the project root (`agents-v2/`) and that `evals/__init__.py` exists. Run `ls evals/__init__.py` to verify.

**`ImportError: cannot import name 'FILE_TOOLS' from 'src.agent.tools'`**
Step 1 of the prompt didn't get applied. Tell your coding agent: *"You forgot to add FILE_TOOLS to src/agent/tools/__init__.py. Please add it."*

**All my golden cases fail with `Selected: []`**
The LLM decided not to call any tool. Usually this means your tool descriptions are too vague. Tell the agent: *"My golden eval cases are failing because the LLM isn't calling any tool. Sharpen the descriptions in src/agent/tools/file.py to be more specific about when each tool should be used."*

**One specific golden case fails consistently**
The prompt in your test case is genuinely ambiguous, OR the tool descriptions are confusable. Re-read the prompt and ask yourself: *if I were the LLM, would I be sure?* Either rewrite the prompt to be more specific, or improve the descriptions.

**The negative cases fail — the LLM calls a tool when asked about France**
This happens with weaker models. It means the tool descriptions are over-broad. They sound like "use me for any question," and the LLM takes that literally. Tighten the descriptions.

**Different runs give different pass rates**
Yes — LLMs are non-deterministic. This is why a single run isn't proof of anything. Mature eval setups run each case multiple times and report a *rate* (e.g., "passes 9/10 runs"). For this chapter, one clean run is enough; you'll see the rate-based version when you read [AI Engineering](https://www.amazon.com/AI-Engineering-Building-Applications-Foundation/dp/1098166302) (recommended in Chapter 10).

## Reference Code

<details>
<summary>evals/data/file_tools.json (click to expand)</summary>

```json
[
  {
    "data": {
      "prompt": "Read the contents of README.md",
      "tools": ["read_file", "write_file", "list_files", "delete_file"]
    },
    "target": {
      "expected_tools": ["read_file"],
      "category": "golden"
    }
  },
  {
    "data": {
      "prompt": "What files are in the src directory?",
      "tools": ["read_file", "write_file", "list_files", "delete_file"]
    },
    "target": {
      "expected_tools": ["list_files"],
      "category": "golden"
    }
  },
  {
    "data": {
      "prompt": "Show me what's in the project",
      "tools": ["read_file", "write_file", "list_files", "delete_file"]
    },
    "target": {
      "expected_tools": ["list_files"],
      "category": "secondary"
    }
  },
  {
    "data": {
      "prompt": "What is the capital of France?",
      "tools": ["read_file", "write_file", "list_files", "delete_file"]
    },
    "target": {
      "forbidden_tools": ["read_file", "write_file", "list_files", "delete_file"],
      "category": "negative"
    }
  },
  {
    "data": {
      "prompt": "Tell me a joke",
      "tools": ["read_file", "write_file", "list_files", "delete_file"]
    },
    "target": {
      "forbidden_tools": ["read_file", "write_file", "list_files", "delete_file"],
      "category": "negative"
    }
  }
]
```
</details>

The full canonical version of all the eval modules is in the [Python edition Chapter 3](https://sivakarasala.github.io/building-ai-agents/python/03-single-turn-evals.html).

## What You Just Learned About Agents

This is the chapter with the highest leverage for product roles. Three takeaways.

**1. Evals are your contract with reality.** Every team building AI features should have an answer to: *"How do you know it works?"* If the answer is "we tried it and it seemed good," the team has no eval discipline. If the answer is "we have N test cases across golden/secondary/negative categories and we're at 94% pass rate, with the 6% failures triaged by category," the team is shipping responsibly. As a PM, the most valuable single question you can ask of your AI engineering team is: *"can I see the eval set?"* If they don't have one, that's the product risk to escalate. Not "can it do X?" but "how do you measure whether it does X reliably?"

**2. There are three flavors of correctness.** The golden / secondary / negative split is not just an implementation detail — it's how you should *think* about every AI feature.
- **Golden:** the things it absolutely must get right. ("When the user says 'cancel my subscription,' it must trigger the cancellation flow.")
- **Secondary:** the things where reasonable behavior is acceptable. ("When the user says 'I want to leave,' it should *probably* offer cancellation, but offering retention is fine too.")
- **Negative:** the things it must never do. ("When the user says 'tell me a joke,' it must not start a refund.")
- The eval set should explicitly include all three. Most teams only test the goldens. The negatives are where the lawsuits come from.

**3. Test data is more important than test code.** Look at the eval framework you just built. It's about 100 lines of code. The actual *value* lives in `file_tools.json` — the list of prompts and expected behaviors. When you upgrade your model from GPT-5-mini to GPT-6-mini, that JSON file is what tells you whether the upgrade is safe. The code is a runner; the data is the asset. Treat it as a first-class artifact: version it, review changes to it, and grow it whenever you discover a new failure mode in production. *"Every bug report becomes an eval case"* is a habit worth pushing your engineering team to adopt.

You now have the three pillars of every agent: a model call, tool definitions, and a way to verify behavior. The next six chapters add capability — the loop, more tools, web search, context management, and the human-in-the-loop UI. But the architecture you've already built is the load-bearing wall. Everything from here is decoration.

---

Congratulations — you've built and tested the foundation of an AI agent without writing a line of code yourself. The remaining chapters of this book follow the same prompt-driven format. When you're ready, continue to the [Python edition](https://sivakarasala.github.io/building-ai-agents/python/) for the canonical walkthrough of Chapters 4–10 — or, when this vibe-coding edition expands, come back here.
