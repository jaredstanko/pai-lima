#!/bin/bash
# PAI Lima — cmux launcher with persistent tmux sessions
# Opens cmux and restores all active workspaces from the VM.
# If no sessions exist, creates a default "pai" workspace.
#
# Usage:
#   ./launch.sh              # Restore all active sessions (or create default)
#   ./launch.sh work         # Launch specific named session(s)
#   ./launch.sh a b c        # Launch multiple named sessions
#
# Prerequisites:
#   - cmux installed (brew install --cask cmux)
#   - Lima VM "pai" created and started (setup-host.sh handles this)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check prerequisites
if ! command -v cmux &>/dev/null; then
  echo "cmux not found. Run ./setup-host.sh first, or: brew install --cask cmux"
  exit 1
fi

if ! command -v limactl &>/dev/null; then
  echo "Lima not found. Run ./setup-host.sh first, or: brew install lima"
  exit 1
fi

# Start the VM if it's not running
VM_STATUS=$(limactl list --json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
if [ "$VM_STATUS" != "Running" ]; then
  echo "Starting PAI VM..."
  limactl start pai
fi

# Launch cmux if not already running
open -a cmux 2>/dev/null || true
sleep 1

# Helper: create a cmux workspace with a persistent tmux session in the VM
create_session() {
  local name="$1"
  cmux new-workspace --command "limactl shell pai -- tmux new-session -As ${name}"
  sleep 0.5
  cmux rename-workspace "$name"
}

if [ $# -gt 0 ]; then
  # Named sessions mode: create a workspace for each argument
  for name in "$@"; do
    create_session "$name"
  done
  echo ""
  echo "Sessions launched: $*"
else
  # Auto-restore mode: query VM for all active tmux sessions
  SESSIONS=$(limactl shell pai -- tmux list-sessions -F '#{session_name}' 2>/dev/null || echo "")

  if [ -n "$SESSIONS" ]; then
    echo "Restoring active workspaces..."
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      echo "  → $name"
      create_session "$name"
    done <<< "$SESSIONS"
    echo ""
    echo "Restored $(echo "$SESSIONS" | grep -c .) workspace(s)."
  else
    # No active sessions — create default
    echo "No active sessions found. Creating default workspace..."
    create_session "pai"
    echo ""
    echo "Default 'pai' workspace created."
  fi
fi

echo ""
echo "Portal: http://localhost:8080"
echo "Sessions are persistent — rerun this script to reattach."
echo "Add more: ./session.sh <name>"
