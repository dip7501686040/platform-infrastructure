#!/usr/bin/env bash
# Manual entry point for the GitHub Actions self-hosted runner -- run this
# yourself after login/reboot when you want the runner (and therefore
# infra-apply) available. Deliberately NOT a LaunchAgent/LaunchDaemon: no
# auto-start on login, on purpose (your call every time, not a background
# service that starts itself).
#
# Usage: scripts/start-runner.sh [--apply]
#   --apply   also dispatch one infra-apply workflow run once the runner
#             comes online, so a single command gets you from cold start to
#             a fully reconciled cluster.
set -e

RUNNER_DIR="$HOME/actions-runner"

if [ ! -x "$RUNNER_DIR/run.sh" ]; then
  echo "No runner found at $RUNNER_DIR -- see platform-infrastructure's Phase 4 setup." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker not responding -- starting Docker Desktop..."
  open -a Docker
  echo "waiting for Docker to be ready..."
  for i in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 5
  done
fi

if pgrep -f "$RUNNER_DIR/bin/Runner.Listener" >/dev/null 2>&1; then
  echo "Runner is already running."
else
  echo "Starting the runner in the background (logs: $RUNNER_DIR/_diag/)..."
  cd "$RUNNER_DIR"
  nohup ./run.sh >/tmp/actions-runner.log 2>&1 &
  disown

  echo "waiting for the runner to register as online with GitHub..."
  for i in $(seq 1 30); do
    STATUS=$(gh api repos/dip7501686040/platform-infrastructure/actions/runners --jq '.runners[0].status' 2>/dev/null || echo "")
    [ "$STATUS" = "online" ] && break
    sleep 2
  done
  echo "Runner status: ${STATUS:-unknown}"
fi

if [ "$1" = "--apply" ]; then
  echo "Dispatching infra-apply..."
  gh workflow run infra-apply.yml --repo dip7501686040/platform-infrastructure
  echo "Triggered -- watch progress: gh run watch --repo dip7501686040/platform-infrastructure"
fi
