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

## Recommended Reading (Chapter 10)

1. **[AI Engineering: Building Applications with Foundation Models](https://www.amazon.com/AI-Engineering-Building-Applications-Foundation/dp/1098166302)** — Chip Huyen (O'Reilly, 2025). Read this first, regardless of edition. It covers everything *around* the agent (eval at scale, RAG, cost optimization, deployment).
2. **[AI Agents: Multi-Agent Systems and Orchestration Patterns](https://www.amazon.com/dp/B0F1YV2Q5Y)** — Victor Dibia (2025). Read after you've built the single-agent. It covers multi-agent orchestration, which is the natural next step.
3. **[The Agentic AI Book](https://book.ryanrad.org/)** — Dr. Ryan Rad. Broad coverage of agent components and production patterns.
4. **[AI Agents and Applications: With LangChain, LangGraph and MCP](https://www.manning.com/books/ai-agents-and-applications)** — Roberto Infante (Manning). Framework approach — useful contrast to our from-scratch builds.
5. **[Build an AI Agent (From Scratch)](https://www.manning.com/books/build-an-ai-agent-from-scratch)** — Jungjun Hur & Younghee Song (Manning, est. Summer 2026). Similar philosophy to our books, in Python.
6. **[AI Agents in Action](https://www.manning.com/books/ai-agents-in-action)** — Micheal Lanham (Manning). Surveys the agent ecosystem: OpenAI Assistants, LangChain, AutoGen, CrewAI.

Pick based on what you're building next — the first two are the most impactful.

## Key Insight

Each edition teaches the same architecture from a different angle. Going through more than one isn't repetitive — it's reinforcing.
