# pai-lima

A sandboxed AI workspace running PAI + Claude Code in an isolated environment with audio passthrough. Supports macOS (Lima VM) and Linux (Docker — planned).

## Platform Support

| Platform | Backend | Status |
|----------|---------|--------|
| **macOS (Apple Silicon)** | Lima VM (Ubuntu 24.04 ARM64, VZ framework) | Available |
| **Linux** | Docker container | Planned |

**Why two backends?** Lima uses Apple's Virtualization.framework for near-native VM performance on macOS, but it's macOS-only. On Linux hosts, running a Linux VM inside Linux adds unnecessary overhead — Docker containers provide the same isolation with instant startup, shared memory, and native filesystem speed. The PAI Companion project was designed for Docker, so the Linux path uses it as-is.

## What You Get

- **Sandboxed environment** — Claude Code runs in isolation, not on your host
- **PAI v4.0** — [Personal AI Infrastructure](https://github.com/danielmiessler/Personal_AI_Infrastructure) with skills, tools, and memory
- **PAI Companion** — [Web portal](https://github.com/chriscantey/pai-companion) for dashboards and file exchange (installed by Claude after setup)
- **Menu bar app** (macOS) — PAI-Status shows VM status, starts/stops the VM, and launches sessions
- **Session resume** — Claude Code sessions can be resumed with `claude -r` after closing
- **Shared folders** — `~/pai-workspace/` on your host is shared with the sandbox
- **Audio passthrough** (macOS) — VirtIO sound device routes VM audio to your Mac speakers

## Requirements

### macOS
- macOS 13+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4)
- An Anthropic API key for Claude Code

### Linux (planned)
- Docker installed and working without sudo
- An Anthropic API key for Claude Code

## Install (macOS)

```bash
git clone https://github.com/jaredstanko/pai-lima.git
cd pai-lima
./setup-host.sh
```

That's it. One command after cloning. The installer is **deterministic** — every dependency version is pinned in `versions.env`, so fresh installs on different machines converge to the same end state.

### What the installer does (10 steps)

1. Checks system requirements (macOS, Apple Silicon, Homebrew, Xcode CLI tools)
2. Installs Lima, kitty, and Hack Nerd Font
3. Creates `~/pai-workspace/` shared directories
4. Creates and starts the Lima VM (Ubuntu 24.04, pinned image)
5. Reboots VM and tests audio passthrough
6. Provisions the VM with pinned versions (Claude Code, PAI, Bun, Playwright, tools)
7. Configures kitty terminal settings
8. Builds and installs the PAI-Status menu bar app
9. Creates a portal bookmark on your Desktop
10. Runs end-state verification and provides authentication instructions

### Version Pinning

All dependency versions are declared in `versions.env` — the single source of truth:

```bash
BUN_VERSION="1.3.11"
CLAUDE_CODE_VERSION="2.1.89"
PLAYWRIGHT_VERSION="1.50.0"
# ... plus Ubuntu image URL, PAI repo commit, apt packages
```

To update versions, edit `versions.env` and re-run `./setup-host.sh`. Run `./verify.sh` to check system state at any time.

### Verification

After install (or anytime), run `./verify.sh` for a 3-state health check:

- **PINNED** — version matches the manifest exactly
- **DRIFTED** — installed but version differs (e.g., Claude Code auto-updated)
- **FAILED** — component missing or broken

### Options

```bash
./setup-host.sh              # Normal install (progress phases)
./setup-host.sh --verbose    # Show full output from each step
```

### After Setup: Install PAI Companion

Once provisioning completes, open a terminal in the VM, authenticate Claude Code, then ask Claude:

> Install PAI Companion following ~/pai-companion/companion/INSTALL.md. Skip Docker (use Bun directly) and skip the voice module.

Claude will follow the companion's installation guide interactively, adapting for the Lima environment.

## Install (Linux — planned)

```bash
git clone https://github.com/jaredstanko/pai-lima.git
cd pai-lima
./setup-docker.sh
```

The Docker path will:
- Build an Ubuntu 24.04 container with PAI, Claude Code, and tools
- Mount `~/pai-workspace/` for shared files
- Run PAI Companion natively (Docker-based, as designed)
- Forward ports 8080 (portal) and 8888 (voice)

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
| **New PAI Session…** | Opens a kitty window that connects to the VM and launches PAI (Claude Code). Each session runs in its own kitty window. |
| **Active Sessions → Resume Session…** | Opens a kitty window with Claude Code's interactive session picker (`claude -r`). Select a previous session to resume where you left off. |
| **Open PAI Web** | Opens the PAI Companion web portal at `http://localhost:8080` in your default browser. |
| **Open a Terminal** | Opens a kitty window with a plain shell connected to the VM. Useful for manual VM administration. |
| **Launch at Login** | Toggle to auto-start PAI-Status when you log in to your Mac. Installs a LaunchAgent. The VM does not auto-start — you still click "Start VM" when ready. |
| **Quit PAI-Status** | Exits the menu bar app. Does not stop the VM — your VM continues running. |

## Shared Files

Your host and the sandbox share files through `~/pai-workspace/`:

```
~/pai-workspace/
├─ exchange/    Drop files here → AI reads them at ~/exchange/
├─ work/        AI outputs appear here (git-tracked)
├─ data/        Datasets, databases
├─ portal/      Web portal files
├─ claude-home/ PAI configuration (~/.claude/ in the VM)
└─ upstream/    Reference repos (PAI, TheAlgorithm)
```

**Data lives on the host.** The VM mounts these directories — destroying and recreating the VM loses nothing.

## CLI Fallback

The menu bar app is the primary interface, but shell scripts are available if you prefer the terminal:

```bash
./launch-host.sh              # New PAI session
./launch-host.sh --resume     # Resume a previous session
./launch-host.sh --shell      # Plain shell in the VM
./session-host.sh             # Same options
```

## Backup & Restore

```bash
./vm-backup-restore.sh backup pai     # Back up VM + workspace
./vm-backup-restore.sh restore pai    # Restore from a backup
```

Backups include the Lima VM instance, global config, and workspace. Restore prompts before overwriting existing data.

## Upgrading

```bash
cd pai-lima
git pull
./upgrade-host.sh
```

Upgrades host tools, PAI-Status app, VM packages, shell environment, and Claude Code. Your workspace, authentication, and sessions are preserved.

## Cleanup

```bash
./cleanup-host.sh
```

Removes the Lima VM, PAI-Status app (all name variants), launch agents, and bookmarks. Asks before touching `~/pai-workspace/`. Does not uninstall Lima, kitty, fonts, or Homebrew.

## VM Specs

| Setting | Default |
|---------|---------|
| VM engine | VZ (Apple Virtualization.framework) |
| OS | Ubuntu 24.04 ARM64 |
| User | `claude` |
| CPUs | 4 |
| Memory | 4 GB |
| Disk | 50 GB |
| Audio | VirtIO → macOS speakers |
| Networking | vzNAT (ports 8080, 8888 forwarded to localhost) |

### Sizing for Your Hardware

The defaults (4 CPU, 4 GB RAM) work well for 1-2 concurrent Claude Code sessions. Claude Code is mostly I/O-bound (waiting on the Anthropic API), so CPU is rarely the bottleneck — RAM is what matters.

| Concurrent Sessions | CPUs | Memory | Host RAM Needed |
|---------------------|------|--------|-----------------|
| 1-2 | 4 | 4 GB | 8 GB+ |
| 3-4 | 4 | 6 GB | 16 GB+ |
| 5-8 | 6 | 8 GB | 24 GB+ |
| 8+ with subagents | 8 | 12 GB | 32 GB+ |

To change defaults, edit `pai.yaml` before running `setup-host.sh`. To resize an existing VM:

```bash
limactl stop pai
limactl edit pai --cpus 6 --memory 6
limactl start pai
```

## Project Structure

```
pai-lima/
├─ versions.env             Version manifest (single source of truth)
├─ setup-host.sh            Deterministic installer (run first)
├─ provision-vm.sh          VM-side provisioning (called by installer)
├─ verify.sh                End-state verification (3-state health check)
├─ upgrade-host.sh          Safe upgrade for existing installs
├─ cleanup-host.sh          Remove everything (asks before data)
├─ vm-backup-restore.sh     Backup and restore Lima VM + workspace
├─ pai.yaml                 Lima VM configuration (pinned Ubuntu image)
├─ launch-host.sh           CLI: launch PAI session
├─ session-host.sh          CLI: launch/resume sessions
├─ config/
│  ├─ kitty.conf            kitty terminal configuration
│  └─ portal.webloc         Portal bookmark template
├─ menubar/
│  ├─ PAIStatus.swift       Menu bar app source
│  ├─ build.sh              Compile and install script
│  └─ Info.plist            App bundle metadata
└─ README.md                This file
```

## Troubleshooting

**Setup fails at "Creating sandbox VM"** — Run `limactl delete pai --force` and re-run `./setup-host.sh`.

**PAI-Status not in menu bar** — Run `open /Applications/PAI-Status.app` or rebuild: `cd menubar && ./build.sh --install`.

**No audio** — Inside the VM: `sudo modprobe virtio_snd`. Log out and back in to refresh group membership.

**Shared folders not visible** — Ensure `~/pai-workspace/` exists: `mkdir -p ~/pai-workspace/{claude-home,data,exchange,portal,upstream,work}`.

**Shift+Enter doesn't work** — Check `~/.config/kitty/kitty.conf` is installed.

## Credits

- [Lima](https://lima-vm.io/) — Linux VMs on macOS
- [PAI](https://github.com/danielmiessler/Personal_AI_Infrastructure) — Personal AI Infrastructure by Daniel Miessler
- [PAI Companion](https://github.com/chriscantey/pai-companion) — Companion package by Chris Cantey
- [kitty](https://sw.kovidgoyal.net/kitty/) — GPU-accelerated terminal emulator
