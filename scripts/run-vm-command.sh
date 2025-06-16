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
            value="/Volumes/My Shared Files/workspace/build-workdir"
        fi
        
        printf 'export %s=%q\n' "$name" "$value" >> "$ENV_FILE"
        env_count=$((env_count + 1))
        
        if [[ "$name" == BUILDKITE_* ]]; then
            buildkite_count=$((buildkite_count + 1))
        fi
    fi
done < <(env -0)

echo "✅ Exported $env_count environment variables ($buildkite_count BUILDKITE_* vars)"

echo "🔗 ===== WORKSPACE AND CACHE MOUNTED ====="

# ===== WORKSPACE AND CACHE ALREADY MOUNTED =====
echo "✅ Workspace already mounted to VM via Tart at /Volumes/My Shared Files/workspace"
if [ "${BUILDKITE_CACHE_TYPE:-}" = "persistent" ] && [ "${BUN_LINK_ONLY:-}" != "ON" ]; then
    echo "✅ Cache directory inside mounted workspace at /Volumes/My Shared Files/workspace/buildkite-cache" 
    echo "🚀 Using fast workspace mount with persistent cache!"
elif [ "${BUN_LINK_ONLY:-}" = "ON" ]; then
    echo "🔗 Linking step - using completely fresh environment (no cache directory)"
    echo "🚀 Using fast workspace mount with fresh build environment!"
else
    echo "📋 No persistent cache configured"
fi

echo "🎬 ===== EXECUTING COMMAND ====="

# ===== EXECUTE COMMAND =====

# Execute the user command in the VM using mounted directories
sshpass -p admin ssh $SSH_OPTS admin@$VM_IP bash -s <<REMOTE_EXEC
set -eo pipefail

echo "🔍 Debugging workspace mount issue..."
echo "Current directory: \$(pwd)"
echo "Available volumes:"
ls -la /Volumes/ || echo "No /Volumes directory found"

# Check if workspace mount exists
if [ -d "/Volumes/My Shared Files/workspace" ]; then
    echo "✅ /Volumes/My Shared Files/workspace exists"
    echo "Contents:"
    ls -la "/Volumes/My Shared Files/workspace/" | head -5 || echo "Cannot list workspace contents"
    
    # Change to mounted workspace directory 
    cd "/Volumes/My Shared Files/workspace"
    echo "✅ Successfully changed to /Volumes/My Shared Files/workspace"
else
    echo "❌ /Volumes/My Shared Files/workspace does not exist - mount failed"
    echo "Trying alternative workspace locations..."
    
    # Try alternative locations
    if [ -d "/Users/admin/workspace" ]; then
        echo "Found workspace at /Users/admin/workspace"
        cd /Users/admin/workspace
    elif [ -d "/home/admin/workspace" ]; then
        echo "Found workspace at /home/admin/workspace"  
        cd /home/admin/workspace
    else
        echo "❌ No workspace found anywhere"
        exit 1
    fi
fi

# Source environment variables (from mounted workspace)
source ./buildkite_env.sh

# Set VM-specific paths for mounted directories
export WORKSPACE="/Volumes/My Shared Files/workspace"
export BUILDKITE_BUILD_PATH="/Volumes/My Shared Files/workspace/build-workdir"
export VENDOR_PATH="/Volumes/My Shared Files/workspace/vendor"
export TMPDIR="/tmp"
export LD_SUPPORT_TMPDIR="/tmp"

# Verify mount points
echo "🔍 Verifying mount points..."
ls -la /Volumes/ || true
if [ -d "/Volumes/My Shared Files/workspace" ]; then
    echo "✅ Workspace mounted at /Volumes/My Shared Files/workspace"
    ls -la "/Volumes/My Shared Files/workspace/" | head -10
    
    # Check if cache directory exists inside workspace
    if [ "${BUN_LINK_ONLY:-}" = "ON" ]; then
        echo "🔗 Linking step - cache directory intentionally not created for fresh environment"
    elif [ "${BUILDKITE_CACHE_TYPE:-}" = "persistent" ]; then
        if [ -d "/Volumes/My Shared Files/workspace/buildkite-cache" ]; then
            echo "✅ Cache directory found inside workspace"
            ls -la "/Volumes/My Shared Files/workspace/buildkite-cache/" || true
        else
            echo "⚠️  Cache directory not found (will be created by build script)"
        fi
    else
        echo "📋 No persistent cache configured"
    fi
else
    echo "❌ Workspace not mounted properly"
    exit 1
fi

# Verify hermetic dependencies inside VM (where tools actually exist)
echo "🔒 Verifying hermetic tool versions inside VM..."

# Check key tools that should be available in the VM
echo "🔍 Checking build tools:"
command -v bun >/dev/null 2>&1 && echo "✅ Bun: \$(bun --version)" || echo "❌ Bun not found"
command -v cmake >/dev/null 2>&1 && echo "✅ CMake: \$(cmake --version | head -1)" || echo "❌ CMake not found"
command -v ninja >/dev/null 2>&1 && echo "✅ Ninja: \$(ninja --version)" || echo "❌ Ninja not found"
command -v clang >/dev/null 2>&1 && echo "✅ Clang: \$(clang --version | head -1)" || echo "❌ Clang not found"
command -v rustc >/dev/null 2>&1 && echo "✅ Rustc: \$(rustc --version)" || echo "❌ Rustc not found"
command -v cargo >/dev/null 2>&1 && echo "✅ Cargo: \$(cargo --version)" || echo "❌ Cargo not found"
command -v ccache >/dev/null 2>&1 && echo "✅ Ccache: \$(ccache --version | head -1)" || echo "❌ Ccache not found"
command -v buildkite-agent >/dev/null 2>&1 && echo "✅ buildkite-agent available" || echo "❌ buildkite-agent not found"

echo "🚀 Executing: $COMMAND"
$COMMAND
REMOTE_EXEC
EXIT_CODE=$?

echo "📤 ===== COPYING FINAL ARTIFACTS BACK ====="

# ===== COPY ONLY FINAL ARTIFACTS BACK =====

# Only copy build artifacts back (cache is mounted so no need to copy)
artifact_dirs=("build" "artifacts" "dist")

echo "📦 Copying final build artifacts only (cache stays mounted)"

# Check if any artifact directories exist in the workspace
should_copy=false
for dir in "${artifact_dirs[@]}"; do
    if [ -d "./$dir" ]; then
        should_copy=true
        break
    fi
done

if [ "$should_copy" = true ]; then
    echo "Copying final artifacts back from VM..."
    
    # Copy only final artifacts back (much faster than full rsync)
    for dir in "${artifact_dirs[@]}"; do
        if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "[ -d \"/Volumes/My Shared Files/workspace/$dir\" ]"; then
            echo "Copying $dir/ back..."
            rsync -av -e "sshpass -p admin ssh $SSH_OPTS" "admin@$VM_IP:/Volumes/My Shared Files/workspace/$dir/" ./$dir/ || true
        fi
    done
    
    echo "✅ Final artifacts copied back"
else
    echo "No final artifact directories found, skipping artifact copy"
fi

# Note: Cache is not copied back because it's mounted directly - 
# changes persist automatically on the host filesystem!

echo "🧹 ===== CLEANUP ====="

# ===== CLEANUP =====
rm -f "$ENV_FILE" || true
echo "✅ Cleanup complete"

echo "===== RUN VM COMMAND COMPLETE ====="
echo "Exit code: $EXIT_CODE"

# Propagate exit status
exit $EXIT_CODE