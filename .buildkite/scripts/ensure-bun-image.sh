#!/bin/bash
set -e
set -x

IMAGE_NAME="base-bun-build-macos-darwin"
BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"
MAX_RETRIES=3
DELETE_EXISTING=false

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

# Authenticate with GitHub Container Registry
echo "Authenticating with GitHub Container Registry..."
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "${GITHUB_TOKEN}" | tart login ghcr.io --password-stdin
else
    echo "Warning: GITHUB_TOKEN not set, authentication may fail"
fi

# Check if we should delete existing image
if [ "$DELETE_EXISTING" = "true" ]; then
    echo "DELETE_EXISTING is true, removing existing image..."
    tart delete "$IMAGE_NAME" || true
fi

# Check if our custom image exists
if ! tart list | grep -q "$IMAGE_NAME"; then
    echo "Creating Bun build image..."
    
    # Clone the base image with retry
    echo "Cloning base image..."
    retry_command "tart clone \"$BASE_IMAGE\" \"$IMAGE_NAME\"" || {
        echo "Failed to clone base image after $MAX_RETRIES attempts"
        exit 1
    }
    
    # Start the VM and run bootstrap
    echo "Starting VM and running bootstrap..."
    tart run "$IMAGE_NAME" --no-graphics --dir=workspace:"$PWD" &
    VM_PID=$!
    
    # Wait for VM to be ready
    echo "Waiting for VM to be ready..."
    sleep 30  # Increased wait time
    
    # Run the simplified macOS bootstrap script
    echo "Running macOS bootstrap script..."
    retry_command ".buildkite/scripts/run-vm-command.sh \"$IMAGE_NAME\" \"cd /Volumes/My\ Shared\ Files/workspace && chmod +x scripts/bootstrap-macos.sh && ./scripts/bootstrap-macos.sh\"" || {
        echo "Bootstrap failed after $MAX_RETRIES attempts"
        kill $VM_PID
        wait $VM_PID
        exit 1
    }
    
    # Stop the VM gracefully
    echo "Stopping VM..."
    kill $VM_PID
    wait $VM_PID || true  # Ignore the exit status of wait since we expect SIGTERM
    
    # Final verification that image exists
    if ! tart list | grep -q "$IMAGE_NAME"; then
        echo "Image was not created successfully"
        exit 1
    fi
    
    echo "Bun build image created successfully"
else
    echo "Bun build image already exists"
fi 