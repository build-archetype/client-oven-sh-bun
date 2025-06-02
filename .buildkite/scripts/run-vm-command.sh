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

# First, check Bun availability and version for debugging
echo "=== BUN AVAILABILITY CHECK ==="
sshpass -p admin ssh $SSH_OPTS "admin@$VM_IP" "bash -l -c '
    echo \"Current user: \$(whoami)\"
    echo \"Current directory: \$(pwd)\"
    echo \"PATH: \$PATH\"
    echo \"\"
    echo \"Checking Bun availability:\"
    if command -v bun >/dev/null 2>&1; then
        echo \"✅ Bun found at: \$(which bun)\"
        echo \"✅ Bun version: \$(bun --version)\"
        echo \"✅ Bun executable permissions: \$(ls -la \$(which bun))\"
    else
        echo \"❌ Bun not found in PATH\"
        echo \"Checking common locations:\"
        for loc in /usr/local/bin/bun /opt/homebrew/bin/bun /usr/bin/bun; do
            if [ -f \"\$loc\" ]; then
                echo \"  Found: \$loc (\$(ls -la \$loc))\"
                echo \"  Version: \$(\$loc --version 2>/dev/null || echo 'failed to get version')\"
            else
                echo \"  Not found: \$loc\"
            fi
        done
    fi
    echo \"\"
    echo \"Available binaries in PATH:\"
    echo \$PATH | tr ':' '\n' | while read dir; do
        if [ -d \"\$dir\" ] && [ -r \"\$dir\" ]; then
            echo \"  \$dir: \$(ls \$dir 2>/dev/null | grep -E '^(bun|node|npm)' | head -3 || echo 'none')\"
        fi
    done
'"

echo "=== RUNNING ACTUAL COMMAND ==="

# Copy workspace to local directory to avoid shared filesystem issues
echo "=== COPYING WORKSPACE TO LOCAL DIRECTORY ==="
sshpass -p admin ssh $SSH_OPTS "admin@$VM_IP" "bash -l -c '
    echo \"Creating local workspace directory...\"
    rm -rf /tmp/workspace
    mkdir -p /tmp/workspace
    echo \"Copying files from shared directory...\"
    rsync -av --exclude=\"build\" --exclude=\"node_modules\" --exclude=\"vendor\" \"/Volumes/My Shared Files/workspace/\" /tmp/workspace/
    echo \"✅ Workspace copied to /tmp/workspace\"
    echo \"Contents:\"
    ls -la /tmp/workspace | head -10
'"

echo "=== RUNNING COMMAND IN LOCAL WORKSPACE ==="

# Create environment variables string for Buildkite
BUILDKITE_ENV=""

echo "=== BUILDKITE ENVIRONMENT VARIABLES DETECTED ==="
# Automatically pass through all BUILDKITE_* environment variables
buildkite_vars_found=0
for var in $(env | grep '^BUILDKITE_' | cut -d= -f1); do
    value="${!var}"
    if [ -n "$value" ]; then
        echo "  $var: $value"
        # Escape single quotes in the value
        escaped_value=$(printf %s "$value" | sed "s/'/'\\\\''/g")
        BUILDKITE_ENV="$BUILDKITE_ENV export $var='$escaped_value';"
        buildkite_vars_found=$((buildkite_vars_found + 1))
    fi
done

if [ $buildkite_vars_found -eq 0 ]; then
    echo "  ⚠️  No BUILDKITE_* environment variables found!"
else
    echo "  ✅ Found $buildkite_vars_found BUILDKITE_* environment variables"
fi
echo "==========================================="

# Always set BUILDKITE=true and CI=true for CMake
BUILDKITE_ENV="$BUILDKITE_ENV export BUILDKITE='true';"
BUILDKITE_ENV="$BUILDKITE_ENV export CI='true';"

echo "=== ADDITIONAL BUILD ENVIRONMENT VARIABLES ==="
# Pass through additional build configuration variables
additional_vars=(
    "BUN_LINK_ONLY"
    "CANARY_REVISION"
    "CMAKE_TLS_VERIFY"
    "CMAKE_VERBOSE_MAKEFILE"
    "ENABLE_BASELINE"
    "ENABLE_CANARY"
)

additional_vars_found=0
for var in "${additional_vars[@]}"; do
    value="${!var}"
    if [ -n "$value" ]; then
        echo "  $var: $value"
        # Escape single quotes in the value
        escaped_value=$(printf %s "$value" | sed "s/'/'\\\\''/g")
        BUILDKITE_ENV="$BUILDKITE_ENV export $var='$escaped_value';"
        additional_vars_found=$((additional_vars_found + 1))
    fi
done

if [ $additional_vars_found -eq 0 ]; then
    echo "  ℹ️  No additional build variables found"
else
    echo "  ✅ Found $additional_vars_found additional build variables"
fi
echo "==========================================="

# Ensure buildkite-agent is in PATH
BUILDKITE_ENV="$BUILDKITE_ENV export PATH=\"\$HOME/.buildkite-agent/bin:/usr/local/bin:/opt/homebrew/bin:\$PATH\";"

echo "=== SETTING UP BUILDKITE AGENT IN VM ==="
sshpass -p admin ssh $SSH_OPTS "admin@$VM_IP" "bash -l -c '
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

exec sshpass -p admin ssh $SSH_OPTS "admin@$VM_IP" "bash -l -c '$BUILDKITE_ENV cd /tmp/workspace && $COMMAND'" 