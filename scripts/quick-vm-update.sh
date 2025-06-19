#!/bin/bash
set -e

# Quick VM update script - run this on each build machine
# Updates VM from one version to another by cloning and updating Bun

OLD_VERSION="1.2.16"
NEW_VERSION="1.2.17"
MACOS_RELEASE="13"  # Change to 14 if needed
BOOTSTRAP_VERSION="4.1"

OLD_VM="bun-build-macos-${MACOS_RELEASE}-${OLD_VERSION}-bootstrap-${BOOTSTRAP_VERSION}"
NEW_VM="bun-build-macos-${MACOS_RELEASE}-${NEW_VERSION}-bootstrap-${BOOTSTRAP_VERSION}"

echo "🔄 Quick VM Update: $OLD_VM → $NEW_VM"

# Check if old VM exists
if ! tart list | grep -q "$OLD_VM"; then
    echo "❌ Old VM not found: $OLD_VM"
    echo "Available VMs:"
    tart list | grep bun-build-macos || echo "None"
    exit 1
fi

# Check if new VM already exists
if tart list | grep -q "$NEW_VM"; then
    echo "✅ New VM already exists: $NEW_VM"
    echo "Nothing to do!"
    exit 0
fi

# Clone old VM to new name
echo "📋 Cloning $OLD_VM to $NEW_VM..."
tart clone "$OLD_VM" "$NEW_VM"

# Start new VM
echo "🚀 Starting VM for update..."
tart run "$NEW_VM" --no-graphics &
VM_PID=$!
sleep 5

# Get VM IP
echo "🌐 Getting VM IP..."
VM_IP=""
for i in {1..10}; do
    VM_IP=$(tart ip "$NEW_VM" 2>/dev/null || echo "")
    if [ -n "$VM_IP" ]; then
        echo "VM IP: $VM_IP"
        break
    fi
    sleep 2
done

if [ -z "$VM_IP" ]; then
    echo "❌ Could not get VM IP"
    kill $VM_PID 2>/dev/null || true
    tart delete "$NEW_VM"
    exit 1
fi

# Wait for SSH
echo "⏳ Waiting for SSH..."
for i in {1..30}; do
    if sshpass -p "admin" ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no admin@"$VM_IP" "echo test" >/dev/null 2>&1; then
        echo "✅ SSH ready"
        break
    fi
    sleep 2
done

# Update Bun in VM
echo "🎯 Updating Bun to $NEW_VERSION..."
sshpass -p "admin" ssh -o StrictHostKeyChecking=no admin@"$VM_IP" "
    echo 'Updating Bun...'
    export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH
    
    # Install specific Bun version
    curl -fsSL https://bun.sh/install | bash -s -- bun-v${NEW_VERSION}
    
    # Verify
    ~/.bun/bin/bun --version
    
    # Update system-wide symlink
    sudo ln -sf ~/.bun/bin/bun /opt/homebrew/bin/bun 2>/dev/null || sudo ln -sf ~/.bun/bin/bun /usr/local/bin/bun
    
    echo 'Bun update complete!'
"

# Stop VM
echo "🛑 Stopping VM..."
sshpass -p "admin" ssh -o StrictHostKeyChecking=no admin@"$VM_IP" "sudo shutdown -h now" || true
sleep 3
kill $VM_PID 2>/dev/null || true

echo "✅ VM updated successfully: $NEW_VM"

# Ask before deleting old VM
echo ""
echo "🗑️  Delete old VM? ($OLD_VM)"
echo "   This will free up ~70GB of space"
read -p "Delete old VM? [y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Deleting $OLD_VM..."
    tart delete "$OLD_VM"
    echo "✅ Old VM deleted"
else
    echo "⚠️  Keeping old VM (delete manually later with: tart delete $OLD_VM)"
fi

echo ""
echo "🎉 VM update complete!"
echo "Updated VM: $NEW_VM"
echo ""
echo "To use the new VM, update your CI scripts to look for version $NEW_VERSION" 