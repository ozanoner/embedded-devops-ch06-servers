#!/usr/bin/env bash
# 95 — Health check: is the stack up, secure, and ready for code-signing + device enrollment?
# Read-only check (only creates temp files for a signature/enrollment test). Exit code:
#   0 = all checks passed (READY)
#   1 = one or more checks failed
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

PASS=0
FAIL=0
pass()      { ok "$1"; PASS=$((PASS + 1)); }
failcheck() { echo "${C_RED}[FAIL]${C_NC}  $1"; FAIL=$((FAIL + 1)); }

banner "Health check — SignServer + enroll stack (ready?)"

# --- 1. Containers -----------------------------------------------------------
info "1. Containers"
for c in ejbca signserver github-runner enroll; do
  st="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)"
  if [[ "$st" == "true" ]]; then
    pass "container '$c' is running"
  else
    failcheck "container '$c' is NOT running"
  fi
done

# --- 2. Health endpoints (no client cert) -----------------------------------
info "2. Health endpoints"
code="$(curl -k -s -o /dev/null -w '%{http_code}' https://localhost:8444/signserver/healthcheck/signserverhealth 2>/dev/null || echo 000)"
if [[ "$code" == "200" ]]; then pass "signserver healthcheck -> 200"; else failcheck "signserver healthcheck -> $code"; fi
code="$(curl -k -s -o /dev/null -w '%{http_code}' https://localhost:8445/ejbca/publicweb/healthcheck/ejbcahealth 2>/dev/null || echo 000)"
if [[ "$code" == "200" ]]; then pass "ejbca healthcheck -> 200"; else failcheck "ejbca healthcheck -> $code"; fi
code="$(curl -k -s -o /dev/null -w '%{http_code}' https://localhost:9443/health 2>/dev/null || echo 000)"
if [[ "$code" == "200" ]]; then pass "enroll /health -> 200 (no client cert)"; else failcheck "enroll /health -> $code"; fi

# --- 3. SignServer TLS certificate ------------------------------------------
info "3. SignServer TLS certificate"
SERVED="$(echo | openssl s_client -connect localhost:8444 -servername signserver 2>/dev/null | openssl x509 -noout -subject -issuer 2>/dev/null || true)"
if [[ "$SERVED" == *'CN = signserver'* && "$SERVED" == *'ManagementCA'* ]]; then
  pass "served cert is CN=signserver issued by ManagementCA"
else
  failcheck "served cert is not the expected ManagementCA-issued cert: ${SERVED:-<no cert>}"
fi

# --- 4. AdminWeb (admin client cert) ----------------------------------------
info "4. AdminWeb (admin client cert)"
code="$(curl -k -s -o /dev/null -w '%{http_code}' \
  --cert "$KEYS_DIR/signserver-admin.crt" --key "$KEYS_DIR/signserver-admin.key" \
  https://localhost:8444/signserver/adminweb/ 2>/dev/null || echo 000)"
if [[ "$code" == "200" ]]; then pass "AdminWeb -> 200 with admin cert"; else failcheck "AdminWeb -> $code with admin cert"; fi

# --- 5. Workers --------------------------------------------------------------
info "5. SignServer workers"
for w in CryptoTokenP12 PlainSigner; do
  st="$(signserver_cli getstatus brief "$w" 2>/dev/null || true)"
  if [[ "$st" == *'Active'* ]]; then
    pass "worker '$w' is Active"
  else
    failcheck "worker '$w' is NOT active"
  fi
done

# --- 6. Authorized clients ---------------------------------------------------
info "6. Authorized clients for PlainSigner"
acl="$(signserver_cli authorizedclients -worker PlainSigner -list 2>/dev/null || true)"
if [[ "$acl" == *'runner'* ]]; then
  pass "runner is an authorized client of PlainSigner"
else
  failcheck "no authorized client (runner) found for PlainSigner"
fi

# --- 7. GitHub runner --------------------------------------------------------
# NOTE: the runner writes its console logs to stderr, so capture 2>&1. Use bash
# pattern matching on the captured variable (no pipe): 'grep -q' on large output
# SIGPIPEs the producer -> exit 141 -> pipefail reports a false failure.
info "7. GitHub runner"
runner_log="$(docker logs github-runner 2>&1 || true)"
if [[ "$runner_log" == *"Listening for Jobs"* ]]; then
  pass "runner is listening for jobs"
else
  failcheck "runner is not listening for jobs (check registration/token)"
fi

# --- 8. End-to-end signing ---------------------------------------------------
info "8. End-to-end signing (runner cert -> PlainSigner -> verify)"
if [[ ! -s "$KEYS_DIR/signer01.crt" ]]; then
  failcheck "keys/signer01.crt missing — cannot verify signatures"
else
  payload="/tmp/hc-payload-$$.txt"
  sig="/tmp/hc-sig-$$.bin"
  printf 'healthcheck %s\n' "$(date -u +%FT%TZ)" > "$payload"
# Prefer signing from inside the runner container (proves the real runner path);
  # fall back to the host using the runner's client cert.
  if docker cp "$payload" github-runner:/tmp/hc-payload.txt >/dev/null 2>&1; then
    ok_code="$(docker exec github-runner bash -lc 'curl -s -o /tmp/hc-sig.bin -w "%{http_code}" -G \
      --cacert /home/runner/keys/ManagementCA.crt \
      --cert /home/runner/keys/client.crt --key /home/runner/keys/client.key \
      "https://signserver:8443/signserver/process" \
      --data-urlencode "workerName=PlainSigner" \
      --data-urlencode "data@/tmp/hc-payload.txt"' 2>/dev/null || true)"
    if [[ "$ok_code" == "200" ]] && docker cp github-runner:/tmp/hc-sig.bin "$sig" >/dev/null 2>&1; then
      echo "    (signed from inside the runner container)"
    else
      echo "    (runner signing path failed; trying host with the runner cert)"
      curl -k -s -o "$sig" -G --cert "$KEYS_DIR/client.crt" --key "$KEYS_DIR/client.key" \
        "https://localhost:8444/signserver/process" \
        --data-urlencode "workerName=PlainSigner" \
        --data-urlencode "data@$payload" || true
    fi
  else
    echo "    (runner container not available; trying host with the runner cert)"
    docker cp "$payload" github-runner:/tmp/hc-payload.txt >/dev/null 2>&1 || true
    curl -k -s -o "$sig" -G --cert "$KEYS_DIR/client.crt" --key "$KEYS_DIR/client.key" \
      "https://localhost:8444/signserver/process" \
      --data-urlencode "workerName=PlainSigner" \
      --data-urlencode "data@$payload" || true
  fi

  openssl x509 -in "$KEYS_DIR/signer01.crt" -pubkey -noout > /tmp/hc-signer.pub 2>/dev/null || true
  if [[ -s "$sig" ]] && openssl dgst -sha256 \
      -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
      -verify /tmp/hc-signer.pub -signature "$sig" "$payload" >/dev/null 2>&1; then
    pass "RSA-PSS signature produced and verified OK (ESP32 Secure Boot v2 code-signing path)"
  else
    failcheck "end-to-end signing/verification failed (RSA-PSS salt 32)"
  fi
  rm -f "$payload" "$sig" /tmp/hc-signer.pub /tmp/hc-sig.bin 2>/dev/null || true
fi

# --- 9. Device enrollment (enroll service) -----------------------------------
# Proves the whole enrollment path: device-factory mTLS -> enroll -> EJBCA REST ->
# ManagementCA-issued cert. Re-enrolls a fixed 'hc-enroll-check' device (pkcs10enroll
# resets the end entity to NEW and re-issues — idempotent), then verifies the PEM.
info "9. Device enrollment (enroll service)"
if [[ ! -s "$KEYS_DIR/device-factory.crt" || ! -s "$KEYS_DIR/device-factory.key" \
   || ! -s "$KEYS_DIR/enroll.crt" || ! -s "$KEYS_DIR/superadmin.crt" ]]; then
  info "    (enroll certs not issued yet — run scripts/35-issue-enroll-certs.sh; skipping)"
elif [[ "$(docker inspect -f '{{.State.Running}}' enroll 2>/dev/null || echo false)" != "true" ]]; then
  failcheck "enroll container is NOT running (cannot test enrollment)"
else
  hc_key="/tmp/hc-enroll-key-$$.key";  hc_csr="/tmp/hc-enroll-csr-$$.csr"
  hc_req="/tmp/hc-enroll-req-$$.json"; hc_cert="/tmp/hc-enroll-cert-$$.pem"
  if openssl ecparam -name prime256v1 -genkey -noout -out "$hc_key" >/dev/null 2>&1 \
     && openssl req -new -key "$hc_key" -subj "/CN=hc-enroll-check" -out "$hc_csr" >/dev/null 2>&1 \
     && python3 -c "import json,sys;print(json.dumps({'device_id':'hc-enroll-check','csr':open('$hc_csr').read()}))" > "$hc_req" 2>/dev/null; then
    ecode="$(curl -k -s --max-time 15 --cert "$KEYS_DIR/device-factory.crt" --key "$KEYS_DIR/device-factory.key" \
      -X POST -H 'Content-Type: application/json' --data-binary @"$hc_req" \
      https://localhost:9443/enroll -o "$hc_cert" -w '%{http_code}' 2>/dev/null || echo 000)"
    if [[ "$ecode" == "200" ]] && openssl verify -CAfile "$KEYS_DIR/ManagementCA.crt" "$hc_cert" >/dev/null 2>&1; then
      pass "enroll: mTLS CSR -> 200 + ManagementCA-issued cert"
    else
      failcheck "enroll failed (HTTP $ecode) or the returned cert does not verify"
    fi
  else
    failcheck "could not generate the test CSR for the enrollment check"
  fi
  rm -f "$hc_key" "$hc_csr" "$hc_req" "$hc_cert" 2>/dev/null || true
fi

# --- Summary -----------------------------------------------------------------
echo
echo "────────────────────────────────────────────────────────────────"
echo "  Result: $PASS passed, $FAIL failed"
echo "────────────────────────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
  ok "READY — the stack is healthy and ready for code-signing and device enrollment."
  exit 0
else
  warn "NOT READY — $FAIL check(s) failed. Review the details above."
  exit 1
fi
