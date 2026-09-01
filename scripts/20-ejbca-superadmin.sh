#!/usr/bin/env bash
# 20 — Enroll the EJBCA 'superadmin' certificate and export the ManagementCA root.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

banner "Step 20 — Enroll EJBCA superadmin + export the ManagementCA root"

docker exec ejbca true 2>/dev/null || fail "The 'ejbca' container is not running. Run step 10 first."

# ---------------------------------------------------------------------------
# 1) superadmin P12 keystore
# ---------------------------------------------------------------------------
if [[ -s "$KEYS_DIR/superadmin.p12" ]]; then
  info "keys/superadmin.p12 already exists — skipping enrollment."
else
  info "Preparing the 'superadmin' end entity for CLI keystore generation..."
  attempt=0
  until ra_setclearpwd superadmin "$P12_PASS"; do
    attempt=$((attempt + 1))
    [[ "$attempt" -ge 3 ]] && fail "Could not set the superadmin password after 3 attempts."
    warn "The 'superadmin' end entity is not ready for CLI password setting yet."
    echo
    echo "  If this is the very first boot, enroll the superadmin certificate via the"
    echo "  EJBCA AdminWeb first:  https://localhost:8445/ejbca/"
    echo "  (use the enrollment code EJBCA printed on startup; token type: P12)."
    echo
    read -r -p "  When the superadmin certificate is enrolled, press Enter to retry (Ctrl-C to abort)... " _
  done

  info "Generating the superadmin keystore via EJBCA CLI batch..."
  if ! docker exec ejbca sh -c 'mkdir -p /tmp/p12 && /opt/keyfactor/bin/ejbca.sh batch superadmin --keyalg RSA --keyspec 2048 -dir /tmp/p12 -u ejbca --clipassword ejbca >/tmp/batch.log 2>&1 && test -s /tmp/p12/superadmin.p12'; then
    docker exec ejbca cat /tmp/batch.log 2>/dev/null || true
    fail "superadmin keystore generation failed (see log above)."
  fi
  docker cp ejbca:/tmp/p12/superadmin.p12 "$KEYS_DIR/superadmin.p12"
  # remove only the individual temp files (never the directory)
  docker exec ejbca rm -f /tmp/p12/superadmin.p12 /tmp/batch.log
  ok "keys/superadmin.p12 created."
fi

# --- superadmin PEM cert/key (for tooling / inspection) ---
[[ -s "$KEYS_DIR/superadmin.crt" ]] || openssl pkcs12 -in "$KEYS_DIR/superadmin.p12" -clcerts -nokeys -passin "pass:$P12_PASS" -out "$KEYS_DIR/superadmin.crt"
if [[ ! -s "$KEYS_DIR/superadmin.key" ]]; then
  openssl pkcs12 -in "$KEYS_DIR/superadmin.p12" -nocerts -nodes -passin "pass:$P12_PASS" -out "$KEYS_DIR/superadmin.key"
  chmod 600 "$KEYS_DIR/superadmin.key"
fi

# Validate the p12 password
if openssl pkcs12 -in "$KEYS_DIR/superadmin.p12" -noout -passin "pass:$P12_PASS" >/dev/null 2>&1; then
  ok "superadmin.p12 opens with the configured password."
else
  fail "Cannot open superadmin.p12 with password '$P12_PASS'."
fi

# ---------------------------------------------------------------------------
# 2) ManagementCA root certificate (the single trust anchor)
# ---------------------------------------------------------------------------
if [[ -s "$KEYS_DIR/ManagementCA.crt" ]] && is_pem_cert "$KEYS_DIR/ManagementCA.crt"; then
  info "keys/ManagementCA.crt already present."
else
  info "Exporting the ManagementCA root certificate..."
  docker exec ejbca /opt/keyfactor/bin/ejbca.sh ca getcacert "$MANAGEMENT_CA" > "$KEYS_DIR/ManagementCA.crt" 2>/dev/null || true
  if ! is_pem_cert "$KEYS_DIR/ManagementCA.crt"; then
    warn "getcacert did not return PEM; extracting the CA from the superadmin P12 chain..."
    openssl pkcs12 -in "$KEYS_DIR/superadmin.p12" -cacerts -nokeys -passin "pass:$P12_PASS" 2>/dev/null \
      | openssl x509 -out "$KEYS_DIR/ManagementCA.crt"
  fi
fi
is_pem_cert "$KEYS_DIR/ManagementCA.crt" || fail "ManagementCA.crt is not a valid PEM certificate."
ok "ManagementCA root certificate saved."

echo
info "CA / superadmin identity:"
openssl x509 -in "$KEYS_DIR/ManagementCA.crt" -noout -subject -issuer
openssl x509 -in "$KEYS_DIR/superadmin.crt"   -noout -subject -issuer

checkpoint "Superadmin + root CA exported. Next: issue the service certificates (step 30)."
