#!/bin/sh
set -e

# ── Start Ollama server in the background ──────────────────────────────────
ollama serve &
OLLAMA_PID=$!

# ── Wait until the API is ready — ollama CLI is always present ────────────
echo "[entrypoint] Waiting for ollama API..."
tries=0
until ollama list > /dev/null 2>&1; do
    sleep 1
    tries=$((tries + 1))
    if [ $tries -ge 30 ]; then echo "[entrypoint] ERROR: ollama did not respond after 30s"; exit 1; fi
done
echo "[entrypoint] Ollama ready."

# ── Optional web UI (FRONTEND=1 enables it; default is API only) ──────────
if [ "${FRONTEND:-0}" = "1" ]; then
    echo "[entrypoint] Serving UI on http://0.0.0.0:8080"
    /app/serve &
fi

# ── Keep container alive; exit if ollama dies ─────────────────────────────
wait $OLLAMA_PID
