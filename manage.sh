#!/usr/bin/env bash
# offline-ai container manager: ollama + web UI + agentic loop, all in docker.
# This script only manages the container and the Tor+SSH identity. Everything
# else (agent, ollama, UI toggle) happens inside, over ssh ai@<onion> via Tor.
# Usage: ./manage.sh <command> [args]
set -euo pipefail

IMAGE="offline-ai"
CONTAINER="offline-ai"
VOLUME="ollama-models"          # persists /root/.ollama across rebuilds
IDVOLUME="offline-ai-id"        # persists tor + ssh host keys (stable .onion)
UI_PORT="${UI_PORT:-8080}"
API_PORT="${API_PORT:-11434}"

# GPU flag - auto-detected; override with GPU=0 ./manage.sh start
GPU="${GPU:-auto}"

# Frontend: 1 = serve web UI on :8080, 0 = API only (curl samples live in the README)
FRONTEND="${FRONTEND:-1}"

# Shared folder: host dir mounted at /work inside the container.
# Drop files here and the agent can read/edit them.
WORKDIR="${WORKDIR:-./work}"

# Bind address for published ports. 127.0.0.1 = only this machine (and your
# SSH port-forwards) can reach the API/UI. Set to 0.0.0.0 for LAN access.
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"

# ── helpers ───────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n'  "$*"; }
bold()  { printf '\033[1m%s\033[0m\n'  "$*"; }

die() { red "error: $*"; exit 1; }

require() { command -v "$1" &>/dev/null || die "'$1' not found in PATH"; }

is_running() { docker ps -q -f name="^${CONTAINER}$" 2>/dev/null | grep -q .; }

read_onion() {
    # Print the .onion address, or nothing if the hidden service isn't up yet.
    docker exec "$CONTAINER" cat /id/tor/hidden/hostname 2>/dev/null || true
}

gpu_flags() {
    if [[ "$GPU" == "0" ]]; then
        echo ""
    elif docker info 2>/dev/null | grep -q "nvidia"; then
        echo "--gpus all"
    else
        if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
            echo "note: NVIDIA GPU found on host but not visible to docker." >&2
            echo "install nvidia-container-toolkit for GPU inference; using CPU for now." >&2
        fi
        echo ""
    fi
}

# ── container lifecycle ───────────────────────────────────────────────────

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
        -v "${IDVOLUME}:/id" \
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
    local onion
    onion="$(read_onion)"
    [ -n "$onion" ] && dim "  Onion → $onion  (ssh ai@$onion via tor)"
    if [[ "$FRONTEND" == "1" ]]; then
        dim "  UI  → http://localhost:${UI_PORT}"
    else
        dim "  Web UI off - start it inside any time: ssh in, then: /app/serve &"
    fi
    dim "  Next: ./manage.sh auth \"ssh-ed25519 AAAA...\"  then ssh in (see: ./manage.sh share)"
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

# ── tor+ssh identity ──────────────────────────────────────────────────────

cmd_auth() {
    # Authorize an SSH key for the container's ai user.
    # Usage: ./manage.sh auth "ssh-ed25519 AAAA..." [--restricted]
    # Default: full shell. --restricted: forwarding-only (web UI), no shell.
    local restricted=0 key=""
    for a in "$@"; do
        case "$a" in
            --restricted) restricted=1 ;;
            *) key="$a" ;;
        esac
    done
    [[ -n "$key" ]] || die 'Usage: ./manage.sh auth "ssh-ed25519 AAAA..." [--restricted]'
    case "$key" in
        ssh-ed25519*|ssh-rsa*|ecdsa-sha2-*) ;;
        *) die "That doesn't look like an SSH public key." ;;
    esac
    is_running || die "Container not running. Run: ./manage.sh start"
    [ "$restricted" -eq 1 ] && key="restrict,permitopen=\"localhost:8080\",no-pty $key"
    printf '%s\n' "$key" | docker exec -i "$CONTAINER" bash -c '
        k=$(cat)
        f=/home/ai/.ssh/authorized_keys
        grep -qxF "$k" "$f" 2>/dev/null || echo "$k" >> "$f"
        chown ai:ai "$f"; chmod 600 "$f"
    ' || die "Failed to authorize key."
    if [ "$restricted" -eq 1 ]; then green "Key authorized (forwarding-only: web UI, no shell).";
    else green "Key authorized (full shell)."; fi
}

cmd_onion() {
    is_running || die "Container not running."
    local onion
    onion="$(read_onion)"
    [ -n "$onion" ] || die "Hidden service not ready yet - check ./manage.sh logs"
    echo "$onion"
}

cmd_share() {
    # Print the copy-paste one-liner for loved ones (web UI only, no shell).
    # Their key must be authorized first: ./manage.sh auth "<pubkey>" --restricted
    is_running || die "Container not running. Run: ./manage.sh start"
    local onion
    onion="$(read_onion)"
    [ -n "$onion" ] || die "Hidden service not ready yet - check ./manage.sh logs"

    bold "Send this to your loved ones (web UI only - no shell access):"
    echo
    echo "  torsocks ssh -o ServerAliveInterval=30 -L 8080:localhost:8080 -N ai@${onion}"
    dim "  Have nc? Alternative: ssh -o \"ProxyCommand=nc -X 5 -x 127.0.0.1:9050 %h %p\" -o ServerAliveInterval=30 -L 8080:localhost:8080 -N ai@${onion}"
    echo
    dim "  1. They need Tor running locally (Tor Browser also works: use -x 127.0.0.1:9150)"
    dim "  2. Their key must be added first: ./manage.sh auth \"<their-pubkey>\" --restricted"
    dim "  3. They open http://localhost:8080 - first connect takes ~30s (Tor circuit)"
    if docker exec "$CONTAINER" pgrep -f "/app/serve" >/dev/null 2>&1; then
        dim "  Web UI is ON."
    else
        echo
        red "  Web UI is currently OFF - ssh in and run: /app/serve &"
    fi
    echo
    dim "Your own full access (agentic CLI + everything):"
    echo "  ssh -o \"ProxyCommand=nc -X 5 -x 127.0.0.1:9050 %h %p\" ai@${onion}"
    dim "  No nc? Use: torsocks ssh ai@${onion}"
    dim "  then run: agent \"your task\""
}

# ── host preflight ────────────────────────────────────────────────────────

cmd_doctor() {
    # Check this machine has what it takes to run offline-ai.
    bold "offline-ai doctor"
    echo
    local fail=0 onion=""
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

    if docker info 2>/dev/null | grep -q nvidia; then
        pass "NVIDIA GPU visible to docker"
    elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        warn "NVIDIA GPU on host but invisible to docker - install nvidia-container-toolkit"
    else
        note "no GPU detected (CPU inference only)"
    fi

    onion="$(read_onion)"
    if [ -n "$onion" ]; then
        pass "Tor hidden service: $onion"
    else
        note "no Tor hidden service (container not running or still starting)"
    fi

    echo
    if [ "$fail" -eq 0 ]; then green "Ready to roll."; else dim "Fix the [!!] items above, then re-run."; fi
}

# ── volume management ─────────────────────────────────────────────────────

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
    bold "manage.sh - offline-ai (container lifecycle + tor+ssh identity)"
    echo
    echo "Container"
    echo "  start              Build (if needed) and start"
    echo "  stop               Stop and remove container"
    echo "  restart            stop + start"
    echo "  rebuild            stop + build + start"
    echo "  logs               Follow container logs"
    echo "  shell              Root shell inside (break-glass when ssh is down)"
    echo "  status             Show running state"
    echo
    echo "Tor+SSH identity"
    echo "  auth \"<pubkey>\" [--restricted]  Authorize a key (restricted = UI only, no shell)"
    echo "  onion              Print the .onion address"
    echo "  share              Print the one-liner for loved ones"
    echo
    echo "Inside, over ssh (ssh ai@<onion> via tor) - this is the daily driver:"
    echo "  agent \"task...\"          Run the agentic loop (tools sandboxed to /work)"
    echo "    e.g. agent --confirm --steps 20 \"refactor main.py\""
    echo "    env knobs: MODEL=<name> (default: first installed)  MAX_STEPS=10  GATE=auto|confirm"
    echo "  ollama pull <model>    Download a model"
    echo "  ollama list            List installed models"
    echo "  ollama rm <model>      Delete a model"
    echo "  ollama run <model>     Interactive CLI chat"
    echo "  /app/serve &           Start the web UI on :8080  (pkill -f /app/serve to stop)"
    echo
    echo "Machine"
    echo "  doctor             Check this machine can run offline-ai"
    echo
    echo "Volume (persistent model storage)"
    echo "  volume-info        Inspect the volume"
    echo "  volume-clean       Delete the volume (wipes all models)"
    echo
    echo "Env overrides (prefix the command)"
    echo "  FRONTEND=1        0 = API only, no web UI (default: on)"
    echo "  WORKDIR=./work    host dir shared with the agent at /work"
    echo "  GPU=0             disable GPU passthrough"
    echo "  UI_PORT=8080  API_PORT=11434"
    echo "  BIND_ADDR=127.0.0.1   bind published ports (0.0.0.0 = LAN)"
    echo
    echo "Get rolling:"
    echo "  ./manage.sh start"
    echo "  ./manage.sh auth \"ssh-ed25519 AAAA...\"   # your key"
    echo "  ./manage.sh onion                        # prints the .onion address"
    echo "  ssh -o \"ProxyCommand=nc -X 5 -x 127.0.0.1:9050 %h %p\" ai@\$(./manage.sh onion)"
    echo "  # no nc?  torsocks ssh ai@\$(./manage.sh onion)"
    echo "  # inside:  ollama pull <model>  &&  agent \"your task\""
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
    auth)         cmd_auth   "$@"  ;;
    onion)        cmd_onion        ;;
    share)        cmd_share  "$@"  ;;
    doctor)       cmd_doctor       ;;
    volume-info)  cmd_volume_info  ;;
    volume-clean) cmd_volume_clean ;;
    help|--help|-h) cmd_help       ;;
    *) red "Unknown command: $CMD"; cmd_help; exit 1 ;;
esac
