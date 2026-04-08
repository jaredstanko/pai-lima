#!/bin/bash
# PAI Lima -- Mount a host directory into the VM
# Adds a permanent shared folder so the AI can access files on your Mac.
#
# Usage:
#   ./scripts/mount.sh ~/Projects/my-repo                    # Mount as /home/claude/my-repo
#   ./scripts/mount.sh ~/Projects/my-repo /home/claude/code  # Mount at a specific VM path
#   ./scripts/mount.sh --list                                # Show current mounts
#   ./scripts/mount.sh --name=v2 ~/Projects/my-repo          # Target a named instance
#
# This requires stopping and restarting the VM (takes ~10 seconds).
# Your sessions and data are preserved.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared instance configuration
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⊘${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; exit 1; }

usage() {
  echo "Usage: $(basename "$0") [--name=X] <host-path> [vm-path]"
  echo ""
  echo "  host-path    Directory on your Mac to share (must exist)"
  echo "  vm-path      Where it appears in the VM (default: /home/claude/<dirname>)"
  echo ""
  echo "Options:"
  echo "  --list       Show currently mounted directories"
  echo "  --name=X     Target a named instance (default: pai)"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0") ~/Projects/my-repo"
  echo "  $(basename "$0") ~/Projects/my-repo /home/claude/code"
  echo "  $(basename "$0") --list"
  exit 1
}

# Parse positional args from remaining (--name already consumed by common.sh)
HOST_PATH=""
VM_PATH=""
LIST_MODE=false

for arg in ${_PAI_REMAINING_ARGS[@]+"${_PAI_REMAINING_ARGS[@]}"}; do
  case "$arg" in
    --list) LIST_MODE=true ;;
    -*) ;; # skip unknown flags
    *)
      if [ -z "$HOST_PATH" ]; then
        HOST_PATH="$arg"
      elif [ -z "$VM_PATH" ]; then
        VM_PATH="$arg"
      fi
      ;;
  esac
done

# List mode
if [ "$LIST_MODE" = true ]; then
  LIMA_CONFIG="$HOME/.lima/${VM_NAME}/lima.yaml"
  if [ ! -f "$LIMA_CONFIG" ]; then
    fail "VM '${VM_NAME}' not found. Run ./install.sh first."
  fi
  echo ""
  echo -e "${BOLD}Shared folders for ${VM_NAME}:${NC}"
  echo ""
  # Extract mount locations and mount points from lima.yaml
  grep -A1 "location:" "$LIMA_CONFIG" | grep -E "location:|mountPoint:" | while IFS= read -r line; do
    if echo "$line" | grep -q "location:"; then
      LOC=$(echo "$line" | sed 's/.*location: *"\{0,1\}//;s/"\{0,1\} *$//')
      read -r next_line
      MP=$(echo "$next_line" | sed 's/.*mountPoint: *"\{0,1\}//;s/"\{0,1\} *$//')
      printf "  %-40s → %s\n" "$LOC" "$MP"
    fi
  done || true
  echo ""
  exit 0
fi

# Validate args
if [ -z "$HOST_PATH" ]; then
  usage
fi

# Resolve to absolute path
HOST_PATH=$(cd "$HOST_PATH" 2>/dev/null && pwd) || fail "Directory not found: $HOST_PATH"

# Default VM path: /home/claude/<dirname>
if [ -z "$VM_PATH" ]; then
  DIRNAME=$(basename "$HOST_PATH")
  VM_PATH="/home/claude/${DIRNAME}"
fi

# Check VM exists
LIMA_CONFIG="$HOME/.lima/${VM_NAME}/lima.yaml"
if [ ! -f "$LIMA_CONFIG" ]; then
  fail "VM '${VM_NAME}' not found. Run ./install.sh first."
fi

# Check if already mounted
if grep -q "\"${HOST_PATH}\"\\|\"${HOST_PATH/#$HOME/\~}\"" "$LIMA_CONFIG" 2>/dev/null; then
  warn "Already mounted: $HOST_PATH"
  exit 0
fi

# Convert to ~ notation for lima.yaml
HOST_TILDE="${HOST_PATH/#$HOME/\~}"

echo ""
echo -e "${BOLD}Mounting directory into ${VM_NAME}:${NC}"
echo ""
echo "  Host:  $HOST_PATH"
echo "  VM:    $VM_PATH"
echo ""

# Stop VM if running
VM_STATUS=$(pai_vm_status)
WAS_RUNNING=false
if [ "$VM_STATUS" = "Running" ]; then
  WAS_RUNNING=true
  echo -e "  Stopping VM..."
  limactl stop "$VM_NAME"
  ok "VM stopped"
fi

# Add the mount to lima.yaml using limactl edit
# Lima's --set flag uses yq-style expressions
limactl edit "$VM_NAME" --set ".mounts += [{\"location\": \"${HOST_TILDE}\", \"mountPoint\": \"${VM_PATH}\", \"writable\": true}]"
ok "Mount added to VM config"

# Restart VM
echo "  Starting VM..."
limactl start "$VM_NAME"
ok "VM started"

echo ""
echo -e "${GREEN}Done!${NC} Your directory is now available in the VM at:"
echo ""
echo "  ${VM_PATH}"
echo ""
echo "  Any changes you make on your Mac are instantly visible in the VM,"
echo "  and vice versa."
echo ""
