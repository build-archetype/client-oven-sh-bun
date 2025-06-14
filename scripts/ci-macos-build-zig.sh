#!/bin/bash
set -euo pipefail

# Script to run all Zig build commands in a single VM session
# This preserves zig cache between build and upload commands

RELEASE="${1:-14}"
BUILD_COMMAND="${2:-bun run build:release}"
TOOLCHAIN="${3:-darwin-aarch64}"
WORKSPACE_DIR="${4:-$(pwd)}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Zig build with cache preservation..."
echo "Release: $RELEASE"
echo "Build command: $BUILD_COMMAND"
echo "Toolchain: $TOOLCHAIN"
echo "Workspace: $WORKSPACE_DIR"

# Create the combined command that runs all targets in sequence
COMBINED_COMMAND="cd workspace && $BUILD_COMMAND --target bun-zig --toolchain $TOOLCHAIN && ($BUILD_COMMAND --target upload-all-caches || echo 'Cache upload failed (non-fatal)')"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Combined command: $COMBINED_COMMAND"

# Run all commands in a single VM session
exec ./scripts/ci-macos.sh --release="$RELEASE" "$COMBINED_COMMAND" "$WORKSPACE_DIR" 