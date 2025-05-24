#!/bin/bash
set -e

VM_NAME=$1
COMMAND=$2

# Get VM IP
VM_IP=$(tart ip "$VM_NAME")
echo "VM IP: $VM_IP"

# Check if VM is healthy
if ! sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP echo "VM is healthy" > /dev/null 2>&1; then
    echo "VM is not healthy"
    exit 1
fi

# Setup workspace if needed
if [[ "$COMMAND" == *"workspace"* ]]; then
    sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP "sudo umount '/Volumes/My Shared Files' || true; mkdir -p ~/workspace; mount_virtiofs com.apple.virtio-fs.automount ~/workspace"
fi

# Run command in VM
sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP "cd ~/workspace/workspace && $COMMAND" 