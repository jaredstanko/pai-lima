#!/bin/bash
# Build PAI Status menu bar app
# Usage: ./build.sh [--install]
#
# Compiles PAIStatus.swift into a standalone .app bundle.
# With --install, copies the app to /Applications.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PAI Status"
BUNDLE_NAME="PAIStatus.app"
BUILD_DIR="$SCRIPT_DIR/build"

echo "Building ${APP_NAME}..."

# Clean
rm -rf "$BUILD_DIR"

# Create .app bundle structure
mkdir -p "$BUILD_DIR/$BUNDLE_NAME/Contents/MacOS"
mkdir -p "$BUILD_DIR/$BUNDLE_NAME/Contents/Resources"

# Compile
swiftc \
  -O \
  -framework Cocoa \
  -o "$BUILD_DIR/$BUNDLE_NAME/Contents/MacOS/PAIStatus" \
  "$SCRIPT_DIR/PAIStatus.swift"

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$BUILD_DIR/$BUNDLE_NAME/Contents/"

echo "Built: $BUILD_DIR/$BUNDLE_NAME"

# Install if requested
if [ "${1:-}" = "--install" ]; then
  echo "Installing to /Applications..."
  # Close running instance if any
  osascript -e 'tell application "PAI Status" to quit' 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/$BUNDLE_NAME"
  cp -R "$BUILD_DIR/$BUNDLE_NAME" "/Applications/"
  echo "Installed to /Applications/$BUNDLE_NAME"
  echo ""
  echo "Launch with: open -a 'PAI Status'"
fi
