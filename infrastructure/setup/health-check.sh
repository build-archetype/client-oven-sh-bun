#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function to print status messages
log() {
    echo -e "${GREEN}[health-check]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

check_buildkite() {
    log "Checking Buildkite Agent..."
    if buildkite-agent status &>/dev/null; then
        log "✅ Agent connected and running"
        log "Tags: $(buildkite-agent status --format '{{.Tags}}')"
        return 0
    else
        error "❌ Agent not running or not connected"
        return 1
    fi
}

check_tart() {
    log "Checking Tart VMs..."
    if ! command -v tart &>/dev/null; then
        error "❌ Tart not installed"
        return 1
    fi

    log "✅ Tart installed"
    log "Running VMs: $(tart list --running | wc -l | xargs)"
    log "Available images: $(tart list | wc -l | xargs)"
    return 0
}

check_monitoring() {
    local has_error=0
    log "Checking monitoring stack..."

    # Check Prometheus
    if curl -s http://localhost:9090/-/healthy &>/dev/null; then
        log "✅ Prometheus running"
    else
        error "❌ Prometheus not running"
        has_error=1
    fi

    # Check Grafana
    if curl -s http://localhost:3000/api/health &>/dev/null; then
        log "✅ Grafana running"
    else
        error "❌ Grafana not running"
        has_error=1
    fi

    return $has_error
}

check_network() {
    local has_error=0
    log "Checking network..."

    # Check VLANs
    if ifconfig | grep -q "vlan1"; then
        log "✅ Build VLAN configured"
    else
        warn "⚠️ Build VLAN not found"
        has_error=1
    fi

    # Check internet connectivity
    if ping -c 1 buildkite.com &>/dev/null; then
        log "✅ Internet connectivity OK"
    else
        error "❌ No internet connectivity"
        has_error=1
    fi

    return $has_error
}

check_storage() {
    log "Checking storage..."
    
    # Check Tart images directory
    if [ -d "/opt/tart/images" ]; then
        log "✅ Tart images directory exists"
        log "Space available: $(df -h /opt/tart/images | awk 'NR==2 {print $4}')"
    else
        error "❌ Tart images directory missing"
        return 1
    fi

    # Check build directories
    if [ -d "/opt/buildkite-agent/builds" ]; then
        log "✅ Build directory exists"
    else
        error "❌ Build directory missing"
        return 1
    fi

    return 0
}

main() {
    local exit_code=0
    
    log "Starting health check..."
    echo

    check_buildkite || exit_code=1
    echo
    
    check_tart || exit_code=1
    echo
    
    check_monitoring || exit_code=1
    echo
    
    check_network || exit_code=1
    echo
    
    check_storage || exit_code=1
    echo

    if [ $exit_code -eq 0 ]; then
        log "✅ All systems operational!"
    else
        error "❌ Some checks failed. Please review the output above."
    fi

    return $exit_code
}

main "$@"
