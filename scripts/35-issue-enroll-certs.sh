#!/usr/bin/env bash
# 35 — Enable the EJBCA REST API, issue the enroll-service certs, start the service.
#   * Enables EJBCA REST Certificate Management (V1 + V2) — required for enrollment.
#   * Issues CN=enroll (SERVER profile, SAN dnsName=enroll,localhost) -> keys/enroll.p12 (+ PEM).
#   * Issues CN=device-factory (ENDUSER profile) -> keys/device-factory.p12 (+ PEM).
#   * Starts the 'enroll' compose service (needs the certs to exist first).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

banner "Step 35 — Enable EJBCA REST, issue enroll + device-factory certs, start enroll"

docker exec ejbca true 2>/dev/null || fail "The 'ejbca' container is not running. Run step 10 first."
[[ -s "$KEYS_DIR/ManagementCA.crt" ]] || fail "keys/ManagementCA.crt is missing — run step 20 first."

# ---------------------------------------------------------------------------
# 1) Enable the EJBCA REST API (certificate enrollment uses it). Disabled by
#    default — every REST call then returns "This service has been disabled."
# ---------------------------------------------------------------------------
info "Enabling EJBCA REST Certificate Management (V1 + V2)..."
protocol_status="$(docker exec ejbca /opt/keyfactor/bin/ejbca.sh config protocols status 2>/dev/null || true)"
protocol_enabled() {
  local proto="$1" line
  while IFS= read -r line; do
    if [[ "$line" == *"$proto:"*Enabled* ]]; then
      return 0
    fi
  done <<< "$protocol_status"
  return 1
}
for proto in "REST Certificate Management" "REST Certificate Management V2"; do
  if protocol_enabled "$proto"; then
    ok "'$proto' already enabled."
  else
    docker exec ejbca /opt/keyfactor/bin/ejbca.sh config protocols enable "$proto" \
      -u "$EJBCA_CLI_USER" --clipassword "$EJBCA_CLI_PASS" >/dev/null 2>&1 \
      || warn "Could not enable '$proto' (it may already be enabled)."
  fi
done

# ---------------------------------------------------------------------------
# 2) Issue certificates (same CLI flow as step 30).
# ---------------------------------------------------------------------------
# issue_ee <user> <CN> <certprofile> <altname-or-''>
issue_ee() {
  local user="$1" cn="$2" profile="$3" altname="$4"
  if [[ -s "$KEYS_DIR/$user.p12" ]]; then
    info "keys/$user.p12 already exists — skipping '$user'."
    return
  fi
  info "Adding end entity '$user' (CN=$cn, certprofile=$profile)..."
  if ! ejbca_cli ra addendentity "$user" --dn "CN=$cn" --caname "$MANAGEMENT_CA" --type 1 --token P12 \
        --certprofile "$profile" --eeprofile EMPTY --password "$P12_PASS" \
        ${altname:+--altname "$altname"} -u "$EJBCA_CLI_USER" --clipassword "$EJBCA_CLI_PASS" >/dev/null 2>&1; then
    warn "addendentity for '$user' reported an error (it may already exist from a partial run). Continuing."
  fi
  ra_setclearpwd "$user" "$P12_PASS" || fail "setclearpwd failed for '$user'."
  info "Generating keystore for '$user' (batch)..."
  if ! docker exec ejbca sh -c "mkdir -p /tmp/p12 && /opt/keyfactor/bin/ejbca.sh batch $user --keyalg RSA --keyspec 2048 -dir /tmp/p12 -u ejbca --clipassword ejbca >/tmp/batch.log 2>&1 && test -s /tmp/p12/$user.p12"; then
    docker exec ejbca cat /tmp/batch.log 2>/dev/null || true
    fail "batch generation failed for '$user' (see log above)."
  fi
  docker cp "ejbca:/tmp/p12/$user.p12" "$KEYS_DIR/$user.p12"
  docker exec ejbca rm -f "/tmp/p12/$user.p12" /tmp/batch.log
  ok "Issued '$user' -> keys/$user.p12"
}

issue_ee enroll         "enroll"         SERVER  "dNSName=enroll,dNSName=localhost"
issue_ee device-factory "device-factory" ENDUSER ""

# ---------------------------------------------------------------------------
# 3) PEM files for the enroll service (server cert/key + factory client cert).
# ---------------------------------------------------------------------------
extract_pem() {
  local user="$1" crt="$2" key="$3"
  [[ -s "$KEYS_DIR/$crt" ]] || openssl pkcs12 -in "$KEYS_DIR/$user.p12" -clcerts -nokeys -passin "pass:$P12_PASS" -out "$KEYS_DIR/$crt"
  if [[ -n "$key" && ! -s "$KEYS_DIR/$key" ]]; then
    openssl pkcs12 -in "$KEYS_DIR/$user.p12" -nocerts -nodes -passin "pass:$P12_PASS" -out "$KEYS_DIR/$key"
  fi
  chmod 644 "$KEYS_DIR/$crt" 2>/dev/null || true
  if [[ -n "$key" ]]; then
    chmod 644 "$KEYS_DIR/$key" 2>/dev/null || true
  fi
}
extract_pem enroll         enroll.crt enroll.key
extract_pem device-factory device-factory.crt device-factory.key

echo
info "Issued certificates (subject <- issuer):"
for c in enroll device-factory; do
  echo "  $c: $(openssl x509 -in "$KEYS_DIR/$c.crt" -noout -subject -issuer 2>/dev/null)"
done

# ---------------------------------------------------------------------------
# 4) Start the enroll service (its certs now exist).
# ---------------------------------------------------------------------------
info "Starting the 'enroll' service (docker compose up -d enroll)..."
cd "$PROJECT_ROOT"
docker compose up -d enroll
wait_for_log enroll "enroll listening" "enroll service" 60 || true

echo
ok "Step 35 complete: REST enabled, enroll + device-factory certs issued, service started."
checkpoint "Next: wire SignServer (step 40) — or skip ahead to verify the enroll service."
