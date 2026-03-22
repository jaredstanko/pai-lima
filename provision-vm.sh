#!/bin/bash
# PAI Provisioning Script
# Run this INSIDE the Lima VM as the 'claude' user.
# Called automatically by setup-host.sh on the Mac.
#
# Usage:
#   bash ~/provision-vm.sh
#
# This script installs:
#   1. System packages
#   2. Bun (JavaScript runtime)
#   3. Claude Code CLI
#   4. PAI v4.0 (Personal AI Infrastructure)
#   5. PAI Companion repo (cloned, not installed — Claude does that)
#   6. Playwright (browser automation)
#
# After this script completes, authenticate Claude Code and ask it to
# install PAI Companion: ~/pai-companion/companion/INSTALL.md

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }

echo -e "${BOLD}"
echo "============================================"
echo "  PAI Provisioning"
echo "============================================"
echo -e "${NC}"

# -----------------------------------------------------------
# Step 1: System packages
# -----------------------------------------------------------
log "Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
  jq fzf ripgrep fd-find sqlite3 tmux bat \
  yt-dlp ffmpeg \
  curl wget imagemagick \
  nmap whois dnsutils net-tools traceroute mtr \
  texlive-latex-base texlive-fonts-recommended pandoc \
  golang-go python3 python3-pip python3-venv build-essential git \
  zip tree nodejs npm kitty-terminfo

# -----------------------------------------------------------
# Step 2: Bun
# -----------------------------------------------------------
if command -v bun &>/dev/null; then
  log "Bun already installed: $(bun --version)"
else
  log "Installing Bun..."
  curl -fsSL https://bun.sh/install | bash
  source ~/.bashrc
fi

# Make sure bun is on PATH for the rest of this script and future logins
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# -----------------------------------------------------------
# Step 3: Claude Code
# -----------------------------------------------------------
# Detect if claude is installed via npm (old method) vs native installer
CLAUDE_NEEDS_INSTALL=false
if command -v claude &>/dev/null; then
  CLAUDE_PATH=$(command -v claude)
  if [[ "$CLAUDE_PATH" == *"node_modules"* ]] || [[ "$CLAUDE_PATH" == *"npm"* ]] || [[ "$CLAUDE_PATH" == *"lib/node_modules"* ]]; then
    warn "Claude Code is installed via npm (old method): $CLAUDE_PATH"
    warn "Removing npm version and installing native..."
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
    bun remove -g @anthropic-ai/claude-code 2>/dev/null || true
    CLAUDE_NEEDS_INSTALL=true
  else
    log "Claude Code already installed (native): $(claude --version 2>/dev/null || echo 'installed')"
  fi
else
  CLAUDE_NEEDS_INSTALL=true
fi

if [ "$CLAUDE_NEEDS_INSTALL" = true ]; then
  log "Installing Claude Code (native installer)..."
  curl -fsSL https://claude.ai/install.sh | bash
fi

# Make sure claude is on PATH for the rest of this script
export PATH="$HOME/.claude/bin:$PATH"

echo ""
warn "After this script finishes, run 'claude' to authenticate with your Anthropic API key."
echo ""

# -----------------------------------------------------------
# Step 3b: Shell environment (.bashrc)
# -----------------------------------------------------------
log "Ensuring .bashrc and .zshrc have correct PATH and settings..."

# Build a block with all PATH entries and settings, guarded by a sentinel
# so we can update it idempotently on re-runs.
SENTINEL="# --- PAI environment (managed by provision-vm.sh) ---"
ENV_BLOCK='
# --- PAI environment (managed by provision-vm.sh) ---

# Bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Claude Code
export PATH="$HOME/.claude/bin:$PATH"

# Local binaries (pip --user, etc.)
export PATH="$HOME/.local/bin:$PATH"

# Go
export PATH="$HOME/go/bin:$PATH"

# Node global (npm install -g)
export PATH="$HOME/.npm-global/bin:$PATH"

# Terminal — kitty-terminfo is installed in the VM
export TERM=xterm-kitty

# Default editor
export EDITOR=nano

# PAI launcher
alias pai='\''bun $HOME/.claude/PAI/Tools/pai.ts'\''

# --- end PAI environment ---
'

# Write to both .bashrc and .zshrc
for rcfile in ~/.bashrc ~/.zshrc; do
  touch "$rcfile"
  if grep -qF "$SENTINEL" "$rcfile" 2>/dev/null; then
    sed -i "/$SENTINEL/,/# --- end PAI environment ---/d" "$rcfile"
  fi
  echo "$ENV_BLOCK" >> "$rcfile"
done

log "PAI environment block written to .bashrc and .zshrc"

# Configure npm global prefix so `npm install -g` doesn't need sudo
mkdir -p "$HOME/.npm-global"
if ! npm config get prefix 2>/dev/null | grep -q '.npm-global'; then
  npm config set prefix "$HOME/.npm-global"
  log "npm global prefix set to ~/.npm-global"
fi

# Apply for the rest of this script
export PATH="$HOME/.claude/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.npm-global/bin:$PATH"
export TERM=xterm-kitty

# -----------------------------------------------------------
# Step 4: PAI v4.0
# -----------------------------------------------------------
if [ -d "$HOME/.claude/PAI" ] || [ -d "$HOME/.claude/skills/PAI" ]; then
  log "PAI appears to be already installed. Skipping."
else
  log "Installing PAI v4.0..."
  cd /tmp
  rm -rf PAI
  git clone https://github.com/danielmiessler/PAI.git
  cd PAI
  LATEST_RELEASE=$(ls Releases/ | sort -V | tail -1)
  log "Using PAI release: $LATEST_RELEASE"
  cp -r "Releases/$LATEST_RELEASE/.claude/" ~/
  cd ~/.claude

  # Fix installer for CLI mode (no GUI available in VM)
  if [ -f install.sh ]; then
    sed -i 's/--mode gui/--mode cli/' install.sh
    bash install.sh
  fi

  # Fix shell config: PAI installer writes to .zshrc, we use bash
  if [ -f ~/.zshrc ]; then
    cat ~/.zshrc >> ~/.bashrc
    # Fix PAI tool paths for the installed layout
    sed -i 's|skills/PAI/Tools/pai.ts|PAI/Tools/pai.ts|g' ~/.bashrc
  fi

  rm -rf /tmp/PAI

  # Ensure PAI core skill is at the expected path for validation
  if [ -d "$HOME/.claude/PAI" ] && [ ! -d "$HOME/.claude/skills/PAI" ]; then
    mkdir -p "$HOME/.claude/skills"
    ln -sf "$HOME/.claude/PAI" "$HOME/.claude/skills/PAI"
    log "Symlinked ~/.claude/PAI → ~/.claude/skills/PAI"
  fi

  log "PAI installed."
fi

source ~/.bashrc 2>/dev/null || true

# -----------------------------------------------------------
# Step 4b: Detect VM IP and write .env
# -----------------------------------------------------------
# Use localhost since Lima port-forwards guest ports to the host
VM_IP="localhost"
echo "$VM_IP" > ~/.vm-ip
log "VM IP: $VM_IP (Lima port-forwards to host)"

# Write .env to ~/.claude (Lima mount from host ~/pai-workspace/claude-home)
if [ -d "$HOME/.claude" ] && touch "$HOME/.claude/.env-test" 2>/dev/null; then
  rm -f "$HOME/.claude/.env-test"
  if [ -f ~/.claude/.env ]; then
    sed -i '/^VM_IP=/d; /^PORTAL_PORT=/d' ~/.claude/.env
  fi
  cat >> ~/.claude/.env <<ENVEOF
VM_IP=$VM_IP
PORTAL_PORT=8080
ENVEOF
  log "VM_IP and PORTAL_PORT written to ~/.claude/.env"
else
  warn "~/.claude mount not writable — skipping .env write"
  warn "Ensure ~/pai-workspace/claude-home exists on the host"
fi

# -----------------------------------------------------------
# Step 5: Clone PAI Companion (for Claude to install later)
# -----------------------------------------------------------
log "Cloning PAI Companion repo..."
cd /tmp
rm -rf pai-companion
if git clone https://github.com/chriscantey/pai-companion.git 2>/dev/null; then
  rm -rf "$HOME/pai-companion"
  cp -r /tmp/pai-companion "$HOME/pai-companion"
  rm -rf /tmp/pai-companion
  log "PAI Companion cloned to ~/pai-companion"
else
  warn "Failed to clone pai-companion — you can clone it manually later."
fi

# -----------------------------------------------------------
# Step 6: Playwright (optional but recommended)
# -----------------------------------------------------------
log "Installing Playwright..."
if command -v bun &>/dev/null; then
  cd /tmp
  mkdir -p playwright-setup && cd playwright-setup
  bun init -y 2>/dev/null || true
  bun add playwright 2>/dev/null || true
  bunx playwright install --with-deps chromium 2>/dev/null || warn "Playwright install may need manual completion."
  cd /tmp && rm -rf playwright-setup
else
  warn "Bun not found. Skipping Playwright."
fi

# ===================================================================
# Verification
# ===================================================================
echo ""
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}  Verifying Installation${NC}"
echo -e "${BOLD}============================================${NC}"
echo ""

PASS=0
FAIL=0

check() {
  local label="$1"
  local result="$2"
  if [ "$result" = "PASS" ]; then
    echo -e "  ${GREEN}✓${NC} $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $label"
    FAIL=$((FAIL + 1))
  fi
}

# Core tools
command -v bun &>/dev/null && check "Bun installed" "PASS" || check "Bun installed" "FAIL"
command -v claude &>/dev/null && check "Claude Code installed" "PASS" || check "Claude Code installed" "FAIL"

# PAI
(test -d "$HOME/.claude/PAI" || test -d "$HOME/.claude/skills/PAI") \
  && check "PAI installed" "PASS" || check "PAI installed" "FAIL"

# Shell environment
grep -qF "# --- PAI environment (managed by provision-vm.sh) ---" ~/.bashrc 2>/dev/null \
  && check ".bashrc PAI environment block" "PASS" || check ".bashrc PAI environment block" "FAIL"

grep -qF "# --- PAI environment (managed by provision-vm.sh) ---" ~/.zshrc 2>/dev/null \
  && check ".zshrc PAI environment block" "PASS" || check ".zshrc PAI environment block" "FAIL"

# VM IP
test -s ~/.vm-ip && check "VM IP configured ($(cat ~/.vm-ip))" "PASS" || check "VM IP configured" "FAIL"

# Companion repo
test -d "$HOME/pai-companion/companion" \
  && check "PAI Companion repo cloned" "PASS" || check "PAI Companion repo cloned" "FAIL"

echo ""
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"

# -----------------------------------------------------------
# Done
# -----------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}============================================${NC}"
echo -e "${BOLD}${GREEN}  Provisioning Complete${NC}"
echo -e "${BOLD}${GREEN}============================================${NC}"
echo ""
log "PAI:          ~/.claude/"
log "Companion:    ~/pai-companion/ (ready for Claude to install)"
echo ""
warn "Next steps:"
warn "  1. Run 'claude' to authenticate with your Anthropic API key"
warn "  2. Ask Claude to install PAI Companion:"
warn "     \"Install PAI Companion following ~/pai-companion/companion/INSTALL.md."
warn "      Skip Docker (use Bun directly) and skip the voice module.\""
warn "  3. Start using PAI: source ~/.bashrc && pai"
echo ""
