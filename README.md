# pai-lima

PAI + PAI Companion running on a Lima VM (Ubuntu 24.04 ARM64) with audio passthrough on Apple Silicon. No Docker.

## What This Sets Up

- **Lima VM** — Ubuntu 24.04 server on Apple's Virtualization.framework (VZ)
- **Audio** — VirtIO sound device passed through to macOS speakers
- **PAI v4.0** — [Personal AI Infrastructure](https://github.com/danielmiessler/Personal_AI_Infrastructure)
- **PAI Companion** — [Web portal, file exchange, context enhancements](https://github.com/chriscantey/pai-companion) (portal served via Bun, not Docker)
- **Shared folder** — `/home/claude/workspace` in VM shared with Mac as `~/claude-workspace`

## Prerequisites

- macOS 13+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4)
- [Homebrew](https://brew.sh) (recommended) or manual install
- An Anthropic API key for Claude Code

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/quinn-pai/pai-lima.git
cd pai-lima

# 2. Install Lima
brew install lima

# 3. Create and start the VM
limactl create --name=pai pai.yaml
limactl start pai

# 4. Copy the install script into the VM and run it
limactl cp install.sh pai:~/install.sh
limactl shell pai
bash ~/install.sh
```

## Installing Lima

### Option A: Homebrew (recommended)

```bash
brew install lima
```

Verify:

```bash
limactl --version
# lima version 2.0.3
```

### Option B: Manual Install

Download the latest release from [lima-vm/lima/releases](https://github.com/lima-vm/lima/releases).

```bash
# Download the ARM64 macOS binary
curl -LO https://github.com/lima-vm/lima/releases/download/v2.0.3/lima-2.0.3-Darwin-arm64.tar.gz

# Extract
tar xzf lima-2.0.3-Darwin-arm64.tar.gz

# Move binaries to your PATH
sudo mv bin/limactl /usr/local/bin/
sudo mv share/lima /usr/local/share/lima

# Verify
limactl --version
```

## Creating the VM

### 1. Create the VM

```bash
limactl create --name=pai pai.yaml
```

This downloads the Ubuntu 24.04 ARM64 cloud image (~700MB, cached after first download) and configures the VM with:

| Setting | Value |
|---------|-------|
| VM engine | VZ (Apple Virtualization.framework) |
| Image | Ubuntu 24.04 ARM64 cloud image |
| User | `claude` (uid 1000) |
| Hostname | `pai` |
| CPUs | 4 |
| Memory | 4 GiB |
| Disk | 40 GiB |
| Audio | VirtIO sound (VZ) → macOS speakers |
| Shared folder | `/home/claude/workspace` → `~/claude-workspace` (reverse mount) |

### 2. Start the VM

```bash
limactl start pai
```

First boot runs provisioning (installs audio drivers, ALSA, PulseAudio, CLI tools). Takes 2-3 minutes.

### 3. Shell in

```bash
limactl shell pai
```

You should see:

```
claude@pai:~$
```

## Installing PAI + PAI Companion

From inside the VM:

```bash
bash ~/install.sh
```

The script installs (in order):

1. **System packages** — curl, git, zip, jq, tree, tmux, ffmpeg, imagemagick, etc.
2. **Bun** — JavaScript runtime
3. **Claude Code** — Anthropic's CLI
4. **PAI v4.0** — clones the latest release and runs the installer in CLI mode
5. **PAI Companion** — clones the companion repo, sets up portal/exchange/work directories, starts the portal web server on port 8080 using Bun (no Docker)
6. **Playwright** — browser automation with Chromium

### After installation

```bash
# Authenticate Claude Code
claude

# Activate PAI
source ~/.bashrc
pai
```

### Access the companion portal

From your Mac browser, visit:

```
http://<vm-ip>:8080
```

Find the VM's IP with:

```bash
limactl shell pai -- hostname -I
```

## Verifying Audio

```bash
limactl shell pai

# Check sound card
sudo aplay -l
# Should show: card 1: SoundCard_1 [VirtIO SoundCard]

# Play a test tone (should come through your Mac speakers)
sudo speaker-test -D plughw:1,0 -t sine -f 440 -l 1 -p 2
```

> **Note:** The `audio.device` field is marked experimental in Lima 2.0.3. If `aplay -l` shows no devices, verify `linux-modules-extra` is installed and `virtio_snd` is loaded:
>
> ```bash
> sudo apt-get install -y linux-modules-extra-$(uname -r)
> sudo modprobe virtio_snd
> ```

## VM Management

```bash
# Stop the VM
limactl stop pai

# Start it again
limactl start pai

# Delete and recreate
limactl delete pai --force
limactl create --name=pai pai.yaml
limactl start pai

# List VMs
limactl list
```

## Directory Layout (inside VM)

```
~/                          Home directory (/home/claude)
~/workspace/                Shared with macOS as ~/claude-workspace
~/workspace/portal/         Companion web portal (served on :8080)
~/workspace/exchange/       File exchange directory
~/workspace/work/           Project workspace (git tracked)
~/workspace/data/           Data storage
~/workspace/upstream/       Reference repos (PAI, TheAlgorithm)
~/.claude/                  PAI configuration and skills
```

## Troubleshooting

**VM won't start:** Make sure no other Lima instance named `pai` exists. Run `limactl delete pai --force` first.

**No audio:** The Ubuntu cloud image doesn't ship `linux-modules-extra`. The provisioning script installs it, but if it fails, run manually: `sudo apt-get install -y linux-modules-extra-$(uname -r) && sudo modprobe virtio_snd`

**aplay works with sudo but not as claude:** Log out and back in (`exit` then `limactl shell pai`) to refresh group membership after provisioning.

**Portal not accessible:** Check the service is running: `systemctl --user status pai-portal`. Get the VM IP: `hostname -I`.

**Shared folder not visible:** The VM's `/home/claude/workspace` is reverse-mounted to `~/claude-workspace` on macOS. Ensure the VM is running (`limactl list`) and check that the mount is active.

## Credits

- [Lima](https://lima-vm.io/) — Linux VMs on macOS
- [PAI](https://github.com/danielmiessler/Personal_AI_Infrastructure) — Personal AI Infrastructure by Daniel Miessler
- [PAI Companion](https://github.com/chriscantey/pai-companion) — Companion package by Chris Cantey
