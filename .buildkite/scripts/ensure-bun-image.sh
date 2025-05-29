#!/bin/bash
set -e
set -x

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check system resources
check_system_resources() {
    log "Checking system resources..."
    log "CPU Info:"
    sysctl -n machdep.cpu.brand_string || true
    log "Memory Info:"
    vm_stat || true
    log "Disk Space:"
    df -h || true
    log "Running VMs:"
    tart list || true
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
    tart list | grep "$IMAGE_NAME" | while read -r line; do
        if echo "$line" | grep -q "running"; then
            log "Found running VM, attempting to stop it..."
            tart stop "$IMAGE_NAME" || true
        fi
    done
}

# Hardcoded image configuration -- update this when we switch to a new base image
IMAGE_NAME="base-bun-build-macos-darwin"
CIRRUS_BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"
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
log "==========================="

# Check system resources before starting
check_system_resources

# Clean up any existing VMs
cleanup_vms

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
    if tart clone "$CIRRUS_BASE_IMAGE" "$IMAGE_NAME"; then
        log "Successfully cloned base image"
        log "Verifying cloned image:"
        tart list
        return 0
    else
        log "Failed to clone base image"
        return 1
    fi
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

# Pull Cirrus base image with retries
log "Starting Cirrus base image pull with retries..."
if ! retry_command "pull_cirrus_base"; then
    log "Failed to pull Cirrus base image after $MAX_RETRIES attempts"
    exit 1
fi

# Clone the base image
log "Cloning Cirrus base image to create our base..."
if ! retry_command "clone_base_image"; then
    log "Failed to clone base image after $MAX_RETRIES attempts"
    exit 1
fi

# Start the VM and run bootstrap
log "Starting VM and running bootstrap..."
VM_PID=""
log "Starting VM with command: tart run $IMAGE_NAME --no-graphics --dir=workspace:$PWD"
tart run "$IMAGE_NAME" --no-graphics --dir=workspace:"$PWD" &
VM_PID=$!

# Wait for VM to be ready and check its status
log "Waiting for VM to be ready..."
sleep 30  # Initial wait time

# Check if VM is running
if ! ps -p $VM_PID > /dev/null; then
    log "VM process failed to start"
    log "Checking VM status:"
    check_vm_status "$IMAGE_NAME"
    log "VM process details:"
    ps aux | grep tart || true
    log "System resources at time of failure:"
    check_system_resources
    exit 1
fi

# Run the simplified macOS bootstrap script
log "Running macOS bootstrap script..."
if ! retry_command ".buildkite/scripts/run-vm-command.sh "$IMAGE_NAME" \"cd /Volumes/My\ Shared\ Files/workspace && chmod +x scripts/bootstrap-macos.sh && ./scripts/bootstrap-macos.sh\""; then
    log "Bootstrap failed after $MAX_RETRIES attempts"
    if [ -n "$VM_PID" ] && ps -p $VM_PID > /dev/null; then
        log "Stopping VM process..."
        kill $VM_PID || true
        wait $VM_PID || true
    fi
    exit 1
fi

# Stop the VM gracefully
log "Stopping VM..."
if [ -n "$VM_PID" ] && ps -p $VM_PID > /dev/null; then
    kill $VM_PID || true
    wait $VM_PID || true
fi

# Push your custom image to your registry
log "Pushing custom image to ghcr.io..."
if [ -n "$GITHUB_TOKEN" ]; then
    echo "$GITHUB_TOKEN" | tart push "$IMAGE_NAME" "$TARGET_IMAGE" --password-stdin || {
        log "Failed to push image"
        exit 1
    }
else
    log "No GitHub token available for pushing image"
    exit 1
fi

log "Bun build image created, updated, and pushed successfully" 