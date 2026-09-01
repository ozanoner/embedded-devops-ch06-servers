#!/usr/bin/env bash
# 30 — Issue all service certificates from ManagementCA and prepare the keystores.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

banner "Step 30 — Issue server, client, and signing certificates from ManagementCA"

docker exec ejbca true 2>/dev/null || fail "The 'ejbca' container is not running. Run step 10 first."
[[ -s "$KEYS_DIR/ManagementCA.crt" ]] || fail "keys/ManagementCA.crt is missing — run step 20 first."

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
  # remove only the individual temp files (never the directory)
  docker exec ejbca rm -f "/tmp/p12/$user.p12" /tmp/batch.log
  ok "Issued '$user' -> keys/$user.p12"
}

issue_ee signserver       "signserver"       SERVER  "dNSName=signserver,dNSName=localhost"
issue_ee signserver-admin "signserver-admin" ENDUSER ""
issue_ee runner           "runner"           ENDUSER ""
issue_ee signer01         "signer01"         ENDUSER ""

# ---------------------------------------------------------------------------
# SignServer TLS keystore: signserver.p12 -> server.jks (+ password file)
# ---------------------------------------------------------------------------
if [[ -s "$KEYS_DIR/server.jks" ]] && keytool -list -keystore "$KEYS_DIR/server.jks" -storepass "$P12_PASS" >/dev/null 2>&1; then
  info "server.jks already valid — skipping conversion."
else
  info "Converting signserver.p12 -> server.jks (TLS keystore)..."
  # Step 10 pre-creates an empty placeholder for this bind mount; keytool refuses
  # to import into an existing-but-empty file, so remove it first (individual file).
  rm -f "$KEYS_DIR/server.jks"
  keytool -importkeystore -noprompt \
    -srckeystore "$KEYS_DIR/signserver.p12" -srcstoretype PKCS12 -srcstorepass "$P12_PASS" -srcalias signserver \
    -destkeystore "$KEYS_DIR/server.jks" -deststoretype JKS -deststorepass "$P12_PASS" -destalias signserver \
    >/dev/null 2>&1 || fail "keytool conversion to server.jks failed."
  printf '%s' "$P12_PASS" > "$KEYS_DIR/server.storepasswd"
  ok "server.jks + server.storepasswd created."
fi

# ---------------------------------------------------------------------------
# PEM files: runner client cert (client.crt/key), admin cert/key, signer cert
# ---------------------------------------------------------------------------
extract_pem() {
  local user="$1" crt="$2" key="$3"
  [[ -s "$KEYS_DIR/$crt" ]] || openssl pkcs12 -in "$KEYS_DIR/$user.p12" -clcerts -nokeys -passin "pass:$P12_PASS" -out "$KEYS_DIR/$crt"
  if [[ -n "$key" && ! -s "$KEYS_DIR/$key" ]]; then
    openssl pkcs12 -in "$KEYS_DIR/$user.p12" -nocerts -nodes -passin "pass:$P12_PASS" -out "$KEYS_DIR/$key"
  fi
  # The runner container runs as uid 1001 and reads client.crt/client.key through
  # a read-only bind mount that preserves HOST permissions (which may be 0600,
  # e.g. under a 077 umask) — so ensure both files are world-readable. chmod
  # unconditionally so re-running this step also repairs already-extracted files.
  chmod 644 "$KEYS_DIR/$crt" 2>/dev/null || true
  if [[ -n "$key" ]]; then
    chmod 644 "$KEYS_DIR/$key" 2>/dev/null || true
  fi
}
extract_pem runner          client.crt client.key          # cert the GitHub runner presents
extract_pem signserver-admin signserver-admin.crt signserver-admin.key
extract_pem signer01        signer01.crt ""

echo
info "Issued certificates (subject <- issuer):"
for c in superadmin signserver signserver-admin runner signer01; do
  if [[ -s "$KEYS_DIR/$c.crt" ]]; then
    echo "  $c: $(openssl x509 -in "$KEYS_DIR/$c.crt" -noout -subject -issuer 2>/dev/null)"
  fi
done

checkpoint "Certificates issued. Next: wire SignServer to use them (step 40)."
