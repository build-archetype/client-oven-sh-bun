#!/bin/bash
set -euo pipefail

# =============================================================================
# BUILD-MACOS-VM.SH - Base VM Management Script
# =============================================================================
#
# PURPOSE: Creates and maintains BASE VMs that serve as templates for builds
# 
# NAMING CONVENTION:
#   Base VMs: bun-build-macos-{release}-{arch}-{bun_version}-bootstrap-{bootstrap_version}
#   Example:  bun-build-macos-13-arm64-1.2.16-bootstrap-4.1
#
# BUILD FLOW:
#   1. This script creates/validates BASE VMs (with all dependencies installed)
#   2. ci-macos.sh CLONES base VMs to create EPHEMERAL VMs for actual builds
#   3. Ephemeral VMs have names like: bun-build-{timestamp}-{UUID}
#   4. Ephemeral VMs are deleted after each build
#   5. Base VMs are reused across multiple builds for efficiency
#
# WHY THIS SEPARATION:
#   - Base VMs: Expensive to create (download macOS, install tools, bootstrap)
#   - Ephemeral VMs: Fast to create (just clone), safe to modify during builds
#   - Avoids corrupting base VMs with build artifacts or configuration changes
#
# =============================================================================

# Fix HOME environment variable if not set (common in CI environments running as root)
if [ -z "${HOME:-}" ]; then
    # Determine appropriate HOME directory based on current user
    if [ "$(id -u)" = "0" ]; then
        # Running as root - use a writable directory since /root is often read-only in CI
        # Try writable locations in order of preference
        for potential_home in "/tmp/root-home" "/var/tmp/root-home" "/opt/buildkite-agent/root-home" "/tmp"; do
            if mkdir -p "$potential_home" 2>/dev/null; then
                export HOME="$potential_home"
                break
            fi
        done
        
        # Fallback if all else fails
        if [ -z "${HOME:-}" ]; then
            export HOME="/tmp"
        fi
    else
        # Try to get HOME from current user
        HOME=$(getent passwd "$(whoami)" | cut -d: -f6 2>/dev/null || echo "/tmp")
        export HOME
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] HOME was not set, using: $HOME"
fi

# Fix USER environment variable if not set (common in CI environments)
if [ -z "${USER:-}" ]; then
    USER=$(whoami)
    export USER
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] USER was not set, using: $USER"
fi

# SSH options for VM connectivity
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# =====================
# CONFIGURATION SECTION
# =====================
# You can override these via environment variables before running the script.

# macOS release version (can be overridden by --release flag)
MACOS_RELEASE="${MACOS_RELEASE:-13}"
# Registry for images (default: GitHub Container Registry)
REGISTRY="${REGISTRY:-ghcr.io}"
# Organization/user for image (default: build-archetype or from GITHUB_REPOSITORY_OWNER)
ORGANIZATION="${GITHUB_REPOSITORY_OWNER:-${ORGANIZATION:-build-archetype}}"
# Repository name (default: client-oven-sh-bun or from GITHUB_REPOSITORY)
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  REPOSITORY="${GITHUB_REPOSITORY##*/}"
else
  REPOSITORY="${REPOSITORY:-client-oven-sh-bun}"
fi
# Base image to clone for new VM images
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/cirruslabs/macos-sonoma-xcode:latest}"
# Bun version (auto-detected, can override)
BUN_VERSION="${BUN_VERSION:-}"
# If not set, will be detected later in the script

# GitHub credentials for pushing images (optional)
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_USERNAME="${GITHUB_USERNAME:-}"

# =====================
# END CONFIGURATION SECTION
# =====================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# === BASH 3.2 COMPATIBILITY FUNCTIONS ===
# Simulate associative arrays for bash 3.2 compatibility
# Global arrays to store key-value pairs
_assoc_keys=()
_assoc_values=()

# Set a key-value pair
assoc_set() {
    local key="$1"
    local value="$2"
    local i
    
    # Check if key already exists
    for i in "${!_assoc_keys[@]:-}"; do
        if [ "${_assoc_keys[i]:-}" = "$key" ]; then
            _assoc_values[i]="$value"
            return 0
        fi
    done
    
    # Add new key-value pair
    _assoc_keys+=("$key")
    _assoc_values+=("$value")
}

# Get value by key
assoc_get() {
    local key="$1"
    local i
    
    for i in "${!_assoc_keys[@]:-}"; do
        if [ "${_assoc_keys[i]:-}" = "$key" ]; then
            echo "${_assoc_values[i]}"
            return 0
        fi
    done
    
    # Key not found
    return 1
}

# Get all keys
assoc_keys() {
    printf '%s\n' "${_assoc_keys[@]:-}"
}

# Clear the associative array simulation
assoc_clear() {
    _assoc_keys=()
    _assoc_values=()
}
# === END BASH 3.2 COMPATIBILITY ===

# Get base image based on macOS release
get_base_image() {
    local release="$1"
    case "$release" in
        "14")
            echo "ghcr.io/cirruslabs/macos-sonoma-xcode:latest"
            ;;
        "13")
            echo "ghcr.io/cirruslabs/macos-ventura-xcode:latest"
            ;;
        *)
            log "⚠️  Unknown macOS release: $release, defaulting to Sonoma (14)"
            echo "ghcr.io/cirruslabs/macos-sonoma-xcode:latest"
            ;;
    esac
}

# Debug: Show who is running this script
log "=== DEBUGGING INFO ==="
log "Current user (whoami): $(whoami)"
log "USER: ${USER:-<not set>}"
log "SUDO_USER: ${SUDO_USER:-<not set>}"
log "HOME: ${HOME:-<not set>}"
log "UID: $(id -u)"
log "GID: $(id -g)"
log "Groups: $(groups)"
log "======================="

# Fix Tart permissions
# This is a workaround for a bug in Tart where the .tart directory is not owned by the user running the script.
# This can be removed once we are confident that tart permissions are working correctly.
fix_tart_permissions() {
    # Safety check - HOME should be set by now, but fallback if not
    if [ -z "${HOME:-}" ]; then
        log "Warning: HOME still not set in fix_tart_permissions, using /root fallback"
        export HOME="/root"
    fi
    
    local tart_dir="$HOME/.tart"
    local real_user="${SUDO_USER:-$USER}"
    
    log "Fixing Tart permissions..."
    log "Tart directory: $tart_dir"
    log "Target user: $real_user"
    
    # Create .tart directory if it doesn't exist
    if [ ! -d "$tart_dir" ]; then
        log "Creating .tart directory..."
        mkdir -p "$tart_dir"
    fi
    
    # Create tmp directory if it doesn't exist
    if [ ! -d "$tart_dir/tmp" ]; then
        log "Creating .tart/tmp directory..."
        mkdir -p "$tart_dir/tmp"
    fi
    
    # Fix ownership - need to fix the parent directory too
    log "Setting ownership to $real_user:staff..."
    if [ "$(stat -f '%Su' "$tart_dir")" != "$real_user" ]; then
        log "Fixing ownership of .tart directory (currently owned by $(stat -f '%Su' "$tart_dir"))"
        if command -v sudo >/dev/null 2>&1; then
            sudo chown -R "$real_user:staff" "$tart_dir"
        else
            chown -R "$real_user:staff" "$tart_dir"
        fi
    fi
    
    # Set proper permissions
    chmod -R 755 "$tart_dir"
    
    # Show final state
    log "Final .tart directory state:"
    ls -la "$tart_dir" || log "Directory doesn't exist or can't be read"
}

# Check if image exists in registry
image_exists_in_registry() {
    local image_url="$1"
    log "Checking if image exists: $image_url"
    
    # Fix permissions before trying to use tart
    fix_tart_permissions
    
    if tart pull "$image_url" 2>&1; then
        log "✅ Image found and pulled from registry"
        return 0
    else
        log "❌ Image not found in registry"
        return 1
    fi
}

# Cleanup old VM images to free storage space (UPDATED FOR MIXED NAMING CONVENTION)
cleanup_old_images() {
    log "=== STORAGE CLEANUP ==="
    log "🧹 Cleaning up old VM images to free storage space..."
    
    # Show current storage usage
    local tart_dir="$HOME/.tart"
    if [ -d "$tart_dir" ]; then
        local before_size=$(du -sh "$tart_dir" 2>/dev/null | cut -f1 || echo "unknown")
        log "📊 Current Tart storage usage: $before_size"
    fi
    
    # Get all local images
    local tart_output=$(tart list 2>&1)
    
    # Track images by macOS release and architecture combination
    # declare -A latest_images  # Key: "macos-arch", Value: "image_name|bun_version"
    # BASH 3.2 COMPATIBILITY: Use function-based associative array simulation
    assoc_clear  # Clear previous data
    local all_bun_images=()
    local images_to_keep=()
    local images_to_delete=()
    
    # Parse all bun-build-macos images
    while IFS= read -r line; do
        if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+) ]]; then
            local image_name="${BASH_REMATCH[1]}"
            
            # Only consider bun-build-macos images with mixed naming convention
            if [[ "$image_name" =~ ^bun-build-macos-[0-9]+-(arm64|x64)-[0-9]+\.[0-9]+\.[0-9]+-bootstrap-[0-9]+\.[0-9]+$ ]]; then
                all_bun_images+=("$image_name")
                
                # Parse image info
                local image_info=$(parse_image_name "$image_name")
                local macos_release="${image_info%%|*}"
                local remaining="${image_info#*|}"
                local arch="${remaining%%|*}"
                remaining="${remaining#*|}"
                local bun_version="${remaining%%|*}"
                local bootstrap_version="${remaining#*|}"
                
                log "  Found: $image_name"
                log "    macOS: $macos_release, Architecture: $arch, Bun: $bun_version, Bootstrap: $bootstrap_version"
                
                # Track the latest version for each macOS release + architecture combination
                local key="${macos_release}-${arch}"
                local current_latest=$(assoc_get "$key" 2>/dev/null || echo "")
                
                if [ -z "$current_latest" ]; then
                    # First image for this combination
                    assoc_set "$key" "$image_name|$bun_version"
                    log "    📌 First image for macOS $macos_release + $arch"
                else
                    # Compare versions
                    local current_version="${current_latest#*|}"
                    if version_compare "$bun_version" "$current_version"; then
                        # This version is newer
                        local old_image="${current_latest%|*}"
                        assoc_set "$key" "$image_name|$bun_version"
                        log "    📈 Newer version found: $bun_version > $current_version"
                        log "    🗑️  Will delete older: $old_image"
                        images_to_delete+=("$old_image")
                    else
                        # Current version is older
                        log "    📉 Older version: $bun_version <= $current_version"
                        log "    🗑️  Will delete this one: $image_name"
                        images_to_delete+=("$image_name")
                    fi
                fi
            fi
        fi
    done <<< "$tart_output"
    
    # Collect images to keep (the latest for each macOS release + architecture)
    while IFS= read -r key; do
        if [ -n "$key" ]; then
            local latest_info=$(assoc_get "$key")
            local image_name="${latest_info%|*}"
            local version="${latest_info#*|}"
        images_to_keep+=("$image_name")
        log "  📌 Keeping latest for $key: $image_name (version: $version)"
        fi
    done <<< "$(assoc_keys)"
    
    # Show what we found
    if [ ${#images_to_keep[@]} -gt 0 ]; then
        log "  📌 Keeping latest images:"
        for image in "${images_to_keep[@]}"; do
            log "    - $image"
        done
    else
        log "  📌 No bun-build-macos images found"
    fi
    
    # Delete old versions (keep latest for each macOS release + architecture)
    if [ ${#images_to_delete[@]} -gt 0 ]; then
        log "🗑️  Deleting ${#images_to_delete[@]} old VM images:"
        for image in "${images_to_delete[@]}"; do
            log "    Deleting: $image"
            if tart delete "$image" 2>/dev/null; then
                log "      ✅ Deleted successfully"
            else
                log "      ⚠️  Failed to delete (may not exist)"
            fi
        done
        log "✅ Cleanup completed"
    else
        log "✅ No old images to clean up (all images are latest for their macOS release + architecture)"
    fi
    
    # Show final storage state
    log "📊 Final VM storage state:"
    local final_output=$(tart list 2>&1)
    while IFS= read -r line; do
        if [[ "$line" =~ ^local.*bun-build-macos ]]; then
            log "    $line"
        fi
    done <<< "$final_output"
    
    # Show storage usage after cleanup
    if [ -d "$tart_dir" ]; then
        local after_size=$(du -sh "$tart_dir" 2>/dev/null | cut -f1 || echo "unknown")
        log "📊 Tart storage usage after cleanup: $after_size"
        if [ "$before_size" != "unknown" ] && [ "$after_size" != "unknown" ]; then
            log "💾 Storage cleanup summary: $before_size → $after_size"
        fi
    fi
    
    log "=== CLEANUP COMPLETE ==="
}

# Get Bun version - fixed version detection
get_bun_version() {
    local version=""
    
    # First try package.json - this is the authoritative source
    if [ -f "package.json" ]; then
        version=$(jq -r '.version // empty' package.json 2>/dev/null || true)
    fi
    
    # If no package.json, try CMakeLists.txt but look for the right pattern
    if [ -z "$version" ] && [ -f "CMakeLists.txt" ]; then
        # Look for project(Bun VERSION ...) or similar patterns
        version=$(grep -E "project\(.*VERSION\s+" CMakeLists.txt | sed -E 's/.*VERSION\s+([0-9]+\.[0-9]+\.[0-9]+).*/\1/' || true)
    fi
    
    # Fallback to git tags
    if [ -z "$version" ]; then
        version=$(git describe --tags --always --dirty 2>/dev/null | sed 's/^bun-v//' | sed 's/^v//' || echo "1.2.14")
    fi
    
    # Clean up version string
    version=${version#v}
    version=${version#bun-}
    
    # Validate version format
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        log "Warning: Invalid version format '$version', using fallback"
        version="1.2.14"
    fi
    
    echo "$version"
}

# Compare semantic versions (returns 0 if v1 >= v2, 1 if v1 < v2)
version_compare() {
    local v1="$1"
    local v2="$2"
    
    if [ "$v1" = "$v2" ]; then
        return 0
    fi
    
    # Split versions into arrays
    IFS='.' read -ra V1 <<< "$v1"
    IFS='.' read -ra V2 <<< "$v2"
    
    # Compare major.minor.patch
    for i in 0 1 2; do
        local n1=${V1[i]:-0}
        local n2=${V2[i]:-0}
        
        if [ "$n1" -gt "$n2" ]; then
            return 0  # v1 > v2
        elif [ "$n1" -lt "$n2" ]; then
            return 1  # v1 < v2
        fi
    done
    
    return 0  # Equal
}

# Check if two versions are compatible for incremental updates (same major.minor)
version_compatible() {
    local v1="$1"
    local v2="$2"
    
    # Split versions into arrays
    IFS='.' read -ra V1 <<< "$v1"
    IFS='.' read -ra V2 <<< "$v2"
    
    # Compare major.minor only
    local major1=${V1[0]:-0}
    local minor1=${V1[1]:-0}
    local major2=${V2[0]:-0}
    local minor2=${V2[1]:-0}
    
    [ "$major1" = "$major2" ] && [ "$minor1" = "$minor2" ]
}

# Get the minor version (e.g., "1.2" from "1.2.16")
get_minor_version() {
    local version="$1"
    echo "$version" | sed -E 's/^([0-9]+\.[0-9]+)\..*/\1/'
}

# Parse image name to extract all components (LOCAL VM FORMAT)
# LOCAL FORMAT: bun-build-macos-{MACOS_RELEASE}-{ARCH}-{BUN_VERSION}-bootstrap-{BOOTSTRAP_VERSION}
# Example: bun-build-macos-13-arm64-1.2.17-bootstrap-4.1
parse_image_name() {
    local image_name="$1"
    local macos_release=""
    local arch=""
    local bun_version=""
    local bootstrap_version=""
    
    # Extract all components from local image name
    # Format: bun-build-macos-{MACOS_RELEASE}-{ARCH}-{BUN_VERSION}-bootstrap-{BOOTSTRAP_VERSION}
    # Example: bun-build-macos-13-arm64-1.2.17-bootstrap-4.1
    if [[ "$image_name" =~ bun-build-macos-([0-9]+)-(arm64|x64)-([0-9]+\.[0-9]+\.[0-9]+)-bootstrap-([0-9]+\.[0-9]+) ]]; then
        macos_release="${BASH_REMATCH[1]}"     # First capture group: macOS release
        arch="${BASH_REMATCH[2]}"             # Second capture group: architecture  
        bun_version="${BASH_REMATCH[3]}"      # Third capture group: Bun version
        bootstrap_version="${BASH_REMATCH[4]}" # Fourth capture group: Bootstrap version
    fi
    
    # Return all components separated by pipes
    echo "$macos_release|$arch|$bun_version|$bootstrap_version"
}

# Parse registry image URL to extract components (REGISTRY FORMAT)
# REGISTRY FORMAT: registry/org/repo/bun-build-macos-{MACOS_RELEASE}-{ARCH}:{BUN_VERSION}-bootstrap-{BOOTSTRAP_VERSION}
# Example: ghcr.io/build-archetype/client-oven-sh-bun/bun-build-macos-13-arm64:1.2.17-bootstrap-4.1
parse_registry_url() {
    local registry_url="$1"
    local macos_release=""
    local arch=""
    local bun_version=""
    local bootstrap_version=""
    
    # Extract image name and tag from URL
    # Format: registry/org/repo/bun-build-macos-{MACOS_RELEASE}-{ARCH}:{BUN_VERSION}-bootstrap-{BOOTSTRAP_VERSION}
    if [[ "$registry_url" =~ bun-build-macos-([0-9]+)-(arm64|x64):([0-9]+\.[0-9]+\.[0-9]+)-bootstrap-([0-9]+\.[0-9]+) ]]; then
        macos_release="${BASH_REMATCH[1]}"     # macOS release from image name
        arch="${BASH_REMATCH[2]}"             # architecture from image name
        bun_version="${BASH_REMATCH[3]}"      # Bun version from tag
        bootstrap_version="${BASH_REMATCH[4]}" # Bootstrap version from tag
    fi
    
    # Return all components separated by pipes
    echo "$macos_release|$arch|$bun_version|$bootstrap_version"
}

# Check local images and categorize them (MIXED NAMING CONVENTION)
# Local VMs use full naming: bun-build-macos-{MACOS_RELEASE}-{ARCH}-{BUN_VERSION}-bootstrap-{BOOTSTRAP_VERSION}
# We can determine compatibility directly from the local VM names
check_local_image_version() {
    local target_bun_version="$1"
    local target_bootstrap_version="$2"
    local target_image_name="$3"
    
    log "🔍 Analyzing local images for target: $target_image_name" >&2
    
    # Get all local images
    local tart_output=$(tart list 2>&1)
    
    # Results
    local exact_match=""
    local compatible_images=()  # Same minor version (1.2.x) and compatible bootstrap
    local usable_images=()      # Same major version (1.x.x) and same architecture
    local all_bun_images=()
    
    # Parse target image info
    local target_info=$(parse_image_name "$target_image_name")
    local target_macos_release="${target_info%%|*}"
    local remaining="${target_info#*|}"
    local target_arch="${remaining%%|*}"
    remaining="${remaining#*|}"
    local target_bun="${remaining%%|*}"
    local target_bootstrap="${remaining#*|}"
    
    log "  Target: macOS $target_macos_release, Architecture: $target_arch, Bun: $target_bun, Bootstrap: $target_bootstrap" >&2
    
    # Parse each line for bun-build-macos images
    while IFS= read -r line; do
        if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+) ]]; then
            local image_name="${BASH_REMATCH[1]}"
            
            # Only consider bun-build-macos images with mixed naming convention
            if [[ "$image_name" =~ ^bun-build-macos-[0-9]+-(arm64|x64)-[0-9]+\.[0-9]+\.[0-9]+-bootstrap-[0-9]+\.[0-9]+$ ]]; then
                all_bun_images+=("$image_name")
                
                # Parse image info
                local image_info=$(parse_image_name "$image_name")
                local macos_release="${image_info%%|*}"
                local remaining="${image_info#*|}"
                local arch="${remaining%%|*}"
                remaining="${remaining#*|}"
                local bun_version="${remaining%%|*}"
                local bootstrap_version="${remaining#*|}"
                
                log "  Found: $image_name" >&2
                log "    macOS: $macos_release, Architecture: $arch, Bun: $bun_version, Bootstrap: $bootstrap_version" >&2
                
                # Check for exact match
                if [ "$image_name" = "$target_image_name" ]; then
                    exact_match="$image_name"
                    log "    ✅ Exact match found!" >&2
                # Check for compatible match (same architecture, compatible versions)
                elif [ "$arch" = "$target_arch" ]; then
                    # Check bootstrap compatibility first (must be same or newer)
                    if version_compare "$bootstrap_version" "$target_bootstrap_version"; then
                        # Check Bun version compatibility (same minor version is best)
                        if version_compatible "$bun_version" "$target_bun_version"; then
                            compatible_images+=("$image_name")
                            log "    🔄 Compatible match (same minor version, compatible bootstrap)" >&2
                        # Same major version can be used as base for incremental builds
                        elif [ "$(echo "$bun_version" | cut -d. -f1)" = "$(echo "$target_bun_version" | cut -d. -f1)" ]; then
                            usable_images+=("$image_name")
                            log "    🔧 Usable base (same architecture and major version)" >&2
                        else
                            log "    ⚠️  Different major version: $bun_version vs $target_bun_version" >&2
                        fi
                    else
                        log "    ❌ Bootstrap too old: $bootstrap_version < $target_bootstrap_version" >&2
                    fi
                else
                    log "    ❌ Incompatible architecture: $arch vs $target_arch" >&2
                fi
            fi
        fi
    done <<< "$tart_output"
    
    # Choose best compatible image (prefer newer versions)
    local best_compatible=""
    if [ ${#compatible_images[@]} -gt 0 ]; then
        # Sort compatible images and pick the latest version
        local latest_version="0.0.0"
        for img in "${compatible_images[@]}"; do
            local img_info=$(parse_image_name "$img")
            local img_bun_version=$(echo "$img_info" | cut -d'|' -f3)
            if version_compare "$img_bun_version" "$latest_version"; then
                best_compatible="$img"
                latest_version="$img_bun_version"
            fi
        done
        log "  🎯 Best compatible: $best_compatible (version: $latest_version)" >&2
    fi
    
    # Choose best usable image if no compatible ones
    local best_usable=""
    if [ -z "$best_compatible" ] && [ ${#usable_images[@]} -gt 0 ]; then
        # Sort usable images and pick the latest version
        local latest_version="0.0.0"
        for img in "${usable_images[@]}"; do
            local img_info=$(parse_image_name "$img")
            local img_bun_version=$(echo "$img_info" | cut -d'|' -f3)
            if version_compare "$img_bun_version" "$latest_version"; then
                best_usable="$img"
                latest_version="$img_bun_version"
            fi
        done
        log "  🔧 Best usable: $best_usable (version: $latest_version)" >&2
    fi
    
    # Return results (format: exact|compatible|usable|all)
    local compatible_list=""
    if [ -n "$best_compatible" ]; then
        compatible_list="$best_compatible"
    fi
    
    local usable_list=""
    if [ -n "$best_usable" ]; then
        usable_list="$best_usable"
    fi
    
    local all_list=""
    if [ ${#all_bun_images[@]} -gt 0 ]; then
        all_list=$(IFS=','; echo "${all_bun_images[*]}")
    fi
    
    echo "$exact_match|$compatible_list|$usable_list|$all_list"
}

# Check if remote image exists
check_remote_image() {
    local remote_url="$1"
    local force_remote_refresh="${2:-false}"
    log "🌐 Checking remote image: $remote_url" >&2
    
    # TEMPORARY: Skip remote check if authentication token looks like Buildkite token
    if [[ "${GITHUB_TOKEN:-}" =~ ^bkct_ ]]; then
        log "⚠️  Detected Buildkite token instead of GitHub token - skipping remote registry check" >&2
        log "   Buildkite tokens (bkct_*) cannot authenticate to GitHub Container Registry" >&2
        log "   Need GitHub token (ghp_* or gho_*) for registry access" >&2
        return 1
    fi
    
    # Fix permissions before trying to use tart (redirect output)
    fix_tart_permissions >&2
    
    # Extract the image name from the URL for local checking
    # URL format: ghcr.io/org/repo/image:tag
    local remote_image_name
    if [[ "$remote_url" =~ ([^/]+):([^:]+)$ ]]; then
        remote_image_name="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    else
        # Fallback parsing
        remote_image_name=$(basename "$remote_url")
    fi
    
    # Skip cache checking if force refresh is requested
    if [ "$force_remote_refresh" = "true" ]; then
        log "   Force remote refresh requested - skipping cache check" >&2
    else
        # First check if this remote image is already cached locally
        log "   Checking if remote image is already cached locally..." >&2
        local tart_output=$(tart list 2>&1)
        
        # Check for cached remote image
        if echo "$tart_output" | grep -q "^remote.*${remote_url}"; then
            log "✅ Remote image already cached locally - no download needed" >&2
            log "   Use --force-remote-refresh to force re-download latest version" >&2
            return 0
        fi
        
        # Also check if there's a local image with matching tag that might be from this remote
        local image_tag="${remote_url##*:}"
        if echo "$tart_output" | grep -q "remote.*${image_tag}"; then
            log "✅ Found cached remote image with matching tag - no download needed" >&2
            log "   Use --force-remote-refresh to force re-download latest version" >&2
            return 0
        fi
        
        log "   Remote image not found in local cache - downloading..." >&2
    fi
    
    # Set up registry authentication before pulling
    log "🔐 Setting up registry authentication..." >&2
    local auth_setup=false
    local original_username="${TART_REGISTRY_USERNAME:-}"
    local original_password="${TART_REGISTRY_PASSWORD:-}"
    
    # Load GitHub credentials using comprehensive method (non-interactive for registry checks)
    if load_github_credentials false false >/dev/null 2>&1; then
        log "   ✅ Registry authentication configured" >&2
        log "   Username: $GITHUB_USERNAME" >&2
        log "   Token: ${GITHUB_TOKEN:0:8}... (${#GITHUB_TOKEN} chars)" >&2
        auth_setup=true
    else
        log "   ⚠️  No credentials found - attempting unauthenticated pull" >&2
        auth_setup=false
    fi
    
    if [ "$auth_setup" = false ]; then
        log "   ⚠️  No credentials found - attempting unauthenticated pull" >&2
    else
        log "   ✅ Registry authentication configured" >&2
    fi
    
    # Not cached or force refresh - need to pull
    log "📥 Starting download of remote VM image (may be 5-15GB+, please wait)..." >&2
    
    # Run tart pull with proper error handling for authentication failures
    local pull_result=0
    local pull_output=""
    local pull_exit_code=0
    
    # Capture both output and exit code
    if pull_output=$(tart pull "$remote_url" 2>&1); then
        log "✅ Remote image found and downloaded successfully" >&2
        log "   Cached for future use - subsequent pulls will be instant" >&2
        pull_result=0
    else
        pull_exit_code=$?
        log "❌ Remote image download failed (exit code: $pull_exit_code)" >&2
        
        # Handle specific exit codes gracefully
        case $pull_exit_code in
            152)
                log "   ⚠️  Authentication failed (exit 152) - this is expected without GitHub credentials" >&2
                log "   Will fall back to building from OCI base images" >&2
                ;;
            125)
                log "   ⚠️  Registry access denied (exit 125) - this is expected for private repositories" >&2
                log "   Will fall back to building from OCI base images" >&2
                ;;
            *)
                log "   ⚠️  Download failed with exit code $pull_exit_code" >&2
        if [ "$auth_setup" = false ]; then
            log "   Possible causes:" >&2
            log "   - Image doesn't exist in registry" >&2
            log "   - Registry requires authentication (set GITHUB_TOKEN and GITHUB_USERNAME)" >&2
        else
            log "   Possible causes:" >&2
            log "   - Image doesn't exist in registry" >&2
            log "   - Authentication failed (check GITHUB_TOKEN permissions)" >&2
            log "   - Network connectivity issues" >&2
        fi
                ;;
        esac
        
        # Log the actual error output for debugging (only first few lines to avoid spam)
        if [ -n "$pull_output" ]; then
            log "   Error details:" >&2
            echo "$pull_output" | head -3 | while read -r line; do
                log "     $line" >&2
            done
        fi
        
        pull_result=1
    fi
    
    # Clean up authentication (restore original values if they existed)
    if [ "$auth_setup" = true ]; then
        if [ -n "$original_username" ]; then
            export TART_REGISTRY_USERNAME="$original_username"
        else
            unset TART_REGISTRY_USERNAME 2>/dev/null || true
        fi
        
        if [ -n "$original_password" ]; then
            export TART_REGISTRY_PASSWORD="$original_password"
        else
            unset TART_REGISTRY_PASSWORD 2>/dev/null || true
        fi
        log "   🧹 Registry authentication cleaned up" >&2
    fi
    
    return $pull_result
}

# Comprehensive VM validation that thoroughly checks if VM is ready for building
comprehensive_vm_validation() {
    local vm_name="$1"
    local validation_mode="${2:-normal}"  # normal or check-only
    
    log "🔬 Comprehensive VM validation: $vm_name"
    
    # Step 1: Validate VM structure and detect corruption
    log "   📁 Checking VM file structure..."
    local vm_path="$HOME/.tart/vms/${vm_name}"
    
    if [ ! -d "$vm_path" ]; then
        log "   ❌ VM directory missing: $vm_path"
        return 1
    fi
    
    # Check for essential VM files
    local config_file="$vm_path/config.json"
    local disk_file="$vm_path/disk.img"
    
    if [ ! -f "$config_file" ]; then
        log "   ❌ config.json missing - VM corrupted"
        return 1
    elif ! jq . "$config_file" >/dev/null 2>&1; then
        log "   ❌ config.json invalid JSON - VM corrupted"
        return 1
    elif [ ! -f "$disk_file" ]; then
        log "   ❌ disk.img missing - VM corrupted"
        return 1
    else
        log "   ✅ VM file structure valid"
    fi
    
    # Step 2: Start VM and validate connectivity
    log "   🚀 Starting VM for validation..."
    tart run "$vm_name" --no-graphics >/dev/null 2>&1 &
    local vm_pid=$!
    
    # Wait for VM to boot (increased timeout for reliability)
    sleep 20
    
    # Get VM IP with retries
    local vm_ip=""
    for i in {1..30}; do
        vm_ip=$(tart ip "$vm_name" 2>/dev/null || echo "")
        if [ -n "$vm_ip" ]; then
            log "   ✅ VM booted successfully (IP: $vm_ip)"
            break
        fi
        sleep 2
    done
    
    if [ -z "$vm_ip" ]; then
        log "   ❌ Could not get VM IP - VM failed to boot properly"
        kill $vm_pid >/dev/null 2>&1 || true
        return 1
    fi
    
    # Wait for SSH to be available with retries
    local ssh_ready=false
    for i in {1..30}; do
        if sshpass -p "admin" ssh $SSH_OPTS -o ConnectTimeout=3 admin@"$vm_ip" "echo 'ready'" >/dev/null 2>&1; then
            ssh_ready=true
            log "   ✅ SSH connectivity established"
            break
        fi
        sleep 2
    done
    
    if [ "$ssh_ready" != "true" ]; then
        log "   ❌ SSH not available - VM not responding to SSH"
        kill $vm_pid >/dev/null 2>&1 || true
        return 1
    fi
    
    # Step 3: Comprehensive tool validation and functionality testing
    log "   🔧 Running comprehensive tool validation..."
    local validation_cmd='
        # Comprehensive PATH setup for all common installation locations
        export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
        
        # Source shell profiles that might set additional PATH
        [ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile" 2>/dev/null || true
        [ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile" 2>/dev/null || true
        [ -f "$HOME/.profile" ] && source "$HOME/.profile" 2>/dev/null || true
        [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env" 2>/dev/null || true
        
        echo "=== COMPREHENSIVE VM VALIDATION ==="
        echo "Current PATH: $PATH"
        echo "Architecture: $(uname -m)"
        echo "macOS Version: $(sw_vers -productVersion)"
        echo ""
        
        missing_tools=""
        failed_tests=""
        
        # Function to test tool functionality
        test_tool() {
            local tool="$1"
            local test_cmd="$2"
            local expected_pattern="$3"
            
            if ! command -v "$tool" >/dev/null 2>&1; then
                echo "❌ $tool: NOT FOUND"
                missing_tools="$missing_tools $tool"
                return 1
            fi
            
            local tool_path=$(command -v "$tool")
            echo "🔍 $tool: found at $tool_path"
            
            # Test basic functionality
            if [ -n "$test_cmd" ]; then
                echo "   Testing: $test_cmd"
                local output
                if output=$(eval "$test_cmd" 2>&1); then
                    if [ -n "$expected_pattern" ]; then
                        if echo "$output" | grep -q "$expected_pattern"; then
                            echo "   ✅ $tool: functional test passed"
                            return 0
                        else
                            echo "   ❌ $tool: functional test failed - unexpected output"
                            echo "   Expected pattern: $expected_pattern"
                            echo "   Actual output: $output"
                            failed_tests="$failed_tests $tool"
                            return 1
                        fi
                    else
                        echo "   ✅ $tool: functional test passed"
                        return 0
                    fi
                else
                    echo "   ❌ $tool: functional test failed - command failed"
                    echo "   Error output: $output"
                    failed_tests="$failed_tests $tool"
                    return 1
                fi
            else
                echo "   ✅ $tool: presence verified"
                return 0
            fi
        }
        
        echo "🔧 Testing critical build tools..."
        
        # Test Bun with functionality check
        test_tool "bun" "bun --version" "[0-9]"
        
        # Test Rust toolchain
        test_tool "cargo" "cargo --version" "cargo [0-9]"
        test_tool "rustc" "rustc --version" "rustc [0-9]"
        
        # Test CMake
        test_tool "cmake" "cmake --version" "cmake version [0-9]"
        
        # Test Ninja with special diagnostics
        if ! command -v ninja >/dev/null 2>&1; then
            echo "❌ ninja: NOT FOUND"
            echo "   🔍 Ninja diagnostics:"
            echo "   Checking common ninja locations..."
            for ninja_path in /opt/homebrew/bin/ninja /usr/local/bin/ninja /usr/bin/ninja; do
                if [ -f "$ninja_path" ]; then
                    echo "   ✅ Found ninja file at: $ninja_path"
                    if [ -x "$ninja_path" ]; then
                        echo "   ✅ Ninja is executable"
                        version=$("$ninja_path" --version 2>/dev/null || echo "version check failed")
                        echo "   ✅ Ninja version: $version"
                        echo "   ⚠️  Ninja exists but not in PATH - PATH issue detected"
                    else
                        echo "   ❌ Ninja exists but is not executable"
                    fi
                else
                    echo "   ❌ Not found: $ninja_path"
                fi
            done
            
            # Check Homebrew ninja installation
            if command -v brew >/dev/null 2>&1; then
                echo "   🍺 Checking Homebrew ninja installation..."
                brew_info=$(brew list ninja 2>/dev/null || echo "not installed")
                echo "   Brew ninja status: $brew_info"
                
                if [ "$brew_info" != "not installed" ]; then
                    brew_prefix=$(brew --prefix 2>/dev/null || echo "unknown")
                    echo "   Brew prefix: $brew_prefix"
                    potential_ninja="$brew_prefix/bin/ninja"
                    if [ -f "$potential_ninja" ]; then
                        echo "   ✅ Found ninja via brew: $potential_ninja"
                        echo "   ⚠️  PATH issue - ninja installed but not accessible"
                    else
                        echo "   ❌ Expected ninja not found: $potential_ninja"
                    fi
                fi
            fi
            missing_tools="$missing_tools ninja"
        else
            test_tool "ninja" "ninja --version" "[0-9]"
        fi
        
        # Test C/C++ compilers
        test_tool "clang" "clang --version" "clang version"
        test_tool "clang++" "clang++ --version" "clang version"
        
        # Test codesigning tools (critical for Bun builds)
        test_tool "codesign" "codesign --version" ""
        test_tool "xcrun" "xcrun --version" "xcrun version"
        
        # Test SDK availability
        echo ""
        echo "🛠️  Testing SDK and development environment..."
        if command -v xcrun >/dev/null 2>&1; then
            sdk_path=$(xcrun --show-sdk-path 2>/dev/null || echo "FAILED")
            if [ "$sdk_path" != "FAILED" ] && [ -d "$sdk_path" ]; then
                echo "✅ SDK available: $sdk_path"
                
                # Test critical SDK components
                if [ -d "$sdk_path/usr/include" ] && [ -d "$sdk_path/usr/lib" ]; then
                    echo "✅ SDK components: headers and libraries present"
                else
                    echo "❌ SDK components: missing headers or libraries"
                    failed_tests="$failed_tests SDK"
                fi
            else
                echo "❌ SDK not accessible: $sdk_path"
                failed_tests="$failed_tests SDK"
            fi
        fi
        
        # Test basic compilation (critical test)
        echo ""
        echo "🏗️  Testing basic C++ compilation..."
        cat > /tmp/test_compile.cpp << "EOF"
#include <iostream>
int main() {
    std::cout << "Hello World" << std::endl;
    return 0;
}
EOF
        
        if clang++ -o /tmp/test_compile /tmp/test_compile.cpp 2>/dev/null; then
            if /tmp/test_compile 2>/dev/null | grep -q "Hello World"; then
                echo "✅ C++ compilation test: PASSED"
                rm -f /tmp/test_compile /tmp/test_compile.cpp
            else
                echo "❌ C++ compilation test: executable failed to run correctly"
                failed_tests="$failed_tests compilation"
            fi
        else
            echo "❌ C++ compilation test: FAILED to compile"
            failed_tests="$failed_tests compilation"
        fi
        
        # Test Bun compilation capability (most critical test)
        echo ""
        echo "🎯 Testing Bun build capability..."
        cat > /tmp/test_bun.js << "EOF"
console.log("Hello from Bun!");
EOF
        
        if bun build /tmp/test_bun.js --outfile /tmp/test_bun_built.js 2>/dev/null; then
            if [ -f /tmp/test_bun_built.js ]; then
                echo "✅ Bun build test: PASSED"
                rm -f /tmp/test_bun.js /tmp/test_bun_built.js
            else
                echo "❌ Bun build test: output file not created"
                failed_tests="$failed_tests bun-build"
            fi
        else
            echo "❌ Bun build test: FAILED"
            failed_tests="$failed_tests bun-build"
        fi
        
        echo ""
        echo "=== VALIDATION SUMMARY ==="
        if [ -n "$missing_tools" ]; then
            echo "❌ MISSING TOOLS:$missing_tools"
        fi
        if [ -n "$failed_tests" ]; then
            echo "❌ FAILED TESTS:$failed_tests"
        fi
        
        if [ -n "$missing_tools" ] || [ -n "$failed_tests" ]; then
            echo "VALIDATION_FAILED: VM not ready for building"
            exit 1
        else
            echo "VALIDATION_PASSED: VM ready for production builds"
            exit 0
        fi
    '
    
    local validation_result
    local validation_success=false
    if validation_result=$(sshpass -p "admin" ssh $SSH_OPTS admin@"$vm_ip" "$validation_cmd" 2>&1); then
        validation_success=true
    fi
    
    # Log validation output
    echo "$validation_result" | while read -r line; do
        log "   $line"
    done
    
    # Cleanup VM
    log "   🛑 Shutting down validation VM..."
    sshpass -p "admin" ssh $SSH_OPTS admin@"$vm_ip" "sudo shutdown -h now" >/dev/null 2>&1 || true
    sleep 10
    kill $vm_pid >/dev/null 2>&1 || true
    sleep 5
    
    if [ "$validation_success" = true ]; then
        log "   ✅ VM passed comprehensive validation - ready for building"
        return 0
    else
        log "   ❌ VM failed comprehensive validation - not ready for building"
        return 1
    fi
}

# Main execution
main() {
    # Parse arguments
    local force_refresh=false
    local cleanup_only=false
    local force_rebuild_all=false
    local force_remote_refresh=false
    local local_dev_mode=false
    local disable_autoupdate=false
    local update_bun_only=false
    local update_homebrew_only=false
    local check_only=false
    local force_oci_rebuild=false
    local ci_mode=false
    for arg in "$@"; do
        case $arg in
            --force-refresh)
                force_refresh=true
                shift
                ;;
            --force-oci-rebuild)
                force_oci_rebuild=true
                force_refresh=true  # Implies force refresh but skips remote registry
                shift
                ;;
            --force-remote-refresh)
                force_remote_refresh=true
                shift
                ;;
            --cleanup-only)
                cleanup_only=true
                shift
                ;;
            --check-only)
                check_only=true
                shift
                ;;
            --ci-mode)
                ci_mode=true
                shift
                ;;
            --force-rebuild-all)
                force_rebuild_all=true
                shift
                ;;
            --local-dev)
                local_dev_mode=true
                shift
                ;;
            --disable-autoupdate)
                disable_autoupdate=true
                shift
                ;;
            --update-bun-only)
                update_bun_only=true
                shift
                ;;
            --update-homebrew-only)
                update_homebrew_only=true
                shift
                ;;
            --release=*)
                MACOS_RELEASE="${arg#*=}"
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --force-refresh         Force refresh of base image"
                echo "  --force-oci-rebuild     Force rebuild from OCI base images (skip registry checks)"
                echo "  --force-remote-refresh  Force re-download of remote images (ignore cache)"
                echo "  --cleanup-only          Clean up old VM images and exit"
                echo "  --check-only            Check if base VM exists without building (exit 0 if exists, 1 if not)"
                echo "  --ci-mode               Enable CI mode (non-fatal failures, continue pipeline)"
                echo "  --local-dev             Enable local development mode (skip remote registry)"
                echo "  --force-rebuild-all     Delete all local VM images and rebuild from scratch"
                echo "  --disable-autoupdate    Disable version-based VM selection (use existing VMs)"
                echo "  --update-bun-only       Update only the Bun version"
                echo "  --update-homebrew-only  Update only the Homebrew version"
                echo "  --release=VERSION       macOS release version (13, 14) [default: 14]"
                echo "  --help, -h              Show this help message"
                echo ""
                echo "Local Development:"
                echo "  Use --local-dev to skip remote registry checks and work offline"
                echo "  This mode focuses on local image caching and base image reuse"
                echo ""
                echo "Caching Behavior:"
                echo "  • Local images are automatically cached and reused"
                echo "  • Remote images are checked and cached after first download"
                echo "  • Use --force-remote-refresh to get latest remote versions"
                echo "  • Use --force-refresh to skip all caching and rebuild"
                echo "  • Use --local-dev to skip remote registry entirely (offline mode)"
                echo "  • Use --disable-autoupdate to skip version checks (use existing VMs)"
                echo "  • VM validation ensures cached images have required tools"
                echo ""
                echo "Environment Variables:"
                echo "  MACOS_RELEASE       macOS release version (default: 14)"
                echo "  BOOTSTRAP_VERSION   Bootstrap script version (auto-detected from script)"
                echo "  BUN_VERSION         Bun version (auto-detected if not set)"
                echo "  REGISTRY            Container registry (default: ghcr.io)"
                echo "  ORGANIZATION        Organization name (default: build-archetype)"
                echo "  REPOSITORY          Repository name (default: client-oven-sh-bun)"
                echo "  GITHUB_TOKEN        GitHub token for registry authentication"
                echo "  GITHUB_USERNAME     GitHub username for registry authentication"
                echo ""
                echo "Examples:"
                echo "  $0                        # Build macOS 14 image (check local → remote → build)"
                echo "  $0 --local-dev            # Local development mode (skip remote registry)"
                echo "  $0 --release=13           # Build macOS 13 base image"
                echo "  $0 --force-refresh        # Force rebuild of base image"
                echo "  $0 --force-remote-refresh # Force re-download of remote images"
                echo "  $0 --force-rebuild-all    # Delete all local VMs and rebuild"
                echo "  $0 --cleanup-only         # Clean up old images and exit"
                echo "  $0 --disable-autoupdate   # Use existing VMs without version checks"
                echo "  $0 --update-bun-only      # Update only the Bun version"
                echo "  $0 --update-homebrew-only # Update only the Homebrew version"
                exit 0
                ;;
        esac
    done
    
    # Fix Tart permissions first thing
    fix_tart_permissions
    
    # === TEMPORARY INSTALLATION STEP ===
    # Add any temporary installations here before image operations
    log "=== TEMPORARY INSTALLATIONS ==="
    log "🔧 Running temporary installation steps..."
    
    # Check and install sshpass (required for VM SSH operations)
    log "Checking for sshpass..."
    if ! command -v sshpass >/dev/null 2>&1; then
        log "🔧 sshpass is required but not found - installing automatically..."
        
        # Try to use Homebrew to install sshpass
        if command -v brew >/dev/null 2>&1; then
            log "   Installing sshpass via Homebrew..."
            if brew install sshpass; then
                log "✅ sshpass installed successfully"
            else
                log "❌ Failed to install sshpass via Homebrew"
                log "   Please install sshpass manually:"
                log "   brew install sshpass"
                exit 1
            fi
        else
            log "❌ Homebrew not found - cannot auto-install sshpass"
            log "   Please install sshpass manually:"
            log "   1. Install Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            log "   2. Install sshpass: brew install sshpass"
            exit 1
        fi
        
        # Verify installation
        if ! command -v sshpass >/dev/null 2>&1; then
            log "❌ sshpass installation failed - still not available"
            exit 1
        fi
    else
        log "✅ sshpass is available"
    fi
    
    log "✅ Temporary installation steps completed"
    log "=== END TEMPORARY INSTALLATIONS ==="
    
    # Handle force rebuild all - delete all bun-build VMs
    if [ "$force_rebuild_all" = true ]; then
        log "=== FORCE REBUILD ALL ==="
        log "🗑️  Deleting all local bun-build VM images..."
        
        local tart_output=$(tart list 2>&1)
        local deleted_count=0
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+) ]]; then
                local image_name="${BASH_REMATCH[1]}"
                if [[ "$image_name" =~ ^bun-build- ]]; then
                    log "  Deleting: $image_name"
                    if tart delete "$image_name" 2>/dev/null; then
                        log "    ✅ Deleted successfully"
                        deleted_count=$((deleted_count + 1))
                    else
                        log "    ⚠️  Failed to delete (may not exist)"
                    fi
                fi
            fi
        done <<< "$tart_output"
        
        log "✅ Deleted $deleted_count VM images - will rebuild from scratch"
        log "=== END FORCE REBUILD ALL ==="
    fi
    
    # Clean up old VM images to free storage space (do this early!)
    cleanup_old_images
    
    # If cleanup-only requested, exit here
    if [ "$cleanup_only" = true ]; then
        log "✅ Cleanup-only mode complete - exiting"
        exit 0
    fi
    
    # Configuration - now uses the release parameter
    BASE_IMAGE=$(get_base_image "$MACOS_RELEASE")
    REGISTRY="ghcr.io"
    ORGANIZATION="${GITHUB_REPOSITORY_OWNER:-build-archetype}"
    
    # Get repository name, handling various cases
    if [ -n "${GITHUB_REPOSITORY:-}" ]; then
        REPOSITORY="${GITHUB_REPOSITORY##*/}"
    else
        # Fallback: get from git remote or use default
        REPOSITORY=$(git remote get-url origin 2>/dev/null | sed -E 's|.*/([^/]+)\.git$|\1|' || echo "client-oven-sh-bun")
    fi
    
    log "Repository detection:"
    log "  GITHUB_REPOSITORY: ${GITHUB_REPOSITORY:-<not set>}"
    log "  GITHUB_REPOSITORY_OWNER: ${GITHUB_REPOSITORY_OWNER:-<not set>}"
    log "  Detected repository: $REPOSITORY"
    
    # Get Bun version
    BUN_VERSION=$(get_bun_version)
    log "Detected Bun version: $BUN_VERSION"
    
    # Bootstrap script version - increment this when bootstrap changes to force new images
    BOOTSTRAP_VERSION=$(get_bootstrap_version scripts/bootstrap-macos.sh)
    log "Detected Bootstrap version: $BOOTSTRAP_VERSION"
    
    # Image names (mixed convention: local has full info, registry uses tags)
    # Local name: bun-build-macos-{MACOS_RELEASE}-{ARCH}-{BUN_VERSION}-bootstrap-{BOOTSTRAP_VERSION}
    # Registry base: registry/org/repo/bun-build-macos-{MACOS_RELEASE}-{ARCH}:{BUN_VERSION}-bootstrap-{BOOTSTRAP_VERSION}
    LOCAL_IMAGE_NAME="bun-build-macos-${MACOS_RELEASE}-${ARCH}-${BUN_VERSION}-bootstrap-${BOOTSTRAP_VERSION}"
    REMOTE_IMAGE_URL="${REGISTRY}/${ORGANIZATION}/${REPOSITORY}/bun-build-macos-${MACOS_RELEASE}-${ARCH}:${BUN_VERSION}-bootstrap-${BOOTSTRAP_VERSION}"
    LATEST_IMAGE_URL="${REGISTRY}/${ORGANIZATION}/${REPOSITORY}/bun-build-macos-${MACOS_RELEASE}-${ARCH}:latest"
    
    # Handle check-only mode - but with comprehensive validation
    if [ "$check_only" = true ]; then
        log "=== CHECK-ONLY MODE ==="
        log "🔍 Checking if base VM exists and is ready: $LOCAL_IMAGE_NAME"
        
        # Check if the exact VM exists locally
        if tart list 2>/dev/null | grep -q "^local.*$LOCAL_IMAGE_NAME"; then
            log "✅ Base VM exists: $LOCAL_IMAGE_NAME"
            log "🔬 Running comprehensive validation to ensure VM is ready for building..."
            
            # Use the same validation logic as the build mode
            # Validate VM structure and detect corruption
            local vm_path="$HOME/.tart/vms/${LOCAL_IMAGE_NAME}"
            local corruption_detected=false
            
            if [ -d "$vm_path" ]; then
                # Check for essential VM files
                local config_file="$vm_path/config.json"
                local disk_file="$vm_path/disk.img"
                
                if [ ! -f "$config_file" ]; then
                    log "   ❌ config.json missing - VM corrupted"
                    corruption_detected=true
                elif ! jq . "$config_file" >/dev/null 2>&1; then
                    log "   ❌ config.json invalid JSON - VM corrupted"
                    corruption_detected=true
                elif [ ! -f "$disk_file" ]; then
                    log "   ❌ disk.img missing - VM corrupted"
                    corruption_detected=true
                else
                    log "   ✅ VM structure appears valid"
                fi
            else
                log "   ❌ VM directory missing - metadata corruption"
                corruption_detected=true
            fi
            
            if [ "$corruption_detected" = true ]; then
                log "❌ VM is corrupted and not ready for building"
                exit 1
            fi
            
            # Now run comprehensive dependency validation
            log "   Starting VM for comprehensive dependency validation..."
            tart run "$LOCAL_IMAGE_NAME" --no-graphics >/dev/null 2>&1 &
            local vm_pid=$!
            
            # Wait for VM to boot
            sleep 20
            
            # Get VM IP
            local vm_ip=""
            for i in {1..30}; do
                vm_ip=$(tart ip "$LOCAL_IMAGE_NAME" 2>/dev/null || echo "")
                if [ -n "$vm_ip" ]; then
                    break
                fi
                sleep 3
            done
            
            if [ -z "$vm_ip" ]; then
                log "   ❌ Could not get VM IP - VM failed to boot properly"
                kill $vm_pid >/dev/null 2>&1 || true
                log "❌ VM is not ready for building"
                exit 1
            fi
            
            # Wait for SSH to be available
            local ssh_ready=false
            for i in {1..30}; do
                if sshpass -p "admin" ssh $SSH_OPTS -o ConnectTimeout=3 admin@"$vm_ip" "echo 'ready'" >/dev/null 2>&1; then
                    ssh_ready=true
                    break
                fi
                sleep 3
            done
            
            if [ "$ssh_ready" != "true" ]; then
                log "   ❌ SSH not available - VM not responding properly"
                kill $vm_pid >/dev/null 2>&1 || true
                log "❌ VM is not ready for building"
                exit 1
            fi
            
            log "   ✅ VM booted and SSH ready (IP: $vm_ip)"
            log "   🔧 Running comprehensive tool and functionality validation..."
            
            # Comprehensive validation (same as build mode)
            local validation_cmd='
                # Comprehensive PATH setup for all common installation locations
                export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
                
                # Source shell profiles that might set additional PATH
                [ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile" 2>/dev/null || true
                [ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile" 2>/dev/null || true
                [ -f "$HOME/.profile" ] && source "$HOME/.profile" 2>/dev/null || true
                [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env" 2>/dev/null || true
                
                echo "=== COMPREHENSIVE VM VALIDATION (CHECK-ONLY MODE) ==="
                echo "Current PATH: $PATH"
                echo "Architecture: $(uname -m)"
                echo "macOS Version: $(sw_vers -productVersion)"
                echo ""
                
                missing_tools=""
                failed_tests=""
                
                echo "🔧 Testing critical build tools..."
                
                # Test Bun with functionality check
                if ! command -v bun >/dev/null 2>&1; then
                    echo "❌ bun: NOT FOUND"
                    missing_tools="$missing_tools bun"
                else
                    echo "🔍 bun: found at $(command -v bun)"
                    if bun_output=$(bun --version 2>&1) && echo "$bun_output" | grep -q "[0-9]"; then
                        echo "   ✅ bun: functional test passed (version: $bun_output)"
                    else
                        echo "   ❌ bun: functional test failed"
                        failed_tests="$failed_tests bun"
                    fi
                fi
                
                # Test Rust toolchain
                for tool in cargo rustc; do
                    if ! command -v "$tool" >/dev/null 2>&1; then
                        echo "❌ $tool: NOT FOUND"
                        missing_tools="$missing_tools $tool"
                    else
                        echo "🔍 $tool: found at $(command -v $tool)"
                        if output=$($tool --version 2>&1) && echo "$output" | grep -q "[0-9]"; then
                            echo "   ✅ $tool: functional test passed"
                        else
                            echo "   ❌ $tool: functional test failed"
                            failed_tests="$failed_tests $tool"
                        fi
                    fi
                done
                
                # Test CMake
                if ! command -v cmake >/dev/null 2>&1; then
                    echo "❌ cmake: NOT FOUND"
                    missing_tools="$missing_tools cmake"
                else
                    echo "🔍 cmake: found at $(command -v cmake)"
                    if cmake_output=$(cmake --version 2>&1) && echo "$cmake_output" | grep -q "cmake version"; then
                        echo "   ✅ cmake: functional test passed"
                    else
                        echo "   ❌ cmake: functional test failed"
                        failed_tests="$failed_tests cmake"
                    fi
                fi
                
                # Test Ninja with special diagnostics
                if ! command -v ninja >/dev/null 2>&1; then
                    echo "❌ ninja: NOT FOUND"
                    echo "   🔍 Ninja diagnostics:"
                    for ninja_path in /opt/homebrew/bin/ninja /usr/local/bin/ninja /usr/bin/ninja; do
                        if [ -f "$ninja_path" ]; then
                            echo "   ✅ Found ninja file at: $ninja_path"
                            if [ -x "$ninja_path" ]; then
                                version=$("$ninja_path" --version 2>/dev/null || echo "version check failed")
                                echo "   ✅ Ninja is executable (version: $version)"
                                echo "   ⚠️  PATH issue - ninja exists but not in PATH"
                            else
                                echo "   ❌ Ninja exists but is not executable"
                            fi
                        else
                            echo "   ❌ Not found: $ninja_path"
                        fi
                    done
                    missing_tools="$missing_tools ninja"
                else
                    echo "🔍 ninja: found at $(command -v ninja)"
                    if ninja_output=$(ninja --version 2>&1) && echo "$ninja_output" | grep -q "[0-9]"; then
                        echo "   ✅ ninja: functional test passed (version: $ninja_output)"
                    else
                        echo "   ❌ ninja: functional test failed"
                        failed_tests="$failed_tests ninja"
                    fi
                fi
                
                # Test C/C++ compilers
                for tool in clang clang++; do
                    if ! command -v "$tool" >/dev/null 2>&1; then
                        echo "❌ $tool: NOT FOUND"
                        missing_tools="$missing_tools $tool"
                    else
                        echo "🔍 $tool: found at $(command -v $tool)"
                        if output=$($tool --version 2>&1) && echo "$output" | grep -q "clang version"; then
                            echo "   ✅ $tool: functional test passed"
                        else
                            echo "   ❌ $tool: functional test failed"
                            failed_tests="$failed_tests $tool"
                        fi
                    fi
                done
                
                # Test codesigning tools (critical for Bun builds)
                for tool in codesign xcrun; do
                    if ! command -v "$tool" >/dev/null 2>&1; then
                        echo "❌ $tool: NOT FOUND"
                        missing_tools="$missing_tools $tool"
                    else
                        echo "✅ $tool: available at $(command -v $tool)"
                    fi
                done
                
                # Test SDK availability
                echo ""
                echo "🛠️  Testing SDK and development environment..."
                if command -v xcrun >/dev/null 2>&1; then
                    sdk_path=$(xcrun --show-sdk-path 2>/dev/null || echo "FAILED")
                    if [ "$sdk_path" != "FAILED" ] && [ -d "$sdk_path" ]; then
                        echo "✅ SDK available: $sdk_path"
                        if [ -d "$sdk_path/usr/include" ] && [ -d "$sdk_path/usr/lib" ]; then
                            echo "✅ SDK components: headers and libraries present"
                        else
                            echo "❌ SDK components: missing headers or libraries"
                            failed_tests="$failed_tests SDK"
                        fi
                    else
                        echo "❌ SDK not accessible: $sdk_path"
                        failed_tests="$failed_tests SDK"
                    fi
                fi
                
                # Test basic compilation (critical test)
                echo ""
                echo "🏗️  Testing basic C++ compilation..."
                cat > /tmp/test_compile.cpp << "EOF"
#include <iostream>
int main() {
    std::cout << "Hello World" << std::endl;
    return 0;
}
EOF
                
                if clang++ -o /tmp/test_compile /tmp/test_compile.cpp 2>/dev/null; then
                    if /tmp/test_compile 2>/dev/null | grep -q "Hello World"; then
                        echo "✅ C++ compilation test: PASSED"
                        rm -f /tmp/test_compile /tmp/test_compile.cpp
                    else
                        echo "❌ C++ compilation test: executable failed to run correctly"
                        failed_tests="$failed_tests compilation"
                    fi
                else
                    echo "❌ C++ compilation test: FAILED to compile"
                    failed_tests="$failed_tests compilation"
                fi
                
                # Test Bun compilation capability (most critical test)
                echo ""
                echo "🎯 Testing Bun build capability..."
                cat > /tmp/test_bun.js << "EOF"
console.log("Hello from Bun!");
EOF
                
                if bun build /tmp/test_bun.js --outfile /tmp/test_bun_built.js 2>/dev/null; then
                    if [ -f /tmp/test_bun_built.js ]; then
                        echo "✅ Bun build test: PASSED"
                        rm -f /tmp/test_bun.js /tmp/test_bun_built.js
                    else
                        echo "❌ Bun build test: output file not created"
                        failed_tests="$failed_tests bun-build"
                    fi
                else
                    echo "❌ Bun build test: FAILED"
                    failed_tests="$failed_tests bun-build"
                fi
                
                echo ""
                echo "=== VALIDATION SUMMARY ==="
                if [ -n "$missing_tools" ]; then
                    echo "❌ MISSING TOOLS:$missing_tools"
                fi
                if [ -n "$failed_tests" ]; then
                    echo "❌ FAILED TESTS:$failed_tests"
                fi
                
                if [ -n "$missing_tools" ] || [ -n "$failed_tests" ]; then
                    echo "VALIDATION_FAILED: VM not ready for building"
                    exit 1
                else
                    echo "VALIDATION_PASSED: VM ready for production builds"
                    exit 0
                fi
            '
            
            local validation_result
            local validation_success=false
            if validation_result=$(sshpass -p "admin" ssh $SSH_OPTS admin@"$vm_ip" "$validation_cmd" 2>&1); then
                validation_success=true
            fi
            
            # Log validation output
            echo "$validation_result" | while read -r line; do
                log "   $line"
            done
            
            # Cleanup VM
            log "   🛑 Shutting down validation VM..."
            sshpass -p "admin" ssh $SSH_OPTS admin@"$vm_ip" "sudo shutdown -h now" >/dev/null 2>&1 || true
            sleep 10
            kill $vm_pid >/dev/null 2>&1 || true
            sleep 5
            
            if [ "$validation_success" = true ]; then
                log "✅ VM passed comprehensive validation - ready for building"
                log "🎯 Base VM is ready for cloning: $LOCAL_IMAGE_NAME"
                exit 0
            else
                log "❌ VM failed comprehensive validation - not ready for building"
                log "🔧 VM exists but is missing tools or has broken dependencies"
                log "   Run without --check-only to rebuild and fix the VM"
                exit 1
            fi
        else
            log "❌ Base VM does not exist: $LOCAL_IMAGE_NAME"
            log "   Available VMs:"
            tart list | grep -E "bun-build-macos" || log "   (no bun-build-macos VMs found)"
            log "   Run without --check-only to build the VM"
            exit 1
        fi
    fi
    
    # If we reach here, VM doesn't exist or failed validation - need to build
    
    # Step 2: Check remote registry (skip if force OCI rebuild requested)
    if [ "$force_oci_rebuild" = true ]; then
        log "🔄 Force OCI rebuild requested - skipping registry checks"
        log "   Will build directly from OCI base image: $BASE_IMAGE"
    else
        log "🌐 Checking remote registry..."
        # Use error handling to gracefully fall back to local build if registry fails
        set +e  # Temporarily disable exit on error
        if check_remote_image "$REMOTE_IMAGE_URL" "$force_remote_refresh"; then
            set -e  # Re-enable exit on error
            log "📥 Using remote image: $REMOTE_IMAGE_URL"
            tart delete "$LOCAL_IMAGE_NAME" 2>/dev/null || true
            tart clone "$REMOTE_IMAGE_URL" "$LOCAL_IMAGE_NAME"
            log "✅ Remote image cloned as: $LOCAL_IMAGE_NAME"
        exit 0
        else
            set -e  # Re-enable exit on error
            log "⚠️  Remote registry check failed - will build locally"
        fi
    fi
    
    # Step 3: Use latest available local VM as base and update it
    log "🔍 Looking for latest local VM to use as base..."
    local latest_local=""
    local tart_output=$(tart list 2>&1)
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+) ]]; then
            local vm_name="${BASH_REMATCH[1]}"
            if [[ "$vm_name" =~ ^bun-build-macos-${MACOS_RELEASE} ]]; then
                latest_local="$vm_name"
            break
        fi
        fi
    done <<< "$tart_output"
    
    if [ -n "$latest_local" ]; then
        log "🔄 Found local VM to use as base: $latest_local"
        log "   Cloning and updating to target version: $LOCAL_IMAGE_NAME"
        
        # Clone the base VM to target name
        if tart clone "$latest_local" "$LOCAL_IMAGE_NAME"; then
            log "✅ Base VM cloned to: $LOCAL_IMAGE_NAME"
            log "🔧 Running bootstrap script to update Bun version and configuration..."
    
            # Start the VM for bootstrapping
            log "   Starting VM for bootstrap..."
            tart run "$LOCAL_IMAGE_NAME" --no-graphics >/dev/null 2>&1 &
            local vm_pid=$!
            
            # Wait for VM to boot
            sleep 10
    
            # Get VM IP
            local vm_ip=""
            for i in {1..20}; do
                vm_ip=$(tart ip "$LOCAL_IMAGE_NAME" 2>/dev/null || echo "")
                if [ -n "$vm_ip" ]; then
                    break
                fi
                sleep 3
            done
    
            if [ -z "$vm_ip" ]; then
                log "❌ Could not get VM IP for bootstrap"
                kill $vm_pid >/dev/null 2>&1 || true
                if [ "$ci_mode" = true ]; then
                    log "🚧 CI Mode: Bootstrap failed but continuing pipeline"
                    exit 0  # Non-fatal in CI mode
                else
                    exit 1
                fi
    fi

            # Wait for SSH to be available
            local ssh_ready=false
            for i in {1..20}; do
                if sshpass -p "admin" ssh $SSH_OPTS -o ConnectTimeout=3 admin@"$vm_ip" "echo 'ready'" >/dev/null 2>&1; then
                    ssh_ready=true
                    break
                fi
                sleep 3
            done
        
            if [ "$ssh_ready" != "true" ]; then
                log "❌ SSH not available for bootstrap"
                kill $vm_pid >/dev/null 2>&1 || true
                if [ "$ci_mode" = true ]; then
                    log "🚧 CI Mode: SSH connection failed but continuing pipeline"
                    exit 0  # Non-fatal in CI mode
                else
                    exit 1
                fi
            fi

            log "✅ VM ready for bootstrap (IP: $vm_ip)"
            
            # Copy bootstrap script to VM
            log "   Copying bootstrap script to VM..."
            if ! sshpass -p "admin" scp $SSH_OPTS scripts/bootstrap-macos.sh admin@"$vm_ip":/tmp/; then
                log "❌ Failed to copy bootstrap script"
                kill $vm_pid >/dev/null 2>&1 || true
                if [ "$ci_mode" = true ]; then
                    log "🚧 CI Mode: Bootstrap script copy failed but continuing pipeline"
                    exit 0  # Non-fatal in CI mode
                else
                    exit 1
                fi
            fi
            
            # Run bootstrap script inside VM
            log "   Executing bootstrap script inside VM..."
            local bootstrap_cmd='
                cd /tmp && \
                chmod +x bootstrap-macos.sh && \
                ./bootstrap-macos.sh
            '
            
            if sshpass -p "admin" ssh $SSH_OPTS admin@"$vm_ip" "$bootstrap_cmd"; then
                log "✅ Bootstrap completed successfully"
            else
                log "⚠️  Bootstrap script had issues but continuing..."
            fi
            
            # Shutdown VM gracefully
            log "   Shutting down VM..."
            sshpass -p "admin" ssh $SSH_OPTS admin@"$vm_ip" "sudo shutdown -h now" >/dev/null 2>&1 || true
            
            # Wait for VM to stop
            sleep 10
            
            # Force kill if still running
            kill $vm_pid >/dev/null 2>&1 || true
            
            # Wait for complete cleanup
            sleep 5
            
            log "✅ VM updated and ready: $LOCAL_IMAGE_NAME"
            exit 0
        else
            log "❌ Failed to clone base VM"
            # Continue to step 4 (OCI build)
        fi
    fi
        
    # Step 4: Build from OCI base images
    log "🏗️  No local VMs found - building from OCI base image..."
    log "   Base image: $BASE_IMAGE"
    log "   Target: $LOCAL_IMAGE_NAME"
    
    # Clone from OCI base with error handling
    set +e  # Temporarily disable exit on error for better error messages
    if tart clone "$BASE_IMAGE" "$LOCAL_IMAGE_NAME" 2>&1; then
        set -e  # Re-enable exit on error
        log "✅ VM built from OCI base: $LOCAL_IMAGE_NAME"
    else
        local clone_exit_code=$?
        set -e  # Re-enable exit on error
        log "❌ Failed to build from OCI base image (exit code: $clone_exit_code)"
        log "   Base image: $BASE_IMAGE"
        log "   This may indicate:"
        log "   - Network connectivity issues"
        log "   - Base image not available"
        log "   - Insufficient disk space"
        
        if [ "$ci_mode" = true ]; then
            log "🚧 CI Mode: VM build failed but continuing pipeline"
            log "   Machine: $(hostname)"
            log "   This machine will not have the VM image available"
            log "   Other machines in the cluster may still succeed"
            log "   CI pipeline will continue with available resources"
            exit 0  # Non-fatal in CI mode
        else
            exit 1  # Fatal in normal mode
        fi
    fi
    
    log "✅ Bootstrap completed successfully"

    # Step 5: Try to push to registry (but don't fail if this doesn't work)
    log "=== REGISTRY PUSH ATTEMPT ==="
    set +e  # Disable error handling for entire registry section

    # Load GitHub credentials using comprehensive method
    log "🔐 Setting up GitHub authentication for registry push..."
    local creds_loaded=false
    if load_github_credentials false true; then
        creds_loaded=true
        log "✅ GitHub authentication configured"
        log "   Username: $GITHUB_USERNAME"
        log "   Token: ${GITHUB_TOKEN:0:8}... (${#GITHUB_TOKEN} chars)"
    else
        log "⚠️  No GitHub credentials available"
        log "   Registry push will be attempted without authentication"
        log "   This may fail for private repositories or when pushing images"
    fi

    if [ "$creds_loaded" = true ]; then
        log "Attempting to push to registry with credentials..."
        
        log "Registry URLs:"
        log "  Primary: $REMOTE_IMAGE_URL"
        log "  Latest:  $LATEST_IMAGE_URL"
        
        # Try to push primary tag
        log "Pushing primary tag..."
        if tart push "$LOCAL_IMAGE_NAME" "$REMOTE_IMAGE_URL" 2>&1; then
            log "✅ Primary push successful"
            
            # Try to push latest tag
            log "Pushing latest tag..."
            if tart push "$LOCAL_IMAGE_NAME" "$LATEST_IMAGE_URL" 2>&1; then
                log "✅ Latest push successful"
            else
                log "⚠️  Latest push failed (non-fatal)"
            fi
            
            log "✅ Registry push completed successfully!"
        else
            log "⚠️  Primary push failed (non-fatal)"
            log "     This is normal if:"
            log "     - Registry authentication failed"
            log "     - Network issues occurred"
            log "     - Registry is read-only"
            log "     The build will continue normally."
        fi
        
        # Clean up environment variables (with error handling)
        unset TART_REGISTRY_USERNAME 2>/dev/null || true
        unset TART_REGISTRY_PASSWORD 2>/dev/null || true
    else
        log "⚠️  Skipping registry push - no credentials available"
        log "     This is normal for:"
        log "     - Local development builds"
        log "     - Forks without push access"
        log "     - Machines not yet configured with credentials"
        log "     The build will continue normally."
    fi

    set -e  # Re-enable strict error handling
    log "=== REGISTRY PUSH SECTION COMPLETE ==="
    
    log "✅ Base image ready: $LOCAL_IMAGE_NAME"
    log "Available images:"
    tart list
}

# Detect architecture
get_architecture() {
    local arch="$(uname -m)"
    case "$arch" in
        arm64|aarch64)
            echo "arm64"
            ;;
        x86_64|x64|amd64)
            echo "x64"
            ;;
        *)
            log "❌ Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

# Architecture for this build
ARCH="$(get_architecture)"

# Base image to clone for new VM images
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/cirruslabs/macos-sonoma-xcode:latest}"

main "$@" 