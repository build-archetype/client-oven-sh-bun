#!/bin/bash
set -e
set -x

# Add trap to ensure cleanup on exit
cleanup() {
    local exit_code=$?
    if [ -n "$VM_PID" ] && ps -p $VM_PID > /dev/null; then
        log "Cleaning up VM process..."
        kill $VM_PID || true
        wait $VM_PID || true
    fi
    exit $exit_code
}
trap cleanup EXIT

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Hardcoded image configuration
IMAGE_NAME="base-bun-build-macos-darwin"
BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"

log "Checking for Bun build image..."
log "Making run-vm-command.sh executable..."
chmod +x .buildkite/scripts/run-vm-command.sh

log "Deleting existing image if present..."
tart delete "$IMAGE_NAME" || true

log "Creating Bun build image..."
log "Cloning base image..."
tart clone "$BASE_IMAGE" "$IMAGE_NAME"

log "Starting VM and running bootstrap..."
tart run "$IMAGE_NAME" --no-graphics --dir=workspace:"$PWD" > vm.log 2>&1 &
VM_PID=$!

log "Waiting for VM to be ready..."
sleep 10

log "Running bootstrap..."
.buildkite/scripts/run-vm-command.sh "$IMAGE_NAME" "cd /Volumes/My\\ Shared\\ Files/workspace && chmod +x scripts/bootstrap.sh && ./scripts/bootstrap.sh --ci"

log "Verifying installation..."
.buildkite/scripts/run-vm-command.sh "$IMAGE_NAME" "which bun && bun --version && which cmake && cmake --version && which ninja && ninja --version"

log "Build completed successfully" 