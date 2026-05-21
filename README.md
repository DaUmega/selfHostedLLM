# Ollama UI

A self-hosted LLM chatbot with a modern web interface powered by [Ollama](https://ollama.ai).

## Quick Start

```bash
./manage.sh start
```

Then open **http://localhost:8080** in your browser.

## Features

- **Local inference** — run LLMs completely offline on your hardware
- **Modern chat UI** — clean, responsive dark-themed interface
- **Model management** — pull, list, remove, and import models
- **GPU support** — auto-detected; disable with `GPU=0`
- **Persistent storage** — models persist across container rebuilds

## Commands

```bash
./manage.sh start          # Start container
./manage.sh stop           # Stop container
./manage.sh logs           # View logs
./manage.sh models         # List installed models
./manage.sh pull <model>   # Download a model (e.g., llama3.2)
./manage.sh run <model>    # Interactive CLI chat
./manage.sh import <ref>   # Import HuggingFace or local GGUF
./manage.sh shell          # Open bash in container
./manage.sh rebuild        # Rebuild image
```

## Configuration

| Env Var    | Default | Purpose                    |
|------------|---------|----------------------------|
| `UI_PORT`  | 8080    | Web UI port                |
| `API_PORT` | 11434   | Ollama API port            |
| `GPU`      | auto    | Enable GPU (`auto`, `0`)   |

Example: `GPU=0 UI_PORT=9000 ./manage.sh start`

## Architecture

- **Dockerfile** — builds image with ollama + Python HTTP server
- **index.html** — responsive chat UI with markdown rendering
- **manage.sh** — container lifecycle management
- **entrypoint.sh** — orchestrates ollama API + web server startup

## Requirements

- Docker
- ~12GB disk, model dependent
- Optional: NVIDIA GPU + [nvidia-container-toolkit](https://github.com/NVIDIA/nvidia-container-toolkit)

## License

MIT
