# Stage 1: build the static Go binaries (agent loop + UI file server).
# No Python, no pip - the binaries carry zero runtime dependencies.
FROM golang:alpine AS build
WORKDIR /src
COPY go.mod agent.go serve.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /out/agent agent.go && \
    CGO_ENABLED=0 go build -trimpath -o /out/serve serve.go

# Stage 2: the appliance. Ollama + agent + UI + Tor + SSH in one box.
# The host runs nothing but the Docker engine. Tor only makes outbound
# connections, so the container needs no inbound ports at all.
FROM ollama/ollama:latest

RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        tor openssh-server procps && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/run/sshd /id && \
    useradd -m -s /bin/bash ai && \
    usermod -p '*' ai
# '*' = no password login possible, but the account is NOT locked.
# useradd alone leaves it locked ('!' in shadow) and sshd then rejects
# ALL auth for ai, even with the right key in authorized_keys.

WORKDIR /app
COPY --from=build /out/agent /out/serve /app/
COPY agent.sh /usr/local/bin/agent
COPY index.html entrypoint.sh sshd_config ./
RUN chmod +x entrypoint.sh /usr/local/bin/agent && \
    mkdir -p /work && \
    chown ai:ai /work

# 11434 = ollama API | 8080 = web UI (both localhost-bound by default via BIND_ADDR)
EXPOSE 11434 8080

ENTRYPOINT ["/app/entrypoint.sh"]
