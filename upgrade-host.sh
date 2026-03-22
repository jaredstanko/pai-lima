#!/bin/bash
# PAI Lima — Upgrade existing installation
# Safe to run on an existing "pai" VM without losing data.
#
# What this upgrades:
#   - Host tools (Lima, kitty via brew)
#   - PAI-Status menu bar app (rebuilt from source)
#   - Portal bookmark on Desktop
#   - VM networking (adds vzNAT + port forwarding if missing)
#   - VM-side tools, aliases, and .bashrc environment
#   - Claude Code (migrates npm→native if needed, runs claude update)
#
# What this does NOT touch:
#   - Your data in ~/pai-workspace/
#   - Your Claude Code authentication and sessions
#   - Your PAI configuration (~/.claude/ inside the VM)
#   - Your work/ directory
#
# Usage:
#   ./upgrade-host.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STEP=0
TOTAL=7

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step() {
  STEP=$((STEP + 1))
  echo ""
  echo -e "${CYAN}[${STEP}/${TOTAL}]${NC} ${BOLD}$1${NC}"
}

ok()   { echo -e "        ${GREEN}✓${NC} $1"; }
skip() { echo -e "        ${YELLOW}⊘${NC} $1 (already up to date)"; }

# Run limactl shell from /tmp to prevent Lima from trying to cd into
# the host's cwd (which doesn't exist inside the VM).
vm_run() { (cd /tmp && limactl shell pai --workdir /home/claude -- "$@"); }

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Sandbox My AI — PAI Lima Upgrade${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  This upgrades your existing installation without losing data."
echo "  Your workspace, config, and sessions are preserved."
echo ""

# ─── Step 1: Upgrade host tools ───────────────────────────────

step "Upgrading host tools..."

if command -v brew &>/dev/null; then
  brew upgrade lima 2>/dev/null && ok "Lima upgraded" || skip "Lima"
  brew upgrade --cask kitty 2>/dev/null && ok "kitty upgraded" || skip "kitty"
else
  skip "Homebrew not found — skipping tool upgrades"
fi

# ─── Step 2: Ensure shared directories exist ──────────────────

step "Checking shared directories..."

WORKSPACE="$HOME/pai-workspace"
DIRS=(claude-home data exchange portal work upstream)
CREATED=0

for dir in "${DIRS[@]}"; do
  if [ ! -d "$WORKSPACE/$dir" ]; then
    mkdir -p "$WORKSPACE/$dir"
    CREATED=$((CREATED + 1))
  fi
done

if [ $CREATED -gt 0 ]; then
  ok "Created $CREATED missing directories"
else
  skip "All directories exist"
fi

# ─── Step 3: Update VM networking ─────────────────────────────

step "Checking VM networking..."

# Verify VM exists
if ! limactl list --json 2>/dev/null | grep -q '"name":"pai"'; then
  echo -e "        ${YELLOW}⚠${NC}  No VM named 'pai' found. Run ./setup-host.sh for a fresh install."
  exit 1
fi

# Check if vzNAT is already configured
VM_JSON=$(limactl list --json 2>/dev/null)
VM_STATUS=$(echo "$VM_JSON" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")

# Check the actual lima config for vzNAT
LIMA_CONFIG="$HOME/.lima/pai/lima.yaml"
if [ -f "$LIMA_CONFIG" ] && grep -q "vzNAT" "$LIMA_CONFIG"; then
  skip "vzNAT networking already configured"
else
  echo "        Adding vzNAT networking and port forwarding..."
  echo "        This requires stopping and restarting the VM."
  echo ""

  if [ "$VM_STATUS" = "Running" ]; then
    echo "        Stopping VM..."
    limactl stop pai
    ok "VM stopped"
  fi

  # Add vzNAT and port forwarding
  limactl edit pai --network "vzNAT" --set '.portForwards = [{"guestPort": 8080, "hostIP": "127.0.0.1"}]'
  ok "vzNAT + port forwarding added"

  echo "        Starting VM..."
  limactl start pai
  ok "VM restarted with new networking"
fi

# Make sure VM is running for remaining steps
VM_STATUS=$(limactl list --json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
if [ "$VM_STATUS" != "Running" ]; then
  echo "        Starting VM..."
  limactl start pai
  ok "VM started"
fi

# ─── Step 4: Update VM-side tools and aliases ─────────────────

step "Updating VM tools and aliases..."

# Copy latest provision script
limactl cp "$SCRIPT_DIR/provision-vm.sh" pai:/home/claude/provision-vm.sh

# Re-run the .bashrc environment block from provision-vm.sh (idempotent),
# then update system packages
vm_run bash -c '
  SENTINEL="# --- PAI environment (managed by provision-vm.sh) ---"
  ENV_BLOCK="
# --- PAI environment (managed by provision-vm.sh) ---

# Bun
export BUN_INSTALL=\"\$HOME/.bun\"
export PATH=\"\$BUN_INSTALL/bin:\$PATH\"

# Claude Code
export PATH=\"\$HOME/.claude/bin:\$PATH\"

# Local binaries (pip --user, etc.)
export PATH=\"\$HOME/.local/bin:\$PATH\"

# Go
export PATH=\"\$HOME/go/bin:\$PATH\"

# Node global (npm install -g)
export PATH=\"\$HOME/.npm-global/bin:\$PATH\"

# Terminal — kitty-terminfo is installed in the VM
export TERM=xterm-kitty

# Default editor
export EDITOR=nano

# PAI launcher
alias pai='\''bun \$HOME/.claude/PAI/Tools/pai.ts'\''

# --- end PAI environment ---
"

  for rcfile in ~/.bashrc ~/.zshrc; do
    touch "$rcfile"
    if grep -qF "$SENTINEL" "$rcfile" 2>/dev/null; then
      sed -i "/$SENTINEL/,/# --- end PAI environment ---/d" "$rcfile"
    fi
    echo "$ENV_BLOCK" >> "$rcfile"
  done

  echo "[+] PAI environment block updated in .bashrc and .zshrc"

  # Update system packages
  sudo apt-get update -qq 2>/dev/null
  sudo apt-get upgrade -y -qq 2>/dev/null
  echo "[+] System packages updated"
'
ok "VM environment and packages updated"

# ─── Step 5: Upgrade Claude Code in VM ────────────────────────

step "Upgrading Claude Code in VM..."

vm_run bash -lc '
  CLAUDE_PATH=$(command -v claude 2>/dev/null || echo "")

  if [ -z "$CLAUDE_PATH" ]; then
    echo "[!] Claude Code not found — installing native..."
    curl -fsSL https://claude.ai/install.sh | bash
  elif echo "$CLAUDE_PATH" | grep -qE "node_modules|npm|lib/node_modules"; then
    echo "[!] Claude Code installed via npm (old method): $CLAUDE_PATH"
    echo "[!] Removing npm version and installing native..."
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
    bun remove -g @anthropic-ai/claude-code 2>/dev/null || true
    curl -fsSL https://claude.ai/install.sh | bash
  else
    echo "[=] Claude Code already native: $CLAUDE_PATH"
    echo "[+] Running claude update..."
    claude update 2>/dev/null || echo "[!] claude update not available — already latest or manual update needed"
  fi
'
ok "Claude Code up to date"

# ─── Step 6: Rebuild menu bar app ─────────────────────────────

step "Rebuilding PAI-Status menu bar app..."

cd "$SCRIPT_DIR/menubar"
bash build.sh --install
ok "PAI-Status rebuilt and installed"

# Relaunch
open /Applications/PAI-Status.app 2>/dev/null || true
ok "PAI-Status running"
cd "$SCRIPT_DIR"

# ─── Step 7: Update portal bookmark ──────────────────────────

step "Updating portal bookmark..."

cp "$SCRIPT_DIR/config/portal.webloc" "$HOME/Desktop/PAI Portal.webloc"
ok "Portal bookmark updated (http://localhost:8080)"

# ─── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Upgrade complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  What was preserved:"
echo "    • All files in ~/pai-workspace/"
echo "    • Claude Code authentication"
echo "    • PAI configuration (~/.claude/)"
echo "    • Claude Code sessions"
echo ""
echo "  What was updated:"
echo "    • Host tools (Lima, kitty)"
echo "    • PAI-Status menu bar app"
echo "    • VM networking (vzNAT → localhost:8080)"
echo "    • VM system packages and aliases"
echo "    • Portal bookmark"
echo ""
