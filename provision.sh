#!/bin/bash
# PAI + PAI Companion Provisioning Script (No Docker)
# Run this INSIDE the Lima VM as the 'claude' user.
# Called automatically by setup-host.sh on the Mac.
#
# Usage:
#   bash ~/provision.sh
#
# This script installs:
#   1. Bun (JavaScript runtime)
#   2. Claude Code CLI
#   3. PAI v4.0 (Personal AI Infrastructure)
#   4. PAI Companion (web portal, file exchange — no Docker)
#   5. Playwright (browser automation)

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
echo "  PAI + PAI Companion Installer (no Docker)"
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
  zip tree nodejs npm

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

# Make sure bun is on PATH for the rest of this script
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# -----------------------------------------------------------
# Step 3: Claude Code
# -----------------------------------------------------------
if command -v claude &>/dev/null; then
  log "Claude Code already installed: $(claude --version 2>/dev/null || echo 'installed')"
else
  log "Installing Claude Code..."
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.claude/bin:$PATH"
fi

# Make sure claude is on PATH for the PAI installer
export PATH="$HOME/.claude/bin:$PATH"

echo ""
warn "After this script finishes, run 'claude' to authenticate with your Anthropic API key."
echo ""

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
  log "PAI installed."
fi

# Ensure pai alias exists in .bashrc
if ! grep -q "alias pai=" ~/.bashrc 2>/dev/null; then
  echo "" >> ~/.bashrc
  echo "# PAI launcher" >> ~/.bashrc
  echo "alias pai='bun /home/claude/.claude/PAI/Tools/pai.ts'" >> ~/.bashrc
  log "Added 'pai' alias to .bashrc"
fi

source ~/.bashrc 2>/dev/null || true

# -----------------------------------------------------------
# Step 5: PAI Companion (no Docker)
# -----------------------------------------------------------
log "Installing PAI Companion..."
cd /tmp
rm -rf pai-companion
git clone https://github.com/chriscantey/pai-companion.git
cd pai-companion

# Create companion directory structure (mounted from macOS host)
mkdir -p ~/portal ~/exchange ~/work ~/data ~/upstream

# Copy companion files
if [ -d companion/portal ]; then
  cp -r companion/portal/* ~/portal/ 2>/dev/null || true
fi
if [ -d companion/welcome ]; then
  cp -r companion/welcome/* ~/portal/ 2>/dev/null || true
fi
if [ -d companion/context ]; then
  cp -r companion/context/* ~/.claude/ 2>/dev/null || true
fi
if [ -d companion/scripts ]; then
  cp -r companion/scripts ~/companion-scripts
fi

# Clone upstream repos for reference
cd ~/upstream
[ -d PAI ] || git clone https://github.com/danielmiessler/PAI.git 2>/dev/null || true
[ -d TheAlgorithm ] || git clone https://github.com/danielmiessler/TheAlgorithm.git 2>/dev/null || true

# --- Portal server WITHOUT Docker ---
# Create a simple Bun-based static file server
mkdir -p ~/portal
cat > ~/portal/serve.ts <<'SERVE'
const server = Bun.serve({
  port: 8080,
  hostname: "0.0.0.0",
  async fetch(req) {
    const url = new URL(req.url);
    let path = url.pathname === "/" ? "/index.html" : url.pathname;
    const file = Bun.file(`${import.meta.dir}${path}`);
    if (await file.exists()) {
      return new Response(file);
    }
    return new Response("Not Found", { status: 404 });
  },
});
console.log(`Portal server running on http://0.0.0.0:${server.port}`);
SERVE

# Create a placeholder index.html if none exists
if [ ! -f ~/portal/index.html ]; then
  cat > ~/portal/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>PAI Companion Portal</title>
  <style>
    body { background: #0a0a0a; color: #e0e0e0; font-family: system-ui, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; }
    .container { text-align: center; max-width: 600px; padding: 2rem; }
    h1 { color: #93c5fd; font-size: 2rem; }
    p { color: #9ca3af; line-height: 1.6; }
    .status { color: #4ade80; font-weight: bold; }
  </style>
</head>
<body>
  <div class="container">
    <h1>PAI Companion Portal</h1>
    <p class="status">Online</p>
    <p>Your PAI Companion is running. This portal serves dashboards, reports, and file exchange interfaces created by your AI assistant.</p>
  </div>
</body>
</html>
HTML
fi

# Create systemd user service for the portal
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/pai-portal.service <<UNIT
[Unit]
Description=PAI Companion Portal Server
After=network.target

[Service]
Type=simple
WorkingDirectory=%h/portal
ExecStart=%h/.bun/bin/bun run serve.ts
Restart=on-failure
Environment=PATH=%h/.bun/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
UNIT

# Enable lingering so user services start at boot without login
sudo loginctl enable-linger claude 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable pai-portal.service
systemctl --user start pai-portal.service

log "Portal server started on port 8080 (Bun, no Docker)."

# Initialize git tracking for work and .claude directories
cd ~/work && git init -q && git add -A && git commit -q -m "Initial work directory" 2>/dev/null || true
cd ~/.claude && git init -q && git add -A && git commit -q -m "Initial PAI config" 2>/dev/null || true

rm -rf /tmp/pai-companion

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

# -----------------------------------------------------------
# Done
# -----------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}============================================${NC}"
echo -e "${BOLD}${GREEN}  Installation Complete${NC}"
echo -e "${BOLD}${GREEN}============================================${NC}"
echo ""
log "PAI:        ~/.claude/"
log "Portal:     http://$(hostname -I | awk '{print $1}'):8080"
log "Exchange:   ~/exchange/"
log "Work:       ~/work/"
log "Upstream:   ~/upstream/"
echo ""
warn "Next steps:"
warn "  1. Run 'claude' to authenticate with your Anthropic API key"
warn "  2. Visit the portal URL above from your Mac browser"
warn "  3. Start using PAI: source ~/.bashrc && pai"
echo ""
