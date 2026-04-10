# Chapter 7: Web Search & Context Management

> 💻 **Code:** start from the [`lesson-07`](https://github.com/Hendrixer/agents-v2/tree/lesson-07) branch of [Hendrixer/agents-v2](https://github.com/Hendrixer/agents-v2). The `notes/` folder on that branch has the code you'll write in this chapter.

## Two Problems, One Chapter

This chapter tackles two related problems:

1. **Web Search** — The agent can only work with local files. We need to give it access to the internet.
2. **Context Management** — As conversations grow, we'll exceed the model's context window. We need to track token usage and compress old conversations.

These are related because web search results can be large, which accelerates context window usage.

## Adding Web Search

OpenAI provides a native web search tool that runs on their infrastructure. We don't need to build a search engine or call a third-party API — we just activate it.

Create `src/agent/tools/webSearch.ts`:

```typescript
import { openai } from "@ai-sdk/openai";

/**
 * OpenAI native web search tool
 *
 * This is a provider tool - execution is handled by OpenAI, not our tool executor.
 * Results are returned directly in the model's response stream.
 */
export const webSearch = openai.tools.webSearch({});
```

That's it. One line of actual code.

### Provider Tools vs. Local Tools

This is fundamentally different from our file tools. With `readFile`, the LLM says "call readFile" and our code runs `fs.readFile()`. With `webSearch`:

1. Our code tells the OpenAI API that web search is available
2. The LLM decides to search
3. **OpenAI runs the search on their servers**
4. Results come back in the response stream
5. The LLM processes them and continues

We never see the raw search results. We never execute anything. The tool is handled entirely by the provider. That's why our `executeTool` function has this check:

```typescript
const execute = tool.execute;
if (!execute) {
  // Provider tools (like webSearch) are executed by OpenAI, not us
  return `Provider tool ${name} - executed by model provider`;
}
```

### Updating the Registry

Add web search to `src/agent/tools/index.ts`:

```typescript
import { readFile, writeFile, listFiles, deleteFile } from "./file.ts";
import { webSearch } from "./webSearch.ts";

export const tools = {
  readFile,
  writeFile,
  listFiles,
  deleteFile,
  webSearch,
};

export { readFile, writeFile, listFiles, deleteFile } from "./file.ts";
export { webSearch } from "./webSearch.ts";

export const fileTools = {
  readFile,
  writeFile,
  listFiles,
  deleteFile,
};
```

## Filtering Incompatible Messages

Provider tools can return message formats that cause issues when sent back to the API. Web search results may include annotation objects or special content types that the API doesn't accept as input.

Create `src/agent/system/filterMessages.ts`:

```typescript
import type { ModelMessage } from "ai";

/**
 * Filter conversation history to only include compatible message formats.
 * Provider tools (like webSearch) may return messages with formats that
 * cause issues when passed back to subsequent API calls.
 */
export const filterCompatibleMessages = (
  messages: ModelMessage[],
): ModelMessage[] => {
  return messages.filter((msg) => {
    // Keep user and system messages
    if (msg.role === "user" || msg.role === "system") {
      return true;
    }

    // Keep assistant messages that have text content
    if (msg.role === "assistant") {
      const content = msg.content;
      if (typeof content === "string" && content.trim()) {
        return true;
      }
      // Check for array content with text parts
      if (Array.isArray(content)) {
        const hasTextContent = content.some((part: unknown) => {
          if (typeof part === "string" && part.trim()) return true;
          if (typeof part === "object" && part !== null && "text" in part) {
            const textPart = part as { text?: string };
            return textPart.text && textPart.text.trim();
          }
          return false;
        });
        return hasTextContent;
      }
    }

    // Keep tool messages
    if (msg.role === "tool") {
      return true;
    }

    return false;
  });
};
```

This filter removes empty assistant messages (which provider tools sometimes generate) while keeping everything else intact. We'll use this in the agent loop before passing conversation history to the LLM.

## Token Estimation

Now let's tackle context management. The first step is knowing how many tokens we're using.

Exact tokenization requires model-specific tokenizers. But for our purposes, an approximation is good enough. Research shows that on average, one token is roughly 3.5–4 characters for English text.

Create `src/agent/context/tokenEstimator.ts`:

```typescript
import type { ModelMessage } from "ai";

/**
 * Estimate token count from text using simple character division.
 * Uses 3.75 as the divisor (midpoint of 3.5-4 range).
 * This is an approximation - not exact tokenization.
 */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 3.75);
}

/**
 * Extract text content from a message.
 * Handles different message content formats (string, array, objects).
 */
export function extractMessageText(message: ModelMessage): string {
  if (typeof message.content === "string") {
    return message.content;
  }

  if (Array.isArray(message.content)) {
    return message.content
      .map((part) => {
        if (typeof part === "string") return part;
        if ("text" in part && typeof part.text === "string") return part.text;
        if ("value" in part && typeof part.value === "string") return part.value;
        if ("output" in part && typeof part.output === "object" && part.output) {
          const output = part.output as Record<string, unknown>;
          if ("value" in output && typeof output.value === "string") {
            return output.value;
          }
        }
        // Fallback: stringify the part
        return JSON.stringify(part);
      })
      .join(" ");
  }

  return JSON.stringify(message.content);
}

export interface TokenUsage {
  input: number;
  output: number;
  total: number;
}

/**
 * Estimate token counts for an array of messages.
 * Separates input (user, system, tool) from output (assistant) tokens.
 */
export function estimateMessagesTokens(messages: ModelMessage[]): TokenUsage {
  let input = 0;
  let output = 0;

  for (const message of messages) {
    const text = extractMessageText(message);
    const tokens = estimateTokens(text);

    if (message.role === "assistant") {
      output += tokens;
    } else {
      // system, user, tool messages count as input
      input += tokens;
    }
  }

  return {
    input,
    output,
    total: input + output,
  };
}
```

The `extractMessageText` function handles the various message content formats in the AI SDK:
- Simple strings
- Arrays of text parts
- Tool result objects with nested `output.value` fields

We separate input and output tokens because they often have different limits and pricing.

## Model Limits

Create `src/agent/context/modelLimits.ts`:

```typescript
import type { ModelLimits } from "../../types.ts";

/**
 * Default threshold for context window usage (80%)
 */
export const DEFAULT_THRESHOLD = 0.8;

/**
 * Model limits registry
 */
const MODEL_LIMITS: Record<string, ModelLimits> = {
  "gpt-5": {
    inputLimit: 272000,
    outputLimit: 128000,
    contextWindow: 400000,
  },
  "gpt-5-mini": {
    inputLimit: 272000,
    outputLimit: 128000,
    contextWindow: 400000,
  },
};

/**
 * Default limits used when model is not found in registry
 */
const DEFAULT_LIMITS: ModelLimits = {
  inputLimit: 128000,
  outputLimit: 16000,
  contextWindow: 128000,
};

/**
 * Get token limits for a specific model.
 * Falls back to default limits if model not found.
 */
export function getModelLimits(model: string): ModelLimits {
  // Direct match
  if (MODEL_LIMITS[model]) {
    return MODEL_LIMITS[model];
  }

  // Check for variants
  if (model.startsWith("gpt-5")) {
    return MODEL_LIMITS["gpt-5"];
  }

  return DEFAULT_LIMITS;
}

/**
 * Check if token usage exceeds the threshold
 */
export function isOverThreshold(
  totalTokens: number,
  contextWindow: number,
  threshold: number = DEFAULT_THRESHOLD,
): boolean {
  return totalTokens > contextWindow * threshold;
}

/**
 * Calculate usage percentage
 */
export function calculateUsagePercentage(
  totalTokens: number,
  contextWindow: number,
): number {
  return (totalTokens / contextWindow) * 100;
}
```

The 80% threshold gives us a buffer. We don't want to hit the exact context limit — that causes truncation or API errors. By compacting at 80%, we leave room for the next response.

## Conversation Compaction

When the conversation gets too long, we summarize it. Create `src/agent/context/compaction.ts`:

```typescript
import { generateText, type ModelMessage } from "ai";
import { openai } from "@ai-sdk/openai";
import { extractMessageText } from "./tokenEstimator.ts";

const SUMMARIZATION_PROMPT = `You are a conversation summarizer. Your task is to create a concise summary of the conversation so far that preserves:

1. Key decisions and conclusions reached
2. Important context and facts mentioned
3. Any pending tasks or questions
4. The overall goal of the conversation

Be concise but complete. The summary should allow the conversation to continue naturally.

Conversation to summarize:
`;

/**
 * Format messages array as readable text for summarization
 */
function messagesToText(messages: ModelMessage[]): string {
  return messages
    .map((msg) => {
      const role = msg.role.toUpperCase();
      const content = extractMessageText(msg);
      return `[${role}]: ${content}`;
    })
    .join("\n\n");
}

/**
 * Compact a conversation by summarizing it with an LLM.
 *
 * Takes the current messages (excluding system prompt) and returns a new
 * messages array with:
 * - A user message containing the summary
 * - An assistant acknowledgment
 *
 * The system prompt should be prepended by the caller.
 */
export async function compactConversation(
  messages: ModelMessage[],
  model: string = "gpt-5-mini",
): Promise<ModelMessage[]> {
  // Filter out system messages - they're handled separately
  const conversationMessages = messages.filter((m) => m.role !== "system");

  if (conversationMessages.length === 0) {
    return [];
  }

  const conversationText = messagesToText(conversationMessages);

  const { text: summary } = await generateText({
    model: openai(model),
    prompt: SUMMARIZATION_PROMPT + conversationText,
  });

  // Create compacted messages
  const compactedMessages: ModelMessage[] = [
    {
      role: "user",
      content: `[CONVERSATION SUMMARY]\nThe following is a summary of our conversation so far:\n\n${summary}\n\nPlease continue from where we left off.`,
    },
    {
      role: "assistant",
      content:
        "I understand. I've reviewed the summary of our conversation and I'm ready to continue. How can I help you next?",
    },
  ];

  return compactedMessages;
}
```

The compaction strategy:
1. Convert all messages to readable text
2. Send to an LLM with a summarization prompt
3. Replace the entire conversation with a summary + acknowledgment

The compacted conversation is just two messages — far fewer tokens than the original. The tradeoff: the agent loses some detail from earlier in the conversation. But it can keep going instead of hitting the context limit.

### Export Barrel

Create `src/agent/context/index.ts`:

```typescript
// Token estimation
export {
  estimateTokens,
  estimateMessagesTokens,
  extractMessageText,
  type TokenUsage,
} from "./tokenEstimator.ts";

// Model limits registry
export {
  DEFAULT_THRESHOLD,
  getModelLimits,
  isOverThreshold,
  calculateUsagePercentage,
} from "./modelLimits.ts";

// Conversation compaction
export { compactConversation } from "./compaction.ts";
```

## Integrating Context Management into the Agent Loop

Now update `src/agent/run.ts` to use context management. The key changes:

1. Filter messages for compatibility before each run
2. Check token usage before starting
3. Compact if over threshold
4. Report token usage to the UI

Here's the updated beginning of `runAgent`:

```typescript
import {
  estimateMessagesTokens,
  getModelLimits,
  isOverThreshold,
  calculateUsagePercentage,
  compactConversation,
  DEFAULT_THRESHOLD,
} from "./context/index.ts";
import { filterCompatibleMessages } from "./system/filterMessages.ts";

export async function runAgent(
  userMessage: string,
  conversationHistory: ModelMessage[],
  callbacks: AgentCallbacks,
): Promise<ModelMessage[]> {
  const modelLimits = getModelLimits(MODEL_NAME);

  // Filter and check if we need to compact
  let workingHistory = filterCompatibleMessages(conversationHistory);
  const preCheckTokens = estimateMessagesTokens([
    { role: "system", content: SYSTEM_PROMPT },
    ...workingHistory,
    { role: "user", content: userMessage },
  ]);

  if (isOverThreshold(preCheckTokens.total, modelLimits.contextWindow)) {
    workingHistory = await compactConversation(workingHistory, MODEL_NAME);
  }

  const messages: ModelMessage[] = [
    { role: "system", content: SYSTEM_PROMPT },
    ...workingHistory,
    { role: "user", content: userMessage },
  ];

  // Report token usage throughout the loop
  const reportTokenUsage = () => {
    if (callbacks.onTokenUsage) {
      const usage = estimateMessagesTokens(messages);
      callbacks.onTokenUsage({
        inputTokens: usage.input,
        outputTokens: usage.output,
        totalTokens: usage.total,
        contextWindow: modelLimits.contextWindow,
        threshold: DEFAULT_THRESHOLD,
        percentage: calculateUsagePercentage(
          usage.total,
          modelLimits.contextWindow,
        ),
      });
    }
  };

  reportTokenUsage();

  // ... rest of the loop (same as before, but call reportTokenUsage()
  //     after each tool result is added to messages)
```

## How It All Fits Together

Here's the flow for a long conversation:

```
Turn 1: User asks a question → Agent responds → 500 tokens used
Turn 2: User asks follow-up → Agent uses 3 tools → 2,000 tokens used
Turn 3: More tools → 5,000 tokens used
...
Turn 20: 300,000 tokens used (75% of 400k context window)
Turn 21: 330,000 tokens used (82.5% — over 80% threshold!)
  → Agent compacts: summarizes entire conversation into ~500 tokens
  → Conversation resets to summary + acknowledgment
Turn 22: Fresh context with full summary → 1,000 tokens used
```

The user doesn't notice anything different. The agent maintains context through the summary and keeps working. It's like a human taking notes during a long meeting — you can't remember every word, but you captured the key points.

## Summary

In this chapter you:

- Added web search as a provider tool (one line of code!)
- Built message filtering for provider tool compatibility
- Implemented token estimation and context window tracking
- Created conversation compaction via LLM summarization
- Integrated context management into the agent loop

The agent can now search the web and handle arbitrarily long conversations. In the next chapter, we'll add shell command execution.

---

**Next: [Chapter 8: Shell Tool →](./08-shell-tool.md)**
