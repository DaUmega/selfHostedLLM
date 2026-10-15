#!/usr/bin/env bash
# offline-ai container manager: ollama + web UI + agentic loop, all in docker
# Usage: ./manage.sh <command> [args]
set -euo pipefail

IMAGE="offline-ai"
CONTAINER="offline-ai"
VOLUME="ollama-models"          # persists /root/.ollama across rebuilds
UI_PORT="${UI_PORT:-8080}"
API_PORT="${API_PORT:-11434}"

# GPU flag - auto-detected; override with GPU=0 ./manage.sh start
GPU="${GPU:-auto}"

# Frontend: 1 = serve web UI on :8080, 0 = API only (manage.sh prints curl samples)
FRONTEND="${FRONTEND:-0}"

# Shared folder: host dir mounted at /work inside the container.
# Drop files here and the agent can read/edit them.
WORKDIR="${WORKDIR:-./work}"

# Bind address for published ports. 127.0.0.1 = only this machine (and your
# SSH port-forwards) can reach the API/UI. Set to 0.0.0.0 for LAN access.
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"

# Agent defaults (overridable per-command, see ./manage.sh agent --help)
# MODEL: if unset, the agent auto-uses the first installed model.
MAX_STEPS="${MAX_STEPS:-10}"
GATE="${GATE:-auto}"             # auto | confirm

resolve_model() {
    # Explicit MODEL wins; otherwise use the first model in `ollama list`.
    if [[ -n "${MODEL:-}" ]]; then echo "$MODEL"; return 0; fi
    docker exec "$CONTAINER" ollama list 2>/dev/null | awk 'NR>1 && NF {print $1; exit}'
}

# ── helpers ───────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n'  "$*"; }
bold()  { printf '\033[1m%s\033[0m\n'  "$*"; }

die() { red "error: $*"; exit 1; }

require() { command -v "$1" &>/dev/null || die "'$1' not found in PATH"; }

is_running() { docker ps -q -f name="^${CONTAINER}$" 2>/dev/null | grep -q .; }

gpu_flags() {
    if [[ "$GPU" == "0" ]]; then
        echo ""
    elif docker info 2>/dev/null | grep -q "nvidia"; then
        echo "--gpus all"
    else
        echo ""
    fi
}

exec_ollama() {
    # Run an ollama command inside the container
    docker exec "$CONTAINER" ollama "$@"
}

# ── commands ──────────────────────────────────────────────────────────────

cmd_build() {
    bold "Building image: $IMAGE"
    docker build -t "$IMAGE" .
    green "Done."
}

cmd_start() {
    require docker
    if is_running; then
        green "Already running."
        [[ "$FRONTEND" == "1" ]] && dim "  UI  → http://localhost:${UI_PORT}"
        dim "  API → http://localhost:${API_PORT}"
        return
    fi

    # Build if image doesn't exist
    if ! docker image inspect "$IMAGE" &>/dev/null; then
        cmd_build
    fi

    mkdir -p "$WORKDIR"
    local workdir_abs
    workdir_abs="$(cd "$WORKDIR" && pwd)"

    local -a ports=(-p "${BIND_ADDR}:${API_PORT}:11434" -p "${BIND_ADDR}:${UI_PORT}:8080")

    bold "Starting container: $CONTAINER"
    dim "  shared folder: $workdir_abs → /work"
    # shellcheck disable=SC2086
    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        "${ports[@]}" \
        -v "${VOLUME}:/root/.ollama" \
        -v "${workdir_abs}:/work" \
        -e OLLAMA_ORIGINS="*" \
        -e FRONTEND="$FRONTEND" \
        $(gpu_flags) \
        "$IMAGE"

    bold "Container logs (live - waiting for API on :${API_PORT})..."
    dim  "────────────────────────────────────────"

    # Stream container logs so you can see exactly what is happening
    docker logs -f "$CONTAINER" &
    LOGS_PID=$!

    # Poll until the ollama CLI inside the container responds
    local tries=0 ready=0
    while [[ $tries -lt 60 ]]; do
        if docker exec "$CONTAINER" ollama list >/dev/null 2>&1; then
            ready=1; break
        fi
        sleep 1
        tries=$((tries + 1))
    done

    kill $LOGS_PID 2>/dev/null || true
    wait $LOGS_PID 2>/dev/null || true
    dim  "────────────────────────────────────────"

    if [[ $ready -eq 0 ]]; then
        red "API did not become ready after 60s - run: ./manage.sh logs"
        exit 1
    fi

    green "Ready."
    if [[ "$FRONTEND" == "1" ]]; then
        dim "  UI  → http://localhost:${UI_PORT}"
        dim "  API → http://localhost:${API_PORT}"
    else
        dim "  API → http://localhost:${API_PORT}  (frontend disabled)"
        dim "  Enable the web UI anytime: ./manage.sh ui on"
        echo
        _api_samples
    fi
}

cmd_stop() {
    bold "Stopping $CONTAINER"
    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm   "$CONTAINER" 2>/dev/null || true
    green "Stopped."
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_rebuild() {
    cmd_stop
    cmd_build
    cmd_start
}

cmd_logs() {
    docker logs -f "$CONTAINER"
}

cmd_shell() {
    docker exec -it "$CONTAINER" /bin/bash
}

cmd_status() {
    if is_running; then
        green "Running"
        docker ps --filter "name=^${CONTAINER}$" --format "  id={{.ID}}  uptime={{.RunningFor}}  ports={{.Ports}}"
    else
        dim "Not running"
    fi
    echo
    dim "Volume: $VOLUME"
    docker volume inspect "$VOLUME" --format "  mountpoint: {{.Mountpoint}}" 2>/dev/null || dim "  (volume not yet created)"
    dim "Shared folder: $WORKDIR → /work"
}

# ── agent ─────────────────────────────────────────────────────────────────

cmd_agent() {
    # Run the agentic loop inside the container (tools sandboxed to /work).
    # Usage: ./manage.sh agent [--confirm] [--steps N] [--resume] "task..."
    # Env overrides: MODEL=<name> (default: first installed model) | MAX_STEPS=10 | GATE=auto|confirm
    is_running || die "Container not running. Run: ./manage.sh start"

    local gate="$GATE" steps="$MAX_STEPS" resume="" task=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --confirm) gate="confirm"; shift ;;
            --steps)   steps="$2"; shift 2 ;;
            --resume)  resume="--resume"; shift ;;
            --)        shift; task+=("$@"); break ;;
            -*)        die "Unknown flag: $1" ;;
            *)         task+=("$1"); shift ;;
        esac
    done
    [[ ${#task[@]} -eq 0 && -z "$resume" ]] && die "Usage: ./manage.sh agent [--confirm] [--steps N] [--resume] \"task...\""

    local model
    model="$(resolve_model)"
    [[ -n "$model" ]] || die "No models installed. Pull one first, e.g.: ./manage.sh pull llama3.2"

    bold "Agent → model=$model steps=$steps gate=$gate"
    dim  "  workdir is /work (mounted from ./$WORKDIR on host)"
    docker exec -it \
        -e MODEL="$model" \
        -e MAX_STEPS="$steps" \
        -e GATE="$gate" \
        "$CONTAINER" /app/agent $resume "${task[@]}"
}

# ── api samples ───────────────────────────────────────────────────────────

_api_samples() {
    local model="${1:-<model>}"
    local base="http://localhost:${API_PORT}"
    bold "Sample API usage:"
    echo
    dim  "# list models"
    echo "curl -s $base/api/tags | python3 -c 'import json,sys; [print(m[\"name\"]) for m in json.load(sys.stdin)[\"models\"]]'"
    echo
    dim  "# chat (non-streaming)"
    echo "curl -s $base/api/chat -d '{\"model\":\"$model\",\"stream\":false,"
    echo "  \"messages\":[{\"role\":\"user\",\"content\":\"write a python hello world\"}]}'"
    echo
    dim  "# one-shot generate"
    echo "curl -s $base/api/generate -d '{\"model\":\"$model\",\"stream\":false,"
    echo "  \"prompt\":\"Explain what a port scan is in one sentence.\"}'"
    echo
    dim  "# streaming chat (newline-delimited JSON)"
    echo "curl -N $base/api/chat -d '{\"model\":\"$model\","
    echo "  \"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
}

cmd_api() {
    is_running || die "Container not running. Run: ./manage.sh start"
    _api_samples "$(resolve_model 2>/dev/null || true)"
}

# ── web UI toggle ─────────────────────────────────────────────────────────

ui_running() {
    docker exec "$CONTAINER" pgrep -f "/app/serve" >/dev/null 2>&1
}

cmd_ui() {
    # Toggle the web UI on a running container (runtime only, not sticky).
    # Usage: ./manage.sh ui [on|off|status]
    is_running || die "Container not running. Run: ./manage.sh start"
    case "${1:-status}" in
        on)
            if ui_running; then
                dim "Web UI already on → http://localhost:${UI_PORT}"
            else
                docker exec -d "$CONTAINER" /app/serve
                green "Web UI on → http://localhost:${UI_PORT}"
            fi
            ;;
        off)
            docker exec "$CONTAINER" pkill -f "/app/serve" >/dev/null 2>&1 || true
            green "Web UI off."
            ;;
        status)
            ui_running && green "Web UI on → http://localhost:${UI_PORT}" || dim "Web UI off"
            ;;
        *) die "Usage: ./manage.sh ui [on|off|status]" ;;
    esac
}

# ── sharing ───────────────────────────────────────────────────────────────

cmd_share() {
    # Print the copy-paste Tor+SSH one-liner for loved ones (web UI only, no shell).
    # Their key must be authorized with forwarding-only restrictions (see README).
    local onion
    onion="$(sudo cat /var/lib/tor/ssh_hidden/hostname 2>/dev/null || true)"
    [ -n "$onion" ] || die "No Tor hidden service on this host. Run: tor-ssh serve"

    local user="${SUDO_USER:-$USER}"
    bold "Send this to your loved ones (web UI only — no shell access):"
    echo
    echo "  ssh -o \"ProxyCommand=nc -X 5 -x 127.0.0.1:9050 %h %p\" -o ServerAliveInterval=30 -L 8080:localhost:8080 -N ${user}@${onion}"
    echo
    dim "  1. They need Tor running locally (Tor Browser also works: use -x 127.0.0.1:9150)"
    dim "  2. Their key must be added with forwarding-only restrictions (README: Remote access)"
    dim "  3. They open http://localhost:8080 — first connect takes ~30s (Tor circuit)"
    if is_running; then
        if ui_running; then
            dim "  Web UI is ON."
        else
            echo
            red "  Web UI is currently OFF — run: ./manage.sh ui on"
        fi
    else
        echo
        red "  Container not running — start it first: ./manage.sh start"
    fi
    echo
    dim "Your own full access:"
    echo "  ssh -o \"ProxyCommand=nc -X 5 -x 127.0.0.1:9050 %h %p\" ${user}@${onion}"
}

# ── doctor ────────────────────────────────────────────────────────────────

cmd_doctor() {
    # Check this machine has what it takes to run offline-ai.
    bold "offline-ai doctor"
    echo
    local fail=0
    pass() { green "  [ok] $1"; }
    warn() { red "  [!!] $1"; fail=1; }
    note() { dim  "  [..] $1"; }

    if command -v docker >/dev/null 2>&1; then pass "docker installed"; else warn "docker not in PATH"; fi
    if docker info >/dev/null 2>&1; then pass "docker daemon running"; else warn "docker daemon not reachable"; fi

    local mem_gb disk_gb
    if [ -f /proc/meminfo ]; then
        mem_gb="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)"
    else
        mem_gb="$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1024/1024/1024}')"
    fi
    disk_gb="$(df -k . 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')"
    if [ "${mem_gb:-0}" -ge 8 ] 2>/dev/null; then pass "memory: ${mem_gb}GB"; else warn "memory: ${mem_gb:-?}GB (models want 8GB+)"; fi
    if [ "${disk_gb:-0}" -ge 20 ] 2>/dev/null; then pass "disk: ${disk_gb}GB free"; else warn "disk: ${disk_gb:-?}GB free (models are 5GB+)"; fi

    if docker info 2>/dev/null | grep -q nvidia; then pass "NVIDIA GPU detected"; else note "no NVIDIA GPU (CPU inference only)"; fi

    local onion
    onion="$(sudo -n cat /var/lib/tor/ssh_hidden/hostname 2>/dev/null || true)"
    if [ -n "$onion" ]; then pass "Tor hidden service: $onion"; else note "no Tor hidden service (optional; README: Remote access)"; fi

    echo
    if [ "$fail" -eq 0 ]; then green "Ready to roll."; else dim "Fix the [!!] items above, then re-run."; fi
}

# ── models ────────────────────────────────────────────────────────────────

cmd_models() {
    is_running || die "Container not running. Run: ./manage.sh start"
    exec_ollama list
}

cmd_pull() {
    # Pull a model from the ollama registry
    # Usage: ./manage.sh pull <model>
    [[ $# -ge 1 ]] || die "Usage: ./manage.sh pull <model>\n  e.g. ./manage.sh pull llama3.2"
    is_running || die "Container not running. Run: ./manage.sh start"

    local interrupted=0
    trap 'interrupted=1' INT TERM
    docker exec -it "$CONTAINER" ollama pull "$1"
    trap - INT TERM

    [[ $interrupted -eq 1 ]] && { docker exec "$CONTAINER" pkill -f "ollama pull" >/dev/null 2>&1 || true; die "Cancelled."; }
}

cmd_remove() {
    # Remove a model
    [[ $# -ge 1 ]] || die "Usage: ./manage.sh remove <model>"
    is_running || die "Container not running."
    exec_ollama rm "$1"
    green "Removed $1"
}

cmd_import() {
    # Import a model - either a HuggingFace/registry ref, or a local GGUF file.
    #
    # Registry ref (hf.co/... or a normal ollama model ref):
    #   `ollama pull` does the download itself, including its own resume/
    #   digest-verification logic.
    #
    # Local .gguf file:
    #   You already have the complete file, so we register it directly via
    #   a minimal Modelfile.
    #
    # Usage:
    #   ./manage.sh import hf.co/user/repo:tag  [local-name]
    #   ./manage.sh import /path/to/local.gguf  [local-name]

    [[ $# -ge 1 ]] || die "Usage: ./manage.sh import <hf-model-or-gguf-path> [name]"
    is_running || die "Container not running. Run: ./manage.sh start"

    local src="$1"
    local name="${2:-}"

    # ── Case A: local .gguf file supplied ─────────────────────────────────
    if [[ "$src" == *.gguf || -f "$src" ]]; then
        [[ -f "$src" ]] || die "File not found: $src"
        local fname
        fname="$(basename "$src")"
        name="${name:-${fname%.gguf}}"
        name="${name//[^a-zA-Z0-9._-]/-}"   # sanitize

        bold "Importing local GGUF: $src  →  model name: $name"
        local dest="/root/.ollama/imports/${name}.gguf"
        docker exec "$CONTAINER" mkdir -p /root/.ollama/imports
        docker cp "$src" "${CONTAINER}:${dest}"
        _create_from_blob "$dest" "$name"
        return
    fi

    # ── Case B: HuggingFace / ollama registry ref ─────────────────────────
    bold "Pulling from registry: $src"
    dim  "(Ctrl+C stops the download - can be resumed later with the same command.)"

    local pull_status=0
    local interrupted=0
    trap 'interrupted=1' INT TERM
    docker exec -it "$CONTAINER" ollama pull "$src" || pull_status=$?
    trap - INT TERM

    if [[ $interrupted -eq 1 ]]; then
        docker exec "$CONTAINER" pkill -f "ollama pull" >/dev/null 2>&1 || true
        red "Cancelled."
        dim  "Nothing was imported - a half-finished download is never registered as a model."
        die  "Re-run to retry (ollama resumes from where it left off): ./manage.sh import $src${name:+ $name}"
    fi

    if [[ $pull_status -ne 0 ]]; then
        red "Pull failed (exit code $pull_status)."
        dim  "Nothing was imported - a half-finished download is never registered as a model."
        die  "Re-run to retry (ollama resumes from where it left off): ./manage.sh import $src${name:+ $name}"
    fi

    # Confirm the model is actually present in ollama's own registry
    if ! docker exec "$CONTAINER" ollama list | grep -qF "$src"; then
        die "Pull reported success but '$src' isn't showing in 'ollama list'. Nothing was imported - try again."
    fi

    green "Pull complete and verified."

    if [[ -n "$name" && "$name" != "$src" ]]; then
        local alias="${name//[^a-zA-Z0-9._-]/-}"   # sanitize
        bold "Aliasing to local name: $alias"
        docker exec "$CONTAINER" ollama cp "$src" "$alias"
        docker exec "$CONTAINER" ollama rm "$src" 2>/dev/null || true
        name="$alias"
    else
        name="$src"
    fi

    green "Model '$name' imported successfully."
    dim  "Verify with: ./manage.sh models"
}

_create_from_blob() {
    local gguf_path="$1"
    local name="$2"

    bold "Creating model '$name' from $gguf_path"

    # Write a minimal Modelfile inside the container
    docker exec "$CONTAINER" sh -c "printf 'FROM %s\n' '$gguf_path' > /tmp/Modelfile"

    docker exec "$CONTAINER" ollama create "$name" -f /tmp/Modelfile
    docker exec "$CONTAINER" rm /tmp/Modelfile

    green "Model '$name' imported successfully."
    dim  "Verify with: ./manage.sh models"
    dim  "The GGUF lives in the '$VOLUME' volume and persists across rebuilds."
}

cmd_run() {
    # Quick interactive chat with a model (CLI)
    [[ $# -ge 1 ]] || die "Usage: ./manage.sh run <model>"
    is_running || die "Container not running."
    docker exec -it "$CONTAINER" ollama run "$1"
}

# ── Volume management ──────────────────────────────────────────────────────

cmd_volume_info() {
    docker volume inspect "$VOLUME" 2>/dev/null || dim "Volume '$VOLUME' does not exist yet."
}

cmd_volume_clean() {
    is_running && die "Stop the container first: ./manage.sh stop"
    read -rp "Delete volume '$VOLUME' and ALL downloaded models? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { dim "Aborted."; exit 0; }
    docker volume rm "$VOLUME"
    green "Volume removed."
}

# ── help ──────────────────────────────────────────────────────────────────

cmd_help() {
    bold "manage.sh - offline-ai (ollama + web UI + agent, all in docker)"
    echo
    echo "Container"
    echo "  start              Build (if needed) and start"
    echo "  stop               Stop and remove container"
    echo "  restart            stop + start"
    echo "  rebuild            stop + build + start"
    echo "  logs               Follow container logs"
    echo "  shell              Open bash inside container"
    echo "  status             Show running state"
    echo
    echo "Agent  (tools sandboxed to ./work → /work)"
    echo "  agent [--confirm] [--steps N] [--resume] \"task...\""
    echo "    e.g. ./manage.sh agent \"list the files in /work and summarize them\""
    echo "    e.g. ./manage.sh agent --confirm --steps 20 \"refactor main.py\""
    echo "    e.g. GATE=confirm MAX_STEPS=5 ./manage.sh agent \"write a fuzzer\""
    echo
    echo "API"
    echo "  api                Print sample curl usage for the Ollama API"
    echo "  ui [on|off|status] Toggle the web UI on a running container"
    echo "  share              Print the Tor+SSH one-liner for loved ones"
    echo
    echo "Machine"
    echo "  doctor             Check this machine can run offline-ai"
    echo
    echo "Models"
    echo "  models             List installed models"
    echo "  pull  <model>      Pull from ollama registry"
    echo "  run   <model>      Interactive CLI chat"
    echo "  remove <model>     Delete a model"
    echo "  import <ref> [name]   Import HF/registry ref or local GGUF"
    echo "    e.g.  ./manage.sh import hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M qwen35-9b"
    echo "    e.g.  ./manage.sh import ./my-model.gguf my-model"
    echo
    echo "Volume (persistent model storage)"
    echo "  volume-info        Inspect the volume"
    echo "  volume-clean       Delete the volume (wipes all models)"
    echo
    echo "Env overrides (prefix the command)"
    echo "  FRONTEND=0        1 = serve web UI on :8080 (default: API only)"
    echo "  WORKDIR=./work    host dir shared with the agent at /work"
    echo "  MODEL=<name>      model the agent uses (default: first installed model)"
    echo "  MAX_STEPS=10      max unattended agent turns"
    echo "  GATE=auto         auto | confirm  (confirm asks before every tool call)"
    echo "  GPU=0             disable GPU passthrough"
    echo "  UI_PORT=8080  API_PORT=11434"
    echo "  BIND_ADDR=127.0.0.1   bind published ports (0.0.0.0 = LAN)"
    echo
    echo "Get rolling (skeleton first, model after):"
    echo "  ./manage.sh start"
    echo "  ./manage.sh import hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M qwen35-9b"
    echo "  ./manage.sh agent \"list the files in /work and summarize them\""
}

# ── dispatch ──────────────────────────────────────────────────────────────
CMD="${1:-help}"
shift || true

case "$CMD" in
    build)        cmd_build        ;;
    start)        cmd_start        ;;
    stop)         cmd_stop         ;;
    restart)      cmd_restart      ;;
    rebuild)      cmd_rebuild      ;;
    logs)         cmd_logs         ;;
    shell)        cmd_shell        ;;
    status)       cmd_status       ;;
    agent)        cmd_agent  "$@"  ;;
    api)          cmd_api          ;;
    ui)           cmd_ui     "$@"  ;;
    share)        cmd_share  "$@"  ;;
    doctor)       cmd_doctor       ;;
    models)       cmd_models       ;;
    pull)         cmd_pull  "$@"   ;;
    run)          cmd_run   "$@"   ;;
    remove)       cmd_remove "$@"  ;;
    import)       cmd_import "$@"  ;;
    volume-info)  cmd_volume_info  ;;
    volume-clean) cmd_volume_clean ;;
    help|--help|-h) cmd_help       ;;
    *) red "Unknown command: $CMD"; cmd_help; exit 1 ;;
esac
