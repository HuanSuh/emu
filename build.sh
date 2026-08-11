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
dart compile exe bin/emu.dart -o emu --define=EMU_VERSION="$VERSION"

echo "✓ built ./emu"
echo "  install with: ln -sf \"$(pwd)/emu\" /usr/local/bin/emu"
