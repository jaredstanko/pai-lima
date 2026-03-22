#!/bin/bash
# PAI + PAI Companion Provisioning Script (No Docker)
# Run this INSIDE the Lima VM as the 'claude' user.
# Called automatically by setup-host.sh on the Mac.
#
# Usage:
#   bash ~/provision-vm.sh
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

# ===================================================================
# Step 5: PAI Companion
# Follows the companion's INSTALL.md phases, adapted for Lima (no Docker).
# ===================================================================

COMPANION_DIR="$HOME/pai-companion"

log "Cloning PAI Companion..."
cd /tmp
rm -rf pai-companion
if ! git clone https://github.com/chriscantey/pai-companion.git; then
  err "Failed to clone pai-companion. Check network connectivity."
  exit 1
fi

# Keep a persistent copy in home for scripts/patches/context
rm -rf "$COMPANION_DIR"
cp -r /tmp/pai-companion "$COMPANION_DIR"
rm -rf /tmp/pai-companion
log "PAI Companion cloned to $COMPANION_DIR"

# --- Phase 0: Linux Adaptation (statusline patches) ---
log "Phase 0: Patching statusline for Linux..."
if [ -f "$COMPANION_DIR/companion/patches/statusline-linux.sh" ]; then
  bash "$COMPANION_DIR/companion/patches/statusline-linux.sh"
  log "Statusline patched for Linux."
else
  warn "Statusline patch script not found — skipping."
fi

# --- Phase 1: VM IP already detected in Step 4b ($VM_IP) ---

# --- Phase 2: Directory Structure ---
log "Phase 2: Setting up directories..."
if [ -f "$COMPANION_DIR/companion/scripts/setup-dirs.sh" ]; then
  bash "$COMPANION_DIR/companion/scripts/setup-dirs.sh"
else
  # Fallback: create directories manually
  mkdir -p ~/portal ~/portal/clipboard ~/exchange ~/work ~/data ~/upstream
fi
log "Directory structure ready."

# --- Phase 3: Portal + Voice Servers (no Docker, no TTS) ---
log "Phase 3: Setting up portal and voice servers..."

# Copy companion portal files if available
if [ -d "$COMPANION_DIR/companion/portal/public" ]; then
  cp -r "$COMPANION_DIR/companion/portal/public/"* ~/portal/ 2>/dev/null || true
  log "Portal public files installed."
fi
if [ -d "$COMPANION_DIR/companion/welcome" ]; then
  cp -r "$COMPANION_DIR/companion/welcome" ~/portal/welcome 2>/dev/null || true
  log "Welcome page installed."
fi

# Create portal server (static files with directory index support)
cat > ~/portal/serve.ts <<'SERVE'
const server = Bun.serve({
  port: 8080,
  hostname: "0.0.0.0",
  async fetch(req) {
    const url = new URL(req.url);
    let path = url.pathname === "/" ? "/index.html" : url.pathname;
    let file = Bun.file(`${import.meta.dir}${path}`);
    if (await file.exists()) return new Response(file);
    if (path.endsWith("/")) {
      file = Bun.file(`${import.meta.dir}${path}index.html`);
      if (await file.exists()) return new Response(file);
    }
    file = Bun.file(`${import.meta.dir}${path}/index.html`);
    if (await file.exists()) return Response.redirect(`${url.origin}${path}/`, 301);
    return new Response("Not Found", { status: 404 });
  },
});
console.log(`Portal running on http://0.0.0.0:${server.port}`);
SERVE
log "Portal serve.ts created."

# Create placeholder index.html if none exists
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
    <p>Your PAI Companion is running.</p>
  </div>
</body>
</html>
HTML
fi

# Create voice/notification server (accepts POST /notify, no TTS)
# PAI hooks call this endpoint — it just logs and returns success
mkdir -p ~/voice-server
cat > ~/voice-server/serve.ts <<'VOICE'
const server = Bun.serve({
  port: 8888,
  hostname: "0.0.0.0",
  async fetch(req) {
    const headers = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
      "Content-Type": "application/json",
    };
    if (req.method === "OPTIONS") return new Response(null, { headers });
    if (req.url.endsWith("/health")) {
      return new Response(JSON.stringify({ status: "ok", port: 8888 }), { headers });
    }
    if (req.method === "POST" && req.url.endsWith("/notify")) {
      try {
        const data = await req.json();
        const msg = data.message || "(no message)";
        console.log(`[notify] ${msg.substring(0, 80)}`);
        return new Response(JSON.stringify({ status: "success" }), { headers });
      } catch {
        return new Response(JSON.stringify({ status: "error" }), { headers, status: 400 });
      }
    }
    return new Response(JSON.stringify({ status: "ok", info: "PAI Voice Server" }), { headers });
  },
});
console.log(`Voice server running on http://0.0.0.0:${server.port}`);
VOICE
log "Voice serve.ts created."

# Create a startup script that launches both servers in background on login
cat > ~/start-servers.sh <<'STARTUP'
#!/bin/bash
# Start PAI portal and voice servers (called from .bashrc on login)
BUN="$HOME/.bun/bin/bun"

# Only start if not already running
if ! curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1 && [ -f ~/portal/serve.ts ]; then
  nohup "$BUN" run ~/portal/serve.ts > ~/portal/server.log 2>&1 &
fi

if ! curl -sf http://127.0.0.1:8888/health >/dev/null 2>&1 && [ -f ~/voice-server/serve.ts ]; then
  nohup "$BUN" run ~/voice-server/serve.ts > ~/voice-server/server.log 2>&1 &
fi
STARTUP
chmod +x ~/start-servers.sh

# Add to .bashrc so servers start on any login (idempotent)
STARTUP_SENTINEL="# --- PAI servers (auto-start) ---"
for rcfile in ~/.bashrc ~/.zshrc; do
  if [ -f "$rcfile" ] && ! grep -qF "$STARTUP_SENTINEL" "$rcfile" 2>/dev/null; then
    cat >> "$rcfile" <<RCEOF

$STARTUP_SENTINEL
[ -f ~/start-servers.sh ] && bash ~/start-servers.sh
# --- end PAI servers ---
RCEOF
  fi
done

# Start them now
bash ~/start-servers.sh

# Verify
sleep 2
if curl -sf http://127.0.0.1:8080/ >/dev/null 2>&1; then
  log "Portal server running on port 8080."
else
  warn "Portal server not responding on 8080."
fi
if curl -sf http://127.0.0.1:8888/health >/dev/null 2>&1; then
  log "Voice server running on port 8888."
else
  warn "Voice server not responding on 8888."
fi

# --- Phase 6: Extended Core Context ---
log "Phase 6: Installing context files..."

mkdir -p ~/.claude/PAI/USER

if [ -f "$COMPANION_DIR/companion/context/identity-additions.md" ]; then
  IDENTITY_FILE="$HOME/.claude/PAI/USER/IDENTITY.md"
  IDENTITY_CONTENT=$(sed "s/{VM_IP}/$VM_IP/g" "$COMPANION_DIR/companion/context/identity-additions.md")
  if [ -f "$IDENTITY_FILE" ] && grep -q "PAI Companion" "$IDENTITY_FILE" 2>/dev/null; then
    log "Identity additions already present — skipping."
  else
    {
      echo ""
      echo "---"
      echo "<!-- Added by PAI Companion setup -->"
      echo "$IDENTITY_CONTENT"
    } >> "$IDENTITY_FILE"
    log "Identity additions appended to IDENTITY.md"
  fi
fi

if [ -f "$COMPANION_DIR/companion/context/steering-rules.md" ]; then
  STEERING_FILE="$HOME/.claude/PAI/USER/AISTEERINGRULES.md"
  STEERING_CONTENT=$(sed "s/{VM_IP}/$VM_IP/g" "$COMPANION_DIR/companion/context/steering-rules.md")
  if [ -f "$STEERING_FILE" ] && grep -qi "Visual-first" "$STEERING_FILE" 2>/dev/null; then
    log "Steering rules already present — skipping."
  else
    {
      echo ""
      echo "---"
      echo "<!-- Added by PAI Companion setup -->"
      echo "$STEERING_CONTENT"
    } >> "$STEERING_FILE"
    log "Steering rules appended to AISTEERINGRULES.md"
  fi
fi

if [ -f "$COMPANION_DIR/companion/context/design-system.md" ]; then
  cp "$COMPANION_DIR/companion/context/design-system.md" ~/.claude/PAI/USER/DESIGN.md
  log "Design system installed to DESIGN.md"
fi

# Add DESIGN.md to settings.json contextFiles if not already present
SETTINGS_FILE="$HOME/.claude/settings.json"
if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
  if ! jq -e '.contextFiles // [] | index("USER/DESIGN.md")' "$SETTINGS_FILE" >/dev/null 2>&1; then
    jq '.contextFiles = ((.contextFiles // []) + ["USER/DESIGN.md"])' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" \
      && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    log "Added DESIGN.md to settings.json contextFiles."
  else
    log "DESIGN.md already in contextFiles."
  fi
fi

# --- Phase 8: Upstream Repos and Algorithm Update ---
log "Phase 8: Setting up upstream repos..."

cd ~/upstream
if [ -d PAI ]; then
  git -C PAI pull --ff-only 2>/dev/null || log "PAI upstream: pull skipped (may have local changes)"
else
  git clone https://github.com/danielmiessler/PAI.git || warn "Failed to clone PAI upstream"
fi

if [ -d TheAlgorithm ]; then
  git -C TheAlgorithm pull --ff-only 2>/dev/null || log "Algorithm upstream: pull skipped"
else
  git clone https://github.com/danielmiessler/TheAlgorithm.git || warn "Failed to clone TheAlgorithm upstream"
fi

# Install latest Algorithm version (never downgrade)
ALG_DIR="$HOME/.claude/PAI/Algorithm"
mkdir -p "$ALG_DIR"

CURRENT_VER=""
if [ -f "$ALG_DIR/LATEST" ]; then
  CURRENT_VER=$(cat "$ALG_DIR/LATEST" | sed 's/^v//')
fi

ALL_VERSIONS=""
for f in ~/upstream/TheAlgorithm/versions/TheAlgorithm_v*.md "$ALG_DIR"/v*.md; do
  [ -f "$f" ] || continue
  ver=$(basename "$f" | sed 's/^TheAlgorithm_v//;s/^v//;s/\.md$//')
  if echo "$ver" | grep -qE '^[0-9]+(\.[0-9]+)*$'; then
    ALL_VERSIONS="$ALL_VERSIONS $ver"
  fi
done

BEST_VER=$(printf '%s\n' $ALL_VERSIONS | sort -V | tail -1)

if [ -n "$BEST_VER" ]; then
  UPSTREAM_FILE="$HOME/upstream/TheAlgorithm/versions/TheAlgorithm_v${BEST_VER}.md"
  if [ -f "$UPSTREAM_FILE" ] && [ ! -f "$ALG_DIR/v${BEST_VER}.md" ]; then
    cp "$UPSTREAM_FILE" "$ALG_DIR/v${BEST_VER}.md"
  fi
  if [ -z "$CURRENT_VER" ]; then
    echo "v${BEST_VER}" > "$ALG_DIR/LATEST"
    log "Algorithm: installed v${BEST_VER}"
  elif [ "$BEST_VER" != "$CURRENT_VER" ]; then
    NEWER=$(printf '%s\n%s\n' "$CURRENT_VER" "$BEST_VER" | sort -V | tail -1)
    if [ "$NEWER" = "$BEST_VER" ]; then
      echo "v${BEST_VER}" > "$ALG_DIR/LATEST"
      log "Algorithm: upgraded from v${CURRENT_VER} to v${BEST_VER}"
    else
      log "Algorithm: keeping v${CURRENT_VER} (best available is v${BEST_VER})"
    fi
  else
    log "Algorithm: v${CURRENT_VER} is already the latest"
  fi
else
  if [ -n "$CURRENT_VER" ]; then
    log "Algorithm: keeping v${CURRENT_VER} (no valid versions found upstream)"
  else
    warn "No Algorithm version found. PAI v4.0 should have installed one."
  fi
fi

# Rebuild dynamic core if build tool exists
if [ -f ~/.claude/PAI/Tools/BuildCLAUDE.ts ]; then
  bun ~/.claude/PAI/Tools/BuildCLAUDE.ts 2>/dev/null || warn "BuildCLAUDE.ts failed — non-blocking."
fi

# --- Phase 9: Local Git Tracking ---
log "Phase 9: Initializing git tracking..."

cd ~/.claude
git init -q 2>/dev/null || true
git -C ~/.claude config user.email "local@vm"
git -C ~/.claude config user.name "$(jq -r '.principal.name // "User"' ~/.claude/settings.json 2>/dev/null || echo 'User')"
cd ~/.claude && git add -A && git commit -q -m "PAI Companion: post-setup snapshot" --allow-empty 2>/dev/null || true

cd ~/work
git init -q 2>/dev/null || true
git -C ~/work config user.email "local@vm"
git -C ~/work config user.name "$(jq -r '.principal.name // "User"' ~/.claude/settings.json 2>/dev/null || echo 'User')"
cd ~/work && git add -A && git commit -q -m "Initial commit" --allow-empty 2>/dev/null || true
log "Git tracking initialized for ~/.claude and ~/work"

# --- Phase 10: Maintenance Cron Jobs ---
log "Phase 10: Installing cron jobs..."
if [ -f "$COMPANION_DIR/companion/scripts/setup-cron.sh" ]; then
  bash "$COMPANION_DIR/companion/scripts/setup-cron.sh"
  log "Cron jobs installed."
else
  warn "Cron setup script not found — skipping."
fi

# --- Phase 10b: Validate Timezone ---
log "Phase 10b: Validating timezone..."
if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null && command -v bun &>/dev/null; then
  TZ_VAL=$(jq -r '.principal.timezone // empty' "$SETTINGS_FILE" 2>/dev/null)
  if [ -n "$TZ_VAL" ]; then
    TZ_VALID=$(bun -e "try { Intl.DateTimeFormat('en', { timeZone: '$TZ_VAL' }); console.log('valid'); } catch { console.log('invalid'); }" 2>/dev/null)
    if [ "$TZ_VALID" = "invalid" ]; then
      # Map common abbreviations to IANA
      SYSTEM_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "")
      if [ -n "$SYSTEM_TZ" ]; then
        jq --arg tz "$SYSTEM_TZ" '.principal.timezone = $tz' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" \
          && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        log "Timezone corrected: $TZ_VAL → $SYSTEM_TZ"
      else
        warn "Timezone '$TZ_VAL' is invalid but could not detect system timezone."
      fi
    else
      log "Timezone valid: $TZ_VAL"
    fi
  else
    log "No timezone set in settings — skipping."
  fi
fi

# --- Phase 11: Version Marker ---
echo "companion-$(date +%Y%m%d)" > ~/portal/.companion-version
log "Version marker: $(cat ~/portal/.companion-version)"

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

# Shell environment
grep -qF "# --- PAI environment (managed by provision-vm.sh) ---" ~/.bashrc 2>/dev/null \
  && check ".bashrc PAI environment block" "PASS" || check ".bashrc PAI environment block" "FAIL"

grep -q 'BUN_INSTALL' ~/.bashrc 2>/dev/null \
  && check ".bashrc Bun PATH" "PASS" || check ".bashrc Bun PATH" "FAIL"

grep -q '\.claude/bin' ~/.bashrc 2>/dev/null \
  && check ".bashrc Claude Code PATH" "PASS" || check ".bashrc Claude Code PATH" "FAIL"

grep -q 'TERM=xterm-kitty' ~/.bashrc 2>/dev/null \
  && check ".bashrc TERM=xterm-kitty" "PASS" || check ".bashrc TERM=xterm-kitty" "FAIL"

grep -q 'alias pai=' ~/.bashrc 2>/dev/null \
  && check ".bashrc pai alias" "PASS" || check ".bashrc pai alias" "FAIL"

# Directories
test -d ~/portal && test -d ~/exchange && test -d ~/work && test -d ~/data && test -d ~/upstream \
  && check "Directory structure" "PASS" || check "Directory structure" "FAIL"

# VM IP
test -s ~/.vm-ip && check "VM IP configured ($(cat ~/.vm-ip))" "PASS" || check "VM IP configured" "FAIL"

# Servers
curl -sf http://127.0.0.1:8080/ >/dev/null 2>&1 \
  && check "Portal server responding (8080)" "PASS" || check "Portal server responding (8080)" "FAIL"

curl -sf http://127.0.0.1:8888/health >/dev/null 2>&1 \
  && check "Voice server responding (8888)" "PASS" || check "Voice server responding (8888)" "FAIL"

# Context files
test -f ~/.claude/PAI/USER/DESIGN.md \
  && check "Design system installed" "PASS" || check "Design system installed" "FAIL"

grep -qi "Visual-first" ~/.claude/PAI/USER/AISTEERINGRULES.md 2>/dev/null \
  && check "Steering rules installed" "PASS" || check "Steering rules installed" "FAIL"

# Upstream repos
git -C ~/upstream/PAI log --oneline -1 >/dev/null 2>&1 \
  && check "Upstream PAI repo" "PASS" || check "Upstream PAI repo" "FAIL"

git -C ~/upstream/TheAlgorithm log --oneline -1 >/dev/null 2>&1 \
  && check "Upstream Algorithm repo" "PASS" || check "Upstream Algorithm repo" "FAIL"

# Algorithm version
test -s ~/.claude/PAI/Algorithm/LATEST \
  && check "Algorithm installed ($(cat ~/.claude/PAI/Algorithm/LATEST))" "PASS" \
  || check "Algorithm installed" "FAIL"

# Git tracking
git -C ~/.claude log --oneline -1 >/dev/null 2>&1 \
  && check "Git tracking (~/.claude)" "PASS" || check "Git tracking (~/.claude)" "FAIL"

git -C ~/work log --oneline -1 >/dev/null 2>&1 \
  && check "Git tracking (~/work)" "PASS" || check "Git tracking (~/work)" "FAIL"

# Cron jobs
crontab -l 2>/dev/null | grep -q "daily snapshot" \
  && check "Cron jobs installed" "PASS" || check "Cron jobs installed" "FAIL"

# Companion version
test -f ~/portal/.companion-version \
  && check "Version marker ($(cat ~/portal/.companion-version))" "PASS" \
  || check "Version marker" "FAIL"

echo ""
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"

# -----------------------------------------------------------
# Done
# -----------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}============================================${NC}"
echo -e "${BOLD}${GREEN}  Installation Complete${NC}"
echo -e "${BOLD}${GREEN}============================================${NC}"
echo ""
log "PAI:          ~/.claude/"
log "Portal:       http://localhost:8080"
log "Voice:        http://localhost:8888 (notification endpoint)"
log "Work:         ~/work/"
log "Upstream:     ~/upstream/"
log "Companion:    ~/pai-companion/"
log "Server logs:  ~/portal/server.log, ~/voice-server/server.log"
echo ""
warn "Next steps:"
warn "  1. Run 'claude' to authenticate with your Anthropic API key"
warn "  2. Visit http://${VM_IP}:8080 from your Mac browser"
warn "  3. Start using PAI: source ~/.bashrc && pai"
echo ""
