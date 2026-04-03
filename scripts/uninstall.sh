#!/bin/bash
# PAI Lima — Host Cleanup
# Removes everything installed by install.sh and scripts/upgrade.sh.
# Asks before removing workspace data.
#
# Usage:
#   ./scripts/uninstall.sh                 # Uninstall default instance
#   ./scripts/uninstall.sh --name=v2       # Uninstall named instance

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
skip() { echo -e "  ${YELLOW}⊘${NC} $1 (not found)"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }

echo ""
echo -e "${BOLD}${RED}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  PAI Lima — Host Cleanup${NC}"
if [ -n "$INSTANCE_SUFFIX" ]; then
  echo -e "${BOLD}  Instance: ${RED}${INSTANCE_NAME}${NC}"
fi
echo -e "${BOLD}${RED}═══════════════════════════════════════════════${NC}"
echo ""
echo "  This will remove PAI Lima components from your Mac."
echo "  It will NOT uninstall Lima, kitty, or Homebrew themselves."
echo ""
echo "  Target: VM '${VM_NAME}', workspace '${WORKSPACE}/'"
echo ""

# ─── 1. Stop and remove Lima VM ──────────────────────────────

echo -e "${CYAN}[1/4]${NC} ${BOLD}Lima VM${NC}"

if command -v limactl &>/dev/null; then
  VM_STATUS=$(pai_vm_status)
  if [ -n "$VM_STATUS" ]; then
    if [ "$VM_STATUS" = "Running" ]; then
      echo "  Stopping VM..."
      limactl stop "$VM_NAME" 2>/dev/null || true
    fi
    echo "  Deleting VM '${VM_NAME}'..."
    limactl delete "$VM_NAME" --force 2>/dev/null || true
    ok "VM '${VM_NAME}' deleted"
  else
    skip "VM '${VM_NAME}'"
  fi
else
  skip "limactl not installed"
fi

# ─── 2. Remove PAI-Status menu bar app ───────────────────────

echo -e "${CYAN}[2/4]${NC} ${BOLD}${APP_NAME} menu bar app${NC}"

# Kill running instances
osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
pkill -f "PAIStatus.*${VM_NAME}" 2>/dev/null || true

REMOVED_APP=false

if [ -d "/Applications/${APP_BUNDLE}" ]; then
  rm -rf "/Applications/${APP_BUNDLE}"
  ok "Removed /Applications/${APP_BUNDLE}"
  REMOVED_APP=true
fi

# Clean up old name variants for default instance only
if [ "$VM_NAME" = "pai" ]; then
  for old_app in "PAIStatus.app" "PAI Status.app"; do
    if [ -d "/Applications/$old_app" ]; then
      rm -rf "/Applications/$old_app"
      ok "Removed /Applications/$old_app (old name)"
      REMOVED_APP=true
    fi
  done
fi

if [ "$REMOVED_APP" = false ]; then
  skip "${APP_NAME} app"
fi

# ─── 3. Remove launch agents and bookmarks ──────────────────

echo -e "${CYAN}[3/4]${NC} ${BOLD}Launch agents and bookmarks${NC}"

AGENTS=(
  "${LAUNCH_AGENT}"
)
# For default instance, also clean up related agents
if [ "$VM_NAME" = "pai" ]; then
  AGENTS+=(
    "com.pai.lima-apple-bridge"
    "com.pai.apple-bridge"
    "com.kai.observability"
  )
fi

for agent in "${AGENTS[@]}"; do
  PLIST="$HOME/Library/LaunchAgents/${agent}.plist"
  if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    ok "Removed $agent"
  else
    skip "$agent"
  fi
done

# Desktop bookmark
BOOKMARK_PATH=$(pai_bookmark_path)
if [ -f "$BOOKMARK_PATH" ]; then
  rm -f "$BOOKMARK_PATH"
  ok "Removed $(basename "$BOOKMARK_PATH")"
else
  skip "Portal bookmark"
fi

# Bridge token and audit log (default instance only)
if [ "$VM_NAME" = "pai" ]; then
  if [ -f "$HOME/.apple-mcp-bridge-token" ]; then
    rm -f "$HOME/.apple-mcp-bridge-token"
    ok "Removed ~/.apple-mcp-bridge-token"
  else
    skip "Bridge token"
  fi

  if [ -f "$HOME/.apple-mcp-audit.jsonl" ]; then
    rm -f "$HOME/.apple-mcp-audit.jsonl"
    ok "Removed ~/.apple-mcp-audit.jsonl"
  else
    skip "Audit log"
  fi
fi

# ─── 4. Workspace data (ASKS FIRST) ──────────────────────────

echo -e "${CYAN}[4/4]${NC} ${BOLD}Workspace data${NC}"

if [ -d "$WORKSPACE" ]; then
  echo ""
  echo -e "  ${RED}${BOLD}WARNING: ${WORKSPACE}/ contains your data!${NC}"
  echo ""
  echo "  This includes:"
  echo "    • claude-home/ — PAI config, settings, memory"
  echo "    • work/        — Projects and work-in-progress"
  echo "    • data/        — Persistent data"
  echo "    • exchange/    — File exchange"
  echo "    • portal/      — Web portal content"
  echo "    • upstream/    — Reference repos"
  echo ""

  # Show sizes
  echo "  Directory sizes:"
  du -sh "$WORKSPACE/"* 2>/dev/null | while read -r size dir; do
    echo "    $size  $(basename "$dir")"
  done
  echo ""

  echo -ne "  ${RED}Delete ${WORKSPACE}/ and ALL its contents? [y/N]:${NC} "
  read -r CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    rm -rf "$WORKSPACE"
    ok "Removed ${WORKSPACE}/"
  else
    warn "Kept ${WORKSPACE}/ — you can remove it manually later"
  fi
else
  skip "${WORKSPACE}/"
fi

# ─── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Cleanup complete${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  What was removed:"
echo "    • Lima VM '${VM_NAME}'"
echo "    • ${APP_NAME} menu bar app"
echo "    • Launch agents"
echo "    • Desktop bookmark"
echo ""
echo "  What was NOT removed:"
echo "    • Lima, kitty, Hack Nerd Font, Homebrew"
echo "    • kitty.conf (~/.config/kitty/)"
echo "    • This repo (pai-lima/)"
if [ -d "$WORKSPACE" ]; then
  echo "    • ${WORKSPACE}/ (you chose to keep it)"
fi
echo ""
echo "  To do a fresh install: ./install.sh${INSTANCE_SUFFIX:+ --name=${_PAI_NAME}}"
echo ""
