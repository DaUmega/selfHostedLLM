FROM ollama/ollama:latest

# Python is already present in the base image (debian-based)
# We just need it to serve index.html on port 8080

RUN apt-get update -qq && apt-get install -y -qq python3 --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY index.html .
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# 11434 = ollama API  |  8080 = web UI
EXPOSE 11434 8080

ENTRYPOINT ["/app/entrypoint.sh"]
