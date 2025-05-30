#!/bin/bash

# Check if VM name is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <vm-name> [command]"
    exit 1
fi

VM_NAME="$1"
VM_IP=$(tart ip "$VM_NAME")
WORKSPACE_DIR="/Volumes/My Shared Files/workspace/client-oven-sh-bun"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Function to check VM health
check_vm_health() {
    echo "Checking VM health..."
    if ! tart list | grep -q "$VM_NAME.*running"; then
        echo "Error: VM '$VM_NAME' is not running"
        exit 1
    fi
    
    # Wait for SSH to be available
    echo "Waiting for SSH to be available..."
    for i in {1..30}; do
        if sshpass -p admin ssh $SSH_OPTS -o ConnectTimeout=2 admin@$VM_IP echo "SSH is ready" >/dev/null 2>&1; then
            echo "SSH is ready"
            return 0
        fi
        echo "Attempt $i: SSH not ready yet..."
        sleep 2
    done
    
    echo "Error: SSH did not become available after 60 seconds"
    exit 1
}

# Function to check if Bun is installed
check_bun() {
    echo "Checking Bun before bootstrap..."
    if ! sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "which bun" >/dev/null 2>&1; then
        echo "Error: Bun is not installed in the VM"
        exit 1
    fi
}

# Check VM health
check_vm_health

# If no command is provided, just check VM health and exit
if [ -z "$2" ]; then
    echo "No command provided. VM is healthy."
    exit 0
fi

# Check Bun installation if command is provided
check_bun

# Run the command in the VM
echo "Running command: $2"
sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "cd '$WORKSPACE_DIR' && $2" 