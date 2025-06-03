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

echo "Running command in VM: $COMMAND"

# ===== CREATE ENVIRONMENT FILE =====
echo "=== CREATING ENVIRONMENT FILE ==="
ENV_FILE="./buildkite_env.sh"

cat > "$ENV_FILE" << 'EOF'
#!/bin/bash
# Environment variables exported from Buildkite host

# Add standard paths
export PATH="$HOME/.buildkite-agent/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

EOF

# Export all environment variables to the file
echo "Exporting environment variables..."
env_count=0
buildkite_count=0

while IFS='=' read -r -d '' name value; do
    if [[ -n "$name" && -n "$value" ]]; then
        # Skip host-specific variables that shouldn't be copied
        if [[ "$name" == "HOME" || "$name" == "TMPDIR" || "$name" == "LD_SUPPORT_TMPDIR" ]]; then
            continue
        fi
        
        # Override build path to use VM workspace
        if [[ "$name" == "BUILDKITE_BUILD_PATH" ]]; then
            value="/Users/admin/workspace/build-workdir"
        fi
        
        printf 'export %s=%q\n' "$name" "$value" >> "$ENV_FILE"
        env_count=$((env_count + 1))
        
        if [[ "$name" == BUILDKITE_* ]]; then
            buildkite_count=$((buildkite_count + 1))
        fi
    fi
done < <(env -0)

echo "✅ Exported $env_count environment variables ($buildkite_count BUILDKITE_* vars)"

# ===== COPY WORKSPACE TO VM =====
echo "=== COPYING WORKSPACE TO VM ==="
echo "Copying workspace to VM..."

# Ensure workspace directory exists on VM
sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "rm -rf ~/workspace && mkdir -p ~/workspace"

# Copy entire workspace to VM
if rsync -av --delete -e "sshpass -p admin ssh $SSH_OPTS" ./ admin@$VM_IP:~/workspace/; then
    echo "✅ Workspace copied successfully"
else
    echo "❌ Failed to copy workspace to VM"
    exit 1
fi

# ===== SETUP VM ENVIRONMENT =====
echo "=== SETTING UP VM ENVIRONMENT ==="

sshpass -p admin ssh $SSH_OPTS admin@$VM_IP bash -s <<'REMOTE_SETUP'
set -eo pipefail

echo "Setting up VM environment..."
cd ~/workspace

# Source environment variables
source ./buildkite_env.sh

# Set VM-specific paths
export WORKSPACE="$HOME/workspace"
export BUILDKITE_BUILD_PATH="$HOME/workspace/build-workdir"
export VENDOR_PATH="$HOME/workspace/vendor"
export TMPDIR="/tmp"
export LD_SUPPORT_TMPDIR="/tmp"

# Ensure buildkite-agent is available
if ! command -v buildkite-agent >/dev/null 2>&1; then
    echo "Installing buildkite-agent..."
    AGENT_DIR="$HOME/.buildkite-agent"
    if [ ! -d "$AGENT_DIR" ]; then
        curl -fsSL https://raw.githubusercontent.com/buildkite/agent/main/install.sh > /tmp/install-buildkite.sh
        chmod +x /tmp/install-buildkite.sh
        DESTINATION=$AGENT_DIR bash /tmp/install-buildkite.sh
        sudo ln -sf "$AGENT_DIR/bin/buildkite-agent" /usr/local/bin/buildkite-agent 2>/dev/null || true
        rm -f /tmp/install-buildkite.sh
    fi
fi

# Ensure bun is accessible
if command -v bun >/dev/null 2>&1; then
    BUN_BIN=$(command -v bun)
    sudo ln -sf "$BUN_BIN" /usr/local/bin/bun 2>/dev/null || true
fi

echo "✅ VM environment setup complete"
REMOTE_SETUP

# ===== EXECUTE COMMAND =====
echo "=== EXECUTING COMMAND ==="

# Execute the user command in the VM
REMOTE_CMD="
set -eo pipefail
cd ~/workspace
source ./buildkite_env.sh
export WORKSPACE=\"\$HOME/workspace\"
export BUILDKITE_BUILD_PATH=\"\$HOME/workspace/build-workdir\"
export VENDOR_PATH=\"\$HOME/workspace/vendor\"
export TMPDIR=\"/tmp\"
export LD_SUPPORT_TMPDIR=\"/tmp\"

echo \"Executing: $COMMAND\"
$COMMAND
"

sshpass -p admin ssh $SSH_OPTS admin@$VM_IP bash -lc "$REMOTE_CMD"
EXIT_CODE=$?

# ===== COPY ARTIFACTS BACK =====
echo "=== COPYING ARTIFACTS BACK ==="

if [ -d "./build" ] || [ -d "./artifacts" ] || [ -d "./dist" ]; then
    echo "Copying build artifacts back from VM..."
    
    # Copy common artifact directories back
    for dir in build artifacts dist; do
        if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "[ -d ~/workspace/$dir ]"; then
            echo "Copying $dir/ back..."
            rsync -av -e "sshpass -p admin ssh $SSH_OPTS" admin@$VM_IP:~/workspace/$dir/ ./$dir/ || true
        fi
    done
    
    echo "✅ Artifacts copied back"
else
    echo "No standard artifact directories found, skipping artifact copy"
fi

# ===== CLEANUP =====
echo "=== CLEANUP ==="
rm -f "$ENV_FILE" || true
echo "✅ Cleanup complete"

# Propagate exit status
exit $EXIT_CODE 