#!/usr/bin/env bash
# Shared helpers for the SignServer / EJBCA / GitHub-runner setup scripts.
# Source this from any step script:  source "$(dirname "$0")/lib/common.sh"
set -euo pipefail

# NOTE: this file lives in scripts/lib/, so compute paths from its own location.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$LIB_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEYS_DIR="$PROJECT_ROOT/keys"

# Configurable values (override via environment if needed)
P12_PASS="${P12_PASS:-changeit}"
EJBCA_CLI_USER="${EJBCA_CLI_USER:-ejbca}"
EJBCA_CLI_PASS="${EJBCA_CLI_PASS:-ejbca}"
MANAGEMENT_CA="${MANAGEMENT_CA:-ManagementCA}"

# Colored output (disabled when stdout is not a terminal)
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'; C_NC=$'\e[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_NC=''
fi

info()   { echo "${C_BLUE}[INFO]${C_NC}  $*"; }
ok()     { echo "${C_GREEN}[ OK ]${C_NC}  $*"; }
warn()   { echo "${C_YELLOW}[WARN]${C_NC}  $*"; }
fail()   { echo "${C_RED}[FAIL]${C_NC}  $*" >&2; exit 1; }
banner() {
  echo
  echo "${C_BOLD}════════════════════════════════════════════════════════════════════${C_NC}"
  echo "${C_BOLD}  $*${C_NC}"
  echo "════════════════════════════════════════════════════════════════════"
}

# require_cmd <name> — fail with guidance if a CLI tool is missing
require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    fail "Required command '$name' not found in PATH. Install it and re-run (Debian/Ubuntu: sudo apt install $name)."
  fi
}

# confirm "<question>" — returns 0 on y/yes, 1 otherwise
confirm() {
  local q="$1" ans
  printf "%s [y/N] " "$q"
  read -r ans
  [[ "$ans" =~ ^[Yy](es)?$ ]]
}

# checkpoint "<message>" — human-in-the-loop gate; waits for Enter
checkpoint() {
  local msg="$1"
  echo
  echo "${C_YELLOW}────────────────────────────────────────────────────────────────${C_NC}"
  echo "${C_YELLOW}  CHECKPOINT${C_NC}"
  echo "${C_YELLOW}  $msg${C_NC}"
  echo "${C_YELLOW}────────────────────────────────────────────────────────────────${C_NC}"
  read -r -p "  Press Enter to continue, or Ctrl-C to abort... " _
  echo
}

# Container CLI wrappers
ejbca_cli()     { docker exec ejbca /opt/keyfactor/bin/ejbca.sh "$@"; }
signserver_cli() { docker exec signserver /opt/keyfactor/signserver/bin/signserver "$@"; }

# ra_setclearpwd <user> <pwd> — set a cleartext password (tries both spellings)
ra_setclearpwd() {
  local user="$1" pwd="$2"
  ejbca_cli ra setclearpwd "$user" "$pwd" -u "$EJBCA_CLI_USER" --clipassword "$EJBCA_CLI_PASS" >/dev/null 2>&1 \
    || ejbca_cli ra setclearpassword "$user" "$pwd" -u "$EJBCA_CLI_USER" --clipassword "$EJBCA_CLI_PASS" >/dev/null 2>&1 \
    || return 1
}

# wait_for_http <url> <label> <timeout_seconds>
wait_for_http() {
  local url="$1" label="$2" timeout="${3:-180}" i code=""
  info "Waiting for $label to become reachable (up to ${timeout}s)..."
  for i in $(seq 1 "$timeout"); do
    code="$(curl -k -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      ok "$label is up (HTTP 200)."
      return 0
    fi
    sleep 1
  done
  fail "$label did not become ready within ${timeout}s (last HTTP '$code'). Check 'docker compose logs'."
}

# wait_for_log <container> <pattern> <label> <timeout_seconds>
# Capture logs to a variable and match with bash pattern matching (no pipe):
# 'grep -q' closes the pipe as soon as it matches, which SIGPIPEs the producer
# (e.g. 'docker logs' / 'echo' on large output) -> exit 141 -> pipefail reports
# a false failure. `[[ $log == *$pattern* ]]` avoids pipes entirely.
wait_for_log() {
  local container="$1" pattern="$2" label="$3" timeout="${4:-120}" i log
  info "Waiting for '$label' in container '$container' (up to ${timeout}s)..."
  for i in $(seq 1 "$timeout"); do
    log="$(docker logs "$container" 2>&1 || true)"
    if [[ "$log" == *"$pattern"* ]]; then
      ok "'$label' detected."
      return 0
    fi
    sleep 2
  done
  warn "Timed out waiting for '$label' in '$container'."
  return 1
}

# is_pem_cert <file> — true if the file starts with a PEM certificate marker
is_pem_cert() {
  local l
  l="$(head -1 "$1" 2>/dev/null)"
  [[ "$l" == *'-----BEGIN CERTIFICATE-----'* ]]
}

# port_in_use <port> — true if something is listening on the port (host)
port_in_use() {
  local port="$1" addrs
  if command -v ss >/dev/null 2>&1; then
    addrs="$(ss -tln 2>/dev/null | awk '{print $4}' || true)"
  elif command -v netstat >/dev/null 2>&1; then
    addrs="$(netstat -tln 2>/dev/null | awk '{print $4}' || true)"
  else
    return 1
  fi
  [[ "$addrs" == *":$port"* ]]
}
