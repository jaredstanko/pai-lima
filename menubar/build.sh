#!/bin/bash
# Build PAI-Status menu bar app
# Usage: ./build.sh [--install] [--vm-name=NAME] [--port=PORT] [--app-name=NAME]
#
# Compiles PAIStatus.swift into a standalone .app bundle.
# With --install, copies the app to /Applications.
# With --vm-name, --port, --app-name, builds a named instance variant.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse flags
INSTALL=false
VM_NAME="pai"
PORTAL_PORT="8080"
APP_NAME="PAI-Status"

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --vm-name=*) VM_NAME="${arg#--vm-name=}" ;;
    --port=*) PORTAL_PORT="${arg#--port=}" ;;
    --app-name=*) APP_NAME="${arg#--app-name=}" ;;
    *) ;;
  esac
done

BUNDLE_NAME="${APP_NAME}.app"
BUILD_DIR="$SCRIPT_DIR/build"
LAUNCH_AGENT="com.pai.status${VM_NAME:+.${VM_NAME#pai-}}"
# For default "pai", launch agent is "com.pai.status" (no suffix)
if [ "$VM_NAME" = "pai" ]; then
  LAUNCH_AGENT="com.pai.status"
fi

echo "Building ${APP_NAME}..."
echo "  VM name: $VM_NAME"
echo "  Portal port: $PORTAL_PORT"

# Clean
rm -rf "$BUILD_DIR"

# Create .app bundle structure
mkdir -p "$BUILD_DIR/$BUNDLE_NAME/Contents/MacOS"
mkdir -p "$BUILD_DIR/$BUNDLE_NAME/Contents/Resources"

# Generate instance-specific Swift source with correct constants
SWIFT_SOURCE="$BUILD_DIR/PAIStatus.swift"
sed \
  -e "s|private let vmName = \"pai\"|private let vmName = \"${VM_NAME}\"|g" \
  -e "s|private let portalURL = \"http://localhost:8080\"|private let portalURL = \"http://localhost:${PORTAL_PORT}\"|g" \
  -e "s|private let launchAgentLabel = \"com.pai.status\"|private let launchAgentLabel = \"${LAUNCH_AGENT}\"|g" \
  -e "s|title: \"Quit PAI-Status\"|title: \"Quit ${APP_NAME}\"|g" \
  "$SCRIPT_DIR/PAIStatus.swift" > "$SWIFT_SOURCE"

# Compile from the generated source
swiftc \
  -O \
  -framework Cocoa \
  -o "$BUILD_DIR/$BUNDLE_NAME/Contents/MacOS/PAIStatus" \
  "$SWIFT_SOURCE"

# Generate Info.plist with correct app name
sed \
  -e "s|PAI-Status|${APP_NAME}|g" \
  -e "s|com.pai.status|${LAUNCH_AGENT}|g" \
  "$SCRIPT_DIR/Info.plist" > "$BUILD_DIR/$BUNDLE_NAME/Contents/Info.plist"

# Clean up generated source
rm -f "$SWIFT_SOURCE"

echo "Built: $BUILD_DIR/$BUNDLE_NAME"

# Install if requested
if [ "$INSTALL" = true ]; then
  echo "Installing to /Applications..."
  # Close running instance if any
  osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
  pkill -f "PAIStatus.*${VM_NAME}" 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/$BUNDLE_NAME"
  # Clean up old name variants for default instance
  if [ "$VM_NAME" = "pai" ]; then
    rm -rf "/Applications/PAIStatus.app"
  fi
  cp -R "$BUILD_DIR/$BUNDLE_NAME" "/Applications/"
  echo "Installed to /Applications/$BUNDLE_NAME"
  echo ""
  echo "Launch with: open /Applications/${BUNDLE_NAME}"
fi
