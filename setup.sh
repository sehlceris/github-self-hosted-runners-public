#!/usr/bin/env bash
# Per-host bootstrap for the runner stack:
#   1. Create .env from .env.example if missing.
#   2. Detect the host's docker.sock GID and write it to .env.
#   3. chown the runtime dirs to UID 1001 (the in-container runner user).
#
# Idempotent — safe to re-run after a host upgrade if the docker GID changes.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

DOCKER_SOCKET=/var/run/docker.sock
RUNNER_UID=1001

if [[ ! -S "$DOCKER_SOCKET" ]]; then
  echo "error: $DOCKER_SOCKET not found — is Docker installed and running?" >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example."
  echo "  → Edit it to set GITHUB_PAT, GITHUB_ORG (or GITHUB_REPO_URL), RUNNER_NAME, RUNNER_LABELS before bringing up."
fi

docker_gid=$(stat -c '%g' "$DOCKER_SOCKET")
if grep -q '^DOCKER_GID=' .env; then
  sed -i "s/^DOCKER_GID=.*/DOCKER_GID=$docker_gid/" .env
else
  printf '\nDOCKER_GID=%s\n' "$docker_gid" >> .env
fi
echo "DOCKER_GID=$docker_gid written to .env"

echo "chowning runner-1 runner-2 cache → UID $RUNNER_UID (sudo)..."
sudo chown -R "$RUNNER_UID:$RUNNER_UID" runner-1 runner-2 cache

echo
echo "Setup complete. Next: docker compose up -d"
