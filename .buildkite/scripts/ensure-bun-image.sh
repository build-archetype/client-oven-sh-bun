#!/bin/bash
set -e

IMAGE_NAME="bun-build-base"
BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"

echo "Checking for Bun build image..."

# Check if our custom image exists
if ! tart list | grep -q "$IMAGE_NAME"; then
    echo "Creating Bun build image..."
    
    # Clone the base image
    echo "Cloning base image..."
    tart clone "$BASE_IMAGE" "$IMAGE_NAME"
    
    # Run the VM and install dependencies
    echo "Running VM to install dependencies..."
    tart run "$IMAGE_NAME" --no-graphics << 'EOF'
        # Mount the workspace
        mkdir -p /Volumes/My\ Shared\ Files/workspace
        
        # Run bootstrap.sh
        cd /Volumes/My\ Shared\ Files/workspace
        chmod +x scripts/bootstrap.sh
        ./scripts/bootstrap.sh
        
        # Verify installation
        echo "Verifying installations..."
        which bun || { echo "Bun not found"; exit 1; }
        bun --version || { echo "Bun version check failed"; exit 1; }
        which cmake || { echo "CMake not found"; exit 1; }
        which ninja || { echo "Ninja not found"; exit 1; }
        
        # Set up environment
        echo "Setting up environment..."
        export BUN_INSTALL="/Users/admin/.bun"
        export PATH="/Users/admin/.bun/bin:$PATH"
        
        # Verify Bun is in PATH
        echo "Verifying Bun in PATH..."
        which bun || { echo "Bun not in PATH"; exit 1; }
        
        echo "All dependencies verified successfully"
EOF
    
    # Stop the VM
    echo "Stopping VM..."
    tart stop "$IMAGE_NAME"
    
    echo "Bun build image created successfully"
else
    echo "Bun build image already exists"
fi 