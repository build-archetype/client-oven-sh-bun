#!/bin/bash
set -euo pipefail

# Agent VM Health Check Script
# This script should be run periodically by each Buildkite agent
# to update its meta-data based on VM image availability

# Configuration
REQUIRED_BOOTSTRAP_VERSION="3.6"
BUN_VERSION="${BUN_VERSION:-1.2.16}"
MACOS_RELEASE="${MACOS_RELEASE:-14}"  # Can be overridden per agent

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [VM-HEALTH] $1"
}

# Function to check if VM image exists locally
check_vm_image_exists() {
    local image_name="$1"
    tart list 2>/dev/null | grep -q "^local.*${image_name}"
}

# Function to get bootstrap version from local script
get_local_bootstrap_version() {
    local bootstrap_file="scripts/bootstrap-macos.sh"
    if [ -f "$bootstrap_file" ]; then
        grep -m1 "^# Version:" "$bootstrap_file" | sed 's/^# Version: *\([0-9.]*\).*/\1/' || echo "unknown"
    else
        echo "unknown"
    fi
}

# Function to get Bun version
get_bun_version() {
    local version=""
    
    # Try package.json first
    if [ -f "package.json" ]; then
        version=$(jq -r '.version // empty' package.json 2>/dev/null || true)
    fi
    
    # Fallback to git
    if [ -z "$version" ]; then
        version=$(git describe --tags --always 2>/dev/null | sed 's/^bun-v//' | sed 's/^v//' || echo "1.2.16")
    fi
    
    # Clean up version
    version=${version#v}
    version=${version#bun-}
    
    # Validate format
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        version="1.2.16"
    fi
    
    echo "$version"
}

# Function to update agent meta-data
update_agent_metadata() {
    local vm_ready="$1"
    local vm_image="$2"
    local bootstrap_version="$3"
    local bun_version="$4"
    local reason="$5"
    
    log "Updating agent meta-data:"
    log "  vm-ready: $vm_ready"
    log "  vm-image: $vm_image"
    log "  vm-bootstrap-version: $bootstrap_version"
    log "  vm-bun-version: $bun_version"
    log "  vm-status-reason: $reason"
    
    # Update meta-data (suppress errors to avoid breaking agent)
    buildkite-agent meta-data set "vm-ready" "$vm_ready" 2>/dev/null || true
    buildkite-agent meta-data set "vm-image" "$vm_image" 2>/dev/null || true
    buildkite-agent meta-data set "vm-bootstrap-version" "$bootstrap_version" 2>/dev/null || true
    buildkite-agent meta-data set "vm-bun-version" "$bun_version" 2>/dev/null || true
    buildkite-agent meta-data set "vm-status-reason" "$reason" 2>/dev/null || true
    buildkite-agent meta-data set "vm-last-check" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
}

# Function to check VM health
check_vm_health() {
    log "=== VM HEALTH CHECK ==="
    
    # Get current versions
    local current_bun_version=$(get_bun_version)
    local current_bootstrap_version=$(get_local_bootstrap_version)
    
    log "Detected versions:"
    log "  Bun: $current_bun_version"
    log "  Bootstrap: $current_bootstrap_version"
    log "  Required Bootstrap: $REQUIRED_BOOTSTRAP_VERSION"
    log "  macOS Release: $MACOS_RELEASE"
    
    # Construct expected image name
    local expected_image="bun-build-macos-${MACOS_RELEASE}-${current_bun_version}-bootstrap-${current_bootstrap_version}"
    
    log "Expected VM image: $expected_image"
    
    # Check if image exists
    if check_vm_image_exists "$expected_image"; then
        # Check if bootstrap version matches requirement
        if [ "$current_bootstrap_version" = "$REQUIRED_BOOTSTRAP_VERSION" ]; then
            log "✅ VM READY: Image exists with correct bootstrap version"
            update_agent_metadata "true" "$expected_image" "$current_bootstrap_version" "$current_bun_version" "VM image available with correct bootstrap version"
            return 0
        else
            log "⚠️  VM NOT READY: Bootstrap version mismatch (have: $current_bootstrap_version, need: $REQUIRED_BOOTSTRAP_VERSION)"
            update_agent_metadata "false" "$expected_image" "$current_bootstrap_version" "$current_bun_version" "Bootstrap version mismatch"
            return 1
        fi
    else
        log "❌ VM NOT READY: Image not found locally"
        update_agent_metadata "false" "$expected_image" "$current_bootstrap_version" "$current_bun_version" "VM image not found locally"
        return 1
    fi
}

# Function to show agent status
show_agent_status() {
    log "=== AGENT STATUS ==="
    log "Agent meta-data:"
    buildkite-agent meta-data get "vm-ready" 2>/dev/null || echo "vm-ready: <not set>"
    buildkite-agent meta-data get "vm-image" 2>/dev/null || echo "vm-image: <not set>"
    buildkite-agent meta-data get "vm-bootstrap-version" 2>/dev/null || echo "vm-bootstrap-version: <not set>"
    buildkite-agent meta-data get "vm-status-reason" 2>/dev/null || echo "vm-status-reason: <not set>"
    buildkite-agent meta-data get "vm-last-check" 2>/dev/null || echo "vm-last-check: <not set>"
    log "=================="
}

# Main execution
main() {
    case "${1:-check}" in
        "check")
            check_vm_health
            ;;
        "status")
            show_agent_status
            ;;
        "force-ready")
            # Force agent to ready state (for testing)
            local bun_version=$(get_bun_version)
            local bootstrap_version=$(get_local_bootstrap_version)
            local image="bun-build-macos-${MACOS_RELEASE}-${bun_version}-bootstrap-${bootstrap_version}"
            update_agent_metadata "true" "$image" "$bootstrap_version" "$bun_version" "Forced ready by admin"
            log "Agent forced to ready state"
            ;;
        "force-not-ready")
            # Force agent to not-ready state (for testing)
            local bun_version=$(get_bun_version)
            local bootstrap_version=$(get_local_bootstrap_version)
            local image="bun-build-macos-${MACOS_RELEASE}-${bun_version}-bootstrap-${bootstrap_version}"
            update_agent_metadata "false" "$image" "$bootstrap_version" "$bun_version" "Forced not-ready by admin"
            log "Agent forced to not-ready state"
            ;;
        *)
            echo "Usage: $0 [check|status|force-ready|force-not-ready]"
            echo ""
            echo "Commands:"
            echo "  check         Check VM health and update meta-data (default)"
            echo "  status        Show current agent meta-data"
            echo "  force-ready   Force agent to ready state"
            echo "  force-not-ready Force agent to not-ready state"
            exit 1
            ;;
    esac
}

main "$@" 