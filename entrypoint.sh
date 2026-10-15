#!/bin/sh
set -e

# ── identity: ssh host keys + tor hidden-service keys (persisted in /id) ──
# Kept in a volume so the .onion address and host keys survive rebuilds.
mkdir -p /id/ssh /id/tor/hidden /id/tor/data /run/sshd
[ -f /id/ssh/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -f /id/ssh/ssh_host_ed25519_key -N ""
[ -f /id/ssh/ssh_host_rsa_key ]     || ssh-keygen -q -t rsa -b 3072 -f /id/ssh/ssh_host_rsa_key -N ""
chmod 600 /id/ssh/ssh_host_*_key
chmod 700 /id/tor/hidden

# ai user: keys are added from the host via ./manage.sh auth
mkdir -p /home/ai/.ssh
touch /home/ai/.ssh/authorized_keys
chmod 700 /home/ai/.ssh
chmod 600 /home/ai/.ssh/authorized_keys
chown -R ai:ai /home/ai/.ssh
chown ai:ai /work

# ── tor: hidden service for ssh. Tor only makes outbound connections,
#    so the container needs no inbound ports at all.
#    DataDirectory lives on /id (not /var/lib/tor): the Debian package chowns
#    /var/lib/tor to the debian-tor user, which breaks tor when run as root.
cat > /app/torrc <<EOF
SocksPort 0
RunAsDaemon 1
DataDirectory /id/tor/data
PidFile /run/tor.pid
HiddenServiceDir /id/tor/hidden
HiddenServicePort 22 127.0.0.1:22
EOF
echo "[entrypoint] Starting tor..."
tor -f /app/torrc

echo "[entrypoint] Starting sshd..."
/usr/sbin/sshd -f /app/sshd_config

# wait for the onion address (fast; reachability takes ~30s more)
tries=0
while [ ! -f /id/tor/hidden/hostname ] && [ $tries -lt 30 ]; do
  sleep 1; tries=$((tries+1))
done
if [ -f /id/tor/hidden/hostname ]; then
  echo "[entrypoint] Onion address: $(cat /id/tor/hidden/hostname)"
else
  echo "[entrypoint] WARNING: hidden service not created"
fi

# ── ollama ────────────────────────────────────────────────────────────────
ollama serve &
OLLAMA_PID=$!

echo "[entrypoint] Waiting for ollama API..."
tries=0
until ollama list > /dev/null 2>&1; do
  sleep 1; tries=$((tries+1))
  if [ $tries -ge 30 ]; then echo "[entrypoint] ERROR: ollama did not respond"; exit 1; fi
done
echo "[entrypoint] Ollama ready."

# ── optional web UI ───────────────────────────────────────────────────────
if [ "${FRONTEND:-0}" = "1" ]; then
  echo "[entrypoint] Serving UI on :8080"
  /app/serve &
fi

# ── supervise: if any core daemon dies, exit so docker restarts us ────────
while kill -0 $OLLAMA_PID 2>/dev/null; do
  pgrep -x sshd >/dev/null || { echo "[entrypoint] sshd died"; exit 1; }
  pgrep -x tor >/dev/null || { echo "[entrypoint] tor died"; exit 1; }
  sleep 15
done
echo "[entrypoint] ollama died"
exit 1
