# Chapter 1: Setup and Your First LLM Call

## No SDK. Just `HttpClient`.

Most AI agent tutorials start with `pip install openai` or `npm install ai`. We're starting with `java.net.http.HttpClient` — the JDK's built-in HTTP client. OpenAI's API is just a REST endpoint. You send JSON, you get JSON back. Everything between is HTTP.

This matters because when something breaks — and it will — you'll know exactly which layer failed. Was it the HTTP connection? The JSON deserialization? The API response format? There's no SDK to blame, no magic to debug through.

## Project Setup

We'll use Gradle with the Kotlin DSL. Make sure you have Java 21:

```bash
java --version
# openjdk 21.x.x
```

Create the project:

```bash
mkdir agents-java && cd agents-java
gradle init --type java-application --dsl kotlin --package com.example.agents \
    --project-name agents-java --java-version 21
```

When Gradle asks about test framework, JUnit Jupiter is a fine default.

### `build.gradle.kts`

Replace the generated `app/build.gradle.kts` with:

```kotlin
plugins {
    application
    id("com.github.johnrengelman.shadow") version "8.1.1"
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("com.fasterxml.jackson.core:jackson-databind:2.17.0")
    implementation("io.github.cdimascio:dotenv-java:3.0.0")
    implementation("com.googlecode.lanterna:lanterna:3.1.2")

    testImplementation("org.junit.jupiter:junit-jupiter:5.10.2")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
}

application {
    mainClass.set("com.example.agents.Main")
}

tasks.test {
    useJUnitPlatform()
}
```

Four dependencies, all minimal:

- **Jackson** for JSON. The streaming Jackson API is also great, but `databind` keeps the code short.
- **dotenv-java** to load `.env` files in development.
- **Lanterna** for the terminal UI in Chapter 9.
- **JUnit** for unit tests.

The Shadow plugin lets us produce a fat JAR (`./gradlew shadowJar`) so the agent ships as a single file.

### Environment

Create `.env` in the project root:

```
OPENAI_API_KEY=your-openai-api-key-here
```

And `.gitignore`:

```
.env
.gradle/
build/
*.iml
.idea/
```

## The OpenAI Responses API

Before writing code, let's understand the API we're calling. We're using OpenAI's **Responses API** — the modern replacement for Chat Completions. It's built around a list of "input items" (roles or typed items like function calls) and returns a list of "output items".

```
POST https://api.openai.com/v1/responses
Authorization: Bearer <your-api-key>
Content-Type: application/json

{
  "model": "gpt-5-mini",
  "instructions": "You are a helpful assistant.",
  "input": [
    {"role": "user", "content": "What is an AI agent?"}
  ]
}
```

The response is a JSON object with an `output` array (assistant messages, function calls, etc.) and a convenience `output_text` field that concatenates all assistant text. A few things differ from Chat Completions:

- The system prompt is the top-level **`instructions`** field, not a message in the array.
- The conversation lives in **`input`**, a heterogeneous list — role-based messages mixed with typed items like `function_call` and `function_call_output`.
- The result is **`output`**, a list of typed output items.

Let's model that in Java.

## API Records

Create `app/src/main/java/com/example/agents/api/Messages.java`:

```java
package com.example.agents.api;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.JsonNode;

import java.util.List;

@JsonInclude(JsonInclude.Include.NON_NULL)
public final class Messages {
    private Messages() {}

    /**
     * One item in the Responses API {@code input} array.
     *
     * <p>Intentionally one record that can represent either a role-based
     * message ({role, content}) or a typed item like
     * {type:"function_call", call_id, name, arguments} and
     * {type:"function_call_output", call_id, output}. Null fields are
     * dropped from the wire format by {@code @JsonInclude(NON_NULL)}.
     */
    public record InputItem(
            // Role-based message fields
            String role,
            String content,

            // Typed item fields
            String type,
            @JsonProperty("call_id") String callId,
            String name,
            String arguments,   // JSON string for function_call
            String output       // result text for function_call_output
    ) {
        public static InputItem user(String content) {
            return new InputItem("user", content, null, null, null, null, null);
        }

        public static InputItem assistant(String content) {
            return new InputItem("assistant", content, null, null, null, null, null);
        }

        public static InputItem functionCall(String callId, String name, String argumentsJson) {
            return new InputItem(null, null, "function_call", callId, name, argumentsJson, null);
        }

        public static InputItem functionCallOutput(String callId, String output) {
            return new InputItem(null, null, "function_call_output", callId, null, null, output);
        }
    }

    /**
     * A tool definition sent to the API.
     *
     * <p>The Responses API uses a flat shape — name/description/parameters
     * live directly on the tool, not nested under a "function" object.
     */
    public record ToolDefinition(
            String type,
            String name,
            String description,
            JsonNode parameters // JSON Schema
    ) {}

    public record ResponsesRequest(
            String model,
            String instructions,
            List<InputItem> input,
            List<ToolDefinition> tools,
            Boolean stream
    ) {}

    public record ResponsesResponse(
            String id,
            List<OutputItem> output,
            @JsonProperty("output_text") String outputText,
            Usage usage
    ) {}

    /**
     * One item in the model's {@code output} array.
     *
     * <p>Common types: {@code message}, {@code function_call},
     * {@code reasoning}, {@code web_search_call}.
     */
    public record OutputItem(
            String type,
            String id,
            String status,

            // For type == "message"
            String role,
            List<ContentPart> content,

            // For type == "function_call"
            @JsonProperty("call_id") String callId,
            String name,
            String arguments
    ) {}

    public record ContentPart(
            String type, // e.g. "output_text"
            String text
    ) {}

    public record Usage(
            @JsonProperty("input_tokens") int inputTokens,
            @JsonProperty("output_tokens") int outputTokens,
            @JsonProperty("total_tokens") int totalTokens
    ) {}
}
```

A few Java-specific notes:

- **`@JsonInclude(NON_NULL)` on the holder class** — Tells Jackson to omit null fields when serializing. The API doesn't expect `"role": null` on a typed function_call item.
- **Records are JSON-friendly** — Jackson's `databind` module understands records natively (since Jackson 2.12). No setters, no Lombok.
- **`@JsonProperty` for snake_case** — Java field names are camelCase, the API uses snake_case. The annotation bridges them.
- **`JsonNode` for parameters** — JSON Schema is dynamic. We could model it, but a raw `JsonNode` is simpler and lets each tool build its own schema however it likes.
- **One `InputItem` record, two shapes** — Role-based messages and typed items share a record. Null fields and `@JsonInclude(NON_NULL)` keep the wire format clean. The alternative (a sealed interface with multiple subtypes plus a custom serializer) is more "type-safe" but a lot more code for the same effect.
- **Static factory methods on `InputItem`** — Constructors with seven nullable arguments are awful to call. The factories make construction a one-liner.

## The HTTP Client

Create `OpenAiClient.java` in the same package:

```java
package com.example.agents.api;

import com.example.agents.api.Messages.ResponsesRequest;
import com.example.agents.api.Messages.ResponsesResponse;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

public final class OpenAiClient {
    private static final URI API_URL = URI.create("https://api.openai.com/v1/responses");

    private final String apiKey;
    private final HttpClient http;
    private final ObjectMapper mapper;

    public OpenAiClient(String apiKey) {
        this.apiKey = apiKey;
        this.http = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .build();
        this.mapper = new ObjectMapper()
                .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
    }

    public ResponsesResponse createResponse(ResponsesRequest req) throws Exception {
        String body = mapper.writeValueAsString(req);

        HttpRequest httpReq = HttpRequest.newBuilder()
                .uri(API_URL)
                .timeout(Duration.ofSeconds(60))
                .header("Authorization", "Bearer " + apiKey)
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();

        HttpResponse<String> resp = http.send(httpReq, HttpResponse.BodyHandlers.ofString());

        if (resp.statusCode() >= 400) {
            throw new RuntimeException("OpenAI API error (" + resp.statusCode() + "): " + resp.body());
        }
        return mapper.readValue(resp.body(), ResponsesResponse.class);
    }

    public ObjectMapper mapper() {
        return mapper;
    }
}
```

Three things worth pausing on:

- **`HttpClient` is reusable.** Build one per process and share it. Internally it manages a connection pool. Creating a new client per request leaks file descriptors.
- **`HttpResponse.BodyHandlers.ofString()`** — Reads the whole body into a `String`. Fine for non-streaming responses; in Chapter 4 we'll switch to a streaming line subscriber.
- **`throws Exception`** — Pragmatic for chapter code. In production you'd throw a checked `IOException` or wrap into a custom `OpenAiException`.

## The System Prompt

Create `agent/Prompts.java`:

```java
package com.example.agents.agent;

public final class Prompts {
    private Prompts() {}

    public static final String SYSTEM = """
            You are a helpful AI assistant. You provide clear, accurate, and concise responses to user questions.

            Guidelines:
            - Be direct and helpful
            - If you don't know something, say so honestly
            - Provide explanations when they add value
            - Stay focused on the user's actual question
            """;
}
```

Java text blocks (`"""`) since Java 15 make multi-line strings actually pleasant. In the Responses API the system prompt is passed via the top-level `instructions` field, not as a message in the input array.

## Your First LLM Call

Now wire it together. Create `Main.java`:

```java
package com.example.agents;

import com.example.agents.agent.Prompts;
import com.example.agents.api.Messages.InputItem;
import com.example.agents.api.Messages.ResponsesRequest;
import com.example.agents.api.Messages.ResponsesResponse;
import com.example.agents.api.OpenAiClient;
import io.github.cdimascio.dotenv.Dotenv;

import java.util.List;

public class Main {
    public static void main(String[] args) throws Exception {
        Dotenv env = Dotenv.configure().ignoreIfMissing().load();
        String apiKey = env.get("OPENAI_API_KEY", System.getenv("OPENAI_API_KEY"));
        if (apiKey == null || apiKey.isBlank()) {
            System.err.println("OPENAI_API_KEY must be set");
            System.exit(1);
        }

        OpenAiClient client = new OpenAiClient(apiKey);

        ResponsesRequest req = new ResponsesRequest(
                "gpt-5-mini",
                Prompts.SYSTEM,
                List.of(
                        InputItem.user("What is an AI agent in one sentence?")
                ),
                null,
                null
        );

        ResponsesResponse resp = client.createResponse(req);

        System.out.println(resp.outputText());
    }
}
```

Run it:

```bash
./gradlew run
```

You should see something like:

```
An AI agent is an autonomous system that perceives its environment, makes
decisions, and takes actions to achieve specific goals.
```

That's a raw HTTP call to OpenAI, decoded into Java records. No SDK involved.

## What We Built

Look at what's happening:

1. `Dotenv` reads `.env` into a map (falling back to real environment variables)
2. We construct a `ResponsesRequest` record literal
3. Jackson serializes it to JSON via the record's components
4. `HttpClient.send` issues the HTTPS POST with our bearer token
5. The response JSON is deserialized into `ResponsesResponse`
6. We print the convenience `output_text` field

Every step is explicit. If the API changes its response format, Jackson will throw a clear error. If we send a malformed request, the API returns an error and we surface the response body.

## Summary

In this chapter you:

- Set up a Gradle project on Java 21 with minimal dependencies
- Modeled the OpenAI Responses API as records with Jackson annotations
- Built an HTTP client using only `java.net.http.HttpClient`
- Made your first LLM call from raw HTTP

In the next chapter, we'll add tool definitions and teach the LLM to call our methods.

---

**Next: [Chapter 2: Tool Calling →](./02-tool-calling.md)**
