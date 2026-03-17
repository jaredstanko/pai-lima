#!/bin/bash
# PAI Lima — cmux launcher
# Opens cmux with a pre-configured workspace for the PAI VM.
#
# Usage:
#   ./launch.sh
#
# Prerequisites:
#   - cmux installed (brew install cmux)
#   - Lima VM "pai" created and started

set -euo pipefail

# Check prerequisites
if ! command -v cmux &>/dev/null; then
  echo "cmux not found. Install it: brew install cmux"
  echo "Or download from https://www.cmux.dev/"
  exit 1
fi

if ! command -v limactl &>/dev/null; then
  echo "Lima not found. Install it: brew install lima"
  exit 1
fi

# Start the VM if it's not running
VM_STATUS=$(limactl list --json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
if [ "$VM_STATUS" != "Running" ]; then
  echo "Starting PAI VM..."
  limactl start pai
fi

# Get VM IP for portal URL
VM_IP=$(limactl shell pai -- hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

# Launch cmux if not already running
open -a cmux 2>/dev/null || true
sleep 2

# Create the PAI workspace with Claude Code shell
cmux new-workspace --title "PAI"
sleep 0.5
cmux send "limactl shell pai\n"
sleep 1
cmux send "source ~/.bashrc 2>/dev/null; clear\n"
sleep 0.5
cmux send "echo '═══ PAI VM Ready ═══  Type: claude'\n"

# Split right — portal/monitoring pane
cmux new-split --direction right
sleep 0.5
cmux send "limactl shell pai\n"
sleep 1
cmux send "source ~/.bashrc 2>/dev/null; clear\n"
sleep 0.5
cmux send "echo '═══ Monitoring ═══  Portal: http://${VM_IP}:8080'\n"

echo ""
echo "PAI workspace ready in cmux."
echo "  Left pane:  Claude Code (type 'claude' to start)"
echo "  Right pane: Monitoring / extra terminal"
echo "  Portal:     http://${VM_IP}:8080"
