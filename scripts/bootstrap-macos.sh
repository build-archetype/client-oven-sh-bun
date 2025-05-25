#!/bin/bash
set -e
set -x

# Version: 1.0
# A simplified bootstrap script specifically for macOS with better retry logic

# Constants
MAX_RETRIES=3
INITIAL_BACKOFF=5
MAX_BACKOFF=30

# Helper functions
print() {
    echo "$@"
}

error() {
    print "error: $@" >&2
    exit 1
}

# Retry function with exponential backoff
retry_command() {
    local cmd="$1"
    local attempt=1
    local backoff=$INITIAL_BACKOFF
    local exitcode=0

    while [ $attempt -le $MAX_RETRIES ]; do
        echo "Attempt $attempt of $MAX_RETRIES: $cmd"
        if eval "$cmd"; then
            return 0
        fi
        exitcode=$?
        echo "Command failed with exit code $exitcode"
        
        if [ $attempt -lt $MAX_RETRIES ]; then
            echo "Waiting $backoff seconds before retry..."
            sleep $backoff
            backoff=$((backoff * 2))
            if [ $backoff -gt $MAX_BACKOFF ]; then
                backoff=$MAX_BACKOFF
            fi
        fi
        attempt=$((attempt + 1))
    done

    return $exitcode
}

# Install Homebrew if not present
install_brew() {
    if ! command -v brew >/dev/null 2>&1; then
        echo "Installing Homebrew..."
        retry_command '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        
        # Add Homebrew to PATH based on architecture
        if [ "$(uname -m)" = "arm64" ]; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
            eval "$(/opt/homebrew/bin/brew shellenv)"
        else
            echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    fi
}

# Install basic dependencies
install_basic_deps() {
    echo "Installing basic dependencies..."
    retry_command 'brew install bash ca-certificates curl htop git gnupg unzip wget'
}

# Install build tools
install_build_tools() {
    echo "Installing build tools..."
    retry_command 'brew install cmake ninja pkg-config golang'
}

# Install development tools
install_dev_tools() {
    echo "Installing development tools..."
    retry_command 'brew install llvm@19'
    
    # Link LLVM tools
    ln -sf "$(brew --prefix llvm@19)/bin/clang" /usr/local/bin/clang
    ln -sf "$(brew --prefix llvm@19)/bin/clang++" /usr/local/bin/clang++
    ln -sf "$(brew --prefix llvm@19)/bin/llvm-ar" /usr/local/bin/llvm-ar
    ln -sf "$(brew --prefix llvm@19)/bin/llvm-ranlib" /usr/local/bin/llvm-ranlib
    ln -sf "$(brew --prefix llvm@19)/bin/lld" /usr/local/bin/lld
}

# Install Bun
install_bun() {
    echo "Installing Bun..."
    # Use the same method as the original bootstrap.sh
    local os="darwin"
    local arch="$(uname -m)"
    if [ "$arch" = "arm64" ]; then
        arch="aarch64"
    else
        arch="x64"
    fi
    
    local bun_triplet="bun-$os-$arch"
    local bun_version="1.2.0"  # Using the version from original script
    local bun_download_url="https://pub-5e11e972747a44bf9aaf9394f185a982.r2.dev/releases/bun-v$bun_version/$bun_triplet.zip"
    
    echo "Downloading Bun from $bun_download_url..."
    retry_command "curl -fsSL -o /tmp/bun.zip $bun_download_url"
    
    echo "Extracting Bun..."
    retry_command "unzip -o /tmp/bun.zip -d /tmp"
    
    echo "Installing Bun..."
    retry_command "sudo mv /tmp/$bun_triplet/bun /usr/local/bin/"
    retry_command "sudo ln -sf /usr/local/bin/bun /usr/local/bin/bunx"
    
    echo "Cleaning up..."
    rm -f /tmp/bun.zip
    rm -rf "/tmp/$bun_triplet"
}

# Main installation process
main() {
    echo "Starting macOS bootstrap process..."
    
    # Install Homebrew first
    install_brew
    
    # Update Homebrew
    echo "Updating Homebrew..."
    retry_command 'brew update'
    
    # Install dependencies in stages
    install_basic_deps
    install_build_tools
    install_dev_tools
    install_bun
    
    # Verify installations
    echo "Verifying installations..."
    which bun && bun --version
    which cmake && cmake --version
    which ninja && ninja --version
    which go && go version
    which clang && clang --version
    
    echo "Bootstrap completed successfully!"
}

# Run main function
main "$@" 