#!/bin/bash
set -euo pipefail

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

# Cleanup old VM images to free storage space
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
    
    # Track latest version for each macOS release (using regular variables for Bash 3.x compatibility)
    local latest_macos13_version=""
    local latest_macos13_bootstrap=""
    local latest_macos13_image=""
    local latest_macos14_version=""
    local latest_macos14_bootstrap=""
    local latest_macos14_image=""
    
    local all_bun_images=()
    local images_to_delete=()
    
    # Parse all bun-build-macos images and find latest for each macOS version
    while IFS= read -r line; do
        if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+) ]]; then
            local image_name="${BASH_REMATCH[1]}"
            
            # Only consider bun-build-macos images
            if [[ "$image_name" =~ ^bun-build-macos-([0-9]+)-([0-9]+\.[0-9]+\.[0-9]+)-bootstrap-([0-9]+\.[0-9]+) ]]; then
                local macos_ver="${BASH_REMATCH[1]}"
                local bun_ver="${BASH_REMATCH[2]}"
                local bootstrap_ver="${BASH_REMATCH[3]}"
                
                all_bun_images+=("$image_name")
                log "  Found: $image_name (macOS: $macos_ver, Bun: $bun_ver, Bootstrap: $bootstrap_ver)"
                
                # Track latest for macOS 13
                if [ "$macos_ver" = "13" ]; then
                    if [ -z "${latest_macos13_version:-}" ] || version_compare "$bun_ver" "${latest_macos13_version}"; then
                        # If same Bun version, prefer higher bootstrap version
                        if [ "$bun_ver" = "${latest_macos13_version:-}" ]; then
                            if version_compare "$bootstrap_ver" "${latest_macos13_bootstrap:-}"; then
                                latest_macos13_version="$bun_ver"
                                latest_macos13_bootstrap="$bootstrap_ver"
                                latest_macos13_image="$image_name"
                            fi
                        else
                            latest_macos13_version="$bun_ver"
                            latest_macos13_bootstrap="$bootstrap_ver"
                            latest_macos13_image="$image_name"
                        fi
                    fi
                fi
                
                # Track latest for macOS 14
                if [ "$macos_ver" = "14" ]; then
                    if [ -z "${latest_macos14_version:-}" ] || version_compare "$bun_ver" "${latest_macos14_version}"; then
                        # If same Bun version, prefer higher bootstrap version
                        if [ "$bun_ver" = "${latest_macos14_version:-}" ]; then
                            if version_compare "$bootstrap_ver" "${latest_macos14_bootstrap:-}"; then
                                latest_macos14_version="$bun_ver"
                                latest_macos14_bootstrap="$bootstrap_ver"
                                latest_macos14_image="$image_name"
                            fi
                        else
                            latest_macos14_version="$bun_ver"
                            latest_macos14_bootstrap="$bootstrap_ver"
                            latest_macos14_image="$image_name"
                        fi
                    fi
                fi
            fi
        fi
    done <<< "$tart_output"
    
    # Show what we found as latest
    if [ -n "${latest_macos13_image:-}" ]; then
        log "  📌 Latest macOS 13: ${latest_macos13_image} (Bun ${latest_macos13_version}, Bootstrap ${latest_macos13_bootstrap})"
    else
        log "  📌 No macOS 13 images found"
    fi
    
    if [ -n "${latest_macos14_image:-}" ]; then
        log "  📌 Latest macOS 14: ${latest_macos14_image} (Bun ${latest_macos14_version}, Bootstrap ${latest_macos14_bootstrap})"
    else
        log "  📌 No macOS 14 images found"
    fi
    
    # Mark all others for deletion
    for image in "${all_bun_images[@]}"; do
        local should_keep=false
        
        # Keep if it's the latest for macOS 13
        if [ -n "${latest_macos13_image:-}" ] && [ "$image" = "${latest_macos13_image}" ]; then
            should_keep=true
        fi
        
        # Keep if it's the latest for macOS 14
        if [ -n "${latest_macos14_image:-}" ] && [ "$image" = "${latest_macos14_image}" ]; then
            should_keep=true
        fi
        
        if [ "$should_keep" = false ]; then
            images_to_delete+=("$image")
        fi
    done
    
    # Delete old images
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
        log "✅ No old images to clean up"
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

# Parse image name to extract version and bootstrap info
parse_image_name() {
    local image_name="$1"
    local bun_version=""
    local bootstrap_version=""
    
    # Extract Bun version and bootstrap version from image name
    # Format: bun-build-macos-X.Y.Z-bootstrap-N.M
    if [[ "$image_name" =~ bun-build-macos-([0-9]+\.[0-9]+\.[0-9]+)-bootstrap-([0-9]+\.[0-9]+) ]]; then
        bun_version="${BASH_REMATCH[1]}"
        bootstrap_version="${BASH_REMATCH[2]}"
    fi
    
    echo "$bun_version|$bootstrap_version"
}

# Check local images and categorize them
check_local_image_version() {
    local target_bun_version="$1"
    local target_bootstrap_version="$2"
    local target_image_name="$3"
    
    log "🔍 Analyzing local images for Bun $target_bun_version, Bootstrap $target_bootstrap_version" >&2
    
    # Get all local images
    local tart_output=$(tart list 2>&1)
    
    # Results
    local exact_match=""
    local usable_images=()
    local all_bun_images=()
    
    # Parse each line for bun-build-macos images
    while IFS= read -r line; do
        if [[ "$line" =~ ^local[[:space:]]+([^[:space:]]+) ]]; then
            local image_name="${BASH_REMATCH[1]}"
            
            # Only consider bun-build-macos images
            if [[ "$image_name" =~ ^bun-build-macos- ]]; then
                all_bun_images+=("$image_name")
                
                # Parse version info
                local version_info=$(parse_image_name "$image_name")
                local bun_ver="${version_info%|*}"
                local bootstrap_ver="${version_info#*|}"
                
                log "  Found: $image_name (Bun: $bun_ver, Bootstrap: $bootstrap_ver)" >&2
                
                # Check for exact match
                if [ "$image_name" = "$target_image_name" ]; then
                    exact_match="$image_name"
                    log "    ✅ Exact match found!" >&2
                # Check for usable match (same Bun version, different bootstrap)
                elif [ "$bun_ver" = "$target_bun_version" ] && [ "$bootstrap_ver" != "$target_bootstrap_version" ]; then
                    usable_images+=("$image_name")
                    log "    🔄 Usable match (different bootstrap)" >&2
                fi
            fi
        fi
    done <<< "$tart_output"
    
    # Return results (format: exact|usable1,usable2|all1,all2)
    # Handle empty arrays properly
    local usable_list=""
    if [ ${#usable_images[@]} -gt 0 ]; then
        usable_list=$(IFS=','; echo "${usable_images[*]}")
    fi
    
    local all_list=""
    if [ ${#all_bun_images[@]} -gt 0 ]; then
        all_list=$(IFS=','; echo "${all_bun_images[*]}")
    fi
    
    echo "$exact_match|$usable_list|$all_list"
}

# Check if remote image exists
check_remote_image() {
    local remote_url="$1"
    log "🌐 Checking remote image: $remote_url" >&2
    
    # Fix permissions before trying to use tart
    fix_tart_permissions >&2
    
    # Show that download is starting since VM images are large (GB+) and can take 10-30+ minutes
    log "📥 Starting download of remote VM image (may be 5-15GB+, please wait)..." >&2
    
    # Run tart pull directly to show native progress output (percentages, etc.)
    if tart pull "$remote_url"; then
        log "✅ Remote image found and downloaded successfully" >&2
        return 0
    else
        log "❌ Remote image not found or download failed" >&2
        return 1
    fi
}

# Make smart caching decision
make_caching_decision() {
    local target_bun_version="$1"
    local target_bootstrap_version="$2"
    local target_image_name="$3"
    local remote_image_url="$4"
    local force_refresh="$5"
    
    log "🧠 Making smart caching decision..." >&2
    log "  Target: Bun $target_bun_version, Bootstrap $target_bootstrap_version" >&2
    log "  Force refresh: $force_refresh" >&2
    
    # If force refresh, skip all local checks
    if [ "$force_refresh" = true ]; then
        log "🔄 Force refresh requested - will check remote then build" >&2
        if check_remote_image "$remote_image_url"; then
            echo "use_remote"
        else
            echo "build_new"
        fi
        return
    fi
    
    # Check local images
    local local_analysis=$(check_local_image_version "$target_bun_version" "$target_bootstrap_version" "$target_image_name")
    local exact_match="${local_analysis%%|*}"
    local usable_images="${local_analysis%|*}"
    usable_images="${usable_images#*|}"
    
    # Priority 1: Exact local match
    if [ -n "$exact_match" ]; then
        log "🎯 Decision: Use exact local match ($exact_match)" >&2
        echo "use_local_exact|$exact_match"
        return
    fi
    
    # Priority 2: Check remote for perfect match
    log "🌐 No exact local match, checking remote..." >&2
    if check_remote_image "$remote_image_url"; then
        log "🎯 Decision: Use remote perfect match" >&2
        echo "use_remote|$remote_image_url"
        return
    fi
    
    # Priority 3: Check for newer bootstrap versions only (removed old fallback)
    # Bootstrap version changes are critical - always build new if version doesn't match
    # Old logic that used different bootstrap versions removed for safety
    
    # Priority 4: Build new image
    log "🎯 Decision: Build new image (no suitable local or remote found)" >&2
    echo "build_new"
}

# Execute the caching decision
execute_caching_decision() {
    local decision="$1"
    local target_image_name="$2"
    local remote_image_url="$3"
    
    # Debug the decision string
    log "⚡ Executing decision: '$decision'" >&2
    
    local action="${decision%%|*}"
    local target="${decision#*|}"
    
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
            
        "build_new")
            log "🏗️  Building new image: $target_image_name" >&2
            return 1  # Signal that we need to build
            ;;
            
        *)
            log "❌ Unknown decision: '$decision'" >&2
            log "❌ Action was: '$action'" >&2
            log "❌ Target was: '$target'" >&2
            log "❌ This suggests a parsing error in the decision string" >&2
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

# Main execution
main() {
    # Parse arguments
    local force_refresh=false
    local cleanup_only=false
    for arg in "$@"; do
        case $arg in
            --force-refresh)
                force_refresh=true
                shift
                ;;
            --cleanup-only)
                cleanup_only=true
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
                echo "  --force-refresh     Force refresh of base image"
                echo "  --cleanup-only      Clean up old VM images and exit"
                echo "  --release=VERSION   macOS release version (13, 14) [default: 14]"
                echo "  --help, -h          Show this help message"
                echo ""
                echo "Environment Variables:"
                echo "  MACOS_RELEASE       macOS release version (default: 14)"
                echo "  BOOTSTRAP_VERSION   Bootstrap script version (auto-detected from script)"
                echo "  BUN_VERSION         Bun version (auto-detected if not set)"
                echo "  REGISTRY            Container registry (default: ghcr.io)"
                echo "  ORGANIZATION        Organization name (default: build-archetype)"
                echo "  REPOSITORY          Repository name (default: client-oven-sh-bun)"
                echo ""
                echo "Examples:"
                echo "  $0                    # Build macOS 14 base image"
                echo "  $0 --release=13       # Build macOS 13 base image"
                echo "  $0 --force-refresh    # Force rebuild of base image"
                echo "  $0 --cleanup-only     # Clean up old images and exit"
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
    
    # Example: Install or update required tools
    # Uncomment and modify as needed:
    
    # Install/update Homebrew packages
    # if command -v brew >/dev/null 2>&1; then
    #     log "Updating Homebrew packages..."
    #     brew update || log "⚠️ Homebrew update failed (continuing)"
    #     brew install jq || log "⚠️ jq install failed (continuing)"
    # fi
    
    # Install Node.js dependencies
    # if [ -f "package.json" ]; then
    #     log "Installing Node.js dependencies..."
    #     npm install || log "⚠️ npm install failed (continuing)"
    # fi
    
    # Install or check other dependencies
    # log "Checking required tools..."
    # for tool in tart sshpass jq; do
    #     if command -v "$tool" >/dev/null 2>&1; then
    #         log "✅ $tool is available"
    #     else
    #         log "⚠️ $tool is missing - attempting to install..."
    #         # Add installation logic here if needed
    #     fi
    # done
    
    log "✅ Temporary installation steps completed"
    log "=== END TEMPORARY INSTALLATIONS ==="
    
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
    
    # Image names (include release and bootstrap version to force rebuilds when bootstrap changes)
    LOCAL_IMAGE_NAME="bun-build-macos-${MACOS_RELEASE}-${BUN_VERSION}-bootstrap-${BOOTSTRAP_VERSION}"
    REMOTE_IMAGE_URL="${REGISTRY}/${ORGANIZATION}/${REPOSITORY}/bun-build-macos-${MACOS_RELEASE}:${BUN_VERSION}-bootstrap-${BOOTSTRAP_VERSION}"
    LATEST_IMAGE_URL="${REGISTRY}/${ORGANIZATION}/${REPOSITORY}/bun-build-macos-${MACOS_RELEASE}:latest"
    
    log "Configuration:"
    log "  macOS Release: $MACOS_RELEASE"
    log "  Base image: $BASE_IMAGE"
    log "  Local name: $LOCAL_IMAGE_NAME"
    log "  Remote URL: $REMOTE_IMAGE_URL"
    log "  Bootstrap version: $BOOTSTRAP_VERSION"
    log "  Force refresh: $force_refresh"
    
    # SMART CACHING LOGIC
    log "=== SMART CACHING ANALYSIS ==="
    
    # Make intelligent caching decision
    local caching_decision=$(make_caching_decision "$BUN_VERSION" "$BOOTSTRAP_VERSION" "$LOCAL_IMAGE_NAME" "$REMOTE_IMAGE_URL" "$force_refresh")
    
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
    log "=== BUILDING NEW BASE IMAGE ==="
    log "Building new base image for Bun ${BUN_VERSION}..."
    
    # Clean up the specific image we're about to build (if it exists)
    log "Cleaning up target image if it exists: $LOCAL_IMAGE_NAME"
    tart delete "$LOCAL_IMAGE_NAME" 2>/dev/null || log "Target image doesn't exist (expected)"
    
    # Clone base image
    log "Cloning base image: $BASE_IMAGE"
    tart clone "$BASE_IMAGE" "$LOCAL_IMAGE_NAME"
    log "✅ Base image cloned"
    
    # Pass the version to bootstrap script
    log "Making bootstrap script executable..."
    chmod +x scripts/bootstrap-macos.sh
    
    # Start VM with shared directory
    log "Starting VM: $LOCAL_IMAGE_NAME"
    tart run "$LOCAL_IMAGE_NAME" --dir=workspace:"$PWD" --no-graphics &
VM_PID=$!

    # Wait for VM to boot
    log "Waiting for VM to boot (60 seconds)..."
    sleep 60
    
    # Get VM IP
    log "Getting VM IP address..."
    VM_IP=""
    for i in {1..10}; do
        VM_IP=$(tart ip "$LOCAL_IMAGE_NAME" 2>/dev/null || echo "")
        if [ -n "$VM_IP" ]; then
            log "VM IP: $VM_IP"
            break
        fi
        log "Attempt $i: waiting for VM IP..."
        sleep 10
    done
    
    if [ -z "$VM_IP" ]; then
        log "❌ Could not get VM IP after 10 attempts"
        kill $VM_PID 2>/dev/null || true
        exit 1
    fi

    # Wait for SSH to be available and run bootstrap
    log "Waiting for SSH to be available and running bootstrap..."
    SSH_SUCCESS=false
    
    for i in {1..30}; do
        log "SSH attempt $i/30..."
        
        # First check if we can SSH at all
        if sshpass -p "admin" ssh $SSH_OPTS admin@"$VM_IP" "echo 'SSH connection successful'"; then
            log "✅ SSH connection established"
            
            # Check initial state before bootstrap
            log "Checking VM state before bootstrap..."
            sshpass -p "admin" ssh $SSH_OPTS admin@"$VM_IP" '
                echo "Current user: $(whoami)"
                echo "Current directory: $(pwd)"
                echo "PATH: $PATH"
                echo "Available in /usr/local/bin: $(ls -la /usr/local/bin/ 2>/dev/null || echo none)"
                echo "Available in /opt/homebrew/bin: $(ls -la /opt/homebrew/bin/ 2>/dev/null | head -5 || echo none)"
            '
            
            # Run the bootstrap script
            if sshpass -p "admin" ssh $SSH_OPTS admin@"$VM_IP" "cd '/Volumes/My Shared Files/workspace' && ./scripts/bootstrap-macos.sh"; then
                log "✅ Bootstrap completed successfully!"
                SSH_SUCCESS=true
                break
            else
                log "❌ Bootstrap failed on attempt $i"
            fi
        else
            log "SSH attempt $i failed, retrying in 30 seconds..."
        fi
        sleep 30
    done
    
    if [ "$SSH_SUCCESS" != "true" ]; then
        log "❌ Bootstrap failed after 30 SSH attempts"
        kill $VM_PID 2>/dev/null || true
    exit 1
    fi

    # Validate that all required tools are installed
    log "=== VALIDATING BASE IMAGE ==="
    log "Testing that all required tools are available..."
    
    # Wait for VM to be ready for validation
    log "Waiting for VM to be ready for validation..."
    sleep 10
    
    # Get VM IP for validation
    VM_IP=""
    for i in {1..10}; do
        VM_IP=$(tart ip "$LOCAL_IMAGE_NAME" 2>/dev/null || echo "")
        if [ -n "$VM_IP" ]; then
            log "VM IP for validation: $VM_IP"
            break
        fi
        log "Attempt $i: waiting for VM IP..."
        sleep 10
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

    # Stop the VM gracefully
    log "Shutting down VM..."
    sshpass -p "admin" ssh $SSH_OPTS admin@"$VM_IP" "sudo shutdown -h now" || true
    
    # Wait for VM to stop
    sleep 30
    kill $VM_PID 2>/dev/null || true
    
    log "✅ Bootstrap completed successfully"

    # Step 5: Try to push to registry (but don't fail if this doesn't work)
    log "=== REGISTRY PUSH ATTEMPT ==="
    set +e  # Disable error handling for entire registry section

    # Check if we have any credentials at all
    HAVE_CREDS=false
    if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_USERNAME:-}" ]; then
        log "✅ Found GitHub credentials in environment"
        HAVE_CREDS=true
    elif [ -f /tmp/github-token.txt ] && [ -f /tmp/github-username.txt ]; then
        log "✅ Found GitHub credentials in legacy files (reading them)"
        GITHUB_TOKEN=$(cat /tmp/github-token.txt 2>/dev/null || echo "")
        GITHUB_USERNAME=$(cat /tmp/github-username.txt 2>/dev/null || echo "")
        if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_USERNAME" ]; then
            HAVE_CREDS=true
        fi
    else
        log "⚠️  No GitHub credentials found anywhere"
    fi

    if [ "$HAVE_CREDS" = true ]; then
        log "Attempting to push to registry with credentials..."
        
        # Set Tart authentication environment variables (with error handling)
        export TART_REGISTRY_USERNAME="$GITHUB_USERNAME" 2>/dev/null || true
        export TART_REGISTRY_PASSWORD="$GITHUB_TOKEN" 2>/dev/null || true
        
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

main "$@" 