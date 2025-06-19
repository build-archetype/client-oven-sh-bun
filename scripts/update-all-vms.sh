#!/bin/bash
set -e

# Universal VM Update Script
# Automatically finds and updates ALL VMs starting with "bun-build" to Bun 1.2.16

TARGET_BUN_VERSION="1.2.16"
TART_PATH="/opt/homebrew/bin/tart"

echo "🚀 Universal Bun VM Updater"
echo "Target Bun version: $TARGET_BUN_VERSION"
echo ""

# Check if tart exists
if [ ! -f "$TART_PATH" ]; then
    echo "❌ Tart not found at $TART_PATH"
    echo "Looking for tart in other locations..."
    TART_PATH=$(which tart 2>/dev/null || find /opt /usr/local -name tart 2>/dev/null | head -1 || echo "")
    if [ -z "$TART_PATH" ]; then
        echo "❌ Tart not found anywhere. Please install tart first."
        exit 1
    fi
    echo "✅ Found tart at: $TART_PATH"
fi

# Get all VMs starting with bun-build
echo "🔍 Scanning for bun-build VMs..."
VMS_TO_UPDATE=()

while IFS= read -r line; do
    if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+) ]]; then
        vm_name="${BASH_REMATCH[1]}"
        if [[ "$vm_name" =~ ^bun-build ]]; then
            echo "  Found: $vm_name"
            VMS_TO_UPDATE+=("$vm_name")
        fi
    fi
done <<< "$($TART_PATH list 2>/dev/null)"

echo ""

if [ ${#VMS_TO_UPDATE[@]} -eq 0 ]; then
    echo "❌ No bun-build VMs found!"
    echo ""
    echo "Current VMs:"
    $TART_PATH list
    exit 1
fi

echo "📋 VMs to update: ${#VMS_TO_UPDATE[@]}"
for vm_name in "${VMS_TO_UPDATE[@]}"; do
    echo "  $vm_name"
done
echo ""

# Update each VM
for vm_name in "${VMS_TO_UPDATE[@]}"; do
    echo "🔄 Updating VM: $vm_name"
    
    # Start VM
    echo "  🚀 Starting VM..."
    $TART_PATH run "$vm_name" --no-graphics &
    VM_PID=$!
    sleep 5
    
    # Get VM IP
    echo "  🌐 Getting VM IP..."
    VM_IP=""
    for i in {1..15}; do
        VM_IP=$($TART_PATH ip "$vm_name" 2>/dev/null || echo "")
        if [ -n "$VM_IP" ]; then
            echo "  VM IP: $VM_IP"
            break
        fi
        echo "    Attempt $i/15..."
        sleep 2
    done
    
    if [ -z "$VM_IP" ]; then
        echo "  ❌ Could not get VM IP"
        kill $VM_PID 2>/dev/null || true
        echo "  🧹 Stopped VM"
        continue
    fi
    
    # Wait for SSH
    echo "  ⏳ Waiting for SSH..."
    SSH_READY=false
    for i in {1..30}; do
        if sshpass -p "admin" ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no admin@"$VM_IP" "echo test" >/dev/null 2>&1; then
            SSH_READY=true
            break
        fi
        sleep 2
    done
    
    if [ "$SSH_READY" != "true" ]; then
        echo "  ❌ SSH not ready"
        kill $VM_PID 2>/dev/null || true
        echo "  🧹 Stopped VM"
        continue
    fi
    
    # Update Bun
    echo "  🎯 Updating Bun to $TARGET_BUN_VERSION..."
    UPDATE_RESULT=0
    sshpass -p "admin" ssh -o StrictHostKeyChecking=no admin@"$VM_IP" "
        echo 'Updating Bun...'
        export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH
        
        # Install specific Bun version
        if curl -fsSL https://bun.sh/install | bash -s -- bun-v${TARGET_BUN_VERSION}; then
            echo 'Bun downloaded successfully'
            
            # Verify installation
            if ~/.bun/bin/bun --version | grep -q '${TARGET_BUN_VERSION}'; then
                echo 'Bun version verified: ${TARGET_BUN_VERSION}'
                
                # Update system-wide symlinks
                sudo ln -sf ~/.bun/bin/bun /opt/homebrew/bin/bun 2>/dev/null || sudo ln -sf ~/.bun/bin/bun /usr/local/bin/bun
                sudo ln -sf ~/.bun/bin/bunx /opt/homebrew/bin/bunx 2>/dev/null || sudo ln -sf ~/.bun/bin/bunx /usr/local/bin/bunx
                
                echo 'Bun update complete! ✅'
                exit 0
            else
                echo 'Bun version verification failed'
                exit 1
            fi
        else
            echo 'Bun download failed'
            exit 1
        fi
    " || UPDATE_RESULT=1
    
    # Stop VM
    echo "  🛑 Stopping VM..."
    sshpass -p "admin" ssh -o StrictHostKeyChecking=no admin@"$VM_IP" "sudo shutdown -h now" >/dev/null 2>&1 || true
    sleep 3
    kill $VM_PID >/dev/null 2>&1 || true
    
    if [ $UPDATE_RESULT -eq 0 ]; then
        echo "  ✅ Successfully updated: $vm_name"
    else
        echo "  ❌ Update failed for: $vm_name"
    fi
    
    echo ""
done

echo "🎉 VM update process complete!"
echo ""
echo "Updated VMs:"
$TART_PATH list | grep bun-build || echo "No bun-build VMs found" 