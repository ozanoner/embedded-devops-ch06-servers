#!/usr/bin/env bash
# 70 — End-to-end verification: the runner signs through SignServer, then verify.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

banner "Step 70 — End-to-end verification (runner -> SignServer -> verify signature)"

docker exec github-runner true 2>/dev/null || fail "The 'github-runner' container is not running. Run step 60 first."
[[ -s "$KEYS_DIR/signer01.crt" ]] || fail "keys/signer01.crt is missing — run step 30 first."

# Build a payload and copy it into the runner container.
printf 'replicated-setup verification %s\n' "$(date -u +%FT%TZ)" > /tmp/e2e-payload.txt
docker cp /tmp/e2e-payload.txt github-runner:/tmp/e2e-payload.txt

info "Calling PlainSigner from inside the runner container (mutual TLS)..."
docker exec github-runner bash -lc 'curl -k -s -o /tmp/e2e-sig.bin -w "HTTP %{http_code}\n" -G \
  --cert /home/runner/keys/client.crt --key /home/runner/keys/client.key \
  "https://signserver:8443/signserver/process" \
  --data-urlencode "workerName=PlainSigner" \
  --data-urlencode "data@/tmp/e2e-payload.txt"'

docker cp github-runner:/tmp/e2e-sig.bin /tmp/e2e-sig.bin

info "Verifying the signature with the signer public key..."
openssl x509 -in "$KEYS_DIR/signer01.crt" -pubkey -noout > /tmp/signer01.pub
if openssl dgst -sha256 -verify /tmp/signer01.pub -signature /tmp/e2e-sig.bin /tmp/e2e-payload.txt >/dev/null 2>&1; then
  ok "Signature verified OK — the runner can sign through SignServer."
else
  fail "Signature did not verify. Remember: the process endpoint signs the exact raw bytes of 'data' (no base64)."
fi

echo
ok "The stack is fully wired and verified end-to-end."
