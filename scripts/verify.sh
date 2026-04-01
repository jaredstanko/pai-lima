#!/bin/bash
# PAI Lima — End-State Verification
# Checks that the full system matches the expected state from versions.env.
# Uses 3-state model: PINNED (exact match), DRIFTED (acceptable), FAILED (blocking).
#
# Can be run standalone or called by install.sh at the end of install.
#
# Usage:
#   ./verify.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Colors ───────────────────────────────────────────────────

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
DRIFT=0
FAIL=0

# ─── Load version manifest ───────────────────────────────────

VERSIONS_FILE="$SCRIPT_DIR/versions.env"
if [ ! -f "$VERSIONS_FILE" ]; then
  echo -e "${RED}✗${NC} versions.env not found in $SCRIPT_DIR"
  exit 1
fi
source "$VERSIONS_FILE"

# ─── Helpers ─────────────────────────────────────────────────

pinned() {
  local label="$1"
  local detail="${2:-}"
  if [ -n "$detail" ]; then
    printf "  ${GREEN}%-8s${NC} %-40s %s\n" "PINNED" "$label" "$detail"
  else
    printf "  ${GREEN}%-8s${NC} %s\n" "PINNED" "$label"
  fi
  PASS=$((PASS + 1))
}

drifted() {
  local label="$1"
  local detail="${2:-}"
  if [ -n "$detail" ]; then
    printf "  ${YELLOW}%-8s${NC} %-40s %s\n" "DRIFTED" "$label" "$detail"
  else
    printf "  ${YELLOW}%-8s${NC} %s\n" "DRIFTED" "$label"
  fi
  DRIFT=$((DRIFT + 1))
}

failed() {
  local label="$1"
  local detail="${2:-}"
  if [ -n "$detail" ]; then
    printf "  ${RED}%-8s${NC} %-40s %s\n" "FAILED" "$label" "$detail"
  else
    printf "  ${RED}%-8s${NC} %s\n" "FAILED" "$label"
  fi
  FAIL=$((FAIL + 1))
}

check_version() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [ -z "$actual" ] || [ "$actual" = "MISSING" ]; then
    failed "$label" "(not installed)"
  elif [ "$actual" = "$expected" ]; then
    pinned "$label" "($actual)"
  else
    drifted "$label" "(expected: $expected, got: $actual)"
  fi
}

check_exists() {
  local label="$1"
  local path="$2"

  if [ -e "$path" ]; then
    pinned "$label"
  else
    failed "$label" "(not found: $path)"
  fi
}

check_command() {
  local label="$1"
  local cmd="$2"

  if command -v "$cmd" &>/dev/null; then
    pinned "$label"
  else
    failed "$label" "($cmd not in PATH)"
  fi
}

# ─── Banner ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  PAI Lima — System Verification${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  Checking against versions.env manifest..."
echo ""

# ═══════════════════════════════════════════════════════════════
# HOST CHECKS (run on macOS)
# ═══════════════════════════════════════════════════════════════

echo -e "${BOLD}  Host (macOS)${NC}"
echo -e "  ──────────────────────────────────────────────"

# macOS
if [[ "$(uname)" = "Darwin" ]]; then
  pinned "macOS" "($(sw_vers -productVersion))"
else
  failed "macOS" "(not macOS)"
fi

# Apple Silicon
if [[ "$(uname -m)" = "arm64" ]]; then
  pinned "Apple Silicon"
else
  failed "Apple Silicon" "($(uname -m))"
fi

# Homebrew
check_command "Homebrew" "brew"

# Lima
if command -v limactl &>/dev/null; then
  LIMA_VER=$(limactl --version 2>/dev/null | grep -oE '[0-9.]+' | head -1 || echo "unknown")
  pinned "Lima" "($LIMA_VER)"
else
  failed "Lima" "(limactl not found)"
fi

# kitty
if [ -d "/Applications/kitty.app" ] || command -v kitty &>/dev/null; then
  pinned "kitty terminal"
else
  failed "kitty terminal"
fi

# PAI-Status.app
check_exists "PAI-Status.app" "/Applications/PAI-Status.app"

# kitty config
check_exists "kitty.conf" "$HOME/.config/kitty/kitty.conf"

# Workspace directories
WORKSPACE="$HOME/pai-workspace"
WORKSPACE_OK=true
for dir in claude-home data exchange portal work upstream; do
  if [ ! -d "$WORKSPACE/$dir" ]; then
    WORKSPACE_OK=false
    failed "Workspace: $dir" "(not found: $WORKSPACE/$dir)"
  fi
done
if [ "$WORKSPACE_OK" = true ]; then
  pinned "Workspace directories (6/6)"
fi

# ═══════════════════════════════════════════════════════════════
# VM CHECKS (run inside Lima VM)
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}  VM (Lima)${NC}"
echo -e "  ──────────────────────────────────────────────"

# Check VM exists and is running
VM_JSON=$(limactl list --json 2>/dev/null || echo "")
if ! echo "$VM_JSON" | grep -q '"name":"pai"'; then
  failed "Lima VM 'pai'" "(does not exist)"
  echo ""
  echo -e "  ${RED}Cannot check VM internals — VM does not exist.${NC}"
else
  VM_STATUS=$(echo "$VM_JSON" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
  if [ "$VM_STATUS" = "Running" ]; then
    pinned "Lima VM 'pai'" "(running)"
  else
    drifted "Lima VM 'pai'" "(status: $VM_STATUS, expected: Running)"
  fi

  if [ "$VM_STATUS" = "Running" ]; then
    # Batch all VM checks into a single SSH session for speed
    VM_CHECK_SCRIPT='
      echo "BUN_VER=$(bun --version 2>/dev/null || echo MISSING)"
      echo "CLAUDE_VER=$(claude --version 2>/dev/null | grep -oE "[0-9.]+" | head -1 || echo MISSING)"
      echo "NODE_VER=$(node --version 2>/dev/null || echo MISSING)"
      echo "PAI_DIR=$(test -d /home/claude/.claude/PAI && echo YES || echo NO)"
      echo "PAI_LINK=$(test -L /home/claude/.claude/skills/PAI && echo YES || echo NO)"
      echo "BASHRC_ENV=$(grep -cF "# --- PAI environment" /home/claude/.bashrc 2>/dev/null || echo 0)"
      echo "ZSHRC_ENV=$(grep -cF "# --- PAI environment" /home/claude/.zshrc 2>/dev/null || echo 0)"
      echo "COMPANION=$(test -d /home/claude/pai-companion/companion && echo YES || echo NO)"
      echo "PW_VER=$(bunx playwright --version 2>/dev/null || echo MISSING)"
      for m in .claude data exchange portal work upstream; do
        test -d "/home/claude/$m" && echo "MOUNT_${m}=YES" || echo "MOUNT_${m}=NO"
      done
    '
    VM_RESULTS=$(limactl shell pai bash -lc "$VM_CHECK_SCRIPT" 2>/dev/null || echo "")

    # Parse results
    get_val() { echo "$VM_RESULTS" | grep "^$1=" | cut -d= -f2- | tr -d '[:space:]'; }

    ACTUAL_BUN=$(get_val BUN_VER)
    check_version "Bun" "$BUN_VERSION" "$ACTUAL_BUN"

    ACTUAL_CLAUDE=$(get_val CLAUDE_VER)
    check_version "Claude Code" "$CLAUDE_CODE_VERSION" "$ACTUAL_CLAUDE"

    ACTUAL_NODE=$(get_val NODE_VER)
    if [ -n "$ACTUAL_NODE" ] && [ "$ACTUAL_NODE" != "MISSING" ]; then
      pinned "Node.js" "($ACTUAL_NODE)"
    else
      failed "Node.js"
    fi

    [ "$(get_val PAI_DIR)" = "YES" ] && pinned "PAI directory" || failed "PAI directory"
    [ "$(get_val PAI_LINK)" = "YES" ] && pinned "PAI skill symlink" || failed "PAI skill symlink"

    # Mount accessibility
    MOUNTS_OK=true
    for mount in .claude data exchange portal work upstream; do
      MOUNT_KEY="MOUNT_${mount}"
      if [ "$(get_val "$MOUNT_KEY")" != "YES" ]; then
        MOUNTS_OK=false
        failed "VM mount: $mount"
      fi
    done
    if [ "$MOUNTS_OK" = true ]; then
      pinned "VM mounts accessible (6/6)"
    fi

    [ "$(get_val BASHRC_ENV)" != "0" ] && pinned ".bashrc PAI environment block" || failed ".bashrc PAI environment block"
    [ "$(get_val ZSHRC_ENV)" != "0" ] && pinned ".zshrc PAI environment block" || failed ".zshrc PAI environment block"
    [ "$(get_val COMPANION)" = "YES" ] && pinned "PAI Companion repo" || failed "PAI Companion repo"

    ACTUAL_PW=$(get_val PW_VER)
    if [ -n "$ACTUAL_PW" ] && [ "$ACTUAL_PW" != "MISSING" ]; then
      check_version "Playwright" "$PLAYWRIGHT_VERSION" "$ACTUAL_PW"
    else
      drifted "Playwright" "(could not verify version)"
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "  ──────────────────────────────────────────────"
TOTAL=$((PASS + DRIFT + FAIL))
echo -e "  ${GREEN}${PASS} PINNED${NC}  ${YELLOW}${DRIFT} DRIFTED${NC}  ${RED}${FAIL} FAILED${NC}  (${TOTAL} checks)"
echo ""

if [ $FAIL -gt 0 ]; then
  echo -e "  ${RED}Some checks failed.${NC} Review output above for details."
  echo -e "  Re-run ${BOLD}./install.sh${NC} to fix, or check ${BOLD}~/.pai-install.log${NC}"
  exit 1
elif [ $DRIFT -gt 0 ]; then
  echo -e "  ${YELLOW}Some versions drifted${NC} (likely Claude Code auto-update). Non-blocking."
  exit 0
else
  echo -e "  ${GREEN}All checks passed. System is deterministic.${NC}"
  exit 0
fi
