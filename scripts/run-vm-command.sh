#!/bin/bash

echo "🎯 VM: $1"
echo "⚡ Command: $2"

# Check if VM name is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <vm-name> [command]"
    exit 1
fi

VM_NAME="$1"
COMMAND="${2:-echo 'VM is ready'}"

# SSH options for reliability - comprehensive host key bypass
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=5 -o ServerAliveCountMax=3"

echo "🔍 ===== WAITING FOR VM ====="

# Function to wait for VM and get IP
# Required for ssh access to the VM
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
            # Give SSH service a moment to fully start after getting IP
            if [ $attempt -eq 0 ]; then
                echo "VM got IP $VM_IP, waiting for SSH service to start..."
                sleep 10
            fi
            
            # Test SSH connectivity with comprehensive options
            if sshpass -p admin ssh $SSH_OPTS -o ConnectTimeout=10 "admin@$VM_IP" echo "test" &>/dev/null; then
                echo "VM is ready at $VM_IP"
                return 0
            fi
        fi
        
        attempt=$((attempt + 1))
        echo "Attempt $attempt/$max_attempts: Waiting for VM..."
        sleep 5  # Increased from 2 to 5 seconds between attempts
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

echo "🌐 VM IP: $VM_IP"
echo "Running command in VM: $COMMAND"

echo "📝 ===== CREATING ENVIRONMENT FILE ====="

# ===== CREATE ENVIRONMENT FILE =====
ENV_FILE="./buildkite_env.sh"

cat > "$ENV_FILE" << 'EOF'
#!/bin/bash
# Environment variables exported from Buildkite host

# Add standard paths (including Rust/Cargo from standard location and system-wide symlinks)
export PATH="$HOME/.buildkite-agent/bin:/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

EOF

# Export all environment variables to the file
echo "Exporting environment variables..."
env_count=0
buildkite_count=0

while IFS='=' read -r -d '' name value; do
    if [[ -n "$name" && -n "$value" ]]; then
        # Skip host-specific variables that shouldn't be copied
        if [[ "$name" == "HOME" || "$name" == "TMPDIR" || "$name" == "LD_SUPPORT_TMPDIR" || "$name" == "PATH" ]]; then
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

echo "📦 ===== COPYING WORKSPACE TO VM ====="

# ===== COPY WORKSPACE TO VM =====
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

echo "⚙️  ===== SETTING UP VM ENVIRONMENT ====="

# ===== SETUP VM ENVIRONMENT =====

sshpass -p admin ssh $SSH_OPTS admin@$VM_IP bash -s <<'REMOTE_SETUP'
set -eo pipefail

echo "🔧 Setting up VM environment..."
cd ~/workspace

# Source environment variables
source ./buildkite_env.sh

# Set VM-specific paths
export WORKSPACE="$HOME/workspace"
export BUILDKITE_BUILD_PATH="$HOME/workspace/build-workdir"
export VENDOR_PATH="$HOME/workspace/vendor"
export TMPDIR="/tmp"
export LD_SUPPORT_TMPDIR="/tmp"

# === DIAGNOSTIC LOGGING FOR ISSUE #24 ===
echo "🔍 === LIFECYCLE SCRIPT ENVIRONMENT DEBUG ==="
echo "Current PATH: $PATH"
echo "User: $(whoami)"
echo "Working directory: $(pwd)"
echo ""
echo "Tool availability check:"
echo "  which bun: $(which bun 2>/dev/null || echo 'NOT FOUND')"
echo "  which node: $(which node 2>/dev/null || echo 'NOT FOUND')"
echo "  which npm: $(which npm 2>/dev/null || echo 'NOT FOUND')"
echo "  which node-gyp: $(which node-gyp 2>/dev/null || echo 'NOT FOUND')"
echo ""
echo "Bun version check:"
if command -v bun >/dev/null 2>&1; then
    echo "  bun --version: $(bun --version 2>/dev/null || echo 'ERROR')"
    echo "  bun location: $(command -v bun)"
else
    echo "  bun: COMMAND NOT FOUND"
fi
echo ""
echo "Node version check:"
if command -v node >/dev/null 2>&1; then
    echo "  node --version: $(node --version 2>/dev/null || echo 'ERROR')"
    echo "  node location: $(command -v node)"
else
    echo "  node: COMMAND NOT FOUND"
fi
echo ""
echo "Directory contents check:"
echo "  /usr/local/bin/ (bun/node): $(ls /usr/local/bin/ 2>/dev/null | grep -E '(bun|node)' || echo 'none found')"
echo "  /opt/homebrew/bin/ (bun/node): $(ls /opt/homebrew/bin/ 2>/dev/null | grep -E '(bun|node)' || echo 'none found')"
echo "  ~/.cargo/bin/ exists: $([ -d ~/.cargo/bin ] && echo 'YES' || echo 'NO')"
echo ""
echo "Environment variables:"
echo "  HOME: $HOME"
echo "  SHELL: $SHELL"
echo "  BUILDKITE_BUILD_PATH: $BUILDKITE_BUILD_PATH"
echo "=============================================="
echo ""

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
    echo "✅ Bun found: $(bun --version)"
else
    echo "❌ Bun not found - base image may be corrupted"
    exit 1
fi

# Ensure node and npm are accessible to lifecycle scripts
if command -v node >/dev/null 2>&1; then
    NODE_BIN=$(command -v node)
    sudo ln -sf "$NODE_BIN" /usr/local/bin/node 2>/dev/null || true
    echo "✅ Node symlink created: $NODE_BIN -> /usr/local/bin/node"
else
    echo "⚠️  Node not found - some lifecycle scripts may fail"
fi

if command -v npm >/dev/null 2>&1; then
    NPM_BIN=$(command -v npm)
    sudo ln -sf "$NPM_BIN" /usr/local/bin/npm 2>/dev/null || true
    echo "✅ NPM symlink created: $NPM_BIN -> /usr/local/bin/npm"
else
    echo "⚠️  NPM not found - some lifecycle scripts may fail"
fi

# Verify Rust is available
if command -v cargo >/dev/null 2>&1; then
    echo "✅ Cargo found: $(cargo --version)"
else
    echo "❌ Cargo not found - base image may be corrupted"
    exit 1
fi

echo "🔧 === Tool Verification ==="
echo "Bun: $(command -v bun || echo 'NOT FOUND')"
echo "Cargo: $(command -v cargo || echo 'NOT FOUND')" 
echo "CMake: $(command -v cmake || echo 'NOT FOUND')"
echo "Node: $(command -v node || echo 'NOT FOUND')"
echo "============================="

# Debug: Show Rust/Cargo availability
echo "🦀 === Rust Debug Info ==="

# Check standard Rust installation location
echo "🔍 Checking standard Rust installation..."
if [ -d "$HOME/.cargo" ]; then
    echo "✅ ~/.cargo directory exists"
    if [ -d "$HOME/.cargo/bin" ]; then
        echo "✅ ~/.cargo/bin directory exists"
        ls -la "$HOME/.cargo/bin/" | grep -E "(cargo|rustc|rustup)" || echo "❌ No Rust binaries in ~/.cargo/bin"
    else
        echo "❌ No ~/.cargo/bin directory"
    fi
else
    echo "❌ No ~/.cargo directory found"
fi

# Check system-wide symlinks
echo "🔍 Checking system-wide Rust symlinks..."
for location in "/usr/local/bin" "/opt/homebrew/bin"; do
    if [ -d "$location" ]; then
        echo "Checking $location:"
        ls -la "$location" | grep -E "(cargo|rustc|rustup)" || echo "  No Rust symlinks found"
    fi
done

# Try to find Rust anywhere on the system
echo "🔍 Searching for Rust binaries system-wide..."
find /usr -name "cargo" 2>/dev/null || echo "No cargo found in /usr"
find /opt -name "cargo" 2>/dev/null || echo "No cargo found in /opt"
find "$HOME" -name "cargo" 2>/dev/null || echo "No cargo found in $HOME"

# Check our environment file
echo "🔍 Checking environment file..."
if [ -f "./buildkite_env.sh" ]; then
    echo "✅ buildkite_env.sh exists"
    echo "PATH line in env file:"
    grep "^export PATH=" ./buildkite_env.sh || echo "❌ No PATH export found"
else
    echo "❌ buildkite_env.sh not found"
fi

# Use which commands for clarity
echo "🔍 Using 'which' to locate Rust tools..."
which cargo && echo "✅ Cargo found at: $(which cargo)" || echo "❌ Cargo not found"
which rustc && echo "✅ Rustc found at: $(which rustc)" || echo "❌ Rustc not found"
which rustup && echo "✅ Rustup found at: $(which rustup)" || echo "❌ Rustup not found"

if command -v cargo >/dev/null 2>&1; then
    echo "✅ Cargo found: $(command -v cargo)"
    echo "✅ Cargo version: $(cargo --version)"
else
    echo "❌ Cargo not found in PATH"
fi

if command -v rustc >/dev/null 2>&1; then
    echo "✅ Rustc found: $(command -v rustc)"
    echo "✅ Rustc version: $(rustc --version)"
else
    echo "❌ Rustc not found in PATH"
fi

echo "🛤️  Current PATH: $PATH"
echo "========================"

echo "✅ VM environment setup complete"
REMOTE_SETUP

echo "🎬 ===== EXECUTING COMMAND ====="

# ===== EXECUTE COMMAND =====

# Execute the user command in the VM - using heredoc for better escaping
sshpass -p admin ssh $SSH_OPTS admin@$VM_IP bash -s <<REMOTE_EXEC
set -eo pipefail
cd ~/workspace
source ./buildkite_env.sh
export WORKSPACE="\$HOME/workspace"
export BUILDKITE_BUILD_PATH="\$HOME/workspace/build-workdir"
export VENDOR_PATH="\$HOME/workspace/vendor"
export TMPDIR="/tmp"
export LD_SUPPORT_TMPDIR="/tmp"

echo "🚀 Executing: $COMMAND"
$COMMAND
REMOTE_EXEC
EXIT_CODE=$?

echo "📤 ===== COPYING ARTIFACTS BACK ====="

# ===== COPY ARTIFACTS BACK =====

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

echo "🧹 ===== CLEANUP ====="

# ===== CLEANUP =====
rm -f "$ENV_FILE" || true
echo "✅ Cleanup complete"

echo "===== RUN VM COMMAND COMPLETE ====="
echo "Exit code: $EXIT_CODE"

# Propagate exit status
exit $EXIT_CODE