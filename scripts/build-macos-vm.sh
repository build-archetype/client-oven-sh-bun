#!/bin/bash
set -euo pipefail

# =============================================================================
# BUILD-MACOS-VM.SH - Base VM Management Script
# =============================================================================

# Configuration
MACOS_RELEASE="${MACOS_RELEASE:-13}"
ARCH="$(uname -m | sed 's/x86_64/x64/')"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Get bootstrap version from the bootstrap script
get_bootstrap_version() {
    local script_path="$1"
    if [ ! -f "$script_path" ]; then
        echo "14"  # updated fallback
        return
    fi
    
    local version=$(grep -E "^# Version: " "$script_path" | sed -E 's/^# Version: ([0-9.]+).*/\1/' | head -1)
    if [ -n "$version" ]; then
        echo "$version"
    else
        echo "14"  # updated fallback
    fi
}

# Get Bun version
get_bun_version() {
    local version=""
    
    # Try package.json first
    if [ -f "package.json" ]; then
        version=$(jq -r '.version // empty' package.json 2>/dev/null || true)
    fi
    
    # Fallback to git tags
    if [ -z "$version" ]; then
        version=$(git describe --tags --always --dirty 2>/dev/null | sed 's/^bun-v//' | sed 's/^v//' || echo "1.2.17")
    fi
    
    # Clean up version string
    version=${version#v}
    version=${version#bun-}
    
    # Validate version format
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        log "Warning: Invalid version format '$version', using fallback"
        version="1.2.17"
    fi
    
    echo "$version"
}

# Get base image based on macOS release
get_base_image() {
    local release="$1"
    case "$release" in
        "14")
            echo "ghcr.io/cirruslabs/macos-sonoma-xcode:latest"
            ;;
        "13")
            echo "ghcr.io/cirruslabs/macos-ventura-xcode:latest"
            ;;
        *)
            log "⚠️  Unknown macOS release: $release, defaulting to Sonoma (14)"
            echo "ghcr.io/cirruslabs/macos-sonoma-xcode:latest"
            ;;
    esac
}

main() {
    # Parse arguments
    local force_refresh=false
    local cleanup_only=false
    local check_only=false
    
    for arg in "$@"; do
        case $arg in
            --force-refresh)
                force_refresh=true
                shift
                ;;
            --cleanup-only)
                cleanup_only=true
                shift
                ;;
            --check-only)
                check_only=true
                shift
                ;;
            --release=*)
                MACOS_RELEASE="${arg#*=}"
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --force-refresh         Force refresh of base image"
                echo "  --cleanup-only          Clean up old VM images and exit"
                echo "  --check-only            Check if base VM exists without building"
                echo "  --release=VERSION       macOS release version (13, 14) [default: 13]"
                echo "  --help, -h              Show this help message"
                exit 0
                ;;
        esac
    done
    
    # Configuration
    BASE_IMAGE=$(get_base_image "$MACOS_RELEASE")
    BUN_VERSION=$(get_bun_version)
    BOOTSTRAP_VERSION=$(get_bootstrap_version scripts/bootstrap_new.sh)
    
    # Image naming convention: bun-build-macos-{release}-{arch}-{bun_version}-bootstrap-{bootstrap_version}
    LOCAL_IMAGE_NAME="bun-build-macos-${MACOS_RELEASE}-${ARCH}-${BUN_VERSION}-bootstrap-${BOOTSTRAP_VERSION}"
    
    log "Configuration:"
    log "  macOS Release: $MACOS_RELEASE"
    log "  Architecture: $ARCH"
    log "  Bun Version: $BUN_VERSION"
    log "  Bootstrap Version: $BOOTSTRAP_VERSION"
    log "  Target VM: $LOCAL_IMAGE_NAME"
    
    # Handle different modes
    if [ "$cleanup_only" = "true" ]; then
        log "✅ Cleanup-only mode - this would clean up old images"
        exit 0
    fi
    
    if [ "$check_only" = "true" ]; then
        log "🔍 Checking if base VM exists: $LOCAL_IMAGE_NAME"
        if tart list 2>/dev/null | grep -q "^local.*$LOCAL_IMAGE_NAME"; then
            log "✅ Base VM exists and ready"
            exit 0
        else
            log "❌ Base VM does not exist"
            exit 1
        fi
    fi
    
    # Quick check if VM already exists and we're not forcing refresh
    if [ "$force_refresh" != "true" ]; then
        if tart list | grep -q "^local.*$LOCAL_IMAGE_NAME"; then
            log "✅ Target VM already exists: $LOCAL_IMAGE_NAME"
            exit 0
        fi
    fi
    
    log "🏗️  Building base VM: $LOCAL_IMAGE_NAME"
    log "   This may take several minutes..."
    log "   Base image: $BASE_IMAGE"
    
    # Clone from base image
    if tart clone "$BASE_IMAGE" "$LOCAL_IMAGE_NAME" 2>&1; then
        log "✅ VM cloned from base: $LOCAL_IMAGE_NAME"
        
        # Start VM and run bootstrap
        log "🔧 Starting VM to run bootstrap script..."
        tart run "$LOCAL_IMAGE_NAME" --no-graphics >/dev/null 2>&1 &
        local vm_pid=$!
        
        # Wait for VM to boot
        sleep 15
        
        # Get VM IP
        local vm_ip=""
        for i in {1..30}; do
            vm_ip=$(tart ip "$LOCAL_IMAGE_NAME" 2>/dev/null || echo "")
            if [ -n "$vm_ip" ]; then
                break
            fi
            sleep 3
        done
        
        if [ -n "$vm_ip" ]; then
            # Wait for SSH
            local ssh_ready=false
            for i in {1..30}; do
                if sshpass -p "admin" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 admin@"$vm_ip" "echo 'ready'" >/dev/null 2>&1; then
                    ssh_ready=true
                    break
                fi
                sleep 3
            done
            
            if [ "$ssh_ready" = "true" ]; then
                log "✅ VM ready for bootstrap (IP: $vm_ip)"
                
                # Copy and run bootstrap script
                if sshpass -p "admin" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR scripts/bootstrap_new.sh admin@"$vm_ip":/tmp/; then
                    log "   📁 Bootstrap script copied, executing..."
                    local bootstrap_cmd='cd /tmp && chmod +x bootstrap_new.sh && ./bootstrap_new.sh'
                    
                    if sshpass -p "admin" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR admin@"$vm_ip" "$bootstrap_cmd"; then
                        log "✅ Bootstrap completed successfully"
                    else
                        log "⚠️  Bootstrap had issues but continuing..."
                    fi
                    
                    # Shutdown VM gracefully
                    log "   🛑 Shutting down VM..."
                    sshpass -p "admin" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR admin@"$vm_ip" "sudo shutdown -h now" >/dev/null 2>&1 || true
                    sleep 10
                    kill $vm_pid >/dev/null 2>&1 || true
                    
                    log "✅ Base VM ready: $LOCAL_IMAGE_NAME"
                else
                    log "❌ Failed to copy bootstrap script"
                    kill $vm_pid >/dev/null 2>&1 || true
                    exit 1
                fi
            else
                log "❌ SSH not available"
                kill $vm_pid >/dev/null 2>&1 || true
                exit 1
            fi
        else
            log "❌ Could not get VM IP"
            kill $vm_pid >/dev/null 2>&1 || true
            exit 1
        fi
    else
        log "❌ Failed to clone base image"
        exit 1
    fi
}

main "$@" 