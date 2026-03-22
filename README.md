# pai-lima

A sandboxed AI workspace running PAI + Claude Code on a Lima VM (Ubuntu 24.04 ARM64) with audio passthrough on Apple Silicon. No Docker.

## What You Get

- **Sandboxed VM** — Claude Code runs in an isolated Ubuntu VM, not on your Mac
- **PAI v4.0** — [Personal AI Infrastructure](https://github.com/danielmiessler/Personal_AI_Infrastructure) with skills, tools, and memory
- **PAI Companion** — [Web portal](https://github.com/chriscantey/pai-companion) at `http://localhost:8080` for dashboards and file exchange
- **Menu bar app** — PAI-Status shows VM status, starts/stops the VM, and launches sessions
- **Session resume** — Claude Code sessions can be resumed with `claude -r` after closing
- **Shared folders** — `~/pai-workspace/` on your Mac is shared with the VM for file exchange
- **Audio passthrough** — VirtIO sound device routes VM audio to your Mac speakers

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4)
- An Anthropic API key for Claude Code

That's it. The installer handles everything else (Homebrew, Lima, kitty, etc.).

## Install

```bash
git clone https://github.com/jaredstanko/pai-lima.git
cd pai-lima
./setup-host.sh
```

The installer walks you through 9 steps:

1. Checks system requirements (macOS, Apple Silicon, Homebrew, Xcode CLI tools)
2. Installs Lima and kitty
3. Creates `~/pai-workspace/` shared directories
4. Creates and starts the Lima VM
5. Provisions the VM (Claude Code, PAI, tools — takes 3-5 minutes on first run)
6. Configures kitty terminal settings
7. Builds and installs the PAI-Status menu bar app
8. Creates a portal bookmark on your Desktop
9. Provides authentication instructions

After setup completes, you'll see PAI-Status in your menu bar.

## Daily Use

Everything is controlled from the **PAI-Status menu bar icon** — no terminal commands needed.

### Start a session

1. Click the PAI icon in your menu bar
2. Click **Start VM** — wait for the green dot
3. Click **New PAI Session…** — a kitty window opens with PAI running in the VM

To resume a previous session, go to **Active Sessions → Resume Session…** which opens Claude Code's interactive session picker.

### Menu bar controls

```
● PAI                          ← green dot = running, red = stopped
├─ VM: Running                 ← current VM status
├─ Start VM                    ← start the Lima VM
├─ Stop VM                     ← gracefully stop the VM
├─ Restart VM                  ← stop then start the VM
├─ ─────────────────────────
├─ New PAI Session…            ← open kitty with PAI in the VM
├─ Active Sessions             ← submenu
│   └─ Resume Session…         ← pick a previous session to resume
├─ ─────────────────────────
├─ Open PAI Web                ← opens http://localhost:8080
├─ Open a Terminal             ← plain shell in kitty
├─ ─────────────────────────
├─ Launch at Login ☐           ← toggle: start PAI-Status on login
└─ Quit PAI-Status
```

### Menu options explained

| Menu Item | Description |
|-----------|-------------|
| **VM: Running/Stopped** | Shows the current state of the Lima VM. Updates every 5 seconds. |
| **Start VM** | Starts the Lima VM (`limactl start pai`). Disabled when the VM is already running or transitioning. |
| **Stop VM** | Gracefully stops the VM (`limactl stop pai`). Disabled when the VM is already stopped or transitioning. |
| **Restart VM** | Stops then starts the VM in sequence. Useful after configuration changes. Disabled when the VM is stopped. |
| **New PAI Session…** | Opens a kitty window that connects to the VM and launches PAI (Claude Code). Each session runs in its own kitty window. |
| **Active Sessions → Resume Session…** | Opens a kitty window with Claude Code's interactive session picker (`claude -r`). Select a previous session to resume where you left off. |
| **Open PAI Web** | Opens the PAI Companion web portal at `http://localhost:8080` in your default browser. The portal provides dashboards, reports, and a file exchange UI. |
| **Open a Terminal** | Opens a kitty window with a plain shell connected to the VM — no PAI, no Claude Code. Useful for manual VM administration. |
| **Launch at Login** | Toggle to auto-start PAI-Status when you log in to your Mac. Installs a LaunchAgent. The VM does not auto-start — you still click "Start VM" when ready. |
| **Quit PAI-Status** | Exits the menu bar app. Does not stop the VM — your VM continues running. |

### Launch at Login

Enable **Launch at Login** in the menu to have PAI-Status start automatically when you open your Mac. The VM won't auto-start — you still click "Start VM" when you're ready.

## Shared Files

Your Mac and the VM share files through `~/pai-workspace/`:

```
~/pai-workspace/
├─ exchange/    Drop files here → AI reads them at ~/exchange/
├─ work/        AI outputs appear here (git-tracked)
├─ data/        Datasets, databases
├─ portal/      Web portal files
├─ claude-home/ PAI configuration (~/.claude/ in the VM)
└─ upstream/    Reference repos (PAI, TheAlgorithm)
```

Files placed in `exchange/` are immediately visible inside the VM. Files the AI creates in `work/` are immediately visible on your Mac.

## Portal

The PAI Companion portal runs inside the VM on port 8080, forwarded to your Mac at:

```
http://localhost:8080
```

A bookmark is placed on your Desktop during setup. You can also click **Open PAI Web** in the menu bar.

## CLI Fallback

The menu bar app is the primary interface, but shell scripts are available if you prefer the terminal:

```bash
# Launch a new PAI session
./launch-host.sh

# Resume a previous session (interactive picker)
./launch-host.sh --resume

# Open a plain shell in the VM
./launch-host.sh --shell

# Or use session.sh for the same options
./session-host.sh
./session-host.sh --resume
./session-host.sh --shell
```

## How Sessions Work

Each session opens a kitty window connected directly to the VM running Claude Code.

```
PAI-Status (macOS)        kitty window          Lima VM (Ubuntu)
┌──────────────────┐      ┌──────────────┐      ┌──────────────────┐
│ New PAI Session   │─────▶│ kitty        │─────▶│ Claude Code      │
│                   │      │              │      │ (PAI)            │
└──────────────────┘      └──────────────┘      └──────────────────┘
```

- Closing the kitty window ends the Claude Code process
- Sessions can be resumed later with **Resume Session…** or `claude -r`
- Claude Code's `--resume` restores your full conversation context

## Keyboard Shortcuts

These work in kitty by default. Configuration is at `~/.config/kitty/kitty.conf` (installed by setup).

| Key | Function |
|-----|----------|
| Shift+Enter | Newline in Claude Code input (multi-line prompts) |
| Ctrl+C | Interrupt command |
| Escape | Cancel Claude Code input |
| Ctrl+Shift+T | New kitty tab |
| Ctrl+Shift+N | New kitty window |

## Audio

The VM has VirtIO audio passed through to your Mac speakers.

```bash
# Test audio (from inside the VM)
limactl shell pai
sudo speaker-test -D plughw:1,0 -t sine -f 440 -l 1 -p 2
```

If `aplay -l` shows no devices:
```bash
sudo apt-get install -y linux-modules-extra-$(uname -r)
sudo modprobe virtio_snd
```

## Upgrading

If you already have a "pai" VM and want to update without losing data:

```bash
cd pai-lima
git pull
./upgrade-host.sh
```

This safely upgrades:
- Host tools (Lima, kitty)
- PAI-Status menu bar app (rebuilt with latest features)
- VM networking (adds vzNAT + localhost:8080 port forwarding if missing)
- VM system packages and shell aliases
- Portal bookmark

**What's preserved** — your workspace files, Claude Code authentication, PAI config, and everything in `~/pai-workspace/`.

The VM will be briefly stopped and restarted if networking changes are needed.

## VM Management

```bash
# Stop the VM
limactl stop pai

# Start the VM
limactl start pai

# SSH into the VM
limactl shell pai

# Delete and recreate from scratch
limactl delete pai --force
./setup-host.sh
```

## VM Specs

| Setting | Default |
|---------|---------|
| VM engine | VZ (Apple Virtualization.framework) |
| OS | Ubuntu 24.04 ARM64 |
| User | `claude` |
| CPUs | 4 |
| Memory | 4 GB |
| Disk | 40 GB |
| Audio | VirtIO → macOS speakers |
| Networking | vzNAT (portal forwarded to localhost:8080) |

### Sizing for Your Hardware

The defaults (4 CPU, 4 GB RAM) work well for 1-2 concurrent Claude Code sessions. Claude Code is mostly I/O-bound (waiting on the Anthropic API), so CPU is rarely the bottleneck — RAM is what matters as you add sessions.

**Per session, Claude Code uses roughly:**
- 100-150 MB idle (Node.js process waiting for input)
- 200-300 MB active (running tools like ripgrep, git, file reads)
- Brief CPU spikes during tool execution, near-zero otherwise

**If Claude Code spawns subagents** (parallel research, council debates, etc.), a single session can temporarily fork 3-5 additional processes. Plan for the peak, not the idle.

**Recommended settings by workload:**

| Concurrent Sessions | CPUs | Memory | Host RAM Needed |
|---------------------|------|--------|-----------------|
| 1-2 | 4 | 4 GB | 8 GB+ (e.g., MacBook Air M1 8 GB) |
| 3-4 | 4 | 6 GB | 16 GB+ (e.g., MacBook Air M3 16 GB) |
| 5-8 | 6 | 8 GB | 24 GB+ (e.g., MacBook Pro M3 24 GB) |
| 8+ with heavy subagents | 8 | 12 GB | 32 GB+ (e.g., MacBook Pro M3 Max) |

**Rule of thumb:** Give the VM no more than half your total RAM. macOS needs 4-5 GB for itself plus whatever apps you run alongside.

**To change the defaults**, edit `pai.yaml` before running `setup-host.sh`:

```yaml
cpus: 6
memory: 6144MiB   # 6 GB
```

**To resize an existing VM** without losing data:

```bash
limactl stop pai
limactl edit pai --cpus 6 --memory 6
limactl start pai
```

## What Gets Installed in the VM

- **Claude Code** — Anthropic's CLI
- **PAI v4.0** — Personal AI Infrastructure
- **Bun** — JavaScript runtime (portal server)
- **Playwright** — browser automation with Chromium
- **System tools** — git, curl, jq, ripgrep, fzf, bat, imagemagick, ffmpeg, python3, golang, nmap, whois, dnsutils, pandoc, yt-dlp, sqlite3, and more

## Project Structure

```
pai-lima/
├─ setup-host.sh       Guided installer (run this first time)
├─ upgrade-host.sh          Safe upgrade for existing installs
├─ provision-vm.sh        VM-side provisioning (called by installer)
├─ pai.yaml            Lima VM configuration
├─ launch-host.sh           CLI: launch PAI session (menu bar alternative)
├─ session-host.sh          CLI: launch/resume sessions
├─ config/
│  ├─ kitty.conf       kitty terminal configuration
│  └─ portal.webloc    Portal bookmark template
├─ menubar/
│  ├─ PAIStatus.swift  Menu bar app source
│  ├─ build.sh         Compile and install script
│  └─ Info.plist       App bundle metadata
└─ README.md           This file
```

## Troubleshooting

**Setup fails at "Creating sandbox VM"** — Make sure no existing VM named "pai" is in a bad state. Run `limactl delete pai --force` and re-run `./setup-host.sh`.

**PAI-Status not in menu bar** — Run `open /Applications/PAI-Status.app` or rebuild: `cd menubar && ./build.sh --install`.

**Portal not loading at localhost:8080** — Check the service inside the VM: `limactl shell pai -- systemctl --user status pai-portal`. The VM must be running and vzNAT networking must be enabled (it is by default in pai.yaml).

**No audio** — The provisioning script installs audio drivers, but if it failed: `limactl shell pai -- sudo modprobe virtio_snd`. Log out and back in to refresh group membership.

**Shared folders not visible** — Ensure `~/pai-workspace/` exists on your Mac. The installer creates it, but if missing: `mkdir -p ~/pai-workspace/{claude-home,data,exchange,portal,upstream,work}`.

**Shift+Enter doesn't work in Claude Code** — Check kitty config at `~/.config/kitty/kitty.conf`. The `map shift+enter send_text all \x1b[13;2u` line should be present.

**aplay works with sudo but not as claude** — Log out of the VM and back in (`exit` then `limactl shell pai`) to refresh group membership.

## Credits

- [Lima](https://lima-vm.io/) — Linux VMs on macOS
- [PAI](https://github.com/danielmiessler/Personal_AI_Infrastructure) — Personal AI Infrastructure by Daniel Miessler
- [PAI Companion](https://github.com/chriscantey/pai-companion) — Companion package by Chris Cantey
- [kitty](https://sw.kovidgoyal.net/kitty/) — GPU-accelerated terminal emulator
