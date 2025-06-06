#!/bin/bash
set -euo pipefail

# Configuration - can be overridden via environment variables
BASE_VM_IMAGE="${BASE_VM_IMAGE:-bun-build-macos-1.2.16-bootstrap-3.5}"
EMERGENCY_CLEANUP="${EMERGENCY_CLEANUP:-false}"
MAX_VM_AGE_HOURS="${MAX_VM_AGE_HOURS:-1}"
DISK_USAGE_THRESHOLD="${DISK_USAGE_THRESHOLD:-80}"
FORCE_BASE_IMAGE_REBUILD="${FORCE_BASE_IMAGE_REBUILD:-false}"

# Function to log messages with timestamps
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to get disk usage percentage
get_disk_usage() {
    df -h . | tail -1 | awk '{print $5}' | sed 's/%//'
}

# Function to perform emergency cleanup
emergency_cleanup() {
    log "🚨 EMERGENCY CLEANUP INITIATED 🚨"
    log "Current disk usage: $(get_disk_usage)%"
    
    log "Deleting ALL timestamp-based VMs..."
    tart list | awk '/^local/ && $2 ~ /^bun-build-[0-9]+-/ {print $2}' | while read vm_name; do
        if [ -n "$vm_name" ]; then
            log "Emergency deleting: $vm_name"
            tart delete "$vm_name" 2>/dev/null || log "Failed to delete $vm_name"
        fi
    done
    
    log "Deleting old versioned base images (keeping only latest bootstrap)..."
    tart list | awk '/^local/ && $2 ~ /^bun-build-macos-.*-bootstrap-[0-9.]+$/ && $2 !~ /bootstrap-3\.5$/ {print $2}' | while read vm_name; do
        if [ -n "$vm_name" ]; then
            log "Emergency deleting old base: $vm_name"
            tart delete "$vm_name" 2>/dev/null || log "Failed to delete $vm_name"
        fi
    done
    
    local final_usage=$(get_disk_usage)
    log "Emergency cleanup complete. Disk usage: ${final_usage}%"
    
    if [ "$final_usage" -gt "$DISK_USAGE_THRESHOLD" ]; then
        log "⚠️  Warning: Disk still at ${final_usage}% after emergency cleanup"
        return 1
    else
        log "✅ Emergency cleanup successful!"
        return 0
    fi
}

# Function to clean up VMs
cleanup_vms() {
    log "Cleaning up stopped VMs..."
    
    # Check if emergency cleanup is requested
    if [ "$EMERGENCY_CLEANUP" = "true" ]; then
        emergency_cleanup
        return $?
    fi
    
    # Check disk usage and trigger emergency cleanup if needed
    local current_usage=$(get_disk_usage)
    if [ "$current_usage" -gt "$DISK_USAGE_THRESHOLD" ]; then
        log "Disk usage at ${current_usage}% - triggering emergency cleanup"
        emergency_cleanup
        return $?
    fi
    
    # Normal cleanup - delete ALL timestamp-based VMs
    tart list | awk '/^local/ && $2 ~ /^bun-build-[0-9]+-/ {print $2}' | while read vm_name; do
        if [ -n "$vm_name" ]; then
            log "Deleting old VM: $vm_name"
            tart delete "$vm_name" 2>/dev/null || log "Failed to delete $vm_name"
        fi
    done
    
    # Also clean up any VMs older than specified hours
    local cutoff_time=$(date -d "${MAX_VM_AGE_HOURS} hours ago" +%s 2>/dev/null || date -v-${MAX_VM_AGE_HOURS}H +%s)
    tart list | awk '/^local/ && $2 ~ /^bun-build-[0-9]+-/ {print $2}' | while read vm_name; do
        if [ -n "$vm_name" ]; then
            # Extract timestamp from VM name
            local vm_timestamp=$(echo "$vm_name" | sed 's/bun-build-\([0-9]\+\)-.*/\1/')
            if [ "$vm_timestamp" -lt "$cutoff_time" ]; then
                log "Deleting expired VM: $vm_name"
                tart delete "$vm_name" 2>/dev/null || log "Failed to delete expired VM $vm_name"
            fi
        fi
    done
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

    log "=== INITIAL TART STATE ==="
    log "Available Tart VMs:"
    tart list || log "Failed to list VMs"
    log "=========================="

    # Clean up any existing stopped VMs
    cleanup_vms

    # Start logging
    start_logging

    # Create and run VM
    log "Creating VM: $vm_name"
    log "Using base image: $BASE_VM_IMAGE"
    
    # Check if forced rebuild is requested
    if [ "$FORCE_BASE_IMAGE_REBUILD" = "true" ]; then
        log "🔄 Force rebuild requested for base image"
        if ! rebuild_base_image "$BASE_VM_IMAGE"; then
            log "❌ Failed to rebuild base image"
            exit 1
        fi
    fi
    
    # Check if base image exists
    if ! tart list | grep -q "^local.*$BASE_VM_IMAGE"; then
        log "❌ Base image '$BASE_VM_IMAGE' not found - will rebuild"
        if ! rebuild_base_image "$BASE_VM_IMAGE"; then
            log "❌ Failed to rebuild missing base image"
            exit 1
        fi
    else
        # Validate base image has required tools
        log "✅ Base image exists - validating tools..."
        if ! validate_base_image "$BASE_VM_IMAGE"; then
            log "❌ Base image validation failed - rebuilding"
            if ! rebuild_base_image "$BASE_VM_IMAGE"; then
                log "❌ Failed to rebuild broken base image"
                exit 1
            fi
        fi
    fi
    
    tart clone "$BASE_VM_IMAGE" "$vm_name"
    
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
    echo "  --cleanup-only            Only perform VM cleanup, don't run build"
    echo "  --emergency-cleanup       Force emergency cleanup (same as EMERGENCY_CLEANUP=true)"
    echo "  --force-base-rebuild      Force rebuild of base image before use"
    echo ""
    echo "Environment Variables:"
    echo "  BASE_VM_IMAGE             Base VM image to clone (default: bun-build-macos-1.2.16-bootstrap-3.5)"
    echo "  EMERGENCY_CLEANUP         Set to 'true' to force emergency cleanup (default: false)"
    echo "  MAX_VM_AGE_HOURS          Maximum age of VMs before cleanup (default: 1)"
    echo "  DISK_USAGE_THRESHOLD      Disk usage % to trigger emergency cleanup (default: 80)"
    echo "  FORCE_BASE_IMAGE_REBUILD  Set to 'true' to force base image rebuild (default: false)"
    echo ""
    echo "Examples:"
    echo "  $0                                           # Run default build"
    echo "  $0 'bun run build:release'                  # Run custom command"
    echo "  $0 --cleanup-only                           # Only cleanup VMs"
    echo "  EMERGENCY_CLEANUP=true $0 --cleanup-only    # Emergency cleanup"
    echo "  $0 --force-base-rebuild                     # Force rebuild base image"
    echo "  BASE_VM_IMAGE=my-custom-image $0            # Use custom base image"
}

# Function to validate base image has required tools
validate_base_image() {
    local base_image="$1"
    log "🔍 Validating base image: $base_image"
    
    # Create a temporary test VM
    local test_vm="test-base-$(date +%s)"
    
    log "Creating test VM to validate base image..."
    if ! tart clone "$base_image" "$test_vm"; then
        log "❌ Failed to clone base image for validation"
        return 1
    fi
    
    # Start test VM
    tart run "$test_vm" --no-graphics &
    local test_vm_pid=$!
    sleep 30
    
    # Get test VM IP
    local test_ip=$(tart ip "$test_vm" 2>/dev/null || echo "")
    if [ -z "$test_ip" ]; then
        log "❌ Could not get test VM IP"
        kill $test_vm_pid 2>/dev/null || true
        tart delete "$test_vm" 2>/dev/null || true
        return 1
    fi
    
    # Test required tools
    local tools_check="
        command -v bun && echo 'Bun: OK' || echo 'Bun: MISSING'
        command -v cargo && echo 'Cargo: OK' || echo 'Cargo: MISSING'  
        command -v cmake && echo 'CMake: OK' || echo 'CMake: MISSING'
        command -v node && echo 'Node: OK' || echo 'Node: MISSING'
        command -v clang && echo 'Clang: OK' || echo 'Clang: MISSING'
        command -v ninja && echo 'Ninja: OK' || echo 'Ninja: MISSING'
    "
    
    log "Testing tools in base image..."
    local validation_result
    if validation_result=$(sshpass -p admin ssh $SSH_OPTS admin@"$test_ip" "$tools_check" 2>/dev/null); then
        log "Base image validation results:"
        echo "$validation_result" | while read line; do
            log "  $line"
        done
        
        # Check if any tools are missing
        if echo "$validation_result" | grep -q "MISSING"; then
            log "❌ Base image is missing required tools"
            kill $test_vm_pid 2>/dev/null || true
            tart delete "$test_vm" 2>/dev/null || true
            return 1
        else
            log "✅ Base image validation passed - all tools present"
            kill $test_vm_pid 2>/dev/null || true
            tart delete "$test_vm" 2>/dev/null || true
            return 0
        fi
    else
        log "❌ Failed to connect to test VM for validation"
        kill $test_vm_pid 2>/dev/null || true
        tart delete "$test_vm" 2>/dev/null || true
        return 1
    fi
}

# Function to rebuild base image
rebuild_base_image() {
    local base_image="$1"
    log "🏗️  Rebuilding base image: $base_image"
    
    # Delete existing broken image
    log "Deleting existing broken base image..."
    tart delete "$base_image" 2>/dev/null || log "Base image didn't exist"
    
    # Use build-macos-vm.sh to rebuild
    log "Running base image rebuild..."
    if ! ./scripts/build-macos-vm.sh; then
        log "❌ Base image rebuild failed"
        return 1
    fi
    
    log "✅ Base image rebuilt successfully"
    return 0
}

# Main execution
main() {
    # Parse arguments
    local cleanup_only=false
    local show_help=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help=true
                shift
                ;;
            --cleanup-only)
                cleanup_only=true
                shift
                ;;
            --force-base-rebuild)
                FORCE_BASE_IMAGE_REBUILD=true
                shift
                ;;
            --emergency-cleanup)
                EMERGENCY_CLEANUP=true
                cleanup_only=true
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
    
    # If cleanup-only mode, just run cleanup and exit
    if [ "$cleanup_only" = true ]; then
        log "Running cleanup-only mode..."
        log "Configuration:"
        log "  EMERGENCY_CLEANUP: $EMERGENCY_CLEANUP"
        log "  MAX_VM_AGE_HOURS: $MAX_VM_AGE_HOURS"
        log "  DISK_USAGE_THRESHOLD: $DISK_USAGE_THRESHOLD"
        log "  Current disk usage: $(get_disk_usage)%"
        
        cleanup_vms
        exit $?
    fi
    
    # Generate a unique VM name
    local vm_name="bun-build-$(date +%s)-$(uuidgen)"
    
    # Get the command to run (default to build command if none provided)
    local command="${1:-./scripts/runner.node.mjs --step=darwin-x64-build-bun}"
    
    # Get the workspace directory (default to current directory)
    local workspace_dir="${2:-$PWD}"

    log "Starting build process..."
    log "Configuration:"
    log "  BASE_VM_IMAGE: $BASE_VM_IMAGE"
    log "  EMERGENCY_CLEANUP: $EMERGENCY_CLEANUP"
    log "  MAX_VM_AGE_HOURS: $MAX_VM_AGE_HOURS"
    log "  DISK_USAGE_THRESHOLD: $DISK_USAGE_THRESHOLD"
    log "VM Name: $vm_name"
    log "Command: $command"
    log "Workspace: $workspace_dir"

    create_and_run_vm "$vm_name" "$command" "$workspace_dir"
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 