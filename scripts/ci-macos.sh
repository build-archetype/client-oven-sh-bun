#!/bin/bash
set -euo pipefail

# SSH options for VM connectivity
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# Function to log messages with timestamps
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to get base VM image name
get_base_vm_image() {
    local release="${1:-14}"
    local arch="arm64"  # Default to arm64 for Apple Silicon
    echo "bun-build-macos-${release}-${arch}-1.2.16-bootstrap-14"
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

    # Get base VM name
    local base_vm_image=$(get_base_vm_image "$release")
    
    # Check if base VM exists
    if ! tart list | grep -q "^local.*$base_vm_image"; then
        log "❌ Base VM not found: $base_vm_image"
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
    sleep 15
    
    # Get VM IP
    local vm_ip=""
    for i in {1..30}; do
        vm_ip=$(tart ip "$vm_name" 2>/dev/null || echo "")
        if [ -n "$vm_ip" ]; then
            break
        fi
        sleep 2
    done
    
    if [ -z "$vm_ip" ]; then
        log "❌ Could not get VM IP"
        exit 1
    fi
    
    # Wait for SSH
    log "Waiting for SSH to be ready on $vm_ip..."
    for i in {1..30}; do
        if sshpass -p "admin" ssh $SSH_OPTS admin@"$vm_ip" "echo 'ready'" >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    
    log "✅ VM ready - executing command"
    
    # Execute command via SSH
    sshpass -p "admin" ssh $SSH_OPTS admin@"$vm_ip" "cd /Volumes/workspace && $command"
    
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