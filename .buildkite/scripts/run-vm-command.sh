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
# IMPORTANT: Use ~/workspace symlink to avoid path quoting issues in compiler flags
export BUILDKITE_BUILD_PATH="/Users/admin/workspace/build-workdir"

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
            value="/Users/admin/workspace/build-workdir"
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
    echo \"Setting up workspace symlink to avoid spaces in path...\"
    
    # Create a symlink without spaces in the user home directory (writable)
    rm -rf ~/workspace 2>/dev/null || true
    ln -sf \"/Volumes/My Shared Files/workspace\" ~/workspace
    echo \"✅ Created symlink: ~/workspace -> /Volumes/My Shared Files/workspace\"
    
    echo \"Sourcing environment from shared filesystem...\"
    
    # Source the environment file from the shared workspace using the symlink
    if [ -f \"\$HOME/workspace/buildkite_env.sh\" ]; then
        source \"\$HOME/workspace/buildkite_env.sh\"
        echo \"✅ Environment file sourced from \$HOME/workspace/buildkite_env.sh\"
    else
        echo \"❌ Environment file not found at \$HOME/workspace/buildkite_env.sh!\"
        echo \"Available files in workspace directory:\"
        ls -la \"\$HOME/workspace\" | head -10
        exit 1
    fi
    
    echo \"\"
    echo \"=== ENVIRONMENT VERIFICATION IN VM ===\"
    echo \"After sourcing environment file:\"
    echo \"  BUILDKITE: \$BUILDKITE\"
    echo \"  CI: \$CI\"
    echo \"  BUILDKITE_BUILD_ID: \$BUILDKITE_BUILD_ID\"
    echo \"  BUILDKITE_PIPELINE_SLUG: \$BUILDKITE_PIPELINE_SLUG\"
    echo \"  CANARY_REVISION: \$CANARY_REVISION\"
    echo \"  BUN_LINK_ONLY: \$BUN_LINK_ONLY\"
    echo \"\"
    echo \"Total BUILDKITE_* variables available: \$(env | grep \\\"^BUILDKITE_\\\" | wc -l)\"
'"

echo "=== ENSURING BUILDKITE AGENT AVAILABILITY ==="
sshpass -p admin ssh $SSH_OPTS "admin@$VM_IP" "bash -l -c '
    # Source environment first
    source \"/Volumes/My Shared Files/workspace/buildkite_env.sh\"
    
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
    source \"\$HOME/workspace/buildkite_env.sh\"
    
    # Add buildkite-agent to PATH multiple times to ensure it sticks
    export PATH=\"\$HOME/.buildkite-agent/bin:/usr/local/bin:/opt/homebrew/bin:\$PATH\"
    
    # Set TMPDIR for build tools
    export TMPDIR=\"/tmp\"
    
    # Verify buildkite-agent is available before running command
    echo \"Verifying buildkite-agent availability...\"
    if command -v buildkite-agent >/dev/null 2>&1; then
        echo \"✅ buildkite-agent found at: \$(which buildkite-agent)\"
    else
        echo \"⚠️  buildkite-agent not found in PATH, but continuing...\"
        echo \"PATH: \$PATH\"
    fi
    
    # Clean up environment file and run command from symlinked workspace
    rm -f \"\$HOME/workspace/buildkite_env.sh\" && cd \"\$HOME/workspace\" && $COMMAND
'"
EXIT_CODE=$?
set -e

echo "=== CLEANUP ==="
echo "Cleaning up environment file from workspace..."
rm -f "$SHARED_ENV_FILE"
echo "✅ Cleanup complete"

# Exit with the same code as the VM command
exit $EXIT_CODE 