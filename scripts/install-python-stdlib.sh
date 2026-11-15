#!/bin/sh
# Xcode build phase: copy the Python standard library into the app and convert its binary
# modules into signed frameworks (iOS requires that). Uses BeeWare's helper from the package.
set -eu
XC="Vendor/python-ios/Python.xcframework"
if [ ! -d "$PROJECT_DIR/$XC" ]; then
  echo "warning: $XC not found; Python is not bundled (run scripts/fetch-python.sh)"
  exit 0
fi
source "$PROJECT_DIR/$XC/build/utils.sh"
install_python "$XC"
# Trim what we never need on a phone (tests, tkinter, idle): ~8 MB
PYLIB="$CODESIGNING_FOLDER_PATH/python/lib/python3.13"
rm -rf "$PYLIB/test" "$PYLIB/idlelib" "$PYLIB/tkinter" "$PYLIB/turtledemo" "$PYLIB/ensurepip" 2>/dev/null || true
find "$CODESIGNING_FOLDER_PATH/python" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
