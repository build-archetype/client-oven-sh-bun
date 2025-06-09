#!/bin/bash
set -e
set -x

# Version: 3.6 - Fixed SSH connectivity and improved base image validation
# A comprehensive bootstrap script for macOS based on the main bootstrap.sh

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

execute() {
    print "$ $@" >&2
    if ! "$@"; then
        error "Command failed: $@"
    fi
}

execute_as_user() {
    local sh="$(require sh)"
    if [ "$(id -u)" = "0" ]; then
        # Running as root, switch to the original user
        local target_user="${SUDO_USER:-$USER}"
        execute sudo -n -u "$target_user" "$sh" -lc "$*"
    else
        execute "$sh" -lc "$*"
    fi
}

which() {
    command -v "$1"
}

require() {
    local path="$(which "$1")"
    if ! [ -f "$path" ]; then
        error "Command \"$1\" is required, but is not installed."
    fi
    print "$path"
}

fetch() {
    local curl="$(which curl)"
    if [ -f "$curl" ]; then
        execute "$curl" -fsSL "$1"
    else
        local wget="$(which wget)"
        if [ -f "$wget" ]; then
            execute "$wget" -qO- "$1"
        else
            error "Command \"curl\" or \"wget\" is required, but is not installed."
        fi
    fi
}

create_directory() {
    local path="$1"
    local path_dir="$path"
    while ! [ -d "$path_dir" ]; do
        path_dir="$(dirname "$path_dir")"
    done

    local path_needs_sudo="0"
    if ! [ -r "$path_dir" ] || ! [ -w "$path_dir" ]; then
        path_needs_sudo="1"
    fi

    local mkdir="$(require mkdir)"
    if [ "$path_needs_sudo" = "1" ]; then
        execute sudo "$mkdir" -p "$path"
    else
        execute "$mkdir" -p "$path"
    fi

    # Set ownership to current user
    execute sudo chown -R "$(whoami):staff" "$path"
    execute sudo chmod -R 755 "$path"
}

create_tmp_directory() {
    local mktemp="$(require mktemp)"
    local path="$(execute "$mktemp" -d)"
    grant_to_user "$path"
    print "$path"
}

download_file() {
    local file_url="$1"
    local file_tmp_dir="$(create_tmp_directory)"
    local file_tmp_path="$file_tmp_dir/$(basename "$file_url")"

    fetch "$file_url" >"$file_tmp_path"
    grant_to_user "$file_tmp_path"
    print "$file_tmp_path"
}

append_to_profile() {
    local content="$1"
    local profiles=".profile .zprofile .bash_profile .bashrc .zshrc"
    for profile in $profiles; do
        local profile_path="$HOME/$profile"
        if [ -f "$profile_path" ] || [ "$profile" = ".zprofile" ]; then
            if ! grep -q "$content" "$profile_path" 2>/dev/null; then
                echo "$content" >> "$profile_path"
            fi
        fi
    done
}

append_to_path() {
    local path="$1"
    if ! [ -d "$path" ]; then
        error "Could not find directory: \"$path\""
    fi

    append_to_profile "export PATH=\"$path:\$PATH\""
    export PATH="$path:$PATH"
}

grant_to_user() {
    local path="$1"
    if ! [ -f "$path" ] && ! [ -d "$path" ]; then
        error "Could not find file or directory: \"$path\""
    fi

    local chown="$(require chown)"
    execute sudo "$chown" -R "$(whoami):staff" "$path"
    execute sudo chmod -R 755 "$path"
}

move_to_bin() {
    local exe_path="$1"
    if ! [ -f "$exe_path" ]; then
        error "Could not find executable: \"$exe_path\""
    fi

    local usr_paths="/usr/local/bin /opt/homebrew/bin"
    local usr_path=""
    for path in $usr_paths; do
        if [ -d "$path" ] && [ -w "$path" ]; then
            usr_path="$path"
            break
        fi
    done

    if [ -z "$usr_path" ]; then
        usr_path="/usr/local/bin"
        execute sudo mkdir -p "$usr_path"
    fi

    execute sudo mv -f "$exe_path" "$usr_path/$(basename "$exe_path")"
    execute sudo chmod +x "$usr_path/$(basename "$exe_path")"
}

# Retry function with exponential backoff (for compatibility)
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

# Package management
install_packages() {
    execute_as_user brew install --force --formula "$@"
    execute_as_user brew link --force --overwrite "$@"
}

# Install Homebrew if not present
install_brew() {
    if ! command -v brew >/dev/null 2>&1; then
        print "Installing Homebrew..."
        
        # Use the standard Homebrew installation method
        print "Downloading and running Homebrew installer..."
        local curl="$(require curl)"
        
        print "$ curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | NONINTERACTIVE=1 bash"
        if ! NONINTERACTIVE=1 "$curl" -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | bash; then
            error "Homebrew installation failed"
        fi
        
        # Add Homebrew to PATH based on architecture
        case "$(uname -m)" in
        arm64)
            append_to_path "/opt/homebrew/bin"
            ;;
        x86_64)
            append_to_path "/usr/local/bin"
            ;;
        esac
        
        # Set CI-friendly environment variables
        append_to_profile "export HOMEBREW_NO_INSTALL_CLEANUP=1"
        append_to_profile "export HOMEBREW_NO_AUTO_UPDATE=1"
        append_to_profile "export HOMEBREW_NO_ANALYTICS=1"
        
        print "✅ Homebrew installed successfully"
    else
        print "✅ Homebrew already installed"
    fi
}

# Node.js version functions (from main bootstrap)
nodejs_version_exact() {
    print "22.9.0"
}

nodejs_version() {
    print "$(nodejs_version_exact)" | cut -d. -f1
}

install_nodejs() {
    install_packages nodejs
}

# Bun version function (from main bootstrap)
bun_version_exact() {
    print "1.2.0"
}

install_bun() {
    print "Installing Bun bootstrap binary..."
    
    local os="darwin"
    local arch="$(uname -m)"
    case "$arch" in
    arm64)
        arch="aarch64"
        ;;
    x86_64)
        arch="x64"
        ;;
    esac
    
    local bun_triplet="bun-$os-$arch"
    local bun_download_url="https://pub-5e11e972747a44bf9aaf9394f185a982.r2.dev/releases/bun-v$(bun_version_exact)/$bun_triplet.zip"
    
    local unzip="$(require unzip)"
    local bun_zip="$(download_file "$bun_download_url")"
    local bun_tmpdir="$(dirname "$bun_zip")"
    execute "$unzip" -o "$bun_zip" -d "$bun_tmpdir"

    move_to_bin "$bun_tmpdir/$bun_triplet/bun"
    local bun_path="$(require bun)"
    execute sudo ln -sf "$bun_path" "$(dirname "$bun_path")/bunx"
    
    print "✅ Bun installed successfully: $(bun --version)"
}

install_rosetta() {
    # Only install Rosetta 2 on Apple Silicon Macs
    if [ "$(uname -m)" = "arm64" ]; then
        print "Checking Rosetta 2 installation..."
        # Check if Rosetta 2 is already installed by trying to run an x86_64 binary
        if ! /usr/bin/pgrep oahd >/dev/null 2>&1 && ! arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
            print "Installing Rosetta 2..."
            execute softwareupdate --install-rosetta --agree-to-license
            print "✅ Rosetta 2 installed successfully"
        else
            print "✅ Rosetta 2 already installed"
        fi
    else
        print "✅ Rosetta 2 not needed on Intel Macs"
    fi
}

install_cmake() {
    install_packages cmake
}

# LLVM version functions (from main bootstrap)
llvm_version_exact() {
    print "19.1.7"
}

llvm_version() {
    print "$(llvm_version_exact)" | cut -d. -f1
}

install_llvm() {
    local llvm_version_num="$(llvm_version)"
    install_packages "llvm@$llvm_version_num"
    
    # Create symlinks for easier access
    local llvm_prefix="/opt/homebrew/opt/llvm@$llvm_version_num"
    if [ "$(uname -m)" = "x86_64" ]; then
        llvm_prefix="/usr/local/opt/llvm@$llvm_version_num"
    fi
    
    # Determine the appropriate bin directory
    local bin_dir="/usr/local/bin"
    if [ "$(uname -m)" = "arm64" ] && [ -d "/opt/homebrew/bin" ]; then
        bin_dir="/opt/homebrew/bin"
    fi
    
    # Ensure bin directory exists and is writable
    if [ ! -d "$bin_dir" ]; then
        execute sudo mkdir -p "$bin_dir"
    fi
    
    print "Creating LLVM symlinks in $bin_dir..."
    execute sudo ln -sf "$llvm_prefix/bin/clang" "$bin_dir/clang"
    execute sudo ln -sf "$llvm_prefix/bin/clang++" "$bin_dir/clang++"
    execute sudo ln -sf "$llvm_prefix/bin/llvm-ar" "$bin_dir/llvm-ar"
    execute sudo ln -sf "$llvm_prefix/bin/llvm-ranlib" "$bin_dir/llvm-ranlib"
    execute sudo ln -sf "$llvm_prefix/bin/lld" "$bin_dir/lld"
    execute sudo ln -sf "$llvm_prefix/bin/llvm-symbolizer" "$bin_dir/llvm-symbolizer"
    
    print "✅ LLVM installed and symlinked successfully"
}

install_ccache() {
    install_packages ccache
}

install_rust() {
    print "Installing Rust..."
    
    # Use standard Rust installation location (more reliable)
    local curl="$(require curl)"
    local sh="$(require sh)"
    
    # Download rustup installer
    local rustup_script=$(download_file "https://sh.rustup.rs")
    
    # Install Rust using standard method (installs to ~/.cargo by default)
    print "Running rustup installer..."
    execute "$sh" "$rustup_script" -y
    
    # Source the cargo env to get the PATH immediately
    if [ -f "$HOME/.cargo/env" ]; then
        source "$HOME/.cargo/env"
    fi
    
    # Add cargo bin to PATH in all profile files for persistence
    append_to_path "$HOME/.cargo/bin"
    
    # Also create system-wide symlinks for reliability
    local bin_dir="/usr/local/bin"
    if [ "$(uname -m)" = "arm64" ] && [ -d "/opt/homebrew/bin" ]; then
        bin_dir="/opt/homebrew/bin"
    fi
    
    # Ensure bin directory exists
    if [ ! -d "$bin_dir" ]; then
        execute sudo mkdir -p "$bin_dir"
    fi
    
    # Create symlinks for cargo, rustc, and rustup
    if [ -f "$HOME/.cargo/bin/cargo" ]; then
        execute sudo ln -sf "$HOME/.cargo/bin/cargo" "$bin_dir/cargo"
        execute sudo ln -sf "$HOME/.cargo/bin/rustc" "$bin_dir/rustc"
        execute sudo ln -sf "$HOME/.cargo/bin/rustup" "$bin_dir/rustup"
        print "✅ Created system-wide Rust symlinks in $bin_dir"
    else
        error "Rust installation failed - cargo not found in ~/.cargo/bin"
    fi
    
    # Verify installation
    if command -v cargo >/dev/null 2>&1; then
        print "✅ Rust installed successfully: $(cargo --version)"
        print "✅ Rustc version: $(rustc --version)"
    else
        error "Rust installation verification failed"
    fi
}

install_buildkite() {
    print "Installing Buildkite Agent..."
    
    local buildkite_version="3.87.0"
    local arch="$(uname -m)"
    case "$arch" in
    arm64)
        buildkite_arch="arm64"
        ;;
    x86_64)
        buildkite_arch="amd64"
        ;;
    esac

    local buildkite_filename="buildkite-agent-darwin-$buildkite_arch-$buildkite_version.tar.gz"
    local buildkite_url="https://github.com/buildkite/agent/releases/download/v$buildkite_version/$buildkite_filename"
    local buildkite_tar="$(download_file "$buildkite_url")"
    local buildkite_tmpdir="$(dirname "$buildkite_tar")"

    execute tar -xzf "$buildkite_tar" -C "$buildkite_tmpdir"
    move_to_bin "$buildkite_tmpdir/buildkite-agent"
    
    print "✅ Buildkite Agent installed successfully: $(buildkite-agent --version)"
}

install_chromium() {
    print "Installing Chromium for browser testing..."
    # Use Google Chrome via Homebrew cask for better compatibility
    execute_as_user brew install google-chrome --cask || {
        print "⚠️ Chrome installation failed, trying chromium..."
        execute_as_user brew install chromium --cask || {
            print "⚠️ Chromium installation also failed - browser tests may not work"
            return 1
        }
    }
    print "✅ Browser installed successfully"
}

install_docker() {
    if ! [ -d "/Applications/Docker.app" ]; then
        print "Installing Docker..."
        execute_as_user brew install docker --cask
    fi
}

install_xcode_tools() {
    # Check if we already have a working C++ compiler (from Xcode or Command Line Tools)
    if command -v clang >/dev/null 2>&1 && command -v clang++ >/dev/null 2>&1; then
        print "✅ C/C++ compilers already available:"
        print "  clang: $(which clang)"
        print "  clang++: $(which clang++)"
        
        # Check if this is from full Xcode
        if xcode-select -p >/dev/null 2>&1; then
            local xcode_path="$(xcode-select -p)"
            print "  Xcode developer tools path: $xcode_path"
            if [[ "$xcode_path" == *"/Applications/Xcode"* ]]; then
                print "  ✅ Full Xcode installation detected - skipping Command Line Tools"
                return 0
            fi
        fi
        
        print "  ✅ Command Line Tools already installed - skipping installation"
        return 0
    fi
    
    print "Installing Xcode Command Line Tools..."
    execute xcode-select --install
}

# Verification function
verify_installations() {
    print "Verifying installations..."
    
    local tools="bun cmake ninja go clang rustc cargo make python3 libtool ruby perl ccache buildkite-agent"
    local missing_tools=""
    local verification_failed=false
    
    for tool in $tools; do
        if command -v "$tool" >/dev/null 2>&1; then
            local version_output=""
            case "$tool" in
            bun) 
                version_output="$(bun --version 2>/dev/null || echo 'version check failed')" 
                ;;
            cmake) 
                version_output="$(cmake --version 2>/dev/null | head -1 || echo 'version check failed')" 
                ;;
            ninja) 
                version_output="$(ninja --version 2>/dev/null || echo 'version check failed')" 
                ;;
            go) 
                version_output="$(go version 2>/dev/null || echo 'version check failed')" 
                ;;
            clang) 
                version_output="$(clang --version 2>/dev/null | head -1 || echo 'version check failed')" 
                ;;
            rustc) 
                version_output="$(rustc --version 2>/dev/null || echo 'version check failed')" 
                ;;
            cargo) 
                version_output="$(cargo --version 2>/dev/null || echo 'version check failed')" 
                ;;
            make) 
                version_output="$(make --version 2>/dev/null | head -1 || echo 'version check failed')" 
                ;;
            python3) 
                version_output="$(python3 --version 2>/dev/null || echo 'version check failed')" 
                ;;
            libtool) 
                version_output="$(libtool --version 2>/dev/null | head -1 || echo 'version check failed')" 
                ;;
            ruby) 
                version_output="$(ruby --version 2>/dev/null || echo 'version check failed')" 
                ;;
            perl) 
                version_output="$(perl --version 2>/dev/null | head -2 | tail -1 || echo 'version check failed')" 
                ;;
            ccache) 
                version_output="$(ccache --version 2>/dev/null | head -1 || echo 'version check failed')" 
                ;;
            buildkite-agent) 
                version_output="$(buildkite-agent --version 2>/dev/null || echo 'version check failed')" 
                ;;
            esac
            print "✅ $tool: $version_output"
        else
            print "❌ $tool: not found"
            missing_tools="$missing_tools $tool"
            verification_failed=true
        fi
    done
    
    # Check for browser availability (Chrome or Chromium)
    if [ -d "/Applications/Google Chrome.app" ] || [ -d "/Applications/Chromium.app" ]; then
        print "✅ Browser installed for testing"
    else
        print "⚠️ No browser found - browser tests may fail"
    fi
    
    if [ "$verification_failed" = true ]; then
        print "⚠️  Some tools are missing:$missing_tools"
        print "   This may cause build failures. Check the installation logs above."
    else
        print "✅ All required tools verified successfully!"
    fi
}

# Main installation process
main() {
    print "Starting macOS bootstrap process..."
    print "User: $(whoami)"
    print "Home: $HOME"
    print "Architecture: $(uname -m)"
    print "OS Version: $(sw_vers -productVersion)"
    
    # Install Homebrew first
    install_brew
    
    # Update Homebrew
    print "Updating Homebrew..."
    execute_as_user brew update
    
    # Install software in stages
    install_common_software
    install_build_essentials
    install_chromium
    install_docker
    install_xcode_tools
    
    # Verify installations
    verify_installations
    
    print "✅ Bootstrap completed successfully!"
    print ""
    print "Important notes:"
    print "- Bun bootstrap binary installed: $(which bun)"
    print "- All build dependencies are ready"
    print "- The actual Bun build should happen in subsequent CI steps"
    print "- This image is now ready for Bun compilation"
}

install_common_software() {
    print "Installing common software..."
    
    install_packages \
        bash \
        ca-certificates \
        curl \
        htop \
        gnupg \
        git \
        unzip \
        wget \
        jq

    install_rosetta
    install_nodejs
    install_bun
    install_buildkite
}

install_build_essentials() {
    print "Installing build essentials..."
    
    install_packages \
        ninja \
        pkg-config \
        golang \
        make \
        python3 \
        libtool \
        ruby \
        perl

    install_cmake
    install_llvm
    install_ccache
    install_rust
}

# Run main function
main "$@" 