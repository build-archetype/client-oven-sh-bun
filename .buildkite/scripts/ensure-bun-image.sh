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
    
    # Create tmp directory if it doesn't exist
    if [ ! -d "$tart_dir/tmp" ]; then
        log "Creating .tart/tmp directory..."
        mkdir -p "$tart_dir/tmp"
    fi
    
    # Fix ownership - need to fix the parent directory too
    log "Setting ownership to $real_user:staff..."
    if [ "$(stat -f '%Su' "$tart_dir")" != "$real_user" ]; then
        log "Fixing ownership of .tart directory (currently owned by $(stat -f '%Su' "$tart_dir"))"
        if command -v sudo >/dev/null 2>&1; then
            sudo chown -R "$real_user:staff" "$tart_dir"
        else
            chown -R "$real_user:staff" "$tart_dir"
        fi
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
    
    # Get repository name, handling various cases
    if [ -n "${GITHUB_REPOSITORY:-}" ]; then
        REPOSITORY="${GITHUB_REPOSITORY##*/}"
    else
        # Fallback: get from git remote or use default
        REPOSITORY=$(git remote get-url origin 2>/dev/null | sed -E 's|.*/([^/]+)\.git$|\1|' || echo "client-oven-sh-bun")
    fi
    
    log "Repository detection:"
    log "  GITHUB_REPOSITORY: ${GITHUB_REPOSITORY:-<not set>}"
    log "  GITHUB_REPOSITORY_OWNER: ${GITHUB_REPOSITORY_OWNER:-<not set>}"
    log "  Detected repository: $REPOSITORY"
    
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
    chmod +x scripts/bootstrap-macos.sh
    
    # Start VM with shared directory
    log "Starting VM: $LOCAL_IMAGE_NAME"
    tart run "$LOCAL_IMAGE_NAME" --dir=workspace:"$PWD" --no-graphics &
    VM_PID=$!
    
    # Wait for VM to boot
    log "Waiting for VM to boot (60 seconds)..."
    sleep 60
    
    # Get VM IP
    log "Getting VM IP address..."
    VM_IP=""
    for i in {1..10}; do
        VM_IP=$(tart ip "$LOCAL_IMAGE_NAME" 2>/dev/null || echo "")
        if [ -n "$VM_IP" ]; then
            log "VM IP: $VM_IP"
            break
        fi
        log "Attempt $i: waiting for VM IP..."
        sleep 10
    done
    
    if [ -z "$VM_IP" ]; then
        log "❌ Could not get VM IP after 10 attempts"
        kill $VM_PID 2>/dev/null || true
        exit 1
    fi
    
    # Install sshpass if not available
    if ! command -v sshpass >/dev/null 2>&1; then
        log "Installing sshpass..."
        brew install sshpass
    fi
    
    # Wait for SSH to be available and run bootstrap
    log "Waiting for SSH to be available and running bootstrap..."
    SSH_SUCCESS=false
    for i in {1..30}; do
        log "SSH attempt $i/30..."
        if sshpass -p "admin" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 admin@"$VM_IP" "cd '/Volumes/My Shared Files/workspace' && ./scripts/bootstrap-macos.sh"; then
            log "✅ Bootstrap completed successfully!"
            SSH_SUCCESS=true
            break
        else
            log "SSH attempt $i failed, retrying in 30 seconds..."
            sleep 30
        fi
    done
    
    if [ "$SSH_SUCCESS" != "true" ]; then
        log "❌ Bootstrap failed after 30 SSH attempts"
        kill $VM_PID 2>/dev/null || true
        exit 1
    fi
    
    # Stop the VM gracefully
    log "Shutting down VM..."
    sshpass -p "admin" ssh -o StrictHostKeyChecking=no admin@"$VM_IP" "sudo shutdown -h now" || true
    
    # Wait for VM to stop
    sleep 30
    kill $VM_PID 2>/dev/null || true
    
    log "✅ Bootstrap completed successfully"
    
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