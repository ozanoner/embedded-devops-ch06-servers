#!/usr/bin/env bash
# Master orchestrator — runs the numbered setup steps with human-in-the-loop gates.
#
#   bash scripts/setup.sh                 # run every core step in order
#   bash scripts/setup.sh 30 40           # run only the listed steps
#   bash scripts/setup.sh 80-browser-trust
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CORE_STEPS=(00-check-prereqs 10-start-stack 20-ejbca-superadmin 30-issue-certs \
            35-issue-enroll-certs 40-wire-signserver 50-configure-worker \
            60-register-runner 70-verify-e2e)

usage() {
  cat <<'EOF'
Usage: setup.sh [step ...]
  Runs setup steps in order (each pauses at checkpoints for human confirmation).

  Without arguments, runs all core steps:
    00-check-prereqs   10-start-stack    20-ejbca-superadmin  30-issue-certs
    35-issue-enroll-certs                40-wire-signserver  50-configure-worker
    60-register-runner 70-verify-e2e
  80-browser-trust     (optional, last)

  Examples:
    bash scripts/setup.sh                # full run
    bash scripts/setup.sh 30 40          # run only steps 30 and 40
    bash scripts/setup.sh 80-browser-trust
EOF
}

run_step() {
  local file="$SCRIPT_DIR/$1.sh"
  if [[ ! -f "$file" ]]; then
    # Allow short/partial names: "30" matches "30-issue-certs.sh"
    local match
    match="$(ls "$SCRIPT_DIR"/"$1"*.sh 2>/dev/null | head -n 1 || true)"
    if [[ -n "$match" ]]; then
      file="$match"
    fi
  fi
  if [[ ! -f "$file" ]]; then
    echo "No such step: $1" >&2
    return 1
  fi
  if [[ ! -x "$file" ]]; then
    chmod +x "$file"
  fi
  echo
  echo ">>> Running $(basename "$file")"
  "$file"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$#" -gt 0 ]]; then
  for s in "$@"; do
    run_step "$s" || exit 1
  done
else
  for s in "${CORE_STEPS[@]}"; do
    run_step "$s" || exit 1
  done
  echo
  echo "${C_GREEN:-}All core steps completed.${C_NC:-}"
  echo "Optionally finish with browser trust:  bash scripts/setup.sh 80-browser-trust"
fi
