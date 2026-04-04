# Reading Guide

Suggested reading order based on your background.

## If You're Picking One Edition

- **[TypeScript](https://sivakarasala.github.io/building-ai-agents/typescript/)** — Most polished path. Uses the Vercel AI SDK, React+Ink for UI. Best if you want to ship something fast.
- **[Python](https://sivakarasala.github.io/building-ai-agents/python/)** — Most approachable. OpenAI SDK, Rich+Prompt Toolkit. Good if you want the clearest mental model of how agents work.
- **[Rust](https://sivakarasala.github.io/building-ai-agents/rust/)** — Deepest understanding. Raw HTTP, manual SSE parsing, no SDK. Best if you want to know every byte flowing between your agent and the API.

## If You're Going Through All Three

**Start with Python** — It has the least friction. You'll internalize the agent concepts (tool calling, agent loop, evals, context management, HITL) without fighting language mechanics.

**Then TypeScript** — The concepts are now familiar, so you can focus on the framework differences (Zod schemas, React+Ink UI, streaming iterators). You'll notice how the SDK abstracts away things you did manually in Python.

**Finish with Rust** — By now you know *what* the agent does. The Rust edition teaches you *how* it works at the lowest level. SSE parsing, trait objects, ownership in async loops. The appendices (A-E) fill in Rust-specific gaps.

## For the Recommended Reading List (Chapter 10)

1. **Chip Huyen's AI Engineering** — Read this first, regardless of edition. It covers everything *around* the agent (eval at scale, RAG, cost optimization, deployment).
2. **Victor Dibia's AI Agents** — Read after you've built the single-agent. It covers multi-agent orchestration, which is the natural next step.
3. The rest are reference material — pick based on what you're building next.

## Key Insight

Each edition teaches the same architecture from a different angle. Going through more than one isn't repetitive — it's reinforcing.
