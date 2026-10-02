#!/usr/bin/env bash
# =============================================================================
# Antigravity Enterprise Gateway (LiteLLM Proxy) — Turnkey Deployment Script
# =============================================================================
# Usage:
#   ./deploy.sh --project <GCP_PROJECT_ID> [options]
#
# Options:
#   -p, --project <ID>         GCP project to deploy into (default: gcloud config project)
#   -r, --region <REGION>      Cloud Run region (default: us-central1)
#   -k, --api-key <KEY>        Use / rotate to this gateway API key (default: reuse or generate)
#   -s, --service <NAME>       Cloud Run service name (default: antigravity-enterprise-gateway)
#   -m, --min-instances <N>    Keep N warm instances to avoid cold starts (default: 0)
#   -h, --help                 Show this help
#
# What this script does automatically:
#   0. Pre-flight checks (required tools, gcloud login)
#   1. Resolves the target GCP project
#   2. Enables required GCP APIs (Cloud Run, Vertex AI, Cloud Build, Secret Manager)
#   3. Creates a dedicated least-privilege IAM Service Account
#   4. Stores (or generates) the gateway API key in Google Cloud Secret Manager
#   5. Deploys the official LiteLLM Proxy container to Cloud Run
#   6. Generates a ready-to-use local `admin_settings.json` for Antigravity IDE / CLI
#   7. Runs end-to-end verification tests (Health, Auth, Gemini, Claude, Tool Calls)
#
# Safe to re-run at any time: every step is idempotent.
# =============================================================================

set -euo pipefail

# Always run from the folder containing this script (Dockerfile, config.yaml, ...)
cd "$(dirname "${BASH_SOURCE[0]}")"

# Ensure gcloud is on PATH if installed in ~/google-cloud-sdk/bin
if ! command -v gcloud >/dev/null 2>&1 && [[ -x "${HOME}/google-cloud-sdk/bin/gcloud" ]]; then
  export PATH="${HOME}/google-cloud-sdk/bin:${PATH}"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SERVICE_NAME="antigravity-enterprise-gateway"
CLOUD_RUN_REGION="us-central1"
VERTEX_LOCATION="global"
SA_NAME="antigravity-gateway-sa"
SECRET_NAME="antigravity-gateway-api-key"
MIN_INSTANCES="0"
PROJECT_ID="${GCP_PROJECT_ID:-}"
CUSTOM_API_KEY="${LITELLM_MASTER_KEY:-${GATEWAY_API_KEY:-}}"

usage() { sed -n '5,14p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo -e "${RED}Error:${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)       PROJECT_ID="${2:?missing value for $1}"; shift 2 ;;
    -r|--region)        CLOUD_RUN_REGION="${2:?missing value for $1}"; shift 2 ;;
    -k|--api-key)       CUSTOM_API_KEY="${2:?missing value for $1}"; shift 2 ;;
    -s|--service)       SERVICE_NAME="${2:?missing value for $1}"; shift 2 ;;
    -m|--min-instances) MIN_INSTANCES="${2:?missing value for $1}"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage; die "Unknown argument: $1" ;;
  esac
done

echo -e "${BLUE}${BOLD}======================================================================${NC}"
echo -e "${BLUE}${BOLD}   Antigravity Enterprise Gateway — Official LiteLLM Proxy Deploy     ${NC}"
echo -e "${BLUE}${BOLD}======================================================================${NC}"

# 0. Pre-flight checks
for tool in gcloud curl openssl sed; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed. See README.md → Prerequisites."
done
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n1 || true)
[[ -n "$ACTIVE_ACCOUNT" ]] || die "You are not logged in to gcloud. Run: ${BOLD}gcloud auth login${NC}"
[[ "$MIN_INSTANCES" =~ ^[0-9]+$ ]] || die "--min-instances must be a non-negative integer."

# 1. Resolve GCP Project ID
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
fi
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  die "No GCP Project ID specified. Run: ${BOLD}./deploy.sh --project YOUR_GCP_PROJECT_ID${NC}"
fi
gcloud projects describe "$PROJECT_ID" --format="value(projectId)" >/dev/null 2>&1 \
  || die "Project '${PROJECT_ID}' not found or ${ACTIVE_ACCOUNT} has no access to it."

echo -e "${GREEN}[1/7] Target GCP Project:${NC} ${BOLD}${PROJECT_ID}${NC} as ${ACTIVE_ACCOUNT} (Cloud Run: ${CLOUD_RUN_REGION}, Vertex AI: ${VERTEX_LOCATION})"

# 2. Enable Required Google Cloud APIs
echo -e "${GREEN}[2/7] Enabling required Google Cloud APIs (first run can take ~1 min)...${NC}"
gcloud services enable \
  run.googleapis.com \
  aiplatform.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

# 3. Create Dedicated Least-Privilege Service Account
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
echo -e "${GREEN}[3/7] Configuring least-privilege Service Account (${SA_EMAIL})...${NC}"

if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Antigravity LiteLLM Gateway Service Account" \
    --project="$PROJECT_ID" \
    --quiet
fi

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/aiplatform.user" \
  --condition=None \
  --quiet >/dev/null

# 4. Provision the Gateway API Key (LiteLLM Master Key) in Secret Manager
echo -e "${GREEN}[4/7] Provisioning gateway API key in Secret Manager (${SECRET_NAME})...${NC}"

if ! gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud secrets create "$SECRET_NAME" \
    --replication-policy="automatic" \
    --project="$PROJECT_ID" \
    --quiet
fi

EXISTING_KEY=$(gcloud secrets versions access latest --secret="$SECRET_NAME" --project="$PROJECT_ID" 2>/dev/null || true)
NEW_VERSION_ADDED=false

if [[ -n "$CUSTOM_API_KEY" && "$CUSTOM_API_KEY" != "$EXISTING_KEY" ]]; then
  ACTIVE_API_KEY="$CUSTOM_API_KEY"
  printf "%s" "$ACTIVE_API_KEY" | gcloud secrets versions add "$SECRET_NAME" \
    --data-file=- --project="$PROJECT_ID" --quiet >/dev/null
  NEW_VERSION_ADDED=true
  echo -e "      Rotated: stored the provided API key as the latest Secret Manager version."
elif [[ -n "$EXISTING_KEY" ]]; then
  ACTIVE_API_KEY="$EXISTING_KEY"
  echo -e "      Reusing existing API key from Secret Manager."
else
  ACTIVE_API_KEY="sk-agy-$(openssl rand -hex 32)"
  printf "%s" "$ACTIVE_API_KEY" | gcloud secrets versions add "$SECRET_NAME" \
    --data-file=- --project="$PROJECT_ID" --quiet >/dev/null
  NEW_VERSION_ADDED=true
  echo -e "      Generated a new random 256-bit API key and stored it in Secret Manager."
fi

gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="$PROJECT_ID" \
  --quiet >/dev/null

# 5. Deploy Official LiteLLM Proxy Container to Cloud Run
echo -e "${GREEN}[5/7] Building and deploying official LiteLLM Proxy (${SERVICE_NAME}) to Cloud Run (~3-5 min)...${NC}"
# Network access is public (the IDE must reach it from anywhere); every model
# request is authenticated by LiteLLM using the API key from Secret Manager.
gcloud run deploy "$SERVICE_NAME" \
  --source . \
  --project="$PROJECT_ID" \
  --region="$CLOUD_RUN_REGION" \
  --service-account="$SA_EMAIL" \
  --allow-unauthenticated \
  --memory="1Gi" \
  --cpu="2" \
  --cpu-boost \
  --min-instances="$MIN_INSTANCES" \
  --timeout="600" \
  --set-env-vars="GCP_PROJECT_ID=${PROJECT_ID},VERTEXAI_PROJECT=${PROJECT_ID},VERTEXAI_LOCATION=${VERTEX_LOCATION}" \
  --set-secrets="LITELLM_MASTER_KEY=${SECRET_NAME}:latest,GATEWAY_API_KEY=${SECRET_NAME}:latest" \
  --quiet

SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$CLOUD_RUN_REGION" \
  --format="value(status.url)")

# Organizations with the "Domain Restricted Sharing" policy block `allUsers`
# IAM bindings, so Cloud Run answers 403 before LiteLLM ever sees the request.
# Fallback: disable the Cloud Run invoker IAM check (LiteLLM still enforces the API key).
wait_for_health() {
  local code=""
  for _ in $(seq 1 12); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "${SERVICE_URL}/health/liveliness" || true)
    [[ "$code" == "200" || "$code" == "403" ]] && break
    sleep 5
  done
  echo "$code"
}
HEALTH_CODE=$(wait_for_health)
if [[ "$HEALTH_CODE" == "403" ]]; then
  echo -e "${YELLOW}      Cloud Run returned 403 (likely org policy blocking public access). Disabling the invoker IAM check...${NC}"
  gcloud run services update "$SERVICE_NAME" \
    --project="$PROJECT_ID" \
    --region="$CLOUD_RUN_REGION" \
    --no-invoker-iam-check \
    --quiet
  HEALTH_CODE=$(wait_for_health)
fi
[[ "$HEALTH_CODE" == "200" ]] || die "Gateway health check returned HTTP ${HEALTH_CODE}. See README.md → Troubleshooting."

# Once the new revision is serving, disable superseded keys so they stop working.
if [[ "$NEW_VERSION_ADDED" == "true" ]]; then
  LATEST_VERSION=$(gcloud secrets versions list "$SECRET_NAME" --project="$PROJECT_ID" \
    --filter="state=ENABLED" --sort-by="~createTime" --limit=1 --format="value(name.basename())")
  for v in $(gcloud secrets versions list "$SECRET_NAME" --project="$PROJECT_ID" \
      --filter="state=ENABLED" --format="value(name.basename())"); do
    if [[ "$v" != "$LATEST_VERSION" ]]; then
      gcloud secrets versions disable "$v" --secret="$SECRET_NAME" --project="$PROJECT_ID" --quiet >/dev/null
      echo -e "      Disabled superseded API key (Secret Manager version ${v})."
    fi
  done
fi

# 6. Generate Local admin_settings.json
echo -e "${GREEN}[6/7] Generating ready-to-use admin_settings.json...${NC}"
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&|\\]/\\&/g'; }
sed -e "s|https://antigravity-enterprise-gateway-XXXXXXXXXX.us-central1.run.app|$(sed_escape "$SERVICE_URL")|g" \
    -e "s|REPLACE_WITH_YOUR_GATEWAY_API_KEY|$(sed_escape "$ACTIVE_API_KEY")|g" \
    admin_settings.example.json > admin_settings.json
chmod 600 admin_settings.json

# 7. Run Post-Deployment Verification Suite
echo -e "${GREEN}[7/7] Running post-deployment verification checks...${NC}"
chmod +x ./scripts/test_gateway.sh
LITELLM_MASTER_KEY="$ACTIVE_API_KEY" ./scripts/test_gateway.sh "$SERVICE_URL"

echo ""
echo -e "${BLUE}${BOLD}======================================================================${NC}"
echo -e "${GREEN}${BOLD}   LiteLLM Proxy Deployment Complete & Verified!                      ${NC}"
echo -e "${BLUE}${BOLD}======================================================================${NC}"
echo -e "${BOLD}Gateway URL:${NC}       ${SERVICE_URL}"
echo -e "${BOLD}API Docs:${NC}          ${SERVICE_URL}/  (Swagger UI)"
echo -e "${BOLD}API Key stored in:${NC} projects/${PROJECT_ID}/secrets/${SECRET_NAME}"
echo -e "${BOLD}Generated Config:${NC}  $(pwd)/admin_settings.json  (contains the API key — treat as a secret)"
echo ""
echo -e "${YELLOW}${BOLD}How clients authenticate:${NC}"
echo -e "  Antigravity sends 'Authorization: Bearer <apiKey from admin_settings.json>' on every request."
echo -e "  Requests without a valid key are rejected by LiteLLM. Rotate with: ./deploy.sh --project ${PROJECT_ID} --api-key <NEW_KEY>"
echo ""
echo -e "${YELLOW}${BOLD}Install for Antigravity IDE / CLI (Linux):${NC}"
echo -e "  sudo mkdir -p /etc/antigravity && sudo cp admin_settings.json /etc/antigravity/admin_settings.json"
echo ""
echo -e "${YELLOW}${BOLD}Quick Test with Antigravity CLI (agy):${NC}"
echo -e "  agy --model gemini-3.8-flash -p \"Explain how binary search works\""
echo -e "  agy --model claude-sonnet-5 -p \"Explain how binary search works\""
echo ""
