#!/bin/bash
set -e
set -x

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Hardcoded image configuration -- update this when we switch to a new base image
IMAGE_NAME="base-bun-build-macos-darwin"
BASE_IMAGE_REMOTE="ghcr.io/cirruslabs/macos-sequoia-base:latest"
TARGET_IMAGE="ghcr.io/build-archetype/client-oven-sh-bun/base-bun-build-macos-darwin:latest"

# set the number of retries for the commands
MAX_RETRIES=3

# Print configuration summary
log "=== Configuration Summary ==="
log "Custom Image Name: $IMAGE_NAME"
log "Base Image Remote: $BASE_IMAGE_REMOTE"
log "Target Image: $TARGET_IMAGE"
log "Max Retries: $MAX_RETRIES"
log "GitHub Token: ${GITHUB_TOKEN:+set}${GITHUB_TOKEN:-not set}"
log "==========================="
log "Current working directory: $(pwd)"
log "Directory contents:"
ls -la
log "==========================="

# Function to check and pull base image
check_and_pull_base_image() {
    log "Checking if base image exists locally..."
    log "Running tart list:"
    tart list
    if ! tart list | grep -q "$IMAGE_NAME"; then
        log "Base image not found locally, attempting to pull..."
        log "Running tart pull $TARGET_IMAGE"
        if ! tart pull "$TARGET_IMAGE"; then
            log "Failed to pull base image from $TARGET_IMAGE"
            return 1
        fi
        log "Successfully pulled base image"
    else
        log "Base image found locally"
    fi
    return 0
}

# Make run-vm-command.sh executable
log "Making run-vm-command.sh executable..."
chmod +x .buildkite/scripts/run-vm-command.sh

# Function to retry commands
retry_command() {
    local cmd="$1"
    local max_attempts=$MAX_RETRIES
    local attempt=1
    local exitcode=0

    while [ $attempt -le $max_attempts ]; do
        log "Attempt $attempt of $max_attempts: $cmd"
        eval "$cmd"
        exitcode=$?
        if [ $exitcode -eq 0 ]; then
            log "Command succeeded on attempt $attempt"
            break
        fi
        log "Command failed with exit code $exitcode"
        if [ $attempt -lt $max_attempts ]; then
            log "Retrying in 30 seconds..."
            sleep 30
        fi
        attempt=$((attempt + 1))
    done

    return $exitcode
}

# Check and pull base image with retries
log "Checking and pulling base image..."
retry_command "check_and_pull_base_image" || {
    log "Failed to check/pull base image after $MAX_RETRIES attempts"
    exit 1
}

# Always clone the base image from the remote reference to the custom image name
log "Cloning base image from remote reference to create custom image..."
retry_command "tart clone $BASE_IMAGE_REMOTE $IMAGE_NAME" || {
    log "Failed to clone base image after $MAX_RETRIES attempts"
    exit 1
}

log "Current tart images:"
tart list

# Start the VM and run bootstrap
log "Starting VM and running bootstrap..."
tart run "$IMAGE_NAME" --no-graphics --dir=workspace:"$PWD" &
VM_PID=$!

# Wait for VM to be ready
log "Waiting for VM to be ready..."
sleep 30  # Increased wait time

# Run the simplified macOS bootstrap script
log "Running macOS bootstrap script..."
retry_command ".buildkite/scripts/run-vm-command.sh "$IMAGE_NAME" \"cd /Volumes/My\ Shared\ Files/workspace && chmod +x scripts/bootstrap-macos.sh && ./scripts/bootstrap-macos.sh\"" || {
    log "Bootstrap failed after $MAX_RETRIES attempts"
    kill $VM_PID
    wait $VM_PID
    exit 1
}

# Stop the VM gracefully
log "Stopping VM..."
kill $VM_PID
wait $VM_PID || true  # Ignore the exit status of wait since we expect SIGTERM

# Push your custom image to your registry
log "Pushing custom image to ghcr.io..."
retry_command "tart push $IMAGE_NAME $TARGET_IMAGE" || {
    log "Failed to push image after $MAX_RETRIES attempts"
    exit 1
}

log "Bun build image created, updated, and pushed successfully" 