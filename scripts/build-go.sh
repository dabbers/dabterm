#!/bin/sh
# Builds the Yaegi Go interpreter bridge (gobridge/) into Vendor/go-ios/Yaegi.xcframework with
# gomobile. Optional: the app builds without it (the `go` command then says Go is not bundled).
# Needs Go (any recent release; a go1.25 toolchain is fetched automatically) and Xcode. Usage: scripts/build-go.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$PATH:$HOME/go/bin"
export GOFLAGS=
export GOTOOLCHAIN=go1.25.4
command -v gomobile >/dev/null || go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20250711185624-d5bb5ecc55c0
command -v gobind >/dev/null || go install golang.org/x/mobile/cmd/gobind@v0.0.0-20250711185624-d5bb5ecc55c0
mkdir -p "$ROOT/Vendor/go-ios"
cd "$ROOT/gobridge"
gomobile bind -target ios,iossimulator -iosversion 18.0 -ldflags="-s -w" -o "$ROOT/Vendor/go-ios/Yaegi.xcframework" .
echo "built $ROOT/Vendor/go-ios/Yaegi.xcframework"
