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

echo "=== RUNNING ACTUAL COMMAND ==="

echo "=== CREATING HOST ENVIRONMENT FILE ==="
# Create environment file directly in workspace directory (gets shared to VM)
SHARED_ENV_FILE="./buildkite_env.sh"

echo "Creating environment file on host at: $SHARED_ENV_FILE"

# Dump ALL environment variables to the shared file
cat > "$SHARED_ENV_FILE" << 'EOF'
#!/bin/bash
# Environment variables exported from Buildkite host

# Add standard paths
export PATH="$HOME/.buildkite-agent/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

# Set build paths to use symlink workspace without spaces instead of shared folder with spaces
# IMPORTANT: Use $HOME/workspace symlink to avoid path quoting issues in compiler flags
# Note: Will be set to actual VM user's home in the VM environment
export BUILDKITE_BUILD_PATH="VM_USER_HOME/workspace/build-workdir"

EOF

# Export all current environment variables to the file
echo "Exporting all environment variables to workspace file..."
env_count=0
buildkite_count=0

# Use a more reliable approach - loop through all environment variables
while IFS='=' read -r -d '' name value; do
    if [[ -n "$name" && -n "$value" ]]; then
        # Override build path to use shared workspace for consistency
        if [[ "$name" == "BUILDKITE_BUILD_PATH" ]]; then
            value="VM_USER_HOME/workspace/build-workdir"
            echo "  Overriding BUILDKITE_BUILD_PATH to use symlink workspace: $value"
        fi
        
        # Use printf to properly escape the value
        printf 'export %s=%q\n' "$name" "$value" >> "$SHARED_ENV_FILE"
        env_count=$((env_count + 1))
        
        # Count BUILDKITE_* variables
        if [[ "$name" == BUILDKITE_* ]]; then
            echo "  Found BUILDKITE variable: $name"
            buildkite_count=$((buildkite_count + 1))
        fi
    fi
done < <(env -0)

echo "✅ Exported $env_count total environment variables"
echo "✅ Found $buildkite_count BUILDKITE_* environment variables"

# Show file info
echo "Environment file created:"
echo "  File: $SHARED_ENV_FILE" 
echo "  Size: $(wc -l < "$SHARED_ENV_FILE") lines"
echo "  First 10 BUILDKITE_* variables:"
grep '^export BUILDKITE_' "$SHARED_ENV_FILE" | head -10

echo "=== SOURCING ENVIRONMENT AND RUNNING COMMAND ==="
sshpass -p admin ssh $SSH_OPTS admin@$VM_IP bash -s <<'REMOTE'
set -eo pipefail

echo "===== VM context ====="
whoami
pwd

# Attempt to remount the Virtio-FS share without spaces
echo "Remounting Virtio-FS…"
sudo umount "/Volumes/My Shared Files" 2>/dev/null || true
sudo mkdir -p "$HOME/virtiofs"
if sudo mount_virtiofs com.apple.virtio-fs.automount "$HOME/virtiofs"; then
  WORK_ROOT="$HOME/virtiofs"
  echo "✅ Remounted to $WORK_ROOT"
else
  echo "⚠️  Remount failed, falling back to /Volumes/My Shared Files"
  WORK_ROOT="/Volumes/My Shared Files"
fi

WORKSPACE="$WORK_ROOT/workspace"

echo "--- mount (virtiofs entries) ---"
mount | grep -E 'virtio|virtiofs' || true

echo "--- ls -la $WORK_ROOT ---"
ls -la "$WORK_ROOT" || true

echo "--- ls -la $WORKSPACE ---"
ls -la "$WORKSPACE" || true

# Source environment
if [ -f "$WORKSPACE/buildkite_env.sh" ]; then
  ORIGINAL_HOME=$HOME
  source "$WORKSPACE/buildkite_env.sh"
  export HOME="$ORIGINAL_HOME"
else
  echo "❌ buildkite_env.sh not found at $WORKSPACE";
  exit 1
fi

# Reset HOME to actual VM user after host env file may have overridden it
export HOME="$WORK_ROOT/.."  # parent dir of WORK_ROOT is user home (e.g., /Users/admin)

export BUILDKITE_BUILD_PATH="$WORKSPACE/build-workdir"
echo "BUILDKITE_BUILD_PATH=$BUILDKITE_BUILD_PATH"

REMOTE

echo "=== ENSURING BUILDKITE AGENT AVAILABILITY ==="
sshpass -p admin ssh $SSH_OPTS admin@$VM_IP bash -s <<'REMOTE'
set -eo pipefail

# Determine WORK_ROOT again (in case first block failed earlier run)
if [ -d "$HOME/virtiofs/workspace" ]; then
  WORK_ROOT="$HOME/virtiofs"
else
  WORK_ROOT="/Volumes/My Shared Files"
fi
WORKSPACE="$WORK_ROOT/workspace"

source "$WORKSPACE/buildkite_env.sh"
export BUILDKITE_BUILD_PATH="$WORKSPACE/build-workdir"
echo "✅ BUILDKITE_BUILD_PATH set to: $BUILDKITE_BUILD_PATH"

# Ensure buildkite-agent binary
if command -v buildkite-agent >/dev/null 2>&1; then
  echo "✅ Buildkite agent already available: $(buildkite-agent --version)"
else
  echo "Installing buildkite-agent…"
  if [ ! -d "$HOME/.buildkite-agent" ]; then
    curl -fsSL https://raw.githubusercontent.com/buildkite/agent/main/install.sh > /tmp/install-buildkite.sh
    chmod +x /tmp/install-buildkite.sh
    DESTINATION=$HOME/.buildkite-agent bash /tmp/install-buildkite.sh
    export PATH="$HOME/.buildkite-agent/bin:$PATH"
    sudo ln -sf "$HOME/.buildkite-agent/bin/buildkite-agent" /usr/local/bin/buildkite-agent 2>/dev/null || true
    rm -f /tmp/install-buildkite.sh
  else
    export PATH="$HOME/.buildkite-agent/bin:$PATH"
  fi
  echo "✅ Buildkite agent setup complete"
fi

command -v buildkite-agent && echo "✅ Buildkite agent ready: $(buildkite-agent --version)" || echo "⚠️  buildkite-agent not found after install"
REMOTE

echo "=== EXECUTING FINAL COMMAND ==="

# Execute the command and capture the exit code
# Ensure environment is sourced before running any command
set +e
sshpass -p admin ssh $SSH_OPTS admin@$VM_IP bash -s <<'REMOTE'
set -eo pipefail

# Resolve workspace again
if [ -d "$HOME/virtiofs/workspace" ]; then
  WORK_ROOT="$HOME/virtiofs"
else
  WORK_ROOT="/Volumes/My Shared Files"
fi
WORKSPACE="$WORK_ROOT/workspace"

ORIGINAL_HOME=$HOME
source "$WORKSPACE/buildkite_env.sh"
export HOME="$ORIGINAL_HOME"

export BUILDKITE_BUILD_PATH="$WORKSPACE/build-workdir"
echo "✅ BUILDKITE_BUILD_PATH set to: $BUILDKITE_BUILD_PATH"

export PATH="$HOME/.buildkite-agent/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
export TMPDIR="/tmp"
echo "Verifying buildkite-agent availability…"
command -v buildkite-agent && echo "✅ buildkite-agent found at $(which buildkite-agent)" || echo "⚠️  buildkite-agent not found in PATH"

# Run command
cd "$WORKSPACE"
eval $COMMAND

# Remove env file after use
rm -f "$WORKSPACE/buildkite_env.sh"
REMOTE
EXIT_CODE=$?
set -e

echo "=== CLEANUP ==="
echo "Cleaning up environment file from workspace..."
rm -f "$SHARED_ENV_FILE"
echo "✅ Cleanup complete"

# Exit with the same code as the VM command
exit $EXIT_CODE 