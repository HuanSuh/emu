#!/usr/bin/env bash
# Build a self-contained `emu` binary: embed web assets, then compile.
set -euo pipefail
cd "$(dirname "$0")"

echo "» fetching deps"
dart pub get >/dev/null

echo "» bundling web assets"
dart run tool/bundle_web.dart

echo "» compiling"
dart compile exe bin/emu.dart -o emu

echo "✓ built ./emu"
echo "  install with: ln -sf \"$(pwd)/emu\" /usr/local/bin/emu"
