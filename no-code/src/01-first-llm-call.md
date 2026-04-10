# Chapter 1: Your First LLM Call

The smallest possible "AI program" is one that sends a question to a language model and prints the answer. No tools, no loop, no agent — just a single round-trip.

That's what you're going to build in this chapter, by handing a single prompt to your coding agent.

## What You're Building and Why

Three files:

1. A **project config** (`pyproject.toml`) — declares the project exists
2. A **dependencies list** (`requirements.txt`) — says which Python libraries to install
3. A **main script** (`src/main.py`) — sends one question to OpenAI and prints the response

Plus a `.env` file holding your OpenAI key.

Why bother with this if it's "just" one LLM call? Because every agent in the world starts here. The agent loop, tool calling, evals, and the terminal UI you'll add in later chapters are all wrappers around this one primitive: *ask a model, get an answer back*. Get this working and the rest of the book is incremental.

**Concept to understand before you read the prompt:** an LLM is a paid web service. Your code sends an HTTP request to OpenAI's servers with your question, OpenAI's servers run the model, and they send back the answer along with how many tokens it used. The OpenAI Python SDK is just a polite wrapper around that HTTP request.

## The Prompt

Open Claude Code (or your coding agent) inside your `agents-v2` folder. Paste this prompt as one block:

```
I'm building a Python CLI AI agent from scratch over the course of a book.
Please set up the absolute minimum project so I can make one LLM call to OpenAI.

Requirements:
1. Create a virtual environment using `python3 -m venv .venv` and explain how to activate it on macOS/Linux and Windows.
2. Create requirements.txt with these exact pinned versions or higher:
   - openai>=1.82.0
   - pydantic>=2.11.0
   - rich>=14.0.0
   - prompt-toolkit>=3.0.50
   - python-dotenv>=1.1.0
3. Create pyproject.toml declaring a package called "agi" version 1.0.0 requiring Python 3.11+.
4. Create a .gitignore that ignores .venv, __pycache__, .env, and *.pyc.
5. Create a .env file with a single line: OPENAI_API_KEY=replace-me
6. Create src/__init__.py (empty) and src/main.py.
   src/main.py should:
     - Load environment variables from .env using python-dotenv
     - Create an OpenAI client (it picks up OPENAI_API_KEY automatically)
     - Call client.chat.completions.create with model "gpt-5-mini"
     - Send a single user message: "What is an AI agent in one sentence?"
     - Print response.choices[0].message.content
7. After creating the files, install the dependencies into the venv with pip.
8. Tell me the exact command to run the script, and what I should see.

Do not add a system prompt yet. Do not add tools yet. Do not add streaming yet.
Keep main.py under 20 lines. I want this to be as small as possible.
```

Hit enter and let it run. The agent will create files, run pip install, and tell you the command to test it.

## What You Should See

When the agent finishes, your folder should look roughly like this:

```
agents-v2/
├── .env
├── .gitignore
├── .venv/
├── pyproject.toml
├── requirements.txt
└── src/
    ├── __init__.py
    └── main.py
```

`src/main.py` should be a tiny file — about 12–15 lines. It should import `os`, `dotenv`, and `openai`, call `load_dotenv()`, instantiate an `OpenAI` client, send one chat completion request, and print the result.

The agent should also have run `pip install -r requirements.txt` and output a confirmation that the packages are installed.

## How to Verify

First, replace `replace-me` in `.env` with your actual OpenAI key:

```bash
# Open .env in any editor and change:
# OPENAI_API_KEY=replace-me
# to:
# OPENAI_API_KEY=sk-...your-actual-key...
```

Then activate your virtual environment (the agent should have told you how — typically `source .venv/bin/activate` on Mac/Linux or `.venv\Scripts\activate` on Windows) and run:

```bash
python -m src.main
```

You should see something like:

```
An AI agent is an autonomous system that perceives its environment, makes decisions, and takes actions to achieve specific goals.
```

The exact wording will be different every time you run it — that's expected. LLMs are non-deterministic. As long as you get one English sentence describing an AI agent, you're done.

## If It Didn't Work

**`ModuleNotFoundError: No module named 'openai'`**
You're not in your virtual environment. Run `source .venv/bin/activate` (Mac/Linux) or `.venv\Scripts\activate` (Windows) and try again. Your terminal prompt should show `(.venv)` at the start.

**`openai.AuthenticationError: Incorrect API key provided`**
Your OpenAI key in `.env` is wrong, missing, or has whitespace around it. Re-copy from [platform.openai.com/api-keys](https://platform.openai.com/api-keys), make sure it starts with `sk-`, and there are no quotes or spaces.

**`openai.RateLimitError: You exceeded your current quota`**
You haven't added a payment method or you're out of credit. Go to [platform.openai.com/account/billing](https://platform.openai.com/account/billing).

**`Model 'gpt-5-mini' does not exist or you do not have access to it`**
This model name is what the rest of the book uses. If your OpenAI account doesn't have access yet, ask your coding agent: *"Change the model in src/main.py from gpt-5-mini to gpt-4o-mini."* Everything in the book will still work.

**The agent created a much bigger project than I asked for**
Tell it: *"This is too much. Delete everything except .env, .gitignore, requirements.txt, pyproject.toml, src/__init__.py, and src/main.py. Keep main.py under 20 lines."* Coding agents sometimes "help" by adding logging, error handling, or class wrappers. For learning, smaller is better.

## Reference Code

If you want to see what `src/main.py` should look like, here's the canonical version from the [Python edition](https://sivakarasala.github.io/building-ai-agents/python/01-intro-to-agents.html):

<details>
<summary>src/main.py (click to expand)</summary>

```python
import os
from dotenv import load_dotenv
from openai import OpenAI

load_dotenv()

client = OpenAI()

response = client.chat.completions.create(
    model="gpt-5-mini",
    messages=[
        {"role": "user", "content": "What is an AI agent in one sentence?"}
    ],
)

print(response.choices[0].message.content)
```
</details>

Your version may look slightly different — different variable names, an extra blank line here or there. As long as the verification step works, you're fine.

## What You Just Learned About Agents

You just shipped the simplest possible LLM application: input → model → output. No memory, no tools, no loop. It cost a fraction of a cent and took one round-trip to OpenAI's servers.

Three things to internalize from this:

**1. The model is a function.** Despite all the hype, an LLM API call is conceptually `output = model(input)`. Everything else — tools, streaming, agents, RAG — is what you build *around* that function. When someone says "we built an AI feature," 80% of the time they built something with this one primitive at the center.

**2. Determinism is gone.** You ran the same code twice and got two different answers. Every product decision around AI has to account for this. Tests, evals, and user-facing copy all have to assume the model will sometimes say something different.

**3. You paid for that.** Look at your OpenAI usage dashboard. That call cost a fraction of a cent. Now imagine 10 million users hitting it. Cost is a first-class product concern with LLM features in a way it isn't with traditional software, where compute is essentially free.

In Chapter 2, you'll teach this same primitive to use **tools** — and that's where it stops being a chatbot and starts being an agent.

---

**Next: [Chapter 2: Tool Calling →](./02-tool-calling.md)**
