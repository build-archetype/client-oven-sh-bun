#!/bin/bash
set -e
set -x

IMAGE_NAME="bun-build-base"
BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"
MAX_RETRIES=3

echo "Checking for Bun build image..."

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
            echo "Retrying in 10 seconds..."
            sleep 10
        fi
        attempt=$((attempt + 1))
    done

    return $exitcode
}

# Check if our custom image exists
if ! tart list | grep -q "$IMAGE_NAME"; then
    echo "Creating Bun build image..."
    
    # Delete existing image if it exists (in case of partial creation)
    echo "Cleaning up any existing image..."
    tart delete "$IMAGE_NAME" || true
    
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
    
    # Run bootstrap script with CI flag and retry
    echo "Running bootstrap..."
    retry_command ".buildkite/scripts/run-vm-command.sh \"$IMAGE_NAME\" \"cd /Volumes/My\ Shared\ Files/workspace && chmod +x scripts/bootstrap.sh && ./scripts/bootstrap.sh --ci\"" || {
        echo "Bootstrap failed after $MAX_RETRIES attempts"
        kill $VM_PID
        wait $VM_PID
        exit 1
    }
    
    # Verify the installation with retry
    echo "Verifying installation..."
    retry_command ".buildkite/scripts/run-vm-command.sh \"$IMAGE_NAME\" \"which bun && bun --version && which cmake && cmake --version && which ninja && ninja --version\"" || {
        echo "Verification failed after $MAX_RETRIES attempts"
        kill $VM_PID
        wait $VM_PID
        exit 1
    }
    
    # Stop the VM
    echo "Stopping VM..."
    kill $VM_PID
    wait $VM_PID
    
    # Final verification that image exists
    if ! tart list | grep -q "$IMAGE_NAME"; then
        echo "Image was not created successfully"
        exit 1
    fi
    
    echo "Bun build image created successfully"
else
    echo "Bun build image already exists"
fi 