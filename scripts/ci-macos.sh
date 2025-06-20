#!/bin/bash
set -euo pipefail

# SSH options for VM connectivity
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# Function to log messages with timestamps
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Get Bun version from package.json (same logic as build-macos-vm.sh)
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
        version="1.2.14"
    fi
    
    echo "$version"
}

# Get bootstrap version from the bootstrap script (same logic as build-macos-vm.sh)
get_bootstrap_version() {
    local script_path="$1"
    if [ ! -f "$script_path" ]; then
        echo "14"  # fallback
        return
    fi
    
    # Extract version from comment like "# Version: 14 - description"
    local version=$(grep -E "^# Version: " "$script_path" | sed -E 's/^# Version: ([0-9.]+).*/\1/' | head -1)
    if [ -n "$version" ]; then
        echo "$version"
    else
        echo "14"  # fallback
    fi
}

# Function to get base VM image name (now dynamic!)
get_base_vm_image() {
    local release="${1:-14}"
    local arch="arm64"  # Default to arm64 for Apple Silicon
    
    # Get versions dynamically (same as build-macos-vm.sh)
    local bun_version=$(get_bun_version)
    local bootstrap_version=$(get_bootstrap_version "scripts/bootstrap_new.sh")
    
    echo "bun-build-macos-${release}-${arch}-${bun_version}-bootstrap-${bootstrap_version}"
}

# Function to cleanup VM
cleanup_vm() {
    local vm_name="$1"
    log "🧹 Cleaning up VM: $vm_name"
    
    # Stop VM if running
    tart stop "$vm_name" 2>/dev/null || true
    sleep 2
    
    # Delete VM
    tart delete "$vm_name" 2>/dev/null || true
    log "✅ VM cleaned up: $vm_name"
}

# Main function to create and run VM
create_and_run_vm() {
    local vm_name="$1"
    local command="$2"
    local workspace_dir="$3"
    local release="${4:-14}"

    # DEBUG: Show what VMs are available at the start
    log "🔍 DEBUG: Available VMs at start of create_and_run_vm:"
    tart list || log "Failed to list VMs"
    
    log "🔍 DEBUG: Looking for base VMs specifically:"
    tart list | grep "bun-build-macos" || log "No bun-build-macos VMs found"

    # Get base VM name
    local base_vm_image=$(get_base_vm_image "$release")
    
    log "🔍 DEBUG: Target base VM name: $base_vm_image"
    
    # Check if base VM exists
    if ! tart list | grep -q "^local.*$base_vm_image"; then
        log "❌ Base VM not found: $base_vm_image"
        log "🔍 DEBUG: Exact VMs available:"
        tart list | while read -r line; do
            log "  $line"
        done
        log "Run: ./scripts/build-macos-vm.sh --release=$release"
        exit 1
    fi
    
    log "Creating VM: $vm_name from base: $base_vm_image"
    
    # Clone VM
    if ! tart clone "$base_vm_image" "$vm_name"; then
        log "❌ Failed to clone VM"
        exit 1
    fi
    
    # Set up cleanup trap
    trap "cleanup_vm '$vm_name'" EXIT INT TERM
    
    # Start VM
    log "Starting VM with workspace: $workspace_dir"
    tart run "$vm_name" --no-graphics --dir=workspace:"$workspace_dir" >/dev/null 2>&1 &
    
    # Wait for VM to boot
    sleep 5
    
    log "✅ VM started - executing command via run-vm-command.sh"
    
    # Use existing run-vm-command.sh script to handle all the SSH complexity
    ./scripts/run-vm-command.sh "$vm_name" "$command"
    
    log "✅ Command completed"
}

# Main execution
main() {
    local release="14"
    
    # Parse basic arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --release=*)
                release="${1#*=}"
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [--release=13|14] [COMMAND] [WORKSPACE_DIR]"
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done
    
    # Generate unique VM name
    local vm_name="bun-build-$(date +%s)-$(uuidgen)"
    
    # Get command and workspace
    local command="${1:-bun run build:release}"
    local workspace_dir="${2:-$PWD}"

    log "Starting simple VM build..."
    log "VM: $vm_name"
    log "Command: $command"
    log "Workspace: $workspace_dir"

    create_and_run_vm "$vm_name" "$command" "$workspace_dir" "$release"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 