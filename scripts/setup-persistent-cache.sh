#!/bin/bash
set -euo pipefail

# Simple persistent cache setup - no artifacts, no network, no overhead!
CACHE_BASE="${BUILDKITE_CACHE_BASE:-/opt/buildkite-cache}"

echo "🔧 Setting up persistent cache directories..."

# Create persistent cache directories
mkdir -p "${CACHE_BASE}"/{zig/global,zig/local,ccache,npm}

# Set up environment variables
export ZIG_GLOBAL_CACHE_DIR="${CACHE_BASE}/zig/global"
export ZIG_LOCAL_CACHE_DIR="${CACHE_BASE}/zig/local"
export CCACHE_DIR="${CACHE_BASE}/ccache"
export NPM_CONFIG_CACHE="${CACHE_BASE}/npm"

# Set permissions for multi-user access (if needed)
chmod -R 755 "${CACHE_BASE}" 2>/dev/null || true

echo "✅ Persistent cache ready:"
echo "   ZIG_GLOBAL_CACHE_DIR=${ZIG_GLOBAL_CACHE_DIR}"
echo "   ZIG_LOCAL_CACHE_DIR=${ZIG_LOCAL_CACHE_DIR}"
echo "   CCACHE_DIR=${CCACHE_DIR}"
echo "   NPM_CONFIG_CACHE=${NPM_CONFIG_CACHE}"

# Show current cache sizes
echo ""
echo "📊 Current cache usage:"
du -sh "${CACHE_BASE}"/* 2>/dev/null || echo "   Cache is empty" 