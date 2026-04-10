# Building AI Agents Without Writing Code

A hands-on guide for product managers, product owners, designers, analysts, and anyone else who wants to *understand* AI agents by building one — without learning a programming language first.

> Inspired by and adapted from [Hendrixer/agents-v2](https://github.com/Hendrixer/agents-v2) and the [AI Agents v2 course on Frontend Masters](https://frontendmasters.com/courses/ai-agents-v2/) by Scott Moss. The original course builds the agent in TypeScript; this edition reimagines the same architecture as a series of prompts you give to a coding agent.

---

## Who This Book Is For

If you've ever:

- Sat in a meeting where engineers debated "tool calling vs. function calling" and felt lost,
- Read a blog post about AI agents and wanted to *actually try one* but stopped at "open your terminal,"
- Built a Notion doc full of agent ideas but had no way to validate them,
- Wanted to understand what your engineering team is shipping when they say "we built an agent,"

…this book is for you.

You don't need to know Python. You don't need to have written a line of code. You don't need to understand what an API is (yet).

You **do** need:

- A computer (Mac, Windows, or Linux)
- A credit card to pay for one OpenAI API key (~$2 will cover everything in this book)
- A coding agent installed — we recommend [Claude Code](https://docs.anthropic.com/claude-code), but Cursor or GitHub Copilot Workspace will also work
- About 4–6 hours of focused time

That's it. The coding agent writes the code. You drive.

## What You'll Build

By the end of this book, you'll have a working CLI AI agent on your laptop that can:

- Read, write, and edit files on your computer
- Run shell commands
- Search the web
- Manage long conversations
- Ask for your permission before doing anything dangerous

It's the same agent the [Python edition](https://sivakarasala.github.io/building-ai-agents/python/) builds — written in Python, with the same architecture. But instead of typing every line yourself, you'll guide a coding agent through the build, one prompt at a time.

## Why This Approach?

Three reasons.

**1. You learn by building.** Reading about agents is one thing. Watching code appear, running it, breaking it, and fixing it is something else entirely. The understanding sticks.

**2. The coding agent is the future of software work.** Whether or not you ever write code yourself, the people on your team will increasingly work *with* coding agents. Knowing what a good prompt looks like, how to verify output, and when to push back on the agent are core skills now — even for non-engineers.

**3. The agent you build is real.** It's not a simulator or a toy. It's the same architecture used by Claude Code, Cursor, and the agents your engineering team is shipping. By the end you'll be able to look at any agent product and have an informed opinion on what's hard, what's easy, and what's just hype.

## How This Book Is Different

Each chapter follows the same seven-section format:

1. **What you're building and why** — The concept, in plain language. No jargon.
2. **The prompt** — A copy-pasteable prompt for your coding agent.
3. **What you should see** — Concrete expectations: which files appear, what they roughly contain.
4. **How to verify** — One command to run, with the expected output.
5. **If it didn't work** — Three to five common failure modes and recovery prompts.
6. **Reference code** — The canonical version (collapsed). Compare against it if you want.
7. **What you just learned about agents** — The takeaway, in product-manager terms.

You don't need to read the reference code. It's there if your coding agent produces something weird and you want to see what *should* have happened.

## A Note on Coding Agents and Drift

Coding agents are non-deterministic. Two readers running the same prompt may get slightly different code. That's fine — what matters is that the *behavior* matches what we describe in "How to verify."

If your agent's output diverges from the reference code in surface ways (different variable names, different file structure) but the verification step still passes, **you're done**. Move on.

If the verification fails, the "If it didn't work" section will get you unstuck most of the time. If you're still stuck after that, the reference code is your safety net.

## Tech Stack

You don't need to know any of this. Your coding agent does. It's listed here so you recognize the words when they appear:

- **Python 3.11+** — The language the agent is written in
- **OpenAI SDK** — How we talk to the LLM
- **Pydantic** — How we describe what tools take as input
- **Rich + Prompt Toolkit** — How we make the terminal look nice

## Acknowledgments

This edition is the same agent as the [Python](https://sivakarasala.github.io/building-ai-agents/python/), [TypeScript](https://sivakarasala.github.io/building-ai-agents/typescript/), [Rust](https://sivakarasala.github.io/building-ai-agents/rust/), [Go](https://sivakarasala.github.io/building-ai-agents/go/), and [Java](https://sivakarasala.github.io/building-ai-agents/java/) editions — just built through prompts instead of code. If at any point you want to see the "answer key," the Python edition has the full hand-written walkthrough.

---

Ready? Let's set up your coding agent.

**Next: [Chapter 0: Setting Up Your Coding Agent →](./00-setup-coding-agent.md)**
