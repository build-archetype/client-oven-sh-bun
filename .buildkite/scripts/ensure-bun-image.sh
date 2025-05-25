#!/bin/bash
set -e
set -x  # Enable command echoing

# Ensure both scripts are executable
chmod +x "$(dirname "$0")/ensure-bun-image.sh"
chmod +x "$(dirname "$0")/run-vm-command.sh"

IMAGE_NAME="bun-build-base"
BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"

echo "Checking for Bun build image..."

# Function to verify the image has all required dependencies
verify_image() {
    echo "Verifying image has all required dependencies..."
    tart run "$IMAGE_NAME" --no-graphics bash -c '
        set -x
        echo "Checking Bun..."
        which bun || exit 1
        bun --version || exit 1
        
        echo "Checking CMake..."
        which cmake || exit 1
        cmake --version || exit 1
        
        echo "Checking Ninja..."
        which ninja || exit 1
        ninja --version || exit 1
        
        echo "Checking Bun installation directory..."
        ls -la /Users/admin/.bun || exit 1
        
        echo "All dependencies verified successfully"
    '
    return $?
}

# Check if our custom image exists and is valid
if ! tart list | grep -q "$IMAGE_NAME" || ! verify_image; then
    echo "Creating or updating Bun build image..."
    
    # Delete existing image if it exists but is invalid
    if tart list | grep -q "$IMAGE_NAME"; then
        echo "Removing invalid image..."
        tart delete "$IMAGE_NAME"
    fi
    
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
        ./scripts/bootstrap.sh || exit 1
        
        echo "Verifying installations..."
        echo "Checking Bun..."
        which bun || exit 1
        bun --version || exit 1
        
        echo "Checking CMake..."
        which cmake || exit 1
        cmake --version || exit 1
        
        echo "Checking Ninja..."
        which ninja || exit 1
        ninja --version || exit 1
        
        echo "Setting up environment..."
        export BUN_INSTALL="/Users/admin/.bun"
        export PATH="/Users/admin/.bun/bin:$PATH"
        
        echo "Verifying Bun in PATH..."
        which bun || exit 1
        bun --version || exit 1
        
        echo "Checking Bun installation directory..."
        ls -la /Users/admin/.bun || exit 1
        
        echo "All dependencies verified successfully"
    '
    
    # Stop the VM
    echo "Stopping VM..."
    tart stop "$IMAGE_NAME"
    
    # Verify the image one final time
    echo "Performing final verification..."
    if ! verify_image; then
        echo "Failed to create valid Bun build image"
        exit 1
    fi
    
    echo "Bun build image created successfully"
else
    echo "Valid Bun build image already exists"
fi 