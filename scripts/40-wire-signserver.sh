#!/usr/bin/env bash
# 40 — Recreate SignServer so it picks up the CA/TLS/worker mounts, then verify TLS.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

banner "Step 40 — Wire SignServer (mounts) and verify its TLS certificate"

# The bind-mount targets must exist and be non-empty (steps 20-30 produced them).
for f in ManagementCA.crt server.jks server.storepasswd signer01.p12; do
  [[ -s "$KEYS_DIR/$f" ]] || fail "keys/$f is missing or empty — run steps 20-30 first."
done

cd "$PROJECT_ROOT"
info "Recreating SignServer so it loads the CA trust, TLS keystore, and worker keystore..."
docker compose up -d --no-deps --force-recreate signserver

wait_for_http "https://localhost:8444/signserver/healthcheck/signserverhealth" "SignServer health" 300

# Verify the served TLS certificate is the EJBCA-issued one
info "Checking the served TLS certificate..."
sleep 2
SERVED="$(echo | openssl s_client -connect localhost:8444 -servername signserver 2>/dev/null | openssl x509 -noout -subject -issuer 2>/dev/null || true)"
echo "  $SERVED"
if [[ "$SERVED" == *'CN = signserver'* && "$SERVED" == *'ManagementCA'* ]]; then
  ok "SignServer serves CN=signserver issued by ManagementCA (no more self-signed)."
else
  fail "SignServer is NOT serving the expected certificate. Check mounts and logs (docker compose logs signserver)."
fi

checkpoint "SignServer TLS verified. Next: register the admin and configure the worker (step 50)."
