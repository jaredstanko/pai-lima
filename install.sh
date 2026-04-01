#!/bin/bash
# PAI Lima — Deterministic Host Installer for macOS
# Single entry point: installs all prerequisites, creates the VM,
# provisions it, builds the menu bar app, and sets up browser bookmarks.
#
# All dependency versions are pinned in versions.env (single source of truth).
# This script is idempotent — safe to re-run if interrupted.
#
# Usage:
#   ./install.sh              # Normal install (progress phases)
#   ./install.sh --verbose    # Show full output from each step
#
# Requirements:
#   - macOS 13+ (Ventura or later)
#   - Apple Silicon (M1/M2/M3/M4)
#   - Internet connection (for downloads)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STEP=0
TOTAL=10
VERBOSE=false
LOG_FILE="$HOME/.pai-install.log"

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=true ;;
  esac
done

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
fail() {
  echo -e "        ${RED}✗${NC} $1"
  if [ -n "${2:-}" ]; then
    echo -e "        ${YELLOW}→${NC} $2"
  fi
  exit 1
}

# Retry helper for network operations
retry() {
  local max_attempts=3
  local delay=5
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    if "$@" >> "$LOG_FILE" 2>&1; then
      return 0
    fi
    if [ $attempt -lt $max_attempts ]; then
      echo -e "        ${YELLOW}⊘${NC} Attempt $attempt/$max_attempts failed. Retrying in ${delay}s..."
      sleep $delay
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# ─── Load version manifest ───────────────────────────────────

VERSIONS_FILE="$SCRIPT_DIR/versions.env"
if [ ! -f "$VERSIONS_FILE" ]; then
  echo -e "${RED}✗${NC} versions.env not found in $SCRIPT_DIR"
  echo -e "${YELLOW}→${NC} This file is required. Re-clone the repo or restore it."
  exit 1
fi
source "$VERSIONS_FILE"

# ─── Banner ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Sandbox My AI — PAI Lima Installer${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  This will set up a sandboxed AI workspace on your Mac."
echo "  Estimated time: 5-10 minutes (first run)."
echo ""
echo "  Pinned versions (from versions.env):"
echo "    Bun:         ${BUN_VERSION}"
echo "    Claude Code: ${CLAUDE_CODE_VERSION}"
echo "    Playwright:  ${PLAYWRIGHT_VERSION}"
echo ""
echo "  Log: $LOG_FILE"
echo ""

# Initialize log
echo "=== PAI Lima Install $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" > "$LOG_FILE"

# ─── Step 1: System requirements ──────────────────────────────

step "Checking system requirements..."

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
  fail "This script requires macOS." "Run this on a Mac with Apple Silicon."
fi
ok "macOS $(sw_vers -productVersion)"

# Check Apple Silicon
if [[ "$(uname -m)" != "arm64" ]]; then
  fail "This script requires Apple Silicon (M1/M2/M3/M4)." "Intel Macs are not supported."
fi
ok "Apple Silicon ($(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'arm64'))"

# Check/install Homebrew
if command -v brew &>/dev/null; then
  ok "Homebrew found"
else
  echo "        Homebrew not found. Installing..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
  ok "Homebrew installed"
fi

# Check Xcode CLI tools (needed for swiftc)
if xcode-select -p &>/dev/null; then
  ok "Xcode Command Line Tools found"
else
  echo "        Installing Xcode Command Line Tools..."
  xcode-select --install 2>/dev/null || true
  echo -e "        ${YELLOW}→${NC} If a dialog appeared, click Install and re-run this script when done."
  exit 0
fi

# ─── Step 2: Install host tools ───────────────────────────────

step "Installing host tools..."

if command -v limactl &>/dev/null; then
  LIMA_VER=$(limactl --version 2>/dev/null | grep -oE '[0-9.]+' | head -1 || echo "unknown")
  skip "Lima ($LIMA_VER)"
else
  echo "        Installing Lima..."
  retry brew install lima
  ok "Lima installed"
fi

if [ -d "/Applications/kitty.app" ] || command -v kitty &>/dev/null; then
  skip "kitty ($(kitty --version 2>/dev/null || echo 'installed'))"
else
  echo "        Installing kitty terminal..."
  retry brew install --cask kitty
  ok "kitty installed"
fi

# Install Hack Nerd Font for kitty
if brew list --cask font-hack-nerd-font &>/dev/null 2>&1; then
  skip "Hack Nerd Font"
else
  echo "        Installing Hack Nerd Font..."
  retry brew install --cask font-hack-nerd-font
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
  ok "VM 'pai' created and started (4 CPU, 4 GB RAM, 50 GB disk)"
fi

# ─── Step 5: Reboot VM and verify audio ──────────────────────

step "Checking sound kernel modules..."

# Only reboot if virtio_snd is not loaded (first run)
if limactl shell pai lsmod 2>/dev/null | grep -q virtio_snd; then
  skip "Sound modules already loaded"
else
  echo "        Rebooting VM to load sound kernel modules..."
  limactl stop pai
  ok "VM stopped"
  limactl start pai
  ok "VM restarted"
fi

# Wait for PulseAudio to come up
sleep 3

echo "        Playing test sound inside VM..."
limactl shell pai bash -c 'PULSE_SERVER=unix:/run/pulse/native timeout 2 speaker-test -t sine -f 440 -l 1 >/dev/null 2>&1 || true'

echo ""
echo -e "        ${YELLOW}▸ Did you hear a tone from your Mac speakers? [y/N]${NC}"
read -r HEARD_SOUND

if [[ "$HEARD_SOUND" =~ ^[Yy] ]]; then
  ok "Audio passthrough confirmed"
else
  echo -e "        ${YELLOW}⊘${NC} Audio not heard — this is non-blocking, continuing setup."
  echo -e "        ${YELLOW}→${NC} Troubleshoot later: limactl shell pai speaker-test -t sine -f 440 -l 1"
fi

# ─── Step 6: Provision sandbox ────────────────────────────────

step "Provisioning sandbox (installs Claude Code, PAI, tools)..."
echo "        This step takes 3-5 minutes on first run."

# Copy versions.env and provision script to VM
limactl cp "$SCRIPT_DIR/versions.env" pai:/home/claude/versions.env
limactl cp "$SCRIPT_DIR/scripts/provision-vm.sh" pai:/home/claude/provision-vm.sh

if [ "$VERBOSE" = true ]; then
  limactl shell pai bash /home/claude/provision-vm.sh
else
  limactl shell pai bash /home/claude/provision-vm.sh 2>&1 | tee -a "$LOG_FILE"
fi
ok "Sandbox provisioned"

# ─── Step 7: Configure terminal keybindings ───────────────────

step "Verifying terminal configuration..."

echo "        kitty keybinding configuration:"
echo "          - Shift+Enter sends escape sequence for Claude Code multi-line input"
echo "          - Remote control enabled for PAI-Status integration"
echo "          - Config installed at ~/.config/kitty/kitty.conf"
ok "kitty configured (see config/kitty.conf)"

# ─── Step 8: Build and install menu bar app ───────────────────

step "Building PAI-Status menu bar app..."

cd "$SCRIPT_DIR/menubar"

if [ -d "/Applications/PAI-Status.app" ]; then
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

# ─── Step 10: Verification & Authentication ──────────────────

step "Final verification..."

# Run verify.sh if it exists
if [ -f "$SCRIPT_DIR/scripts/verify.sh" ]; then
  echo ""
  bash "$SCRIPT_DIR/scripts/verify.sh"
  echo ""
fi

ok "Verification complete"

# ─── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Setup complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}●${NC} Look for PAI-Status in your menu bar (top right)"
echo ""
echo "  Getting started:"
echo "    1. Click the PAI icon in your menu bar"
echo "    2. Click ${BOLD}New PAI Session${NC} to open a terminal"
echo "    3. Run 'claude' and authenticate with your API key"
echo "    4. Optional: click ${BOLD}Launch at Login${NC} so PAI-Status"
echo "       starts automatically when you log in"
echo ""
echo "  From now on, PAI-Status is your control center:"
echo -e "    ${BOLD}New PAI Session${NC}     Open a new AI workspace"
echo -e "    ${BOLD}Resume Session${NC}      Pick up where you left off"
echo -e "    ${BOLD}Start/Stop VM${NC}       Control the sandbox"
echo -e "    ${BOLD}Open PAI Web${NC}        Open the web portal"
echo ""
echo -e "  Install log: $LOG_FILE"
echo -e "  Shared files: ~/pai-workspace/"
echo ""
