#!/bin/bash
# PAI Lima — spawn a new PAI session in kitty
#
# Usage:
#   ./session-host.sh              # New PAI session (Claude Code)
#   ./session-host.sh --shell      # Open a plain shell in the VM
#   ./session-host.sh --resume     # Resume a previous session (interactive picker)

set -euo pipefail

# Check prerequisites
if ! command -v kitty &>/dev/null; then
  echo "kitty not found. Install it: brew install --cask kitty"
  exit 1
fi

# Ensure VM is running
VM_STATUS=$(limactl list --json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
if [ "$VM_STATUS" != "Running" ]; then
  echo "Starting PAI VM..."
  limactl start pai
fi

KITTY_SOCKET="unix:/tmp/kitty"

# Try tab in existing Kitty, fall back to new window
open_kitty_tab() {
  local title="$1"
  shift
  if [ -S /tmp/kitty ] && kitty @ --to "$KITTY_SOCKET" launch --type=tab --title "$title" -- "$@" 2>/dev/null; then
    return
  fi
  kitty --title "$title" "$@"
}

case "${1:-}" in
  --shell|-s)
    open_kitty_tab "PAI Shell" limactl shell pai
    ;;
  --resume|-r)
    open_kitty_tab "Resume Session" limactl shell pai bash -lc "claude -r"
    ;;
  *)
    open_kitty_tab "PAI" limactl shell pai bash -lc "bun ~/.claude/PAI/Tools/pai.ts"
    ;;
esac
