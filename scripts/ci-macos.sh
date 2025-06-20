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
    local arch="${2:-arm64}"  # Default to arm64 for Apple Silicon
    local bun_version="${3:-1.2.16}"
    # Auto-detect bootstrap version from script (single source of truth)
    local bootstrap_version="${4:-$(get_bootstrap_version)}"
    echo "bun-build-macos-${release}-${arch}-${bun_version}-bootstrap-${bootstrap_version}"
}

# Get bootstrap version from the bootstrap script (single source of truth)
get_bootstrap_version() {
    local script_path="scripts/bootstrap_new.sh"  # Updated to use bootstrap_new.sh
    if [ ! -f "$script_path" ]; then
        echo "14"  # Updated fallback from 4.0 to 14
        return
    fi
    
    # Extract version from comment like "# Version: 14 - description"
    local version=$(grep -E "^# Version: " "$script_path" | sed -E 's/^# Version: ([0-9.]+).*/\1/' | head -1)
    if [ -n "$version" ]; then
        echo "$version"
    else
        echo "14"  # Updated fallback from 4.0 to 14
    fi
} # SSH options for VM connectivity
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
    # Extract version info from image name: bun-build-macos-13-1.2.16-bootstrap-4.1
    if [[ "$base_vm_image" =~ bun-build-macos-([0-9]+)-([0-9]+\.[0-9]+\.[0-9]+)-bootstrap-([0-9]+\.[0-9]+) ]]; then
        local macos_release="${BASH_REMATCH[1]}"
        local bun_version="${BASH_REMATCH[2]}"
        local bootstrap_version="${BASH_REMATCH[3]}"
        local registry_url="ghcr.io/build-archetype/client-oven-sh-bun/bun-build-macos-${macos_release}:${bun_version}-bootstrap-${bootstrap_version}"
    else
        # Fallback to latest if we can't parse the version
        local registry_url="ghcr.io/build-archetype/client-oven-sh-bun/bun-build-macos-${release}:latest"
    fi
    
    log "📥 Attempting to pull from registry: $registry_url"
    if tart pull "$registry_url" 2>&1; then
        log "✅ Successfully pulled from registry"
        # Clone to expected local name
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

# Function to clean up orphaned temporary VMs
cleanup_orphaned_vms() {
    log "🧹 Cleaning up orphaned temporary VMs..."
    
    local cleaned_count=0
    local total_size_freed=0
    
    # Find all temporary VMs (pattern: bun-build-TIMESTAMP-UUID)
    while IFS= read -r line; do
        if [[ "$line" =~ ^local[[:space:]]+bun-build-[0-9]+-[A-F0-9-]+[[:space:]] ]]; then
            local vm_name=$(echo "$line" | awk '{print $2}')
            local size=$(echo "$line" | awk '{print $4}')
            
            log "🗑️  Deleting orphaned temporary VM: $vm_name (${size}GB)"
            if tart delete "$vm_name"; then
                log "✅ Successfully deleted $vm_name"
                cleaned_count=$((cleaned_count + 1))
                total_size_freed=$((total_size_freed + size))
            else
                log "❌ Failed to delete $vm_name"
            fi
        fi
    done <<< "$(tart list 2>/dev/null || echo '')"
    
    if [ $cleaned_count -gt 0 ]; then
        log "🎉 Cleaned up $cleaned_count orphaned VMs, freed ${total_size_freed}GB"
    else
        log "✅ No orphaned temporary VMs found"
    fi
}

# Function to cleanup single VM with better error handling
cleanup_vm() {
    local vm_name="$1"
    
    log "🧹 Cleaning up VM: $vm_name"
    
    # Check if VM exists first
    if ! tart list | grep -q "^local.*$vm_name"; then
        log "✅ VM $vm_name already deleted or doesn't exist"
        return 0
    fi
    
    # Try to stop VM first if it's running (with timeout)
    if tart list | grep "$vm_name" | grep -q "running"; then
        log "🛑 Stopping running VM: $vm_name"
        tart stop "$vm_name" || log "⚠️ Failed to stop VM (may already be stopped)"
        sleep 2
        
        # Wait for VM to actually stop
        local stop_attempts=0
        while tart list | grep "$vm_name" | grep -q "running" && [ $stop_attempts -lt 10 ]; do
            log "   Waiting for VM to stop... (attempt $((stop_attempts + 1))/10)"
            sleep 2
            stop_attempts=$((stop_attempts + 1))
        done
        
        # Force kill if still running
        if tart list | grep "$vm_name" | grep -q "running"; then
            log "⚠️ VM still running after stop attempts, this may indicate a problem"
        fi
    fi
    
    # Delete the VM with retry logic
    local delete_attempts=0
    local max_delete_attempts=3
    
    while [ $delete_attempts -lt $max_delete_attempts ]; do
        delete_attempts=$((delete_attempts + 1))
        log "🗑️  Deleting VM: $vm_name (attempt $delete_attempts/$max_delete_attempts)"
        
        if tart delete "$vm_name" 2>/dev/null; then
            log "✅ Successfully deleted VM: $vm_name"
            return 0
        else
            log "❌ Failed to delete VM: $vm_name (attempt $delete_attempts)"
            if [ $delete_attempts -lt $max_delete_attempts ]; then
                log "   Retrying in 5 seconds..."
                sleep 5
            fi
        fi
    done
    
    # Final attempt with force if available
    log "⚠️ All delete attempts failed, VM $vm_name may be orphaned"
    log "   Manual cleanup may be required: tart delete $vm_name"
    return 1
}

# Function to start logging
start_logging() {
    log "Starting Tart logging..."
    log stream --predicate 'process == "tart" OR process CONTAINS "Virtualization"' > tart.log 2>&1 &
    TART_LOG_PID=$!
    trap 'if [ -n "$TART_LOG_PID" ]; then kill $TART_LOG_PID 2>/dev/null || true; fi; buildkite-agent artifact upload tart.log || true' EXIT
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
    local release="${4:-14}"  # Default to macOS 14 if not specified

    # Fail-safe: Clean up any orphaned VMs from previous failed builds FIRST
    log "🧹 Performing fail-safe cleanup of orphaned VMs..."
    cleanup_orphaned_vms

    # Make vm_name available globally for cleanup trap (only after cleanup is done)
    VM_NAME_FOR_CLEANUP="$vm_name"

    # Determine the correct base VM image for this release
    local base_vm_image
    if [ -n "$BASE_VM_IMAGE" ]; then
        base_vm_image="$BASE_VM_IMAGE"
        log "Using explicit base VM image: $base_vm_image"
    else
        base_vm_image=$(get_base_vm_image "$release" "arm64")
        log "Using release-specific base VM image: $base_vm_image"
    fi

    log "=== INITIAL TART STATE ==="
    log "Available Tart VMs:"
    tart list || log "Failed to list VMs"
    log "=========================="

    # Monitor disk usage and perform automatic cleanup if needed
    local current_usage=$(get_disk_usage)
    log "Current disk usage: ${current_usage}%"
    if [ "$current_usage" -gt "$DISK_USAGE_THRESHOLD" ]; then
        log "⚠️  WARNING: Disk usage at ${current_usage}% exceeds threshold (${DISK_USAGE_THRESHOLD}%)"
        log "    Automatically cleaning up orphaned VMs to free space..."
        
        # Clean up orphaned temporary VMs automatically when disk usage is high
        cleanup_orphaned_vms
        
        # Check disk usage again after cleanup
        local usage_after_cleanup=$(get_disk_usage)
        log "📊 Disk usage after cleanup: ${usage_after_cleanup}%"
        
        if [ "$usage_after_cleanup" -gt "$DISK_USAGE_THRESHOLD" ]; then
            log "⚠️  WARNING: Disk usage still high after cleanup (${usage_after_cleanup}%)"
            log "    This may indicate a deeper storage issue"
            log "    Continuing with build, but consider manual investigation"
        else
            log "✅ Disk usage reduced to acceptable level (${usage_after_cleanup}%)"
        fi
    fi

    # BUILD PHASES DO NO CLEANUP - this is handled in VM preparation step
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
    
    # Check if base image exists and ensure it's available (with registry fallback)
    if ! ensure_vm_image_available "$base_vm_image" "$release"; then
        log "❌ Unable to ensure base image '$base_vm_image' is available"
        log "Both local and registry sources failed"
        exit 1
    fi
    
    log "✅ Base image found - cloning VM"
    if ! tart clone "$base_vm_image" "$vm_name"; then
        log "❌ Failed to clone VM from base image: $base_vm_image"
        log "   This could indicate disk space issues or corrupted base image"
        exit 1
    fi
    log "✅ VM cloned successfully: $vm_name"
    
    # Allocate VM resources for build performance
    log "Allocating VM resources for build performance..."
    log "  Setting memory: ${MACOS_VM_MEMORY:-6144}MB (${MACOS_VM_CONFIG_DESCRIPTION:-conservative default})"
    log "  Setting CPUs: ${MACOS_VM_CPU:-4} cores"
    tart set "$vm_name" --memory "${MACOS_VM_MEMORY:-6144}" --cpu "${MACOS_VM_CPU:-4}"
    log "✅ VM resources allocated"
    
    # Set up cleanup trap IMMEDIATELY after VM creation to prevent orphaned VMs
    cleanup_trap() {
        local exit_code=$?
        log "🛡️  Cleanup trap triggered (exit code: $exit_code)"
        if [ -n "${VM_NAME_FOR_CLEANUP:-}" ]; then
            cleanup_vm "$VM_NAME_FOR_CLEANUP"
        else
            log "⚠️  No VM name available for cleanup"
        fi
    }
    trap cleanup_trap EXIT INT TERM
    
    # Validate workspace directory before VM start - prefer current directory for reliability
    log "🔍 Validating workspace directory: $workspace_dir"
    local actual_workspace_dir="$workspace_dir"
    
    # If we have a complex/long path, prefer current directory for reliability (like C++ build)
    if [[ "$workspace_dir" =~ /builds/.*/build-archetype.*/ ]] || [ "${#workspace_dir}" -gt 100 ]; then
        log "🔄 Detected complex BuildKite workspace path, using current directory for reliability"
        log "   Complex path: $workspace_dir"
        log "   Using instead: $PWD"
        actual_workspace_dir="$PWD"
    fi
    
    if [ ! -d "$actual_workspace_dir" ]; then
        log "❌ Workspace directory does not exist: $actual_workspace_dir"
        log "   Falling back to current directory: $PWD"
        actual_workspace_dir="$PWD"
    fi
    
    if [ ! -r "$actual_workspace_dir" ]; then
        log "❌ Workspace directory is not readable: $actual_workspace_dir"
        log "   Falling back to current directory: $PWD"
        actual_workspace_dir="$PWD"
    fi
    
    # Final validation
    if [ ! -d "$actual_workspace_dir" ] || [ ! -r "$actual_workspace_dir" ]; then
        log "❌ Even current directory has issues - this is a serious problem"
        exit 1
    fi
    
    log "✅ Workspace directory validated: $actual_workspace_dir"
    
    log "Starting VM with workspace: $actual_workspace_dir"
    tart run "$vm_name" --no-graphics --dir=workspace:"$actual_workspace_dir" > vm.log 2>&1 &
    local vm_pid=$!
    
    # Wait for VM to be ready
    log "Waiting for VM to be ready..."
    sleep 2

    # Verify VM actually started
    if ! tart list | grep "$vm_name" | grep -q "running"; then
        log "❌ VM failed to start - not in running state"
        log "   Checking vm.log for details..."
        if [ -f vm.log ]; then
            log "   VM log contents:"
            tail -20 vm.log | while read -r line; do
                log "     $line"
            done
            
            # Check for specific error types
            if grep -q "directory sharing device configuration is invalid" vm.log; then
                log "🔍 Detected directory sharing configuration error"
                log "   This is often caused by:"
                log "   - Non-existent or inaccessible workspace directory"
                log "   - Deep nested paths that macOS virtualization can't handle"
                log "   - Permission issues with the shared directory"
                log "   - Special characters or symlinks in the path"
                
                # Try to start without directory sharing as fallback
                log "🔄 Attempting to restart VM without directory sharing..."
                tart run "$vm_name" --no-graphics > vm.log 2>&1 &
                local vm_pid_retry=$!
                sleep 2
                
                if tart list | grep "$vm_name" | grep -q "running"; then
                    log "✅ VM started successfully without directory sharing"
                    log "⚠️  WARNING: VM started without workspace sharing"
                    log "   Build may need to copy files manually via SSH"
                    return 0  # Continue with the build
                else
                    log "❌ VM failed to start even without directory sharing"
                fi
            elif grep -q "insufficient disk space\|No space left" vm.log; then
                log "🔍 Detected disk space issue"
                log "   Even after cleanup, there may be insufficient space for VM startup"
            fi
        fi
        
        log "   This often indicates insufficient disk space or other system issues"
        # The cleanup trap will handle VM deletion
        exit 1
    fi
    log "✅ VM is running successfully"

    # Make run-vm-command.sh executable
    chmod +x ./scripts/run-vm-command.sh

    # Execute the command
    log "Executing command in VM: $command"
    ./scripts/run-vm-command.sh "$vm_name" "$command"

    # Upload logs
    buildkite-agent artifact upload vm.log || true

    # Cleanup - use robust cleanup function
    cleanup_vm "$vm_name"

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
    echo "  --cleanup-orphaned        Clean up orphaned temporary VMs"
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
    local cleanup_orphaned=false
    
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
            --cleanup-orphaned)
                cleanup_orphaned=true
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
    
    # Handle cleanup-orphaned option
    if [ "$cleanup_orphaned" = true ]; then
        cleanup_orphaned_vms
        exit 0
    fi
    
    # Start with a clean slate: Clean up any orphaned VMs before any operations
    log "🧹 Initial cleanup: Removing any orphaned VMs from previous builds..."
    cleanup_orphaned_vms
    
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

    # Setup cache environment
    setup_cache_environment

    create_and_run_vm "$vm_name" "$command" "$workspace_dir" "$release"
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 