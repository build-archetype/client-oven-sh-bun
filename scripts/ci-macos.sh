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
    
    # Clean up ALL temporary VMs (any VM starting with tmp-) - stop them first if running
    log "🗑️  Removing ALL temporary VMs (tmp-*)..."
    while IFS= read -r line; do
        # Skip header line and empty lines
        [[ "$line" =~ ^(Source|local|OCI)[[:space:]] ]] || continue
        [[ "$line" =~ ^Source ]] && continue
        
        # Parse the line - Format: local  VM_NAME  DISK_SIZE  SIZE_ON_DISK  SIZE_ON_DISK  STATE
        if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+(.+) ]]; then
            local vm_name="${BASH_REMATCH[1]}"
            local size_gb="${BASH_REMATCH[3]}"  # Use SizeOnDisk (3rd number)
            local state="${BASH_REMATCH[5]}"
            
            # Match ANY VM starting with tmp-
            if [[ "$vm_name" =~ ^tmp- ]]; then
                log "    Found temporary VM: $vm_name (${size_gb}GB, $state)"
                
                # Stop VM if it's running
                if [[ "$state" == "running" ]]; then
                    log "    Stopping running VM: $vm_name"
                    if tart stop "$vm_name" 2>/dev/null; then
                        log "    ✅ Stopped successfully"
                        # Wait a moment for VM to fully stop
                        sleep 3
                    else
                        log "    ⚠️  Failed to stop, will try to delete anyway"
                    fi
                fi
                
                # Delete the VM
                log "    Deleting VM: $vm_name"
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
    
    # Clean up legacy temporary build VMs (any bun-build VM without 'bootstrap' in name)
    log "🗑️  Removing legacy temporary build VMs (bun-build* without 'bootstrap')..."
    while IFS= read -r line; do
        # Skip header line and empty lines
        [[ "$line" =~ ^(Source|local|OCI)[[:space:]] ]] || continue
        [[ "$line" =~ ^Source ]] && continue
        
        # Parse the line - Format: local  VM_NAME  DISK_SIZE  SIZE_ON_DISK  SIZE_ON_DISK  STATE
        if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+(.+) ]]; then
            local vm_name="${BASH_REMATCH[1]}"
            local size_gb="${BASH_REMATCH[3]}"  # Use SizeOnDisk (3rd number)
            local state="${BASH_REMATCH[5]}"
            
            # Match any bun-build VM that doesn't contain 'bootstrap'
            if [[ "$vm_name" =~ ^bun-build ]] && [[ ! "$vm_name" =~ bootstrap ]]; then
                log "    Found legacy temporary VM: $vm_name (${size_gb}GB, $state)"
                
                # Stop VM if it's running
                if [[ "$state" == "running" ]]; then
                    log "    Stopping running VM: $vm_name"
                    if tart stop "$vm_name" 2>/dev/null; then
                        log "    ✅ Stopped successfully"
                        sleep 3
                    else
                        log "    ⚠️  Failed to stop, will try to delete anyway"
                    fi
                fi
                
                # Delete the VM
                log "    Deleting VM: $vm_name"
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
        # Skip header line and empty lines
        [[ "$line" =~ ^(Source|local|OCI)[[:space:]] ]] || continue
        [[ "$line" =~ ^Source ]] && continue
        
        if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+stopped ]]; then
            local vm_name="${BASH_REMATCH[1]}"
            local size_gb="${BASH_REMATCH[3]}"  # Use SizeOnDisk (3rd number)
            
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
    
    # Clean up duplicate OCI images (keep only latest tag, remove SHA versions)
    log "🗑️  Removing duplicate OCI images..."
    while IFS= read -r line; do
        # Skip header line and empty lines
        [[ "$line" =~ ^(Source|local|OCI)[[:space:]] ]] || continue
        [[ "$line" =~ ^Source ]] && continue
        
        if [[ "$line" =~ ^OCI[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+stopped ]]; then
            local vm_name="${BASH_REMATCH[1]}"
            local size_gb="${BASH_REMATCH[3]}"  # Use SizeOnDisk (3rd number)
            
            # Remove SHA-based OCI images (keep only tag-based ones)
            if [[ "$vm_name" =~ @sha256: ]]; then
                log "    Deleting duplicate OCI SHA image: $vm_name (${size_gb}GB)"
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
    
    # Set VM resources for better build performance
    log "Setting VM resources: 6 CPUs, 10GB RAM..."
    tart set "$vm_name" --cpu 6 --memory 10240  # 10240 MB = 10 GB
    
    # Set current VM name for cleanup trap
    export CURRENT_VM_NAME="$vm_name"
    
    log "Starting VM with allocated resources (6 CPUs + 10GB)..."
    tart run "$vm_name" --no-graphics > vm.log 2>&1 &
    
    # Give VM a moment to start, then let run-vm-command.sh handle readiness checking
    log "VM started, letting run-vm-command.sh handle readiness and workspace setup..."
    sleep 5

    # Make run-vm-command.sh executable
    chmod +x ./scripts/run-vm-command.sh

    # Execute the command - run-vm-command.sh will handle VM readiness checking and workspace setup
    log "Executing command in VM: $command"
    ./scripts/run-vm-command.sh "$vm_name" "$command"

    # Upload logs
    buildkite-agent artifact upload vm.log || true

    # VM cleanup is now handled by the exit trap
    log "VM cleanup will be handled by exit trap"

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

# Function to ensure cleanup on exit
cleanup_on_exit() {
    local exit_code=$?
    log "🧹 Exit cleanup triggered (exit code: $exit_code)"
    
    # Clean up specific VM if it was created
    if [ -n "${CURRENT_VM_NAME:-}" ]; then
        log "Cleaning up current VM: $CURRENT_VM_NAME"
        if tart list | grep -q "$CURRENT_VM_NAME"; then
            log "VM $CURRENT_VM_NAME exists, stopping and deleting..."
            # Stop VM first if it's running
            if tart list | grep -q "$CURRENT_VM_NAME.*running"; then
                log "Stopping running VM: $CURRENT_VM_NAME"
                tart stop "$CURRENT_VM_NAME" 2>/dev/null || log "Failed to stop $CURRENT_VM_NAME"
                sleep 2
            fi
            # Delete the VM
            tart delete "$CURRENT_VM_NAME" 2>/dev/null || log "Failed to delete $CURRENT_VM_NAME"
        else
            log "VM $CURRENT_VM_NAME not found - may have been cleaned up earlier"
        fi
    fi
    
    # Clean up any remaining tmp VMs - stop them first if running
    log "Final cleanup of all tmp VMs..."
    local tart_output=$(tart list 2>/dev/null || echo "")
    while IFS= read -r line; do
        [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+(.+) ]] || continue
        local vm_name="${BASH_REMATCH[1]}"
        local state="${BASH_REMATCH[5]}"
        if [[ "$vm_name" =~ ^tmp- ]]; then
            log "Final cleanup: found $vm_name ($state)"
            # Stop if running
            if [[ "$state" == "running" ]]; then
                log "Stopping running VM: $vm_name"
                tart stop "$vm_name" 2>/dev/null || log "Failed to stop $vm_name"
                sleep 2
            fi
            # Delete the VM
            log "Deleting VM: $vm_name"
            tart delete "$vm_name" 2>/dev/null || log "Failed to delete $vm_name"
        fi
    done <<< "$tart_output"
    
    # Kill logging process if it exists
    if [ -n "${TART_LOG_PID:-}" ]; then
        kill $TART_LOG_PID 2>/dev/null || true
        buildkite-agent artifact upload tart.log 2>/dev/null || true
    fi
    
    exit $exit_code
}

# Set up cleanup trap
trap cleanup_on_exit EXIT INT TERM

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
    
    # Generate a unique VM name with tmp prefix for easy cleanup
    local vm_name="tmp-bun-build-$(printf "%05d" $((RANDOM % 100000)))"
    
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