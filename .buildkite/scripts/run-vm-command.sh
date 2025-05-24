#!/bin/bash
set -e

VM_NAME=$1
COMMAND=$2

# Get VM IP
VM_IP=$(tart ip "$VM_NAME")
echo "VM IP: $VM_IP"

# Run command in VM
sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP "cd ~/workspace/workspace && $COMMAND" 