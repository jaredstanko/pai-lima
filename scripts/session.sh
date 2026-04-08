#!/bin/bash
# PAI Lima -- spawn a new PAI session in kitty
# Thin wrapper around launch.sh for backward compatibility.
#
# Usage:
#   ./scripts/session.sh                    # New PAI session (Claude Code)
#   ./scripts/session.sh --shell            # Open a plain shell in the VM
#   ./scripts/session.sh --resume           # Resume a previous session
#   ./scripts/session.sh --name=v2          # Target a named instance

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/launch.sh" "$@"
