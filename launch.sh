#!/bin/bash
# PAI Lima — launch PAI in a kitty terminal
# Opens a kitty window connected to the VM running PAI (Claude Code).
#
# Usage:
#   ./launch.sh              # Open PAI session
#   ./launch.sh --resume     # Resume a previous Claude Code session
#   ./launch.sh --shell      # Open a plain shell in the VM
#
# Prerequisites:
#   - kitty installed (brew install --cask kitty)
#   - Lima VM "pai" created and started (setup-host.sh handles this)

set -euo pipefail

# Check prerequisites
if ! command -v kitty &>/dev/null; then
  echo "kitty not found. Run ./setup-host.sh first, or: brew install --cask kitty"
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

case "${1:-}" in
  --resume|-r)
    echo "Opening session picker..."
    kitty --title "Resume Session" limactl shell pai -- bash -lc "claude -r"
    ;;
  --shell|-s)
    echo "Opening shell..."
    kitty --title "PAI Shell" limactl shell pai
    ;;
  *)
    echo "Launching PAI..."
    kitty --title "PAI" limactl shell pai -- bash -lc "bun ~/.claude/PAI/Tools/pai.ts"
    ;;
esac

echo ""
echo "Portal: http://localhost:8080"
