#!/usr/bin/env bash
# 60 — Register the GitHub Actions self-hosted runner (human supplies the token).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

banner "Step 60 — Register the GitHub Actions self-hosted runner"

# ---------------------------------------------------------------------------
# Collect runner parameters from the operator (human-in-the-loop)
# ---------------------------------------------------------------------------
echo
echo "You need a runner registration token from GitHub:"
echo "  Repository -> Settings -> Actions -> Runners -> New self-hosted runner -> Linux"
echo
read -r -p "GitHub repository URL [https://github.com/OWNER/REPO]: " RUNNER_REPOSITORY_URL
RUNNER_REPOSITORY_URL="${RUNNER_REPOSITORY_URL:-https://github.com/OWNER/REPO}"
read -r -p "Runner name [github-runner]: " RUNNER_NAME
RUNNER_NAME="${RUNNER_NAME:-github-runner}"
read -r -p "Runner labels (comma-separated) [self-hosted,linux,local]: " RUNNER_LABELS
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,local}"
read -r -p "Registration token (paste from GitHub): " RUNNER_TOKEN
if [[ -z "${RUNNER_TOKEN:-}" ]]; then
  fail "A registration token is required. Generate one on GitHub and re-run this step."
fi

# ---------------------------------------------------------------------------
# Write .env (compose reads it for RUNNER_* interpolation)
# ---------------------------------------------------------------------------
cat > "$PROJECT_ROOT/.env" <<EOF
RUNNER_REPOSITORY_URL=$RUNNER_REPOSITORY_URL
RUNNER_NAME=$RUNNER_NAME
RUNNER_LABELS=$RUNNER_LABELS
RUNNER_TOKEN=$RUNNER_TOKEN
EOF
chmod 600 "$PROJECT_ROOT/.env"
ok ".env written (RUNNER_REPOSITORY_URL, RUNNER_NAME, RUNNER_LABELS, RUNNER_TOKEN)."

# ---------------------------------------------------------------------------
# Start the runner and wait for it to register
# ---------------------------------------------------------------------------
cd "$PROJECT_ROOT"
info "Starting the runner container..."
docker compose up -d runner

if wait_for_log github-runner "Listening for Jobs" "runner registration" 180; then
  ok "Runner is registered and listening for jobs."
else
  echo
  docker logs github-runner 2>&1 | tail -25
  fail "Runner did not reach 'Listening for Jobs'. Check the token/URL, then re-run this step."
fi

checkpoint "Runner registered. Next: verify the full chain end-to-end (step 70)."
