#!/bin/bash
set -euo pipefail

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
MACOS_RELEASE="${MACOS_RELEASE:-14}"
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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

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
    declare -A latest_images  # Key: "macos-arch", Value: "image_name|bun_version"
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
                local current_latest="${latest_images[$key]:-}"
                
                if [ -z "$current_latest" ]; then
                    # First image for this combination
                    latest_images[$key]="$image_name|$bun_version"
                    log "    📌 First image for macOS $macos_release + $arch"
                else
                    # Compare versions
                    local current_version="${current_latest#*|}"
                    if version_compare "$bun_version" "$current_version"; then
                        # This version is newer
                        local old_image="${current_latest%|*}"
                        latest_images[$key]="$image_name|$bun_version"
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
    for key in "${!latest_images[@]}"; do
        local image_name="${latest_images[$key]%|*}"
        local version="${latest_images[$key]#*|}"
        images_to_keep+=("$image_name")
        log "  📌 Keeping latest for $key: $image_name (version: $version)"
    done
    
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
    
    # Run tart pull directly to show native progress output (percentages, etc.)
    # Redirect to stderr to prevent pollution of decision output
    local pull_result=0
    if tart pull "$remote_url" > /dev/stderr 2>&1; then
        log "✅ Remote image found and downloaded successfully" >&2
        log "   Cached for future use - subsequent pulls will be instant" >&2
        pull_result=0
    else
        log "❌ Remote image not found or download failed" >&2
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

# Validate that a VM image has all required tools installed
validate_vm_image_tools() {
    local image_name="$1"
    log "🔬 Validating tools in VM image: $image_name" >&2
    
    # Start the VM temporarily for validation (redirect all output to stderr)
    log "   Starting VM for validation..." >&2
    tart run "$image_name" --no-graphics >/dev/null 2>&1 &
    local vm_pid=$!
    
    # Wait for VM to boot (reduced from 30s to 2s - modern VMs boot faster)
    sleep 2
    
    # Get VM IP (redirect stderr to avoid pollution)
    local vm_ip=""
    for i in {1..10}; do
        vm_ip=$(tart ip "$image_name" 2>/dev/null || echo "")
        if [ -n "$vm_ip" ]; then
            break
        fi
        sleep 2
    done
    
    if [ -z "$vm_ip" ]; then
        log "   ❌ Could not get VM IP for validation" >&2
        # Cleanup with output redirection
        kill $vm_pid >/dev/null 2>&1 || true
        return 1
    fi
    
    # Wait for SSH to be available
    local ssh_ready=false
    for i in {1..10}; do
        if sshpass -p "admin" ssh $SSH_OPTS -o ConnectTimeout=2 admin@"$vm_ip" "echo 'test'" >/dev/null 2>&1; then
            ssh_ready=true
            break
        fi
        sleep 2
    done
    
    if [ "$ssh_ready" != "true" ]; then
        log "   ❌ SSH not available for validation" >&2
        # Cleanup with output redirection
        kill $vm_pid >/dev/null 2>&1 || true
        return 1
    fi
    
    # Check critical tools
    log "   Checking critical tools..." >&2
    local validation_cmd='
        export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
        
        echo "=== TOOL VALIDATION ==="
        missing_tools=""
        
        # Check bun (most critical)
        if command -v bun >/dev/null 2>&1; then
            echo "✅ bun: $(bun --version)"
        else
            echo "❌ bun: MISSING"
            missing_tools="$missing_tools bun"
        fi
        
        # Check other critical tools
        for tool in cargo cmake clang ninja; do
            if command -v "$tool" >/dev/null 2>&1; then
                echo "✅ $tool: available"
            else
                echo "❌ $tool: MISSING"
                missing_tools="$missing_tools $tool"
            fi
        done
        
        echo "======================="
        echo ""
        echo "=== CODESIGNING ENVIRONMENT CHECK ==="
        echo "Verifying codesigning tools and SDK for Mach-O generation..."
        
        # Check codesigning tools
        echo "🔐 Codesigning Tools:"
        codesign_missing=""
        for tool in codesign xcrun; do
            if command -v "$tool" >/dev/null 2>&1; then
                echo "  ✅ $tool: available"
            else
                echo "  ❌ $tool: MISSING"
                codesign_missing="$codesign_missing $tool"
            fi
        done
        
        # Check SDK availability
        echo ""
        echo "📱 SDK Check:"
        if command -v xcrun >/dev/null 2>&1; then
            sdk_path=$(xcrun --show-sdk-path 2>/dev/null || echo "FAILED")
            if [ "$sdk_path" != "FAILED" ] && [ -d "$sdk_path" ]; then
                echo "  ✅ SDK path: $sdk_path"
                
                # Check key SDK components
                if [ -d "$sdk_path/usr/include" ] && [ -d "$sdk_path/usr/lib" ]; then
                    echo "  ✅ SDK components: headers and libraries present"
                else
                    echo "  ⚠️  SDK components: missing headers or libraries"
                fi
            else
                echo "  ❌ SDK path: not accessible or missing"
                codesign_missing="$codesign_missing SDK"
            fi
        else
            echo "  ❌ xcrun: not available for SDK detection"
            codesign_missing="$codesign_missing xcrun"
        fi
        
        # Check Xcode tools
        echo ""
        echo "🛠️  Developer Tools:"
        if command -v xcode-select >/dev/null 2>&1; then
            xcode_path=$(xcode-select -p 2>/dev/null || echo "NOT SET")
            if [ -d "$xcode_path" ]; then
                echo "  ✅ Xcode developer path: $xcode_path"
            else
                echo "  ❌ Xcode developer path: invalid or missing"
                codesign_missing="$codesign_missing xcode-select"
            fi
        else
            echo "  ❌ xcode-select: not available"
            codesign_missing="$codesign_missing xcode-select"
        fi
        
        echo "============================================"
        
        # Return status
        if [ -n "$missing_tools" ]; then
            echo "VALIDATION_FAILED: Missing tools:$missing_tools"
            exit 1
        elif [ -n "$codesign_missing" ]; then
            echo "VALIDATION_FAILED: Missing codesigning tools:$codesign_missing"
            exit 1
        else
            echo "VALIDATION_PASSED: All critical tools and codesigning environment ready"
            exit 0
        fi
    '
    
    local validation_result
    local validation_success=false
    if validation_result=$(sshpass -p "admin" ssh $SSH_OPTS admin@"$vm_ip" "$validation_cmd" 2>&1); then
        validation_success=true
    fi
    
    # Log validation output (to stderr to avoid pollution)
    echo "$validation_result" | while read -r line; do
        log "   $line" >&2
    done
    
    # Cleanup VM with proper output redirection to prevent pollution
    log "   Shutting down validation VM..." >&2
    
    # Try graceful shutdown first (redirect all output)
    sshpass -p "admin" ssh $SSH_OPTS admin@"$vm_ip" "sudo shutdown -h now" >/dev/null 2>&1 || true
    
    # Wait for VM to stop (reduced from 30s to 2s)
    sleep 2
    
    # Force kill if still running (redirect all output)
    kill $vm_pid >/dev/null 2>&1 || true
    
    # Wait for complete cleanup (reduced from 5s to 2s)
    sleep 2
    
    if [ "$validation_success" = "true" ]; then
        log "   ✅ VM image validation passed - tools and codesigning environment ready" >&2
        return 0
    else
        log "   ❌ VM image validation failed - missing tools or codesigning environment" >&2
        return 1
    fi
}

# Enhanced caching decision that includes tool validation
make_caching_decision() {
    local target_bun_version="$1"
    local target_bootstrap_version="$2"
    local target_image_name="$3"
    local remote_image_url="$4"
    local force_refresh="$5"
    local force_remote_refresh="${6:-false}"
    local local_dev_mode="${7:-false}"
    local disable_autoupdate="${8:-false}"
    
    log "🧠 Making smart caching decision..." >&2
    log "  Target: Bun $target_bun_version, Bootstrap $target_bootstrap_version" >&2
    log "  Force refresh: $force_refresh" >&2
    log "  Force remote refresh: $force_remote_refresh" >&2
    log "  Local dev mode: $local_dev_mode" >&2
    log "  Disable autoupdate: $disable_autoupdate" >&2
    
    # If force refresh, skip all local checks
    if [ "$force_refresh" = true ]; then
        log "🔄 Force refresh requested - will check remote then build" >&2
        if [ "$local_dev_mode" = true ]; then
            log "🏠 Local dev mode: Skipping remote check, will build from base" >&2
            echo "build_new"
        elif check_remote_image "$remote_image_url" "$force_remote_refresh"; then
            echo "use_remote"
        else
            echo "build_new"
        fi
        return
    fi
    
    # Check local images first (always do this regardless of mode)
    local local_analysis=$(check_local_image_version "$target_bun_version" "$target_bootstrap_version" "$target_image_name")
    
    # Parse the enhanced results: exact|compatible|usable|all
    local exact_match="${local_analysis%%|*}"
    local remaining="${local_analysis#*|}"
    local compatible_match="${remaining%%|*}"
    remaining="${remaining#*|}"
    local usable_images="${remaining%%|*}"
    local all_images="${remaining#*|}"
    
    # Priority 1: Exact local match - trust existing images (no validation to avoid deleting working images)
    if [ -n "$exact_match" ]; then
        log "🔍 Found exact local match: $exact_match" >&2
        log "🎯 Decision: Use exact local match ($exact_match) - trusting existing image" >&2
        echo "use_local_exact|$exact_match"
        return
    fi
    
    # Priority 2: Compatible local match (same minor version - incremental update)
    if [ -n "$compatible_match" ]; then
        log "🔍 Found compatible local match: $compatible_match" >&2
        log "🔄 Compatible local image found: $compatible_match" >&2
        log "🎯 Decision: Build incrementally from compatible local base" >&2
        echo "build_incremental|$compatible_match"
        return
    fi
    
    # Priority 3: Check remote registry (skip only in local dev mode)
    if [ "$local_dev_mode" = true ]; then
        log "🏠 Local dev mode: Skipping remote registry checks" >&2
        log "🎯 Decision: Build new image from local base (local dev mode)" >&2
        echo "build_new"
        return
    else
        log "🌐 Checking remote registry..." >&2
        if check_remote_image "$remote_image_url" "$force_remote_refresh"; then
            log "🎯 Decision: Use remote image" >&2
            echo "use_remote|$remote_image_url"
            return
        fi
        log "❌ No remote image found, will build new" >&2
    fi
    
    # Priority 4: Build from scratch
    log "🎯 Decision: Build new image from scratch (no valid options found)" >&2
    echo "build_new"
}

# Execute the caching decision
execute_caching_decision() {
    local decision="$1"
    local target_image_name="$2"
    local remote_image_url="$3"
    
    # Clean up the decision string in case it got polluted with VM messages
    # Extract the last line that looks like a valid decision
    local clean_decision
    if echo "$decision" | grep -q "guest has stopped\|virtual machine"; then
        log "⚠️  Decision string appears polluted with VM messages, cleaning..." >&2
        # Get the last line that looks like a decision (contains build_ or use_)
        clean_decision=$(echo "$decision" | grep -E "(build_|use_)" | tail -1 || echo "$decision")
        log "   Original: '$decision'" >&2
        log "   Cleaned:  '$clean_decision'" >&2
    else
        clean_decision="$decision"
    fi
    
    # Debug the decision string
    log "⚡ Executing decision: '$clean_decision'" >&2
    
    local action="${clean_decision%%|*}"
    local target="${clean_decision#*|}"
    
    log "  Action: '$action'" >&2
    log "  Target: '$target'" >&2
    
    case "$action" in
        "use_local_exact")
            log "✅ Using exact local match: $target" >&2
            log "Image ready: $target_image_name" >&2
            return 0
            ;;
            
        "use_remote")
            log "📥 Using remote image: $remote_image_url" >&2
            # Clean up any existing local image to avoid conflicts
            tart delete "$target_image_name" 2>/dev/null || log "No existing local image to delete" >&2
            # Clone from remote (already pulled in check_remote_image)
            log "📋 Cloning remote image to local storage..." >&2
            tart clone "$remote_image_url" "$target_image_name"
            log "✅ Remote image cloned locally as: $target_image_name" >&2
            return 0
            ;;
            
        "build_incremental")
            log "🔄 Building incrementally from compatible base: $target" >&2
            # Set environment variable for main build logic to know about incremental build
            export INCREMENTAL_BASE_IMAGE="$target"
            return 1  # Signal that we need to build
            ;;
            
        "build_new")
            log "🏗️  Building new image: $target_image_name" >&2
            # Clear any incremental base image
            unset INCREMENTAL_BASE_IMAGE
            return 1  # Signal that we need to build
            ;;
            
        *)
            log "❌ Unknown decision: '$clean_decision'" >&2
            log "❌ Action was: '$action'" >&2
            log "❌ Target was: '$target'" >&2
            log "❌ This suggests a parsing error in the decision string" >&2
            log "❌ Original decision was: '$decision'" >&2
            # Fallback to build_new if we can't parse the decision
            log "🔄 Falling back to build_new as safe default..." >&2
            unset INCREMENTAL_BASE_IMAGE
            return 1
            ;;
    esac
}

# Check if local image exists and get its creation time (legacy function, kept for compatibility)
get_local_image_info() {
    local image_name="$1"
    
    log "🔍 Checking for local image: $image_name"
    
    # Get the full tart list output
    local tart_output=$(tart list 2>&1)
    
    # Check if our specific image exists
    if echo "$tart_output" | grep -q "^local.*${image_name}"; then
        log "✅ Found local image: $image_name"
        echo "exists"
    else
        log "❌ No local image found: $image_name"
        echo "missing"
    fi
}

# Get bootstrap version from the bootstrap script (single source of truth)
get_bootstrap_version() {
    local script_path="$1"
    if [ ! -f "$script_path" ]; then
        echo "0"
        return
    fi
    
    # Extract version from comment like "# Version: 4.0 - description"
    local version=$(grep -E "^# Version: " "$script_path" | sed -E 's/^# Version: ([0-9.]+).*/\1/' | head -1)
    if [ -n "$version" ]; then
        echo "$version"
    else
        echo "0"
    fi
}

# Enhanced GitHub credentials loading with keychain support
load_github_credentials() {
    local force_prompt="${1:-false}"
    local interactive_mode="${2:-true}"
    
    log "🔐 Loading GitHub credentials for registry access..."
    
    # If credentials already loaded and not forcing prompt, use them
    if [ "$force_prompt" != "true" ] && [ -n "${GITHUB_USERNAME:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
        log "✅ Using existing GitHub credentials: $GITHUB_USERNAME"
        export TART_REGISTRY_USERNAME="$GITHUB_USERNAME"
        export TART_REGISTRY_PASSWORD="$GITHUB_TOKEN"
        return 0
    fi
    
    # Method 1: Try loading from CI keychain (most secure)
    log "   Trying CI keychain..."
    local keychain_username=""
    local keychain_token=""
    
    # Check if CI keychain exists
    local ci_keychain="$HOME/Library/Keychains/bun-ci.keychain-db"
    local keychain_password_file="$HOME/.buildkite-agent/ci-keychain-password.txt"
    
    if [ -f "$ci_keychain" ]; then
        log "   Found CI keychain: $ci_keychain"
        
        # Unlock keychain if password file exists
        if [ -f "$keychain_password_file" ]; then
            local keychain_password=$(cat "$keychain_password_file" 2>/dev/null || echo "")
            if [ -n "$keychain_password" ]; then
                security unlock-keychain -p "$keychain_password" "$ci_keychain" 2>/dev/null || true
            fi
        fi
        
        # Load credentials using search all keychains method (works over SSH)
        keychain_username=$(security find-generic-password -a "bun-ci" -s "github-username" -w 2>/dev/null || echo "")
        keychain_token=$(security find-generic-password -a "bun-ci" -s "github-token" -w 2>/dev/null || echo "")
        
        if [ -n "$keychain_username" ] && [ -n "$keychain_token" ]; then
            log "✅ Loaded GitHub credentials from CI keychain: $keychain_username"
            export GITHUB_USERNAME="$keychain_username"
            export GITHUB_TOKEN="$keychain_token"
            export TART_REGISTRY_USERNAME="$keychain_username"
            export TART_REGISTRY_PASSWORD="$keychain_token"
            return 0
        else
            log "   CI keychain exists but no credentials found"
        fi
    else
        log "   No CI keychain found at $ci_keychain"
    fi
    
    # Method 2: Try environment variables
    log "   Trying environment variables..."
    if [ -n "${GITHUB_USERNAME:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
        log "✅ Using GitHub credentials from environment: $GITHUB_USERNAME"
        export TART_REGISTRY_USERNAME="$GITHUB_USERNAME"
        export TART_REGISTRY_PASSWORD="$GITHUB_TOKEN"
        return 0
    else
        log "   No environment variables found"
    fi
    
    # Method 3: Try legacy credential files
    log "   Trying legacy credential files..."
    if [ -f /tmp/github-token.txt ] && [ -f /tmp/github-username.txt ]; then
        local file_token=$(cat /tmp/github-token.txt 2>/dev/null || echo "")
        local file_username=$(cat /tmp/github-username.txt 2>/dev/null || echo "")
        if [ -n "$file_token" ] && [ -n "$file_username" ]; then
            log "✅ Using GitHub credentials from legacy files: $file_username"
            export GITHUB_USERNAME="$file_username"
            export GITHUB_TOKEN="$file_token"
            export TART_REGISTRY_USERNAME="$file_username"
            export TART_REGISTRY_PASSWORD="$file_token"
            return 0
        else
            log "   Legacy files exist but are empty or unreadable"
        fi
    else
        log "   No legacy credential files found"
    fi
    
    # Method 4: Try helper script from setup-mac-server.sh
    log "   Trying helper script..."
    local helper_script="$HOME/.buildkite-agent/load-github-credentials.sh"
    if [ -f "$helper_script" ] && [ -x "$helper_script" ]; then
        log "   Found credentials helper script: $helper_script"
        if source "$helper_script" 2>/dev/null; then
            if [ -n "${GITHUB_USERNAME:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
                log "✅ Loaded GitHub credentials from helper script: $GITHUB_USERNAME"
                return 0
            fi
        fi
        log "   Helper script failed to load credentials"
    else
        log "   No helper script found at $helper_script"
    fi
    
    # Method 5: Interactive prompt (only if in interactive mode and not in CI)
    if [ "$interactive_mode" = "true" ] && [ -t 0 ] && [ -z "${CI:-}" ] && [ -z "${BUILDKITE:-}" ]; then
        log "   No credentials found, prompting user..."
        
        # Prompt for credentials
        local input_username=""
        local input_token=""
        
        echo -n "Enter GitHub username for registry access: "
        read input_username
        
        if [ -n "$input_username" ]; then
            echo -n "Enter GitHub token (will be hidden): "
            # Read token securely
            local char
            while IFS= read -r -s -n1 char; do
                if [[ $char == $'\0' || $char == $'\n' ]]; then
                    break
                fi
                if [[ $char == $'\177' ]]; then
                    if [ -n "$input_token" ]; then
                        input_token="${input_token%?}"
                        printf '\b \b'
                    fi
                else
                    input_token+="$char"
                    printf '•'
                fi
            done
            echo
            
            if [ -n "$input_token" ]; then
                log "✅ Using manually entered GitHub credentials: $input_username"
                export GITHUB_USERNAME="$input_username"
                export GITHUB_TOKEN="$input_token"
                export TART_REGISTRY_USERNAME="$input_username"
                export TART_REGISTRY_PASSWORD="$input_token"
                
                # Offer to store in keychain for future use
                echo -n "Store credentials in CI keychain for future use? (y/n): "
                read store_choice
                if [[ "$store_choice" == "y" || "$store_choice" == "Y" ]]; then
                    store_credentials_in_keychain "$input_username" "$input_token"
                fi
                
                return 0
            else
                log "   No token entered"
            fi
        else
            log "   No username entered"
        fi
    else
        log "   Skipping interactive prompt (non-interactive mode or CI environment)"
    fi
    
    # No credentials found
    log "❌ No GitHub credentials found"
    log "   Registry operations will be attempted without authentication"
    log "   This may fail for private repositories or pushing images"
    return 1
}

# Store credentials in CI keychain for future use
store_credentials_in_keychain() {
    local username="$1"
    local token="$2"
    
    log "🔒 Storing GitHub credentials in CI keychain..."
    
    # Create CI keychain if it doesn't exist
    local ci_keychain="$HOME/Library/Keychains/bun-ci.keychain-db"
    local keychain_password_file="$HOME/.buildkite-agent/ci-keychain-password.txt"
    
    if [ ! -f "$ci_keychain" ]; then
        log "   Creating CI keychain..."
        
        # Create directories
        mkdir -p "$HOME/.buildkite-agent"
        mkdir -p "$HOME/Library/Keychains"
        
        # Generate secure password
        local keychain_password=$(openssl rand -base64 32)
        
        # Create keychain
        security create-keychain -p "$keychain_password" "$ci_keychain"
        security set-keychain-settings "$ci_keychain"
        security list-keychains -s "$ci_keychain" $(security list-keychains -d user | tr -d '"')
        security unlock-keychain -p "$keychain_password" "$ci_keychain"
        
        # Store password for future use
        echo "$keychain_password" > "$keychain_password_file"
        chmod 600 "$keychain_password_file"
        
        log "   ✅ CI keychain created"
    else
        log "   Using existing CI keychain"
        
        # Unlock if password file exists
        if [ -f "$keychain_password_file" ]; then
            local keychain_password=$(cat "$keychain_password_file" 2>/dev/null || echo "")
            if [ -n "$keychain_password" ]; then
                security unlock-keychain -p "$keychain_password" "$ci_keychain" 2>/dev/null || true
            fi
        fi
    fi
    
    # Store credentials (remove existing first to avoid duplicates)
    security delete-generic-password -a "bun-ci" -s "github-username" "$ci_keychain" 2>/dev/null || true
    security delete-generic-password -a "bun-ci" -s "github-token" "$ci_keychain" 2>/dev/null || true
    
    # Add new credentials
    security add-generic-password -a "bun-ci" -s "github-username" -w "$username" "$ci_keychain"
    security add-generic-password -a "bun-ci" -s "github-token" -w "$token" "$ci_keychain"
    
    log "   ✅ Credentials stored securely in CI keychain"
    
    # Create helper script if it doesn't exist
    local helper_script="$HOME/.buildkite-agent/load-github-credentials.sh"
    if [ ! -f "$helper_script" ]; then
        cat > "$helper_script" << 'CREDENTIALS_SCRIPT_END'
#!/bin/bash
# Load GitHub credentials from keychain (using search all keychains method that works over SSH)

GITHUB_USERNAME=$(security find-generic-password -a "bun-ci" -s "github-username" -w 2>/dev/null)
GITHUB_TOKEN=$(security find-generic-password -a "bun-ci" -s "github-token" -w 2>/dev/null)

if [ -n "$GITHUB_USERNAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    export TART_REGISTRY_USERNAME="$GITHUB_USERNAME"
    export TART_REGISTRY_PASSWORD="$GITHUB_TOKEN"
    export GITHUB_USERNAME="$GITHUB_USERNAME"
    export GITHUB_TOKEN="$GITHUB_TOKEN"
    echo "✅ GitHub credentials loaded: $GITHUB_USERNAME"
    return 0
else
    echo "❌ Failed to load GitHub credentials from keychain"
    return 1
fi
CREDENTIALS_SCRIPT_END
        
        chmod +x "$helper_script"
        log "   ✅ Helper script created at $helper_script"
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
    for arg in "$@"; do
        case $arg in
            --force-refresh)
                force_refresh=true
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
                echo "  --force-remote-refresh  Force re-download of remote images (ignore cache)"
                echo "  --cleanup-only          Clean up old VM images and exit"
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
    
    log "Configuration:"
    log "  macOS Release: $MACOS_RELEASE"
    log "  Architecture: $ARCH"
    log "  Base image: $BASE_IMAGE"
    log "  Local name: $LOCAL_IMAGE_NAME"
    log "  Remote URL: $REMOTE_IMAGE_URL"
    log "  Bootstrap version: $BOOTSTRAP_VERSION"
    log "  Force refresh: $force_refresh"
    log "  Disable autoupdate: $disable_autoupdate"
    
    # Check for disable-autoupdate mode
    if [ "$disable_autoupdate" = true ]; then
        log "=== DISABLE AUTOUPDATE MODE ==="
        log "🔒 Autoupdate disabled - using existing VMs without version checks"
        
        # Find the most recent VM image for this macOS release and architecture
        local tart_output=$(tart list 2>&1)
        local existing_image=""
        local best_version="0.0.0"
        
        # Look for any bun-build-macos image with matching macOS release and architecture
        while IFS= read -r line; do
            if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+) ]]; then
                local image_name="${BASH_REMATCH[1]}"
                
                # Check if it matches our macOS release and architecture pattern
                if [[ "$image_name" =~ ^bun-build-macos-${MACOS_RELEASE}-(${ARCH})-[0-9]+\.[0-9]+\.[0-9]+-bootstrap-[0-9]+\.[0-9]+$ ]]; then
                    # Parse version from this image
                    local image_info=$(parse_image_name "$image_name")
                    local remaining="${image_info#*|}"  # Skip macOS release
                    remaining="${remaining#*|}"         # Skip architecture
                    local bun_version="${remaining%%|*}" # Get Bun version
                    
                    log "    Found candidate: $image_name (Bun: $bun_version)"
                    
                    # Keep track of the highest version
                    if version_compare "$bun_version" "$best_version"; then
                        existing_image="$image_name"
                        best_version="$bun_version"
                        log "      ✅ New best candidate (version: $bun_version)"
                    else
                        log "      ⬇️  Older version: $bun_version <= $best_version"
                    fi
                fi
            fi
        done <<< "$tart_output"
        
        if [ -n "$existing_image" ]; then
            log "✅ Using existing VM: $existing_image (version: $best_version)"
            log "Final image name: $existing_image"
            log "Available images:"
            tart list | grep -E "(NAME|bun-build-macos)" || tart list
            exit 0
        else
            log "❌ No existing VM found for macOS $MACOS_RELEASE with architecture $ARCH"
            log "   Looking for pattern: bun-build-macos-${MACOS_RELEASE}-${ARCH}-*"
            log "   Available VMs:"
            tart list | grep -E "bun-build-macos" || log "   (none)"
            log "   Please build a VM first without --disable-autoupdate"
            exit 1
        fi
    fi
    
    # SMART CACHING LOGIC
    log "=== SMART CACHING ANALYSIS ==="
    
    # Make intelligent caching decision
    local caching_decision=$(make_caching_decision "$BUN_VERSION" "$BOOTSTRAP_VERSION" "$LOCAL_IMAGE_NAME" "$REMOTE_IMAGE_URL" "$force_refresh" "$force_remote_refresh" "$local_dev_mode" "$disable_autoupdate")
    
    log "Caching decision: $caching_decision"
    
    # Execute the decision
    if execute_caching_decision "$caching_decision" "$LOCAL_IMAGE_NAME" "$REMOTE_IMAGE_URL"; then
        log "✅ Image ready via smart caching!"
        log "Final image name: $LOCAL_IMAGE_NAME"
        log "Available images:"
        tart list | grep -E "(NAME|bun-build-macos)" || tart list
        exit 0
    fi
    
    # If we reach here, we need to build a new image

    # Validate that all required tools are installed
    log "=== VALIDATING BASE IMAGE ==="
    log "Testing that all required tools are available..."
    
    # Wait for VM to be ready for validation
    log "Waiting for VM to be ready for validation..."
    sleep 2
    
    # Get VM IP for validation
    VM_IP=""
    for i in {1..10}; do
        VM_IP=$(tart ip "$LOCAL_IMAGE_NAME" 2>/dev/null || echo "")
        if [ -n "$VM_IP" ]; then
            log "VM IP for validation: $VM_IP"
            break
        fi
        log "Attempt $i: waiting for VM IP..."
        sleep 2
    done
    
    if [ -z "$VM_IP" ]; then
        log "❌ Could not get VM IP for validation"
        kill $VM_PID 2>/dev/null || true
        exit 1
    fi

    # Test required tools
    local tools_check="
        export PATH=\"/usr/local/bin:/opt/homebrew/bin:\$PATH\"
        echo '=== Tool Validation ==='
        command -v bun && echo 'Bun: ✅ '\$(bun --version) || echo 'Bun: ❌ MISSING'
        command -v cargo && echo 'Cargo: ✅ '\$(cargo --version) || echo 'Cargo: ❌ MISSING'  
        command -v cmake && echo 'CMake: ✅ '\$(cmake --version | head -1) || echo 'CMake: ❌ MISSING'
        command -v node && echo 'Node: ✅ '\$(node --version) || echo 'Node: ❌ MISSING'
        command -v clang && echo 'Clang: ✅ '\$(clang --version | head -1) || echo 'Clang: ❌ MISSING'
        command -v ninja && echo 'Ninja: ✅ '\$(ninja --version) || echo 'Ninja: ❌ MISSING'
        echo '======================='
    "
    
    log "Validating tools in base image..."
    local validation_result
    if validation_result=$(sshpass -p "admin" ssh $SSH_OPTS admin@"$VM_IP" "$tools_check" 2>/dev/null); then
        echo "$validation_result" | while read line; do
            log "$line"
        done
        
        # Check if any tools are missing
        if echo "$validation_result" | grep -q "❌ MISSING"; then
            log "❌ Base image validation FAILED - missing required tools"
            log "Bootstrap did not install all required tools properly"
            kill $VM_PID 2>/dev/null || true
            exit 1
        else
            log "✅ Base image validation PASSED - all required tools present"
        fi
    else
        log "❌ Failed to connect to VM for validation"
        kill $VM_PID 2>/dev/null || true
        exit 1
    fi

    # TEMPORARY: Run codesigning environment diagnostics
    log "=== CODESIGNING ENVIRONMENT DIAGNOSTICS (TEMPORARY) ==="
    log "Running codesigning environment check for debugging..."
    
    local codesigning_check='
        echo ""
        echo "=== CODESIGNING & SDK ENVIRONMENT DIAGNOSTICS ==="
        echo "Checking environment for '"'"'bun build --compile'"'"' / Mach-O generation issues..."
        echo ""
        
        # Check Xcode tools
        echo "📋 Xcode Developer Tools:"
        if command -v xcode-select >/dev/null 2>&1; then
            xcode_path=$(xcode-select -p 2>/dev/null || echo "NOT SET")
            echo "  ✅ xcode-select: $xcode_path"
            
            # Check if the path actually exists
            if [ -d "$xcode_path" ]; then
                echo "  ✅ Developer directory exists: $xcode_path"
            else
                echo "  ❌ Developer directory missing: $xcode_path"
            fi
        else
            echo "  ❌ xcode-select: NOT FOUND"
        fi
        
        # Check codesigning tools
        echo ""
        echo "🔐 Codesigning Tools:"
        codesign_tools="codesign notarytool xcrun security"
        for tool in $codesign_tools; do
            if command -v "$tool" >/dev/null 2>&1; then
                tool_path=$(which "$tool")
                echo "  ✅ $tool: $tool_path"
                
                # Try to get version if possible
                case "$tool" in
                    codesign)
                        version=$(codesign --version 2>/dev/null || echo "version unknown")
                        echo "     Version: $version"
                        ;;
                    xcrun)
                        version=$(xcrun --version 2>/dev/null || echo "version unknown")  
                        echo "     Version: $version"
                        ;;
                esac
            else
                echo "  ❌ $tool: NOT FOUND"
            fi
        done
        
        # Check SDK paths and environment variables
        echo ""
        echo "🛠️  SDK Environment Variables:"
        sdk_vars="SDK_PATH XCODE_SDK_PATH DEVELOPER_DIR SDKROOT MACOSX_DEPLOYMENT_TARGET"
        for var in $sdk_vars; do
            value=$(eval echo \$"$var")
            if [ -n "$value" ]; then
                echo "  ✅ $var: $value"
                
                # Check if SDK path actually exists
                if [[ "$var" == *"SDK"* ]] && [ -n "$value" ]; then
                    if [ -d "$value" ]; then
                        echo "     Directory exists: YES"
                    else
                        echo "     Directory exists: NO"
                    fi
                fi
            else
                echo "  ⚠️  $var: NOT SET"
            fi
        done
        
        # Check SDK using xcrun
        echo ""
        echo "📱 macOS SDK Information:"
        if command -v xcrun >/dev/null 2>&1; then
            sdk_path=$(xcrun --show-sdk-path 2>/dev/null || echo "FAILED")
            echo "  SDK Path: $sdk_path"
            
            if [ "$sdk_path" != "FAILED" ] && [ -d "$sdk_path" ]; then
                echo "  ✅ SDK directory exists"
                
                sdk_version=$(xcrun --show-sdk-version 2>/dev/null || echo "unknown")
                echo "  SDK Version: $sdk_version"
                
                sdk_platform=$(xcrun --show-sdk-platform-path 2>/dev/null || echo "unknown")
                echo "  SDK Platform: $sdk_platform"
                
                # List some key SDK contents
                if [ -d "$sdk_path/usr/include" ]; then
                    echo "  ✅ Headers directory exists: $sdk_path/usr/include"
                else
                    echo "  ❌ Headers directory missing: $sdk_path/usr/include"
                fi
                
                if [ -d "$sdk_path/usr/lib" ]; then
                    echo "  ✅ Libraries directory exists: $sdk_path/usr/lib"
                else
                    echo "  ❌ Libraries directory missing: $sdk_path/usr/lib"
                fi
            else
                echo "  ❌ SDK directory does not exist or xcrun failed"
            fi
        else
            echo "  ❌ xcrun not available"
        fi
        
        # Check Command Line Tools
        echo ""
        echo "⚒️  Command Line Tools:"
        if [ -d "/Library/Developer/CommandLineTools" ]; then
            echo "  ✅ Command Line Tools installed: /Library/Developer/CommandLineTools"
            
            if [ -f "/Library/Developer/CommandLineTools/usr/bin/codesign" ]; then
                echo "  ✅ CommandLineTools codesign: /Library/Developer/CommandLineTools/usr/bin/codesign"
            else
                echo "  ❌ CommandLineTools codesign: NOT FOUND"
            fi
        else
            echo "  ❌ Command Line Tools: NOT INSTALLED"
        fi
        
        # Check for potential environment fixes
        echo ""
        echo "🔧 Suggested Environment Setup:"
        if command -v xcrun >/dev/null 2>&1; then
            suggested_sdk=$(xcrun --show-sdk-path 2>/dev/null)
            suggested_dev=$(xcode-select -p 2>/dev/null)
            
            if [ -n "$suggested_sdk" ]; then
                echo "  export SDK_PATH=\"$suggested_sdk\""
                echo "  export XCODE_SDK_PATH=\"$suggested_sdk\""
                echo "  export SDKROOT=\"$suggested_sdk\""
            fi
            
            if [ -n "$suggested_dev" ]; then
                echo "  export DEVELOPER_DIR=\"$suggested_dev\""
            fi
            
            echo "  export MACOSX_DEPLOYMENT_TARGET=\"13.0\""
        else
            echo "  ❌ Cannot determine proper SDK paths - xcrun not available"
        fi
        
        echo ""
        echo "=== END CODESIGNING DIAGNOSTICS ==="
        echo ""
    '
    
    local codesigning_result
    if codesigning_result=$(sshpass -p "admin" ssh $SSH_OPTS admin@"$VM_IP" "$codesigning_check" 2>/dev/null); then
        echo "$codesigning_result" | while read line; do
            log "$line"
        done
        log "✅ Codesigning environment diagnostics completed"
    else
        log "❌ Failed to run codesigning diagnostics in VM"
    fi
    
    log "=== END CODESIGNING DIAGNOSTICS ==="

    # Stop the VM gracefully
    log "Shutting down VM..."
    sshpass -p "admin" ssh $SSH_OPTS admin@"$VM_IP" "sudo shutdown -h now" || true
    
    # Wait for VM to stop (reduced from 30s to 2s)
    sleep 2
    kill $VM_PID 2>/dev/null || true
    
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