#!/usr/bin/env bash
# 90 — Uninstall: remove containers, data volumes, keys/, and .env.
#
# SAFETY MODEL
#   - Refuses to run unless stdin is an interactive terminal, so it can never
#     run unattended (e.g. piped input) and remove things by itself.
#   - Only touches THIS project's resources, matched by exact names:
#       containers: ejbca, signserver, github-runner, enroll
#       volumes   : ch06-servers_ejbca-data, ch06-servers_signserver-data, ch06-servers_runner-data
#       files     : "$KEYS_DIR" and "$PROJECT_ROOT/.env" (generated, gitignored)
#       images    : the four pinned images (optional step)
#   - Asks for confirmation BEFORE EACH removal step and prints what is about
#     to be removed (with absolute paths). Answering "no" skips that step and
#     continues with the next one.
#   - Run with --dry-run (or -n) to list everything without removing anything.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

banner "Step 90 — Uninstall (containers, volumes, keys, .env, browser certs)"

# --- safety: never run unattended ---
if [[ ! -t 0 ]]; then
  fail "This script must be run interactively in a terminal (it refuses piped/redirected input)."
fi

# --- safety: only run from this project ---
if [[ ! -f "$PROJECT_ROOT/docker-compose.yml" ]]; then
  fail "docker-compose.yml not found in $PROJECT_ROOT — refusing to continue (wrong project?)."
fi

# --- optional dry-run ---
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
  DRY_RUN=1
  info "DRY RUN — printing what would be removed; nothing will be deleted."
fi

warn "This removes containers, persistent data, certificates, and tokens."
warn "Each step asks for confirmation first; answer 'n' to skip that step."
echo
info "The following steps will be offered:"
echo "  1. Containers + named volumes (ejbca, signserver, runner, enroll)"
echo "  2. Certificates / keystores ($KEYS_DIR)"
echo "  3. Runner token ($PROJECT_ROOT/.env)"
echo "  4. Docker images (optional)"
echo "  5. Browser certificates (Chrome/NSS) — optional"
echo

cd "$PROJECT_ROOT"

# ---------------------------------------------------------------------------
# STEP 1 — Containers + named volumes
# ---------------------------------------------------------------------------
echo
info "STEP 1/5 — Containers and named volumes"
echo "  Containers that would be removed (matched by exact name):"
ps_out="$(docker ps -a --format '    {{.Names}}  ({{.Image}}, {{.Status}})' \
  --filter name=ejbca --filter name=signserver --filter name=github-runner --filter name=enroll 2>/dev/null || true)"
if [[ -n "$ps_out" ]]; then
  echo "$ps_out"
else
  echo "    (none found)"
fi
echo "  Named volumes that would be removed (absolute host paths):"
for v in ch06-servers_ejbca-data ch06-servers_signserver-data ch06-servers_runner-data; do
  mp="$(docker volume inspect "$v" --format '{{.Mountpoint}}' 2>/dev/null || true)"
  echo "    $v  ->  ${mp:-<not present>}"
done
if [[ "$DRY_RUN" -eq 1 ]]; then
  warn "(dry run) Would remove the containers + volumes above — not executed."
elif confirm "Remove the containers and their named volumes above?"; then
  running="$(docker compose ps -q 2>/dev/null || true)"
  if [[ -n "$running" ]]; then
    info "Running: docker compose down -v  (removes only this project's volumes)"
    docker compose down -v || true
  else
    info "No running stack containers; removing leftover volumes directly..."
    docker volume rm ch06-servers_ejbca-data ch06-servers_signserver-data ch06-servers_runner-data \
      >/dev/null 2>&1 || true
  fi
  ok "Step 1 done."
else
  warn "Step 1 skipped (containers/volumes kept)."
fi

# ---------------------------------------------------------------------------
# STEP 2 — Individual certificate/keystore files in keys/ (directory is kept)
# Only well-known individual files are ever removed — never the keys/
# directory itself, and never wildcard/recursive removals.
# ---------------------------------------------------------------------------
KEYS_FILES="ManagementCA.crt superadmin.p12 superadmin.crt superadmin.key \
signserver.p12 signserver-admin.p12 signserver-admin.crt signserver-admin.key \
runner.p12 signer01.p12 signer01.crt server.jks server.storepasswd \
client.crt client.key enroll.p12 enroll.crt enroll.key \
device-factory.p12 device-factory.crt device-factory.key worker.properties \
ca.crt ca.key ca.srl client.csr client-browser.p12 client.p12 superadmin-browser.p12"

echo
info "STEP 2/5 — Individual files in keys/"
if [[ -d "$KEYS_DIR" ]]; then
  # Defensive guard: only ever remove files inside the project's own keys/ dir.
  if [[ "$KEYS_DIR" != "$PROJECT_ROOT/keys" ]]; then
    fail "Unexpected keys path '$KEYS_DIR' — refusing to remove anything."
  fi
  echo "  Files that would be removed (individual, absolute paths):"
  found=0
  for f in $KEYS_FILES; do
    if [[ -e "$KEYS_DIR/$f" ]]; then
      echo "    $KEYS_DIR/$f"
      found=1
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "    (none of the known keys/ files are present)"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "(dry run) Would remove the keys/ files above — not executed."
  elif confirm "Remove the individual keys/ files listed above?"; then
    for f in $KEYS_FILES; do
      rm -f -- "$KEYS_DIR/$f"
    done
    ok "Individual keys/ files removed (the directory itself is kept)."
  else
    warn "Step 2 skipped (keys/ files kept)."
  fi
else
  info "keys/ does not exist ($KEYS_DIR) — nothing to remove."
fi

# ---------------------------------------------------------------------------
# STEP 3 — Runner token (.env)
# ---------------------------------------------------------------------------
echo
info "STEP 3/5 — Runner token (.env)"
if [[ -f "$PROJECT_ROOT/.env" ]]; then
  echo "  Will remove file: $PROJECT_ROOT/.env"
  echo "  Keys it contains: $(grep -oE '^[A-Z_]+' "$PROJECT_ROOT/.env" | tr '\n' ' ')"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "(dry run) Would remove .env — not executed."
  elif confirm "Remove the .env file above?"; then
    rm -f "$PROJECT_ROOT/.env"
    ok ".env removed."
  else
    warn "Step 3 skipped (.env kept)."
  fi
else
  info "$PROJECT_ROOT/.env does not exist — nothing to remove."
fi

# ---------------------------------------------------------------------------
# STEP 4 — Docker images (optional)
# ---------------------------------------------------------------------------
echo
info "STEP 4/5 — Docker images (optional)"
echo "  Images that would be removed (exact pinned tags):"
for img in keyfactor/ejbca-ce:9.3.7 keyfactor/signserver-ce:7.3.2 ghcr.io/actions/actions-runner:2.336.0 python:3.12-slim; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "    $img  (present)"
  else
    echo "    $img  (not pulled)"
  fi
done
if [[ "$DRY_RUN" -eq 1 ]]; then
  warn "(dry run) Would remove the images above — not executed."
elif confirm "Remove the Docker images above?"; then
  docker rmi keyfactor/ejbca-ce:9.3.7 keyfactor/signserver-ce:7.3.2 ghcr.io/actions/actions-runner:2.336.0 python:3.12-slim \
    >/dev/null 2>&1 || true
  ok "Images removed (or already absent)."
else
  warn "Step 4 skipped (images kept)."
fi

# ---------------------------------------------------------------------------
# STEP 5 — Browser certificates (Chrome/NSS) — optional
# Removes only well-known individual nicknames from the user's NSS store
# (~/.pki/nssdb), which is where Chrome keeps personal certs on Linux.
# ---------------------------------------------------------------------------
echo
info "STEP 5/5 — Browser certificates (Chrome/NSS)"
NSSDB="sql:$HOME/.pki/nssdb"
NSS_NICKNAMES=("ManagementCA" "SuperAdmin" "Local Test CA")
if ! command -v certutil >/dev/null 2>&1; then
  info "certutil is not installed — cannot clean the NSS store automatically."
  info "Remove the entries manually in chrome://settings/certificates."
elif [[ ! -d "$HOME/.pki/nssdb" ]]; then
  info "No NSS database at $HOME/.pki/nssdb — nothing to remove from the browser store."
else
  certlist="$(certutil -d "$NSSDB" -L 2>/dev/null || true)"
  echo "  Certificates currently in the browser store:"
  printf '%s\n' "$certlist" | sed 's/^/    /'
  echo "  Well-known entries that would be removed (by exact nickname):"
  found=0
  for nick in "${NSS_NICKNAMES[@]}"; do
    if [[ "$certlist" == *"$nick"* ]]; then
      echo "    $nick"
      found=1
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "    (none of the known nicknames are present)"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "(dry run) Would remove the browser entries above — not executed."
  else
    for nick in "${NSS_NICKNAMES[@]}"; do
      if [[ "$certlist" == *"$nick"* ]]; then
        if confirm "Remove '$nick' from the browser store?"; then
          if certutil -d "$NSSDB" -D -n "$nick" >/dev/null 2>&1; then
            ok "'$nick' removed."
          else
            warn "Could not remove '$nick'."
          fi
        else
          warn "'$nick' kept."
        fi
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# Verify result
# ---------------------------------------------------------------------------
echo
info "Verifying result:"
docker compose ps 2>/dev/null || true
vols="$(docker volume ls 2>/dev/null || true)"
if [[ "$vols" == *'ch06-servers'* ]]; then
  warn "Some ch06-servers volumes are still present."
else
  ok "No ch06-servers volumes remain."
fi
if [[ -d "$KEYS_DIR" ]] && [[ -n "$(ls -A "$KEYS_DIR" 2>/dev/null || true)" ]]; then
  warn "keys/ still contains files."
else
  ok "keys/ has no files (directory kept)."
fi
[[ -e "$PROJECT_ROOT/.env" ]] && warn ".env still exists!" || ok ".env removed."
if command -v certutil >/dev/null 2>&1 && [[ -d "$HOME/.pki/nssdb" ]]; then
  nss_left="$(certutil -d "sql:$HOME/.pki/nssdb" -L 2>/dev/null || true)"
  if [[ "$nss_left" == *'ManagementCA'* ]]; then
    warn "ManagementCA is still in the browser store."
  else
    ok "ManagementCA is gone from the browser store (or was not present)."
  fi
fi

echo
ok "Uninstall finished."
info "To rebuild:  bash scripts/setup.sh"
info "Remember to also remove the runner in GitHub (Settings -> Actions -> Runners) and generate a fresh token."
