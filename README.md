# Antigravity Enterprise Gateway — LiteLLM on Cloud Run

Deploy **LiteLLM Proxy** on **Google Cloud Run** for **Antigravity CLI (`agy`)** and **Antigravity IDE** with **one command**.

This repository deploys the **official [LiteLLM Proxy](https://docs.litellm.ai/docs/simple_proxy)** (`ghcr.io/berriai/litellm`, pinned to v1.105.0) configured for Antigravity's Google GenAI wire protocol (`/v1beta/models/{model}:streamGenerateContent?alt=sse`).

- 🧠 **Bring & Choose Your Models:** Curate which models developers see, set default models, or route requests to different models behind the proxy (supports both Vertex AI and OpenAI-compatible formats).
- 💰 **Control the Budget:** Set spending/usage limits per developer or team, and route simpler tasks to cheaper/faster models.
- 🔒 **Pass Security Audit:** Strip sensitive data (PII) and log every AI request inside your own Google Cloud project.

---

## 1-Minute Quickstart

### Prerequisites

1. [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install), `curl`, `openssl`, and `awk` installed, and `gcloud` logged in:
   ```bash
   gcloud auth login
   ```
2. A Google Cloud project with **billing enabled**, and you have **Owner** (or Editor + Security Admin) on it.
3. **Model Activation in Vertex AI Model Garden (Partner Models only):**
   Understanding which models work out-of-the-box vs. which require one-time activation in Google Cloud Console:

   | Model Family | Examples in `config.yaml` | Activation Required? |
   | :--- | :--- | :--- |
   | **Google Gemini** *(First-Party)* | `gemini-3.8-flash`, `gemini-3.7-flash`, `gemini-3.1-pro-preview` | **No** — automatically enabled when `./deploy.sh` enables the Vertex AI API (`aiplatform.googleapis.com`). |
   | **Anthropic Claude** *(Partner)* | `claude-sonnet-5`, `claude-opus-5` *(plus optional `claude-sonnet-4-6`, `claude-opus-4-6`, `claude-haiku-4-5@20251001`)* | **Yes (once per GCP project)** — open [Vertex AI Model Garden](https://console.cloud.google.com/vertex-ai/model-garden), select your GCP project, search for the model card (e.g. **Claude Opus 5** / **Claude Sonnet 5**), and click **Enable**. |

   > **Tip:** You can enable Claude models in Model Garden **before or after** running `./deploy.sh`. During deployment, `./deploy.sh` probes every model in `config.yaml` and automatically excludes any model that isn't enabled in Model Garden yet so broken models never clutter your CLI list.

---

### Step 1: Deploy in One Command

```bash
./deploy.sh --project YOUR_GCP_PROJECT_ID
```

That's it. The script is idempotent and safe to re-run at any time. It:

1. Runs pre-flight checks (tools installed, `gcloud` logged in, project accessible).
2. Enables required GCP APIs (`run`, `aiplatform`, `cloudbuild`, `artifactregistry`, `secretmanager`).
3. Creates a dedicated least-privilege Service Account (`antigravity-gateway-sa`) with only `roles/aiplatform.user`.
4. Generates a random 256-bit **gateway API key** (or reuses your existing one) in **Google Cloud Secret Manager** (`antigravity-gateway-api-key`).
5. Builds and deploys the LiteLLM Proxy container (`config.yaml` + `callbacks.py`) to **Cloud Run**.
6. **Probes every model in `config.yaml`** against Vertex AI to check which models are `✓ ACTIVE` vs `○ INACTIVE` (not yet enabled in Model Garden).
7. Generates **`admin_settings.json`** and **`gateway.env`** in this folder containing **only the verified active models**.
8. Runs `./scripts/test_gateway.sh` to verify health, authentication, Gemini and Claude streaming, and tool calling.

**Optional flags:**

| Flag | Default | Purpose |
| :--- | :--- | :--- |
| `-p, --project <ID>` | `gcloud config` project | Target GCP project ID |
| `-s, --service <NAME>` | `antigravity-enterprise-gateway` | Cloud Run service name (deploy multiple gateways side by side) |
| `-r, --region <REGION>` | `us-central1` | Cloud Run region |
| `-k, --api-key <KEY>` | reuse existing / generate | Set or **rotate** the gateway API key |
| `-m, --min-instances <N>` | `0` | Keep `N` instances warm to avoid ~10–20s cold starts (costs money) |
| `-S, --sync-models` | `false` | **Fast model sync (~5s):** Skip Cloud Run container build, re-probe active models in Model Garden, and regenerate `admin_settings.json` + `gateway.env` |

---

### Step 2: Connect Antigravity CLI (`agy`) & IDE

Install `admin_settings.json` with world-readable permissions (`0644`) **and** load `gateway.env`:

- **Linux:**
  ```bash
  # 1. Install admin_settings.json with 0644 permissions so non-root `agy` can read it
  sudo install -d -m 755 /etc/antigravity
  sudo install -m 644 admin_settings.json /etc/antigravity/admin_settings.json

  # 2. Load the active gateway model catalog into your current shell
  source gateway.env

  # Optional: Persist gateway.env for all new terminal sessions on Linux
  sudo install -m 644 gateway.env /etc/profile.d/antigravity-gateway.sh
  ```
- **macOS:**
  ```bash
  sudo install -d -m 755 "/Library/Application Support/Antigravity"
  sudo install -m 644 admin_settings.json "/Library/Application Support/Antigravity/admin_settings.json"
  source gateway.env
  ```
- **Windows (PowerShell as Administrator):**
  ```powershell
  New-Item -ItemType Directory -Force -Path "$env:ProgramData\Antigravity"
  Copy-Item admin_settings.json "$env:ProgramData\Antigravity\admin_settings.json"
  ```

Now verify your active model catalog and test inference with `agy`:

```bash
# 1. Check the active model list (should show ONLY your active gateway models)
agy models

# 2. Test Gemini (note: Gemini 3.x models in `agy` require an effort suffix -low/-medium/-high or --effort)
agy --model gemini-3.8-flash-low -p "Explain how binary search works"
agy --model gemini-3.8-flash --effort high -p "Explain how binary search works"

# 3. Test Claude Opus 5 & Claude Sonnet 5 (passed directly by model ID)
agy --model claude-opus-5 -p "Write a Python binary search implementation"
agy --model claude-sonnet-5 -p "Write a Python binary search implementation"
```

> **Why are both `install -m 644` and `source gateway.env` important?**
> 1. **File permissions (`0644`):** `deploy.sh` creates `admin_settings.json` with `0600` permissions locally. If you copy it with plain `sudo cp` without setting `0644`, `/etc/antigravity/admin_settings.json` becomes root-only (`-rw------- root:root`). The non-root `agy` CLI cannot read it and silently falls back to the consumer Antigravity catalog (which lists consumer defaults like `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, and `gpt-oss-120b-medium`). Using `sudo install -m 644` prevents this.
> 2. **`AGY_LLM_GATEWAY_MODELS` (`gateway.env`):** While the Antigravity IDE reads `models.list` from `admin_settings.json`, the `agy` CLI discovers custom/partner gateway models (such as `claude-opus-5` and `claude-sonnet-5`) from the `AGY_LLM_GATEWAY_MODELS` environment variable exported by `gateway.env`.

---

## Managing Models: How & When to Enable, Add, or Remove Models

### Where Models Are Configured (3 Layers)

```
┌────────────────────────────────────────────────────────────────────────────┐
│ 1. Vertex AI Model Garden (GCP Console)                                    │
│    • Grants your GCP project access to Partner models (Claude Opus 5, etc.)│
│    • Gemini models do NOT need this step (auto-enabled with Vertex AI API) │
└─────────────────────────────────────┬──────────────────────────────────────┘
                                      ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ 2. config.yaml (LiteLLM Proxy Server on Cloud Run)                         │
│    • `model_list`: Every model the gateway is allowed to route to          │
│    • `model_group_alias`: Shorthand aliases (e.g. opus-5 -> claude-opus-5) │
│    • `fallbacks`: Automatic retry fallback chains on HTTP 429 / 5xx        │
└─────────────────────────────────────┬──────────────────────────────────────┘
                                      ▼  (./deploy.sh probes & generates)
┌────────────────────────────────────────────────────────────────────────────┐
│ 3. admin_settings.json + gateway.env (Developer Workstation)               │
│    • Contains ONLY the models from config.yaml that are ACTIVE in GCP      │
│    • Controls what appears in `agy models` and the Antigravity IDE picker  │
└────────────────────────────────────────────────────────────────────────────┘
```

### Quick Decision Guide: What Should I Run?

| What you want to do | Where to make the change | Command to run | Redeploys Cloud Run? |
| :--- | :--- | :--- | :--- |
| **I just enabled `claude-opus-5` or `claude-sonnet-5` in Model Garden** *(already in `config.yaml`)* | [Vertex AI Model Garden](https://console.cloud.google.com/vertex-ai/model-garden) → click **Enable** | `./deploy.sh --project <PROJECT> --service <SERVICE> --sync-models` then re-copy `admin_settings.json` & `source gateway.env` | **No** (~5 seconds) |
| **I want to add a brand-new model** *(or uncomment `claude-sonnet-4-6`, `gemini-2.5-pro`, `gpt-4o`, etc.)* | 1. Enable in Model Garden (if Partner model)<br>2. Add/uncomment under `model_list` in `config.yaml` | `./deploy.sh --project <PROJECT> --service <SERVICE>` then re-copy `admin_settings.json` & `source gateway.env` | **Yes** (~3–5 minutes) |
| **I want to remove a model for everyone** | Remove or comment out the model block under `model_list` in `config.yaml` (and remove from `fallbacks`) | `./deploy.sh --project <PROJECT> --service <SERVICE>` then re-copy `admin_settings.json` & `source gateway.env` | **Yes** (~3–5 minutes) |
| **I want to hide a model on my machine only** | Remove the model ID from `AGY_LLM_GATEWAY_MODELS` in `gateway.env` and `models` in `/etc/antigravity/admin_settings.json` | `source gateway.env` | **No** (instant) |

---

### Detailed Examples

#### Example A: Enabling a Partner Model in Vertex AI Model Garden (e.g., Claude Opus 5)
1. Open [Vertex AI Model Garden](https://console.cloud.google.com/vertex-ai/model-garden) and make sure your GCP project is selected at the top.
2. Search for **Claude Opus 5** (or **Claude Sonnet 5**), open its model card, and click **Enable** (accept the partner terms if prompted).
3. Verify the **Model ID** on the card (e.g. `claude-opus-5`).
4. Since `claude-opus-5` and `claude-sonnet-5` are already in `config.yaml` by default, you do **not** need to rebuild the container. Just sync your local client config:
   ```bash
   ./deploy.sh --project YOUR_GCP_PROJECT_ID --service YOUR_SERVICE_NAME --sync-models
   sudo install -m 644 admin_settings.json /etc/antigravity/admin_settings.json
   source gateway.env
   ```
5. Confirm `claude-opus-5` now appears in `agy models` and test it:
   ```bash
   agy models
   agy --model claude-opus-5 -p "Hello from Claude Opus 5!"
   ```

#### Example B: Adding a New Model to `config.yaml`
Suppose you want to add `claude-haiku-4-5@20251001` (from Vertex AI Model Garden) or `gpt-4o` (from OpenAI):

1. If it is a Vertex AI Partner model, enable it in [Vertex AI Model Garden](https://console.cloud.google.com/vertex-ai/model-garden) first.
2. Open `config.yaml` and add (or uncomment) the entry under `model_list`:
   ```yaml
   model_list:
     # Vertex AI Model Garden model:
     - model_name: claude-haiku-4-5@20251001
       litellm_params:
         model: vertex_ai/claude-haiku-4-5@20251001
         vertex_project: os.environ/GCP_PROJECT_ID
         vertex_location: global

     # Or a third-party provider (OpenAI, Anthropic direct, AWS Bedrock, etc.):
     - model_name: gpt-4o
       litellm_params:
         model: openai/gpt-4o
         api_key: os.environ/OPENAI_API_KEY
   ```
3. Redeploy the gateway so LiteLLM loads the updated `config.yaml`, probes the new model, and updates `admin_settings.json` and `gateway.env`:
   ```bash
   ./deploy.sh --project YOUR_GCP_PROJECT_ID --service YOUR_SERVICE_NAME
   sudo install -m 644 admin_settings.json /etc/antigravity/admin_settings.json
   source gateway.env
   ```

#### Example C: Removing a Model
1. Open `config.yaml` and delete or comment out the `- model_name: ...` block under `model_list` (also check `router_settings.fallbacks` to make sure no other model falls back to it).
2. Re-run `./deploy.sh --project YOUR_GCP_PROJECT_ID --service YOUR_SERVICE_NAME`, then re-run:
   ```bash
   sudo install -m 644 admin_settings.json /etc/antigravity/admin_settings.json
   source gateway.env
   ```

---

## Authentication & Security

**Short answer: API-key authentication enforced by LiteLLM. Not IAP.**

Here is how a request is authenticated, step by step:

```
Antigravity CLI / IDE
   │  reads gateway.apiKey from admin_settings.json / AGY_LLM_GATEWAY_API_KEY
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
| **Where the key lives** | Google Cloud Secret Manager (`antigravity-gateway-api-key`). Only the gateway's Service Account has `secretAccessor`. On developer machines it's in `admin_settings.json` / `gateway.env`. |
| **What the gateway can do in GCP** | Only `roles/aiplatform.user` (call Vertex AI models) through its dedicated Service Account. Nothing else. |
| **Transport** | HTTPS only (Cloud Run managed TLS). |

### Why not IAP?
Cloud Run supports [Identity-Aware Proxy](https://cloud.google.com/run/docs/securing/identity-aware-proxy-cloud-run). However, IAP requires each client to obtain a short-lived Google OIDC token per user, and Antigravity's gateway setting sends a **static** API key (`apiKey` + optional `customHeaders`). An IAP-protected gateway would reject the CLI. API-key auth at the LiteLLM layer is the supported model for this integration.

### Rotating the API key
```bash
./deploy.sh --project YOUR_GCP_PROJECT_ID --api-key "sk-agy-$(openssl rand -hex 32)"
```
This stores the new key as the latest Secret Manager version, rolls out a new Cloud Run revision, **disables the old key version**, and regenerates `admin_settings.json` and `gateway.env`. Redistribute the updated files to your developers.

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
│              Developer Workstation (Antigravity CLI / IDE)              │
│  Reads /etc/antigravity/admin_settings.json + gateway.env               │
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
│      - Resolves model_group_alias (e.g. opus-5 -> claude-opus-5)        │
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
     │  • gemini-3.1-pro-preview │       │  • (optional 4.6 / Haiku) │
     └───────────────────────────┘       └───────────────────────────┘
```

---

## Repository Structure

```text
.
├── config.yaml                 # LiteLLM Proxy model list, aliases, fallbacks & settings
├── callbacks.py                # LiteLLM plugin normalizing Antigravity protojson quirks
├── Dockerfile                  # Extends the pinned official LiteLLM image
├── deploy.sh                   # One-command Cloud Run deployment, model probe & config generator
├── admin_settings.example.json # Reference template for the Antigravity enterprise client config
├── scripts/
│   └── test_gateway.sh         # End-to-end security, streaming & tool-calling checks
└── README.md                   # This guide
```

---

## LiteLLM Features & Upgrade Path

### Built-in endpoints
- **Swagger / OpenAPI explorer:** `https://<YOUR_GATEWAY_URL>/` (root path)
- **Model list:** `GET https://<YOUR_GATEWAY_URL>/v1/models` (needs the API key)
- **OpenAI-compatible:** `POST https://<YOUR_GATEWAY_URL>/v1/chat/completions`. Other tools (Cursor, Continue, LangChain, the OpenAI SDK) can share the same gateway.

### Upgrade path: per-developer keys, budgets & Admin UI
The PoC runs **stateless** (no database). That's why the LiteLLM Admin UI at `/ui` loads but login fails with *"Not connected to DB"*. To unlock virtual keys, teams, spend tracking, budgets and the Admin UI:

1. Create a Postgres database (e.g. Cloud SQL for PostgreSQL) and store its connection string in Secret Manager as `litellm-database-url`.
2. Grant `antigravity-gateway-sa` `roles/secretmanager.secretAccessor` on it (plus `roles/cloudsql.client` if using Cloud SQL connectors).
3. Add `DATABASE_URL=litellm-database-url:latest` to `--set-secrets` in `deploy.sh` and re-run it. LiteLLM runs its schema migrations automatically on startup.
4. Log in to `https://<YOUR_GATEWAY_URL>/ui` with username `admin` and the master key, then issue one virtual key per developer and put *that* key in their `admin_settings.json` / `gateway.env`.

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
  ✓ PASS: Claude Opus 5 GenAI-to-Anthropic SSE streaming succeeded
  ✓ PASS: Claude Sonnet 5 tool calling with Antigravity protojson schema succeeded
  ✓ PASS: OpenAI-compatible endpoint (/v1/chat/completions) succeeded
```

---

## Troubleshooting

| Symptom | Cause | Fix |
| :--- | :--- | :--- |
| **`agy models` shows `claude-sonnet-4-6` / `gpt-oss-120b-medium` and is missing `claude-opus-5` / `claude-sonnet-5`** | 1. `/etc/antigravity/admin_settings.json` was copied with `0600` permissions (unreadable by non-root `agy`), so `agy` fell back to consumer mode, **or**<br>2. `AGY_LLM_GATEWAY_MODELS` (`gateway.env`) was not sourced in the shell. | Run:<br>`sudo install -d -m 755 /etc/antigravity && sudo install -m 644 admin_settings.json /etc/antigravity/admin_settings.json`<br>`source gateway.env` |
| **`--model gemini-3.8-flash requires --effort (available: low, medium, high)`** | Built-in Gemini 3.x models in `agy` require a thinking effort tier. | Use a tier suffix (`agy --model gemini-3.8-flash-low`, `-medium`, or `-high`) or pass `--effort` (`agy --model gemini-3.8-flash --effort low`). Partner models (`claude-opus-5`, `claude-sonnet-5`) do not need `--effort`. |
| **`model claude-opus-5 is not recognized as a known model or custom model in settings`** | `AGY_LLM_GATEWAY_MODELS` is not exported in your current shell, or `claude-opus-5` was not enabled in Model Garden when `gateway.env` was generated. | Enable Claude Opus 5 in [Vertex AI Model Garden](https://console.cloud.google.com/vertex-ai/model-garden), run `./deploy.sh --project YOUR_PROJECT_ID --sync-models`, then `source gateway.env`. |
| **Claude returns `404` or `403` from Vertex AI** | The Claude model has not been enabled in your GCP project's Model Garden. | Open [Vertex AI Model Garden](https://console.cloud.google.com/vertex-ai/model-garden), select your project, click the Claude model card, and click **Enable**. |
| **`401` "No api key passed in"** | The client isn't sending `Authorization: Bearer`. | Check that `gateway.apiKey` is set in `/etc/antigravity/admin_settings.json` and `source gateway.env` has been run. |
| **`400` "No connected db"** | The client sent an API key that **doesn't match** the gateway key (stateless mode). | Re-run `./deploy.sh --project YOUR_PROJECT_ID --sync-models`, reinstall `admin_settings.json`, and `source gateway.env`. |
| **`403 Forbidden` HTML page from Google** | An org policy blocks public Cloud Run services. | Re-run `./deploy.sh`. It detects this and applies `--no-invoker-iam-check` automatically. |
| **First request after idle is slow / times out** | Cloud Run cold start (scale-to-zero). | `./deploy.sh --project YOUR_PROJECT_ID --min-instances 1` |
| **`429` / quota errors** | Vertex AI quota exhausted for a model. | Fallbacks in `config.yaml` kick in automatically. Request more quota in the Cloud Console if they persist. |
| **See server logs** | — | `gcloud run services logs read antigravity-enterprise-gateway --project=YOUR_PROJECT_ID --region=us-central1 --limit=50` |
