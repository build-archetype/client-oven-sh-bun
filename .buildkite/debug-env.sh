#!/bin/bash

echo "🔍 Debugging Buildkite environment variables..."
echo ""
echo "=== Checking exact Grafana secret names ==="
echo "GRAFANA_CLOUD_USERNAME: ${GRAFANA_CLOUD_USERNAME:-❌ NOT SET}"
echo "GRAFANA_CLOUD_API_KEY: ${GRAFANA_CLOUD_API_KEY:0:10}... (${#GRAFANA_CLOUD_API_KEY} chars) ${GRAFANA_CLOUD_API_KEY:+✅ SET}"
echo "GRAFANA_PROMETHEUS_URL: ${GRAFANA_PROMETHEUS_URL:-❌ NOT SET}"
echo "GRAFANA_LOKI_URL: ${GRAFANA_LOKI_URL:-❌ NOT SET}"
echo ""
echo "=== All GRAFANA-related environment variables ==="
env | grep -i grafana | sort
echo ""
echo "=== All environment variables containing 'CLOUD' ==="
env | grep -i cloud | sort
echo ""
echo "=== All environment variables containing 'LOKI' ==="  
env | grep -i loki | sort
echo ""
echo "=== All environment variables containing 'PROMETHEUS' ==="
env | grep -i prometheus | sort
echo ""
echo "=== Buildkite environment ==="
echo "BUILDKITE: ${BUILDKITE:-not set}"
echo "BUILDKITE_BUILD_ID: ${BUILDKITE_BUILD_ID:-not set}"
echo "BUILDKITE_PIPELINE_SLUG: ${BUILDKITE_PIPELINE_SLUG:-not set}"
echo ""
echo "=== Total environment variables ==="
echo "Total env vars: $(env | wc -l)"
echo ""
echo "🔍 Debug complete" 