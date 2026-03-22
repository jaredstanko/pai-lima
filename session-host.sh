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

case "${1:-}" in
  --shell|-s)
    kitty --title "PAI Shell" limactl shell pai --workdir /home/claude
    ;;
  --resume|-r)
    kitty --title "Resume Session" limactl shell pai --workdir /home/claude -- bash -lc "claude -r"
    ;;
  *)
    kitty --title "PAI" limactl shell pai --workdir /home/claude -- bash -lc "bun ~/.claude/PAI/Tools/pai.ts"
    ;;
esac
