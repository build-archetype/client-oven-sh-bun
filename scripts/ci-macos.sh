#!/bin/bash
set -euo pipefail

# Function to log messages with timestamps
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to get Bun version - same logic as build-macos-vm.sh
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
        version=$(git describe --tags --always --dirty 2>/dev/null | sed 's/^bun-v//' | sed 's/^v//' || echo "1.2.16")
    fi
    
    # Clean up version string
    version=${version#v}
    version=${version#bun-}
    
    # Validate version format
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        log "Warning: Invalid version format '$version', using fallback"
        version="1.2.16"
    fi
    
    echo "$version"
}

# Function to get architecture
get_arch() {
    local arch=$(uname -m)
    case "$arch" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64) echo "x64" ;;
        *) echo "arm64" ;; # Default to arm64 for macOS
    esac
}

# Function to find the best matching base image
find_base_image() {
    local release="$1"
    local arch=$(get_arch)
    local bun_version=$(get_bun_version)
    local bootstrap_version="4.1"  # Current bootstrap version
    
    # Try exact match first: bun-build-macos-${release}-${arch}-${bun_version}-bootstrap-${bootstrap_version}
    local exact_image="bun-build-macos-${release}-${arch}-${bun_version}-bootstrap-${bootstrap_version}"
    log "Looking for exact match: $exact_image"
    
    if tart list | grep -q "^local.*${exact_image}"; then
        log "✅ Found exact match: $exact_image"
        echo "$exact_image"
        return 0
    fi
    
    # Try to find any image for this release and architecture
    log "Exact match not found, looking for any ${release}-${arch} image..."
    local pattern="bun-build-macos-${release}-${arch}-"
    local found_image=$(tart list | grep "^local" | grep "$pattern" | head -1 | awk '{print $2}' || echo "")
    
    if [ -n "$found_image" ]; then
        log "✅ Found compatible image: $found_image"
        echo "$found_image"
        return 0
    fi
    
    # Fallback: try to find any bun-build-macos image
    log "No release-specific image found, looking for any bun-build-macos image..."
    local fallback_image=$(tart list | grep "^local" | grep "bun-build-macos" | head -1 | awk '{print $2}' || echo "")
    
    if [ -n "$fallback_image" ]; then
        log "⚠️  Using fallback image: $fallback_image"
        echo "$fallback_image"
        return 0
    fi
    
    log "❌ No suitable base image found!"
    log "Available images:"
    tart list
    return 1
}

# Function to clean up VMs
cleanup_vms() {
    log "Cleaning up stopped VMs..."
    tart list | awk '/stopped/ && $1 == "local" && $2 ~ /^bun-build-[0-9]+-[0-9a-f-]+$/ {print $2}' | xargs -n1 tart delete || true
}

# Function to start logging
start_logging() {
    log "Starting Tart logging..."
    log stream --predicate 'process == "tart" OR process CONTAINS "Virtualization"' > tart.log 2>&1 &
    TART_LOG_PID=$!
    trap 'if [ -n "$TART_LOG_PID" ]; then kill $TART_LOG_PID 2>/dev/null || true; fi; buildkite-agent artifact upload tart.log || true' EXIT
}

# Function to create and run VM
create_and_run_vm() {
    local vm_name="$1"
    local command="$2"
    local workspace_dir="$3"
    local release="$4"

    log "=== INITIAL TART STATE ==="
    log "Available Tart VMs:"
    tart list || log "Failed to list VMs"
    log "=========================="

    # Clean up any existing stopped VMs
    cleanup_vms

    # Start logging
    start_logging

    # Find the base image to use
    local base_image
    if ! base_image=$(find_base_image "$release"); then
        log "❌ Failed to find suitable base image"
        exit 1
    fi

    # Create and run VM
    log "Creating VM: $vm_name"
    log "Using base image: $base_image"
    tart clone "$base_image" "$vm_name"
    
    log "Starting VM with workspace: $workspace_dir"
    tart run "$vm_name" --no-graphics --dir=workspace:"$workspace_dir" > vm.log 2>&1 &
    
    # Wait for VM to be ready
    log "Waiting for VM to be ready..."
    sleep 30

    # Make run-vm-command.sh executable
    chmod +x ./scripts/run-vm-command.sh

    # Execute the command
    log "Executing command in VM: $command"
    ./scripts/run-vm-command.sh "$vm_name" "$command"

    # Upload logs
    buildkite-agent artifact upload vm.log || true

    # Cleanup
    log "Checking VM status before cleanup..."
    if tart list | grep -q "$vm_name"; then
        log "VM $vm_name exists, deleting..."
        tart delete "$vm_name" || true
    else
        log "VM $vm_name not found - may have been cleaned up earlier or crashed"
    fi

    log "=== FINAL TART STATE ==="
    log "Available Tart VMs:"
    tart list || log "Failed to list VMs"
    log "========================"
}

# Main execution
main() {
    # Parse arguments
    local release="14"  # Default to macOS 14
    local command=""
    local workspace_dir="$PWD"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --release=*)
                release="${1#*=}"
                shift
                ;;
            --release)
                release="$2"
                shift 2
                ;;
            *)
                # First non-option argument is the command
                if [ -z "$command" ]; then
                    command="$1"
                else
                    # Second non-option argument is workspace dir
                    workspace_dir="$1"
                fi
                shift
                ;;
        esac
    done
    
    # Set default command if none provided
    if [ -z "$command" ]; then
        command="./scripts/runner.node.mjs --step=darwin-x64-build-bun"
    fi

    # Generate a unique VM name
    local vm_name="bun-build-$(date +%s)-$(uuidgen)"

    log "Starting build process..."
    log "Configuration:"
    log "  macOS Release: $release"
    log "  Cache Restore: false"
    log "  Cache Save: false"
    log "  BASE_VM_IMAGE override: <auto-determined>"
    log "  FORCE_BASE_IMAGE_REBUILD: false"
    log "VM Name: $vm_name"
    log "Command: $command"
    log "Workspace: $workspace_dir"

    create_and_run_vm "$vm_name" "$command" "$workspace_dir" "$release"
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 