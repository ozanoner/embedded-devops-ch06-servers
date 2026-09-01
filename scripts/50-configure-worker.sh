#!/usr/bin/env bash
# 50 — Register the admin cert, create CryptoTokenP12 + PlainSigner, authorize the runner.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

banner "Step 50 — Register admin, configure the PlainSigner worker, authorize the runner"

docker exec signserver true 2>/dev/null || fail "The 'signserver' container is not running. Run step 40 first."

# ---------------------------------------------------------------------------
# 1) Register the admin certificate (signserver-admin)
# ---------------------------------------------------------------------------
ADMINS="$(signserver_cli wsadmins -list 2>/dev/null || true)"
if [[ "$ADMINS" == *'ManagementCA'* ]]; then
  info "Admin already registered — skipping."
else
  info "Registering 'signserver-admin' as an authorized administrator..."
  # The container app user (uid 10001) must be able to read the cert file.
  cp "$KEYS_DIR/signserver-admin.crt" /tmp/signserver-admin.crt
  chmod 644 /tmp/signserver-admin.crt
  docker cp /tmp/signserver-admin.crt signserver:/tmp/signserver-admin.crt
  # docker cp preserves the host 0644 perms, so the file is already world-readable.
  # A chmod inside the container would fail anyway ('Operation not permitted':
  # docker cp writes the file as root, and we run as uid 10001) — so tolerate it.
  docker exec signserver chmod 644 /tmp/signserver-admin.crt 2>/dev/null || true
  signserver_cli wsadmins -add -cert /tmp/signserver-admin.crt || {
    warn "First wsadmins -add attempt failed; retrying (permissions already forced to 0644)..."
    signserver_cli wsadmins -add -cert /tmp/signserver-admin.crt
  }
  rm -f /tmp/signserver-admin.crt
  ok "Admin registered."
fi
echo
signserver_cli wsadmins -list

# ---------------------------------------------------------------------------
# 2) Crypto token (CryptoTokenP12) + PlainSigner worker
# ---------------------------------------------------------------------------
WSTATUS="$(signserver_cli getstatus brief PlainSigner 2>/dev/null || true)"
if [[ "$WSTATUS" == *'Active'* ]]; then
  info "PlainSigner worker already configured — skipping."
else
  info "Creating CryptoTokenP12 + PlainSigner via setproperties..."
  cat > /tmp/worker.properties <<EOF
WORKERGENID1.TYPE=CRYPTO_WORKER
WORKERGENID1.IMPLEMENTATION_CLASS=org.signserver.server.signers.CryptoWorker
WORKERGENID1.NAME=CryptoTokenP12
WORKERGENID1.CRYPTOTOKEN_IMPLEMENTATION_CLASS=org.signserver.server.cryptotokens.KeystoreCryptoToken
WORKERGENID1.KEYSTORETYPE=PKCS12
WORKERGENID1.KEYSTOREPATH=/mnt/external/secrets/signer01.p12
WORKERGENID1.KEYSTOREPASSWORD=$P12_PASS
WORKERGENID1.DEFAULTKEY=signer01

WORKERGENID2.TYPE=PROCESSABLE
WORKERGENID2.IMPLEMENTATION_CLASS=org.signserver.module.cmssigner.PlainSigner
WORKERGENID2.NAME=PlainSigner
WORKERGENID2.AUTHTYPE=NOAUTH
WORKERGENID2.CRYPTOTOKEN=CryptoTokenP12
WORKERGENID2.DEFAULTKEY=signer01
WORKERGENID2.SIGNATUREALGORITHM=SHA256withRSA
WORKERGENID2.DISABLEKEYUSAGECOUNTER=true
EOF
  docker cp /tmp/worker.properties signserver:/tmp/worker.properties
  signserver_cli setproperties /tmp/worker.properties >/dev/null
  signserver_cli reload PlainSigner    >/dev/null 2>&1 || true
  signserver_cli reload CryptoTokenP12 >/dev/null 2>&1 || true
  rm -f /tmp/worker.properties
  info "Worker created. Reloading configuration..."
  # Full reload is needed for the token to become active.
  signserver_cli reload PlainSigner >/dev/null 2>&1 || true
fi

echo
signserver_cli getstatus brief CryptoTokenP12 || true
signserver_cli getstatus brief PlainSigner   || true
st="$(signserver_cli getstatus brief PlainSigner 2>/dev/null || true)"
[[ "$st" == *'Active'* ]] || fail "PlainSigner is not Active."

# ---------------------------------------------------------------------------
# 3) Authorize the runner client cert for the worker
# ---------------------------------------------------------------------------
ACL="$(signserver_cli authorizedclients -worker PlainSigner -list 2>/dev/null || true)"
if [[ "${ACL,,}" == *'runner'* ]]; then
  info "Runner already authorized — skipping."
else
  info "Authorizing the runner client cert (CN=runner) for PlainSigner..."
  cp "$KEYS_DIR/client.crt" /tmp/client.crt
  chmod 644 /tmp/client.crt
  docker cp /tmp/client.crt signserver:/tmp/client.crt
  signserver_cli authorizedclients -worker PlainSigner -add \
    -matchSubjectWithType CERTIFICATE_SERIALNO \
    -matchIssuerWithType ISSUER_DN_BCSTYLE \
    -cert /tmp/client.crt -description "runner"
  rm -f /tmp/client.crt
  ok "Runner authorized."
fi
echo
signserver_cli authorizedclients -worker PlainSigner -list

# ---------------------------------------------------------------------------
# 4) Sanity: AdminWeb now answers 200 with the admin cert
# ---------------------------------------------------------------------------
code="$(curl -k -s -o /dev/null -w '%{http_code}' \
  --cert "$KEYS_DIR/signserver-admin.crt" --key "$KEYS_DIR/signserver-admin.key" \
  https://localhost:8444/signserver/adminweb/ 2>/dev/null || true)"
if [[ "$code" == "200" ]]; then
  ok "AdminWeb returns 200 with the admin client cert."
else
  warn "AdminWeb returned HTTP $code with the admin cert (expected 200). Check 'wsadmins -list'."
fi

checkpoint "Worker configured and runner authorized. Next: register the GitHub runner (step 60)."
