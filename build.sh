#!/usr/bin/env bash
# =============================================================================
# build.sh — Package bintxt_tool UI into a standalone executable
#
# Usage:
#   ./build.sh              # builds for current platform
#
# Output:
#   dist/bintxt_tool        (Linux)
#   dist/bintxt_tool.app    (macOS — drag to Applications)
#
# Requirements:
#   pip install pyinstaller
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== bintxt_tool build ==="

# Verify PyInstaller is available
if ! command -v pyinstaller &>/dev/null; then
  echo "ERROR: pyinstaller not found. Run: pip install pyinstaller"
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
  --name "bintxt_tool" \
  $ICON_ARG \
  --add-data "cfg:cfg" \
  --add-data "ui/assets:ui/assets" \
  --paths "." \
  --distpath "." \
  ui/app.py

echo
echo "=== Build complete ==="
echo "    Output: ./bintxt_tool  (in repo root)"
echo "    Run it from this folder so it finds cfg/, input/, output/"
