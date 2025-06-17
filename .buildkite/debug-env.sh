#!/bin/bash

echo "🔍 Debugging Buildkite environment variables..."
echo ""
echo "=== GRAFANA-related environment variables ==="
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
echo "🔍 Debug complete" 