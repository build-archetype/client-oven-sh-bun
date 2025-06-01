#!/bin/bash
set -euo pipefail

# Add trap for cleanup
cleanup() {
    if [ -n "${VM_PID:-}" ]; then
        kill $VM_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Get Bun version
get_bun_version() {
    local version=""
    
    if [ -f "CMakeLists.txt" ]; then
        version=$(grep -E "set\(Bun_VERSION" CMakeLists.txt | sed 's/.*"\(.*\)".*/\1/' || true)
    fi
    
    if [ -z "$version" ] && [ -f "package.json" ]; then
        version=$(jq -r '.version // empty' package.json 2>/dev/null || true)
    fi
    
    if [ -z "$version" ]; then
        version=$(git describe --tags --always --dirty 2>/dev/null || echo "dev")
    fi
    
    version=${version#v}
    echo "$version"
}

# Check if image exists in registry
image_exists_in_registry() {
    local image_url="$1"
    log "Checking if image exists: $image_url"
    
    if tart pull "$image_url" &> /dev/null; then
        log "Image found and pulled from registry"
        return 0
    fi
    
    return 1
}

# Main execution
main() {
    # Configuration
    BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"
    REGISTRY="ghcr.io"
    ORGANIZATION="${GITHUB_REPOSITORY_OWNER:-oven-sh}"
    REPOSITORY="${GITHUB_REPOSITORY##*/}"
    
    # Get Bun version
    BUN_VERSION=$(get_bun_version)
    log "Detected Bun version: $BUN_VERSION"
    
    # Image names
    LOCAL_IMAGE_NAME="bun-build-macos-${BUN_VERSION}"
    REMOTE_IMAGE_URL="${REGISTRY}/${ORGANIZATION}/${REPOSITORY}/bun-build-macos:${BUN_VERSION}"
    LATEST_IMAGE_URL="${REGISTRY}/${ORGANIZATION}/${REPOSITORY}/bun-build-macos:latest"
    
    # Check registry
    if image_exists_in_registry "$REMOTE_IMAGE_URL"; then
        log "Base image for Bun ${BUN_VERSION} already exists"
        
        # Clone to versioned name
        if ! tart list | grep -q "^${LOCAL_IMAGE_NAME}"; then
            tart clone "bun-build-macos" "$LOCAL_IMAGE_NAME" 2>/dev/null || true
        fi
        
        exit 0
    fi
    
    log "Building new base image for Bun ${BUN_VERSION}..."
    
    # Clean up any existing image
    tart delete "$LOCAL_IMAGE_NAME" 2>/dev/null || true
    
    # Clone base
    log "Cloning base image..."
    tart clone "$BASE_IMAGE" "$LOCAL_IMAGE_NAME"
    
    # Start VM
    log "Starting VM..."
    tart run "$LOCAL_IMAGE_NAME" --no-graphics --dir=workspace:"$PWD" > vm.log 2>&1 &
    VM_PID=$!
    
    # Wait for VM to be ready
    sleep 10
    
    # Make scripts executable
    chmod +x scripts/bootstrap.sh
    chmod +x .buildkite/scripts/run-vm-command.sh
    
    # Run bootstrap using SSH
    log "Running bootstrap..."
    if ! .buildkite/scripts/run-vm-command.sh "$LOCAL_IMAGE_NAME" "cd '/Volumes/My Shared Files/workspace' && ./scripts/bootstrap.sh --ci"; then
        log "Bootstrap failed, check vm.log"
        cat vm.log
        exit 1
    fi
    
    # Verify installation
    log "Verifying installation..."
    .buildkite/scripts/run-vm-command.sh "$LOCAL_IMAGE_NAME" "which bun && bun --version && which cmake && cmake --version"
    
    # Stop VM
    log "Stopping VM..."
    tart stop "$LOCAL_IMAGE_NAME" || true
    wait $VM_PID 2>/dev/null || true
    
    # Push to registry if credentials exist
    if [ -f /tmp/github-token.txt ] && [ -f /tmp/github-username.txt ]; then
        GITHUB_TOKEN=$(cat /tmp/github-token.txt)
        GITHUB_USERNAME=$(cat /tmp/github-username.txt)
        
        log "Pushing to registry..."
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
        
        tart push "$LOCAL_IMAGE_NAME" "$REMOTE_IMAGE_URL"
        tart push "$LOCAL_IMAGE_NAME" "$LATEST_IMAGE_URL"
        
        log "Push complete!"
    fi
    
    log "Base image ready: $LOCAL_IMAGE_NAME"
}

main "$@" 