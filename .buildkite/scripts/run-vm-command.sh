#!/bin/bash
set -e

VM_NAME=$1
COMMAND=$2

# Get VM IP
VM_IP=$(tart ip "$VM_NAME")
echo "VM IP: $VM_IP"

# Check if VM is healthy
echo "Checking VM health..."
attempt=1
max_attempts=5
while [ "$attempt" -le "$max_attempts" ]; do
  echo "[$attempt/$max_attempts] Checking VM health..."
  
  # First check if SSH is running
  if ! nc -z $VM_IP 22 > /dev/null 2>&1; then
    echo "SSH port not yet available, waiting..."
    sleep 20
    attempt=$((attempt + 1))
    continue
  fi
  
  # Try SSH with verbose output for debugging
  if sshpass -p admin ssh -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP echo "VM is healthy" > /dev/null 2>&1; then
    echo "VM is healthy"
    break
  fi
  
  if [ "$attempt" -eq "$max_attempts" ]; then
    echo "VM failed to become healthy after $max_attempts attempts"
    exit 1
  fi
  
  echo "[$attempt/$max_attempts] VM not ready yet, waiting..."
  sleep 20
  attempt=$((attempt + 1))
done

# Check Bun before bootstrap
echo "Checking Bun before bootstrap..."
sshpass -p admin ssh -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP "which bun || echo 'Bun not found'"

# Run bootstrap.sh to set up dependencies
echo "Setting up build environment..."
sshpass -p admin ssh -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP "cd '/Volumes/My Shared Files/workspace' && chmod +x scripts/bootstrap.sh && ./scripts/bootstrap.sh"

# Check Bun after bootstrap
echo "Checking Bun after bootstrap..."
sshpass -p admin ssh -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP "which bun && bun --version || echo 'Bun not found'"

# Run the command
echo "Running command: $COMMAND"
sshpass -p admin ssh -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP "cd '/Volumes/My Shared Files/workspace' && $COMMAND" 