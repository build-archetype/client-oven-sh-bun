#!/bin/bash
set -euo pipefail

# Agent VM Health Check Script
# This script checks VM image availability for specific macOS versions
# and updates version-specific agent meta-data

# Configuration
REQUIRED_BOOTSTRAP_VERSION="3.6"
BUN_VERSION="${BUN_VERSION:-1.2.16}"
# Check both macOS versions that this agent might support
MACOS_VERSIONS_TO_CHECK="${MACOS_VERSIONS_TO_CHECK:-13 14}"  # Space-separated list

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

# Function to update agent meta-data for specific macOS version
update_agent_metadata_for_version() {
    local macos_version="$1"
    local vm_ready="$2"
    local vm_image="$3"
    local bootstrap_version="$4"
    local bun_version="$5"
    local reason="$6"
    
    local vm_ready_key="vm-ready-macos-${macos_version}"
    
    log "Updating agent meta-data for macOS $macos_version:"
    log "  $vm_ready_key: $vm_ready"
    log "  vm-image-macos-${macos_version}: $vm_image"
    log "  reason: $reason"
    
    # Update meta-data (suppress errors to avoid breaking agent)
    buildkite-agent meta-data set "$vm_ready_key" "$vm_ready" 2>/dev/null || true
    buildkite-agent meta-data set "vm-image-macos-${macos_version}" "$vm_image" 2>/dev/null || true
    buildkite-agent meta-data set "vm-bootstrap-version-macos-${macos_version}" "$bootstrap_version" 2>/dev/null || true
    buildkite-agent meta-data set "vm-bun-version-macos-${macos_version}" "$bun_version" 2>/dev/null || true
    buildkite-agent meta-data set "vm-status-reason-macos-${macos_version}" "$reason" 2>/dev/null || true
    buildkite-agent meta-data set "vm-last-check-macos-${macos_version}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
}

# Function to check VM health for specific macOS version
check_vm_health_for_version() {
    local macos_version="$1"
    
    log "=== VM HEALTH CHECK FOR macOS $macos_version ==="
    
    # Get current versions
    local current_bun_version=$(get_bun_version)
    local current_bootstrap_version=$(get_local_bootstrap_version)
    
    log "Detected versions:"
    log "  Bun: $current_bun_version"
    log "  Bootstrap: $current_bootstrap_version"
    log "  Required Bootstrap: $REQUIRED_BOOTSTRAP_VERSION"
    log "  macOS Release: $macos_version"
    
    # Construct expected image name
    local expected_image="bun-build-macos-${macos_version}-${current_bun_version}-bootstrap-${current_bootstrap_version}"
    
    log "Expected VM image: $expected_image"
    
    # Check if image exists
    if check_vm_image_exists "$expected_image"; then
        # Check if bootstrap version matches requirement
        if [ "$current_bootstrap_version" = "$REQUIRED_BOOTSTRAP_VERSION" ]; then
            log "✅ VM READY: macOS $macos_version image exists with correct bootstrap version"
            update_agent_metadata_for_version "$macos_version" "true" "$expected_image" "$current_bootstrap_version" "$current_bun_version" "VM image available with correct bootstrap version"
            return 0
        else
            log "⚠️  VM NOT READY: macOS $macos_version bootstrap version mismatch (have: $current_bootstrap_version, need: $REQUIRED_BOOTSTRAP_VERSION)"
            update_agent_metadata_for_version "$macos_version" "false" "$expected_image" "$current_bootstrap_version" "$current_bun_version" "Bootstrap version mismatch"
            return 1
        fi
    else
        log "❌ VM NOT READY: macOS $macos_version image not found locally"
        update_agent_metadata_for_version "$macos_version" "false" "$expected_image" "$current_bootstrap_version" "$current_bun_version" "VM image not found locally"
        return 1
    fi
}

# Function to check VM health for all configured versions
check_vm_health() {
    log "=== AGENT VM HEALTH CHECK ==="
    log "Checking macOS versions: $MACOS_VERSIONS_TO_CHECK"
    
    local overall_status=0
    
    for version in $MACOS_VERSIONS_TO_CHECK; do
        if ! check_vm_health_for_version "$version"; then
            overall_status=1
        fi
    done
    
    log "=== HEALTH CHECK COMPLETE ==="
    return $overall_status
}

# Function to show agent status
show_agent_status() {
    log "=== AGENT STATUS ==="
    
    for version in $MACOS_VERSIONS_TO_CHECK; do
        log "macOS $version status:"
        buildkite-agent meta-data get "vm-ready-macos-${version}" 2>/dev/null || echo "  vm-ready-macos-${version}: <not set>"
        buildkite-agent meta-data get "vm-image-macos-${version}" 2>/dev/null || echo "  vm-image-macos-${version}: <not set>"
        buildkite-agent meta-data get "vm-status-reason-macos-${version}" 2>/dev/null || echo "  vm-status-reason-macos-${version}: <not set>"
        buildkite-agent meta-data get "vm-last-check-macos-${version}" 2>/dev/null || echo "  vm-last-check-macos-${version}: <not set>"
        echo ""
    done
    
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
            # Force agent to ready state for all versions (for testing)
            local bun_version=$(get_bun_version)
            local bootstrap_version=$(get_local_bootstrap_version)
            for version in $MACOS_VERSIONS_TO_CHECK; do
                local image="bun-build-macos-${version}-${bun_version}-bootstrap-${bootstrap_version}"
                update_agent_metadata_for_version "$version" "true" "$image" "$bootstrap_version" "$bun_version" "Forced ready by admin"
                log "Agent forced to ready state for macOS $version"
            done
            ;;
        "force-not-ready")
            # Force agent to not-ready state for all versions (for testing)
            local bun_version=$(get_bun_version)
            local bootstrap_version=$(get_local_bootstrap_version)
            for version in $MACOS_VERSIONS_TO_CHECK; do
                local image="bun-build-macos-${version}-${bun_version}-bootstrap-${bootstrap_version}"
                update_agent_metadata_for_version "$version" "false" "$image" "$bootstrap_version" "$bun_version" "Forced not-ready by admin"
                log "Agent forced to not-ready state for macOS $version"
            done
            ;;
        *)
            echo "Usage: $0 [check|status|force-ready|force-not-ready]"
            echo ""
            echo "Commands:"
            echo "  check         Check VM health and update meta-data (default)"
            echo "  status        Show current agent meta-data"
            echo "  force-ready   Force agent to ready state for all versions"
            echo "  force-not-ready Force agent to not-ready state for all versions"
            echo ""
            echo "Environment Variables:"
            echo "  MACOS_VERSIONS_TO_CHECK  Space-separated macOS versions (default: '13 14')"
            echo "  REQUIRED_BOOTSTRAP_VERSION  Required bootstrap version (default: '3.6')"
            exit 1
            ;;
    esac
}

main "$@" 