#!/bin/bash
# PAI Lima -- Shared instance configuration
# Source this file at the top of every script to get instance-aware variables.
#
# Parses --name=X and --port=N from arguments and sets:
#   INSTANCE_NAME   "pai" (default) or "pai-X"
#   INSTANCE_SUFFIX "" (default) or "-X"
#   VM_NAME         Same as INSTANCE_NAME (Lima VM name)
#   WORKSPACE       ~/pai-workspace (default) or ~/pai-workspace-X
#   PORTAL_PORT     8080 (default) or specified/auto-assigned port
#   APP_NAME        "PAI-Status" (default) or "PAI-Status-X"
#   APP_BUNDLE      "PAI-Status.app" (default) or "PAI-Status-X.app"
#   LAUNCH_AGENT    "com.pai.status" (default) or "com.pai.status.X"
#   LOG_FILE        ~/.pai-install.log (default) or ~/.pai-install-X.log
#
# Usage in scripts:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/common.sh" || source "$SCRIPT_DIR/scripts/common.sh"

# Parse --name and --port from all arguments
_PAI_NAME=""
_PAI_PORT=""
_PAI_NEEDS_PORT=false
_PAI_REMAINING_ARGS=()

for _arg in "$@"; do
  case "$_arg" in
    --name=*) _PAI_NAME="${_arg#--name=}" ;;
    --port=*) _PAI_PORT="${_arg#--port=}" ;;
    --needs-port) _PAI_NEEDS_PORT=true ;;
    *) _PAI_REMAINING_ARGS+=("$_arg") ;;
  esac
done

# Derive all instance variables
if [ -n "$_PAI_NAME" ]; then
  INSTANCE_NAME="pai-${_PAI_NAME}"
  INSTANCE_SUFFIX="-${_PAI_NAME}"
  WORKSPACE="$HOME/pai-workspace-${_PAI_NAME}"
  APP_NAME="PAI-Status-${_PAI_NAME}"
  APP_BUNDLE="PAI-Status-${_PAI_NAME}.app"
  LAUNCH_AGENT="com.pai.status.${_PAI_NAME}"
  LOG_FILE="$HOME/.pai-install-${_PAI_NAME}.log"

  # Port: use specified, or auto-assign only when caller needs it
  if [ -n "$_PAI_PORT" ]; then
    PORTAL_PORT="$_PAI_PORT"
  elif [ "$_PAI_NEEDS_PORT" = true ]; then
    # Auto-assign: scan 8081-8099 for first unused port
    PORTAL_PORT=""
    for _p in $(seq 8081 8099); do
      if ! lsof -i ":$_p" &>/dev/null 2>&1; then
        PORTAL_PORT="$_p"
        break
      fi
    done
    if [ -z "$PORTAL_PORT" ]; then
      echo "Error: Could not find an available port in 8081-8099. Use --port=N to specify." >&2
      exit 1
    fi
  else
    PORTAL_PORT="${_PAI_PORT:-8081}"
  fi
else
  INSTANCE_NAME="pai"
  INSTANCE_SUFFIX=""
  WORKSPACE="$HOME/pai-workspace"
  APP_NAME="PAI-Status"
  APP_BUNDLE="PAI-Status.app"
  LAUNCH_AGENT="com.pai.status"
  LOG_FILE="$HOME/.pai-install.log"
  PORTAL_PORT="${_PAI_PORT:-8080}"
fi

VM_NAME="$INSTANCE_NAME"

# Export for subshells
export INSTANCE_NAME INSTANCE_SUFFIX VM_NAME WORKSPACE PORTAL_PORT APP_NAME APP_BUNDLE LAUNCH_AGENT LOG_FILE

# ─── Shared helpers ─────────────────────────────────────────

# Get the status of the instance's VM ("Running", "Stopped", or "")
pai_vm_status() {
  local json
  json=$(limactl list --json 2>/dev/null || echo "")
  # grep exits 1 on no match -- must not propagate under set -eo pipefail
  echo "$json" | grep -A5 "\"name\":\"${VM_NAME}\"" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true
}

# Generate a .webloc bookmark file for the portal
# Usage: pai_generate_webloc "/path/to/output.webloc"
pai_generate_webloc() {
  local dest="$1"
  cat > "$dest" <<WEBLOC
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>URL</key>
	<string>http://localhost:${PORTAL_PORT}</string>
</dict>
</plist>
WEBLOC
}

# Get the bookmark file path for this instance
pai_bookmark_path() {
  local name="PAI Portal${INSTANCE_SUFFIX:+ ($INSTANCE_NAME)}"
  echo "$HOME/Desktop/${name}.webloc"
}

# Find a kitty remote control socket
pai_find_kitty_socket() {
  for sock in /tmp/kitty-*; do
    [ -S "$sock" ] && echo "unix:$sock" && return 0
  done
  return 1
}

# Open a command in a kitty tab (new window if no existing kitty)
pai_open_kitty_tab() {
  local title="$1"
  shift
  local socket
  if socket=$(pai_find_kitty_socket) && timeout 5 kitty @ --to "$socket" launch --type=tab --title "$title" -- "$@" 2>/dev/null; then
    return
  fi
  kitty --title "$title" "$@"
}
