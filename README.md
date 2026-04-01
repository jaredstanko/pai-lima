# pai-lima

A sandboxed AI workspace running Claude Code in an isolated VM on your Mac. One script to install, then a menu bar app to control everything.

## What You Get

- **Sandboxed AI** — Claude Code runs inside an isolated VM, not on your Mac
- **Menu bar control** — Start sessions, stop the VM, open the web portal — all from one icon
- **Session resume** — Pick up previous conversations where you left off
- **Shared folders** — Drop files in `~/pai-workspace/` and the AI can access them
- **Audio** — The AI can speak through your Mac speakers

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4)
- An Anthropic API key for Claude Code

## Install

```bash
git clone https://github.com/jaredstanko/pai-lima.git
cd pai-lima
./install.sh
```

That's it. The installer handles everything: tools, VM, provisioning, and the menu bar app. Takes about 5-10 minutes on a fresh machine.

The install is **deterministic** — every dependency version is pinned in `versions.env`, so you get the same result every time, on every machine.

### Install options

```bash
./install.sh              # Normal install
./install.sh --verbose    # Show detailed output
```

## Using PAI

After install, **PAI-Status appears in your menu bar** (top right). This is your control center.

### First time

1. Click the **PAI icon** in your menu bar
2. Click **New PAI Session** — a terminal window opens
3. Run `claude` and enter your Anthropic API key when prompted
4. You're in. Start talking to Claude.

### From then on

Click the PAI icon and choose what you need:

```
● PAI                          ← green = running, red = stopped
├─ VM: Running
├─ Start VM / Stop VM
├─ ─────────────────────────
├─ New PAI Session…            ← start a new AI workspace
├─ Active Sessions
│   └─ Resume Session…         ← pick up where you left off
├─ ─────────────────────────
├─ Open PAI Web                ← web portal and dashboards
├─ Open a Terminal             ← plain shell (no AI)
├─ ─────────────────────────
├─ Launch at Login ☐           ← start PAI-Status automatically
└─ Quit PAI-Status
```

**Tip:** Check **Launch at Login** so PAI-Status is always ready when you open your Mac. The VM doesn't auto-start — you still click Start VM when you're ready to work.

## Shared Files

Your Mac and the AI sandbox share files through `~/pai-workspace/`:

```
~/pai-workspace/
├─ exchange/    Drop files here — the AI reads them at ~/exchange/
├─ work/        AI outputs and projects appear here
├─ data/        Datasets, databases
├─ portal/      Web portal files
├─ claude-home/ AI configuration (settings, memory, sessions)
└─ upstream/    Reference repos
```

Your data lives on your Mac, not inside the VM. You can destroy and recreate the VM without losing anything.

---

## Advanced

Everything below is for users who want to understand the internals, customize the setup, or use CLI tools instead of the menu bar app.

### CLI Fallback

If you prefer the terminal over the menu bar:

```bash
./scripts/launch.sh              # New PAI session
./scripts/launch.sh --resume     # Resume a previous session
./scripts/launch.sh --shell      # Plain shell in the VM
```

### Version Pinning

All dependency versions are declared in `versions.env`:

```bash
BUN_VERSION="1.3.11"
CLAUDE_CODE_VERSION="2.1.89"
PLAYWRIGHT_VERSION="1.59.0"
# ... plus Ubuntu image URL, PAI repo commit, apt packages
```

To update versions, edit `versions.env` and re-run `./install.sh`.

### Verification

Run `./scripts/verify.sh` anytime to check system health:

- **PINNED** — version matches the manifest exactly
- **DRIFTED** — installed but version differs (e.g., Claude Code auto-updated)
- **FAILED** — component missing or broken

### Upgrading

```bash
cd pai-lima
git pull
./scripts/upgrade.sh
```

Your workspace, authentication, and sessions are preserved.

### Backup & Restore

```bash
./scripts/backup-restore.sh backup pai     # Back up VM + workspace
./scripts/backup-restore.sh restore pai    # Restore from a backup
```

### Uninstall

```bash
./scripts/uninstall.sh
```

Removes the VM, menu bar app, and launch agents. Asks before touching `~/pai-workspace/`.

### PAI Companion (Web Portal)

After authenticating Claude Code, open a session and ask:

> Install PAI Companion following ~/pai-companion/companion/INSTALL.md. Skip Docker (use Bun directly) and skip the voice module.

### VM Specs

| Setting | Default |
|---------|---------|
| VM engine | VZ (Apple Virtualization.framework) |
| OS | Ubuntu 24.04 ARM64 |
| CPUs | 4 |
| Memory | 4 GB |
| Disk | 50 GB |
| Audio | VirtIO sound device |

To resize an existing VM:

```bash
limactl stop pai
limactl edit pai --cpus 6 --memory 6
limactl start pai
```

Edit `pai.yaml` before running `./install.sh` to change defaults for new installs.

### Project Structure

```
pai-lima/
├─ install.sh               The installer (run this)
├─ versions.env             Pinned dependency versions
├─ pai.yaml                 VM configuration
├─ scripts/
│  ├─ provision-vm.sh       VM provisioning (called by installer)
│  ├─ verify.sh             System health check
│  ├─ launch.sh             CLI: open a PAI session
│  ├─ upgrade.sh            Upgrade existing install
│  ├─ uninstall.sh          Remove everything
│  └─ backup-restore.sh     Backup and restore
├─ config/
│  ├─ kitty.conf            Terminal configuration
│  └─ portal.webloc         Portal bookmark
├─ menubar/
│  ├─ PAIStatus.swift       Menu bar app source
│  ├─ build.sh              Compile script
│  └─ Info.plist             App metadata
└─ README.md
```

### Troubleshooting

**Install fails at "Creating sandbox VM"** — Run `limactl delete pai --force` and re-run `./install.sh`.

**PAI-Status not in menu bar** — Run `open /Applications/PAI-Status.app` or rebuild: `cd menubar && ./build.sh --install`.

**No audio** — Inside the VM: `sudo modprobe virtio_snd`.

**Shared folders not visible** — Run `mkdir -p ~/pai-workspace/{claude-home,data,exchange,portal,upstream,work}`.

## Credits

- [Lima](https://lima-vm.io/) — Linux VMs on macOS
- [PAI](https://github.com/danielmiessler/Personal_AI_Infrastructure) — Personal AI Infrastructure by Daniel Miessler
- [PAI Companion](https://github.com/chriscantey/pai-companion) — Companion package by Chris Cantey
- [kitty](https://sw.kovidgoyal.net/kitty/) — GPU-accelerated terminal emulator
