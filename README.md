# Antigravity Enterprise Gateway — LiteLLM on Cloud Run

Deploy **LiteLLM Proxy** on **Google Cloud Run** for **Antigravity CLI `agy`** with **one command**.

This repository deploys the **official [LiteLLM Proxy](https://docs.litellm.ai/docs/simple_proxy)** (`ghcr.io/berriai/litellm`, pinned to v1.105.0) configured for Antigravity's Google GenAI wire protocol (`/v1beta/models/{model}:streamGenerateContent?alt=sse`).

- 🧠 Bring & Choose Your Models: Curate which models developers see, set default models, or route requests to different models behind the proxy (supports both Vertex AI and OpenAI-compatible formats).
- 💰 Control the Budget: Set spending/usage limits per developer or team, and route simpler tasks to cheaper/faster models.
- 🔒 Pass Security Audit: Strip sensitive data (PII) and log every AI request inside the company's own network.

---

## 1-Minute Quickstart

### Prerequisites
1. [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install), `curl` and `openssl` installed, and gcloud logged in:
   ```bash
   gcloud auth login
   ```
2. A Google Cloud project with **billing enabled**, and you have **Owner** (or Editor + Security Admin) on it.
3. If you want Claude: enable the Claude models once in [Vertex AI Model Garden](https://console.cloud.google.com/vertex-ai/model-garden) for that project.

### Step 1: Deploy in One Command

```bash
./deploy.sh --project YOUR_GCP_PROJECT_ID
```

That's it. The script is idempotent, so it's safe to re-run at any time. It:

1. Runs pre-flight checks (tools installed, gcloud logged in, project accessible).
2. Enables required GCP APIs (`run`, `aiplatform`, `cloudbuild`, `artifactregistry`, `secretmanager`).
3. Creates a dedicated least-privilege Service Account (`antigravity-gateway-sa`) with only `roles/aiplatform.user`.
4. Generates a random 256-bit **gateway API key** and stores it in **Google Cloud Secret Manager** (`antigravity-gateway-api-key`).
5. Builds and deploys the LiteLLM Proxy container to **Cloud Run**.
6. Generates `admin_settings.json` in this folder, pre-filled with your gateway URL and API key.
7. Runs `./scripts/test_gateway.sh` to verify health, authentication, Gemini and Claude streaming, and tool calling.

**Optional flags:**

| Flag | Default | Purpose |
| :--- | :--- | :--- |
| `--region <REGION>` | `us-central1` | Cloud Run region |
| `--api-key <KEY>` | reuse existing / generate | Set or **rotate** the gateway API key |
| `--min-instances <N>` | `0` | Keep `N` instances warm. Avoids the ~10–20s cold start on the first request after idle (costs money) |
| `--service <NAME>` | `antigravity-enterprise-gateway` | Cloud Run service name (deploy multiple gateways side by side) |

---

### Step 2: Connect Antigravity CLI

Copy the generated `admin_settings.json` to your OS enterprise settings path:

- **Linux:**
  ```bash
  sudo mkdir -p /etc/antigravity
  sudo cp admin_settings.json /etc/antigravity/admin_settings.json
  sudo chmod 644 /etc/antigravity/admin_settings.json
  ```
- **macOS:**
  ```bash
  sudo mkdir -p "/Library/Application Support/Antigravity"
  sudo cp admin_settings.json "/Library/Application Support/Antigravity/admin_settings.json"
  sudo chmod 644 "/Library/Application Support/Antigravity/admin_settings.json"
  ```
- **Windows (PowerShell as Administrator):**
  ```powershell
  New-Item -ItemType Directory -Force -Path "$env:ProgramData\Antigravity"
  Copy-Item admin_settings.json "$env:ProgramData\Antigravity\admin_settings.json"
  ```

Restart Antigravity, or test right away from your terminal with `agy`:

```bash
agy --model gemini-3.8-flash -p "Write a Python binary search implementation"
agy --model claude-sonnet-5  -p "Write a Python binary search implementation"
```

---

## Authentication & Security

**Short answer: API-key authentication enforced by LiteLLM. Not IAP.**

Here is how a request is authenticated, step by step:

```
Antigravity CLI
   │  reads gateway.apiKey from admin_settings.json
   │  sends:  Authorization: Bearer <apiKey>
   ▼
Cloud Run (public HTTPS endpoint, TLS by Google Front End)
   ▼
LiteLLM Proxy auth check
   │  compares the Bearer token against LITELLM_MASTER_KEY
   │  (injected from Secret Manager at container start, never in the image or source)
   ├── no key       → 401 Unauthorized
   ├── wrong key    → rejected (400 "No connected db" in default mode, 401 with a DB)
   └── valid key    → request routed to the model
   ▼
Vertex AI (Gemini / Claude), called as the Cloud Run Service Account.
No Google credentials ever leave GCP or reach the developer's machine.
```

| Layer | What protects it |
| :--- | :--- |
| **Who can call the gateway** | The gateway API key (`Authorization: Bearer`). Every model endpoint (`/v1beta/*`, `/v1/*`, `/health`, `/metrics`, key management) requires it. Only `/health/liveliness`, `/health/readiness`, the Swagger UI at `/` and the static `/ui` shell are public, and none of them expose secrets or models. |
| **Where the key lives** | Google Cloud Secret Manager (`antigravity-gateway-api-key`). Only the gateway's Service Account has `secretAccessor`. On developer machines it's in `admin_settings.json` (keep it `root`-owned on shared machines). |
| **What the gateway can do in GCP** | Only `roles/aiplatform.user` (call Vertex AI models) through its dedicated Service Account. Nothing else. |
| **Transport** | HTTPS only (Cloud Run managed TLS). |

### Why not IAP?
Cloud Run supports [Identity-Aware Proxy](https://cloud.google.com/run/docs/securing/identity-aware-proxy-cloud-run). However, IAP requires each client to obtain a short-lived Google OIDC token per user, and Antigravity's gateway setting sends a **static** API key (`apiKey` + optional `customHeaders`). An IAP-protected gateway would reject the CLI. API-key auth at the LiteLLM layer is the supported model for this integration.

### Rotating the API key
```bash
./deploy.sh --project YOUR_GCP_PROJECT_ID --api-key "sk-agy-$(openssl rand -hex 32)"
```
This stores the new key as the latest Secret Manager version, rolls out a new Cloud Run revision, **disables the old key version**, and regenerates `admin_settings.json`. Redistribute the new `admin_settings.json` to your developers.

### Hardening for production (beyond PoC)
| Concern | Recommendation |
| :--- | :--- |
| One shared key for everyone | Add Postgres to get **per-developer virtual keys** with budgets/rate limits that can be revoked one at a time ([see below](#upgrade-path-per-developer-keys-budgets--admin-ui)). Keep the master key for admins only. |
| Restrict network access | Put the service behind an external HTTPS Load Balancer + **Cloud Armor** IP allowlist (corporate egress IPs), then set `gcloud run services update SERVICE --ingress internal-and-cloud-load-balancing`. Or use `--ingress internal` if all developers come in over VPN / Interconnect. |
| Hide the API explorer | Add `NO_DOCS=True` to `--set-env-vars` in `deploy.sh` to disable the Swagger UI at `/`. |
| Org blocks public services | Handled automatically. If the *Domain Restricted Sharing* policy blocks `allUsers`, `deploy.sh` detects the 403 and switches to `--no-invoker-iam-check`. The LiteLLM API key is still enforced. |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                Developer Workstation (Antigravity CLI)            │
│  Reads /etc/antigravity/admin_settings.json (wireProtocol: "genai")     │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │ HTTPS POST /v1beta/models/{model}:streamGenerateContent?alt=sse
                                    │ Header: Authorization: Bearer <gateway API key>
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│             Google Cloud Run — Official LiteLLM Proxy Server            │
│                 (ghcr.io/berriai/litellm, pinned v1.105.0)              │
│                                                                         │
│  • Auth Guard: Validates Bearer token against Secret Manager key        │
│  • LiteLLM Router (config.yaml):                                        │
│      - Resolves model_group_alias (e.g. sonnet-5 -> claude-sonnet-5)    │
│      - Automatic retries & fallback chains on 429 / 5xx                 │
│  • Antigravity Protojson Plugin (callbacks.py):                         │
│      - Normalizes protojson tool schemas ("minItems": "2" -> 2)         │
│      - Preserves multi-part system instructions & unique tool_call_ids  │
└──────────────────┬───────────────────────────────────┬──────────────────┘
                   │ Native GenAI Pass-Through         │ GoogleGenAIAdapter Translation
                   │ (Cloud Run Service Account ADC)   │ (Cloud Run Service Account ADC)
                   ▼                                   ▼
     ┌───────────────────────────┐       ┌───────────────────────────┐
     │   Vertex AI Gemini API    │       │  Vertex AI Model Garden   │
     │  • gemini-3.8-flash       │       │  • claude-sonnet-5        │
     │  • gemini-3.7-flash       │       │  • claude-opus-5          │
     │  • gemini-3.1-pro-preview │       │  • claude-sonnet-4-6      │
     │  • gemini-2.5-pro / flash │       │  • claude-opus-4-6        │
     └───────────────────────────┘       └───────────────────────────┘
```

---

## Repository Structure

```text
.
├── config.yaml                 # LiteLLM Proxy model list, aliases, fallbacks & settings
├── callbacks.py                # LiteLLM plugin normalizing Antigravity protojson quirks
├── Dockerfile                  # Extends the pinned official LiteLLM image
├── deploy.sh                   # One-command Cloud Run deployment & verification
├── admin_settings.example.json # Template for the Antigravity enterprise client config
├── scripts/
│   └── test_gateway.sh         # End-to-end security, streaming & tool-calling checks
└── README.md                   # This guide
```

---

## Customizing Models & Using LiteLLM Features

### 1. Built-in endpoints
- **Swagger / OpenAPI explorer:** `https://<YOUR_GATEWAY_URL>/` (root path)
- **Model list:** `GET https://<YOUR_GATEWAY_URL>/v1/models` (needs the API key)
- **OpenAI-compatible:** `POST https://<YOUR_GATEWAY_URL>/v1/chat/completions`. Other tools (Cursor, Continue, LangChain, the OpenAI SDK) can share the same gateway.

### 2. Adding models or providers (`config.yaml`)
To add a model from any of [LiteLLM's 100+ providers](https://docs.litellm.ai/docs/providers), add an entry under `model_list` in `config.yaml`, add its `modelId` to `admin_settings.example.json`, and re-run `./deploy.sh`:

```yaml
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY   # store it in Secret Manager and add to --set-secrets
```

LiteLLM translates Antigravity's `/v1beta/models/gpt-4o:streamGenerateContent` calls to OpenAI's format and streams the response back.

### 3. Model aliases & fallbacks (`config.yaml`)
Under `router_settings`, define aliases and automatic fallback chains for when a model hits quota (`429`) or a transient `5xx`:

```yaml
router_settings:
  num_retries: 2
  model_group_alias:
    sonnet-5: claude-sonnet-5
  fallbacks:
    - claude-fable-5: ["claude-opus-5", "claude-sonnet-5"]
    - gemini-3.8-flash: ["gemini-3.7-flash", "gemini-2.5-flash"]
```

### Upgrade path: per-developer keys, budgets & Admin UI
The PoC runs **stateless** (no database). That's why the LiteLLM Admin UI at `/ui` loads but login fails with *"Not connected to DB"*. To unlock virtual keys, teams, spend tracking, budgets and the Admin UI:

1. Create a Postgres database (e.g. Cloud SQL for PostgreSQL) and store its connection string in Secret Manager as `litellm-database-url`.
2. Grant `antigravity-gateway-sa` `roles/secretmanager.secretAccessor` on it (plus `roles/cloudsql.client` if using Cloud SQL connectors).
3. Add `DATABASE_URL=litellm-database-url:latest` to `--set-secrets` in `deploy.sh` and re-run it. LiteLLM runs its schema migrations automatically on startup.
4. Log in to `https://<YOUR_GATEWAY_URL>/ui` with username `admin` and the master key, then issue one virtual key per developer and put *that* key in their `admin_settings.json`.

### Upgrading LiteLLM
The base image is pinned by digest in the `Dockerfile` for reproducible deployments. To upgrade, change `LITELLM_IMAGE`, re-run `./deploy.sh`, and confirm all checks pass.

---

## Running Verification Tests Manually

```bash
./scripts/test_gateway.sh https://YOUR-GATEWAY-URL.run.app YOUR_GATEWAY_API_KEY
```

Expected output:
```text
Running LiteLLM Proxy Security & Inference Checks against https://...
  ✓ PASS: LiteLLM Proxy liveliness check (/health/liveliness) returned 200 OK
  ✓ PASS: Unauthenticated request rejected with HTTP 401 Unauthorized
  ✓ PASS: Invalid API key rejected (HTTP 400)
  ✓ PASS: LiteLLM Proxy model catalog (/v1/models) lists Gemini & Claude models
  ✓ PASS: Gemini 3.8 Flash native GenAI SSE streaming succeeded
  ✓ PASS: Claude Sonnet 5 GenAI-to-Anthropic SSE streaming succeeded
  ✓ PASS: Claude Sonnet 5 tool calling with Antigravity protojson schema succeeded
  ✓ PASS: OpenAI-compatible endpoint (/v1/chat/completions) succeeded
```

---

## Troubleshooting

| Symptom | Cause | Fix |
| :--- | :--- | :--- |
| **`401` "No api key passed in"** | The client isn't sending `Authorization: Bearer`. | Check that `gateway.apiKey` is set in the installed `admin_settings.json`. |
| **`400` "No connected db"** | The client sent a key that **doesn't match** the gateway key (stateless mode). | Re-copy the latest `admin_settings.json`, or print the current key: `gcloud secrets versions access latest --secret=antigravity-gateway-api-key --project=YOUR_PROJECT_ID` |
| **`403 Forbidden` HTML page from Google** | An org policy blocks public Cloud Run services. | Re-run `./deploy.sh`. It detects this and applies `--no-invoker-iam-check` automatically. If that's also blocked by policy, ask your org admin or use a Load Balancer (see Hardening). |
| **First request after idle is slow / times out** | Cloud Run cold start (scale-to-zero). | `./deploy.sh --project YOUR_PROJECT_ID --min-instances 1` |
| **Claude returns `404` or `403` from Vertex AI** | Claude models haven't been enabled in the project. | Open [Vertex AI Model Garden](https://console.cloud.google.com/vertex-ai/model-garden) and enable Claude Sonnet / Opus. |
| **`429` / quota errors** | Vertex AI quota exhausted for a model. | Fallbacks in `config.yaml` kick in automatically. Request more quota in the Cloud Console if they persist. |
| **Antigravity still prompts for Google login** | `admin_settings.json` is in the wrong folder or unreadable. | Copy it to the OS path in Step 2 with read permission (`chmod 644`) and restart the IDE. |
| **See server logs** | — | `gcloud run services logs read antigravity-enterprise-gateway --project=YOUR_PROJECT_ID --region=us-central1 --limit=50` |
