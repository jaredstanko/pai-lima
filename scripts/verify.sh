#!/bin/bash
# PAI Lima -- End-State Verification
# Checks that the full system is installed and functional.
# Uses 2-state model: PASS (present and working), FAIL (missing or broken).
#
# Can be run standalone or called by install.sh at the end of install.
#
# Usage:
#   ./verify.sh                  # Verify default instance
#   ./verify.sh --name=v2        # Verify named instance

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared instance configuration
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ─── Colors ───────────────────────────────────────────────────

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

# ─── Helpers ─────────────────────────────────────────────────

passed() {
  local label="$1"
  local detail="${2:-}"
  if [ -n "$detail" ]; then
    printf "  ${GREEN}%-8s${NC} %-40s %s\n" "PASS" "$label" "$detail"
  else
    printf "  ${GREEN}%-8s${NC} %s\n" "PASS" "$label"
  fi
  PASS=$((PASS + 1))
}

failed() {
  local label="$1"
  local detail="${2:-}"
  if [ -n "$detail" ]; then
    printf "  ${RED}%-8s${NC} %-40s %s\n" "FAIL" "$label" "$detail"
  else
    printf "  ${RED}%-8s${NC} %s\n" "FAIL" "$label"
  fi
  FAIL=$((FAIL + 1))
}

check_exists() {
  local label="$1"
  local path="$2"

  if [ -e "$path" ]; then
    passed "$label"
  else
    failed "$label" "(not found: $path)"
  fi
}

check_command() {
  local label="$1"
  local cmd="$2"

  if command -v "$cmd" &>/dev/null; then
    passed "$label"
  else
    failed "$label" "($cmd not in PATH)"
  fi
}

check_installed() {
  local label="$1"
  local actual="$2"

  if [ -n "$actual" ] && [ "$actual" != "MISSING" ]; then
    passed "$label" "($actual)"
  else
    failed "$label"
  fi
}

# ─── Banner ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  PAI Lima -- System Verification${NC}"
if [ -n "$INSTANCE_SUFFIX" ]; then
  echo -e "${BOLD}  Instance: ${CYAN}${INSTANCE_NAME}${NC}"
fi
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# HOST CHECKS (run on macOS)
# ═══════════════════════════════════════════════════════════════

echo -e "${BOLD}  Host (macOS)${NC}"
echo -e "  ──────────────────────────────────────────────"

# macOS
if [[ "$(uname)" = "Darwin" ]]; then
  passed "macOS" "($(sw_vers -productVersion))"
else
  failed "macOS" "(not macOS)"
fi

# Apple Silicon
if [[ "$(uname -m)" = "arm64" ]]; then
  passed "Apple Silicon"
else
  failed "Apple Silicon" "($(uname -m))"
fi

# Homebrew
check_command "Homebrew" "brew"

# Lima
if command -v limactl &>/dev/null; then
  LIMA_VER=$(limactl --version 2>/dev/null | grep -oE '[0-9.]+' | head -1 || echo "unknown")
  passed "Lima" "($LIMA_VER)"
else
  failed "Lima" "(limactl not found)"
fi

# kitty
if [ -d "/Applications/kitty.app" ] || command -v kitty &>/dev/null; then
  passed "kitty terminal"
else
  failed "kitty terminal"
fi

# PAI-Status app (instance-specific)
check_exists "${APP_NAME}.app" "/Applications/${APP_BUNDLE}"

# kitty config
check_exists "kitty.conf" "$HOME/.config/kitty/kitty.conf"

# Workspace directories (instance-specific)
WORKSPACE_OK=true
for dir in claude-home data exchange portal work upstream; do
  if [ ! -d "$WORKSPACE/$dir" ]; then
    WORKSPACE_OK=false
    failed "Workspace: $dir" "(not found: $WORKSPACE/$dir)"
  fi
done
if [ "$WORKSPACE_OK" = true ]; then
  passed "Workspace directories (6/6)" "($WORKSPACE/)"
fi

# ═══════════════════════════════════════════════════════════════
# VM CHECKS (run inside Lima VM)
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}  VM (Lima: ${VM_NAME})${NC}"
echo -e "  ──────────────────────────────────────────────"

# Check VM exists and is running
VM_STATUS=$(pai_vm_status)
if [ -z "$VM_STATUS" ]; then
  failed "Lima VM '${VM_NAME}'" "(does not exist)"
  echo ""
  echo -e "  ${RED}Cannot check VM internals -- VM does not exist.${NC}"
else
  if [ "$VM_STATUS" = "Running" ]; then
    passed "Lima VM '${VM_NAME}'" "(running)"
  else
    failed "Lima VM '${VM_NAME}'" "(status: $VM_STATUS, expected: Running)"
  fi

  if [ "$VM_STATUS" = "Running" ]; then
    # Batch all VM checks into a single SSH session for speed
    VM_CHECK_SCRIPT='
      echo "BUN_VER=$(command -v bun >/dev/null 2>&1 && bun --version 2>/dev/null || echo MISSING)"
      echo "CLAUDE_VER=$(command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null | grep -oE "[0-9.]+" | head -1 || echo MISSING)"
      echo "NODE_VER=$(command -v node >/dev/null 2>&1 && node --version 2>/dev/null || echo MISSING)"
      echo "PAI_DIR=$(test -d /home/claude/.claude/PAI && echo YES || echo NO)"
      echo "PAI_LINK=$(test -L /home/claude/.claude/skills/PAI && echo YES || echo NO)"
      echo "BASHRC_ENV=$(grep -cF "# --- PAI environment" /home/claude/.bashrc 2>/dev/null || echo 0)"
      echo "ZSHRC_ENV=$(grep -cF "# --- PAI environment" /home/claude/.zshrc 2>/dev/null || echo 0)"
      echo "COMPANION=$(test -d /home/claude/pai-companion/companion && echo YES || echo NO)"
      echo "PW_VER=$(command -v bunx >/dev/null 2>&1 && bunx playwright --version 2>/dev/null || echo MISSING)"
      for m in .claude data exchange portal work upstream; do
        test -d "/home/claude/$m" && echo "MOUNT_${m}=YES" || echo "MOUNT_${m}=NO"
      done
    '
    VM_RESULTS=$(limactl shell "$VM_NAME" bash -lc "$VM_CHECK_SCRIPT" 2>/dev/null || echo "")

    # Parse results
    get_val() { echo "$VM_RESULTS" | grep "^$1=" | cut -d= -f2- | tr -d '[:space:]'; }

    check_installed "Bun" "$(get_val BUN_VER)"
    check_installed "Claude Code" "$(get_val CLAUDE_VER)"
    check_installed "Node.js" "$(get_val NODE_VER)"

    [ "$(get_val PAI_DIR)" = "YES" ] && passed "PAI directory" || failed "PAI directory"
    [ "$(get_val PAI_LINK)" = "YES" ] && passed "PAI skill symlink" || failed "PAI skill symlink"

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
      passed "VM mounts accessible (6/6)"
    fi

    [ "$(get_val BASHRC_ENV)" != "0" ] && passed ".bashrc PAI environment block" || failed ".bashrc PAI environment block"
    [ "$(get_val ZSHRC_ENV)" != "0" ] && passed ".zshrc PAI environment block" || failed ".zshrc PAI environment block"
    [ "$(get_val COMPANION)" = "YES" ] && passed "PAI Companion repo" || failed "PAI Companion repo"

    check_installed "Playwright" "$(get_val PW_VER)"
  fi
fi

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "  ──────────────────────────────────────────────"
TOTAL=$((PASS + FAIL))
echo -e "  ${GREEN}${PASS} PASS${NC}  ${RED}${FAIL} FAIL${NC}  (${TOTAL} checks)"
echo ""

if [ $FAIL -gt 0 ]; then
  echo -e "  ${RED}Some checks failed.${NC} Review output above for details."
  echo -e "  Re-run ${BOLD}./install.sh${NC} to fix, or check ${BOLD}${LOG_FILE}${NC}"
  exit 1
else
  echo -e "  ${GREEN}All checks passed.${NC}"
  exit 0
fi
