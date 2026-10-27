#!/usr/bin/env bash
# Build a self-contained `emu` binary: embed web assets, then compile.
set -euo pipefail
cd "$(dirname "$0")"

echo "» fetching deps"
dart pub get >/dev/null

echo "» bundling web assets"
dart run tool/bundle_web.dart

VERSION=$(grep '^version:' pubspec.yaml | head -1 | sed 's/version: *//' | tr -d '[:space:]')

echo "» compiling (v$VERSION)"
# Into a temp file, then renamed over ./emu: a running emu (the hub, which may
# be the one updating itself) keeps its own file instead of seeing it rewritten.
dart compile exe bin/emu.dart -o emu.tmp --define=EMU_VERSION="$VERSION"
mv -f emu.tmp emu

echo "✓ built ./emu"
echo "  install with: ln -sf \"$(pwd)/emu\" /usr/local/bin/emu"
