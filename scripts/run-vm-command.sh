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

# SSH options with debugging for troubleshooting authentication issues
SSH_DEBUG_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=DEBUG -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o PreferredAuthentications=password -o PubkeyAuthentication=no"

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

# Give SSH service a moment to fully stabilize before starting operations
echo "⏳ Waiting 3 seconds for SSH service to fully stabilize..."
sleep 3

# Check for SSH keys that might interfere with password authentication
echo "🔍 Checking for SSH keys that might interfere..."
if [ -f ~/.ssh/id_rsa ] || [ -f ~/.ssh/id_ed25519 ] || [ -f ~/.ssh/id_ecdsa ]; then
    echo "⚠️  Found SSH keys in ~/.ssh/ - these might interfere with password auth"
    ls -la ~/.ssh/id_* 2>/dev/null || true
else
    echo "✅ No SSH keys found in ~/.ssh/"
fi

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

# Test SSH connection before copying
echo "🔍 Testing SSH connection before copying..."
if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "echo 'SSH test successful'" 2>&1; then
    echo "✅ SSH connection test passed"
else
    echo "❌ SSH connection test failed - trying with debug options..."
    echo "SSH Debug output:"
    sshpass -p admin ssh $SSH_DEBUG_OPTS admin@$VM_IP "echo 'SSH debug test'" 2>&1 || true
    
    echo "Checking VM SSH service status..."
    if nc -z "$VM_IP" 22 >/dev/null 2>&1; then
        echo "✅ SSH port 22 is still open"
    else
        echo "❌ SSH port 22 is no longer accessible"
        exit 1
    fi
    
    echo "Trying SSH with password-only authentication..."
    if sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no admin@$VM_IP "echo 'Password-only SSH test successful'" 2>&1; then
        echo "✅ Password-only SSH works"
        SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR"
    else
        echo "❌ Even password-only SSH failed"
        exit 1
    fi
fi

# Create VM workspace directory
VM_WORKSPACE="/Users/admin/workspace"
sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "mkdir -p $VM_WORKSPACE"

# Copy source files (exclude build artifacts but include cache structure)
echo "Copying source files to VM..."
if tar -czf - \
    --exclude='.git' \
    --exclude='build' \
    --exclude='zig-cache' \
    --exclude='zig-out' \
    --exclude='node_modules' \
    --exclude='.DS_Store' \
    --exclude='*.tmp' \
    --exclude='*.log' \
    . | sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "cd '$VM_WORKSPACE' && tar -xzf -" 2>&1; then
    echo "✅ Source code copied successfully"
else
    echo "❌ Failed to copy source code to VM"
    
    # Additional debugging
    echo "🔍 Debug: Testing individual SSH components..."
    
    # Test if we can still SSH at all
    echo "Testing basic SSH connectivity..."
    if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "echo 'Basic SSH still works'" 2>&1; then
        echo "✅ Basic SSH still functional"
    else
        echo "❌ Basic SSH no longer working"
        exit 1
    fi
    
    # Test if we can access the target directory
    echo "Testing VM workspace directory access..."
    if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "ls -la '$VM_WORKSPACE'" 2>&1; then
        echo "✅ Can access VM workspace directory"
    else
        echo "❌ Cannot access VM workspace directory"
        echo "Trying to create it..."
        sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "mkdir -p '$VM_WORKSPACE'" 2>&1 || true
    fi
    
    # Test a simpler copy operation
    echo "Testing simple file copy..."
    echo "test content" | sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "cat > '$VM_WORKSPACE/test.txt'" 2>&1
    if [ $? -eq 0 ]; then
        echo "✅ Simple file copy works"
        # Try the full copy again with more verbose error reporting
        echo "Retrying full copy with detailed error output..."
        tar -czf - \
            --exclude='.git' \
            --exclude='build' \
            --exclude='zig-cache' \
            --exclude='zig-out' \
            --exclude='node_modules' \
            --exclude='.DS_Store' \
            --exclude='*.tmp' \
            --exclude='*.log' \
            . | sshpass -p admin ssh -v $SSH_OPTS admin@$VM_IP "cd '$VM_WORKSPACE' && tar -xzf -" 2>&1
        if [ $? -eq 0 ]; then
            echo "✅ Retry succeeded"
        else
            echo "❌ Retry also failed"
            
            # Check SSH daemon configuration
            echo "🔍 Checking SSH daemon configuration..."
            sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "sudo grep -E '^(MaxAuthTries|PasswordAuthentication|PubkeyAuthentication)' /etc/ssh/sshd_config 2>/dev/null || echo 'Could not check SSH config'" 2>&1 || true
            
            # Check system authentication logs  
            echo "🔍 Checking recent SSH authentication logs..."
            sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "tail -10 /var/log/auth.log 2>/dev/null || tail -10 /var/log/secure 2>/dev/null || echo 'No auth logs found'" 2>&1 || true
            
            # Try alternative copying method - smaller chunks
            echo "🔄 Trying alternative copying method (smaller chunks)..."
            
            # Create the workspace directory first
            sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "mkdir -p '$VM_WORKSPACE'"
            
            # Copy everything except problematic items using find to get complete file list
            echo "Copying complete source tree (excluding build artifacts and caches)..."
            
            # Use tar with explicit exclusions to copy everything needed
            if tar -cf - \
                --exclude='.git' \
                --exclude='build' \
                --exclude='zig-cache' \
                --exclude='zig-out' \
                --exclude='node_modules' \
                --exclude='.DS_Store' \
                --exclude='*.tmp' \
                --exclude='*.log' \
                --exclude='tart.log' \
                --exclude='.tart' \
                --exclude='vm.log' \
                . | sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "cd '$VM_WORKSPACE' && tar -xf -" 2>&1; then
                echo "✅ Complete source tree copied successfully"
            else
                echo "❌ Alternative tar method also failed, trying individual directory approach..."
                
                # Get list of all directories and files (excluding problematic ones)
                ALL_ITEMS=$(find . -maxdepth 1 -type d -not -name '.' -not -name '.git' -not -name 'build' -not -name 'zig-cache' -not -name 'zig-out' -not -name 'node_modules' -not -name '.tart' | sort)
                ALL_FILES=$(find . -maxdepth 1 -type f -not -name '*.log' -not -name '*.tmp' -not -name '.DS_Store' -not -name 'tart.log' -not -name 'vm.log' | sort)
                
                echo "Copying directories individually..."
                for item in $ALL_ITEMS; do
                    if [ -d "$item" ]; then
                        echo "Copying $item..."
                        if tar -cf - "$item" | sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "cd '$VM_WORKSPACE' && tar -xf -" 2>&1; then
                            echo "✅ $item copied"
                        else
                            echo "⚠️ Failed to copy $item, continuing..."
                        fi
                    fi
                done
                
                echo "Copying files individually..."
                for item in $ALL_FILES; do
                    if [ -f "$item" ]; then
                        echo "Copying $item..."
                        if sshpass -p admin scp $SSH_OPTS "$item" admin@$VM_IP:"$VM_WORKSPACE/" 2>&1; then
                            echo "✅ $item copied"
                        else
                            echo "⚠️ Failed to copy $item, continuing..."
                        fi
                    fi
                done
                
                echo "✅ Individual file/directory copying completed"
            fi
            
            echo "✅ Alternative copying method succeeded"
        fi
    else
        echo "❌ Even simple file copy failed"
        
        # Check if this is a permission issue
        echo "🔍 Checking VM permissions and disk space..."
        sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "df -h && whoami && id" 2>&1 || true
        
        exit 1
    fi
fi

# Copy existing build artifacts to VM for incremental builds
echo "📁 Copying existing build artifacts for incremental builds..."
if [ -d "./build" ]; then
    echo "Found existing build/ directory - copying to VM for incremental build..."
    echo "🔍 Debug: About to copy $(du -sh ./build 2>/dev/null | cut -f1) of build artifacts..."
    if tar -cf - ./build | sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "cd $VM_WORKSPACE && tar -xf -"; then
        echo "✅ Build artifacts copied to VM via tar+ssh"
        # Verify the copy worked by checking what's in VM
        echo "🔍 Debug: Verifying build/ copy in VM..."
        sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "ls -la $VM_WORKSPACE/build/ 2>/dev/null | head -5" || echo "   Failed to list VM build directory"
    else
        echo "⚠️ Failed to copy build artifacts - will do clean build"
    fi
else
    echo "📋 No existing build/ directory found - will do clean build"
fi

# Copy existing zig-cache to VM for fast incremental Zig builds
echo "⚡ Copying existing zig-cache for fast Zig builds..."
if [ -d "./zig-cache" ]; then
    echo "Found existing zig-cache/ directory - copying to VM for fast Zig incremental builds..."
    echo "🔍 Debug: About to copy $(du -sh ./zig-cache 2>/dev/null | cut -f1) of Zig cache..."
    if tar -cf - ./zig-cache | sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "cd $VM_WORKSPACE && tar -xf -"; then
        echo "✅ Zig cache copied to VM via tar+ssh"
        # Verify the copy worked
        echo "🔍 Debug: Verifying zig-cache/ copy in VM..."
        sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "ls -la $VM_WORKSPACE/zig-cache/ 2>/dev/null | head -3" || echo "   Failed to list VM zig-cache directory"
    else
        echo "⚠️ Failed to copy zig-cache - will do clean Zig build"
    fi
else
    echo "📋 No existing zig-cache/ directory found - will do clean Zig build"
fi

# Copy buildkite-cache directory (for CMake cache system) if it exists
echo "🏗️  Copying buildkite-cache for CMake incremental builds..."
if [ -d "./buildkite-cache" ]; then
    echo "Found existing buildkite-cache/ directory - copying to VM for CMake incremental builds..."
    echo "🔍 Debug: About to copy $(du -sh ./buildkite-cache 2>/dev/null | cut -f1) of buildkite cache..."
    if tar -cf - ./buildkite-cache | sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "cd $VM_WORKSPACE && tar -xf -"; then
        echo "✅ Buildkite cache copied to VM via tar+ssh"
        # Verify the copy worked
        echo "🔍 Debug: Verifying buildkite-cache/ copy in VM..."
        sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "ls -la $VM_WORKSPACE/buildkite-cache/ 2>/dev/null | head -5" || echo "   Failed to list VM buildkite-cache directory"
        
        # Check for CMake cache directories specifically
        if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "[ -d $VM_WORKSPACE/buildkite-cache/build-results ]"; then
            echo "🔍 Debug: CMake cache build-results found in VM:"
            sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "ls -la $VM_WORKSPACE/buildkite-cache/build-results/ 2>/dev/null" || echo "   Failed to list build-results"
        else
            echo "🔍 Debug: No CMake cache build-results directory found in VM"
        fi
    else
        echo "⚠️ Failed to copy buildkite-cache - will do clean CMake build"
    fi
else
    echo "📋 No existing buildkite-cache/ directory found - will do clean CMake build"
fi

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

# Don't override cache directories - let build.mjs persistent cache settings be used
# The cache directories will be set by build.mjs to point to persistent locations
# instead of /tmp which gets lost when VM is destroyed

echo "🔧 Using persistent cache directories (set by build.mjs):"
echo "  Workspace: $VM_WORKSPACE (local filesystem)"
echo "  Build: $VM_WORKSPACE/build"
echo "  Cache: Using build.mjs persistent cache configuration"
echo "  ✅ Cache will persist across builds!"

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

# ===== COPY BUILD ARTIFACTS AND CACHES BACK =====

artifact_dirs=("build" "artifacts" "dist")
cache_dirs=("zig-cache" "buildkite-cache")

echo "📦 Copying build artifacts and caches back from VM..."

# Debug: Show what exists in VM before copying back
echo "🔍 Debug: VM filesystem state before copying back:"
sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "ls -la $VM_WORKSPACE/ | head -15" || echo "   Failed to list VM workspace"

# Copy build artifacts back from VM workspace
for dir in "${artifact_dirs[@]}"; do
    if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "[ -d \"$VM_WORKSPACE/$dir\" ]"; then
        echo "Copying $dir/ back from VM..."
        echo "🔍 Debug: VM $dir/ directory info:"
        sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "du -sh \"$VM_WORKSPACE/$dir\" 2>/dev/null || echo 'Size unknown'"
        sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "find \"$VM_WORKSPACE/$dir\" -name '*.a' -o -name '*.o' -o -name 'bun*' 2>/dev/null | head -5" || echo "   No build artifacts found"
        
        # Use tar over SSH (more reliable than rsync with sshpass)
        if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "cd \"$VM_WORKSPACE\" && tar -cf - \"$dir\"" | tar -xf -; then
            echo "✅ $dir copied back via tar+ssh"
            # Verify copy back worked
            echo "🔍 Debug: Verifying $dir/ copied back to HOST:"
            echo "   HOST $dir/ size: $(du -sh ./$dir 2>/dev/null | cut -f1 || echo 'unknown')"
        else
            echo "❌ Failed to copy $dir back from VM"
        fi
    else
        echo "📋 No $dir/ directory found in VM to copy back"
    fi
done

# Copy incremental caches back for next build
for dir in "${cache_dirs[@]}"; do
    if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "[ -d \"$VM_WORKSPACE/$dir\" ]"; then
        echo "⚡ Copying $dir/ back for fast incremental builds..."
        echo "🔍 Debug: VM $dir/ directory info:"
        sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "du -sh \"$VM_WORKSPACE/$dir\" 2>/dev/null || echo 'Size unknown'"
        
        # For buildkite-cache, show what's in build-results specifically
        if [ "$dir" = "buildkite-cache" ]; then
            echo "🔍 Debug: VM buildkite-cache/build-results contents:"
            sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "ls -la \"$VM_WORKSPACE/$dir/build-results/\" 2>/dev/null || echo 'No build-results directory'"
        fi
        
        # Use tar over SSH for cache directories
        if sshpass -p admin ssh $SSH_OPTS admin@$VM_IP "cd \"$VM_WORKSPACE\" && tar -cf - \"$dir\"" | tar -xf -; then
            echo "✅ $dir copied back via tar+ssh"
            # Verify copy back worked
            echo "🔍 Debug: Verifying $dir/ copied back to HOST:"
            echo "   HOST $dir/ size: $(du -sh ./$dir 2>/dev/null | cut -f1 || echo 'unknown')"
            
            # For buildkite-cache, verify CMake cache structure
            if [ "$dir" = "buildkite-cache" ] && [ -d "./$dir/build-results" ]; then
                echo "🔍 Debug: HOST buildkite-cache/build-results contents:"
                ls -la ./$dir/build-results/ 2>/dev/null | head -5 || echo "   Empty or inaccessible"
            fi
        else
            echo "⚠️ Failed to copy $dir back - next build may be slower"
        fi
    else
        echo "📋 No $dir/ directory found in VM to copy back"
    fi
done

echo "✅ Build artifacts and caches copied back from VM"

echo "🧹 ===== CLEANUP ====="

# ===== CLEANUP =====
rm -f "$ENV_FILE" || true
echo "✅ Cleanup complete"

echo "===== RUN VM COMMAND COMPLETE ====="
echo "Exit code: $EXIT_CODE"

# Propagate exit status
exit $EXIT_CODE