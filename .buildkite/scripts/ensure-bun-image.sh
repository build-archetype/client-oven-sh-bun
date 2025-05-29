#!/bin/bash
set -e
set -x

# Hardcoded image configuration -- update this when we switch to a new base image
IMAGE_NAME="base-bun-build-macos-darwin"
BASE_IMAGE_REMOTE="ghcr.io/cirruslabs/macos-sequoia-base:latest"
TARGET_IMAGE="ghcr.io/build-archetype/client-oven-sh-bun/base-bun-build-macos-darwin:latest"

MAX_RETRIES=3

# Print configuration summary
echo "=== Configuration Summary ==="
echo "Custom Image Name: $IMAGE_NAME"
echo "Base Image Remote: $BASE_IMAGE_REMOTE"
echo "Target Image: $TARGET_IMAGE"
echo "Max Retries: $MAX_RETRIES"
echo "GitHub Token: ${GITHUB_TOKEN:+set}${GITHUB_TOKEN:-not set}"
echo "==========================="
echo

# Function to check and pull base image
check_and_pull_base_image() {
    echo "Checking if base image exists locally..."
    if ! tart list | grep -q "$IMAGE_NAME"; then
        echo "Base image not found locally, attempting to pull..."
        if ! tart pull "$TARGET_IMAGE"; then
            echo "Failed to pull base image from $TARGET_IMAGE"
            return 1
        fi
        echo "Successfully pulled base image"
    else
        echo "Base image found locally"
    fi
    return 0
}

# Make run-vm-command.sh executable
echo "Making run-vm-command.sh executable..."
chmod +x .buildkite/scripts/run-vm-command.sh

# Function to retry commands
retry_command() {
    local cmd="$1"
    local max_attempts=$MAX_RETRIES
    local attempt=1
    local exitcode=0

    while [ $attempt -le $max_attempts ]; do
        echo "Attempt $attempt of $max_attempts: $cmd"
        eval "$cmd"
        exitcode=$?
        if [ $exitcode -eq 0 ]; then
            break
        fi
        echo "Command failed with exit code $exitcode"
        if [ $attempt -lt $max_attempts ]; then
            echo "Retrying in 30 seconds..."
            sleep 30
        fi
        attempt=$((attempt + 1))
    done

    return $exitcode
}

# Check and pull base image with retries
echo "Checking and pulling base image..."
retry_command "check_and_pull_base_image" || {
    echo "Failed to check/pull base image after $MAX_RETRIES attempts"
    exit 1
}

# Always clone the base image from the remote reference to the custom image name
# This will overwrite any existing VM with the same name

echo "Cloning base image from remote reference to create custom image..."
retry_command "tart clone $BASE_IMAGE_REMOTE $IMAGE_NAME" || {
    echo "Failed to clone base image after $MAX_RETRIES attempts"
    exit 1
}

tart list

# Start the VM and run bootstrap
echo "Starting VM and running bootstrap..."
tart run "$IMAGE_NAME" --no-graphics --dir=workspace:"$PWD" &
VM_PID=$!

# Wait for VM to be ready
echo "Waiting for VM to be ready..."
sleep 30  # Increased wait time

# Run the simplified macOS bootstrap script
echo "Running macOS bootstrap script..."
retry_command ".buildkite/scripts/run-vm-command.sh "$IMAGE_NAME" \"cd /Volumes/My\ Shared\ Files/workspace && chmod +x scripts/bootstrap-macos.sh && ./scripts/bootstrap-macos.sh\"" || {
    echo "Bootstrap failed after $MAX_RETRIES attempts"
    kill $VM_PID
    wait $VM_PID
    exit 1
}

# Stop the VM gracefully
echo "Stopping VM..."
kill $VM_PID
wait $VM_PID || true  # Ignore the exit status of wait since we expect SIGTERM

# Push your custom image to your registry
echo "Pushing custom image to ghcr.io..."
retry_command "tart push $IMAGE_NAME $TARGET_IMAGE" || {
    echo "Failed to push image after $MAX_RETRIES attempts"
    exit 1
}

echo "Bun build image created, updated, and pushed successfully" 