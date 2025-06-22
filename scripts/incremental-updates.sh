#!/bin/bash

# Incremental VM Update Scripts
# 
# This file contains functions for safe incremental updates between bootstrap versions.
# Each function handles a specific version transition.
# 
# Usage: source this file and call the appropriate update function
# 
# Function naming: update_X_Y_to_A_B() where X.Y -> A.B
# Example: update_3_6_to_3_7() handles bootstrap 3.6 -> 3.7 transition

# =============================================================================
# Bootstrap 3.6 -> 3.7: Add tool symlinks for lifecycle scripts
# =============================================================================
update_3_6_to_3_7() {
    echo "🔧 Incremental Update: Bootstrap 3.6 -> 3.7"
    echo "   Adding tool symlinks for lifecycle script execution"
    echo ""
    
    # Ensure /usr/local/bin exists
    echo "📁 Ensuring /usr/local/bin directory exists..."
    sudo mkdir -p /usr/local/bin
    
    # Create symlinks (idempotent operations)
    echo "🔗 Creating tool symlinks..."
    
    if command -v node >/dev/null 2>&1; then
        local node_path="$(command -v node)"
        sudo ln -sf "$node_path" /usr/local/bin/node
        echo "✅ Node symlink: $node_path -> /usr/local/bin/node"
    else
        echo "⚠️  Node not found - skipping symlink"
    fi
    
    if command -v npm >/dev/null 2>&1; then
        local npm_path="$(command -v npm)"
        sudo ln -sf "$npm_path" /usr/local/bin/npm  
        echo "✅ NPM symlink: $npm_path -> /usr/local/bin/npm"
    else
        echo "⚠️  NPM not found - skipping symlink"
    fi
    
    if command -v bun >/dev/null 2>&1; then
        local bun_path="$(command -v bun)"
        sudo ln -sf "$bun_path" /usr/local/bin/bun
        echo "✅ Bun symlink: $bun_path -> /usr/local/bin/bun"
    else
        echo "⚠️  Bun not found - skipping symlink"
    fi
    
    # Verify symlinks were created
    echo ""
    echo "🔍 Verification:"
    echo "   /usr/local/bin/node: $([ -L /usr/local/bin/node ] && echo "✅ exists" || echo "❌ missing")"
    echo "   /usr/local/bin/npm:  $([ -L /usr/local/bin/npm ] && echo "✅ exists" || echo "❌ missing")"
    echo "   /usr/local/bin/bun:  $([ -L /usr/local/bin/bun ] && echo "✅ exists" || echo "❌ missing")"
    
    echo ""
    echo "✅ Bootstrap 3.6 -> 3.7 incremental update completed"
    echo "   Tool symlinks created for reliable lifecycle script execution"
    
    return 0
}

# =============================================================================
# Template for future updates - remove when no longer needed
# =============================================================================

# update_3_7_to_3_8() {
#     echo "🔧 Incremental Update: Bootstrap 3.7 -> 3.8"
#     echo "   Description of changes..."
#     
#     # Your incremental update logic here
#     
#     echo "✅ Bootstrap 3.7 -> 3.8 incremental update completed"
#     return 0
# }

# =============================================================================
# Helper Functions
# =============================================================================

# Get available update functions
list_available_updates() {
    echo "Available incremental updates:"
    declare -F | grep "update_" | sed 's/declare -f /  /' | sort
}

# Check if a specific update function exists
has_update_function() {
    local from_version="$1"
    local to_version="$2"
    
    # Convert dots to underscores for function name
    local func_name="update_${from_version//./_}_to_${to_version//./_}"
    
    if declare -F "$func_name" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Execute a specific update function
execute_update() {
    local from_version="$1"
    local to_version="$2"
    
    # Convert dots to underscores for function name
    local func_name="update_${from_version//./_}_to_${to_version//./_}"
    
    if has_update_function "$from_version" "$to_version"; then
        echo "🚀 Executing: $func_name"
        "$func_name"
        return $?
    else
        echo "❌ No incremental update function found: $func_name"
        return 1
    fi
} 