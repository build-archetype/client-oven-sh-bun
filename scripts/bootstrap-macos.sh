#!/bin/bash
set -e
set -x

# Version: 2.0
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

create_tmp_directory() {
    local mktemp="$(require mktemp)"
    local path="$(execute "$mktemp" -d)"
    print "$path"
}

download_file() {
    local file_url="$1"
    local file_tmp_dir="$(create_tmp_directory)"
    local file_tmp_path="$file_tmp_dir/$(basename "$file_url")"

    fetch "$file_url" >"$file_tmp_path"
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
        local bash="$(require bash)"
        local script=$(download_file "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh")
        execute_as_user "$bash" -lc "NONINTERACTIVE=1 $script"
        
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
    if ! command -v arch >/dev/null 2>&1; then
        print "Installing Rosetta 2..."
        execute softwareupdate --install-rosetta --agree-to-license
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
    
    print "Creating LLVM symlinks..."
    execute sudo ln -sf "$llvm_prefix/bin/clang" /usr/local/bin/clang
    execute sudo ln -sf "$llvm_prefix/bin/clang++" /usr/local/bin/clang++
    execute sudo ln -sf "$llvm_prefix/bin/llvm-ar" /usr/local/bin/llvm-ar
    execute sudo ln -sf "$llvm_prefix/bin/llvm-ranlib" /usr/local/bin/llvm-ranlib
    execute sudo ln -sf "$llvm_prefix/bin/lld" /usr/local/bin/lld
    execute sudo ln -sf "$llvm_prefix/bin/llvm-symbolizer" /usr/local/bin/llvm-symbolizer
}

install_ccache() {
    install_packages ccache
}

install_rust() {
    local rust_home="/opt/rust"
    
    print "Installing Rust..."
    execute sudo mkdir -p "$rust_home"
    execute sudo chown -R "$(whoami):staff" "$rust_home"
    
    append_to_profile "export RUSTUP_HOME=$rust_home"
    append_to_profile "export CARGO_HOME=$rust_home"

    local sh="$(require sh)"
    local rustup_script=$(download_file "https://sh.rustup.rs")
    execute "$sh" -lc "RUSTUP_HOME=$rust_home CARGO_HOME=$rust_home $rustup_script -y --no-modify-path"
    append_to_path "$rust_home/bin"
    
    print "✅ Rust installed successfully: $(cargo --version)"
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
        perl \
        zig

    install_cmake
    install_llvm
    install_ccache
    install_rust
}

install_docker() {
    if ! [ -d "/Applications/Docker.app" ]; then
        print "Installing Docker..."
        execute_as_user brew install docker --cask
    fi
}

# Verification function
verify_installations() {
    print "Verifying installations..."
    
    local tools="bun cmake ninja go clang rustc cargo make python3 libtool ruby perl ccache zig"
    for tool in $tools; do
        if command -v "$tool" >/dev/null 2>&1; then
            local version_output=""
            case "$tool" in
            bun) version_output="$(bun --version)" ;;
            cmake) version_output="$(cmake --version | head -1)" ;;
            ninja) version_output="$(ninja --version)" ;;
            go) version_output="$(go version)" ;;
            clang) version_output="$(clang --version | head -1)" ;;
            rustc) version_output="$(rustc --version)" ;;
            cargo) version_output="$(cargo --version)" ;;
            make) version_output="$(make --version | head -1)" ;;
            python3) version_output="$(python3 --version)" ;;
            libtool) version_output="$(libtool --version | head -1)" ;;
            ruby) version_output="$(ruby --version)" ;;
            perl) version_output="$(perl --version | head -2 | tail -1)" ;;
            ccache) version_output="$(ccache --version | head -1)" ;;
            zig) version_output="$(zig version)" ;;
            esac
            print "✅ $tool: $version_output"
        else
            print "❌ $tool: not found"
        fi
    done
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
    install_docker
    
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

# Run main function
main "$@" 