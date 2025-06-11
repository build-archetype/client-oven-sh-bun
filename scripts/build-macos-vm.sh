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
    if [ ${#all_bun_images[@]} -gt 0 ]; then
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
    fi
    
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

# Parse image name to extract version and bootstrap info
parse_image_name() {
    local image_name="$1"
    local bun_version=""
    local bootstrap_version=""
    
    # Extract Bun version and bootstrap version from image name
    # Format: bun-build-macos-[MACOS_RELEASE]-[BUN_VERSION]-bootstrap-[BOOTSTRAP_VERSION]
    # Example: bun-build-macos-13-1.2.16-bootstrap-4.1
    if [[ "$image_name" =~ bun-build-macos-([0-9]+)-([0-9]+\.[0-9]+\.[0-9]+)-bootstrap-([0-9]+\.[0-9]+) ]]; then
        bun_version="${BASH_REMATCH[2]}"      # Second capture group is Bun version
        bootstrap_version="${BASH_REMATCH[3]}" # Third capture group is Bootstrap version
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
    local compatible_images=()  # Same minor version (e.g., 1.2.x)
    local usable_images=()      # Different minor version but could be useful
    local all_bun_images=()
    
    local target_minor=$(get_minor_version "$target_bun_version")
    
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
                # Check for compatible match (same minor version)
                elif [ -n "$bun_ver" ] && version_compatible "$bun_ver" "$target_bun_version"; then
                    compatible_images+=("$image_name")
                    log "    🔄 Compatible match (same minor version: $(get_minor_version "$bun_ver"))" >&2
                # Check for usable match (different minor but could bootstrap)
                elif [ -n "$bun_ver" ] && [ "$bun_ver" != "$target_bun_version" ]; then
                    usable_images+=("$image_name")
                    log "    🔧 Usable base (different minor: $(get_minor_version "$bun_ver"))" >&2
                fi
            fi
        fi
    done <<< "$tart_output"
    
    # Find best compatible image (highest version with same minor)
    local best_compatible=""
    if [ ${#compatible_images[@]} -gt 0 ]; then
        local best_compatible_version=""
        for image in "${compatible_images[@]}"; do
            local version_info=$(parse_image_name "$image")
            local bun_ver="${version_info%|*}"
            if [ -z "$best_compatible_version" ] || version_compare "$bun_ver" "$best_compatible_version"; then
                best_compatible="$image"
                best_compatible_version="$bun_ver"
            fi
        done
        log "  🎯 Best compatible: $best_compatible (Bun: $best_compatible_version)" >&2
    fi
    
    # Return results (format: exact|compatible|usable|all)
    local compatible_list=""
    if [ -n "$best_compatible" ]; then
        compatible_list="$best_compatible"
    fi
    
    local usable_list=""
    if [ ${#usable_images[@]} -gt 0 ]; then
        usable_list=$(IFS=','; echo "${usable_images[*]}")
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
    
    # Check if we have credentials
    if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_USERNAME:-}" ]; then
        log "   Using GitHub credentials from environment" >&2
        export TART_REGISTRY_USERNAME="$GITHUB_USERNAME"
        export TART_REGISTRY_PASSWORD="$GITHUB_TOKEN"
        auth_setup=true
    elif [ -f /tmp/github-token.txt ] && [ -f /tmp/github-username.txt ]; then
        log "   Using GitHub credentials from legacy files" >&2
        local file_token=$(cat /tmp/github-token.txt 2>/dev/null || echo "")
        local file_username=$(cat /tmp/github-username.txt 2>/dev/null || echo "")
        if [ -n "$file_token" ] && [ -n "$file_username" ]; then
            export TART_REGISTRY_USERNAME="$file_username"
            export TART_REGISTRY_PASSWORD="$file_token"
            auth_setup=true
        fi
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
    
    # Wait for VM to boot
    sleep 30
    
    # Get VM IP (redirect stderr to avoid pollution)
    local vm_ip=""
    for i in {1..10}; do
        vm_ip=$(tart ip "$image_name" 2>/dev/null || echo "")
        if [ -n "$vm_ip" ]; then
            break
        fi
        sleep 5
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
        sleep 3
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
    
    # Wait a bit for graceful shutdown
    sleep 10
    
    # Force kill if still running (redirect all output)
    kill $vm_pid >/dev/null 2>&1 || true
    
    # Wait for complete cleanup
    sleep 5
    
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
    
    log "🧠 Making smart caching decision..." >&2
    log "  Target: Bun $target_bun_version, Bootstrap $target_bootstrap_version" >&2
    log "  Force refresh: $force_refresh" >&2
    log "  Force remote refresh: $force_remote_refresh" >&2
    log "  Local dev mode: $local_dev_mode" >&2
    
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
    
    # Priority 1: Exact local match - but validate it has required tools
    if [ -n "$exact_match" ]; then
        log "🔍 Found exact local match: $exact_match - validating tools..." >&2
        if validate_vm_image_tools "$exact_match"; then
            log "🎯 Decision: Use exact local match ($exact_match)" >&2
            echo "use_local_exact|$exact_match"
            return
        else
            log "⚠️  Exact match failed validation - deleting corrupted image" >&2
            tart delete "$exact_match" 2>/dev/null || log "   Failed to delete corrupted image" >&2
            # Continue to other options
        fi
    fi
    
    # Priority 2: Compatible local match (same minor version - incremental update)
    if [ -n "$compatible_match" ]; then
        log "🔍 Found compatible local match: $compatible_match - validating tools..." >&2
        if validate_vm_image_tools "$compatible_match"; then
            log "🔄 Compatible local image found: $compatible_match" >&2
            log "🎯 Decision: Build incrementally from compatible local base" >&2
            echo "build_incremental|$compatible_match"
            return
        else
            log "⚠️  Compatible match failed validation - deleting corrupted image" >&2
            tart delete "$compatible_match" 2>/dev/null || log "   Failed to delete corrupted image" >&2
            # Continue to remote check
        fi
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

# Main execution
main() {
    # Parse arguments
    local force_refresh=false
    local cleanup_only=false
    local force_rebuild_all=false
    local force_remote_refresh=false
    local local_dev_mode=false
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
    local caching_decision=$(make_caching_decision "$BUN_VERSION" "$BOOTSTRAP_VERSION" "$LOCAL_IMAGE_NAME" "$REMOTE_IMAGE_URL" "$force_refresh" "$force_remote_refresh" "$local_dev_mode")
    
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
    if [ -n "${INCREMENTAL_BASE_IMAGE:-}" ]; then
        log "=== BUILDING INCREMENTAL IMAGE ==="
        log "Building incremental image for Bun ${BUN_VERSION} from base: $INCREMENTAL_BASE_IMAGE"
        
        # Clean up the specific image we're about to build (if it exists)
        log "Cleaning up target image if it exists: $LOCAL_IMAGE_NAME"
        tart delete "$LOCAL_IMAGE_NAME" 2>/dev/null || log "Target image doesn't exist (expected)"
        
        # Clone from incremental base instead of raw macOS image
        log "Cloning from incremental base: $INCREMENTAL_BASE_IMAGE"
        tart clone "$INCREMENTAL_BASE_IMAGE" "$LOCAL_IMAGE_NAME"
        log "✅ Incremental base cloned"
        
        # Allocate VM resources for build performance
        log "Allocating VM resources for build performance..."
        log "  Setting memory: ${MACOS_VM_MEMORY:-16384}MB (${MACOS_VM_CONFIG_DESCRIPTION:-default configuration})"
        log "  Setting CPUs: ${MACOS_VM_CPU:-8} cores"
        tart set "$LOCAL_IMAGE_NAME" --memory "${MACOS_VM_MEMORY:-16384}" --cpu "${MACOS_VM_CPU:-8}"
        log "✅ VM resources allocated"
        
        IS_INCREMENTAL_BUILD=true
    else
        log "=== BUILDING NEW BASE IMAGE ==="
        log "Building new base image for Bun ${BUN_VERSION}..."
        
        # Clean up the specific image we're about to build (if it exists)
        log "Cleaning up target image if it exists: $LOCAL_IMAGE_NAME"
        tart delete "$LOCAL_IMAGE_NAME" 2>/dev/null || log "Target image doesn't exist (expected)"
        
        # Clone base image
        log "Cloning base image: $BASE_IMAGE"
        tart clone "$BASE_IMAGE" "$LOCAL_IMAGE_NAME"
        log "✅ Base image cloned"
        
        IS_INCREMENTAL_BUILD=false
    fi
    
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