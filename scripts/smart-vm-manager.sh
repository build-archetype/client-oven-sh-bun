#!/bin/bash
set -e

# Professional VM Management System
# Automatically detects version drift and updates VMs gracefully

TART_PATH="/opt/homebrew/bin/tart"
MACHINE_ID=$(hostname)

echo "🏗️  Professional VM Manager - $MACHINE_ID"
echo "=================================================="

# Get target Bun version (from project, CI env, or latest)
get_target_version() {
    # Priority: 1) CI env var, 2) project bunfig, 3) latest stable
    if [ -n "$TARGET_BUN_VERSION" ]; then
        echo "$TARGET_BUN_VERSION"
    elif [ -f "/Users/mac-ci/workspace/.bunfig.toml" ]; then
        # Extract version from bunfig if it exists
        grep -o 'bun-version.*=.*"[^"]*"' /Users/mac-ci/workspace/.bunfig.toml 2>/dev/null | cut -d'"' -f2 || echo "1.2.16"
    else
        echo "1.2.16"  # Default to current stable
    fi
}

# Check what Bun version is installed in a VM
get_vm_bun_version() {
    local vm_name="$1"
    local vm_ip="$2"
    
    sshpass -p "admin" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no admin@"$vm_ip" \
        "bun --version 2>/dev/null || ~/.bun/bin/bun --version 2>/dev/null || echo 'unknown'" 2>/dev/null
}

# Get current production VMs
get_production_vms() {
    $TART_PATH list | grep -E "bun-build-macos-[0-9]+-latest" | awk '{print $2}' || true
}

# Check if VM needs update
check_vm_status() {
    local vm_name="$1"
    local target_version="$2"
    
    echo "📊 Checking VM: $vm_name"
    
    # Start VM temporarily to check version
    $TART_PATH run "$vm_name" --no-graphics &
    local vm_pid=$!
    sleep 5
    
    # Get IP
    local vm_ip=""
    for i in {1..10}; do
        vm_ip=$($TART_PATH ip "$vm_name" 2>/dev/null || echo "")
        if [ -n "$vm_ip" ]; then
            break
        fi
        sleep 2
    done
    
    if [ -n "$vm_ip" ]; then
        # Wait for SSH
        for i in {1..15}; do
            if sshpass -p "admin" ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no admin@"$vm_ip" "echo test" >/dev/null 2>&1; then
                break
            fi
            sleep 2
        done
        
        # Check version
        local current_version=$(get_vm_bun_version "$vm_name" "$vm_ip")
        
        # Stop VM
        sshpass -p "admin" ssh -o StrictHostKeyChecking=no admin@"$vm_ip" "sudo shutdown -h now" >/dev/null 2>&1 || true
        sleep 2
        kill $vm_pid >/dev/null 2>&1 || true
        
        echo "  Current: $current_version | Target: $target_version"
        
        if [[ "$current_version" == "$target_version"* ]]; then
            echo "  ✅ UP TO DATE"
            return 0
        else
            echo "  🔄 NEEDS UPDATE"
            return 1
        fi
    else
        kill $vm_pid >/dev/null 2>&1 || true
        echo "  ❌ Cannot check (VM network issue)"
        return 1
    fi
}

# Update VM in-place
update_vm() {
    local vm_name="$1"
    local target_version="$2"
    
    echo "🔄 Updating VM: $vm_name → $target_version"
    
    # Start VM
    $TART_PATH run "$vm_name" --no-graphics &
    local vm_pid=$!
    sleep 5
    
    # Get IP and wait for SSH (same logic as before)
    local vm_ip=""
    for i in {1..15}; do
        vm_ip=$($TART_PATH ip "$vm_name" 2>/dev/null || echo "")
        if [ -n "$vm_ip" ]; then
            # Wait for SSH
            local ssh_ready=false
            for j in {1..20}; do
                if sshpass -p "admin" ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no admin@"$vm_ip" "echo test" >/dev/null 2>&1; then
                    ssh_ready=true
                    break
                fi
                sleep 2
            done
            
            if [ "$ssh_ready" = true ]; then
                break
            fi
        fi
        sleep 2
    done
    
    if [ -z "$vm_ip" ]; then
        echo "  ❌ Failed to get VM IP"
        kill $vm_pid >/dev/null 2>&1 || true
        return 1
    fi
    
    # Perform update
    echo "  📦 Installing Bun $target_version..."
    local update_success=false
    
    if sshpass -p "admin" ssh -o StrictHostKeyChecking=no admin@"$vm_ip" "
        export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH
        
        # Install Bun
        curl -fsSL https://bun.sh/install | bash -s -- bun-v${target_version} && \\
        ~/.bun/bin/bun --version | grep -q '${target_version}' && \\
        sudo ln -sf ~/.bun/bin/bun /opt/homebrew/bin/bun && \\
        sudo ln -sf ~/.bun/bin/bunx /opt/homebrew/bin/bunx && \\
        echo 'Bun update successful'
    "; then
        update_success=true
    fi
    
    # Stop VM
    sshpass -p "admin" ssh -o StrictHostKeyChecking=no admin@"$vm_ip" "sudo shutdown -h now" >/dev/null 2>&1 || true
    sleep 3
    kill $vm_pid >/dev/null 2>&1 || true
    
    if [ "$update_success" = true ]; then
        echo "  ✅ Successfully updated $vm_name"
        return 0
    else
        echo "  ❌ Failed to update $vm_name"
        return 1
    fi
}

# Main logic
main() {
    local target_version=$(get_target_version)
    echo "🎯 Target Bun version: $target_version"
    echo ""
    
    # Get production VMs
    local vms=($(get_production_vms))
    
    if [ ${#vms[@]} -eq 0 ]; then
        echo "❌ No production VMs found (looking for *-latest pattern)"
        echo "Current VMs:"
        $TART_PATH list
        exit 1
    fi
    
    echo "📋 Production VMs found: ${#vms[@]}"
    for vm in "${vms[@]}"; do
        echo "  - $vm"
    done
    echo ""
    
    # Check and update each VM
    local updated_count=0
    local failed_count=0
    
    for vm_name in "${vms[@]}"; do
        if check_vm_status "$vm_name" "$target_version"; then
            echo "  ⏭️  Skipping (already up to date)"
        else
            if update_vm "$vm_name" "$target_version"; then
                ((updated_count++))
            else
                ((failed_count++))
            fi
        fi
        echo ""
    done
    
    # Summary
    echo "🎉 VM Update Summary"
    echo "=================="
    echo "Updated: $updated_count"
    echo "Failed:  $failed_count"
    echo "Total:   ${#vms[@]}"
    
    if [ $failed_count -gt 0 ]; then
        echo ""
        echo "⚠️  Some VMs failed to update, but builds can continue"
        echo "   Consider manual investigation during maintenance window"
        exit 1
    else
        echo ""
        echo "✅ All VMs are up to date!"
        exit 0
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 