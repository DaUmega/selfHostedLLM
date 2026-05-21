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

# ── Serve the web UI on port 8080 ─────────────────────────────────────────
echo "[entrypoint] Serving UI on http://0.0.0.0:8080"
python3 -m http.server 8080 --directory /app &

# ── Keep container alive; exit if ollama dies ─────────────────────────────
wait $OLLAMA_PID
