#!/bin/bash
set -e
set -x

# Add trap to ensure cleanup on exit
cleanup() {
    local exit_code=$?
    if [ -n "$VM_PID" ] && ps -p $VM_PID > /dev/null; then
        log "Cleaning up VM process..."
        kill $VM_PID || true
        wait $VM_PID || true
    fi
    # Always try to capture tart logs on exit
    log "Capturing tart logs..."
    tart list > tart_list.log
    tart info "$IMAGE_NAME" > tart_info.log 2>&1 || true
    if [ $exit_code -ne 0 ]; then
        log "Script failed, capturing additional debug info..."
        system_profiler SPVirtualizationDataType > virtualization_info.log 2>&1 || true
        log show --predicate 'process == "tart"' --last 5m > tart_system_log.log 2>&1 || true
    fi
    # Clean up credentials file
    if [ -f "$CREDS_FILE" ]; then
        rm -f "$CREDS_FILE"
    fi
    exit $exit_code
}
trap cleanup EXIT

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Initial environment diagnostics
log "=== Initial Environment Diagnostics ==="
log "Current user: $(whoami)"
log "Current directory: $(pwd)"
log "Directory contents:"
ls -la

log "=== Tart Environment ==="
log "Tart version:"
tart version || true
log "Tart location:"
which tart || true
log "Tart permissions:"
ls -l $(which tart) || true

log "=== System Information ==="
log "macOS version:"
sw_vers
log "CPU architecture:"
uname -m
log "Virtualization support:"
sysctl kern.hv_support || true

log "=== Tart State ==="
log "Current tart images:"
tart list || true
log "Tart configuration:"
tart config list || true

log "=== Buildkite Environment ==="
log "Buildkite agent version:"
buildkite-agent --version || true
log "Buildkite environment variables:"
env | grep -i buildkite || true

log "=== GitHub Authentication ==="
log "GitHub token present: ${GITHUB_TOKEN:+yes}${GITHUB_TOKEN:-no}"
log "GitHub username: ${GITHUB_USERNAME:-not set}"

log "=== Tart Detailed Diagnostics ==="
log "Tart process status:"
ps aux | grep tart || true
log "Tart directory permissions:"
ls -la ~/.tart || true
log "Tart configuration directory:"
ls -la /etc/tart || true
log "Tart system logs:"
log show --predicate 'process == "tart"' --last 5m || true

log "=== Starting Main Process ==="

# Function to check system resources
check_system_resources() {
    log "Checking system resources..."
    log "CPU Info:"
    sysctl -n machdep.cpu.brand_string || true
    log "CPU Architecture:"
    uname -m || true
    log "macOS Version:"
    sw_vers || true
    log "Memory Info:"
    vm_stat || true
    log "Disk Space:"
    df -h || true
    log "Running VMs:"
    tart list || true
    log "Tart Version:"
    tart version || true
}

# Function to check VM status
check_vm_status() {
    local vm_name="$1"
    log "Checking VM status for $vm_name..."
    tart list | grep "$vm_name" || {
        log "VM $vm_name not found in tart list"
        return 1
    }
    return 0
}

# Function to clean up existing VMs
cleanup_vms() {
    log "Cleaning up any existing VMs..."
    if tart list | grep -q "$IMAGE_NAME"; then
        log "Found existing VM $IMAGE_NAME, deleting it..."
        tart delete "$IMAGE_NAME" || {
            log "Failed to delete existing VM $IMAGE_NAME"
            return 1
        }
        log "Successfully deleted existing VM $IMAGE_NAME"
    else
        log "No existing VM $IMAGE_NAME found"
    fi
}

# Hardcoded image configuration -- update this when we switch to a new base image
IMAGE_NAME="base-bun-build-macos-darwin"
CIRRUS_BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-vanilla:latest"
TARGET_IMAGE="ghcr.io/build-archetype/client-oven-sh-bun/base-bun-build-macos-darwin:latest"

# set the number of retries for the commands
MAX_RETRIES=3

# Print configuration summary
log "=== Configuration Summary ==="
log "Custom Image Name: $IMAGE_NAME"
log "Cirrus Base Image: $CIRRUS_BASE_IMAGE"
log "Target Image: $TARGET_IMAGE"
log "Max Retries: $MAX_RETRIES"
log "GitHub Token: ${GITHUB_TOKEN:+set}${GITHUB_TOKEN:-not set}"
log "==========================="
log "Current working directory: $(pwd)"
log "Directory contents:"
ls -la
log "Directory tree structure:"
log "=== .buildkite/scripts/ ==="
ls -la .buildkite/scripts/
log "=== scripts/ ==="
ls -la scripts/
log "=== .buildkite/ ==="
ls -la .buildkite/
log "==========================="

# Check system resources before starting
check_system_resources

# Clean up any existing VMs before starting
log "Cleaning up any existing VMs before starting..."
if ! cleanup_vms; then
    log "Failed to clean up existing VMs - exiting"
    exit 1
fi

# Function to check if image exists
check_image_exists() {
    local image_name="$1"
    log "Checking if image $image_name exists..."
    log "Current tart images:"
    tart list
    if tart list | grep -q "$image_name"; then
        log "Image $image_name found locally"
        return 0
    else
        log "Image $image_name not found locally"
        return 1
    fi
}

# Function to pull Cirrus base image
pull_cirrus_base() {
    log "Attempting to pull Cirrus base image $CIRRUS_BASE_IMAGE..."
    log "Checking available disk space before pull..."
    df -h
    if tart pull "$CIRRUS_BASE_IMAGE"; then
        log "Successfully pulled Cirrus base image"
        log "Verifying image after pull:"
        tart list
        return 0
    else
        log "Failed to pull Cirrus base image"
        return 1
    fi
}

# Function to clone base image
clone_base_image() {
    log "Cloning Cirrus base image to create our base..."
    log "Starting clone operation (this may take several minutes)..."
    log "Current tart images:"
    tart list

    log "Verifying source image exists..."
    if ! tart list | grep -q "$CIRRUS_BASE_IMAGE"; then
        log "ERROR: Source image $CIRRUS_BASE_IMAGE not found"
        return 1
    fi

    log "Starting clone operation..."
    tart clone "$CIRRUS_BASE_IMAGE" "$IMAGE_NAME"
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log "Clone failed with exit code $exit_code"
        return 1
    fi
    
    log "Clone completed successfully"
    log "Verifying cloned image:"
    tart list | grep "$IMAGE_NAME" || {
        log "ERROR: Cloned image $IMAGE_NAME not found after clone"
        return 1
    }
    return 0
}

# Make run-vm-command.sh executable
log "Making run-vm-command.sh executable..."
chmod +x .buildkite/scripts/run-vm-command.sh

# Function to retry commands
retry_command() {
    local cmd="$1"
    local max_attempts=$MAX_RETRIES
    local attempt=1
    local exitcode=0

    while [ $attempt -le $max_attempts ]; do
        log "Attempt $attempt of $max_attempts: $cmd"
        eval "$cmd"
        exitcode=$?
        if [ $exitcode -eq 0 ]; then
            log "Command succeeded on attempt $attempt"
            break
        fi
        log "Command failed with exit code $exitcode"
        if [ $attempt -lt $max_attempts ]; then
            log "Retrying in 30 seconds..."
            sleep 30
        fi
        attempt=$((attempt + 1))
    done

    if [ $exitcode -ne 0 ]; then
        log "Command failed after $max_attempts attempts"
    fi

    return $exitcode
}

# Initialize success flag
BUILD_SUCCESS=false

# Pull Cirrus base image with retries
log "Starting Cirrus base image pull with retries..."
if ! retry_command "pull_cirrus_base"; then
    log "Failed to pull Cirrus base image after $MAX_RETRIES attempts"
    exit 1
fi

# Clone the base image - no retries, exit on failure
log "Cloning Cirrus base image to create our base..."
if ! clone_base_image; then
    log "Failed to clone base image - exiting"
    exit 1
fi

# Test basic VM functionality
log "Testing basic VM functionality..."
log "Starting test VM run..."
if ! tart run "$IMAGE_NAME" --no-graphics; then
    log "Basic VM test failed - VM may be corrupted"
    exit 1
fi
log "Basic VM test successful, stopping VM..."
tart stop "$IMAGE_NAME" || true

# Start the VM and run bootstrap
log "Starting VM and running bootstrap..."
VM_PID=""

# Validate VM before starting
log "Validating VM before start..."
if ! tart list | grep -q "$IMAGE_NAME.*stopped"; then
    log "ERROR: VM $IMAGE_NAME not found or not in stopped state"
    tart list
    exit 1
fi

# Check VM details
log "VM details:"
tart info "$IMAGE_NAME" || {
    log "ERROR: Failed to get VM info"
    exit 1
}

# Check virtualization status
log "Checking virtualization status..."
if ! sysctl kern.hv_support >/dev/null 2>&1; then
    log "ERROR: Virtualization not supported or not enabled"
    exit 1
fi

log "Starting VM with command: tart run $IMAGE_NAME --no-graphics --dir=workspace:$PWD"
tart run "$IMAGE_NAME" --no-graphics --dir=workspace:"$PWD" 2>vm_error.log &
VM_PID=$!

# Wait for VM to be ready and check its status
log "Waiting for VM to be ready..."
sleep 30  # Initial wait time

# Check if VM is running
if ! ps -p $VM_PID > /dev/null; then
    log "VM process failed to start"
    log "VM error log:"
    cat vm_error.log || true
    log "Checking VM status:"
    check_vm_status "$IMAGE_NAME"
    log "VM process details:"
    ps aux | grep tart || true
    log "System resources at time of failure:"
    check_system_resources
    exit 1
fi

# Run the bootstrap script - no retries, exit on failure
log "Running macOS bootstrap script..."
if ! .buildkite/scripts/run-vm-command.sh "$IMAGE_NAME" "cd /Volumes/My\\ Shared\\ Files/workspace/client-oven-sh-bun && chmod +x scripts/bootstrap-macos.sh && ./scripts/bootstrap-macos.sh"; then
    log "Bootstrap failed - exiting"
    exit 1
fi

# Stop the VM gracefully
log "Stopping VM..."
if [ -n "$VM_PID" ] && ps -p $VM_PID > /dev/null; then
    kill $VM_PID || true
    wait $VM_PID || true
fi

# Only push if everything succeeded
log "All operations completed successfully"
log "Pushing image..."

if [ -n "$GITHUB_TOKEN" ]; then
    # Push the image (authentication is handled by the pipeline)
    log "Pushing image to $TARGET_IMAGE..."
    tart push "$IMAGE_NAME" "$TARGET_IMAGE" || {
        log "Failed to push image"
        exit 1
    }
    log "Bun build image created, updated, and pushed successfully"
else
    log "No GitHub token available for pushing image"
    exit 1
fi

log "Build completed successfully" 