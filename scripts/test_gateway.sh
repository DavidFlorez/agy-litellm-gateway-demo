#!/usr/bin/env bash
# =============================================================================
# Antigravity Enterprise Gateway (LiteLLM Proxy) — End-to-End Verification
# =============================================================================
# Usage:
#   ./scripts/test_gateway.sh <GATEWAY_URL> <LITELLM_MASTER_KEY>
# =============================================================================

set -euo pipefail

GW_URL="${1:-${AGY_GATEWAY_URL:-}}"
API_KEY="${2:-${LITELLM_MASTER_KEY:-${AGY_GATEWAY_API_KEY:-}}}"

if [[ -z "$GW_URL" || -z "$API_KEY" ]]; then
  echo "Usage: ./scripts/test_gateway.sh <GATEWAY_URL> <LITELLM_MASTER_KEY>"
  exit 1
fi

GW_URL="${GW_URL%/}"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓ PASS:${NC} $1"; }
fail() { echo -e "  ${RED}✗ FAIL:${NC} $1"; exit 1; }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo -e "${BOLD}Running LiteLLM Proxy Security & Inference Checks against ${GW_URL}...${NC}"

# 1. LiteLLM Proxy Health Check (/health/liveliness)
HTTP_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${GW_URL}/health/liveliness" || true)
HTTP_HEALTH="${HTTP_HEALTH:-000}"
if [[ "$HTTP_HEALTH" == "200" ]]; then
  pass "LiteLLM Proxy liveliness check (/health/liveliness) returned 200 OK"
else
  fail "Health check returned HTTP ${HTTP_HEALTH}"
fi

# 2. Security Check: Unauthenticated Request MUST be rejected with 401
HTTP_NO_AUTH=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "${GW_URL}/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}' || true)
HTTP_NO_AUTH="${HTTP_NO_AUTH:-000}"
if [[ "$HTTP_NO_AUTH" == "401" ]]; then
  pass "Unauthenticated request rejected with HTTP 401 Unauthorized"
else
  fail "Expected HTTP 401 for unauthenticated request, got ${HTTP_NO_AUTH}"
fi

# 3. Security Check: Invalid API Key MUST be rejected.
#    Without a Postgres DB (the default PoC setup), LiteLLM rejects any key that is
#    not the master key with HTTP 400 "No connected db". With a DB it returns 401.
#    Either way the request never reaches a model.
HTTP_BAD_KEY=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "${GW_URL}/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse" \
  -H "Authorization: Bearer invalid-key-attempt" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}' || true)
HTTP_BAD_KEY="${HTTP_BAD_KEY:-000}"
if [[ "$HTTP_BAD_KEY" == "401" || "$HTTP_BAD_KEY" == "400" ]]; then
  pass "Invalid API key rejected (HTTP ${HTTP_BAD_KEY})"
else
  fail "Expected HTTP 401/400 for invalid API key, got ${HTTP_BAD_KEY}"
fi

# 4. Model Catalog Check (/v1/models)
MODELS_OUT=$(curl -s "${GW_URL}/v1/models" -H "Authorization: Bearer ${API_KEY}" || true)
if echo "$MODELS_OUT" | grep -q '"gemini-3.8-flash"' && echo "$MODELS_OUT" | grep -q '"claude-sonnet-5"'; then
  pass "LiteLLM Proxy model catalog (/v1/models) lists Gemini & Claude models"
else
  fail "Model catalog check failed: ${MODELS_OUT}"
fi

# 5. Gemini 3.8 Flash Native GenAI Streaming Check (with Antigravity dummy x-goog-api-key header)
GEMINI_OUT=$(curl -s -N -X POST \
  "${GW_URL}/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "x-goog-api-key: dummy_api_key" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Reply with the single word PONG."}]}]}' || true)
if echo "$GEMINI_OUT" | grep -q '"candidates"'; then
  pass "Gemini 3.8 Flash native GenAI SSE streaming succeeded"
else
  fail "Gemini 3.8 Flash streaming failed: ${GEMINI_OUT}"
fi

# 6. Claude Sonnet 5 GenAI Streaming Check (via LiteLLM GoogleGenAIAdapter)
CLAUDE_STATUS=$(curl -s -o "${TMP_DIR}/sonnet.out" -w "%{http_code}" -N -X POST \
  "${GW_URL}/v1beta/models/claude-sonnet-5:streamGenerateContent?alt=sse" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "x-goog-api-key: dummy_api_key" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Reply with the single word PONG."}]}]}' || true)
CLAUDE_STATUS="${CLAUDE_STATUS:-000}"
CLAUDE_OUT=$(cat "${TMP_DIR}/sonnet.out" 2>/dev/null || true)
if [[ "$CLAUDE_STATUS" == "200" ]] && echo "$CLAUDE_OUT" | grep -q '"finishReason"[[:space:]]*:[[:space:]]*"STOP"'; then
  pass "Claude Sonnet 5 GenAI-to-Anthropic SSE streaming succeeded"
elif [[ "$CLAUDE_STATUS" == "404" || "$CLAUDE_STATUS" == "403" || "$CLAUDE_STATUS" == "429" ]]; then
  echo -e "  \033[1;33m○ SKIP:\033[0m Claude Sonnet 5 is not active in Model Garden / Quotas (HTTP ${CLAUDE_STATUS})"
else
  fail "Claude Sonnet 5 streaming failed (HTTP ${CLAUDE_STATUS}): ${CLAUDE_OUT}"
fi

# 7. Claude Opus 5 & 5.5 GenAI Streaming Check (via LiteLLM GoogleGenAIAdapter)
for opus_model in claude-opus-5 claude-opus-5-5; do
  OPUS_STATUS=$(curl -s -o "${TMP_DIR}/${opus_model}.out" -w "%{http_code}" -N -X POST \
    "${GW_URL}/v1beta/models/${opus_model}:streamGenerateContent?alt=sse" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "x-goog-api-key: dummy_api_key" \
    -H "Content-Type: application/json" \
    -d '{"contents":[{"role":"user","parts":[{"text":"Reply with the single word PONG."}]}]}' || true)
  OPUS_STATUS="${OPUS_STATUS:-000}"
  OPUS_OUT=$(cat "${TMP_DIR}/${opus_model}.out" 2>/dev/null || true)
  if [[ "$OPUS_STATUS" == "200" ]] && echo "$OPUS_OUT" | grep -q '"finishReason"[[:space:]]*:[[:space:]]*"STOP"'; then
    pass "${opus_model} GenAI-to-Anthropic SSE streaming succeeded"
  elif [[ "$OPUS_STATUS" == "404" || "$OPUS_STATUS" == "403" || "$OPUS_STATUS" == "429" ]]; then
    echo -e "  \033[1;33m○ SKIP:\033[0m ${opus_model} is not active in Model Garden / Quotas (HTTP ${OPUS_STATUS})"
  else
    fail "${opus_model} streaming failed (HTTP ${OPUS_STATUS}): ${OPUS_OUT}"
  fi
done

# 8. Claude Tool Calling with Antigravity Protojson Schema ("minItems": "1", uppercase types)
if [[ "$CLAUDE_STATUS" == "200" ]]; then
  TOOL_OUT=$(curl -s -N -X POST \
    "${GW_URL}/v1beta/models/claude-sonnet-5:streamGenerateContent?alt=sse" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{
      "systemInstruction": {
        "parts": [
          {"text": "You are an assistant."},
          {"text": "Always call the get_weather tool when asked about weather."}
        ]
      },
      "contents": [
        {"role": "user", "parts": [{"text": "What is the weather in Jakarta?"}]}
      ],
      "tools": [
        {
          "functionDeclarations": [
            {
              "name": "get_weather",
              "description": "Get weather for a city",
              "parameters": {
                "type": "OBJECT",
                "properties": {
                  "city": {"type": "STRING"},
                  "tags": {"type": "ARRAY", "items": {"type": "STRING"}, "minItems": "1"}
                },
                "required": ["city"]
              }
            }
          ]
        }
      ],
      "toolConfig": {"functionCallingConfig": {"mode": "ANY"}}
    }' || true)
  if echo "$TOOL_OUT" | grep -q '"functionCall"' && echo "$TOOL_OUT" | grep -q '"get_weather"'; then
    pass "Claude Sonnet 5 tool calling with Antigravity protojson schema succeeded"
  else
    fail "Claude Sonnet 5 tool calling failed: ${TOOL_OUT}"
  fi
fi

# 9. Standard OpenAI Chat Completions Endpoint (/v1/chat/completions)
OPENAI_OUT=$(curl -s -X POST \
  "${GW_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-3.8-flash","messages":[{"role":"user","content":"Reply with PONG"}]}' || true)
if echo "$OPENAI_OUT" | grep -q '"choices"'; then
  pass "OpenAI-compatible endpoint (/v1/chat/completions) succeeded"
else
  fail "OpenAI endpoint check failed: ${OPENAI_OUT}"
fi
