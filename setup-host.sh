#!/bin/bash
# PAI Lima — Guided Host Installer for macOS
# Single entry point: installs all prerequisites, creates the VM,
# provisions it, builds the menu bar app, and sets up browser bookmarks.
#
# Usage:
#   ./setup-host.sh
#
# Requirements:
#   - macOS 13+ (Ventura or later)
#   - Apple Silicon (M1/M2/M3/M4)
#   - Internet connection (for downloads)
#
# This script is idempotent — safe to re-run if interrupted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STEP=0
TOTAL=9

# ─── Colors and helpers ───────────────────────────────────────

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

step() {
  STEP=$((STEP + 1))
  echo ""
  echo -e "${CYAN}[${STEP}/${TOTAL}]${NC} ${BOLD}$1${NC}"
}

ok()   { echo -e "        ${GREEN}✓${NC} $1"; }
skip() { echo -e "        ${YELLOW}⊘${NC} $1 (already done)"; }
fail() { echo -e "        ${RED}✗${NC} $1"; exit 1; }

# ─── Banner ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Sandbox My AI — PAI Lima Installer${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  This will set up a sandboxed AI workspace on your Mac."
echo "  Estimated time: 5-10 minutes (first run)."
echo ""

# ─── Step 1: System requirements ──────────────────────────────

step "Checking system requirements..."

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
  fail "This script requires macOS."
fi
ok "macOS $(sw_vers -productVersion)"

# Check Apple Silicon
if [[ "$(uname -m)" != "arm64" ]]; then
  fail "This script requires Apple Silicon (M1/M2/M3/M4)."
fi
ok "Apple Silicon ($(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'arm64'))"

# Check/install Homebrew
if command -v brew &>/dev/null; then
  ok "Homebrew found"
else
  echo "  Homebrew not found. Installing..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
  ok "Homebrew installed"
fi

# Check Xcode CLI tools (needed for swiftc)
if xcode-select -p &>/dev/null; then
  ok "Xcode Command Line Tools found"
else
  echo "  Installing Xcode Command Line Tools..."
  xcode-select --install 2>/dev/null || true
  echo "  → If a dialog appeared, click Install and re-run this script when done."
  exit 0
fi

# ─── Step 2: Install host tools ───────────────────────────────

step "Installing host tools..."

if command -v limactl &>/dev/null; then
  skip "Lima ($(limactl --version 2>/dev/null | head -1 || echo 'installed'))"
else
  brew install lima
  ok "Lima installed"
fi

if [ -d "/Applications/cmux.app" ] || command -v cmux &>/dev/null; then
  skip "cmux"
else
  brew install --cask cmux
  ok "cmux installed"
fi

# ─── Step 3: Create shared workspace directories ──────────────

step "Creating shared workspace directories..."

WORKSPACE="$HOME/pai-workspace"
DIRS=(claude-home data exchange portal work upstream)

for dir in "${DIRS[@]}"; do
  mkdir -p "$WORKSPACE/$dir"
done
ok "~/pai-workspace/ with ${#DIRS[@]} subdirectories"

# ─── Step 4: Create and start sandbox VM ──────────────────────

step "Creating sandbox VM..."

VM_JSON=$(limactl list --json 2>/dev/null || echo "")

if echo "$VM_JSON" | grep -q '"name":"pai"'; then
  skip "VM 'pai' already exists"
  VM_STATUS=$(echo "$VM_JSON" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
  if [ "$VM_STATUS" != "Running" ]; then
    echo "        Starting VM..."
    limactl start pai
    ok "VM started"
  else
    skip "VM already running"
  fi
else
  echo "        Creating VM from pai.yaml (this takes 3-5 minutes)..."
  limactl create --name=pai "$SCRIPT_DIR/pai.yaml"
  limactl start pai
  ok "VM 'pai' created and started (4 CPU, 4 GB RAM, 40 GB disk)"
fi

# ─── Step 5: Provision sandbox ────────────────────────────────

step "Provisioning sandbox (installs Claude Code, PAI, tools)..."
echo "        This step takes 3-5 minutes on first run."

# Check if already provisioned (claude command exists in VM)
if limactl shell pai -- command -v claude &>/dev/null 2>&1; then
  skip "Claude Code already installed in VM"
else
  limactl cp "$SCRIPT_DIR/provision.sh" pai:/home/claude/provision.sh
  limactl shell pai -- bash /home/claude/provision.sh
  ok "Sandbox provisioned"
fi

# ─── Step 6: Configure terminal keybindings ───────────────────

step "Configuring terminal keybindings..."

echo "        cmux keybinding requirements:"
echo "          • Shift+Enter must send escape sequence (not be captured)"
echo "          • Ctrl+B must pass through to tmux (not captured by cmux)"
echo ""
echo "        These work by default in cmux. If you experience issues:"
echo "          • Open cmux → Preferences → Keyboard"
echo "          • See config/terminal.conf for full documentation"
ok "Keybinding documentation at config/terminal.conf"

# ─── Step 7: Build and install menu bar app ───────────────────

step "Building PAI-Status menu bar app..."

cd "$SCRIPT_DIR/menubar"

if [ -d "/Applications/PAI-Status.app" ]; then
  # Rebuild to pick up new features (Open Portal, etc.)
  echo "        Updating PAI-Status app..."
fi

bash build.sh --install
ok "PAI-Status installed to /Applications"

# Launch it
open /Applications/PAI-Status.app 2>/dev/null || true
ok "PAI-Status running in menu bar"

cd "$SCRIPT_DIR"

# ─── Step 8: Set up browser bookmark ─────────────────────────

step "Setting up browser bookmarks..."

BOOKMARK_DEST="$HOME/Desktop/PAI Portal.webloc"
cp "$SCRIPT_DIR/config/portal.webloc" "$BOOKMARK_DEST"
ok "Portal bookmark created on Desktop: PAI Portal.webloc"
ok "Portal URL: http://localhost:8080"

# ─── Step 9: Claude Code authentication ──────────────────────

step "Claude Code authentication..."

echo ""
echo "        To authenticate Claude Code, launch a workspace and follow the prompts:"
echo "        ./launch.sh"
echo ""
echo "        Or authenticate directly:"
echo "        limactl shell pai -- claude"
ok "Claude Code ready — authenticate on first workspace launch"

# ─── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Setup complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}●${NC} PAI-Status is in your menu bar (top right)"
echo -e "  📂 Shared files: ~/pai-workspace/"
echo -e "  🌐 Portal: http://localhost:8080 (bookmark on Desktop)"
echo -e "  🖥️  To open workspaces: ${BOLD}./launch.sh${NC}"
echo ""
echo "  Quick start:"
echo "    • Drop files in ~/pai-workspace/exchange/ to give them to the AI"
echo "    • AI outputs appear in ~/pai-workspace/work/"
echo "    • Click the PAI icon in your menu bar for workspace controls"
echo ""
