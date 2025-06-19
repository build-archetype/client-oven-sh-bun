#!/bin/bash
set -e

# VM Migration Script
# Migrates from old rigid naming to clean professional naming

TART_PATH="/opt/homebrew/bin/tart"

echo "🔄 VM Migration to Professional Naming"
echo "======================================"

# Function to find the best VM for each macOS version
find_best_vm_for_macos() {
    local macos_version="$1"
    
    # Get all VMs for this macOS version, sorted by Bun version (newest first)
    $TART_PATH list | grep "bun-build-macos-${macos_version}-" | \
        awk '{print $2}' | \
        sort -V -r | \
        head -1
}

# Migrate VMs
echo "🔍 Analyzing current VMs..."
echo ""

# Find macOS versions
macos_versions=($($TART_PATH list | grep -o "bun-build-macos-[0-9]\+" | sed 's/bun-build-macos-//' | sort -u))

if [ ${#macos_versions[@]} -eq 0 ]; then
    echo "❌ No bun-build VMs found to migrate"
    exit 1
fi

echo "📋 Found macOS versions: ${macos_versions[*]}"
echo ""

for macos_ver in "${macos_versions[@]}"; do
    echo "🔄 Processing macOS $macos_ver..."
    
    # Find the best VM (highest Bun version)
    best_vm=$(find_best_vm_for_macos "$macos_ver")
    target_name="bun-build-macos-${macos_ver}-latest"
    
    if [ -z "$best_vm" ]; then
        echo "  ❌ No VMs found for macOS $macos_ver"
        continue
    fi
    
    echo "  Best VM: $best_vm"
    echo "  Target:  $target_name"
    
    if [ "$best_vm" == "$target_name" ]; then
        echo "  ✅ Already correctly named"
    else
        # Check if target already exists
        if $TART_PATH list | grep -q "$target_name"; then
            echo "  ⚠️  Target name already exists"
            echo "     You may want to manually resolve this:"
            echo "     tart delete $target_name  # if you want to replace it"
            echo "     tart rename $best_vm $target_name"
        else
            echo "  🏷️  Renaming: $best_vm → $target_name"
            $TART_PATH rename "$best_vm" "$target_name" || echo "     ❌ Rename failed"
        fi
    fi
    
    echo ""
done

echo "🎉 Migration complete!"
echo ""
echo "💡 Next steps:"
echo "1. Run this on all 3 machines"
echo "2. Delete old/unused VMs to save space"
echo "3. Use the new smart-vm-manager.sh for updates"
echo ""
echo "Current VMs:"
$TART_PATH list | grep bun-build 