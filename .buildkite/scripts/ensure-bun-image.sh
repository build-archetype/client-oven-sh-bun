#!/bin/bash
set -e
set -x

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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

# Hardcoded image configuration -- update this when we switch to a new base image
IMAGE_NAME="base-bun-build-macos-darwin"
BASE_IMAGE_REMOTE="ghcr.io/cirruslabs/macos-sequoia-base:latest"
TARGET_IMAGE="ghcr.io/build-archetype/client-oven-sh-bun/base-bun-build-macos-darwin:latest"

# set the number of retries for the commands
MAX_RETRIES=3

# Print configuration summary
log "=== Configuration Summary ==="
log "Custom Image Name: $IMAGE_NAME"
log "Base Image Remote: $BASE_IMAGE_REMOTE"
log "Target Image: $TARGET_IMAGE"
log "Max Retries: $MAX_RETRIES"
log "GitHub Token: ${GITHUB_TOKEN:+set}${GITHUB_TOKEN:-not set}"
log "==========================="
log "Current working directory: $(pwd)"
log "Directory contents:"
ls -la
log "==========================="

# Function to check if image exists
check_image_exists() {
    log "Checking if image $IMAGE_NAME exists..."
    log "Current tart images:"
    tart list
    if tart list | grep -q "$IMAGE_NAME"; then
        log "Image $IMAGE_NAME found locally"
        return 0
    else
        log "Image $IMAGE_NAME not found locally"
        return 1
    fi
}

# Function to pull image
pull_image() {
    log "Attempting to pull image $TARGET_IMAGE..."
    log "Running tart pull with verbose output..."
    if tart pull "$TARGET_IMAGE" --verbose; then
        log "Successfully pulled image $TARGET_IMAGE"
        log "Verifying image after pull:"
        tart list
        return 0
    else
        log "Failed to pull image $TARGET_IMAGE"
        return 1
    fi
}

# Function to check and pull base image
check_and_pull_base_image() {
    log "Starting base image check and pull process..."
    
    # First check if image exists
    if check_image_exists; then
        log "Base image already exists, no need to pull"
        return 0
    fi
    
    # If image doesn't exist, try to pull it
    log "Base image not found, attempting to pull..."
    if pull_image; then
        # Verify the pull was successful by checking if image exists
        if check_image_exists; then
            log "Successfully pulled and verified base image"
            return 0
        else
            log "Image pull appeared successful but image not found in local list"
            return 1
        fi
    else
        log "Failed to pull base image"
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

# Check and pull base image with retries
log "Starting base image check and pull with retries..."
if ! retry_command "check_and_pull_base_image"; then
    log "Failed to check/pull base image after $MAX_RETRIES attempts"
    exit 1
fi

# Always clone the base image from the remote reference to the custom image name
log "Cloning base image from remote reference to create custom image..."
log "Current tart images before clone:"
tart list
retry_command "tart clone $BASE_IMAGE_REMOTE $IMAGE_NAME" || {
    log "Failed to clone base image after $MAX_RETRIES attempts"
    exit 1
}
log "Current tart images after clone:"
tart list

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