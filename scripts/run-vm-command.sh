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
            # Test SSH connectivity with comprehensive options
            if sshpass -p admin ssh $SSH_OPTS -o ConnectTimeout=2 "admin@$VM_IP" echo "test" &>/dev/null; then
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
            value="/Users/admin/workspace/build"
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

# Copy entire workspace to VM using rsync (more reliable than tar+ssh)
if rsync -av --delete \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='.DS_Store' \
    --exclude='*.tmp' \
    --exclude='*.log' \
    -e "sshpass -p admin ssh $SSH_OPTS" ./ admin@$VM_IP:~/workspace/; then
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
export BUILDKITE_BUILD_PATH="$HOME/workspace/build"
export VENDOR_PATH="$HOME/workspace/vendor"
export TMPDIR="/tmp"
export LD_SUPPORT_TMPDIR="/tmp"

# Verify tools are available
echo "🔒 Verifying build tools..."
command -v bun >/dev/null 2>&1 && echo "✅ Bun: $(bun --version)" || echo "❌ Bun not found"
command -v cmake >/dev/null 2>&1 && echo "✅ CMake: $(cmake --version | head -1)" || echo "❌ CMake not found"
command -v ninja >/dev/null 2>&1 && echo "✅ Ninja: $(ninja --version)" || echo "❌ Ninja not found"
command -v clang >/dev/null 2>&1 && echo "✅ Clang: $(clang --version | head -1)" || echo "❌ Clang not found"
command -v cargo >/dev/null 2>&1 && echo "✅ Cargo: $(cargo --version)" || echo "❌ Cargo not found"

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
export BUILDKITE_BUILD_PATH="\$HOME/workspace/build"
export VENDOR_PATH="\$HOME/workspace/vendor"
export TMPDIR="/tmp"
export LD_SUPPORT_TMPDIR="/tmp"

echo "🚀 Executing: $COMMAND"
echo "📊 Started at: \$(date)"
$COMMAND
echo "🏁 Completed at: \$(date)"
REMOTE_EXEC
EXIT_CODE=$?

echo "📤 ===== COPYING ARTIFACTS BACK ====="

# ===== COPY ARTIFACTS BACK =====

echo "Copying build artifacts back from VM..."

# Copy common artifact directories back using rsync (reliable and fast)
artifact_dirs=("build" "artifacts" "dist" "zig-cache" "buildkite-cache")

for dir in "${artifact_dirs[@]}"; do
    if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "[ -d ~/workspace/$dir ]"; then
        echo "📦 Copying $dir/ back from VM..."
        
        # Create local directory if it doesn't exist
        mkdir -p "./$dir"
        
        # Use rsync for reliable copying
        if rsync -av -e "sshpass -p admin ssh $SSH_OPTS" admin@$VM_IP:~/workspace/$dir/ ./$dir/; then
            echo "✅ $dir copied back successfully"
            
            # Show size for verification
            local_size=$(du -sh "./$dir" 2>/dev/null | cut -f1 || echo "unknown")
            echo "   Size: $local_size"
        else
            echo "⚠️ Failed to copy $dir back from VM (non-fatal)"
        fi
    else
        echo "📋 No $dir/ directory found in VM"
    fi
done

echo "✅ Artifacts copied back"

echo "🧹 ===== CLEANUP ====="

# ===== CLEANUP =====
rm -f "$ENV_FILE" || true
echo "✅ Cleanup complete"

echo "===== RUN VM COMMAND COMPLETE ====="
echo "Exit code: $EXIT_CODE"

# Propagate exit status
exit $EXIT_CODE