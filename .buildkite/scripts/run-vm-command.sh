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
  if sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP echo "VM is healthy" > /dev/null 2>&1; then
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

# Check if Bun is installed and install if needed
echo "Checking for Bun installation..."
if ! sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP "which bun" > /dev/null 2>&1; then
  echo "Bun not found, installing..."
  sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP "curl -fsSL https://bun.sh/install | bash"
fi

# Set up environment and verify Bun is in PATH
echo "Setting up environment..."
sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP "export BUN_INSTALL=\"\$HOME/.bun\" && export PATH=\"\$BUN_INSTALL/bin:\$PATH\" && which bun || echo 'Bun not found in PATH'"

# Run the command with Bun in PATH
echo "Running command: $COMMAND"
sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$VM_IP "export BUN_INSTALL=\"\$HOME/.bun\" && export PATH=\"\$BUN_INSTALL/bin:\$PATH\" && cd '/Volumes/My Shared Files/workspace' && echo 'Current PATH:' && echo \$PATH && which bun && $COMMAND" 