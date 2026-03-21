#!/bin/bash
# PAI Lima — spawn a new Claude Code session
# Creates a cmux workspace backed by a persistent tmux session in the VM,
# then automatically starts Claude Code.
#
# Usage:
#   ./session.sh <name>           # New session, auto-launch Claude Code
#   ./session.sh <name> --shell   # New session, drop to shell (no auto-claude)
#   ./session.sh --list           # List active tmux sessions in the VM
#
# Rerunning with the same name reattaches to the existing session.

set -euo pipefail

if [ "${1:-}" = "--list" ]; then
  echo "Active tmux sessions in PAI VM:"
  limactl shell pai -- tmux list-sessions 2>/dev/null || echo "  (none)"
  exit 0
fi

if [ $# -lt 1 ]; then
  echo "Usage: ./session.sh <session-name> [--shell]"
  echo "       ./session.sh --list"
  exit 1
fi

SESSION_NAME="$1"
SHELL_ONLY="${2:-}"

# Check prerequisites
if ! command -v cmux &>/dev/null; then
  echo "cmux not found. Install it: brew install cmux"
  exit 1
fi

# Ensure VM is running
VM_STATUS=$(limactl list --json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
if [ "$VM_STATUS" != "Running" ]; then
  echo "Starting PAI VM..."
  limactl start pai
fi

# Check if this tmux session already exists in the VM
SESSION_EXISTS=$(limactl shell pai -- tmux has-session -t "$SESSION_NAME" 2>/dev/null && echo "yes" || echo "no")

# Create cmux workspace with persistent tmux session
cmux new-workspace --command "limactl shell pai -- tmux new-session -As ${SESSION_NAME}"
sleep 0.5
cmux rename-workspace "$SESSION_NAME"

# Auto-launch Claude Code in new sessions (not reattaches, not --shell)
if [ "$SESSION_EXISTS" = "no" ] && [ "$SHELL_ONLY" != "--shell" ]; then
  sleep 1
  cmux send "claude\n"
fi

echo "Session '${SESSION_NAME}' ready."
[ "$SESSION_EXISTS" = "yes" ] && echo "  (reattached to existing session)"
