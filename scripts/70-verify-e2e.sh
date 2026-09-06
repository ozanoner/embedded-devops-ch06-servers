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
docker exec github-runner bash -lc 'curl -s -o /tmp/e2e-sig.bin -w "HTTP %{http_code}\n" -G \
  --cacert /home/runner/keys/ManagementCA.crt \
  --cert /home/runner/keys/client.crt --key /home/runner/keys/client.key \
  "https://signserver:8443/signserver/process" \
  --data-urlencode "workerName=PlainSigner" \
  --data-urlencode "data@/tmp/e2e-payload.txt"'

docker cp github-runner:/tmp/e2e-sig.bin /tmp/e2e-sig.bin

info "Verifying the RSA-PSS signature with the signer public key..."
openssl x509 -in "$KEYS_DIR/signer01.crt" -pubkey -noout > /tmp/signer01.pub
# PlainSigner signs with SHA256withRSAandMGF1 = RSA-PSS (SHA-256, MGF1, salt 32):
# the exact scheme ESP32 Secure Boot v2 verifies. In production the 'data' would
# be a secure-padded ESP-IDF image and this signature feeds 'idf.py secure-sign-data'.
if openssl dgst -sha256 \
    -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
    -verify /tmp/signer01.pub -signature /tmp/e2e-sig.bin /tmp/e2e-payload.txt >/dev/null 2>&1; then
  ok "RSA-PSS signature verified OK — the runner can sign ESP32 Secure Boot v2 images (RSA-3072/PSS)."
else
  fail "Signature did not verify. Remember: the process endpoint signs the exact raw bytes of 'data' (no base64); verify with RSA-PSS salt=32."
fi

echo
ok "The stack is fully wired and verified end-to-end."
