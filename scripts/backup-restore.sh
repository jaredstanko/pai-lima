#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared instance configuration (sets VM_NAME, WORKSPACE, etc.)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

LIMA_HOME="${LIMA_HOME:-$HOME/.lima}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$WORKSPACE}"
BACKUP_DIR="$SCRIPT_DIR"
BACKUP_PREFIX="backup-vm-"

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: $(basename "$0") <subcommand> [--name=X]"
  echo ""
  echo "Subcommands:"
  echo "  backup              Back up the Lima VM and workspace"
  echo "  restore             Restore from a backup"
  echo ""
  echo "Options:"
  echo "  --name=X            Target a named instance (default: pai)"
  echo ""
  echo "Backups are stored in: $BACKUP_DIR/$BACKUP_PREFIX<date>-<vm-name>/"
  exit 1
}

list_vms() {
  limactl list --format '{{.Name}}' 2>/dev/null || true
}

pick_vm() {
  local vms
  vms=$(list_vms)

  if [[ -z "$vms" ]]; then
    echo "No Lima VMs found." >&2
    exit 1
  fi

  echo "Available VMs:" >&2
  local i=1
  local vm_array=()
  while IFS= read -r vm; do
    echo "  $i) $vm" >&2
    vm_array+=("$vm")
    ((i++))
  done <<< "$vms"

  printf "Select VM number: " >&2
  read -r choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#vm_array[@]} )); then
    echo "Invalid selection." >&2
    exit 1
  fi

  echo "${vm_array[$((choice - 1))]}"
}

pick_backup() {
  local vm_name="$1"
  local pattern="$BACKUP_DIR/${BACKUP_PREFIX}*-${vm_name}"
  local backups=()

  while IFS= read -r -d '' dir; do
    backups+=("$dir")
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name "${BACKUP_PREFIX}*-${vm_name}" -print0 | sort -z)

  if [[ ${#backups[@]} -eq 0 ]]; then
    echo "No backups found for VM '$vm_name'." >&2
    exit 1
  fi

  echo "Available backups for '$vm_name':" >&2
  local i=1
  for b in "${backups[@]}"; do
    local size
    size=$(du -sh "$b" 2>/dev/null | cut -f1)
    echo "  $i) $(basename "$b")  [$size]" >&2
    ((i++))
  done

  printf "Select backup number: " >&2
  read -r choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
    echo "Invalid selection." >&2
    exit 1
  fi

  echo "${backups[$((choice - 1))]}"
}

# ── Ownership fix ─────────────────────────────────────────────────────────────
fix_ownership() {
  local target="$1"
  local current_user current_group
  current_user="$(id -un)"
  current_group="$(id -gn)"
  echo "→ Fixing ownership on: $target"
  # chown -R requires sudo if any files are owned by root (e.g. VM disk images)
  if chown -R "${current_user}:${current_group}" "$target" 2>/dev/null; then
    :
  else
    echo "  (retrying with sudo...)"
    sudo chown -R "${current_user}:${current_group}" "$target"
  fi
  # Restore sane permissions: dirs 755, files 644, executables kept executable
  find "$target" -type d -exec chmod 755 {} +
  find "$target" -type f ! -perm /111 -exec chmod 644 {} +
  find "$target" -type f -perm /111 -exec chmod 755 {} +
}

# ── Backup ────────────────────────────────────────────────────────────────────
do_backup() {
  local vm_name="${1:-}"

  if [[ -z "$vm_name" ]]; then
    vm_name=$(pick_vm)
  fi

  local vm_dir="$LIMA_HOME/$vm_name"
  if [[ ! -d "$vm_dir" ]]; then
    echo "Error: VM directory not found: $vm_dir" >&2
    exit 1
  fi

  local date_stamp
  date_stamp=$(date +%Y%m%d-%H%M%S)
  local dest="$BACKUP_DIR/${BACKUP_PREFIX}${date_stamp}-${vm_name}"

  local was_running=false
  local status
  status=$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v vm="$vm_name" '$1 == vm {print $2}')

  if [[ "$status" == "Running" ]]; then
    echo "→ VM '$vm_name' is running. Stopping it for a clean backup..."
    limactl stop "$vm_name"
    was_running=true
  fi

  echo "→ Backing up '$vm_name' to: $(basename "$dest")"
  mkdir -p "$dest"

  # Copy VM instance dir (copy-on-write clone where possible)
  cp -rc "$vm_dir" "$dest/instance"

  # Copy global config
  if [[ -d "$LIMA_HOME/_config" ]]; then
    cp -rc "$LIMA_HOME/_config" "$dest/_config"
  fi

  # Copy workspace
  if [[ -d "$WORKSPACE_DIR" ]]; then
    echo "→ Backing up workspace: $WORKSPACE_DIR"
    cp -rc "$WORKSPACE_DIR" "$dest/pai-workspace"
  else
    echo "⚠ Workspace directory not found, skipping: $WORKSPACE_DIR"
  fi

  if $was_running; then
    echo "→ Restarting VM '$vm_name'..."
    limactl start "$vm_name"
  fi

  echo "✓ Backup complete: $dest"
}

# ── Restore ───────────────────────────────────────────────────────────────────
do_restore() {
  local vm_name="${1:-}"

  if [[ -z "$vm_name" ]]; then
    vm_name=$(pick_vm 2>/dev/null || true)
    # If no VMs exist yet, ask for a name to restore into
    if [[ -z "$vm_name" ]]; then
      printf "No running VMs found. Enter target VM name to restore into: "
      read -r vm_name
    fi
  fi

  local backup_path
  backup_path=$(pick_backup "$vm_name")

  local vm_dir="$LIMA_HOME/$vm_name"

  # Stop the VM if running
  local status
  status=$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v vm="$vm_name" '$1 == vm {print $2}')
  if [[ "$status" == "Running" ]]; then
    echo "→ Stopping VM '$vm_name' before restore..."
    limactl stop "$vm_name"
  fi

  # Warn if target already exists
  if [[ -d "$vm_dir" ]]; then
    printf "⚠ VM directory '%s' already exists. Overwrite? [y/N] " "$vm_dir"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Restore cancelled."
      exit 0
    fi
    rm -rf "$vm_dir"
  fi

  echo "→ Restoring '$vm_name' from: $(basename "$backup_path")"

  cp -rc "$backup_path/instance/$vm_name" "$vm_dir"
  fix_ownership "$vm_dir"

  if [[ -d "$backup_path/_config" ]]; then
    echo "→ Restoring _config..."
    rm -rf "$LIMA_HOME/_config"
    cp -rc "$backup_path/_config" "$LIMA_HOME/_config"
    fix_ownership "$LIMA_HOME/_config"
  fi

  if [[ -d "$backup_path/pai-workspace" ]]; then
    if [[ -d "$WORKSPACE_DIR" ]]; then
      printf "⚠ Workspace '%s' already exists. Overwrite? [y/N] " "$WORKSPACE_DIR"
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$WORKSPACE_DIR"
        cp -rc "$backup_path/pai-workspace" "$WORKSPACE_DIR"
        fix_ownership "$WORKSPACE_DIR"
        echo "→ Workspace restored."
      else
        echo "→ Skipping workspace restore."
      fi
    else
      cp -rc "$backup_path/pai-workspace" "$WORKSPACE_DIR"
      fix_ownership "$WORKSPACE_DIR"
      echo "→ Workspace restored."
    fi
  else
    echo "⚠ No workspace found in this backup, skipping."
  fi

  echo "✓ Restore complete. Start your VM with: limactl start $vm_name"
}

# ── Entry point ───────────────────────────────────────────────────────────────
# Extract subcommand from remaining args (--name already consumed by common.sh)
SUBCOMMAND=""
POSITIONAL_VM=""
for arg in "${_PAI_REMAINING_ARGS[@]}"; do
  case "$arg" in
    backup|restore) SUBCOMMAND="$arg" ;;
    -*) ;; # skip other flags
    *) POSITIONAL_VM="$arg" ;;
  esac
done

if [[ -z "$SUBCOMMAND" ]]; then
  usage
fi

# Use positional VM name if given, otherwise use instance name from --name flag
BACKUP_VM_NAME="${POSITIONAL_VM:-$VM_NAME}"

case "$SUBCOMMAND" in
  backup)  do_backup  "$BACKUP_VM_NAME" ;;
  restore) do_restore "$BACKUP_VM_NAME" ;;
  *)       usage ;;
esac
