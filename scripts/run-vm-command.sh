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

# Check for required dependencies and install if needed
if ! command -v sshpass >/dev/null 2>&1; then
    echo "🔧 sshpass is required but not found - installing automatically..."
    
    # Try to use Homebrew to install sshpass
    if command -v brew >/dev/null 2>&1; then
        echo "   Installing sshpass via Homebrew..."
        if brew install sshpass; then
            echo "✅ sshpass installed successfully"
        else
            echo "❌ Failed to install sshpass via Homebrew"
            echo "   Please install sshpass manually:"
            echo "   brew install sshpass"
            exit 1
        fi
    else
        echo "❌ Homebrew not found - cannot auto-install sshpass"
        echo "   Please install sshpass manually:"
        echo "   1. Install Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        echo "   2. Install sshpass: brew install sshpass"
        echo "   Current PATH: $PATH"
        exit 1
    fi
    
    # Verify installation worked
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "❌ sshpass installation failed - still not available"
        echo "   Please check your Homebrew installation and PATH"
        exit 1
    fi
else
    echo "✅ sshpass is available"
fi

# SSH options for reliability - comprehensive host key bypass
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=5 -o ServerAliveCountMax=3"

echo "🔍 ===== WAITING FOR VM ====="

# Function to wait for VM and get IP
# Required for ssh access to the VM
wait_for_vm() {
    local vm_name="$1"
    
    echo "Waiting for VM '$vm_name' to be ready..."
    
    # Get VM IP with more reliable retry logic
    echo "Waiting for VM to get an IP address..."
    for i in {1..15}; do
        # Check if VM is running
        if ! tart list | grep -q "$vm_name.*running"; then
            echo "Error: VM '$vm_name' is not running"
            return 1
        fi
        
        VM_IP=$(tart ip "$vm_name" 2>/dev/null || echo "")
        if [ -n "$VM_IP" ]; then
            echo "VM IP: $VM_IP"
            break
        fi
        echo "Attempt $i/15: waiting for VM IP..."
        sleep 5
    done
    
    if [ -z "$VM_IP" ]; then
        echo "Error: Could not get VM IP after 15 attempts"
        return 1
    fi

    # Wait for SSH to be available
    echo "Waiting for SSH service to be ready..."
    
    # First wait for SSH service to be ready by checking port
    for i in {1..10}; do
        if nc -z "$VM_IP" 22 >/dev/null 2>&1; then
            echo "✅ SSH port is open"
            break
        fi
        if [ $i -eq 10 ]; then
            echo "Error: SSH port 22 did not open on VM"
            return 1
        fi
        echo "SSH port not ready, attempt $i/10..."
        sleep 5
    done
    
    # Now try SSH connection with more reliable retry logic
    for i in {1..30}; do
        echo "SSH attempt $i/30..."
        if sshpass -p admin ssh $SSH_OPTS -o ConnectTimeout=10 "admin@$VM_IP" "echo 'SSH connection successful'" &>/dev/null; then
            echo "✅ SSH connection established"
            return 0
        fi
        echo "SSH attempt $i failed, retrying in 5 seconds..."
        sleep 5
    done
    
    echo "Error: VM SSH did not become ready within timeout"
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

# Ensure bun is accessible
if command -v bun >/dev/null 2>&1; then
    BUN_BIN=$(command -v bun)
    sudo ln -sf "$BUN_BIN" /usr/local/bin/bun 2>/dev/null || true
    echo "✅ Bun found: $(bun --version)"
else
    echo "❌ Bun not found - base image may be corrupted"
    exit 1
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

# Execute the user command in the VM - using direct SSH with TTY for real-time output
echo "🚀 Executing: $COMMAND"

# Create a temporary script file for more reliable execution and output
SCRIPT_FILE="/tmp/vm_command_$$.sh"
cat > "$SCRIPT_FILE" << 'SCRIPT_CONTENT'
#!/bin/bash
set -eo pipefail
cd ~/workspace
source ./buildkite_env.sh
export WORKSPACE="$HOME/workspace"
export BUILDKITE_BUILD_PATH="$HOME/workspace/build-workdir"
export VENDOR_PATH="$HOME/workspace/vendor"
export TMPDIR="/tmp"
export LD_SUPPORT_TMPDIR="/tmp"

# Disable output buffering for real-time output
export PYTHONUNBUFFERED=1
export CARGO_TERM_VERBOSE=true

# Execute the command with explicit output flushing
exec bash -c 'COMMAND_TO_RUN'
SCRIPT_CONTENT

# Replace the placeholder with the actual command (properly escaped)
sed -i.bak "s/COMMAND_TO_RUN/$(printf '%s\n' "$COMMAND" | sed 's/[[\.*^$()+?{|]/\\&/g')/g" "$SCRIPT_FILE"

# Copy script to VM
echo "📝 Copying execution script to VM..."
sshpass -p admin scp $SSH_OPTS "$SCRIPT_FILE" admin@$VM_IP:/tmp/vm_command.sh

# Execute with TTY allocation for real-time output and proper signal handling
echo "⚡ Executing command with real-time output..."
sshpass -p admin ssh -t $SSH_OPTS admin@$VM_IP 'bash -l /tmp/vm_command.sh'
EXIT_CODE=$?

# Cleanup temporary files
rm -f "$SCRIPT_FILE" || true
sshpass -p admin ssh $SSH_OPTS admin@$VM_IP 'rm -f /tmp/vm_command.sh' || true

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