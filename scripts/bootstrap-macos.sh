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
    retry_command 'brew install bash ca-certificates curl htop git gnupg unzip wget jq'
}

# Install build tools
install_build_tools() {
    echo "Installing build tools..."
    retry_command 'brew install cmake ninja pkg-config golang'
    
    # Additional essential build tools from main bootstrap
    echo "Installing additional build essentials..."
    retry_command 'brew install make python3 libtool ruby perl'
}

# Install development tools
install_dev_tools() {
    echo "Installing development tools..."
    retry_command 'brew install llvm@19'
    
    # Install ccache for faster compilation
    echo "Installing ccache..."
    retry_command 'brew install ccache'
    
    # Link LLVM tools with sudo
    echo "Creating symbolic links for LLVM tools..."
    retry_command 'sudo ln -sf "$(brew --prefix llvm@19)/bin/clang" /usr/local/bin/clang'
    retry_command 'sudo ln -sf "$(brew --prefix llvm@19)/bin/clang++" /usr/local/bin/clang++'
    retry_command 'sudo ln -sf "$(brew --prefix llvm@19)/bin/llvm-ar" /usr/local/bin/llvm-ar'
    retry_command 'sudo ln -sf "$(brew --prefix llvm@19)/bin/llvm-ranlib" /usr/local/bin/llvm-ranlib'
    retry_command 'sudo ln -sf "$(brew --prefix llvm@19)/bin/lld" /usr/local/bin/lld'
}

# Install Rust (required for building Bun)
install_rust() {
    echo "Installing Rust..."
    
    if ! command -v cargo >/dev/null 2>&1; then
        echo "Rust not found, installing via rustup..."
        
        # Create dedicated Rust directory (following main bootstrap approach)
        local rust_home="/opt/rust"
        echo "Creating Rust home directory: $rust_home"
        sudo mkdir -p "$rust_home"
        sudo chown -R "$(whoami):staff" "$rust_home"
        
        # Set up Rust environment variables (following main bootstrap)
        export RUSTUP_HOME="$rust_home"
        export CARGO_HOME="$rust_home"
        
        # Install rustup and Rust non-interactively
        retry_command 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path'
        
        # Add Rust environment to shell profiles
        local rust_profile_content="export RUSTUP_HOME=\"$rust_home\"
export CARGO_HOME=\"$rust_home\"
export PATH=\"$rust_home/bin:\$PATH\""
        
        for profile in ~/.zprofile ~/.bash_profile ~/.bashrc ~/.zshrc ~/.profile; do
            if [ -f "$profile" ] || [ "$profile" = ~/.zprofile ]; then
                echo "Adding Rust environment to $profile..."
                if ! grep -q "RUSTUP_HOME" "$profile" 2>/dev/null; then
                    echo "$rust_profile_content" >> "$profile"
                fi
            fi
        done
        
        # Update current session PATH
        export PATH="$rust_home/bin:$PATH"
        
        # Verify Rust installation
        echo "Verifying Rust installation..."
        if command -v cargo >/dev/null 2>&1; then
            echo "✅ Rust installed successfully"
            echo "  Rustc version: $(rustc --version)"
            echo "  Cargo version: $(cargo --version)"
            echo "  Rust home: $rust_home"
        else
            error "Rust installation verification failed"
        fi
    else
        echo "✅ Rust already installed"
        echo "  Rustc version: $(rustc --version)"
        echo "  Cargo version: $(cargo --version)"
    fi
}

# Install bootstrap Bun (pre-built binary to build Bun with)
install_bootstrap_bun() {
    echo "Installing bootstrap Bun binary..."
    
    # Use the same logic as bootstrap.sh
    local os="darwin"
    local arch="$(uname -m)"
    if [ "$arch" = "arm64" ]; then
        arch="aarch64"
    else
        arch="x64"
    fi
    
    local bun_triplet="bun-$os-$arch"
    local bootstrap_version="1.2.0"  # Same as bootstrap.sh
    local bun_download_url="https://pub-5e11e972747a44bf9aaf9394f185a982.r2.dev/releases/bun-v$bootstrap_version/$bun_triplet.zip"
    
    echo "Downloading bootstrap Bun version $bootstrap_version from $bun_download_url..."
    
    # Download and extract
    local tmp_dir="/tmp/bun-bootstrap"
    mkdir -p "$tmp_dir"
    retry_command "curl -fsSL -o '$tmp_dir/bun.zip' '$bun_download_url'"
    retry_command "cd '$tmp_dir' && unzip -o bun.zip"
    
    # Install to /usr/local/bin
    retry_command "sudo cp '$tmp_dir/$bun_triplet/bun' /usr/local/bin/"
    retry_command "sudo chmod +x /usr/local/bin/bun"
    retry_command "sudo ln -sf /usr/local/bin/bun /usr/local/bin/bunx"
    
    # Add /usr/local/bin to PATH in shell profiles
    echo "Adding /usr/local/bin to PATH in shell profiles..."
    local path_export='export PATH="/usr/local/bin:$PATH"'
    
    # Update various shell profiles
    for profile in ~/.zprofile ~/.bash_profile ~/.bashrc ~/.zshrc ~/.profile; do
        if [ -f "$profile" ] || [ "$profile" = ~/.zprofile ]; then
            echo "Updating $profile..."
            if ! grep -q "/usr/local/bin" "$profile" 2>/dev/null; then
                echo "$path_export" >> "$profile"
            fi
        fi
    done
    
    # Also update current session
    export PATH="/usr/local/bin:$PATH"
    
    # Verify bootstrap Bun works
    echo "Verifying bootstrap Bun installation..."
    /usr/local/bin/bun --version || error "Bootstrap Bun verification failed"
    
    # Clean up
    rm -rf "$tmp_dir"
    echo "✅ Bootstrap Bun installed successfully"
}

# Build Bun from source using the bootstrap Bun
build_bun_from_source() {
    echo "Building Bun from source..."
    
    # Navigate to the workspace directory
    cd "/Volumes/My Shared Files/workspace" || error "Could not find workspace directory"
    
    echo "Current directory: $(pwd)"
    echo "Contents of workspace:"
    ls -la
    
    # Verify we have the Bun source
    if [ ! -f "CMakeLists.txt" ] || [ ! -f "package.json" ]; then
        error "This doesn't appear to be a Bun source directory"
    fi
    
    # Get the version from package.json
    local bun_version=""
    if [ -f "package.json" ]; then
        bun_version=$(jq -r '.version // empty' package.json 2>/dev/null || echo "unknown")
    fi
    echo "Building Bun version: $bun_version"
    
    # Install Zig (required for building Bun)
    echo "Installing Zig..."
    retry_command 'brew install zig'
    
    # Set up build environment
    export CMAKE_BUILD_TYPE=Release
    export PATH="/opt/homebrew/opt/llvm@19/bin:$PATH"
    export CC="$(brew --prefix llvm@19)/bin/clang"
    export CXX="$(brew --prefix llvm@19)/bin/clang++"
    
    # Ensure Rust is available in the PATH
    local rust_home="/opt/rust"
    if [ -d "$rust_home" ]; then
        export RUSTUP_HOME="$rust_home"
        export CARGO_HOME="$rust_home"
        export PATH="$rust_home/bin:$PATH"
    elif [ -f "$HOME/.cargo/env" ]; then
        # Fallback to default cargo installation
        source "$HOME/.cargo/env"
        export PATH="$HOME/.cargo/bin:$PATH"
    fi
    
    echo "Build environment:"
    echo "  CC: $CC"
    echo "  CXX: $CXX"
    echo "  CMAKE_BUILD_TYPE: $CMAKE_BUILD_TYPE"
    echo "  Bootstrap Bun: $(which bun) (version: $(bun --version))"
    echo "  Rust: $(which rustc 2>/dev/null || echo 'not found') (version: $(rustc --version 2>/dev/null || echo 'not available'))"
    echo "  Cargo: $(which cargo 2>/dev/null || echo 'not found') (version: $(cargo --version 2>/dev/null || echo 'not available'))"
    
    # Check status before building
    check_bun_status "BEFORE BUILD CONFIGURATION"
    
    # Configure the build with Bun
    echo "Configuring build with bootstrap Bun..."
    retry_command 'bun run build:configure'
    
    # If that doesn't work, try cmake directly
    if [ ! -d "build/release" ]; then
        echo "Fallback: Configuring build with cmake..."
        retry_command 'cmake -B build/release -GNinja -DCMAKE_BUILD_TYPE=Release'
    fi
    
    # Build Bun using bootstrap Bun
    echo "Building Bun from source (this may take a while)..."
    if [ -f "package.json" ] && jq -e '.scripts.build' package.json >/dev/null 2>&1; then
        retry_command 'bun run build'
    else
        # Fallback to ninja
        retry_command 'ninja -C build/release'
    fi
    
    # Install the newly built Bun binary
    echo "Installing newly built Bun binary..."
    if [ -f "build/release/bun" ]; then
        retry_command 'sudo cp build/release/bun /usr/local/bin/bun-new'
        retry_command 'sudo chmod +x /usr/local/bin/bun-new'
        
        # Replace the bootstrap bun with the new one
        retry_command 'sudo mv /usr/local/bin/bun-new /usr/local/bin/bun'
        retry_command 'sudo ln -sf /usr/local/bin/bun /usr/local/bin/bunx'
        
        # Ensure PATH is still correct
        export PATH="/usr/local/bin:$PATH"
        
        echo "✅ Bun built and installed successfully"
    else
        error "Build failed - bun binary not found in build/release/"
    fi
    
    # Verify the final installation
    echo "Verifying final Bun installation..."
    echo "PATH: $PATH"
    echo "Which bun: $(which bun)"
    local final_version=$(/usr/local/bin/bun --version)
    echo "Final Bun version: $final_version"
    
    if [ "$final_version" != "$bun_version" ]; then
        echo "⚠️  Warning: Built version ($final_version) doesn't match expected ($bun_version)"
    fi
}

# Helper function to check Bun and PATH status
check_bun_status() {
    local stage="$1"
    echo ""
    echo "=== BUN & PATH STATUS CHECK: $stage ==="
    echo "Current user: $(whoami)"
    echo "Current directory: $(pwd)"
    echo "PATH: $PATH"
    echo ""
    echo "Checking Bun availability:"
    if command -v bun >/dev/null 2>&1; then
        echo "✅ Bun found at: $(which bun)"
        local version=$(bun --version 2>/dev/null || echo "failed to get version")
        echo "✅ Bun version: $version"
        echo "✅ Bun executable permissions: $(ls -la $(which bun) 2>/dev/null || echo 'failed to check permissions')"
    else
        echo "❌ Bun not found in PATH"
        echo "Checking common locations:"
        for loc in /usr/local/bin/bun /opt/homebrew/bin/bun /usr/bin/bun; do
            if [ -f "$loc" ]; then
                echo "  Found: $loc ($(ls -la $loc))"
                echo "  Version: $($loc --version 2>/dev/null || echo 'failed to get version')"
            else
                echo "  Not found: $loc"
            fi
        done
    fi
    echo ""
    echo "Available binaries in PATH directories:"
    echo $PATH | tr ':' '\n' | while read dir; do
        if [ -d "$dir" ] && [ -r "$dir" ]; then
            local bins=$(ls "$dir" 2>/dev/null | grep -E '^(bun|node|npm|bunx)' | head -5 || echo 'none')
            echo "  $dir: $bins"
        fi
    done
    echo "============================================"
    echo ""
}

# Main installation process
main() {
    echo "Starting macOS bootstrap process..."
    
    # Initial status check
    check_bun_status "INITIAL STATE"
    
    # Install Homebrew first
    install_brew
    
    # Update Homebrew
    echo "Updating Homebrew..."
    retry_command 'brew update'
    
    # Install dependencies in stages
    install_basic_deps
    install_build_tools
    install_dev_tools
    install_rust
    
    # Install bootstrap Bun first (needed to build actual Bun)
    install_bootstrap_bun
    
    # Check status after bootstrap Bun installation
    check_bun_status "AFTER BOOTSTRAP BUN INSTALL"
    
    # Build the actual Bun from source
    build_bun_from_source
    
    # Check status after building from source
    check_bun_status "AFTER BUILDING FROM SOURCE"
    
    # Verify installations
    echo "Verifying installations..."
    which bun && bun --version
    which cmake && cmake --version
    which ninja && ninja --version
    which go && go version
    which clang && clang --version
    which rustc && rustc --version
    which cargo && cargo --version
    which make && make --version | head -1
    which python3 && python3 --version
    which libtool && libtool --version | head -1
    which ruby && ruby --version
    which perl && perl --version
    which ccache && ccache --version
    
    # Final status check
    check_bun_status "FINAL STATE"
    
    echo "Bootstrap completed successfully!"
}

# Run main function
main "$@" 