#!/bin/bash

# Check if VM name is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <vm-name> [command]"
    exit 1
fi

VM_NAME="$1"
COMMAND="${2:-echo 'VM is ready'}"

# Function to wait for VM and get IP
wait_for_vm() {
    local vm_name="$1"
    local max_attempts=30
    local attempt=0
    
    echo "Waiting for VM '$vm_name' to be ready..."
    
    while [ $attempt -lt $max_attempts ]; do
        # Check if VM is running
        if ! tart list | grep -q "$vm_name.*running"; then
            echo "Error: VM '$vm_name' is not running"
            return 1
        fi
        
        # Try to get IP
        VM_IP=$(tart ip "$vm_name" 2>/dev/null || echo "")
        if [ -n "$VM_IP" ]; then
            # Test SSH connectivity
            if sshpass -p admin ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 "admin@$VM_IP" echo "test" &>/dev/null; then
                echo "VM is ready at $VM_IP"
                return 0
            fi
        fi
        
        attempt=$((attempt + 1))
        echo "Attempt $attempt/$max_attempts: Waiting for VM..."
        sleep 2
    done
    
    echo "Error: VM did not become ready within timeout"
    return 1
}

# Wait for VM
if ! wait_for_vm "$VM_NAME"; then
    exit 1
fi

# Get VM IP
VM_IP=$(tart ip "$VM_NAME")

# SSH options for reliability
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=5 -o ServerAliveCountMax=3"

# Execute command
echo "Running command in VM: $COMMAND"

# First, check Bun availability and version for debugging
echo "=== BUN AVAILABILITY CHECK ==="
sshpass -p admin ssh $SSH_OPTS "admin@$VM_IP" "bash -l -c '
    echo \"Current user: \$(whoami)\"
    echo \"Current directory: \$(pwd)\"
    echo \"PATH: \$PATH\"
    echo \"\"
    echo \"Checking Bun availability:\"
    if command -v bun >/dev/null 2>&1; then
        echo \"✅ Bun found at: \$(which bun)\"
        echo \"✅ Bun version: \$(bun --version)\"
        echo \"✅ Bun executable permissions: \$(ls -la \$(which bun))\"
    else
        echo \"❌ Bun not found in PATH\"
        echo \"Checking common locations:\"
        for loc in /usr/local/bin/bun /opt/homebrew/bin/bun /usr/bin/bun; do
            if [ -f \"\$loc\" ]; then
                echo \"  Found: \$loc (\$(ls -la \$loc))\"
                echo \"  Version: \$(\$loc --version 2>/dev/null || echo 'failed to get version')\"
            else
                echo \"  Not found: \$loc\"
            fi
        done
    fi
    echo \"\"
    echo \"Available binaries in PATH:\"
    echo \$PATH | tr ':' '\n' | while read dir; do
        if [ -d \"\$dir\" ] && [ -r \"\$dir\" ]; then
            echo \"  \$dir: \$(ls \$dir 2>/dev/null | grep -E '^(bun|node|npm)' | head -3 || echo 'none')\"
        fi
    done
'"

echo "=== RUNNING ACTUAL COMMAND ==="

# Copy workspace to local directory to avoid shared filesystem issues
echo "=== COPYING WORKSPACE TO LOCAL DIRECTORY ==="
sshpass -p admin ssh $SSH_OPTS "admin@$VM_IP" "bash -l -c '
    echo \"Creating local workspace directory...\"
    rm -rf /tmp/workspace
    mkdir -p /tmp/workspace
    echo \"Copying files from shared directory...\"
    rsync -av --exclude=\"build\" --exclude=\"node_modules\" --exclude=\"vendor\" \"/Volumes/My Shared Files/workspace/\" /tmp/workspace/
    echo \"✅ Workspace copied to /tmp/workspace\"
    echo \"Contents:\"
    ls -la /tmp/workspace | head -10
'"

echo "=== RUNNING COMMAND IN LOCAL WORKSPACE ==="
exec sshpass -p admin ssh $SSH_OPTS "admin@$VM_IP" "bash -l -c 'cd /tmp/workspace && $COMMAND'" 