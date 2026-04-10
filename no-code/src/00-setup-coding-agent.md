# Chapter 0: Setting Up Your Coding Agent

This is the only chapter where you'll do "setup" work. Once your coding agent is running and your API keys are in place, every other chapter is just: paste a prompt, watch it work, run one verification command.

If you get stuck here, that's normal. Most people get stuck on environment setup at least once. The good news: you only have to do it once.

## What You're Building and Why

You need three things on your computer before Chapter 1:

1. **A coding agent** — the AI that will write Python code on your behalf
2. **An OpenAI API key** — so the agent you *build* can talk to a model
3. **Python 3.11 or newer** — the language the agent will be written in

Think of it like setting up a new kitchen before cooking. We're laying out the tools so the actual cooking (Chapters 1–3) can be uninterrupted.

## Step 1: Pick a Coding Agent

We recommend **Claude Code** for this book. It's the most capable terminal-based coding agent at the time of writing, it handles multi-file projects well, and the prompts in this book have been tested against it.

Other coding agents that will work:

| Coding Agent | Works for this book? | Notes |
|---|---|---|
| **Claude Code** | Yes (recommended) | Best fit for the prompt style we use |
| **Cursor** | Yes | IDE-based; you'll paste prompts into the chat panel |
| **GitHub Copilot Workspace / Codex** | Yes | Similar workflow to Cursor |
| **ChatGPT + manual copy/paste** | Works but tedious | You'll be the file system |

The rest of this chapter assumes Claude Code. If you're using a different agent, the prompts are the same — just paste them into wherever your agent takes input.

### Install Claude Code

Open your Terminal app (on Mac: ⌘+Space, type "Terminal"; on Windows: search "PowerShell"), and paste:

```bash
curl -fsSL https://claude.ai/install.sh | sh
```

Then run:

```bash
claude --version
```

You should see a version number. If you get "command not found," close and reopen your terminal and try again.

For the latest install instructions, see [Claude Code docs](https://docs.anthropic.com/claude-code).

### Sign in

Run:

```bash
claude
```

The first time you run it, it'll walk you through signing in. Use your Anthropic account — if you don't have one, create it at [claude.ai](https://claude.ai). Claude Code uses your Anthropic subscription or pay-as-you-go credits; it does **not** use your OpenAI key (that's for the agent you're *building*, not the agent that's *helping you*).

## Step 2: Get an OpenAI API Key

The agent you build in this book talks to OpenAI's models. You need one API key.

1. Go to [platform.openai.com](https://platform.openai.com)
2. Sign up or log in
3. Click your profile icon → **API keys** → **Create new secret key**
4. Copy the key. It starts with `sk-` and is about 50 characters long.
5. Paste it somewhere safe for now (a sticky note, password manager, anywhere you can find it again in five minutes)

You'll also need to add a few dollars of credit to your OpenAI account: **Settings → Billing → Add payment method**. The entire book uses well under $5 of credit.

> **Why both an Anthropic and OpenAI account?** Claude Code (your *helper*) is made by Anthropic. The agent you're *building* uses OpenAI models because that's what the original course uses. There's no technical reason — you could rebuild this whole book using Claude or Gemini models with small prompt tweaks. We're staying on OpenAI to match the other editions exactly.

## Step 3: Make Sure Python Is Installed

In your terminal:

```bash
python3 --version
```

If you see `Python 3.11.x` or higher, you're done with this step.

If you see something lower (like `Python 3.9`) or "command not found":

- **Mac**: Install [Homebrew](https://brew.sh), then run `brew install python@3.12`
- **Windows**: Install from [python.org/downloads](https://www.python.org/downloads/) — make sure to check "Add Python to PATH" during install
- **Linux**: `sudo apt install python3.12` (or your distro's equivalent)

Then run `python3 --version` again to confirm.

## Step 4: Create Your Project Folder

Pick a folder where you want this project to live. Anywhere works — your Desktop, your Documents folder, wherever. In your terminal:

```bash
mkdir agents-v2
cd agents-v2
```

This creates an empty folder and moves into it. From here on, every prompt assumes you're inside this folder.

## Step 5: Start Claude Code in Your Project

From inside the `agents-v2` folder, run:

```bash
claude
```

Claude Code will start up and show you a prompt. This is where you'll paste every prompt in this book.

Try a smoke test. Paste this:

```
What folder are we in, and is it empty?
```

Claude Code should respond with something like "We're in `/Users/.../agents-v2` and the folder is empty." If it does — congratulations, your coding agent is working.

## How to Verify Everything Is Ready

Run these four commands in your terminal (outside Claude Code) and check the output:

```bash
claude --version          # should print a version
python3 --version         # should print 3.11 or higher
pwd                       # should end in /agents-v2
ls                        # should print nothing (empty folder)
```

If all four look right, you're set.

## If It Didn't Work

**"claude: command not found"**
Close your terminal completely and reopen it. The install script adds `claude` to your shell's PATH, and that change only takes effect in new terminal windows.

**"python3: command not found"**
On Windows, you may need `python` instead of `python3`. Try `python --version`. If that works, mentally substitute `python` for `python3` in the rest of this book.

**Claude Code keeps asking me to log in**
You may have multiple Anthropic accounts. Run `claude logout` then `claude` and sign in again with the account that has credits.

**My OpenAI account says "you must add a payment method"**
You do — even if you have free trial credit, OpenAI requires a card on file before issuing API keys. Add one in **Settings → Billing**.

**Chapter 1 fails immediately with "incorrect API key provided"**
Your OpenAI key is wrong, or there's a stray space when you pasted it. Re-copy from [platform.openai.com](https://platform.openai.com/api-keys) and try again. The key should start with `sk-` and be one continuous string with no spaces.

**My coding agent does something completely different from what the prompt asks**
This happens occasionally. Try the prompt again in a fresh Claude Code session (`/clear` inside Claude Code, or quit and restart). If it still misbehaves, it usually means the prompt was ambiguous in your context — re-read the "What you should see" section and tell the agent more specifically what you wanted.

## What You Just Learned About Agents

Two things, actually.

**First: agents need API keys, money, and an environment.** Every "magical" AI product you've used had someone do this exact setup. Knowing where the keys come from, what they cost, and where they live demystifies a huge part of how AI products are deployed.

**Second: you just used a coding agent to verify your environment.** When you asked Claude Code "what folder are we in, is it empty?", it ran shell commands, read the output, and summarized them for you. That's *exactly* the loop you're going to build in Chapter 4: an LLM that can call tools, see the results, and respond. You've been the agent's user. Soon you'll have built one of your own.

---

**Next: [Chapter 1: Your First LLM Call →](./01-first-llm-call.md)**
