# offline-ai

Self-hosted LLM in docker: Ollama + optional web UI + an **agentic loop** with
sandboxed tools, all offline on your hardware.

## Quick start

The image is just the skeleton — Ollama, the agent, the UI server — with no
model baked in. Start it, then add a model whenever you like:

```bash
./manage.sh start
./manage.sh import hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M qwen35-9b
```

Then run the agent:

```bash
./manage.sh agent "list the files in /work and summarize what this project does"
```

The agent auto-uses the first installed model, so the model name needs no
manual syncing anywhere — `pull`/`import` a model and the agent picks it up.
Override per command with `MODEL=<name>`. Models live in a docker volume and
survive rebuilds.

Drop files into `./work/` on the host — the agent sees them at `/work` and can
read/edit them there. Nothing outside `/work` is reachable.

## The agent

`agent.go` is ~400 lines of Go, stdlib only. It compiles to a **static binary**
baked into the image — no Python, no pip, nothing to break on upgrade. It runs
a tool loop against Ollama's `/api/chat`:

- **Tools** (all sandboxed to `/work`): `read_file`, `write_file`, `list_dir`, `exec`
- **Step budget**: `MAX_STEPS` caps unattended turns (default 10). On exhaustion
  it saves state to `/work/.agent.json`; resume with `--resume`.
- **Gates**: `GATE=confirm` (or `--confirm`) asks before *every* tool call —
  `[Y/n/q]`. Default `auto` runs unattended up to the step budget.
- **Context compression**: past `CTX_BUDGET` chars of history (~12k default), the
  middle of the transcript is summarized by the model into a memory note and the
  loop continues. No manual compacting needed.

```bash
./manage.sh agent "write a python port scanner in /work"
./manage.sh agent --confirm --steps 20 "refactor main.py, run the tests after"
GATE=confirm MAX_STEPS=5 MODEL=qwen35-9b ./manage.sh agent "try harder on the parser"
./manage.sh agent --resume "now also handle UDP"
```

Honest expectations: a 9B model does tool calls fine but is weak at long
autonomous chains — supervise it, review diffs, keep tasks small.

## Frontend optional

The web UI is off by default — API only. Enable it at start:

```bash
FRONTEND=1 ./manage.sh start
```

Or toggle it on a running container, anytime:

```bash
./manage.sh ui on        # ./manage.sh ui off | ./manage.sh ui status
./manage.sh api          # sample curl usage anytime
```

The toggle is runtime-only (not sticky across restarts); `FRONTEND=1` sets the
initial state. With the UI off, start prints working curl examples for
`/api/chat`, `/api/generate`, and streaming.

## Commands

```bash
./manage.sh start          # Build (if needed) and start
./manage.sh stop           # Stop and remove container
./manage.sh agent ...      # Run the agentic loop (see above)
./manage.sh api            # Sample curl usage for the Ollama API
./manage.sh ui [on|off|status]  # Toggle the web UI on a running container
./manage.sh share          # Print the Tor+SSH one-liner for loved ones
./manage.sh doctor         # Check this machine can run offline-ai
./manage.sh models         # List installed models
./manage.sh pull <model>   # Download a model
./manage.sh run <model>    # Interactive CLI chat
./manage.sh import <ref>   # Import HuggingFace ref or local GGUF
./manage.sh remove <model> # Delete a model
./manage.sh shell          # Bash inside the container
./manage.sh logs           # Follow logs
./manage.sh rebuild        # Rebuild image
```

## Configuration

| Env Var       | Default              | Purpose                                        |
|---------------|----------------------|------------------------------------------------|
| `FRONTEND`    | 0                    | 1 = serve the web UI, 0 = API only             |
| `BIND_ADDR`   | 127.0.0.1            | Bind published ports (`0.0.0.0` = LAN)         |
| `WORKDIR`     | ./work               | Host dir shared with agent at /work            |
| `MODEL`       | first installed      | Model the agent uses (auto-detected)           |
| `MAX_STEPS`   | 10                   | Max unattended agent turns                     |
| `GATE`        | auto                 | auto \| confirm (ask before every tool call)   |
| `CTX_BUDGET`  | 12000                | Chars of history before auto-compression       |
| `NUM_CTX`     | 16384                | Ollama context window                          |
| `UI_PORT`     | 8080                 | Web UI port                                    |
| `API_PORT`    | 11434                | Ollama API port                                |
| `GPU`         | auto                 | Enable GPU (`auto`, `0`)                       |

## Architecture

- **Dockerfile** — multi-stage: Go builds the static binaries, then ollama + binaries
- **agent.go** — the agentic loop (tools, gates, step budget, compression)
- **serve.go** — tiny static file server for the UI (replaces `python -m http.server`)
- **entrypoint.sh** — starts ollama, optional UI
- **index.html** — chat UI (only served when FRONTEND=1)
- **manage.sh** — lifecycle, model, agent, and API helpers

## Remote access (Tor + SSH)

The repo has no logins or user accounts — the SSH key is the entire auth model.
Tor provides the transport (no open ports, no public IP). Setup uses the
tor-ssh script directly from its own repo (nothing vendored here):

```bash
curl -fsSL https://raw.githubusercontent.com/DaUmega/miscTools/refs/heads/main/torSSH.sh | bash -s -- <command>
```

**One-time server setup** — order matters, `install` refuses to disable
password auth until a key exists:

```bash
# 1. each person runs: tor-ssh keygen   → sends you their pubkey
# 2. you authorize keys on the host:
tor-ssh auth "ssh-ed25519 AAAA..."   # your key: full shell access
# 3. install + serve:
tor-ssh install
tor-ssh serve                        # prints the .onion address
```

**Two keys, two access levels.** Your key gets a normal shell. Loved ones get a
forwarding-only key: prefix their line in `~/.ssh/authorized_keys` with

```
restrict,permitopen="localhost:8080",no-pty ssh-ed25519 BBBB...
```

That key can do exactly one thing — forward port 8080. No shell, no commands.
Everyone can share one username since the key itself enforces the boundary.

**Sharing:** `./manage.sh share` prints a copy-paste one-liner. Send it over a
channel you already trust (Signal, in person). They need Tor running locally,
then they run the line, wait ~30s for the circuit to build (normal), and open
http://localhost:8080. The UI has no login because the SSH forward *is* the
auth — only key holders get through.

**Your own access from anywhere:** `tor-ssh connect user@<onion>`, then
`./manage.sh ...` exactly like home. Add `-L 11434:localhost:11434` for API.

**Revoking someone:** delete their key line, `sudo systemctl reload ssh`. Done.

## Requirements

- Docker, ~12GB disk (model dependent)
- Optional: NVIDIA GPU + nvidia-container-toolkit

## License

MIT
