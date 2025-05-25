#!/bin/bash
set -e
set -x  # Enable command echoing

# Ensure both scripts are executable
chmod +x "$(dirname "$0")/ensure-bun-image.sh"
chmod +x "$(dirname "$0")/run-vm-command.sh"

IMAGE_NAME="bun-build-base"
BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"

echo "Checking for Bun build image..."

# Check if our custom image exists and is valid
if ! tart list | grep -q "$IMAGE_NAME"; then
    echo "Creating Bun build image..."
    
    # Clone the base image
    echo "Cloning base image..."
    tart clone "$BASE_IMAGE" "$IMAGE_NAME"
    
    # Run the VM and install dependencies
    echo "Running VM to install dependencies..."
    tart run "$IMAGE_NAME" --no-graphics --dir=workspace:"$PWD" bash -c '
        set -x
        echo "Setting up workspace..."
        cd /Volumes/My\ Shared\ Files/workspace
        
        echo "Running bootstrap.sh..."
        chmod +x scripts/bootstrap.sh
        ./scripts/bootstrap.sh
        
        echo "Verifying installations..."
        echo "Checking Bun..."
        which bun
        bun --version
        
        echo "Checking CMake..."
        which cmake
        cmake --version
        
        echo "Checking Ninja..."
        which ninja
        ninja --version
        
        echo "Setting up environment..."
        export BUN_INSTALL="/Users/admin/.bun"
        export PATH="/Users/admin/.bun/bin:$PATH"
        
        echo "Verifying Bun in PATH..."
        which bun
        bun --version
        
        echo "Checking Bun installation directory..."
        ls -la /Users/admin/.bun
        
        echo "All dependencies verified successfully"
    '
    
    # Stop the VM
    echo "Stopping VM..."
    tart stop "$IMAGE_NAME"
    
    echo "Bun build image created successfully"
else
    echo "Valid Bun build image already exists"
fi 