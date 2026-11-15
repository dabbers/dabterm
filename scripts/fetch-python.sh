#!/bin/sh
# Download the BeeWare Python iOS framework (official CPython iOS build, PEP 730) into Vendor/.
# The app builds without it (the `python` command then reports that Python is not bundled).
# Usage: scripts/fetch-python.sh [3.13-b18]
set -eu
TAG="${1:-3.13-b18}"
VER="${TAG%%-*}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/python-ios"
URL="https://github.com/beeware/Python-Apple-support/releases/download/$TAG/Python-$VER-iOS-support.${TAG#*-}.tar.gz"
mkdir -p "$ROOT/Vendor"
rm -rf "$DEST"; mkdir -p "$DEST"
echo "Downloading $URL"
curl -L --progress-bar -o "$DEST.tar.gz" "$URL"
tar -xzf "$DEST.tar.gz" -C "$DEST"
rm "$DEST.tar.gz"
# Swift needs a framework-style module map to `import Python`; the package only ships a headers one.
for slice in "$DEST"/Python.xcframework/ios-*; do
  mkdir -p "$slice/Python.framework/Modules"
  printf 'framework module Python {\n    umbrella header "Python.h"\n    export *\n    link "Python"\n}\n' > "$slice/Python.framework/Modules/module.modulemap"
done
cat "$DEST/VERSIONS" | head -3
echo "Installed to $DEST. Run xcodegen generate and build."
