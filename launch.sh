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

# Track whether cmux was already running (to handle default workspace)
CMUX_WAS_RUNNING=false
if pgrep -x cmux &>/dev/null; then
  CMUX_WAS_RUNNING=true
fi

# Launch cmux if not already running
open -a cmux 2>/dev/null || true
sleep 1

# Helper: create a cmux workspace with a persistent tmux session in the VM
create_session() {
  local name="$1"
  local with_pai="${2:-false}"
  local cmd="limactl shell pai -- tmux new-session -As ${name}"
  if [ "$with_pai" = "true" ]; then
    cmd="limactl shell pai -- tmux new-session -As ${name} \\; send-keys 'bun /home/claude/.claude/PAI/Tools/pai.ts' Enter"
  fi
  cmux new-workspace --command "$cmd"
  sleep 0.5
  cmux rename-workspace "$name"
}

# Helper: replace cmux's default workspace (avoids extra host-shell tab on fresh launch)
replace_default_workspace() {
  local name="$1"
  local with_pai="${2:-false}"
  local cmd="limactl shell pai -- tmux new-session -As ${name}"
  if [ "$with_pai" = "true" ]; then
    cmd="limactl shell pai -- tmux new-session -As ${name} \\; send-keys 'bun /home/claude/.claude/PAI/Tools/pai.ts' Enter"
  fi
  cmux send --workspace workspace:1 "${cmd}\n"
  sleep 0.5
  cmux rename-workspace --workspace workspace:1 "$name"
}

if [ $# -gt 0 ]; then
  # Named sessions mode: create a workspace for each argument
  FIRST=true
  for name in "$@"; do
    if [ "$FIRST" = true ] && [ "$CMUX_WAS_RUNNING" = false ]; then
      replace_default_workspace "$name" true
      FIRST=false
    else
      create_session "$name" true
    fi
  done
  echo ""
  echo "Sessions launched: $*"
else
  # Auto-restore mode: query VM for all active tmux sessions
  SESSIONS=$(limactl shell pai -- tmux list-sessions -F '#{session_name}' 2>/dev/null || echo "")

  if [ -n "$SESSIONS" ]; then
    echo "Restoring active workspaces..."
    FIRST=true
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      echo "  → $name"
      if [ "$FIRST" = true ] && [ "$CMUX_WAS_RUNNING" = false ]; then
        replace_default_workspace "$name"
        FIRST=false
      else
        create_session "$name"
      fi
    done <<< "$SESSIONS"
    echo ""
    echo "Restored $(echo "$SESSIONS" | grep -c .) workspace(s)."
  else
    # No active sessions — create default with PAI auto-started
    echo "No active sessions found. Creating default workspace..."
    if [ "$CMUX_WAS_RUNNING" = false ]; then
      replace_default_workspace "pai" true
    else
      create_session "pai" true
    fi
    echo ""
    echo "Default 'pai' workspace created."
  fi
fi

echo ""
echo "Portal: http://localhost:8080"
echo "Sessions are persistent — rerun this script to reattach."
echo "Add more: ./session.sh <name>"
