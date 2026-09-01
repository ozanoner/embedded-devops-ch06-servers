#!/usr/bin/env bash
# 10 — Start EJBCA + SignServer (the runner is added in step 60, it needs a token).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

banner "Step 10 — Start the stack (EJBCA + SignServer)"

[[ -f "$PROJECT_ROOT/docker-compose.yml" ]] || fail "docker-compose.yml not found in $PROJECT_ROOT."

# Docker Compose needs a .env file to exist (it is referenced by the runner service).
if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  info "Creating an empty .env (the runner step will fill it in later)."
  touch "$PROJECT_ROOT/.env"
fi

# On a fresh machine the bind-mount targets do not exist yet. Pre-create them as
# empty placeholders so Docker does not turn them into directories that would hide
# the real files. (If this is a re-run on a machine that already has certs, skip.)
if [[ ! -s "$KEYS_DIR/ManagementCA.crt" || ! -s "$KEYS_DIR/server.jks" || ! -s "$KEYS_DIR/signer01.p12" ]]; then
  info "Creating placeholder files for the bind mounts (replaced in steps 20-35)..."
  mkdir -p "$KEYS_DIR"
  : > "$KEYS_DIR/ManagementCA.crt" || true
  : > "$KEYS_DIR/server.jks" || true
  : > "$KEYS_DIR/server.storepasswd" || true
  : > "$KEYS_DIR/signer01.p12" || true
  # enroll-service bind mounts (real certs are issued in step 35; placeholders
  # keep `docker compose up -d` from turning these into directories)
  : > "$KEYS_DIR/enroll.crt" || true
  : > "$KEYS_DIR/enroll.key" || true
fi

cd "$PROJECT_ROOT"
info "Running: docker compose up -d ejbca signserver"
docker compose up -d ejbca signserver

# Wait for EJBCA first boot (creates ManagementCA + TLS).
wait_for_http "https://localhost:8445/ejbca/publicweb/healthcheck/ejbcahealth" "EJBCA health" 300

echo
info "EJBCA is up and the ManagementCA root has been created on first boot."
checkpoint "Next: enroll the superadmin certificate and export the root CA (step 20)."
