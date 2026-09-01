#!/usr/bin/env bash
# 00 — Preflight: verify tooling, Docker daemon + Compose, project files, and ports.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

banner "Step 00 — Preflight checks (tooling, Docker, ports)"

# --- required CLI tools (Debian/Ubuntu hints) ---
require_cmd docker
require_cmd openssl
require_cmd curl
require_cmd git
if ! command -v keytool >/dev/null 2>&1; then
  fail "Required command 'keytool' not found. Install a JRE/JDK: sudo apt install -y default-jre-headless"
fi
ok "CLI tools present (docker, openssl, curl, git, keytool)."

# --- Docker daemon ---
if ! docker info >/dev/null 2>&1; then
  fail "Docker daemon is not running or not accessible. Start it (e.g. 'sudo systemctl start docker') and re-run."
fi
ok "Docker daemon is running."

# --- Docker Compose v2 plugin ---
COMPOSE_VER="$(docker compose version --short 2>/dev/null || true)"
if [[ -z "$COMPOSE_VER" ]]; then
  fail "Docker Compose (v2 plugin) is missing. Install it (Debian/Ubuntu: 'docker-compose-plugin') and re-run."
fi
ok "Docker Compose v2 available ($COMPOSE_VER)."

# --- project files ---
[[ -f "$PROJECT_ROOT/docker-compose.yml" ]] || fail "docker-compose.yml not found in $PROJECT_ROOT."
ok "docker-compose.yml present."

# --- ports ---
for p in 8081 8082 8444 8445; do
  if port_in_use "$p"; then
    warn "Port $p is already in use — the stack may fail to bind. Please free it before continuing."
  else
    ok "Port $p is free."
  fi
done

# --- keys dir ---
mkdir -p "$KEYS_DIR"
ok "keys/ directory ready at $KEYS_DIR"

echo
if confirm "All preflight checks done. Proceed to start the stack?"; then
  ok "Proceeding."
else
  info "Aborted by user."
  exit 0
fi
