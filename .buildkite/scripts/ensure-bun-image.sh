#!/bin/bash
set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Debug: Show who is running this script
log "=== DEBUGGING INFO ==="
log "Current user (whoami): $(whoami)"
log "USER: ${USER:-<not set>}"
log "SUDO_USER: ${SUDO_USER:-<not set>}"
log "HOME: ${HOME:-<not set>}"
log "UID: $(id -u)"
log "GID: $(id -g)"
log "Groups: $(groups)"
log "======================="

# Fix Tart permissions
fix_tart_permissions() {
    local tart_dir="$HOME/.tart"
    local real_user="${SUDO_USER:-$USER}"
    
    log "Fixing Tart permissions..."
    log "Tart directory: $tart_dir"
    log "Target user: $real_user"
    
    # Create .tart directory if it doesn't exist
    if [ ! -d "$tart_dir" ]; then
        log "Creating .tart directory..."
        mkdir -p "$tart_dir"
    fi
    
    # Fix ownership
    log "Setting ownership to $real_user:staff..."
    if [ "$real_user" != "$(whoami)" ]; then
        # We're running as root/sudo, fix ownership
        chown -R "$real_user:staff" "$tart_dir"
    fi
    
    # Set proper permissions
    chmod -R 755 "$tart_dir"
    
    # Show final state
    log "Final .tart directory state:"
    ls -la "$tart_dir" || log "Directory doesn't exist or can't be read"
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
    
    # Fix permissions before trying to use tart
    fix_tart_permissions
    
    if tart pull "$image_url" 2>&1; then
        log "✅ Image found and pulled from registry"
        return 0
    else
        log "❌ Image not found in registry"
        return 1
    fi
}

# Main execution
main() {
    # Fix Tart permissions first thing
    fix_tart_permissions
    
    # Configuration
    BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"
    REGISTRY="ghcr.io"
    ORGANIZATION="${GITHUB_REPOSITORY_OWNER:-build-archetype}"
    REPOSITORY="${GITHUB_REPOSITORY##*/}"
    
    # Get Bun version
    BUN_VERSION=$(get_bun_version)
    log "Detected Bun version: $BUN_VERSION"
    
    # Image names
    LOCAL_IMAGE_NAME="bun-build-macos-${BUN_VERSION}"
    REMOTE_IMAGE_URL="${REGISTRY}/${ORGANIZATION}/${REPOSITORY}/bun-build-macos:${BUN_VERSION}"
    LATEST_IMAGE_URL="${REGISTRY}/${ORGANIZATION}/${REPOSITORY}/bun-build-macos:latest"
    
    log "Configuration:"
    log "  Base image: $BASE_IMAGE"
    log "  Local name: $LOCAL_IMAGE_NAME"
    log "  Remote URL: $REMOTE_IMAGE_URL"
    
    # Check if local image already exists
    log "Checking for existing local images..."
    tart list
    if tart list | grep -q "^${LOCAL_IMAGE_NAME}"; then
        log "✅ Local image already exists: $LOCAL_IMAGE_NAME"
        exit 0
    fi
    
    # Check registry
    if image_exists_in_registry "$REMOTE_IMAGE_URL"; then
        log "Cloning from registry to local name..."
        tart clone "$REMOTE_IMAGE_URL" "$LOCAL_IMAGE_NAME"
        log "✅ Cloned successfully"
        exit 0
    fi
    
    log "Building new base image for Bun ${BUN_VERSION}..."
    
    # Clean up any existing image
    log "Cleaning up any existing local image..."
    tart delete "$LOCAL_IMAGE_NAME" 2>/dev/null || log "No existing image to delete"
    
    # Clone base image
    log "Cloning base image: $BASE_IMAGE"
    tart clone "$BASE_IMAGE" "$LOCAL_IMAGE_NAME"
    log "✅ Base image cloned"
    
    # Make bootstrap script executable
    log "Making bootstrap script executable..."
    chmod +x scripts/bootstrap.sh
    
    # Run bootstrap in the VM
    log "Running bootstrap in VM (this may take several minutes)..."
    log "Command: tart run $LOCAL_IMAGE_NAME --dir=workspace:$PWD -- /bin/bash -c 'cd /Volumes/My Shared Files/workspace && ./scripts/bootstrap.sh --ci'"
    
    if tart run "$LOCAL_IMAGE_NAME" --dir=workspace:"$PWD" -- /bin/bash -c "cd '/Volumes/My Shared Files/workspace' && ./scripts/bootstrap.sh --ci"; then
        log "✅ Bootstrap completed successfully"
    else
        log "❌ Bootstrap failed"
        exit 1
    fi
    
    # Push to registry if credentials exist
    if [ -f /tmp/github-token.txt ] && [ -f /tmp/github-username.txt ]; then
        GITHUB_TOKEN=$(cat /tmp/github-token.txt)
        GITHUB_USERNAME=$(cat /tmp/github-username.txt)
        
        log "Logging into GitHub Container Registry..."
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
        
        log "Pushing to registry: $REMOTE_IMAGE_URL"
        tart push "$LOCAL_IMAGE_NAME" "$REMOTE_IMAGE_URL"
        
        log "Pushing latest tag: $LATEST_IMAGE_URL"
        tart push "$LOCAL_IMAGE_NAME" "$LATEST_IMAGE_URL"
        
        log "✅ Push complete!"
    else
        log "⚠️  No GitHub credentials found, skipping registry push"
    fi
    
    log "✅ Base image ready: $LOCAL_IMAGE_NAME"
    log "Available images:"
    tart list
}

main "$@" 