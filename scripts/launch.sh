#!/bin/bash
# PAI Lima — launch PAI in a kitty terminal
# Opens a kitty window connected to the VM running PAI (Claude Code).
#
# Usage:
#   ./scripts/launch.sh                    # Open PAI session (default instance)
#   ./scripts/launch.sh --resume           # Resume a previous Claude Code session
#   ./scripts/launch.sh --shell            # Open a plain shell in the VM
#   ./scripts/launch.sh --name=v2          # Target a named instance
#   ./scripts/launch.sh --name=v2 --shell  # Shell into a named instance
#
# Prerequisites:
#   - kitty installed (brew install --cask kitty)
#   - Lima VM created and started (install.sh handles this)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared instance configuration
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Check prerequisites
if ! command -v kitty &>/dev/null; then
  echo "kitty not found. Run ./install.sh first, or: brew install --cask kitty"
  exit 1
fi

if ! command -v limactl &>/dev/null; then
  echo "Lima not found. Run ./install.sh first, or: brew install lima"
  exit 1
fi

# Start the VM if it's not running
VM_STATUS=$(pai_vm_status)
if [ "$VM_STATUS" != "Running" ]; then
  echo "Starting ${VM_NAME} VM..."
  limactl start "$VM_NAME"
fi

# Determine action from remaining args
ACTION=""
for arg in "${_PAI_REMAINING_ARGS[@]}"; do
  case "$arg" in
    --resume|-r) ACTION="resume" ;;
    --shell|-s) ACTION="shell" ;;
    *) ;;
  esac
done

TITLE_PREFIX="${INSTANCE_NAME}"

case "$ACTION" in
  resume)
    echo "Opening session picker..."
    pai_open_kitty_tab "${TITLE_PREFIX}: Resume" limactl shell "$VM_NAME" bash -lc "claude -r"
    ;;
  shell)
    echo "Opening shell..."
    pai_open_kitty_tab "${TITLE_PREFIX}: Shell" limactl shell "$VM_NAME"
    ;;
  *)
    echo "Launching PAI..."
    pai_open_kitty_tab "${TITLE_PREFIX}" limactl shell "$VM_NAME" bash -lc "bun ~/.claude/PAI/Tools/pai.ts"
    ;;
esac

echo ""
echo "Portal: http://localhost:${PORTAL_PORT}"
