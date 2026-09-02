#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      echo "Usage: $0 [--pull] [--no-migrate]"
      echo "  Restarts stack via stop.sh + start.sh"
      echo "  Args are forwarded to start.sh"
      exit 0
      ;;
  esac
done

log "==> Restarting digihome stack..."
"$SCRIPT_DIR/stop.sh"
"$SCRIPT_DIR/start.sh" "$@"
log "==> Restart done"
