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
    local bun_version="${2:-1.2.16}"
    local bootstrap_version="${3:-3.6}"
    echo "bun-build-macos-${release}-${bun_version}-bootstrap-${bootstrap_version}"
}

# SSH options for VM connectivity
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# Function to get disk usage percentage
get_disk_usage() {
    df -h . | tail -1 | awk '{print $5}' | sed 's/%//'
}


# Function to extract bootstrap version from bootstrap-macos.sh
get_bootstrap_version() {
    local bootstrap_file="${1:-scripts/bootstrap-macos.sh}"
    if [ -f "$bootstrap_file" ]; then
        # Extract version from comment line: # Version: 3.6 - Description
        grep -m1 "^# Version:" "$bootstrap_file" | sed 's/^# Version: *\([0-9.]*\).*/\1/'
    else
        echo "3.6"  # fallback
    fi
}

# Function to clean up temporary VMs before creating new ones
cleanup_temporary_vms() {
    log "🧹 ===== CLEANING UP TEMPORARY VMS ====="
    
    local current_bootstrap_version=$(get_bootstrap_version)
    local cleaned_count=0
    local space_freed=0
    
    log "Current bootstrap version detected: $current_bootstrap_version"
    
    # Get list of all local VMs
    local tart_output=$(tart list 2>/dev/null || echo "")
    
    if [ -z "$tart_output" ]; then
        log "No VMs found or tart command failed"
        return 0
    fi
    
    # Clean up temporary build VMs (UUID-named)
    log "🗑️  Removing temporary build VMs..."
    while IFS= read -r line; do
        if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+)[[:space:]]+[0-9]+[[:space:]]+([0-9]+)[[:space:]]+[0-9]+[[:space:]]+stopped ]]; then
            local vm_name="${BASH_REMATCH[1]}"
            local size_gb="${BASH_REMATCH[2]}"
            
            # Match temporary build VMs: bun-build-{timestamp}-{UUID}
            if [[ "$vm_name" =~ ^bun-build-[0-9]+-[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$ ]]; then
                log "    Deleting temporary VM: $vm_name (${size_gb}GB)"
                if tart delete "$vm_name" 2>/dev/null; then
                    log "    ✅ Deleted successfully"
                    cleaned_count=$((cleaned_count + 1))
                    space_freed=$((space_freed + size_gb))
                else
                    log "    ⚠️  Failed to delete"
                fi
            fi
        fi
    done <<< "$tart_output"
    
    # Clean up outdated base images (old bootstrap versions)
    log "🗑️  Removing outdated base images..."
    while IFS= read -r line; do
        if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+)[[:space:]]+[0-9]+[[:space:]]+([0-9]+)[[:space:]]+[0-9]+[[:space:]]+stopped ]]; then
            local vm_name="${BASH_REMATCH[1]}"
            local size_gb="${BASH_REMATCH[2]}"
            
            # Match base images with bootstrap versions
            if [[ "$vm_name" =~ ^bun-build-macos-[0-9]+-.*-bootstrap-(.+)$ ]]; then
                local bootstrap_version="${BASH_REMATCH[1]}"
                
                # Only delete if bootstrap version is NOT current
                if [[ "$bootstrap_version" != "$current_bootstrap_version" ]]; then
                    log "    Deleting outdated base image: $vm_name (bootstrap-${bootstrap_version} != current-${current_bootstrap_version}) (${size_gb}GB)"
                    if tart delete "$vm_name" 2>/dev/null; then
                        log "    ✅ Deleted successfully"
                        cleaned_count=$((cleaned_count + 1))
                        space_freed=$((space_freed + size_gb))
                    else
                        log "    ⚠️  Failed to delete"
                    fi
                fi
            fi
        fi
    done <<< "$tart_output"
    
    # Clean up redundant arch-specific images (keep only generic ones)
    log "🗑️  Removing redundant architecture-specific images..."
    while IFS= read -r line; do
        if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+)[[:space:]]+[0-9]+[[:space:]]+([0-9]+)[[:space:]]+[0-9]+[[:space:]]+stopped ]]; then
            local vm_name="${BASH_REMATCH[1]}"
            local size_gb="${BASH_REMATCH[2]}"
            
            # Match arch-specific images: bun-build-macos-{release}-{arch}-{version}-bootstrap-{bootstrap}
            if [[ "$vm_name" =~ ^bun-build-macos-[0-9]+-arm64-.*-bootstrap-.*$ ]] || 
               [[ "$vm_name" =~ ^bun-build-macos-[0-9]+-x64-.*-bootstrap-.*$ ]]; then
                log "    Deleting redundant arch-specific image: $vm_name (${size_gb}GB)"
                log "    (Generic images work for all architectures)"
                if tart delete "$vm_name" 2>/dev/null; then
                    log "    ✅ Deleted successfully"
                    cleaned_count=$((cleaned_count + 1))
                    space_freed=$((space_freed + size_gb))
                else
                    log "    ⚠️  Failed to delete"
                fi
            fi
        fi
    done <<< "$tart_output"
    
    log "✅ Cleanup complete: Removed $cleaned_count VMs, freed ${space_freed}GB"
    log "=== END CLEANUP ==="
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
    local release="${4:-14}"  # Default to macOS 14 if not specified

    # Determine the correct base VM image for this release
    local base_vm_image
    if [ -n "$BASE_VM_IMAGE" ]; then
        base_vm_image="$BASE_VM_IMAGE"
        log "Using explicit base VM image: $base_vm_image"
    else
        base_vm_image=$(get_base_vm_image "$release")
        log "Using release-specific base VM image: $base_vm_image"
    fi

    log "=== INITIAL TART STATE ==="
    log "Available Tart VMs:"
    tart list || log "Failed to list VMs"
    log "=========================="

    # Monitor disk usage for awareness but take NO cleanup action during build phases
    local current_usage=$(get_disk_usage)
    log "Current disk usage: ${current_usage}%"
    if [ "$current_usage" -gt "$DISK_USAGE_THRESHOLD" ]; then
        log "⚠️  WARNING: Disk usage at ${current_usage}% exceeds threshold (${DISK_USAGE_THRESHOLD}%)"
        log "    Build phases perform NO cleanup - this is handled in VM preparation step"
        log "    If needed, run cleanup manually: ./scripts/build-macos-vm.sh (includes cleanup)"
    fi


    # Clean up temporary VMs before creating new ones
    cleanup_temporary_vms    # BUILD PHASES DO NO CLEANUP - this is handled in VM preparation step
    # We assume base images exist and temporary VMs are managed by preparation step

    # Start logging
    start_logging

    # Create and run VM
    log "Creating VM: $vm_name"
    log "Using base image: $base_vm_image"
    log "For macOS release: $release"
    
    # Check if forced rebuild is requested
    if [ "$FORCE_BASE_IMAGE_REBUILD" = "true" ]; then
        log "🔄 Force rebuild requested - please run image prep step manually"
        log "Run: ./scripts/build-macos-vm.sh --release=$release --force-refresh"
        exit 1
    fi
    
    # Check if base image exists (simple check - no validation)
    if ! tart list | grep -q "^local.*$base_vm_image"; then
        log "❌ Base image '$base_vm_image' not found!"
        log "Please run the prep step to create base image first"
        log "Run: ./scripts/build-macos-vm.sh --release=$release"
        exit 1
    fi
    
    log "✅ Base image found - cloning VM"
    tart clone "$base_vm_image" "$vm_name"
    
    log "Setting VM resources..."
    tart set "$vm_name" --cpu=6 --memory=16384
    
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

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS] [COMMAND] [WORKSPACE_DIR]"
    echo ""
    echo "Options:"
    echo "  --help                    Show this help message"
    echo "  --force-base-rebuild      Force rebuild of base image before use"
    echo "  --release=VERSION         macOS release version (13, 14) [default: 14]"
    echo ""
    echo "Environment Variables:"
    echo "  BASE_VM_IMAGE             Base VM image to clone (auto-determined if not set)"
    echo "  FORCE_BASE_IMAGE_REBUILD  Set to 'true' to force base image rebuild (default: false)"
    echo ""
    echo "Examples:"
    echo "  $0                                           # Run default build on macOS 14"
    echo "  $0 --release=13                              # Run default build on macOS 13"
    echo "  $0 'bun run build:release'                  # Run custom command"
    echo "  $0 --force-base-rebuild --release=13        # Force rebuild base image for macOS 13"
    echo "  BASE_VM_IMAGE=my-custom-image $0            # Use custom base image"
    echo ""
    echo "Note: For VM cleanup, use ./scripts/build-macos-vm.sh which handles all cleanup operations"
}

# Main execution
main() {
    # Parse arguments
    local show_help=false
    local release="14"  # Default to macOS 14
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help=true
                shift
                ;;
            --force-base-rebuild)
                FORCE_BASE_IMAGE_REBUILD=true
                shift
                ;;
            --release=*)
                release="${1#*=}"
                shift
                ;;
            *)
                break
                ;;
        esac
    done
    
    if [ "$show_help" = true ]; then
        show_usage
        exit 0
    fi
    
    # BUILD PHASES ONLY - no cleanup functionality
    # All cleanup is handled by VM preparation step (build-macos-vm.sh)
    
    # Generate a unique VM name
    local vm_name="bun-build-$(date +%s)-$(uuidgen)"
    
    # Get the command to run (default to build command if none provided)
    local command="${1:-./scripts/runner.node.mjs --step=darwin-x64-build-bun}"
    
    # Get the workspace directory (default to current directory)
    local workspace_dir="${2:-$PWD}"

    log "Starting build process..."
    log "Configuration:"
    log "  macOS Release: $release"
    log "  BASE_VM_IMAGE override: ${BASE_VM_IMAGE:-<auto-determined>}"
    log "  FORCE_BASE_IMAGE_REBUILD: $FORCE_BASE_IMAGE_REBUILD"
    log "VM Name: $vm_name"
    log "Command: $command"
    log "Workspace: $workspace_dir"

    create_and_run_vm "$vm_name" "$command" "$workspace_dir" "$release"
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 