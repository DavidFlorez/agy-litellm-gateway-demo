# =============================================================================
# Antigravity Enterprise Gateway — Official LiteLLM Proxy Container
# =============================================================================
# The base image is PINNED to an exact, verified digest (LiteLLM v1.105.0) so
# every customer deployment is reproducible. `main-latest` moves several times a
# week, and callbacks.py hooks into LiteLLM's GoogleGenAIAdapter internals.
#
# To upgrade: change LITELLM_IMAGE, redeploy, and re-run ./scripts/test_gateway.sh.
ARG LITELLM_IMAGE=ghcr.io/berriai/litellm:main-latest@sha256:a69f5f0c56b868d2fdfce7abfb037fed947b70ede202047ffc19c14dc96ab90a
FROM ${LITELLM_IMAGE}

WORKDIR /app

# Copy official LiteLLM Proxy configuration and Antigravity protojson callback
COPY config.yaml /app/config.yaml
COPY callbacks.py /app/callbacks.py

ENV PORT=8080
EXPOSE 8080

# Launch the official LiteLLM Proxy server (`litellm --config /app/config.yaml --port 8080`)
CMD ["--config", "/app/config.yaml", "--port", "8080"]
