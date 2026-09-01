#!/usr/bin/env bash
# 80 — Browser (Chrome) trust guidance. Browser-only: NO system or NSS store changes.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

banner "Step 80 — Chrome: import the admin client cert and open the AdminWeb"

[[ -s "$KEYS_DIR/signserver-admin.p12" ]] || fail "keys/signserver-admin.p12 is missing — run step 30 first."

# Quick sanity so we hand over a valid p12 and a reachable server.
if openssl pkcs12 -in "$KEYS_DIR/signserver-admin.p12" -noout -passin "pass:$P12_PASS" >/dev/null 2>&1; then
  ok "signserver-admin.p12 is valid (password: $P12_PASS)."
else
  warn "Could not open signserver-admin.p12 with the default password."
fi

code="$(curl -k -s -o /dev/null -w '%{http_code}' https://localhost:8444/signserver/healthcheck/signserverhealth 2>/dev/null || true)"
if [[ "$code" == "200" ]]; then
  ok "SignServer is reachable."
else
  warn "SignServer health check returned HTTP $code."
fi

cat <<EOF

────────────────────────────────────────────────────────────────────
  CHROME (Linux) — manual steps. No system/NSS trust store is touched.
────────────────────────────────────────────────────────────────────
  1. Import the client certificate:
       chrome://settings/certificates  →  "Your certificates"  →  Import
       select:  $KEYS_DIR/signserver-admin.p12
       password: $P12_PASS
     This is the CN=signserver-admin certificate Chrome will present to
     SignServer's AdminWeb.

  2. Open the AdminWeb:
       https://localhost:8444/signserver/adminweb/

  3. Chrome warns "Your connection is not private"
     (NET::ERR_CERT_AUTHORITY_INVALID) because ManagementCA is a private
     CA that is not in the OS trust store. Click:
       "Advanced"  →  "Proceed to localhost (unsafe)"
     The page then loads because you authenticated with the client cert.

  NOTE: If you also use Firefox, import signserver-admin.p12 there and add
  keys/ManagementCA.crt to Firefox's own trust store — still no system change.
────────────────────────────────────────────────────────────────────
EOF

if confirm "Open the AdminWeb in the default browser now?"; then
  xdg-open "https://localhost:8444/signserver/adminweb/" >/dev/null 2>&1 || \
    warn "Could not auto-open a browser; open the URL manually."
fi

checkpoint "Browser trust steps reviewed. Setup complete!"
