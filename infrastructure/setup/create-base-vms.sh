#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
MACOS_VERSION="14"
VM_USERNAME="admin"
VM_PASSWORD="admin"  # You should change this
TART_PATH="/opt/tart/images"

# Function to print status messages
log() {
    echo -e "${GREEN}[create-base-vms]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check if Tart is installed
check_tart() {
    if ! command -v tart &> /dev/null; then
        error "Tart is not installed. Please install it first: brew install tart"
    fi
}

# Function to create VM configuration script
create_vm_config_script() {
    local SCRIPT_PATH="/tmp/configure-vm.sh"
    cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash
set -euo pipefail

# Wait for Software Update to complete its initial check
while pgrep -q "Software Update"; do
    echo "Waiting for Software Update to complete..."
    sleep 5
done

echo "Installing Xcode Command Line Tools..."
# Try to install Xcode CLI tools, ignore if already installed
xcode-select --install || true
# Wait for installation to complete
while pgrep -q "Install Command Line Developer Tools"; do
    echo "Waiting for Xcode CLI tools installation..."
    sleep 5
done

echo "Installing Homebrew..."
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Add Homebrew to PATH
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

echo "Installing build dependencies..."
brew install \
    git \
    node \
    cmake \
    ninja \
    python3 \
    wget \
    curl \
    zig \
    pkg-config \
    openssl@3

echo "Configuring system settings..."
# Disable sleep
sudo pmset -a sleep 0
sudo pmset -a hibernatemode 0
sudo pmset -a disablesleep 1

# Disable screen saver
defaults write com.apple.screensaver idleTime 0

# Disable automatic updates
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false

# Disable crash reporter
defaults write com.apple.CrashReporter DialogType none

# Speed up window animations
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock autohide-time-modifier -float 0

# Create build directories
sudo mkdir -p /opt/buildkite-agent/builds
sudo mkdir -p /opt/buildkite-agent/hooks
sudo mkdir -p /opt/buildkite-agent/plugins

echo "Setup complete!"
EOF

    chmod +x "$SCRIPT_PATH"
    echo "$SCRIPT_PATH"
}

# Function to create and configure a VM
create_vm() {
    local NAME=$1
    local INTEL=${2:-false}
    
    log "Creating VM: $NAME"
    
    # Create VM with appropriate architecture flag
    if [ "$INTEL" = true ]; then
        tart create "$NAME" --from-macos-version "$MACOS_VERSION" --intel || error "Failed to create Intel VM $NAME"
    else
        tart create "$NAME" --from-macos-version "$MACOS_VERSION" || error "Failed to create ARM VM $NAME"
    fi
    
    # Start VM
    log "Starting VM $NAME..."
    tart run "$NAME" &
    
    # Wait for VM to be ready
    sleep 30  # Initial boot time
    
    # Copy and execute configuration script
    CONFIG_SCRIPT=$(create_vm_config_script)
    log "Copying configuration script to VM..."
    tart copy "$NAME" "$CONFIG_SCRIPT" /tmp/configure-vm.sh
    
    log "Executing configuration script in VM..."
    tart exec "$NAME" /tmp/configure-vm.sh
    
    # Stop VM
    log "Stopping VM $NAME..."
    tart stop "$NAME"
    
    log "VM $NAME created and configured successfully"
}

# Function to create all base VMs
create_all_vms() {
    # Create base ARM VM
    log "Creating base ARM VM..."
    create_vm "base-macos-arm"
    
    # Clone for different ARM architectures
    log "Creating M1/M2/M3/M4 specific VMs..."
    for arch in m1 m2 m3 m4; do
        log "Cloning for $arch..."
        tart clone "base-macos-arm" "base-$arch" || error "Failed to clone for $arch"
    done
    
    # Create Intel VM
    log "Creating base Intel VM..."
    create_vm "base-macos-intel" true
    
    log "All VMs created successfully!"
}

# Main execution
main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error "Please run as root (sudo -E)"
    fi
    
    # Check for Tart
    check_tart
    
    # Create VMs directory if it doesn't exist
    mkdir -p "$TART_PATH"
    
    # Create all VMs
    create_all_vms
    
    # List all created VMs
    log "Created VMs:"
    tart list
    
    log "Base VM creation complete! You can now use these images for your CI builds."
    log "Base images are stored in $TART_PATH"
}

# Run main function
main "$@"
