#!/usr/bin/env bash
# =============================================================================
# build.sh — Package bintxt_tool UI into a standalone executable
#
# Usage:
#   ./build.sh              # builds for current platform
#
# Output:
#   ./bintxt_tool_v1-0-0        (Linux)
#   ./bintxt_tool_v1-0-0.app    (macOS — drag to Applications)
#
# Requirements:
#   pip install --upgrade pyinstaller
#
# Update EXE_NAME below when shipping a new UI version.
# =============================================================================

set -euo pipefail

EXE_NAME="bintxt_tool_v1-0-0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== bintxt_tool build ($EXE_NAME) ==="

# Verify PyInstaller is available
if ! command -v pyinstaller &>/dev/null; then
  echo "ERROR: pyinstaller not found. Run: pip install --upgrade pyinstaller"
  exit 1
fi

# Pick icon for platform
if [[ "$(uname)" == "Darwin" ]]; then
  ICON_ARG="--icon=ui/assets/icon.icns"
  if [[ ! -f "ui/assets/icon.icns" ]]; then
    echo "WARNING: ui/assets/icon.icns not found — building without icon"
    ICON_ARG=""
  fi
else
  ICON_ARG="--icon=ui/assets/icon.ico"
fi

pyinstaller \
  --onefile \
  --windowed \
  --name "$EXE_NAME" \
  $ICON_ARG \
  --add-data "cfg:cfg" \
  --add-data "ui/assets:ui/assets" \
  --paths "." \
  --distpath "." \
  --workpath "build" \
  ui/app.py

echo
echo "=== Build complete ==="
echo "    Output: ./$EXE_NAME"
echo "    Run it from this folder so it finds cfg/, input/, output/"
