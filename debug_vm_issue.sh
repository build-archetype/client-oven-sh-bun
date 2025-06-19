#!/bin/bash
set -euo pipefail

echo "=== VM CLONING DEBUG SCRIPT ==="
echo "Current user: $(whoami)"
echo "Current directory: $(pwd)"
echo "Tart directory: $HOME/.tart"
echo ""

echo "=== CHECKING BASE VM ==="
VM_NAME="bun-build-macos-13-arm64-1.2.16-bootstrap-13"
VM_PATH="$HOME/.tart/vms/$VM_NAME"

echo "VM Name: $VM_NAME"
echo "VM Path: $VM_PATH"
echo ""

if [ -d "$VM_PATH" ]; then
    echo "✅ VM directory exists"
    echo "Directory contents:"
    ls -la "$VM_PATH"
    echo ""
    
    echo "Config.json status:"
    if [ -f "$VM_PATH/config.json" ]; then
        echo "✅ config.json exists"
        echo "File size: $(stat -f%z "$VM_PATH/config.json") bytes"
        echo "File permissions: $(stat -f%Sp "$VM_PATH/config.json")"
        echo "File owner: $(stat -f%Su "$VM_PATH/config.json")"
        echo ""
        echo "Config.json content (first 200 chars):"
        head -c 200 "$VM_PATH/config.json" || echo "Failed to read config.json"
        echo ""
        echo "JSON validation:"
        if jq . "$VM_PATH/config.json" >/dev/null 2>&1; then
            echo "✅ Valid JSON"
        else
            echo "❌ Invalid JSON"
            echo "JSON errors:"
            jq . "$VM_PATH/config.json" 2>&1 || true
        fi
    else
        echo "❌ config.json does NOT exist"
    fi
    echo ""
    
    echo "Disk.img status:"
    if [ -f "$VM_PATH/disk.img" ]; then
        echo "✅ disk.img exists"
        echo "File size: $(stat -f%z "$VM_PATH/disk.img") bytes"
        echo "File permissions: $(stat -f%Sp "$VM_PATH/disk.img")"
        echo "File owner: $(stat -f%Su "$VM_PATH/disk.img")"
    else
        echo "❌ disk.img does NOT exist"
    fi
else
    echo "❌ VM directory does NOT exist: $VM_PATH"
fi

echo ""
echo "=== TART STATUS ==="
echo "Tart list:"
tart list
echo ""

echo "=== ATTEMPTING MANUAL CLONE ==="
TEST_VM_NAME="test-clone-$(date +%s)"
echo "Testing clone: $VM_NAME -> $TEST_VM_NAME"

if tart clone "$VM_NAME" "$TEST_VM_NAME" 2>&1; then
    echo "✅ Manual clone succeeded!"
    echo "Cleaning up test VM..."
    tart delete "$TEST_VM_NAME" >/dev/null 2>&1 || true
else
    echo "❌ Manual clone failed with same error"
fi

echo ""
echo "=== CHECKING DISK SPACE ==="
df -h "$HOME/.tart"

echo ""
echo "=== CHECKING PERMISSIONS ==="
echo "Tart directory permissions:"
ls -la "$HOME/.tart"
echo ""
echo "VMs directory permissions:"
ls -la "$HOME/.tart/vms"

echo ""
echo "=== RACE CONDITION TEST ==="
echo "Testing if VM is still running/locked..."
if tart list | grep "$VM_NAME" | grep -q "running"; then
    echo "⚠️  VM is still running!"
else
    echo "✅ VM is not running"
fi

echo ""
echo "=== PROCESS CHECK ==="
echo "Checking for tart processes..."
ps aux | grep -i tart | grep -v grep || echo "No tart processes found"

echo ""
echo "=== LSOF CHECK ==="
echo "Checking for open files in VM directory..."
lsof +D "$VM_PATH" 2>/dev/null || echo "No open files found (or lsof failed)"

echo ""
echo "=== DEBUG COMPLETE ===" 