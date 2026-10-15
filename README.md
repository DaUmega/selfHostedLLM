# offline-ai

Self-hosted LLM appliance in docker: Ollama + optional web UI + an **agentic
loop** with sandboxed tools, plus Tor + SSH for remote access, all in one
container, all offline on your hardware. The host runs nothing but Docker.

## Quick start

The image is just the skeleton - Ollama, the agent, the UI server, Tor, SSH -
with no model baked in. Start it, add a model and your key:

```bash
./manage.sh start
./manage.sh auth "ssh-ed25519 AAAA..."   # your key (from Bitwarden, ssh-add -L, ...)
./manage.sh onion                        # prints the .onion address
```

Then ssh in (from anywhere, over Tor) - this is the daily driver:

```bash
ssh -o "ProxyCommand=nc -X 5 -x 127.0.0.1:9050 %h %p" ai@$(./manage.sh onion)
```

Inside, grab a model and run the agent:

```bash
ollama pull hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M
agent "list the files in /work and summarize what this project does"
```

The `agent` command auto-picks the installed model. Models live in a docker
volume and survive rebuilds; Tor/SSH keys live in their own volume so the
`.onion` stays stable. `manage.sh` only handles the container and the
Tor+SSH identity - everything else happens inside, over ssh.

Drop files into `./work/` on the host - the agent sees them at `/work` and can
read/edit them there. Nothing outside `/work` is reachable.

## The agent

`agent.go` is ~400 lines of Go, stdlib only. It compiles to a **static binary**
baked into the image - no Python, no pip, nothing to break on upgrade. It runs
a tool loop against Ollama's `/api/chat`:

- **Tools** (all sandboxed to `/work`): `read_file`, `write_file`, `list_dir`, `exec`
- **Step budget**: `MAX_STEPS` caps unattended turns (default 10). On exhaustion
  it saves state to `/work/.agent.json`; resume with `--resume`.
- **Gates**: `GATE=confirm` (or `--confirm`) asks before *every* tool call -
  `[Y/n/q]`. Default `auto` runs unattended up to the step budget.
- **Context compression**: past `CTX_BUDGET` chars of history (~12k default), the
  middle of the transcript is summarized by the model into a memory note and the
  loop continues. No manual compacting needed.

```bash
agent "write a python port scanner in /work"
agent --confirm --steps 20 "refactor main.py, run the tests after"
GATE=confirm MAX_STEPS=5 MODEL=qwen35-9b agent "try harder on the parser"
agent --resume "now also handle UDP"
```

All of the above runs inside the container, over ssh. Model management is
plain ollama there too: `ollama list`, `ollama pull <model>`, `ollama rm
<model>`, `ollama run <model>`. For a local GGUF file, copy it in from the
host (`docker cp model.gguf offline-ai:/tmp/`) then `ollama create mymodel -f`
with a two-line Modelfile (`FROM /tmp/model.gguf`).

Honest expectations: a 9B model does tool calls fine but is weak at long
autonomous chains - supervise it, review diffs, keep tasks small.

## Frontend optional

The web UI is off by default - API only. Enable it at start:

```bash
FRONTEND=1 ./manage.sh start
```

Or start it on a running container, anytime - ssh in and run:

```bash
/app/serve &            # pkill -f /app/serve to stop it
```

That only lasts until the container restarts; `FRONTEND=1` sets the initial
state at start. With the UI off, talk to the API directly:

```bash
# list models
curl -s http://localhost:11434/api/tags | python3 -c 'import json,sys; [print(m["name"]) for m in json.load(sys.stdin)["models"]]'

# chat (non-streaming)
curl -s http://localhost:11434/api/chat -d '{"model":"qwen35-9b","stream":false,
  "messages":[{"role":"user","content":"write a python hello world"}]}'

# one-shot generate
curl -s http://localhost:11434/api/generate -d '{"model":"qwen35-9b","stream":false,
  "prompt":"Explain what a port scan is in one sentence."}'

# streaming chat (newline-delimited JSON)
curl -N http://localhost:11434/api/chat -d '{"model":"qwen35-9b",
  "messages":[{"role":"user","content":"hi"}]}'
```

## Commands

```bash
./manage.sh start          # Build (if needed) and start
./manage.sh stop           # Stop and remove container
./manage.sh restart        # stop + start
./manage.sh rebuild        # stop + build + start
./manage.sh logs           # Follow container logs
./manage.sh shell          # Root shell inside (break-glass when ssh is down)
./manage.sh status         # Show running state
./manage.sh auth "<pubkey>" [--restricted]  # Authorize an SSH key (restricted = UI only)
./manage.sh onion          # Print the .onion address
./manage.sh share          # Print the Tor+SSH one-liner for loved ones
./manage.sh doctor         # Check this machine can run offline-ai
./manage.sh volume-info    # Inspect the model volume
./manage.sh volume-clean   # Delete the model volume (wipes all models)
```

Inside, over ssh (`ssh ai@<onion>` via Tor):

```bash
agent "task..."            # Agentic loop, tools sandboxed to /work
ollama pull <model>        # Download a model
ollama list | ollama rm <model>   # List / delete models
ollama run <model>         # Interactive CLI chat
/app/serve &               # Start the web UI on :8080
```

## Configuration

| Env Var       | Default              | Purpose                                        |
|---------------|----------------------|------------------------------------------------|
| `FRONTEND`    | 0                    | 1 = serve the web UI, 0 = API only             |
| `BIND_ADDR`   | 127.0.0.1            | Bind published ports (`0.0.0.0` = LAN)         |
| `WORKDIR`     | ./work               | Host dir shared with agent at /work            |
| `UI_PORT`     | 8080                 | Web UI port                                    |
| `API_PORT`    | 11434                | Ollama API port                                |
| `GPU`         | auto                 | Enable GPU (`auto`, `0`)                       |

Inside the container, the agent reads its own knobs: `MODEL` (default: first
installed model), `MAX_STEPS` (default 10), `GATE` (`auto` or `confirm`),
`CTX_BUDGET` (default 12000), `NUM_CTX` (default 16384).

## Architecture

One container is the whole appliance. The host runs nothing but Docker.

- **Dockerfile** - multi-stage: Go builds the static binaries, then ollama +
  tor + openssh-server. No Python anywhere.
- **agent.go** - the agentic loop (tools, gates, step budget, compression);
  also reachable inside the container via the `agent` wrapper (auto model)
- **serve.go** - tiny static file server for the UI (only when `ui on`)
- **entrypoint.sh** - supervises ollama, tor, sshd (+ UI); first run generates
  ssh host keys and the hidden service, persisted in the `offline-ai-id` volume
- **sshd_config** - key-only SSH for the `ai` user, no root, no passwords
- **bin/agent** - `agent` wrapper: auto-picks the installed model, execs the loop
- **index.html** - chat UI (only served when the UI is on)
- **manage.sh** - container lifecycle + Tor+SSH identity (keys, onion, sharing).
  Everything else (agent, ollama, UI) runs inside, over ssh.

Tor only makes outbound connections, so nothing inbound is open on the host.
SSH into the container never grants host access; the container boundary is
the security boundary (no docker socket mounted, ever).

## Remote access (Tor + SSH, inside the container)

The container is the appliance: Tor and OpenSSH run inside it, so the host is
never touched - no host sshd changes, no host Tor, no `/etc` edits. Tor only
makes outbound connections, so nothing inbound is open anywhere. The repo has
no logins or user accounts; the SSH key is the entire auth model.

**Setup** - authorize your key, then read the onion address:

```bash
./manage.sh auth "ssh-ed25519 AAAA..."   # your key: full shell as the ai user
./manage.sh onion                        # prints the .onion address
```

The key can come from anywhere: Bitwarden (`ssh-add -L` lists keys loaded in
the agent) or an existing `~/.ssh/id_ed25519.pub`. Root login is disabled in
the container; your key gets a normal shell as the `ai` user. That's the
full-access side of the two-key model.

**Two keys, two access levels.** Your key gets a shell. Loved ones get a
forwarding-only key:

```bash
./manage.sh auth "ssh-ed25519 BBBB..." --restricted
```

That key can do exactly one thing - forward port 8080. No shell, no commands.
Everyone shares the `ai` username since the key itself enforces the boundary.

**Your own access from anywhere** (agentic CLI, everything):

```bash
ssh -o "ProxyCommand=nc -X 5 -x 127.0.0.1:9050 %h %p" ai@<onion>
agent "refactor main.py and run the tests"
```

The `agent` command inside the container auto-picks the installed model.
Add `-L 11434:localhost:11434` to the ssh line for the Ollama API.

**Sharing with loved ones:** `./manage.sh share` prints a copy-paste
one-liner. Send it over a channel you already trust (Signal, in person). They
need Tor running locally, then they run the line, wait ~30s for the circuit
to build (normal), and open http://localhost:8080. The UI has no login
because the SSH forward *is* the auth - only key holders get through.

**Revoking someone:** `docker exec offline-ai sed -i '/BBBB.../d' /home/ai/.ssh/authorized_keys`
(replace `BBBB...` with part of their key), no restart needed. To rotate the
`.onion` address itself: `docker volume rm offline-ai-id` (with the container
stopped) - back up `/id` first if you want to keep the address.

## Requirements

- Docker, ~12GB disk (model dependent)
- Optional: NVIDIA GPU + nvidia-container-toolkit

## License

MIT
