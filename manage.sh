#!/usr/bin/env bash
# manage.sh — ollama-ui container manager
# Usage: ./manage.sh <command> [args]
set -euo pipefail

IMAGE="ollama-ui"
CONTAINER="ollama-ui"
VOLUME="ollama-models"          # persists /root/.ollama across rebuilds
UI_PORT="${UI_PORT:-8080}"
API_PORT="${API_PORT:-11434}"

# GPU flag — auto-detected; override with GPU=0 ./manage.sh start
GPU="${GPU:-auto}"

# ── helpers ───────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n'  "$*"; }
bold()  { printf '\033[1m%s\033[0m\n'  "$*"; }

die() { red "error: $*"; exit 1; }

require() { command -v "$1" &>/dev/null || die "'$1' not found in PATH"; }

is_running() { docker ps -q -f name="^${CONTAINER}$" | grep -q .; }

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

wait_api() {
    local tries=0
    until docker exec "$CONTAINER" curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; do
        sleep 1
        tries=$((tries + 1))
        [[ $tries -gt 30 ]] && die "Ollama API did not become ready"
    done
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
        green "Already running. UI → http://localhost:${UI_PORT}"
        return
    fi

    # Build if image doesn't exist
    if ! docker image inspect "$IMAGE" &>/dev/null; then
        cmd_build
    fi

    bold "Starting container: $CONTAINER"
    # shellcheck disable=SC2086
    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        -p "${UI_PORT}:8080" \
        -p "${API_PORT}:11434" \
        -v "${VOLUME}:/root/.ollama" \
        -e OLLAMA_ORIGINS="*" \
        $(gpu_flags) \
        "$IMAGE"

    bold "Container logs (live — waiting for API on :${API_PORT})..."
    dim  "────────────────────────────────────────"

    # Stream container logs so you can see exactly what is happening
    docker logs -f "$CONTAINER" &
    LOGS_PID=$!

    # Poll host-side mapped port using bash built-in /dev/tcp — no curl/wget on host needed
    local tries=0 ready=0
    while [[ $tries -lt 60 ]]; do
        # ollama CLI is always present and talks to the local API
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
        red "API did not become ready after 60s — run: ./manage.sh logs"
        exit 1
    fi

    green "Ready."
    dim "  UI  → http://localhost:${UI_PORT}"
    dim "  API → http://localhost:${API_PORT}"
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
}

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
    # Import a model — either a HuggingFace/registry ref, or a local GGUF file.
    #
    # Registry ref (hf.co/... or a normal ollama model ref):
    #   `ollama pull` does the download itself, including its own resume/
    #   digest-verification logic. We only ever act on its exit code — if it
    #   fails or is interrupted (lost connection, Ctrl+C, etc.) we abort and
    #   import NOTHING. There is no "best effort" partial import: a half
    #   finished download is not a model.
    #
    #   If you want a friendlier local name than the ref, we alias it with
    #   `ollama cp`, which just points a new name at the same verified
    #   blobs — no manual blob-hunting involved.
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
    dim  "(Ctrl+C stops the download for real — nothing is imported until it's verified complete)"

    # IMPORTANT: -it allocates a real TTY so Ctrl+C reaches the remote
    # process instead of just killing the local docker-exec client.
    #
    # We do NOT trust ollama's own exit code to tell us whether Ctrl+C
    # happened: ollama appears to exit 0 on a cancelled pull (it treats
    # SIGINT as a clean shutdown, not a failure). So we catch the signal
    # ourselves — bash is in the same foreground process group as the
    # terminal and receives the same Ctrl+C — and that flag always wins,
    # regardless of what ollama reports.
    local pull_status=0
    local interrupted=0
    trap 'interrupted=1' INT TERM
    docker exec -it "$CONTAINER" ollama pull "$src" || pull_status=$?
    trap - INT TERM

    if [[ $interrupted -eq 1 ]]; then
        docker exec "$CONTAINER" pkill -f "ollama pull" >/dev/null 2>&1 || true
        red "Cancelled."
        dim  "Nothing was imported — a half-finished download is never registered as a model."
        die  "Re-run to retry (ollama resumes from where it left off): ./manage.sh import $src${name:+ $name}"
    fi

    if [[ $pull_status -ne 0 ]]; then
        red "Pull failed (exit code $pull_status)."
        dim  "Nothing was imported — a half-finished download is never registered as a model."
        die  "Re-run to retry (ollama resumes from where it left off): ./manage.sh import $src${name:+ $name}"
    fi

    # Belt and suspenders: don't take the exit code's word for it. Confirm
    # the model is actually present in ollama's own registry before we
    # ever say the word "success".
    if ! docker exec "$CONTAINER" ollama list | grep -qF "$src"; then
        die "Pull reported success but '$src' isn't showing in 'ollama list'. Nothing was imported — try again."
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
    bold "manage.sh — ollama-ui"
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
    echo "Models"
    echo "  models             List installed models"
    echo "  pull  <model>      Pull from ollama registry"
    echo "  run   <model>      Interactive CLI chat"
    echo "  remove <model>     Delete a model"
    echo "  import <ref> [name]   Import HF/registry ref or local GGUF"
    echo "    e.g.  ./manage.sh import hf.co/user/repo:tag"
    echo "    e.g.  ./manage.sh import ./my-model.gguf my-model"
    echo
    echo "Volume (persistent model storage)"
    echo "  volume-info        Inspect the volume"
    echo "  volume-clean       Delete the volume (wipes all models)"
    echo
    echo "Env overrides"
    echo "  UI_PORT=8080  API_PORT=11434  GPU=0   (prefix the command)"
    echo "    e.g.  GPU=0 ./manage.sh start"
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
