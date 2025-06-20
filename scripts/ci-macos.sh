#!/bin/bash
set -euo pipefail

# Configuration - can be overridden via environment variables
BASE_VM_IMAGE="${BASE_VM_IMAGE:-}"  # Will be determined based on platform
FORCE_BASE_IMAGE_REBUILD="${FORCE_BASE_IMAGE_REBUILD:-false}"
DISK_USAGE_THRESHOLD="${DISK_USAGE_THRESHOLD:-80}"  # For monitoring only, no cleanup action

# Function to log messages with timestamps
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to get base VM image name for a specific macOS release
get_base_vm_image() {
    local release="${1:-14}"
    local bun_version="${2:-$(detect_bun_version)}"
    # Auto-detect bootstrap version from script (single source of truth)
    local bootstrap_version="${3:-$(get_bootstrap_version)}"
    # Auto-detect architecture
    local arch="${4:-$(get_arch)}"
    echo "bun-build-macos-${release}-${arch}-${bun_version}-bootstrap-${bootstrap_version}"
}

# Function to detect current architecture
get_arch() {
    case "$(uname -m)" in
        arm64) echo "arm64" ;;
        x86_64) echo "x64" ;;
        *) echo "arm64" ;;  # Default to arm64 for Apple Silicon CI machines
    esac
}

# Function to detect current Bun version from package.json
detect_bun_version() {
    local package_json="package.json"
    if [ -f "$package_json" ]; then
        # Extract version from package.json
        local version=$(grep '"version"' "$package_json" | sed -E 's/.*"version": "([^"]+)".*/\1/' | head -1)
        if [ -n "$version" ]; then
            echo "$version"
            return
        fi
    fi
    
    # Fallback if package.json not found or version not parsed
    echo "1.2.17"  # Updated fallback to match current version
}

# Get bootstrap version from the bootstrap script (single source of truth)
get_bootstrap_version() {
    local script_path="scripts/bootstrap_new.sh"
    if [ ! -f "$script_path" ]; then
        echo "4.0"  # fallback
        return
    fi
    
    # Extract version from comment like "# Version: 4.0 - description"
    local version=$(grep -E "^# Version: " "$script_path" | sed -E 's/^# Version: ([0-9.]+).*/\1/' | head -1)
    if [ -n "$version" ]; then
        echo "$version"
    else
        echo "4.0"  # fallback
    fi
}

# SSH options for VM connectivity
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# Function to ensure VM image is available (lightweight registry check)
ensure_vm_image_available() {
    local base_vm_image="$1"
    local release="$2"
    
    # Check if base image exists locally
    if tart list | grep -q "^local.*$base_vm_image"; then
        log "✅ Base image found locally: $base_vm_image"
        return 0
    fi
    
    log "🔍 Base image '$base_vm_image' not found locally"
    
    # Try to pull from registry (registry-first approach for distributed CI)
    # Extract version info from image name: bun-build-macos-13-arm64-1.2.16-bootstrap-4.1
    if [[ "$base_vm_image" =~ bun-build-macos-([0-9]+)-(arm64|x64)-([0-9]+\.[0-9]+\.[0-9]+)-bootstrap-([0-9]+\.[0-9]+) ]]; then
        local macos_release="${BASH_REMATCH[1]}"
        local arch="${BASH_REMATCH[2]}"
        local bun_version="${BASH_REMATCH[3]}"
        local bootstrap_version="${BASH_REMATCH[4]}"
        local registry_url="ghcr.io/build-archetype/client-oven-sh-bun/bun-build-macos-${macos_release}-${arch}:${bun_version}-bootstrap-${bootstrap_version}"
    else
        # Fallback to latest if we can't parse the version (auto-detect arch)
        local arch=$(get_arch)
        local registry_url="ghcr.io/build-archetype/client-oven-sh-bun/bun-build-macos-${release}-${arch}:latest"
    fi
    
    log "📥 Attempting to pull from registry: $registry_url"
    if tart pull "$registry_url" 2>&1; then
        log "✅ Successfully pulled from registry"
        # Clone to expected local name
        
        # SAFETY: Ensure we're in a valid directory before tart clone operations
        # Fix for: "shell-init: error retrieving current directory: getcwd: cannot access parent directories"
        if ! pwd >/dev/null 2>&1; then
            log "⚠️  Current directory is invalid - switching to HOME for tart operations"
            cd "$HOME"
            log "   Switched to: $(pwd)"
        fi
        
        if tart clone "$registry_url" "$base_vm_image" 2>&1; then
            log "✅ Successfully cloned to local name: $base_vm_image"
            return 0
        else
            log "⚠️ Registry pull succeeded but local clone failed"
        fi
    else
        log "⚠️ Registry pull failed or image not available"
    fi
    
    # If we get here, both local and registry failed
    log "❌ Base image '$base_vm_image' not available locally or in registry"
    log "Please run the prep step to create base image first:"
    log "Run: ./scripts/build-macos-vm.sh --release=$release"
    return 1
}

# Function to get disk usage percentage
get_disk_usage() {
    df -h . | tail -1 | awk '{print $5}' | sed 's/%//'
}

# Internal function for robust VM cleanup (shared logic)
cleanup_vm_internal() {
    local vm_name="$1"
    
    # Check if VM exists first with fresh state
    if ! tart list 2>/dev/null | grep -q "^local.*$vm_name"; then
        # VM doesn't exist, consider it cleaned
        return 0
    fi
    
    # Try to stop VM first if it's running (with timeout)
    if tart list 2>/dev/null | grep "$vm_name" | grep -q "running"; then
        log "   🛑 Stopping running VM: $vm_name"
        tart stop "$vm_name" 2>/dev/null || log "     ⚠️ Failed to stop VM (may already be stopped)"
        sleep 2
        
        # Wait for VM to actually stop with timeout
        local stop_attempts=0
        while tart list 2>/dev/null | grep "$vm_name" | grep -q "running" && [ $stop_attempts -lt 5 ]; do
            log "     Waiting for VM to stop... (attempt $((stop_attempts + 1))/5)"
            sleep 2
            stop_attempts=$((stop_attempts + 1))
        done
        
        # Check if still running after timeout
        if tart list 2>/dev/null | grep "$vm_name" | grep -q "running"; then
            log "     ⚠️ VM still running after stop attempts, proceeding with delete anyway"
        fi
    fi
    
    # Delete the VM with retry logic
    local delete_attempts=0
    local max_delete_attempts=3
    
    while [ $delete_attempts -lt $max_delete_attempts ]; do
        delete_attempts=$((delete_attempts + 1))
        
        # Check again if VM still exists (state might have changed)
        if ! tart list 2>/dev/null | grep -q "^local.*$vm_name"; then
            # VM no longer exists, consider success
            return 0
        fi
        
        log "     🗑️  Deleting VM: $vm_name (attempt $delete_attempts/$max_delete_attempts)"
        
        if tart delete "$vm_name" 2>/dev/null; then
            # Verify deletion worked
            if ! tart list 2>/dev/null | grep -q "^local.*$vm_name"; then
            return 0
            fi
        fi
        
        # If we get here, deletion failed
            if [ $delete_attempts -lt $max_delete_attempts ]; then
            log "     ⚠️ Delete attempt failed, retrying in 3 seconds..."
            sleep 3
        fi
    done
    
    log "     ❌ All delete attempts failed for $vm_name"
    return 1
}

# Function to cleanup orphaned VMs
cleanup_orphaned_vms() {
    log "🧹 Cleaning up orphaned VMs..."
    local orphaned_count=0
    
    # Use a more specific pattern for TEMPORARY CI VM names only (timestamp + UUID format)
    # This matches: bun-build-1750316948-E694FB0B-BE9C-4EE9-B6D7-51ADCFE79A62
    # But NOT: bun-build-macos-13-arm64-1.2.16-bootstrap-4.1 (base images)
    local vm_pattern="bun-build-[0-9]\+-[A-F0-9]\{8\}-[A-F0-9]\{4\}-[A-F0-9]\{4\}-[A-F0-9]\{4\}-[A-F0-9]\{12\}"
    local vms_to_cleanup=()
    
    # Get list of VMs that match our TEMPORARY pattern only
    while read -r vm_name; do
        # Double-check the pattern matches temporary VM format (timestamp-UUID)
        if [[ "$vm_name" =~ ^bun-build-[0-9]+-[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$ ]]; then
            vms_to_cleanup+=("$vm_name")
            orphaned_count=$((orphaned_count + 1))
        fi
    done < <(tart list --quiet 2>/dev/null | grep "^bun-build-" | awk '{print $1}' || true)
    
    if [ ${#vms_to_cleanup[@]} -eq 0 ]; then
        log "✅ No orphaned temporary VMs found"
        return 0
    fi
    
    log "Found $orphaned_count orphaned TEMPORARY VM(s) to clean up:"
    for vm_name in "${vms_to_cleanup[@]}"; do
        log "  - $vm_name (temporary build VM)"
    done
    
    # Clean up each orphaned VM
    local cleaned=0
    for vm_name in "${vms_to_cleanup[@]}"; do
        log "🗑️  Cleaning up orphaned temporary VM: $vm_name"
        
        # Use the robust cleanup_vm function for each orphaned VM
        if cleanup_vm_internal "$vm_name"; then
            log "✅ Successfully cleaned up: $vm_name"
            cleaned=$((cleaned + 1))
        else
            log "⚠️  Failed to clean up: $vm_name (may require manual intervention)"
        fi
    done
    
    log "🧹 Orphaned temporary VM cleanup complete: $cleaned/$orphaned_count VMs cleaned"
    log "📌 Base VMs (bun-build-macos-*) are preserved and not affected"
    return 0
}

# Function to cleanup single VM with better error handling
cleanup_vm() {
    local vm_name="$1"
    
    log "🧹 Cleaning up VM: $vm_name"
    
    if cleanup_vm_internal "$vm_name"; then
        log "✅ Successfully deleted VM: $vm_name"
        return 0
    else
    log "⚠️ All delete attempts failed, VM $vm_name may be orphaned"
    log "   Manual cleanup may be required: tart delete $vm_name"
    return 1
    fi
}

# Function to setup cache environment
setup_cache_environment() {
    log "🔑 Setting up cache environment..."
    
    # Try to get the BUN_CACHE_API_TOKEN secret if we're in Buildkite
    if command -v buildkite-agent >/dev/null 2>&1; then
        log "Retrieving BUN_CACHE_API_TOKEN from Buildkite secrets..."
        
        if BUN_CACHE_TOKEN=$(buildkite-agent secret get BUN_CACHE_API_TOKEN 2>/dev/null); then
            export BUN_CACHE_API_TOKEN="$BUN_CACHE_TOKEN"
            log "✅ BUN_CACHE_API_TOKEN retrieved successfully"
        else
            log "⚠️  BUN_CACHE_API_TOKEN secret not found or inaccessible"
            log "   Cache detection will be limited to environment variables only"
            log "   To enable full cache detection, create secret: BUN_CACHE_API_TOKEN"
        fi
    else
        log "⚠️  buildkite-agent not available on host"
        log "   Cache detection will use environment variables only"
    fi
}

# Function to create and run VM
create_and_run_vm() {
    local vm_name="$1"
    local command="$2"
    local workspace_dir="$3"
    local release="${4:-14}"

    # Determine base VM image
    local base_vm_image
    if [ -n "$BASE_VM_IMAGE" ]; then
        base_vm_image="$BASE_VM_IMAGE"
    else
        base_vm_image=$(get_base_vm_image "$release")
    fi

    log "Creating VM: $vm_name from base: $base_vm_image"
    
    # Simple clone - assume base VM exists and works
    if ! tart clone "$base_vm_image" "$vm_name"; then
        log "❌ Failed to clone VM"
        exit 1
    fi
    
    # Set up cleanup trap
    cleanup_trap() {
        cleanup_vm "$vm_name"
    }
    trap cleanup_trap EXIT INT TERM
    
    # Start VM with workspace mount
    log "Starting VM with workspace: $workspace_dir"
    tart run "$vm_name" --no-graphics --dir=workspace:"$workspace_dir" > vm.log 2>&1 &
    
    # Wait for VM to be ready
    sleep 10
    
    # Verify VM started
    if ! tart list | grep "$vm_name" | grep -q "running"; then
        log "❌ VM failed to start"
        exit 1
    fi
    
    log "✅ VM running - executing command"

    # Execute the command
    ./scripts/run-vm-command.sh "$vm_name" "$command"

    # Upload logs
    buildkite-agent artifact upload vm.log || true

    # Cleanup
    cleanup_vm "$vm_name"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS] [COMMAND] [WORKSPACE_DIR]"
    echo ""
    echo "Options:"
    echo "  --help                    Show this help message"
    echo "  --release=VERSION         macOS release version (13, 14) [default: 14]"
    echo "  --cleanup-orphaned        Clean up orphaned temporary VMs"
    echo ""
    echo "Examples:"
    echo "  $0                                           # Run default build on macOS 14"
    echo "  $0 --release=13                              # Run default build on macOS 13"
    echo "  $0 'bun run build:release'                  # Run custom command"
}

# Main execution
main() {
    # Parse arguments
    local release="14"  # Default to macOS 14
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_usage
                exit 0
                ;;
            --release=*)
                release="${1#*=}"
                shift
                ;;
            --cleanup-orphaned)
                cleanup_orphaned_vms
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done
    
    # Clean up any orphaned VMs from previous builds
    cleanup_orphaned_vms
    
    # Generate a unique VM name
    local vm_name="bun-build-$(date +%s)-$(uuidgen)"
    
    # Get the command to run
    local command="${1:-./scripts/runner.node.mjs --step=darwin-x64-build-bun}"
    
    # Get workspace directory
    local workspace_dir="${2:-$PWD}"

    log "Starting build process..."
    log "VM Name: $vm_name"
    log "Command: $command"
    log "Workspace: $workspace_dir"

    # Setup cache environment if needed
    setup_cache_environment

    create_and_run_vm "$vm_name" "$command" "$workspace_dir" "$release"
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 