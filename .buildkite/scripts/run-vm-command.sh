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
sshpass -p admin ssh $SSH_OPTS "admin@$VM_IP" "bash -l -c '
    echo \"Setting up workspace mount without spaces...\"
    echo \"Current user: \$(whoami)\"
    echo \"Home directory: \$HOME\"
    echo \"Working directory: \$(pwd)\"
    
    # Remount the Virtio-FS share to a path without spaces
    sudo umount "/Volumes/My Shared Files" 2>/dev/null || true
    sudo mkdir -p "\$HOME/virtiofs"
    sudo mount_virtiofs com.apple.virtio-fs.automount "\$HOME/virtiofs"
    export VM_WORK_ROOT="\$HOME/virtiofs"
    export VM_WORKSPACE="\$VM_WORK_ROOT/workspace"
    echo \"✅ Remounted Virtio-FS to: \$VM_WORK_ROOT\"
    echo \"✅ Workspace directory expected at: \$VM_WORKSPACE\"
    
    # Source the environment file and fix paths
    if [ -f "\$VM_WORKSPACE/buildkite_env.sh" ]; then
        source "\$VM_WORKSPACE/buildkite_env.sh"
    else
        echo \"❌ Environment file not found at \$VM_WORKSPACE/buildkite_env.sh\"
        ls -la "\$VM_WORK_ROOT" | head -20
        exit 1
    fi
    export BUILDKITE_BUILD_PATH="\$VM_WORKSPACE/build-workdir"
    echo \"✅ BUILDKITE_BUILD_PATH set to: \$BUILDKITE_BUILD_PATH\"
    
    # Verify workspace directory exists
    if [ ! -d "\$VM_WORKSPACE" ]; then
        echo \"❌ Workspace directory \$VM_WORKSPACE does not exist\"
        exit 1
    fi
'"

echo "=== ENSURING BUILDKITE AGENT AVAILABILITY ==="
sshpass -p admin ssh $SSH_OPTS "admin@$VM_IP" "bash -l -c '
    # Source environment and fix the build path
    source "\$HOME/virtiofs/workspace/buildkite_env.sh"
    export BUILDKITE_BUILD_PATH="\$HOME/virtiofs/workspace/build-workdir"
    echo \"✅ BUILDKITE_BUILD_PATH set to: \$BUILDKITE_BUILD_PATH\"
    
    # Check if buildkite-agent is already available
    if command -v buildkite-agent >/dev/null 2>&1; then
        echo \"✅ Buildkite agent already available: \$(buildkite-agent --version)\"
    else
        echo \"Installing buildkite-agent...\"
        
        # Try to install in user home first (faster fallback)
        if [ ! -d \"\$HOME/.buildkite-agent\" ]; then
            echo \"Downloading buildkite-agent installer...\"
            curl -fsSL https://raw.githubusercontent.com/buildkite/agent/main/install.sh > /tmp/install-buildkite.sh
            chmod +x /tmp/install-buildkite.sh
            
            # Install to user home directory
            export DESTINATION=\$HOME/.buildkite-agent
            bash /tmp/install-buildkite.sh
            
            # Add to PATH for this session
            export PATH=\"\$HOME/.buildkite-agent/bin:\$PATH\"
            
            # Create system-wide symlink if possible
            if sudo -n true 2>/dev/null; then
                sudo ln -sf \"\$HOME/.buildkite-agent/bin/buildkite-agent\" \"/usr/local/bin/buildkite-agent\" 2>/dev/null || true
            fi
            
            rm -f /tmp/install-buildkite.sh
        else
            # Already installed, just add to PATH
            export PATH=\"\$HOME/.buildkite-agent/bin:\$PATH\"
        fi
        
        echo \"✅ Buildkite agent setup complete\"
    fi
    
    # Verify installation
    if command -v buildkite-agent >/dev/null 2>&1; then
        echo \"✅ Buildkite agent ready: \$(buildkite-agent --version)\"
    else
        echo \"⚠️  Buildkite agent installation may have failed, but continuing...\"
    fi
'"

echo "=== EXECUTING FINAL COMMAND ==="

# Execute the command and capture the exit code
# Ensure environment is sourced before running any command
set +e
sshpass -p admin ssh $SSH_OPTS "admin@$VM_IP" "bash -l -c '
    # Source environment and ensure buildkite-agent is in PATH
    source "\$HOME/virtiofs/workspace/buildkite_env.sh"
    export BUILDKITE_BUILD_PATH="\$HOME/virtiofs/workspace/build-workdir"
    echo \"✅ BUILDKITE_BUILD_PATH set to: \$BUILDKITE_BUILD_PATH\"
    
    # Add buildkite-agent to PATH multiple times to ensure it sticks
    export PATH="\$HOME/.buildkite-agent/bin:/usr/local/bin:/opt/homebrew/bin:\$PATH"
    export TMPDIR="/tmp"
    echo \"Verifying buildkite-agent availability...\"
    
    if command -v buildkite-agent >/dev/null 2>&1; then
        echo \"✅ buildkite-agent found at: \\$(which buildkite-agent)\"
    else
        echo \"⚠️  buildkite-agent not found in PATH, but continuing...\"
        echo \"PATH: \\$PATH\"
    fi
    
    # Clean up environment file and run command from symlinked workspace
    rm -f "\$HOME/virtiofs/workspace/buildkite_env.sh" && cd "\$HOME/virtiofs/workspace" && $COMMAND
'"
EXIT_CODE=$?
set -e

echo "=== CLEANUP ==="
echo "Cleaning up environment file from workspace..."
rm -f "$SHARED_ENV_FILE"
echo "✅ Cleanup complete"

# Exit with the same code as the VM command
exit $EXIT_CODE 