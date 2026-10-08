# Proxy Configuration Guide: Compatibility with Antigravity (AGY)

This document provides a comprehensive technical reference for configuring an LLM proxy (such as [LiteLLM Proxy](https://docs.litellm.ai/docs/simple_proxy)) to be fully compatible with the **Google Antigravity CLI (`agy`)**.

---

## 1. Architectural Overview & Context

The Antigravity CLI (`agy`) is designed by default to speak directly to Google's frontier model infrastructure. When an enterprise or team deploys an intermediate proxy or gateway (e.g. deployed on **Google Cloud Run** to control routing, enforce budgets, or integrate partner models like Anthropic Claude, OpenAI, or xAI Grok), the proxy must satisfy specific protocol, serialization, and routing requirements.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                 Developer Workstation (Antigravity CLI)                 │
│  Reads /etc/antigravity/admin_settings.json + gateway.env               │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │ HTTPS POST /v1beta/models/{model}:streamGenerateContent?alt=sse
                                    │ Header: Authorization: Bearer <gateway API key>
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                 Google Cloud Run — LiteLLM Proxy Server                 │
│                                                                         │
│  • Auth Guard: Validates Bearer token against master secret             │
│  • Router (config.yaml):                                                │
│      - Resolves model_group_alias (e.g. opus-5 -> claude-opus-5)        │
│      - Handles automatic fallbacks on 429 (quota) or 5xx                │
│  • Protojson Compatibility Plugin (callbacks.py):                       │
│      - Normalizes protojson schema types ("minItems": "2" -> 2)         │
│      - Preserves multi-part system instructions & unique tool_call_ids  │
│      - Flushes streaming zero-argument tool calls                       │
│      - Maps thinkingLevel <-> thinkingBudget across models              │
└──────────────────┬───────────────────────────────────┬──────────────────┘
                   │ Native GenAI Pass-Through         │ GoogleGenAIAdapter Translation
                   ▼                                   ▼
     ┌───────────────────────────┐       ┌───────────────────────────┐
     │ Vertex AI / GEAP Gemini   │       │ Model Garden & Partners   │
     │  • gemini-3.8-flash       │       │  • claude-sonnet-5        │
     │  • gemini-3.7-flash       │       │  • claude-opus-5          │
     │  • gemini-3.1-pro-preview │       │  • grok-4.7               │
     └───────────────────────────┘       └───────────────────────────┘
```

---

## 2. Core Compatibility Requirements

### A. Wire Protocol & Endpoint Exposure (Google GenAI)
`agy` does **not** communicate via OpenAI Chat Completions (`/v1/chat/completions`) by default. It utilizes the **Google GenAI wire protocol**:

1. **Required Endpoints:**
   * `POST /v1beta/models/{model}:streamGenerateContent?alt=sse` (for streaming requests)
   * `POST /v1beta/models/{model}:generateContent` (for unary requests)
2. **Bidirectional Adapter Translation:**
   * For **Gemini models** on Vertex AI / GEAP, requests pass through natively.
   * For **Non-Gemini models** (e.g. Anthropic Claude, OpenAI, Grok), the proxy must translate inbound Google GenAI structures (`contents`, `parts`, `functionCall`, `functionResponse`) into provider formats (`messages`, `tool_calls`, `tool`), and translate outbound chunks back into Server-Sent Events (SSE) compliant with `GenerateContentResponse`.

---

### B. Antigravity Protojson Serialization Normalization (`callbacks.py`)

`agy`'s Go client serializes requests using Go's `protojson` implementation. This introduces several protobuf-specific wire conventions that downstream non-Gemini providers (especially Anthropic on Vertex AI) reject. 

To resolve this, the proxy requires a custom callback/interceptor (e.g. `callbacks.antigravity_compat`):

1. **JSON Schema Type & Integer Bounds Normalization:**
   * `protojson` serializes `int64` schema validation keywords as strings:
     ```json
     // Emitted by protojson:
     "parameters": {
       "type": "OBJECT",
       "properties": {
         "count": { "type": "INTEGER" }
       },
       "minItems": "2",
       "maxLength": "100"
     }
     ```
   * Downstream APIs require strict JSON Schema Draft 2020-12 types. The proxy must normalize:
     * Enum types: `"INTEGER"` $\to$ `"integer"`, `"STRING"` $\to$ `"string"`, `"OBJECT"` $\to$ `"object"`.
     * Numeric constraints: `"minItems": "2"` $\to$ `"minItems": 2`.
2. **Gemini-Specific Key Stripping:**
   * Strip proprietary schema attributes like `propertyOrdering`, `property_ordering`, and `nullable` before sending requests to non-Gemini providers.
3. **Multi-Part System Instructions:**
   * `agy` splits system prompts across multiple parts in `systemInstruction.parts`.
   * Standard adapters often only inspect `parts[0]`. The proxy must concatenate all parts (`"\n\n".join(...)`) to preserve instructions, developer rules, and workspace context.
4. **Deterministic Tool Call Identification (`tool_call_id`):**
   * Antigravity function calls and responses rely on tool names, whereas Anthropic strictly enforces matching unique `tool_call_id`s.
   * The proxy must track and assign unique IDs (e.g. `call_<name>_<counter>`) when converting `functionCall` to `tool_calls`, and correlate them when translating subsequent `functionResponse` blocks.
5. **Zero-Argument Tool Call Flushing:**
   * When Anthropic streams a tool invocation without arguments (`{}`), intermediate delta chunks have `arguments=""`.
   * The proxy must flush accumulated empty tool calls when `finish_reason` is received rather than discarding them.
6. **Thinking Parameter Translation:**
   * **Gemini 3.x** uses `thinkingLevel` (`"HIGH"`, `"MEDIUM"`, `"LOW"`, `"MINIMAL"`).
   * **Gemini 2.5** uses `thinkingBudget` (integer token count).
   * **Anthropic** uses `thinking.budget_tokens`.
   * When falling back between model generations, the proxy must translate level strings to numeric token budgets (e.g., `HIGH` $\to$ `16384`, `MEDIUM` $\to$ `8192`, `LOW` $\to$ `2048`).

---

### C. Proxy Router & Fallback Configuration (`config.yaml`)

The proxy configuration must align with `agy`'s naming patterns and resilience needs:

```yaml
# 1. Model Definitions
model_list:
  - model_name: gemini-3.8-flash
    litellm_params:
      model: vertex_ai/gemini-3.8-flash
      vertex_project: os.environ/GCP_PROJECT_ID
      vertex_location: global

  - model_name: claude-opus-5
    litellm_params:
      model: vertex_ai/claude-opus-5
      vertex_project: os.environ/GCP_PROJECT_ID
      vertex_location: global

# 2. Router Aliases & Fallbacks
router_settings:
  routing_strategy: simple-shuffle
  num_retries: 2
  timeout: 600

  # Map CLI effort suffixes and shorthands to canonical models
  model_group_alias:
    gemini-3.8-flash-high: gemini-3.8-flash
    gemini-3.8-flash-medium: gemini-3.8-flash
    gemini-3.8-flash-low: gemini-3.8-flash
    gemini-3.7-flash-high: gemini-3.7-flash
    gemini-3.7-flash-medium: gemini-3.7-flash
    gemini-3.7-flash-low: gemini-3.7-flash
    sonnet-5: claude-sonnet-5
    opus-5: claude-opus-5
    claude-opus-5-thinking: claude-opus-5

  # Fallback routing on quota exhaustion (429) or transient 5xx errors
  fallbacks:
    - gemini-3.8-flash: [gemini-3.7-flash]
    - claude-opus-5: [claude-sonnet-5]

# 3. Runtime Engine Settings
litellm_settings:
  drop_params: true         # Avoid 400 errors if an unsupported parameter is passed
  modify_params: true       # Allow custom plugins to rewrite params
  callbacks:
    - callbacks.antigravity_compat

# 4. Master Key Authentication
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

---

### D. Authentication Strategy: Bearer Token vs. IAP

* **Static Master API Key:** `agy` sends a static token in the HTTP header:
  ```http
  Authorization: Bearer <apiKey>
  ```
* **Why Not Google IAP?** Google Identity-Aware Proxy (IAP) requires short-lived per-user Google OIDC identity tokens, which the CLI does not automatically generate or refresh for custom gateway endpoints.
* **Security Best Practice:** 
  * Deploy the proxy container on Google Cloud Run with an unguessable 256-bit API key stored in **Google Secret Manager**.
  * Grant the Cloud Run runtime service account only `roles/aiplatform.user`.
  * Restrict network ingress to corporate VPCs or Cloud Armor IP allowlists if required.

---

## 3. Client Workstation Setup

For `agy` to route requests through the configured proxy instead of default consumer endpoints, two files must be configured on developer machines:

### 1. `admin_settings.json`
Specifies the gateway URL, authentication token, and wire protocol.

* **File Locations:**
  * **macOS:** `/Library/Application Support/Antigravity/admin_settings.json`
  * **Linux:** `/etc/antigravity/admin_settings.json`
  * **Windows:** `%ProgramData%\Antigravity\admin_settings.json`
* **File Permissions:** Must be readable by non-root users (mode `644` / `rw-r--r--`).
* **Content:**
  ```json
  {
    "gateway": {
      "enabled": true,
      "url": "https://<your-gateway-service-url>.run.app",
      "apiKey": "<your-gateway-api-key>",
      "wireProtocol": "genai"
    },
    "models": {
      "defaultModelId": "gemini-3.8-flash",
      "filter": [
        "gemini-3.8-flash",
        "gemini-3.7-flash",
        "claude-opus-5",
        "claude-sonnet-5"
      ]
    },
    "auth": {
      "suppressInteractiveLogin": true
    }
  }
  ```

### 2. `gateway.env`
Defines the environment variables read by the CLI for model discovery:

```bash
export AGY_LLM_GATEWAY_URL="https://<your-gateway-service-url>.run.app"
export AGY_LLM_GATEWAY_API_KEY="<your-gateway-api-key>"
export AGY_LLM_GATEWAY_MODELS="gemini-3.8-flash,gemini-3.7-flash,claude-opus-5,claude-sonnet-5"
```

---

## 4. Verification Checklist

Once the proxy is running and configured, verify with the following commands:

```bash
# 1. Verify model catalog exposed to agy
agy models

# 2. Test Gemini execution with thinking effort level
agy --model gemini-3.8-flash-low -p "Explain quicksort in 2 sentences"

# 3. Test Partner model translation (Claude)
agy --model claude-opus-5 -p "Explain quicksort in 2 sentences"

# 4. Test tool calling through the gateway
agy -p "List files in the current directory"
```
