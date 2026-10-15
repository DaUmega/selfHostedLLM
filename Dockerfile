# Stage 1: build the static Go binaries (agent loop + UI file server).
# No Python, no pip - the binaries carry zero runtime dependencies.
FROM golang:alpine AS build
WORKDIR /src
COPY go.mod agent.go serve.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /out/agent agent.go && \
    CGO_ENABLED=0 go build -trimpath -o /out/serve serve.go

# Stage 2: ollama + the two static binaries.
FROM ollama/ollama:latest
WORKDIR /app
COPY --from=build /out/agent /out/serve /app/
COPY index.html entrypoint.sh ./
RUN chmod +x entrypoint.sh
RUN mkdir -p /work

# 11434 = ollama API  |  8080 = web UI (only served when FRONTEND=1)
EXPOSE 11434 8080

ENTRYPOINT ["/app/entrypoint.sh"]
