#!/bin/bash
# PAI Lima — Deterministic Host Installer for macOS
# Single entry point: installs all prerequisites, creates the VM,
# provisions it, builds the menu bar app, and sets up browser bookmarks.
#
# Tools are installed at their latest versions. The Ubuntu VM image is pinned in pai.yaml.
# This script is idempotent — safe to re-run if interrupted.
#
# Usage:
#   ./install.sh                        # Normal install (default "pai" instance)
#   ./install.sh --verbose              # Show full output from each step
#   ./install.sh --name=v2              # Parallel install as "pai-v2"
#   ./install.sh --name=v2 --port=8082  # Parallel install with specific portal port
#
# Requirements:
#   - macOS 13+ (Ventura or later)
#   - Apple Silicon (M1/M2/M3/M4)
#   - Internet connection (for downloads)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared instance configuration (sets VM_NAME, WORKSPACE, PORTAL_PORT, etc.)
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/scripts/common.sh" "$@" --needs-port

STEP=0
TOTAL=10
VERBOSE=false

# Parse additional flags (--name and --port already consumed by common.sh)
for arg in ${_PAI_REMAINING_ARGS[@]+"${_PAI_REMAINING_ARGS[@]}"}; do
  case "$arg" in
    --verbose|-v) VERBOSE=true ;;
    *) ;;
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

# ─── Banner ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Sandbox My AI — PAI Lima Installer${NC}"
if [ -n "$INSTANCE_SUFFIX" ]; then
  echo -e "${BOLD}  Instance: ${CYAN}${INSTANCE_NAME}${NC}"
fi
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  This will set up a sandboxed AI workspace on your Mac."
echo "  Estimated time: 5-10 minutes (first run)."
echo ""
echo "  VM name:     $VM_NAME"
echo "  Workspace:   $WORKSPACE"
echo "  Portal port: $PORTAL_PORT"
echo "  Log:         $LOG_FILE"
echo ""

# Initialize log
echo "=== PAI Lima Install ($INSTANCE_NAME) $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" > "$LOG_FILE"

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

DIRS=(claude-home data exchange portal work upstream)

for dir in "${DIRS[@]}"; do
  mkdir -p "$WORKSPACE/$dir"
done
ok "$WORKSPACE/ with ${#DIRS[@]} subdirectories"

# ─── Step 4: Create and start sandbox VM ──────────────────────

step "Creating sandbox VM..."

# Generate instance-specific pai.yaml from template
GENERATED_YAML="$SCRIPT_DIR/.pai-${INSTANCE_NAME}.yaml"
# Workspace path needs ~ prefix for Lima yaml (not expanded $HOME)
WORKSPACE_TILDE="${WORKSPACE/#$HOME/~}"
sed \
  -e "s|~/pai-workspace/|${WORKSPACE_TILDE}/|g" \
  -e "s|set-hostname pai|set-hostname ${INSTANCE_NAME}|g" \
  -e "s|lima-pai|${INSTANCE_NAME}|g" \
  "$SCRIPT_DIR/pai.yaml" > "$GENERATED_YAML"

# If using a non-default port, add hostPort to the port forwarding
if [ "$PORTAL_PORT" != "8080" ]; then
  sed -i '' -e "s|guestPort: 8080|guestPort: 8080\n    hostPort: ${PORTAL_PORT}|g" "$GENERATED_YAML"
fi

VM_STATUS=$(pai_vm_status)

if [ -n "$VM_STATUS" ]; then
  skip "VM '$VM_NAME' already exists"
  if [ "$VM_STATUS" != "Running" ]; then
    echo "        Starting VM..."
    limactl start "$VM_NAME"
    ok "VM started"
  else
    skip "VM already running"
  fi
else
  echo "        Creating VM from pai.yaml (this takes 3-5 minutes)..."
  limactl create --name="$VM_NAME" "$GENERATED_YAML"
  limactl start "$VM_NAME"
  ok "VM '$VM_NAME' created and started (4 CPU, 4 GB RAM, 50 GB disk)"
fi

# Clean up generated yaml
rm -f "$GENERATED_YAML"

# ─── Step 5: Reboot VM and verify audio ──────────────────────

step "Checking sound kernel modules..."

# Only reboot if virtio_snd is not loaded (first run)
if limactl shell "$VM_NAME" lsmod 2>/dev/null | grep -q virtio_snd; then
  skip "Sound modules already loaded"
else
  echo "        Rebooting VM to load sound kernel modules..."
  limactl stop "$VM_NAME"
  ok "VM stopped"
  limactl start "$VM_NAME"
  ok "VM restarted"
fi

# Wait for PulseAudio to come up
sleep 3

echo "        Playing test sound inside VM..."
limactl shell "$VM_NAME" bash -c 'PULSE_SERVER=unix:/run/pulse/native timeout 2 speaker-test -t sine -f 440 -l 1 >/dev/null 2>&1 || true'

echo ""
echo -e "        ${YELLOW}▸ Did you hear a tone from your Mac speakers? [y/N]${NC}"
read -r HEARD_SOUND

if [[ "$HEARD_SOUND" =~ ^[Yy] ]]; then
  ok "Audio passthrough confirmed"
else
  echo -e "        ${YELLOW}⊘${NC} Audio not heard — this is non-blocking, continuing setup."
  echo -e "        ${YELLOW}→${NC} Troubleshoot later: limactl shell $VM_NAME speaker-test -t sine -f 440 -l 1"
fi

# ─── Step 6: Provision sandbox ────────────────────────────────

step "Provisioning sandbox (installs Claude Code, PAI, tools)..."
echo "        This step takes 3-5 minutes on first run."

# Copy provision script to VM
limactl cp "$SCRIPT_DIR/scripts/provision-vm.sh" "$VM_NAME":/home/claude/provision-vm.sh

if [ "$VERBOSE" = true ]; then
  limactl shell "$VM_NAME" bash /home/claude/provision-vm.sh
else
  limactl shell "$VM_NAME" bash /home/claude/provision-vm.sh 2>&1 | tee -a "$LOG_FILE"
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

step "Building ${APP_NAME} menu bar app..."

cd "$SCRIPT_DIR/menubar"

if [ -d "/Applications/${APP_BUNDLE}" ]; then
  echo "        Updating ${APP_NAME} app..."
fi

bash build.sh --install --vm-name="$VM_NAME" --port="$PORTAL_PORT" --app-name="$APP_NAME"
ok "${APP_NAME} installed to /Applications"

# Launch it
open "/Applications/${APP_BUNDLE}" 2>/dev/null || true
ok "${APP_NAME} running in menu bar"

cd "$SCRIPT_DIR"

# ─── Step 9: Set up browser bookmark ─────────────────────────

step "Setting up browser bookmarks..."

BOOKMARK_DEST=$(pai_bookmark_path)
pai_generate_webloc "$BOOKMARK_DEST"
ok "Portal bookmark created on Desktop: $(basename "$BOOKMARK_DEST")"
ok "Portal URL: http://localhost:${PORTAL_PORT}"

# ─── Step 10: Verification & Authentication ──────────────────

step "Final verification..."

# Run verify.sh if it exists
if [ -f "$SCRIPT_DIR/scripts/verify.sh" ]; then
  echo ""
  VERIFY_ARGS=(--port="$PORTAL_PORT")
  if [ -n "$_PAI_NAME" ]; then
    VERIFY_ARGS+=(--name="$_PAI_NAME")
  fi
  bash "$SCRIPT_DIR/scripts/verify.sh" "${VERIFY_ARGS[@]}"
  echo ""
fi

ok "Verification complete"

# ─── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Setup complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}●${NC} Look for ${APP_NAME} in your menu bar (top right)"
echo ""
echo "  Getting started:"
echo "    1. Click the PAI icon in your menu bar"
echo "    2. Click ${BOLD}New PAI Session${NC} to open a terminal"
echo "    3. Run 'claude' and authenticate with your API key"
echo "    4. Optional: click ${BOLD}Launch at Login${NC} so ${APP_NAME}"
echo "       starts automatically when you log in"
echo ""
echo "  From now on, ${APP_NAME} is your control center:"
echo -e "    ${BOLD}New PAI Session${NC}     Open a new AI workspace"
echo -e "    ${BOLD}Resume Session${NC}      Pick up where you left off"
echo -e "    ${BOLD}Start/Stop VM${NC}       Control the sandbox"
echo -e "    ${BOLD}Open PAI Web${NC}        Open the web portal"
echo ""
echo -e "  Install log: $LOG_FILE"
echo -e "  Shared files: $WORKSPACE/"
if [ -n "$INSTANCE_SUFFIX" ]; then
  echo ""
  echo "  All scripts support --name=${_PAI_NAME} to target this instance:"
  echo "    ./scripts/launch.sh --name=${_PAI_NAME}"
  echo "    ./scripts/upgrade.sh --name=${_PAI_NAME}"
  echo "    ./scripts/verify.sh --name=${_PAI_NAME}"
  echo "    ./scripts/uninstall.sh --name=${_PAI_NAME}"
fi
echo ""
