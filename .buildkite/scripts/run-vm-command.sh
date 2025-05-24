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

# Run command in VM
sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP "cd /Volumes/My\ Shared\ Files/workspace && $COMMAND" 