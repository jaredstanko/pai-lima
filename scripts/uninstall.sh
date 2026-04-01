#!/bin/bash
# PAI Lima — Host Cleanup
# Removes everything installed by install.sh and scripts/upgrade.sh.
# Asks before removing ~/pai-workspace/ (your data lives there).
#
# Usage:
#   ./scripts/uninstall.sh

set -euo pipefail

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
echo -e "${BOLD}${RED}═══════════════════════════════════════════════${NC}"
echo ""
echo "  This will remove PAI Lima components from your Mac."
echo "  It will NOT uninstall Lima, kitty, or Homebrew themselves."
echo ""

# ─── 1. Stop and remove Lima VM ──────────────────────────────

echo -e "${CYAN}[1/4]${NC} ${BOLD}Lima VM${NC}"

if command -v limactl &>/dev/null; then
  if limactl list --format '{{.Name}}' 2>/dev/null | grep -q "^pai$"; then
    VM_STATUS=$(limactl list --format '{{.Status}}' --filter "Name=pai" 2>/dev/null || echo "Unknown")
    if [ "$VM_STATUS" = "Running" ]; then
      echo "  Stopping VM..."
      limactl stop pai 2>/dev/null || true
    fi
    echo "  Deleting VM 'pai'..."
    limactl delete pai --force 2>/dev/null || true
    ok "VM 'pai' deleted"
  else
    skip "VM 'pai'"
  fi
else
  skip "limactl not installed"
fi

# ─── 2. Remove PAI-Status menu bar app ───────────────────────

echo -e "${CYAN}[2/4]${NC} ${BOLD}PAI-Status menu bar app${NC}"

# Kill running instances (current and old names)
osascript -e 'tell application "PAI-Status" to quit' 2>/dev/null || true
osascript -e 'tell application "PAI Status" to quit' 2>/dev/null || true
osascript -e 'tell application "PAIStatus" to quit' 2>/dev/null || true
pkill -f PAIStatus 2>/dev/null || true

REMOVED_APP=false

# Current name
if [ -d "/Applications/PAI-Status.app" ]; then
  rm -rf "/Applications/PAI-Status.app"
  ok "Removed /Applications/PAI-Status.app"
  REMOVED_APP=true
fi

# Old names from previous iterations
for old_app in "PAIStatus.app" "PAI Status.app"; do
  if [ -d "/Applications/$old_app" ]; then
    rm -rf "/Applications/$old_app"
    ok "Removed /Applications/$old_app (old name)"
    REMOVED_APP=true
  fi
done

if [ "$REMOVED_APP" = false ]; then
  skip "PAI-Status app"
fi

# ─── 3. Remove launch agents ─────────────────────────────────

echo -e "${CYAN}[3/4]${NC} ${BOLD}Launch agents and bookmarks${NC}"

AGENTS=(
  "com.pai.status"
  "com.pai.lima-apple-bridge"
  "com.pai.apple-bridge"
  "com.kai.observability"
)

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
if [ -f "$HOME/Desktop/PAI Portal.webloc" ]; then
  rm -f "$HOME/Desktop/PAI Portal.webloc"
  ok "Removed Desktop/PAI Portal.webloc"
else
  skip "Portal bookmark"
fi

# Bridge token
if [ -f "$HOME/.apple-mcp-bridge-token" ]; then
  rm -f "$HOME/.apple-mcp-bridge-token"
  ok "Removed ~/.apple-mcp-bridge-token"
else
  skip "Bridge token"
fi

# Audit log
if [ -f "$HOME/.apple-mcp-audit.jsonl" ]; then
  rm -f "$HOME/.apple-mcp-audit.jsonl"
  ok "Removed ~/.apple-mcp-audit.jsonl"
else
  skip "Audit log"
fi

# ─── 4. Workspace data (ASKS FIRST) ──────────────────────────

echo -e "${CYAN}[4/4]${NC} ${BOLD}Workspace data${NC}"

if [ -d "$HOME/pai-workspace" ]; then
  echo ""
  echo -e "  ${RED}${BOLD}WARNING: ~/pai-workspace/ contains your data!${NC}"
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
  du -sh "$HOME/pai-workspace/"* 2>/dev/null | while read -r size dir; do
    echo "    $size  $(basename "$dir")"
  done
  echo ""

  echo -ne "  ${RED}Delete ~/pai-workspace/ and ALL its contents? [y/N]:${NC} "
  read -r CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    rm -rf "$HOME/pai-workspace"
    ok "Removed ~/pai-workspace/"
  else
    warn "Kept ~/pai-workspace/ — you can remove it manually later"
  fi
else
  skip "~/pai-workspace/"
fi

# ─── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Cleanup complete${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  What was removed:"
echo "    • Lima VM 'pai'"
echo "    • PAI-Status menu bar app (all name variants)"
echo "    • Launch agents"
echo "    • Desktop bookmark, bridge token, audit log"
echo ""
echo "  What was NOT removed:"
echo "    • Lima, kitty, Hack Nerd Font, Homebrew"
echo "    • kitty.conf (~/.config/kitty/)"
echo "    • This repo (pai-lima/)"
if [ -d "$HOME/pai-workspace" ]; then
  echo "    • ~/pai-workspace/ (you chose to keep it)"
fi
echo ""
echo "  To do a fresh install: ./install.sh"
echo ""
