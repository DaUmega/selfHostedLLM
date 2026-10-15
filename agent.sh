#!/bin/sh
# agent: the agentic loop, with auto model detection (mirrors `manage.sh agent`).
# Run inside the appliance, e.g.:  ssh ai@<onion>  →  agent "task..."
export MODEL="${MODEL:-$(ollama list 2>/dev/null | awk 'NR>1 && NF {print $1; exit}')}"
[ -n "$MODEL" ] || { echo "error: no models installed (run: ollama pull <model>)" >&2; exit 1; }
echo "Agent → model=$MODEL workdir=/work"
exec /app/agent "$@"
