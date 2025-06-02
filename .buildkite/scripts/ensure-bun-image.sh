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

# Get Bun version - fixed version detection
get_bun_version() {
    local version=""
    
    # First try package.json - this is the authoritative source
    if [ -f "package.json" ]; then
        version=$(jq -r '.version // empty' package.json 2>/dev/null || true)
    fi
    
    # If no package.json, try CMakeLists.txt but look for the right pattern
    if [ -z "$version" ] && [ -f "CMakeLists.txt" ]; then
        # Look for project(Bun VERSION ...) or similar patterns
        version=$(grep -E "project\(.*VERSION\s+" CMakeLists.txt | sed -E 's/.*VERSION\s+([0-9]+\.[0-9]+\.[0-9]+).*/\1/' || true)
    fi
    
    # Fallback to git tags
    if [ -z "$version" ]; then
        version=$(git describe --tags --always --dirty 2>/dev/null | sed 's/^bun-v//' | sed 's/^v//' || echo "1.2.14")
    fi
    
    # Clean up version string
    version=${version#v}
    version=${version#bun-}
    
    # Validate version format
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        log "Warning: Invalid version format '$version', using fallback"
        version="1.2.14"
    fi
    
    echo "$version"
}

# Compare semantic versions (returns 0 if v1 >= v2, 1 if v1 < v2)
version_compare() {
    local v1="$1"
    local v2="$2"
    
    if [ "$v1" = "$v2" ]; then
        return 0
    fi
    
    # Split versions into arrays
    IFS='.' read -ra V1 <<< "$v1"
    IFS='.' read -ra V2 <<< "$v2"
    
    # Compare major.minor.patch
    for i in 0 1 2; do
        local n1=${V1[i]:-0}
        local n2=${V2[i]:-0}
        
        if [ "$n1" -gt "$n2" ]; then
            return 0  # v1 > v2
        elif [ "$n1" -lt "$n2" ]; then
            return 1  # v1 < v2
        fi
    done
    
    return 0  # Equal
}

# Check if local image exists and get its creation time
get_local_image_info() {
    local image_name="$1"
    
    log "🔍 Checking for local image: $image_name"
    log "Running: tart list"
    
    # Get the full tart list output for debugging
    local tart_output=$(tart list 2>&1)
    log "Tart list output:"
    echo "$tart_output" | while IFS= read -r line; do
        log "  $line"
    done
    
    # Check if our specific image exists
    if echo "$tart_output" | grep -q "^${image_name}"; then
        log "✅ Found exact match for: $image_name"
        echo "exists"
    else
        log "❌ No exact match found for: $image_name"
        log "Looking for pattern: ^${image_name}"
        
        # Show similar images for debugging
        local similar=$(echo "$tart_output" | grep -i "bun\|macos" || echo "none")
        if [ "$similar" != "none" ]; then
            log "Similar images found:"
            echo "$similar" | while IFS= read -r line; do
                log "  $line"
            done
        else
            log "No Bun or macOS related images found"
        fi
        
        echo "missing"
    fi
}

# Main execution
main() {
    # Parse arguments
    local force_refresh=false
    for arg in "$@"; do
        case $arg in
            --force-refresh)
                force_refresh=true
                shift
                ;;
        esac
    done
    
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
    
    # Bootstrap script version - increment this when bootstrap changes to force new images
    BOOTSTRAP_VERSION="2.1"  # Added Rust support + additional build dependencies (make, python3, libtool, ruby, perl, ccache)
    
    # Image names (include bootstrap version to force rebuilds when bootstrap changes)
    LOCAL_IMAGE_NAME="bun-build-macos-${BUN_VERSION}-bootstrap-${BOOTSTRAP_VERSION}"
    REMOTE_IMAGE_URL="${REGISTRY}/${ORGANIZATION}/${REPOSITORY}/bun-build-macos:${BUN_VERSION}-bootstrap-${BOOTSTRAP_VERSION}"
    LATEST_IMAGE_URL="${REGISTRY}/${ORGANIZATION}/${REPOSITORY}/bun-build-macos:latest"
    
    log "Configuration:"
    log "  Base image: $BASE_IMAGE"
    log "  Local name: $LOCAL_IMAGE_NAME"
    log "  Remote URL: $REMOTE_IMAGE_URL"
    log "  Bootstrap version: $BOOTSTRAP_VERSION"
    log "  Force refresh: $force_refresh"
    
    # NEW LOGIC: Check local first, then remote, with version comparison
    log "=== CHECKING IMAGE AVAILABILITY ==="
    
    # Step 1: Check if we should use local image
    local use_local=false
    if [ "$force_refresh" != true ]; then
        local local_status=$(get_local_image_info "$LOCAL_IMAGE_NAME")
        if [ "$local_status" = "exists" ]; then
            log "✅ Local image exists: $LOCAL_IMAGE_NAME"
            use_local=true
        else
            log "❌ No local image found"
        fi
    else
        log "🔄 Force refresh requested - skipping local check"
    fi
    
    # Step 2: Check remote for same version
    local remote_available=false
    log "Checking registry for exact version match..."
    if image_exists_in_registry "$REMOTE_IMAGE_URL"; then
        log "✅ Remote image found for exact version: $BUN_VERSION"
        remote_available=true
        
        # If we have both local and remote with same version, prefer local (faster)
        if [ "$use_local" = true ] && [ "$force_refresh" != true ]; then
            log "📋 Using local image (same version as remote, faster)"
            exit 0
        else
            log "📋 Using remote image (cloning locally)"
            # Delete local if it exists to avoid conflicts
            tart delete "$LOCAL_IMAGE_NAME" 2>/dev/null || log "No existing local image to delete"
            tart clone "$REMOTE_IMAGE_URL" "$LOCAL_IMAGE_NAME"
            log "✅ Cloned successfully from registry"
            exit 0
        fi
    else
        log "❌ No remote image found for version $BUN_VERSION"
    fi
    
    # Step 3: If only local exists and no remote, use local
    if [ "$use_local" = true ] && [ "$remote_available" != true ]; then
        log "📋 Using local image (no remote available)"
        exit 0
    fi
    
    # Step 4: Need to build new image
    log "=== BUILDING NEW BASE IMAGE ==="
    log "Building new base image for Bun ${BUN_VERSION}..."
    
    # Clean up any existing image
    log "Cleaning up any existing local image..."
    tart delete "$LOCAL_IMAGE_NAME" 2>/dev/null || log "No existing image to delete"
    
    # Clone base image
    log "Cloning base image: $BASE_IMAGE"
    tart clone "$BASE_IMAGE" "$LOCAL_IMAGE_NAME"
    log "✅ Base image cloned"
    
    # Pass the version to bootstrap script
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
        
        # First check if we can SSH at all
        if sshpass -p "admin" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 admin@"$VM_IP" "echo 'SSH connection successful'"; then
            log "✅ SSH connection established"
            
            # Check initial state before bootstrap
            log "Checking VM state before bootstrap..."
            sshpass -p "admin" ssh -o StrictHostKeyChecking=no admin@"$VM_IP" "
                echo 'Current user: $(whoami)'
                echo 'Current directory: $(pwd)'
                echo 'PATH: $PATH'
                echo 'Available in /usr/local/bin: $(ls -la /usr/local/bin/ 2>/dev/null || echo none)'
                echo 'Available in /opt/homebrew/bin: $(ls -la /opt/homebrew/bin/ 2>/dev/null | head -5 || echo none)'
            "
            
            # Run the bootstrap script
            if sshpass -p "admin" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 admin@"$VM_IP" "cd '/Volumes/My Shared Files/workspace' && ./scripts/bootstrap-macos.sh"; then
                log "✅ Bootstrap completed successfully!"
                SSH_SUCCESS=true
                break
            else
                log "❌ Bootstrap failed on attempt $i"
            fi
        else
            log "SSH attempt $i failed, retrying in 30 seconds..."
        fi
        sleep 30
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
    
    # Step 5: Try to push to registry (but don't fail if this doesn't work)
    log "=== REGISTRY PUSH ATTEMPT ==="
    set +e  # Disable error handling for entire registry section

    # Check if we have any credentials at all
    HAVE_CREDS=false
    if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_USERNAME:-}" ]; then
        log "✅ Found GitHub credentials in environment"
        HAVE_CREDS=true
    elif [ -f /tmp/github-token.txt ] && [ -f /tmp/github-username.txt ]; then
        log "✅ Found GitHub credentials in legacy files (reading them)"
        GITHUB_TOKEN=$(cat /tmp/github-token.txt 2>/dev/null || echo "")
        GITHUB_USERNAME=$(cat /tmp/github-username.txt 2>/dev/null || echo "")
        if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_USERNAME" ]; then
            HAVE_CREDS=true
        fi
    else
        log "⚠️  No GitHub credentials found anywhere"
    fi

    if [ "$HAVE_CREDS" = true ]; then
        log "Attempting to push to registry with credentials..."
        
        # Set Tart authentication environment variables (with error handling)
        export TART_REGISTRY_USERNAME="$GITHUB_USERNAME" 2>/dev/null || true
        export TART_REGISTRY_PASSWORD="$GITHUB_TOKEN" 2>/dev/null || true
        
        log "Registry URLs:"
        log "  Primary: $REMOTE_IMAGE_URL"
        log "  Latest:  $LATEST_IMAGE_URL"
        
        # Try to push primary tag
        log "Pushing primary tag..."
        if tart push "$LOCAL_IMAGE_NAME" "$REMOTE_IMAGE_URL" 2>&1; then
            log "✅ Primary push successful"
            
            # Try to push latest tag
            log "Pushing latest tag..."
            if tart push "$LOCAL_IMAGE_NAME" "$LATEST_IMAGE_URL" 2>&1; then
                log "✅ Latest push successful"
            else
                log "⚠️  Latest push failed (non-fatal)"
            fi
            
            log "✅ Registry push completed successfully!"
        else
            log "⚠️  Primary push failed (non-fatal)"
            log "     This is normal if:"
            log "     - Registry authentication failed"
            log "     - Network issues occurred"
            log "     - Registry is read-only"
            log "     The build will continue normally."
        fi
        
        # Clean up environment variables (with error handling)
        unset TART_REGISTRY_USERNAME 2>/dev/null || true
        unset TART_REGISTRY_PASSWORD 2>/dev/null || true
    else
        log "⚠️  Skipping registry push - no credentials available"
        log "     This is normal for:"
        log "     - Local development builds"
        log "     - Forks without push access"
        log "     - Machines not yet configured with credentials"
        log "     The build will continue normally."
    fi

    set -e  # Re-enable strict error handling
    log "=== REGISTRY PUSH SECTION COMPLETE ==="
    
    log "✅ Base image ready: $LOCAL_IMAGE_NAME"
    log "Available images:"
    tart list
}

main "$@" 