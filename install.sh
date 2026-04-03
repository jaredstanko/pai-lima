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

# Use a safe TERM for install output — kitty/xterm-kitty can cause
# garbled output when viewed in Terminal.app or other basic terminals
export TERM=xterm-256color

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared instance configuration (sets VM_NAME, WORKSPACE, PORTAL_PORT, etc.)
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/scripts/common.sh" "$@" --needs-port

STEP=0
TOTAL=8
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
echo -e "${BOLD}${YELLOW}  NOTE: You will see a lot of installation output.${NC}"
echo -e "${BOLD}${YELLOW}  Ignore it all until you see the final instructions.${NC}"
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
  # macOS sed doesn't support \n in replacement — use literal newline
  sed -i '' -e "s|guestPort: 8080|guestPort: 8080\\
    hostPort: ${PORTAL_PORT}|g" "$GENERATED_YAML"
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
  limactl create --tty=false --name="$VM_NAME" "$GENERATED_YAML"
  limactl start "$VM_NAME"
  ok "VM '$VM_NAME' created and started (4 CPU, 4 GB RAM, 50 GB disk)"
fi

# Clean up generated yaml
rm -f "$GENERATED_YAML"

# ─── Step 5: Provision sandbox ────────────────────────────────

step "Provisioning sandbox (installs Claude Code, PAI, tools)..."
echo "        This step takes 3-5 minutes on first run."

# Copy provision script to VM
limactl cp "$SCRIPT_DIR/scripts/provision-vm.sh" "$VM_NAME":/home/claude/provision-vm.sh

if [ "$VERBOSE" = true ]; then
  limactl shell --workdir /home/claude "$VM_NAME" bash /home/claude/provision-vm.sh
else
  limactl shell --workdir /home/claude "$VM_NAME" bash /home/claude/provision-vm.sh 2>&1 | tee -a "$LOG_FILE"
fi
ok "Sandbox provisioned"

# ─── Step 6: Build and install menu bar app ───────────────────

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

# ─── Step 7: Set up browser bookmark ─────────────────────────

step "Setting up browser bookmarks..."

BOOKMARK_DEST=$(pai_bookmark_path)
pai_generate_webloc "$BOOKMARK_DEST"
ok "Portal bookmark created on Desktop: $(basename "$BOOKMARK_DEST")"
ok "Portal URL: http://localhost:${PORTAL_PORT}"

# ─── Step 8: Verification ────────────────────────────────────

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
echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  SETUP COMPLETE — READ THESE INSTRUCTIONS${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Follow these steps in order:"
echo ""
echo "  1. Look at the top-right of your screen for the ${APP_NAME} icon"
echo ""
echo "  2. Click it, then click \"Launch at Login\""
echo "     This makes ${APP_NAME} start automatically when you open your Mac."
echo ""
echo "  3. Click the icon again, then click \"New PAI Session\""
echo "     A terminal window will open."
echo ""
echo "  4. Sign in with your Anthropic account"
echo "     It will open a browser for you to log in."
echo "     When it asks if you trust /home/claude/.claude, say yes."
echo ""
echo "  5. Once signed in, paste this message into the terminal:"
echo ""
echo -e "     ${CYAN}Install PAI Companion following ~/pai-companion/companion/INSTALL.md.${NC}"
echo -e "     ${CYAN}Skip Docker (use Bun directly for the portal) and skip the voice${NC}"
echo -e "     ${CYAN}module. Keep ~/.vm-ip set to localhost and VM_IP=localhost in .env.${NC}"
echo -e "     ${CYAN}After installation, verify the portal is running at localhost:${PORTAL_PORT}${NC}"
echo -e "     ${CYAN}and verify the voice server is working. Set both to start on boot.${NC}"
echo ""
echo "     Claude Code will ask: \"Do you want to create PRD.md?\""
echo "     Press 2 (Yes) to allow it to edit settings for this session."
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Install log: $LOG_FILE"
echo "  Shared files: $WORKSPACE/"
if [ -n "$INSTANCE_SUFFIX" ]; then
  echo ""
  echo "  All scripts support --name=${_PAI_NAME} to target this instance:"
  echo "    ./scripts/launch.sh --name=${_PAI_NAME}"
  echo "    ./scripts/upgrade.sh --name=${_PAI_NAME}"
  echo "    ./scripts/verify.sh --name=${_PAI_NAME}"
  echo "    ./scripts/uninstall.sh --name=${_PAI_NAME}"
fi
echo ""
