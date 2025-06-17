#!/bin/bash
set -euo pipefail

# Test Grafana configuration for Buildkite CI
# This script validates environment variables and connectivity without installing anything

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "🧪 Testing Grafana configuration..."

# Check required environment variables
REQUIRED_VARS=(
    "GRAFANA_CLOUD_USERNAME"
    "GRAFANA_CLOUD_API_KEY"
    "GRAFANA_PROMETHEUS_URL"
    "GRAFANA_LOKI_URL"
)

missing_vars=()
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        missing_vars+=("$var")
        log "❌ Missing: $var"
    else
        # Show first 8 chars for secrets, full value for URLs
        if [[ "$var" == *"API_KEY"* ]]; then
            log "✅ Found: $var = ${!var:0:8}... (${#!var} chars)"
        else
            log "✅ Found: $var = ${!var}"
        fi
    fi
done

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    log ""
    log "❌ Missing ${#missing_vars[@]} required environment variables:"
    printf '   - %s\n' "${missing_vars[@]}"
    log ""
    log "📋 To fix this:"
    log "   1. Set these as Buildkite secrets in your pipeline settings"
    log "   2. Or export them locally for testing:"
    log ""
    for var in "${missing_vars[@]}"; do
        log "      export $var=\"your-value-here\""
    done
    log ""
    exit 1
fi

log "✅ All required environment variables found"

# Test network connectivity (basic checks)
log ""
log "🌐 Testing network connectivity..."

if curl -s --connect-timeout 5 https://grafana.com > /dev/null; then
    log "✅ Can reach grafana.com"
else
    log "⚠️  Cannot reach grafana.com (check network/firewall)"
fi

# Test Prometheus endpoint format
if [[ "$GRAFANA_PROMETHEUS_URL" =~ ^https://prometheus-.*\.grafana\.net/api/prom/push$ ]]; then
    log "✅ Prometheus URL format looks correct"
else
    log "⚠️  Prometheus URL format may be incorrect"
    log "   Expected: https://prometheus-prod-XX-XXX.grafana.net/api/prom/push"
    log "   Got: $GRAFANA_PROMETHEUS_URL"
fi

# Test Loki endpoint format  
if [[ "$GRAFANA_LOKI_URL" =~ ^https://logs-.*\.grafana\.net/loki/api/v1/push$ ]]; then
    log "✅ Loki URL format looks correct"
else
    log "⚠️  Loki URL format may be incorrect"
    log "   Expected: https://logs-prod-XXX.grafana.net/loki/api/v1/push"
    log "   Got: $GRAFANA_LOKI_URL"
fi

# Test authentication (dry run)
log ""
log "🔐 Testing authentication (dry run)..."

auth_test=$(curl -s -w "%{http_code}" \
    -u "$GRAFANA_CLOUD_USERNAME:$GRAFANA_CLOUD_API_KEY" \
    -H "Content-Type: application/x-protobuf" \
    -H "X-Prometheus-Remote-Write-Version: 0.1.0" \
    --data-binary @/dev/null \
    "$GRAFANA_PROMETHEUS_URL" \
    -o /dev/null 2>/dev/null || echo "000")

case "$auth_test" in
    "200"|"204")
        log "✅ Authentication successful (HTTP $auth_test)"
        ;;
    "401"|"403")
        log "❌ Authentication failed (HTTP $auth_test)"
        log "   Check your GRAFANA_CLOUD_USERNAME and GRAFANA_CLOUD_API_KEY"
        ;;
    "000")
        log "⚠️  Network error during authentication test"
        log "   Check network connectivity and firewall settings"
        ;;
    *)
        log "⚠️  Unexpected response during authentication test (HTTP $auth_test)"
        ;;
esac

# Check if this is a Buildkite environment
log ""
log "🏗️  Environment info:"
if [[ -n "${BUILDKITE:-}" ]]; then
    log "✅ Running in Buildkite environment"
    log "   Build ID: ${BUILDKITE_BUILD_ID:-unknown}"
    log "   Pipeline: ${BUILDKITE_PIPELINE_SLUG:-unknown}"
    log "   Agent: ${BUILDKITE_AGENT_NAME:-unknown}"
else
    log "ℹ️  Not running in Buildkite (local test)"
fi

# Machine info
MACHINE_UUID=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}' 2>/dev/null || echo "unknown")
MACHINE_ARCH=$(uname -m)
log "   Machine: $(hostname -s)-${MACHINE_UUID:0:8} ($MACHINE_ARCH)"

log ""
log "✅ Configuration test complete!"
log ""
log "🚀 Next steps:"
log "   1. If all tests passed, run: ./scripts/setup-grafana-monitoring.sh"
log "   2. Or add the monitoring step to your Buildkite pipeline"
log "   3. Import the Grafana dashboards from grafana-cloud-setup.md" 