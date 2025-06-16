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
# Create environment file in mounted workspace (no need to copy it separately)
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

echo "🔗 ===== COPYING SOURCE TO VM ====="

# ===== COPY SOURCE TO VM =====
echo "📁 Copying source code to VM (eliminates mounted filesystem issues)..."

# Create VM workspace directory
VM_WORKSPACE="/Users/admin/workspace"
sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "mkdir -p $VM_WORKSPACE"

# Copy source files to VM (excluding build artifacts and cache)
echo "Copying source files to VM..."
rsync -av \
    --exclude 'build/' \
    --exclude 'buildkite-cache/' \
    --exclude '.git/' \
    --exclude 'node_modules/' \
    --exclude '*.o' \
    --exclude '*.a' \
    --exclude 'zig-cache/' \
    --exclude 'zig-out/' \
    -e "sshpass -p admin ssh $SSH_OPTS" \
    ./ admin@$VM_IP:$VM_WORKSPACE/

echo "✅ Source code copied to VM"

# Copy environment file to VM  
sshpass -p admin scp $SSH_OPTS "$ENV_FILE" admin@$VM_IP:$VM_WORKSPACE/buildkite_env.sh
echo "✅ Environment file copied to VM"

echo "🎬 ===== EXECUTING COMMAND ====="

# ===== EXECUTE COMMAND =====

# Execute the user command in the VM using copied workspace
sshpass -p admin ssh $SSH_OPTS admin@$VM_IP bash -s <<REMOTE_EXEC
set -eo pipefail

echo "🔍 Working in copied workspace..."
echo "Current directory: \$(pwd)"

# Change to copied workspace directory 
cd "$VM_WORKSPACE"
echo "✅ Changed to workspace: $VM_WORKSPACE"

# Source environment variables
source ./buildkite_env.sh

# Set VM workspace paths (using local filesystem - no mounted paths!)
export WORKSPACE="$VM_WORKSPACE"
export BUILDKITE_BUILD_PATH="$VM_WORKSPACE/build"
export VENDOR_PATH="$VM_WORKSPACE/vendor"
export TMPDIR="/tmp"
export LD_SUPPORT_TMPDIR="/tmp"

# Use standard local cache directories (no overrides needed)
export ZIG_LOCAL_CACHE_DIR="/tmp/zig-cache/local"
export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache/global"
export CCACHE_DIR="/tmp/ccache"

# Create cache directories
mkdir -p "/tmp/zig-cache/local" "/tmp/zig-cache/global" "/tmp/ccache"

echo "🔧 Using local filesystem cache directories:"
echo "  Workspace: $VM_WORKSPACE (local filesystem)"
echo "  Build: $VM_WORKSPACE/build"
echo "  Zig Cache: /tmp/zig-cache/"
echo "  Ccache: /tmp/ccache"
echo "  ✅ No mounted filesystem issues!"

# Verify workspace setup
echo "🔍 Verifying workspace setup..."
ls -la "$VM_WORKSPACE/" | head -10
echo "📁 Workspace contents look good"

# Verify tools are available
echo "🔒 Verifying build tools..."
command -v bun >/dev/null 2>&1 && echo "✅ Bun: \$(bun --version)" || echo "❌ Bun not found"
command -v cmake >/dev/null 2>&1 && echo "✅ CMake: \$(cmake --version | head -1)" || echo "❌ CMake not found"
command -v ninja >/dev/null 2>&1 && echo "✅ Ninja: \$(ninja --version)" || echo "❌ Ninja not found"
command -v clang >/dev/null 2>&1 && echo "✅ Clang: \$(clang --version | head -1)" || echo "❌ Clang not found"

echo "🚀 Executing: $COMMAND"
$COMMAND
REMOTE_EXEC
EXIT_CODE=$?

echo "📤 ===== COPYING FINAL ARTIFACTS BACK ====="

# ===== COPY BUILD ARTIFACTS BACK =====

artifact_dirs=("build" "artifacts" "dist")

echo "📦 Copying build artifacts back from VM..."

# Check if any artifact directories exist in the VM workspace
should_copy=false
for dir in "${artifact_dirs[@]}"; do
    if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "[ -d \"$VM_WORKSPACE/$dir\" ]"; then
        should_copy=true
        break
    fi
done

if [ "$should_copy" = true ]; then
    echo "Copying final artifacts back from VM..."
    
    # Copy artifacts back from VM workspace
    for dir in "${artifact_dirs[@]}"; do
        if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "[ -d \"$VM_WORKSPACE/$dir\" ]"; then
            echo "Copying $dir/ back..."
            
            # Use rsync to copy artifacts back efficiently
            if rsync -av -e "sshpass -p admin ssh $SSH_OPTS" "admin@$VM_IP:$VM_WORKSPACE/$dir/" ./$dir/ 2>/dev/null; then
                echo "✅ rsync succeeded for $dir"
            else
                echo "⚠️ rsync failed, trying tar+ssh fallback for $dir..."
                
                # Fallback: use tar over SSH
                mkdir -p "./$dir"
                if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "cd \"$VM_WORKSPACE\" && tar -cf - \"$dir\"" | tar -xf - 2>/dev/null; then
                    echo "✅ tar+ssh fallback succeeded for $dir"
                else
                    echo "❌ Both rsync and tar+ssh failed for $dir"
                fi
            fi
        fi
    done
    
    echo "✅ Final artifacts copied back"
else
    echo "No final artifact directories found, skipping artifact copy"
fi

echo "🧹 ===== CLEANUP ====="

# ===== CLEANUP =====
rm -f "$ENV_FILE" || true
echo "✅ Cleanup complete"

echo "===== RUN VM COMMAND COMPLETE ====="
echo "Exit code: $EXIT_CODE"

# Propagate exit status
exit $EXIT_CODE