#!/bin/bash
set -euo pipefail

VM_BASE="${VM_BASE:-base-m1}"
WORKSPACE_DIR="$(pwd)"
TMPDIR=$(mktemp -d)

# Rsync workspace to temp dir, excluding build artifacts and node_modules
rsync -a --exclude node_modules --exclude build --exclude dist "$WORKSPACE_DIR/" "$TMPDIR/"

echo "--- Running build in Tart VM: $VM_BASE"
tart run "$VM_BASE" --dir "$TMPDIR:/workspace" -- \
  bash -c 'cd /workspace && rm -rf build node_modules dist && bun install && bun run build:release'

rm -rf "$TMPDIR" 