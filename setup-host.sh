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
TOTAL=10

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

# Run limactl shell from /tmp to prevent Lima from trying to cd into
# the host's cwd (which doesn't exist inside the VM).
vm_run() { (cd /tmp && limactl shell pai --workdir /home/claude "$@"); }

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

if [ -d "/Applications/kitty.app" ] || command -v kitty &>/dev/null; then
  skip "kitty ($(kitty --version 2>/dev/null || echo 'installed'))"
else
  brew install --cask kitty
  ok "kitty installed"
fi

# Install Hack Nerd Font for kitty
if brew list --cask font-hack-nerd-font &>/dev/null 2>&1; then
  skip "Hack Nerd Font"
else
  brew install --cask font-hack-nerd-font
  ok "Hack Nerd Font installed"
fi

# Install kitty configuration
mkdir -p "$HOME/.config/kitty"
cp "$SCRIPT_DIR/config/kitty.conf" "$HOME/.config/kitty/kitty.conf"
ok "kitty.conf installed to ~/.config/kitty/"

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

# ─── Step 5: Reboot VM and verify audio ──────────────────────

step "Rebooting VM to load sound kernel modules..."

echo "        Stopping VM..."
limactl stop pai
ok "VM stopped"

echo "        Starting VM..."
limactl start pai
ok "VM restarted"

# Wait for PulseAudio to come up
sleep 3

echo "        Playing test sound inside VM..."
# Generate a 1-second 440Hz sine wave and play it through ALSA/PulseAudio
# Run from /tmp to avoid Lima trying to cd into the host's cwd inside the VM
vm_run bash -c 'PULSE_SERVER=unix:/run/pulse/native timeout 2 speaker-test -t sine -f 440 -l 1 >/dev/null 2>&1 || true'

echo ""
echo -e "        ${YELLOW}▸ Did you hear a tone from your Mac speakers? [y/N]${NC}"
read -r HEARD_SOUND

if [[ "$HEARD_SOUND" =~ ^[Yy] ]]; then
  ok "Audio passthrough confirmed"
else
  echo -e "        ${YELLOW}⊘${NC} Audio not heard — this is non-blocking, continuing setup."
  echo "        You can troubleshoot later: limactl shell pai --workdir /home/claude -- speaker-test -t sine -f 440 -l 1"
fi

# ─── Step 6: Provision sandbox ────────────────────────────────

step "Provisioning sandbox (installs Claude Code, PAI, tools)..."
echo "        This step takes 3-5 minutes on first run."

# Check if already provisioned (claude command exists in VM)
if vm_run command -v claude &>/dev/null 2>&1; then
  skip "Claude Code already installed in VM"
else
  limactl cp "$SCRIPT_DIR/provision-vm.sh" pai:/home/claude/provision-vm.sh
  vm_run bash /home/claude/provision-vm.sh
  ok "Sandbox provisioned"
fi

# ─── Step 7: Configure terminal keybindings ───────────────────

step "Verifying terminal configuration..."

echo "        kitty keybinding configuration:"
echo "          • Shift+Enter sends escape sequence for Claude Code multi-line input"
echo "          • Remote control enabled for PAI-Status integration"
echo "          • Config installed at ~/.config/kitty/kitty.conf"
ok "kitty configured (see config/kitty.conf)"

# ─── Step 8: Build and install menu bar app ───────────────────

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

# ─── Step 9: Set up browser bookmark ─────────────────────────

step "Setting up browser bookmarks..."

BOOKMARK_DEST="$HOME/Desktop/PAI Portal.webloc"
cp "$SCRIPT_DIR/config/portal.webloc" "$BOOKMARK_DEST"
ok "Portal bookmark created on Desktop: PAI Portal.webloc"
ok "Portal URL: http://localhost:8080"

# ─── Step 10: Claude Code authentication ─────────────────────

step "Claude Code authentication..."

echo ""
echo "        To authenticate Claude Code, launch a workspace and follow the prompts:"
echo "        ./launch-host.sh"
echo ""
echo "        Or authenticate directly:"
echo "        limactl shell pai --workdir /home/claude -- claude  # (display only, not executed)"
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
echo -e "  🖥️  To open workspaces: ${BOLD}./launch-host.sh${NC}"
echo ""
echo "  Quick start:"
echo "    • Drop files in ~/pai-workspace/exchange/ to give them to the AI"
echo "    • AI outputs appear in ~/pai-workspace/work/"
echo "    • Click the PAI icon in your menu bar for workspace controls"
echo ""
