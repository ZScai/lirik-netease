#!/bin/bash
# Build arm64/universal MediaRemoteAdapter.framework on macOS and place under vendor/.
# Run on a Mac with Xcode + CMake. Not runnable on Linux.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="${TMPDIR:-/tmp}/mediaremote-adapter-build"
rm -rf "$WORKDIR"
git clone --depth 1 https://github.com/ungive/mediaremote-adapter.git "$WORKDIR"
mkdir -p "$WORKDIR/build"
cd "$WORKDIR/build"
cmake ..
cmake --build .
DEST="$ROOT/vendor/MediaRemoteAdapter.framework"
rm -rf "$DEST"
cp -R MediaRemoteAdapter.framework "$DEST"
echo "Installed: $DEST"
lipo -info "$DEST/Versions/A/MediaRemoteAdapter" || true
