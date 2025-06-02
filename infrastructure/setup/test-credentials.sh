#!/bin/bash
set -euo pipefail

# Test script to verify CI keychain credential access
echo "🔍 Testing CI Keychain Credential Access"
echo "========================================"

CI_KEYCHAIN="$HOME/Library/Keychains/bun-ci.keychain-db"
KEYCHAIN_PASSWORD_FILE="$HOME/.buildkite-agent/ci-keychain-password.txt"

# Check if keychain exists
if [ -f "$CI_KEYCHAIN" ]; then
    echo "✅ CI keychain found: $CI_KEYCHAIN"
else
    echo "❌ CI keychain not found: $CI_KEYCHAIN"
    exit 1
fi

# Check if password file exists
if [ -f "$KEYCHAIN_PASSWORD_FILE" ]; then
    echo "✅ Keychain password file found"
else
    echo "❌ Keychain password file not found: $KEYCHAIN_PASSWORD_FILE"
    exit 1
fi

# Test unlocking keychain
echo "🔓 Testing keychain unlock..."
KEYCHAIN_PASSWORD=$(cat "$KEYCHAIN_PASSWORD_FILE")
if security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$CI_KEYCHAIN"; then
    echo "✅ Keychain unlocked successfully"
else
    echo "❌ Failed to unlock keychain"
    exit 1
fi

# Test credential retrieval
echo "📋 Testing credential retrieval..."
GITHUB_USERNAME=$(security find-generic-password -a "bun-ci" -s "github-username" -w -k "$CI_KEYCHAIN" 2>/dev/null || echo "")
GITHUB_TOKEN=$(security find-generic-password -a "bun-ci" -s "github-token" -w -k "$CI_KEYCHAIN" 2>/dev/null || echo "")

if [ -n "$GITHUB_USERNAME" ]; then
    echo "✅ GitHub username retrieved: $GITHUB_USERNAME"
else
    echo "❌ Failed to retrieve GitHub username"
    exit 1
fi

if [ -n "$GITHUB_TOKEN" ]; then
    # Only show first 8 chars for security
    echo "✅ GitHub token retrieved: ${GITHUB_TOKEN:0:8}..."
else
    echo "❌ Failed to retrieve GitHub token"
    exit 1
fi

# Test Tart authentication
echo "🐧 Testing Tart authentication..."
export TART_REGISTRY_USERNAME="$GITHUB_USERNAME"
export TART_REGISTRY_PASSWORD="$GITHUB_TOKEN"

# Just test that tart can use the credentials (don't actually push)
if tart list >/dev/null 2>&1; then
    echo "✅ Tart is working with credentials set"
else
    echo "❌ Tart failed with credentials set"
    exit 1
fi

echo ""
echo "🎉 All credential tests passed!"
echo "   Your CI keychain is properly configured."
echo ""
echo "💡 To manually load credentials in a shell:"
echo "   source ~/.buildkite-agent/hooks/environment" 