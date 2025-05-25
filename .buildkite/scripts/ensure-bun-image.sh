#!/bin/bash
set -e

IMAGE_NAME="bun-build-base"
BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"

echo "Checking for Bun build image..."

# Function to verify image has all required dependencies
verify_image() {
    echo "Verifying image has all required dependencies..."
    tart run "$IMAGE_NAME" --no-graphics << 'EOF'
        echo "Checking for required tools..."
        echo "Checking Bun..."
        which bun
        bun --version
        
        echo "Checking CMake..."
        which cmake
        cmake --version
        
        echo "Checking Ninja..."
        which ninja
        ninja --version
        
        echo "Checking Bun installation directory..."
        ls -la /Users/admin/.bun
        
        echo "Checking PATH..."
        echo $PATH
        
        echo "All dependencies verified successfully"
EOF
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
    tart run "$IMAGE_NAME" --no-graphics << 'EOF'
        echo "Setting up workspace..."
        mkdir -p /Volumes/My\ Shared\ Files/workspace
        
        echo "Running bootstrap.sh..."
        cd /Volumes/My\ Shared\ Files/workspace
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
EOF
    
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