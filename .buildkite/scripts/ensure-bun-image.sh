#!/bin/bash
set -e
set -x

IMAGE_NAME="bun-build-base"
BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"

echo "Checking for Bun build image..."

# Check if our custom image exists
if ! tart list | grep -q "$IMAGE_NAME"; then
    echo "Creating Bun build image..."
    
    # Clone the base image
    echo "Cloning base image..."
    tart clone "$BASE_IMAGE" "$IMAGE_NAME"
    
    # Start the VM and run bootstrap
    echo "Starting VM and running bootstrap..."
    tart run "$IMAGE_NAME" --no-graphics --dir=workspace:"$PWD" &
    VM_PID=$!
    
    # Wait for VM to be ready
    echo "Waiting for VM to be ready..."
    sleep 10
    
    # Run bootstrap script with CI flag
    echo "Running bootstrap..."
    ./scripts/run-vm-command.sh "$IMAGE_NAME" "cd /Volumes/My\ Shared\ Files/workspace && chmod +x scripts/bootstrap.sh && ./scripts/bootstrap.sh --ci"
    
    # Verify the installation
    echo "Verifying installation..."
    ./scripts/run-vm-command.sh "$IMAGE_NAME" "which bun && bun --version && which cmake && cmake --version && which ninja && ninja --version"
    
    # Stop the VM
    echo "Stopping VM..."
    kill $VM_PID
    wait $VM_PID
    
    echo "Bun build image created successfully"
else
    echo "Bun build image already exists"
fi 