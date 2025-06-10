#!/bin/bash

# last updated 2025-06-10 - FIXED VERSION
# Fixed critical issues: REAL_USER definition, monitoring defaults, error handling
#
# Environment Variables (optional - will be prompted if not set):
# - BUILDKITE_AGENT_TOKEN: Your Buildkite agent token (required)
# - GITHUB_USERNAME: GitHub username for ghcr.io pushes (required)  
# - GITHUB_TOKEN: GitHub token for ghcr.io pushes (required)
# - MACHINE_LOCATION: Machine location identifier (default: office-1)
# - COMPUTER_NAME: Computer name (default: system hostname)
# - MONITORING_ENABLED: Enable monitoring (true/false, default: prompt)
# - MONITORING_TYPE: Type of monitoring - "grafana-cloud" or "self-hosted" (default: grafana-cloud)
# - GRAFANA_CLOUD_USER: Grafana Cloud username/instance ID (required if MONITORING_TYPE=grafana-cloud)
# - GRAFANA_CLOUD_API_KEY: Grafana Cloud API key (required if MONITORING_TYPE=grafana-cloud)
# - GRAFANA_CLOUD_PROMETHEUS_URL: Grafana Cloud Prometheus endpoint (required if MONITORING_TYPE=grafana-cloud)
# - GRAFANA_CLOUD_LOKI_URL: Grafana Cloud Loki endpoint (required if MONITORING_TYPE=grafana-cloud)
# - PROMETHEUS_URL: Prometheus URL (required if MONITORING_TYPE=self-hosted, default: http://localhost:9090)
# - LOKI_URL: Loki URL (required if MONITORING_TYPE=self-hosted, default: http://localhost:3100)
# - GRAFANA_URL: Grafana URL (required if MONITORING_TYPE=self-hosted, default: http://localhost:3000)
# - VPN_ENABLED: Enable VPN setup (true/false, default: prompt)
# - VPN_TYPE: VPN type - "tailscale", "wireguard", "unifi", "cloudflare", or "none"
# - TAILSCALE_AUTH_KEY: Tailscale authentication key (optional)
# - WIREGUARD_PRIVATE_KEY: WireGuard private key (required if VPN_TYPE=wireguard)
# - WIREGUARD_PUBLIC_KEY: WireGuard peer public key (required if VPN_TYPE=wireguard)
# - WIREGUARD_ENDPOINT: WireGuard endpoint (required if VPN_TYPE=wireguard)
# - UNIFI_VPN_USER: UniFi VPN username (required if VPN_TYPE=unifi)
# - UNIFI_VPN_PASSWORD: UniFi VPN password (required if VPN_TYPE=unifi)
# - UNIFI_VPN_SERVER: UniFi VPN server (required if VPN_TYPE=unifi)
# - CLOUDFLARE_TUNNEL_TOKEN: Cloudflare Tunnel token (required if VPN_TYPE=cloudflare)
# - AUTO_CONFIRM: Skip confirmation prompts (true/false, default: false)
#
# Example:
# MONITORING_ENABLED=true MONITORING_TYPE=grafana-cloud ./setup-mac-server-fixed.sh
#
# Example with monitoring disabled and Tailscale VPN:
# MONITORING_ENABLED=false VPN_ENABLED=true VPN_TYPE=tailscale ./setup-mac-server-fixed.sh
#
# Example with full environment variables (non-interactive):
# BUILDKITE_AGENT_TOKEN=xxx GITHUB_USERNAME=myuser GITHUB_TOKEN=xxx \
# MONITORING_ENABLED=true MONITORING_TYPE=grafana-cloud \
# GRAFANA_CLOUD_USER=123456 GRAFANA_CLOUD_API_KEY=xxx \
# VPN_ENABLED=true VPN_TYPE=tailscale TAILSCALE_AUTH_KEY=xxx \
# AUTO_CONFIRM=true ./setup-mac-server-fixed.sh

set -euo pipefail


# Only show welcome/confirmation if not already in privileged (sudo/root) mode
if [ "$EUID" -ne 0 ]; then
  # --- Determine target CI user upfront ---
  # This is critical - we need to know who the CI user will be before installing anything
  if [ -n "$SUDO_USER" ]; then
    # Script was run with sudo, use the original user
    TARGET_CI_USER="$SUDO_USER"
  else
    # Script run directly, current user will be CI user
    TARGET_CI_USER="$USER"
  fi
  
  echo_color "$BLUE" "Target CI user will be: $TARGET_CI_USER"
  
  # --- Welcome message ---
  echo -e "\033[1;36m" # Cyan bold
  cat <<WELCOME
Bun.sh On-Prem Mac CI Server Setup
==================================
This script will:
  - Install and configure Homebrew and dependencies for user: $TARGET_CI_USER
  - Set up Buildkite agent, Prometheus, Grafana, and Tart
  - Configure VPN (WireGuard, Tailscale, or UniFi)
  - Set up SSH and system security
  - Configure your Mac to never sleep (server mode)
  - Create base Tart VMs (optional)
  - Start all required services

You will be prompted for secrets and configuration details.
WELCOME
  echo -e "\033[1;33mWARNING: This script will make system-level changes and should be run on a dedicated CI/server Mac.\033[0m"

  if [ "${AUTO_CONFIRM:-false}" = true ]; then
    confirm_start="y"
    echo -e "\033[1;32mAUTO_CONFIRM enabled: Continuing with setup...\033[0m"
  else
    read -rp $'\033[1;32mContinue with setup? (y/n): \033[0m' confirm_start
  fi
  if [[ "$confirm_start" != "y" ]]; then
    echo -e "\033[0;31mAborted by user.\033[0m"
    exit 1
  fi
  echo -e "\033[0m" # Reset color
fi

# --- Color codes ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

LOGFILE="setup-mac-server.log"
exec > >(tee -a "$LOGFILE") 2>&1

# --- Prompt helpers ---
echo_color() { echo -e "$1$2${NC}"; }

# --- Check if script is being re-executed as root ---
if [ "$EUID" -eq 0 ] && [ -n "${BUILDKITE_AGENT_TOKEN:-}" ]; then
  echo_color "$BLUE" "Re-executing as root. Skipping prompts..."
  # Jump to privileged setup section
  goto_privileged_setup=true
else
  goto_privileged_setup=false
fi

# --- Prompt for all inputs up front ---
if [ "$goto_privileged_setup" = false ]; then
  echo -e "${BLUE}Bun.sh On-Prem CI Setup${NC}"
  echo "--------------------------------"

  prompt_secret() {
    local var_name=$1
    local prompt_text=$2
    local input=""
    local char

    printf "%s: " "$prompt_text"
    stty -echo
    while IFS= read -r -s -n1 char; do
      # Enter key (newline) ends input
      if [[ $char == $'\0' || $char == $'\n' ]]; then
        break
      fi
      # Backspace handling
      if [[ $char == $'\177' ]]; then
        if [ -n "$input" ]; then
          input="${input%?}"
          printf '\b \b'
        fi
      else
        input+="$char"
        printf '•'
      fi
    done
    stty echo
    echo
    if [ -n "$input" ]; then
      eval "$var_name=\"$input\""
    else
      echo_color "$RED" "Value required."
      prompt_secret "$var_name" "$prompt_text"
    fi
  }

  prompt_text() {
    local var_name=$1
    local prompt_text=$2
    local default_value=${3:-}
    read -rp "$prompt_text${default_value:+ [$default_value]}: " input
    input=${input:-$default_value}
    eval "$var_name=\"$input\""
  }

  # 0. VPN type selection (always shown)
  if [ -z "${VPN_ENABLED:-}" ] || [ -z "${VPN_TYPE:-}" ]; then
    while true; do
      echo_color "$BLUE" "Select VPN type:"
      echo "  0) None"
      echo "  1) Tailscale (default)"
      echo "  2) WireGuard"
      echo "  3) UniFi VPN"
      echo "  4) Cloudflare Tunnel"
      read -rp "Choice [1]: " vpn_choice
      case "${vpn_choice:-1}" in
        0) VPN_TYPE="none"; VPN_ENABLED=false; break ;;
        1|"") VPN_TYPE="tailscale"; VPN_ENABLED=true; break ;;
        2) VPN_TYPE="wireguard"; VPN_ENABLED=true; break ;;
        3) VPN_TYPE="unifi"; VPN_ENABLED=true; break ;;
        4) VPN_TYPE="cloudflare"; VPN_ENABLED=true; break ;;
        *) echo_color "$YELLOW" "Invalid choice. Please enter 0, 1, 2, 3, or 4." ;;
      esac
    done
  else
    # If VPN variables are set via environment, validate them
    case "${VPN_TYPE}" in
      none) VPN_ENABLED=false ;;
      tailscale|wireguard|unifi|cloudflare) VPN_ENABLED=true ;;
      *) echo_color "$RED" "Invalid VPN_TYPE: $VPN_TYPE. Valid options: none, tailscale, wireguard, unifi, cloudflare"; exit 1 ;;
    esac
  fi

  # 0.5. Monitoring setup selection
  if [ -z "${MONITORING_ENABLED:-}" ]; then
    while true; do
      echo_color "$BLUE" "Enable monitoring and logging?"
      echo "  0) No monitoring (default)"
      echo "  1) Grafana Cloud"
      echo "  2) Self-hosted Grafana/Prometheus"
      read -rp "Choice [0]: " monitoring_choice
      case "${monitoring_choice:-0}" in
        0) MONITORING_ENABLED=false; break ;;
        1) MONITORING_ENABLED=true; MONITORING_TYPE="grafana-cloud"; break ;;
        2) MONITORING_ENABLED=true; MONITORING_TYPE="self-hosted"; break ;;
        *) echo_color "$YELLOW" "Invalid choice. Please enter 0, 1, or 2." ;;
      esac
    done
  else
    # If MONITORING_ENABLED is set via environment variable, set MONITORING_TYPE if not already set
    if [ "$MONITORING_ENABLED" = true ] && [ -z "${MONITORING_TYPE:-}" ]; then
      MONITORING_TYPE="${MONITORING_TYPE:-grafana-cloud}"  # Default to grafana-cloud if not specified
    fi
  fi

  # 1. Buildkite token
  if [ -z "${BUILDKITE_AGENT_TOKEN:-}" ]; then
    prompt_secret BUILDKITE_AGENT_TOKEN "Enter your Buildkite Agent Token"
  fi

  # 1b. GitHub username and token for ghcr.io pushes
  if [ -z "${GITHUB_USERNAME:-}" ]; then
    prompt_text GITHUB_USERNAME "Enter your GitHub Username (for ghcr.io pushes)"
  fi
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    prompt_secret GITHUB_TOKEN "Enter your GitHub Token (for ghcr.io pushes)"
  fi

  # 1c. Monitoring credentials (if enabled)
  if [ "$MONITORING_ENABLED" = true ]; then
    case "$MONITORING_TYPE" in
      grafana-cloud)
        echo_color "$BLUE" "Grafana Cloud Configuration:"
        if [ -z "${GRAFANA_CLOUD_USER:-}" ]; then
          prompt_text GRAFANA_CLOUD_USER "Enter Grafana Cloud username/instance ID"
        fi
        if [ -z "${GRAFANA_CLOUD_API_KEY:-}" ]; then
          prompt_secret GRAFANA_CLOUD_API_KEY "Enter Grafana Cloud API key"
        fi
        if [ -z "${GRAFANA_CLOUD_PROMETHEUS_URL:-}" ]; then
          prompt_text GRAFANA_CLOUD_PROMETHEUS_URL "Enter Prometheus endpoint URL" "https://prometheus-prod-XX-XXX.grafana.net/api/prom/push"
        fi
        if [ -z "${GRAFANA_CLOUD_LOKI_URL:-}" ]; then
          prompt_text GRAFANA_CLOUD_LOKI_URL "Enter Loki endpoint URL" "https://logs-prod-XXX.grafana.net/loki/api/v1/push"
        fi
        ;;
      self-hosted)
        echo_color "$BLUE" "Self-hosted Grafana Configuration:"
        if [ -z "${PROMETHEUS_URL:-}" ]; then
          prompt_text PROMETHEUS_URL "Enter Prometheus URL" "http://localhost:9090"
        fi
        if [ -z "${LOKI_URL:-}" ]; then
          prompt_text LOKI_URL "Enter Loki URL" "http://localhost:3100"
        fi
        if [ -z "${GRAFANA_URL:-}" ]; then
          prompt_text GRAFANA_URL "Enter Grafana URL" "http://localhost:3000"
        fi
        ;;
    esac
  fi

  # Create dedicated CI keychain and store credentials securely
  CI_KEYCHAIN="$REAL_HOME/Library/Keychains/bun-ci.keychain-db"
  CI_KEYCHAIN_PASSWORD=$(openssl rand -base64 32)

  echo_color "$BLUE" "Creating secure CI keychain..."
  # Create the keychain
  security create-keychain -p "$CI_KEYCHAIN_PASSWORD" "$CI_KEYCHAIN"
  # Add to keychain search list
  security list-keychains -d user -s "$CI_KEYCHAIN" $(security list-keychains -d user | sed s/\"//g)
  # Set keychain to not lock automatically and not require password for access
  security set-keychain-settings "$CI_KEYCHAIN"
  # Unlock the keychain (it will stay unlocked due to settings above)
  security unlock-keychain -p "$CI_KEYCHAIN_PASSWORD" "$CI_KEYCHAIN"

  # Store GitHub credentials in the CI keychain
  echo_color "$BLUE" "Storing GitHub credentials in secure keychain..."
  security add-generic-password -a "bun-ci" -s "github-username" -w "$GITHUB_USERNAME" -k "$CI_KEYCHAIN"
  security add-generic-password -a "bun-ci" -s "github-token" -w "$GITHUB_TOKEN" -k "$CI_KEYCHAIN"

  # Store monitoring credentials in the CI keychain (if enabled)
  if [ "$MONITORING_ENABLED" = true ]; then
    echo_color "$BLUE" "Storing monitoring credentials in secure keychain..."
    case "$MONITORING_TYPE" in
      grafana-cloud)
        security add-generic-password -a "bun-ci" -s "grafana-cloud-user" -w "$GRAFANA_CLOUD_USER" -k "$CI_KEYCHAIN"
        security add-generic-password -a "bun-ci" -s "grafana-cloud-api-key" -w "$GRAFANA_CLOUD_API_KEY" -k "$CI_KEYCHAIN"
        security add-generic-password -a "bun-ci" -s "grafana-cloud-prometheus-url" -w "$GRAFANA_CLOUD_PROMETHEUS_URL" -k "$CI_KEYCHAIN"
        security add-generic-password -a "bun-ci" -s "grafana-cloud-loki-url" -w "$GRAFANA_CLOUD_LOKI_URL" -k "$CI_KEYCHAIN"
        ;;
      self-hosted)
        security add-generic-password -a "bun-ci" -s "prometheus-url" -w "$PROMETHEUS_URL" -k "$CI_KEYCHAIN"
        security add-generic-password -a "bun-ci" -s "loki-url" -w "$LOKI_URL" -k "$CI_KEYCHAIN"
        security add-generic-password -a "bun-ci" -s "grafana-url" -w "$GRAFANA_URL" -k "$CI_KEYCHAIN"
        ;;
    esac
  fi

  # Store keychain password securely for later access
  echo "$CI_KEYCHAIN_PASSWORD" > "$REAL_HOME/.buildkite-agent/ci-keychain-password.txt"
  chmod 600 "$REAL_HOME/.buildkite-agent/ci-keychain-password.txt"
  chown "$REAL_USER:staff" "$REAL_HOME/.buildkite-agent/ci-keychain-password.txt"

  # Set ownership of keychain
  chown "$REAL_USER:staff" "$CI_KEYCHAIN"

  echo_color "$GREEN" "✅ Credentials stored securely in CI keychain"

  # 2. Prometheus credentials (commented out for now)
  # prompt_secret PROMETHEUS_USER "Enter Prometheus admin username" "admin"
  # prompt_secret PROMETHEUS_PASSWORD "Enter Prometheus admin password"

  # 3. VPN details (if enabled)
  if [ "$VPN_ENABLED" = true ]; then
    case "$VPN_TYPE" in
      wireguard)
        prompt_secret WIREGUARD_PRIVATE_KEY "Enter WireGuard private key"
        prompt_secret WIREGUARD_PUBLIC_KEY "Enter WireGuard peer public key"
        prompt_text WIREGUARD_ENDPOINT "Enter WireGuard endpoint" "vpn.example.com"
        ;;
      tailscale)
        prompt_secret TAILSCALE_AUTH_KEY "Enter Tailscale auth key (optional)"
        ;;
      unifi)
        prompt_text UNIFI_VPN_USER "Enter UniFi VPN username" ""
        prompt_secret UNIFI_VPN_PASSWORD "Enter UniFi VPN password"
        prompt_text UNIFI_VPN_SERVER "Enter UniFi VPN server" ""
        ;;
      cloudflare)
        prompt_secret CLOUDFLARE_TUNNEL_TOKEN "Enter Cloudflare Tunnel token"
        ;;
    esac
  fi

  # 4. Optional network config
  if [ -z "${BUILD_VLAN:-}" ]; then
    prompt_text BUILD_VLAN "Build VLAN" "10.0.1.0/24"
  fi
  if [ -z "${MGMT_VLAN:-}" ]; then
    prompt_text MGMT_VLAN "Management VLAN" "10.0.2.0/24"
  fi
  if [ -z "${STORAGE_VLAN:-}" ]; then
    prompt_text STORAGE_VLAN "Storage VLAN" "10.0.3.0/24"
  fi
  
  # 5. Machine location (with default and validation)
  MACHINE_LOCATION="${MACHINE_LOCATION:-office-1}"  # Set default value if not set
  if [ -z "$MACHINE_LOCATION" ]; then
    prompt_text MACHINE_LOCATION "Enter machine location (e.g., office-1, datacenter-2)" "office-1"
  fi
  
  # Validate MACHINE_LOCATION is set
  if [ -z "$MACHINE_LOCATION" ]; then
    echo_color "$RED" "Error: Machine location cannot be empty"
    exit 1
  fi

  # Get computer name
  if [ -z "${COMPUTER_NAME:-}" ]; then
    COMPUTER_NAME=$(scutil --get ComputerName 2>/dev/null || hostname)
    prompt_text COMPUTER_NAME "Enter computer name" "$COMPUTER_NAME"
  fi

  echo_color "$BLUE" "Debug: Machine info set:"
  echo_color "$BLUE" "  Location: $MACHINE_LOCATION"
  echo_color "$BLUE" "  Computer Name: $COMPUTER_NAME"

  # --- Show summary and confirm ---
  echo_color "$YELLOW" "\nSummary of your choices:"
  echo "  Buildkite Agent Token:   [hidden]"
  echo "  GitHub Username:         $GITHUB_USERNAME"
  echo "  GitHub Token:            [hidden]"
  echo "  Machine Location:        $MACHINE_LOCATION"
  if [ "$VPN_ENABLED" = true ]; then
    echo "  VPN Type:                 $VPN_TYPE"
    case "$VPN_TYPE" in
      wireguard)
        echo "  WireGuard Endpoint:       $WIREGUARD_ENDPOINT" ;;
      tailscale)
        echo "  Tailscale Auth Key:       [hidden]" ;;
      unifi)
        echo "  UniFi VPN User:           $UNIFI_VPN_USER"
        echo "  UniFi VPN Server:         $UNIFI_VPN_SERVER" ;;
      cloudflare)
        echo "  Cloudflare Tunnel Token:  [hidden]" ;;
    esac
  else
    echo "  VPN Setup:                Skipped"
  fi
  if [ "$MONITORING_ENABLED" = true ]; then
    echo "  Monitoring Type:          $MONITORING_TYPE"
    case "$MONITORING_TYPE" in
      grafana-cloud)
        echo "  Grafana Cloud User:       $GRAFANA_CLOUD_USER"
        echo "  Grafana Cloud API Key:    [hidden]"
        echo "  Prometheus URL:           $GRAFANA_CLOUD_PROMETHEUS_URL"
        echo "  Loki URL:                 $GRAFANA_CLOUD_LOKI_URL" ;;
      self-hosted)
        echo "  Prometheus URL:           $PROMETHEUS_URL"
        echo "  Loki URL:                 $LOKI_URL"
        echo "  Grafana URL:              $GRAFANA_URL" ;;
    esac
  else
    echo "  Monitoring Setup:         Disabled"
  fi
  echo "  Build VLAN:               $BUILD_VLAN"
  echo "  Management VLAN:          $MGMT_VLAN"
  echo "  Storage VLAN:             $STORAGE_VLAN"

  if [ "${AUTO_CONFIRM:-false}" = true ]; then
    confirm="y"
    echo_color "$GREEN" "AUTO_CONFIRM enabled: Proceeding with installation..."
  else
    read -rp "Proceed with installation? (y/n): " confirm
  fi
  if [[ "$confirm" != "y" ]]; then
    echo_color "$RED" "Aborted by user."
    exit 1
  fi

  # --- After all variables are set, but before proceeding with setup ---

  # List of required variables
  REQUIRED_VARS=(BUILDKITE_AGENT_TOKEN GITHUB_USERNAME GITHUB_TOKEN MACHINE_LOCATION COMPUTER_NAME)
  MISSING_VARS=()

  for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
      MISSING_VARS+=("$var")
    fi
  done

  if [ ${#MISSING_VARS[@]} -ne 0 ]; then
    echo_color "$RED" "\nERROR: The following required variables are missing: ${MISSING_VARS[*]}"
    echo_color "$YELLOW" "Please set them as environment variables or provide them interactively."
    exit 1
  else
    echo_color "$GREEN" "\nAll required variables are set:"
    for var in "${REQUIRED_VARS[@]}"; do
      if [[ "$var" == *TOKEN* ]]; then
        echo_color "$GREEN" "  $var: [hidden]"
      else
        echo_color "$GREEN" "  $var: ${!var}"
      fi
    done
  fi

  # --- Homebrew install section (user) ---
  if [ "$EUID" -ne 0 ]; then
    echo_color "$BLUE" "\n[1/3] Installing Homebrew and dependencies for $TARGET_CI_USER..."
    
    # Set REAL_USER consistently from the start
    REAL_USER="$TARGET_CI_USER"
    REAL_HOME=$(eval echo ~$REAL_USER)
    
    echo_color "$BLUE" "Installing as user: $REAL_USER"
    echo_color "$BLUE" "Home directory: $REAL_HOME"
    
    # Function to run commands as target CI user
    run_as_ci_user() {
      if [ "$USER" = "$TARGET_CI_USER" ]; then
        # Already running as target user
        bash -c "$1"
      else
        # Need to switch to target user
        sudo -u "$TARGET_CI_USER" -i bash -c "$1"
      fi
    }
    
    # Check if Homebrew already exists for the target user
    echo_color "$BLUE" "Checking Homebrew installation for $TARGET_CI_USER..."
    if run_as_ci_user 'command -v brew' &>/dev/null; then
      echo_color "$GREEN" "✅ Homebrew already installed for $TARGET_CI_USER"
    else
      # Check if Homebrew exists but not in PATH
      if run_as_ci_user '[ -f "/opt/homebrew/bin/brew" ]'; then
        echo_color "$BLUE" "Found Homebrew at /opt/homebrew, adding to PATH for $TARGET_CI_USER..."
        run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv)" && echo '\''eval "$(/opt/homebrew/bin/brew shellenv)"'\'' >> ~/.zprofile'
      elif run_as_ci_user '[ -f "/usr/local/bin/brew" ]'; then
        echo_color "$BLUE" "Found Homebrew at /usr/local, adding to PATH for $TARGET_CI_USER..."
        run_as_ci_user 'eval "$(/usr/local/bin/brew shellenv)" && echo '\''eval "$(/usr/local/bin/brew shellenv)"'\'' >> ~/.bash_profile'
      else
        # Install Homebrew as target CI user
        echo_color "$YELLOW" "Installing Homebrew for $TARGET_CI_USER..."
        run_as_ci_user '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        
        # Set up PATH for target user
        if run_as_ci_user '[ -d "/opt/homebrew/bin" ]'; then
          run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv)" && echo '\''eval "$(/opt/homebrew/bin/brew shellenv)"'\'' >> ~/.zprofile'
        elif run_as_ci_user '[ -d "/usr/local/bin" ]'; then
          run_as_ci_user 'eval "$(/usr/local/bin/brew shellenv)" && echo '\''eval "$(/usr/local/bin/brew shellenv)"'\'' >> ~/.bash_profile'
        fi
      fi
      
      # Verify Homebrew is now accessible
      if ! run_as_ci_user 'command -v brew' &>/dev/null; then
        echo_color "$RED" "Homebrew installation failed for $TARGET_CI_USER. Aborting."
        exit 1
      fi
      echo_color "$GREEN" "✅ Homebrew installed successfully for $TARGET_CI_USER"
    fi
    
    # Install packages as target CI user
    echo_color "$BLUE" "Installing CI dependencies as $TARGET_CI_USER..."
    
    # Install Tailscale
    run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)" && brew install tailscale'
    if ! run_as_ci_user 'command -v tailscale' &>/dev/null; then
      echo_color "$RED" "Tailscale installation failed for $TARGET_CI_USER. Aborting."
      exit 1
    fi
    
    # Install Buildkite agent
    echo_color "$BLUE" "Installing Buildkite agent for $TARGET_CI_USER..."
    if run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)" && brew tap buildkite/buildkite && brew install buildkite/buildkite/buildkite-agent'; then
      echo_color "$GREEN" "✅ Buildkite agent tap and install completed"
    else
      echo_color "$RED" "❌ Buildkite agent installation failed for $TARGET_CI_USER. Aborting."
      exit 1
    fi
    
    # Verify buildkite-agent is accessible
    if ! run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)" && command -v buildkite-agent' &>/dev/null; then
      echo_color "$RED" "❌ Buildkite agent not accessible after installation for $TARGET_CI_USER. Aborting."
      echo_color "$YELLOW" "Debug: Checking brew list..."
      run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)" && brew list | grep buildkite || echo "No buildkite packages found"'
      exit 1
    fi
    echo_color "$GREEN" "✅ Buildkite agent installed and accessible for $TARGET_CI_USER"
    
    # Install other CI tools
    echo_color "$BLUE" "Installing other CI dependencies for $TARGET_CI_USER..."
    run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)" && brew install terraform jq yq wget git wireguard-tools openvpn node cmake ninja ccache pkg-config golang make python3 libtool ruby perl'
    
    # Install monitoring tools if enabled
    if [ "${MONITORING_ENABLED:-false}" = true ]; then
      echo_color "$BLUE" "Installing monitoring tools for $TARGET_CI_USER..."
      run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)" && brew tap grafana/grafana' || echo_color "$YELLOW" "⚠️ Failed to add Grafana tap"
      run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)" && brew install grafana/grafana/alloy' || echo_color "$YELLOW" "⚠️ Failed to install Grafana Alloy"
      run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)" && brew install prometheus-node-exporter' || echo_color "$YELLOW" "⚠️ Failed to install Node Exporter"
      echo_color "$GREEN" "✅ Monitoring tools installation completed for $TARGET_CI_USER"
    fi
    
    # Verify Node.js installation
    if ! run_as_ci_user 'command -v node' &>/dev/null; then
      echo_color "$RED" "Node.js installation failed for $TARGET_CI_USER. Aborting."
      exit 1
    fi
    NODE_VERSION=$(run_as_ci_user 'node --version')
    echo_color "$GREEN" "✅ Node.js installed for $TARGET_CI_USER (version: $NODE_VERSION)"

    # Install Tart
    if ! run_as_ci_user 'command -v tart' &>/dev/null; then
      echo_color "$YELLOW" "Installing Tart for $TARGET_CI_USER..."
      run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)" && brew tap cirruslabs/cli'
      run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)" && brew install cirruslabs/cli/tart'
      if run_as_ci_user 'command -v tart' &>/dev/null; then
        echo_color "$GREEN" "✅ Tart installed successfully for $TARGET_CI_USER"
      else
        echo_color "$RED" "Tart installation failed for $TARGET_CI_USER. Aborting."
        exit 1
      fi
    else
      echo_color "$GREEN" "✅ Tart already installed for $TARGET_CI_USER"
    fi

    # Install sshpass
    if ! run_as_ci_user 'command -v sshpass' &>/dev/null; then
      echo_color "$YELLOW" "Installing sshpass for $TARGET_CI_USER..."
      run_as_ci_user 'eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)" && brew install cirruslabs/cli/sshpass' || echo_color "$YELLOW" "⚠️ Failed to install sshpass"
      if run_as_ci_user 'command -v sshpass' &>/dev/null; then
        echo_color "$GREEN" "✅ sshpass installed successfully for $TARGET_CI_USER"
      else
        echo_color "$YELLOW" "⚠️ sshpass installation may have failed - VM access may not work"
      fi
    else
      echo_color "$GREEN" "✅ sshpass already installed for $TARGET_CI_USER"
    fi

    echo_color "$GREEN" "✅ All dependencies installed for $TARGET_CI_USER"
    echo_color "$BLUE" "Switching to root for system configuration..."
    
    # Export all variables including TARGET_CI_USER for privileged section
    export_vars="TARGET_CI_USER=\"$TARGET_CI_USER\" BUILDKITE_AGENT_TOKEN=\"$BUILDKITE_AGENT_TOKEN\" VPN_ENABLED=\"$VPN_ENABLED\" BUILD_VLAN=\"$BUILD_VLAN\" MGMT_VLAN=\"$MGMT_VLAN\" STORAGE_VLAN=\"$STORAGE_VLAN\" MACHINE_LOCATION=\"$MACHINE_LOCATION\" COMPUTER_NAME=\"$COMPUTER_NAME\""
    
    # Add monitoring variables
    export_vars+=" MONITORING_ENABLED=\"$MONITORING_ENABLED\""
    if [ "$MONITORING_ENABLED" = true ]; then
      export_vars+=" MONITORING_TYPE=\"$MONITORING_TYPE\""
    fi
    
    if [ "$VPN_ENABLED" = true ]; then
      export_vars+=" VPN_TYPE=\"$VPN_TYPE\""
      case "$VPN_TYPE" in
        wireguard)
          export_vars+=" WIREGUARD_PRIVATE_KEY=\"$WIREGUARD_PRIVATE_KEY\" WIREGUARD_PUBLIC_KEY=\"$WIREGUARD_PUBLIC_KEY\" WIREGUARD_ENDPOINT=\"$WIREGUARD_ENDPOINT\"" ;;
        tailscale)
          export_vars+=" TAILSCALE_AUTH_KEY=\"$TAILSCALE_AUTH_KEY\"" ;;
        unifi)
          export_vars+=" UNIFI_VPN_USER=\"$UNIFI_VPN_USER\" UNIFI_VPN_PASSWORD=\"$UNIFI_VPN_PASSWORD\" UNIFI_VPN_SERVER=\"$UNIFI_VPN_SERVER\"" ;;
        cloudflare)
          export_vars+=" CLOUDFLARE_TUNNEL_TOKEN=\"$CLOUDFLARE_TUNNEL_TOKEN\"" ;;
      esac
    fi
    eval exec sudo $export_vars "$0" "$@"
  fi
fi

# --- Privileged setup (root) ---
echo_color "$BLUE" "\n[2/3] Running privileged setup..."

# Use TARGET_CI_USER passed from first section, fallback to detection if not available
if [ -n "${TARGET_CI_USER:-}" ]; then
  REAL_USER="$TARGET_CI_USER"
  echo_color "$BLUE" "Using TARGET_CI_USER from first section: $REAL_USER"
else
  # Fallback to detection (for direct root execution)
  REAL_USER="${SUDO_USER:-$USER}"
  echo_color "$YELLOW" "TARGET_CI_USER not set, falling back to detection: $REAL_USER"
fi
REAL_HOME=$(eval echo ~$REAL_USER)

echo_color "$BLUE" "Setting up CI for user $REAL_USER..."
echo_color "$BLUE" "Debug: REAL_USER=$REAL_USER"
echo_color "$BLUE" "Debug: REAL_HOME=$REAL_HOME"

# Create necessary directories in user's home
CI_DIRS=(
    "$REAL_HOME/.buildkite-agent"
    "$REAL_HOME/.buildkite-agent/hooks"
    "$REAL_HOME/builds"
    "$REAL_HOME/plugins"
    "$REAL_HOME/.tart"
    "$REAL_HOME/.tart/tmp"
    "$REAL_HOME/.tart/cache"
    "$REAL_HOME/.tart/vms"
)

echo_color "$BLUE" "Creating CI directories..."
for dir in "${CI_DIRS[@]}"; do
    echo_color "$BLUE" "  Creating: $dir"
    mkdir -p "$dir"
    if [ -d "$dir" ]; then
        echo_color "$GREEN" "    ✅ Created successfully"
        chown -R "$REAL_USER:staff" "$dir"
        chmod -R 755 "$dir"
    else
        echo_color "$RED" "    ❌ Failed to create directory"
    fi
done

# --- Fix Tart permissions ---
echo_color "$BLUE" "Configuring Tart permissions..."

# Find Tart binary location
TART_BIN=$(which tart || echo "/opt/homebrew/bin/tart")
if [ ! -f "$TART_BIN" ]; then
    echo_color "$RED" "Tart not found! Please ensure it's installed."
    exit 1
fi

# Create comprehensive sudoers file for Tart
cat > /etc/sudoers.d/tart-ci << EOF
# Allow passwordless SSH operations for CI user (needed for VM access)
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/ssh *
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/sshpass *
$REAL_USER ALL=(ALL) NOPASSWD: /opt/homebrew/bin/sshpass *
$REAL_USER ALL=(ALL) NOPASSWD: /usr/local/bin/sshpass *
EOF

# --- Configure monitoring (if enabled) ---
if [ "${MONITORING_ENABLED:-false}" = true ]; then
  echo_color "$BLUE" "Configuring monitoring and logging..."
  
  # Create monitoring directories
  MONITORING_DIRS=(
    "$REAL_HOME/.alloy"
    "$REAL_HOME/.monitoring"
    "$REAL_HOME/.monitoring/logs"
    "$REAL_HOME/.monitoring/data"
    "/opt/homebrew/etc/alloy"
    "/opt/homebrew/var/log/alloy"
  )
  
  for dir in "${MONITORING_DIRS[@]}"; do
    mkdir -p "$dir"
    chown "$REAL_USER:staff" "$dir"
    chmod 755 "$dir"
  done
  
  # Load credentials from keychain for configuration
  CI_KEYCHAIN="$REAL_HOME/Library/Keychains/bun-ci.keychain-db"
  KEYCHAIN_PASSWORD_FILE="$REAL_HOME/.buildkite-agent/ci-keychain-password.txt"
  
  if [ -f "$KEYCHAIN_PASSWORD_FILE" ]; then
    KEYCHAIN_PASSWORD=$(cat "$KEYCHAIN_PASSWORD_FILE")
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$CI_KEYCHAIN" 2>/dev/null || true
  fi
  
  # Create Grafana Alloy configuration
  case "${MONITORING_TYPE:-grafana-cloud}" in
    grafana-cloud)
      # Load Grafana Cloud credentials
      GRAFANA_CLOUD_USER=$(security find-generic-password -a "bun-ci" -s "grafana-cloud-user" -w -k "$CI_KEYCHAIN" 2>/dev/null || echo "")
      GRAFANA_CLOUD_API_KEY=$(security find-generic-password -a "bun-ci" -s "grafana-cloud-api-key" -w -k "$CI_KEYCHAIN" 2>/dev/null || echo "")
      GRAFANA_CLOUD_PROMETHEUS_URL=$(security find-generic-password -a "bun-ci" -s "grafana-cloud-prometheus-url" -w -k "$CI_KEYCHAIN" 2>/dev/null || echo "")
      GRAFANA_CLOUD_LOKI_URL=$(security find-generic-password -a "bun-ci" -s "grafana-cloud-loki-url" -w -k "$CI_KEYCHAIN" 2>/dev/null || echo "")
      
      cat > "$REAL_HOME/.alloy/config.alloy" << EOF
// Grafana Alloy configuration for Bun CI monitoring
// This configuration collects system metrics, build logs, and application metrics

logging {
  level  = "info"
  format = "logfmt"
}

// === METRICS COLLECTION ===

// Node Exporter for system metrics
prometheus.exporter.unix "node" {
  include_exporter_metrics = true
  disable_collectors       = ["mdadm"]
  filesystem {
    fs_types_exclude     = "^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$"
    mount_points_exclude = "^/(dev|proc|run|sys|tmp)($|/)"
  }
}

// Custom Buildkite metrics exporter
prometheus.exporter.process "buildkite_agent" {
  matcher {
    name = "buildkite-agent"
  }
}

// Collect metrics from exporters
prometheus.scrape "local_metrics" {
  targets = concat(
    prometheus.exporter.unix.node.targets,
    prometheus.exporter.process.buildkite_agent.targets,
  )
  
  forward_to = [prometheus.relabel.add_labels.receiver]
  
  scrape_interval = "15s"
  scrape_timeout  = "10s"
}

// Add machine labels to all metrics
prometheus.relabel "add_labels" {
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
  
  rule {
    target_label = "machine_id"
    replacement  = "$MACHINE_UUID"
  }
  
  rule {
    target_label = "machine_location" 
    replacement  = "$MACHINE_LOCATION"
  }
  
  rule {
    target_label = "machine_name"
    replacement  = "$COMPUTER_NAME"
  }
  
  rule {
    target_label = "environment"
    replacement  = "ci"
  }
  
  rule {
    target_label = "service_type"
    replacement  = "buildkite-agent"
  }
}

// Send metrics to Grafana Cloud
prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = "$GRAFANA_CLOUD_PROMETHEUS_URL"
    basic_auth {
      username = "$GRAFANA_CLOUD_USER"
      password = "$GRAFANA_CLOUD_API_KEY"
    }
  }
}

// === LOGS COLLECTION ===

// Buildkite agent logs
loki.source.file "buildkite_logs" {
  targets = [
    {__path__ = "/opt/homebrew/var/log/buildkite-agent.log"},
    {__path__ = "/usr/local/var/log/buildkite-agent.log"},
    {__path__ = "$REAL_HOME/builds/**/buildkite-*.log"},
  ]
  
  forward_to = [loki.relabel.buildkite.receiver]
}

// System logs
loki.source.file "system_logs" {
  targets = [
    {__path__ = "/var/log/system.log"},
    {__path__ = "/var/log/install.log"},
    {__path__ = "/var/log/wifi.log"},
  ]
  
  forward_to = [loki.relabel.system.receiver]
}

// Tart VM logs
loki.source.file "tart_logs" {
  targets = [
    {__path__ = "$REAL_HOME/.tart/logs/*.log"},
    {__path__ = "$REAL_HOME/.tart/vms/*/console.log"},
  ]
  
  forward_to = [loki.relabel.tart.receiver]
}

// Build logs from CI jobs
loki.source.file "build_logs" {
  targets = [
    {__path__ = "$REAL_HOME/builds/**/*.log"},
    {__path__ = "$REAL_HOME/builds/**/cmake-build-*.log"},
    {__path__ = "$REAL_HOME/builds/**/bun-build-*.log"},
  ]
  
  forward_to = [loki.relabel.builds.receiver]
}

// Label buildkite logs
loki.relabel "buildkite" {
  forward_to = [loki.write.grafana_cloud.receiver]
  
  rule {
    source_labels = ["__path__"]
    target_label  = "log_type"
    replacement   = "buildkite"
  }
  
  rule {
    target_label = "machine_id"
    replacement  = "$MACHINE_UUID"
  }
  
  rule {
    target_label = "machine_location"
    replacement  = "$MACHINE_LOCATION"
  }
  
  rule {
    target_label = "machine_name"
    replacement  = "$COMPUTER_NAME"
  }
}

// Label system logs  
loki.relabel "system" {
  forward_to = [loki.write.grafana_cloud.receiver]
  
  rule {
    source_labels = ["__path__"]
    target_label  = "log_type"
    replacement   = "system"
  }
  
  rule {
    target_label = "machine_id"
    replacement  = "$MACHINE_UUID"
  }
  
  rule {
    target_label = "machine_location"
    replacement  = "$MACHINE_LOCATION"
  }
  
  rule {
    target_label = "machine_name"
    replacement  = "$COMPUTER_NAME"
  }
}

// Label Tart logs
loki.relabel "tart" {
  forward_to = [loki.write.grafana_cloud.receiver]
  
  rule {
    source_labels = ["__path__"]
    target_label  = "log_type"
    replacement   = "tart"
  }
  
  rule {
    target_label = "machine_id"
    replacement  = "$MACHINE_UUID"
  }
  
  rule {
    target_label = "machine_location"
    replacement  = "$MACHINE_LOCATION"
  }
  
  rule {
    target_label = "machine_name"
    replacement  = "$COMPUTER_NAME"
  }
}

// Label build logs
loki.relabel "builds" {
  forward_to = [loki.write.grafana_cloud.receiver]
  
  rule {
    source_labels = ["__path__"]
    target_label  = "log_type"
    replacement   = "build"
  }
  
  rule {
    source_labels = ["__path__"]
    regex         = ".*/builds/([^/]+)/.*"
    target_label  = "build_id"
    replacement   = "\${1}"
  }
  
  rule {
    target_label = "machine_id"
    replacement  = "$MACHINE_UUID"
  }
  
  rule {
    target_label = "machine_location"
    replacement  = "$MACHINE_LOCATION"
  }
  
  rule {
    target_label = "machine_name"
    replacement  = "$COMPUTER_NAME"
  }
}

// Send logs to Grafana Cloud
loki.write "grafana_cloud" {
  endpoint {
    url = "$GRAFANA_CLOUD_LOKI_URL"
    basic_auth {
      username = "$GRAFANA_CLOUD_USER"
      password = "$GRAFANA_CLOUD_API_KEY"
    }
  }
}
EOF
      ;;
      
    self-hosted)
      # Load self-hosted credentials
      PROMETHEUS_URL=$(security find-generic-password -a "bun-ci" -s "prometheus-url" -w -k "$CI_KEYCHAIN" 2>/dev/null || echo "http://localhost:9090")
      LOKI_URL=$(security find-generic-password -a "bun-ci" -s "loki-url" -w -k "$CI_KEYCHAIN" 2>/dev/null || echo "http://localhost:3100")
      
      cat > "$REAL_HOME/.alloy/config.alloy" << EOF
// Grafana Alloy configuration for self-hosted monitoring

logging {
  level  = "info"
  format = "logfmt"
}

// === METRICS COLLECTION ===

prometheus.exporter.unix "node" {
  include_exporter_metrics = true
  disable_collectors       = ["mdadm"]
}

prometheus.exporter.process "buildkite_agent" {
  matcher {
    name = "buildkite-agent"
  }
}

prometheus.scrape "local_metrics" {
  targets = concat(
    prometheus.exporter.unix.node.targets,
    prometheus.exporter.process.buildkite_agent.targets,
  )
  
  forward_to = [prometheus.relabel.add_labels.receiver]
  
  scrape_interval = "15s"
  scrape_timeout  = "10s"
}

prometheus.relabel "add_labels" {
  forward_to = [prometheus.remote_write.self_hosted.receiver]
  
  rule {
    target_label = "machine_id"
    replacement  = "$MACHINE_UUID"
  }
  
  rule {
    target_label = "machine_location" 
    replacement  = "$MACHINE_LOCATION"
  }
  
  rule {
    target_label = "machine_name"
    replacement  = "$COMPUTER_NAME"
  }
}

prometheus.remote_write "self_hosted" {
  endpoint {
    url = "$PROMETHEUS_URL/api/v1/write"
  }
}

// === LOGS COLLECTION ===

loki.source.file "all_logs" {
  targets = [
    {__path__ = "/opt/homebrew/var/log/buildkite-agent.log", log_type = "buildkite"},
    {__path__ = "/var/log/system.log", log_type = "system"},
    {__path__ = "$REAL_HOME/builds/**/*.log", log_type = "build"},
    {__path__ = "$REAL_HOME/.tart/logs/*.log", log_type = "tart"},
  ]
  
  forward_to = [loki.relabel.all.receiver]
}

loki.relabel "all" {
  forward_to = [loki.write.self_hosted.receiver]
  
  rule {
    target_label = "machine_id"
    replacement  = "$MACHINE_UUID"
  }
  
  rule {
    target_label = "machine_location"
    replacement  = "$MACHINE_LOCATION"
  }
  
  rule {
    target_label = "machine_name"
    replacement  = "$COMPUTER_NAME"
  }
}

loki.write "self_hosted" {
  endpoint {
    url = "$LOKI_URL/loki/api/v1/push"
  }
}
EOF
      ;;
  esac
  
  # Set permissions on config file
  chown "$REAL_USER:staff" "$REAL_HOME/.alloy/config.alloy"
  chmod 644 "$REAL_HOME/.alloy/config.alloy"
  
  # Copy config to Homebrew location
  if mkdir -p /opt/homebrew/etc/alloy 2>/dev/null; then
    cp "$REAL_HOME/.alloy/config.alloy" /opt/homebrew/etc/alloy/ 2>/dev/null || echo_color "$YELLOW" "⚠️  Failed to copy alloy config to Homebrew location (non-fatal)"
  else
    echo_color "$YELLOW" "⚠️  Cannot create Homebrew alloy directory (non-fatal)"
  fi
  
  echo_color "$GREEN" "✅ Monitoring configuration created"
fi

# --- Prevent system sleep (server mode) ---
echo_color "$BLUE" "Configuring system to never sleep (server mode)..."
sudo systemsetup -setcomputersleep Never
sudo systemsetup -setdisplaysleep Never  
sudo systemsetup -setharddisksleep Never
sudo pmset -a sleep 0
sudo pmset -a disablesleep 1

# --- Configure SSH ---
echo_color "$BLUE" "Configuring SSH access..."
FDA_CHECK_OUTPUT=$(sudo systemsetup -getremotelogin 2>&1)
if echo "$FDA_CHECK_OUTPUT" | grep -q "Full Disk Access"; then
    echo_color "$YELLOW" "\nIMPORTANT: Terminal needs Full Disk Access for SSH setup."
    echo_color "$YELLOW" "Grant access in System Settings → Privacy & Security → Full Disk Access"
    echo_color "$YELLOW" "Then re-run this script."
    exit 1
fi
sudo systemsetup -setremotelogin on || true

# Get machine info
MACHINE_UUID=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}')
MACHINE_ARCH=$(uname -m)
AGENT_NAME="${COMPUTER_NAME}-${MACHINE_LOCATION}-${MACHINE_UUID:0:8}"

# --- Write Buildkite config ---
echo_color "$BLUE" "Writing Buildkite agent configuration..."

# Write to user's home directory
cat > "$REAL_HOME/.buildkite-agent/buildkite-agent.cfg" << EOF
token="${BUILDKITE_AGENT_TOKEN}"
name="${AGENT_NAME}"
tags="os=darwin,arch=${MACHINE_ARCH},queue=darwin,tart=true"
build-path="$REAL_HOME/builds"
hooks-path="$REAL_HOME/.buildkite-agent/hooks"
plugins-path="$REAL_HOME/plugins"
EOF
chown "$REAL_USER:staff" "$REAL_HOME/.buildkite-agent/buildkite-agent.cfg"
chmod 600 "$REAL_HOME/.buildkite-agent/buildkite-agent.cfg"

# Also write to Homebrew location (optional - may fail without elevated permissions)
echo_color "$BLUE" "Attempting to write buildkite config to Homebrew location..."
if mkdir -p /opt/homebrew/etc/buildkite-agent 2>/dev/null; then
    if cp "$REAL_HOME/.buildkite-agent/buildkite-agent.cfg" /opt/homebrew/etc/buildkite-agent/ 2>/dev/null; then
        chown "$REAL_USER:staff" /opt/homebrew/etc/buildkite-agent/buildkite-agent.cfg 2>/dev/null || true
        echo_color "$GREEN" "✅ Buildkite config written to Homebrew location"
    else
        echo_color "$YELLOW" "⚠️  Failed to copy buildkite config to Homebrew location (non-fatal)"
    fi
else
    echo_color "$YELLOW" "⚠️  Cannot create Homebrew buildkite directory (non-fatal - agent will use user config)"
fi

# --- Create environment hook for proper PATH ---
echo_color "$BLUE" "Creating environment hook..."
echo_color "$BLUE" "Debug: Target file: $REAL_HOME/.buildkite-agent/hooks/environment"
echo_color "$BLUE" "Debug: Directory exists: $([ -d "$REAL_HOME/.buildkite-agent/hooks" ] && echo "YES" || echo "NO")"

cat > "$REAL_HOME/.buildkite-agent/hooks/environment" << 'EOF'
#!/bin/bash
set -euo pipefail

# Ensure Homebrew is in PATH
if [[ -d "/opt/homebrew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
else
    eval "$(/usr/local/bin/brew shellenv)"
fi

# Ensure Tart can be found
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Set up build environment
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

# Load GitHub credentials from CI keychain
load_github_credentials() {
    local ci_keychain="$HOME/Library/Keychains/bun-ci.keychain-db"
    local keychain_password_file="$HOME/.buildkite-agent/ci-keychain-password.txt"
    
    # Check if keychain exists
    if [ ! -f "$ci_keychain" ]; then
        echo "⚠️  CI keychain not found at $ci_keychain"
        return 1
    fi
    
    # Unlock keychain if needed
    if [ -f "$keychain_password_file" ]; then
        local keychain_password=$(cat "$keychain_password_file")
        security unlock-keychain -p "$keychain_password" "$ci_keychain" 2>/dev/null || true
    fi
    
    # Load credentials
    local username=$(security find-generic-password -a "bun-ci" -s "github-username" -w -k "$ci_keychain" 2>/dev/null || echo "")
    local token=$(security find-generic-password -a "bun-ci" -s "github-token" -w -k "$ci_keychain" 2>/dev/null || echo "")
    
    if [ -n "$username" ] && [ -n "$token" ]; then
        export GITHUB_USERNAME="$username"
        export GITHUB_TOKEN="$token"
        echo "✅ GitHub credentials loaded from keychain"
        return 0
    else
        echo "⚠️  Failed to load GitHub credentials from keychain"
        return 1
    fi
}

# Load the credentials
load_github_credentials || echo "⚠️  GitHub credentials not available - registry pushes may fail"
EOF

if [ -f "$REAL_HOME/.buildkite-agent/hooks/environment" ]; then
    echo_color "$GREEN" "✅ Environment hook created successfully"
    chmod +x "$REAL_HOME/.buildkite-agent/hooks/environment"
    chown "$REAL_USER:staff" "$REAL_HOME/.buildkite-agent/hooks/environment"
else
    echo_color "$RED" "❌ Failed to create environment hook"
    ls -la "$REAL_HOME/.buildkite-agent/hooks/" || echo "Directory does not exist"
fi

# VPN setup (if enabled)
if [ "$VPN_ENABLED" = true ]; then
  case "$VPN_TYPE" in
    wireguard)
      mkdir -p /etc/wireguard
      cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = ${WIREGUARD_PRIVATE_KEY}
Address = 10.0.0.2/24
ListenPort = 51820

[Peer]
PublicKey = ${WIREGUARD_PUBLIC_KEY}
Endpoint = ${WIREGUARD_ENDPOINT}:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF
      ;;
    tailscale)
      # Ensure tailscaled is running
      if [ -f "/opt/homebrew/bin/brew" ]; then
        sudo -u "$REAL_USER" /opt/homebrew/bin/brew services start tailscale
      elif [ -f "/usr/local/bin/brew" ]; then
        sudo -u "$REAL_USER" /usr/local/bin/brew services start tailscale
      fi
      if [ -n "${TAILSCALE_AUTH_KEY-}" ]; then
        # Start Tailscale with auth key
        echo_color "$BLUE" "Starting Tailscale with auth key..."
        tailscale up --authkey="$TAILSCALE_AUTH_KEY" --hostname="bun-ci-$(hostname)"

        # Wait for Tailscale to be ready
        echo_color "$BLUE" "Waiting for Tailscale to be ready..."
        for i in {1..30}; do
          if tailscale status &>/dev/null; then
            echo_color "$GREEN" "Tailscale is ready!"
            break
          fi
          if [ $i -eq 30 ]; then
            echo_color "$RED" "Tailscale failed to start within timeout"
            exit 1
          fi
          sleep 1
        done

        # Get Tailscale IP
        TAILSCALE_IP=$(tailscale ip --1)
        echo_color "$GREEN" "Tailscale IP: $TAILSCALE_IP"

        # Configure SSH access
        echo_color "$BLUE" "Configuring SSH access..."
        mkdir -p /etc/ssh/sshd_config.d
        cat > /etc/ssh/sshd_config.d/tailscale.conf << EOF
# Allow Tailscale IPs
Match Address ${TAILSCALE_IP}
    PermitRootLogin no
    PasswordAuthentication no
    PubkeyAuthentication yes
    AllowGroups buildkite-agent wheel
EOF

        # Enable and restart SSH server to apply changes (macOS)
        echo_color "$BLUE" "Ensuring SSH server is enabled..."
        # Check for Full Disk Access by attempting a harmless systemsetup command
        FDA_CHECK_OUTPUT=$(sudo systemsetup -getremotelogin 2>&1)
        if echo "$FDA_CHECK_OUTPUT" | grep -q "Full Disk Access"; then
          echo_color "$YELLOW" "\nIMPORTANT: macOS requires your Terminal app to have Full Disk Access to enable Remote Login (SSH) from the command line."
          echo_color "$YELLOW" "If you see a permissions error, follow these steps:"
          echo_color "$YELLOW" "1. Open System Settings → Privacy & Security → Full Disk Access."
          echo_color "$YELLOW" "2. Click the + button and add your Terminal app (e.g., Terminal, iTerm)."
          echo_color "$YELLOW" "3. Quit and reopen your Terminal app, then re-run this script."
          echo_color "$YELLOW" "\nAfter granting access and restarting, re-run this script."
          echo_color "$YELLOW" "Press SPACEBAR to exit."
          # Wait for spacebar
          while true; do
            read -rsn1 key
            if [[ $key == " " ]]; then
              break
            fi
          done
          exit 1
        fi
        sudo systemsetup -setremotelogin on
        # Try to restart SSH daemon if the service exists
        if sudo launchctl list | grep -q com.openssh.sshd; then
          echo_color "$BLUE" "Restarting SSH daemon..."
          sudo launchctl kickstart -k system/com.openssh.sshd
        else
          echo_color "$YELLOW" "SSH daemon service not found; enabled SSH but did not restart (may not be needed on this macOS version)."
        fi
      else
        echo_color "$YELLOW" "No Tailscale auth key provided. Starting Tailscale in interactive mode..."
        tailscale up --hostname="bun-ci-$(hostname)"
      fi
      ;;
    unifi)
      mkdir -p /etc/openvpn
      cat > /etc/openvpn/auth.txt << EOF
${UNIFI_VPN_USER}
${UNIFI_VPN_PASSWORD}
EOF
      chmod 600 /etc/openvpn/auth.txt
      curl -k -u "${UNIFI_VPN_USER}:${UNIFI_VPN_PASSWORD}" \
        "https://${UNIFI_VPN_SERVER}:943/remote/client.ovpn" \
        -o /etc/openvpn/unifi.ovpn
      echo "auth-user-pass /etc/openvpn/auth.txt" >> /etc/openvpn/unifi.ovpn
      ;;
    cloudflare)
      echo_color "$BLUE" "Setting up Cloudflare Tunnel..."
      
      # Install cloudflared if not present
      if ! command -v cloudflared &> /dev/null; then
        echo_color "$YELLOW" "Installing cloudflared..."
        if [ -f "/opt/homebrew/bin/brew" ]; then
          sudo -u "$REAL_USER" /opt/homebrew/bin/brew install cloudflared
        elif [ -f "/usr/local/bin/brew" ]; then
          sudo -u "$REAL_USER" /usr/local/bin/brew install cloudflared
        else
          echo_color "$RED" "Homebrew not found. Cannot install cloudflared."
          exit 1
        fi
        if ! command -v cloudflared &> /dev/null; then
          echo_color "$RED" "Failed to install cloudflared. Please install manually with: brew install cloudflared"
          exit 1
        fi
        echo_color "$GREEN" "✅ cloudflared installed successfully."
      else
        echo_color "$GREEN" "cloudflared is already installed."
      fi

      # Install the service with the token
      echo_color "$BLUE" "Installing Cloudflare Tunnel service..."
      sudo cloudflared service install "$CLOUDFLARE_TUNNEL_TOKEN"

      echo_color "$GREEN" "✅ Cloudflare Tunnel setup complete."
      echo_color "$BLUE" "You can check the status with:"
      echo "  - Check service: launchctl list | grep cloudflare"
      echo "  - Check tunnel status: cloudflared tunnel info"
      ;;
  esac
fi

# --- Start services as the real user ---
echo_color "$BLUE" "Starting Buildkite agent as $REAL_USER..."

# First verify that buildkite-agent is accessible to the target user
echo_color "$BLUE" "Verifying buildkite-agent access for user $REAL_USER..."
if ! sudo -u "$REAL_USER" -i bash -c 'command -v buildkite-agent' &>/dev/null; then
  echo_color "$RED" "❌ Buildkite agent not accessible to user $REAL_USER!"
  echo_color "$YELLOW" "Checking if buildkite-agent exists in system paths..."
  
  # Check common locations
  for path in "/opt/homebrew/bin/buildkite-agent" "/usr/local/bin/buildkite-agent"; do
    if [ -f "$path" ]; then
      echo_color "$BLUE" "Found buildkite-agent at: $path"
      # Make sure it's executable by the user
      chmod +x "$path" 2>/dev/null || true
    fi
  done
  
  # Try again with explicit PATH
  if ! sudo -u "$REAL_USER" -i bash -c 'PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" command -v buildkite-agent' &>/dev/null; then
    echo_color "$RED" "❌ Buildkite agent still not accessible. Installation may have failed."
    exit 1
  fi
fi

# Get buildkite-agent version with proper user context
AGENT_VERSION=$(sudo -u "$REAL_USER" -i bash -c 'PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" buildkite-agent --version 2>/dev/null | head -1' || echo "unknown")
echo_color "$GREEN" "✅ Buildkite agent found: $AGENT_VERSION"

# Create and fix ownership of required directories before starting service
echo_color "$BLUE" "Ensuring proper directory ownership..."
HOMEBREW_DIRS=(
  "/opt/homebrew/var"
  "/opt/homebrew/var/log"
  "/opt/homebrew/var/buildkite-agent"
  "/usr/local/var" 
  "/usr/local/var/log"
  "/usr/local/var/buildkite-agent"
)

for dir in "${HOMEBREW_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    echo_color "$BLUE" "  Fixing ownership: $dir"
    chown -R "$REAL_USER:staff" "$dir" 2>/dev/null || {
      echo_color "$YELLOW" "  ⚠️  Could not change ownership of $dir (may not be critical)"
    }
  else
    # Try to create directory if it doesn't exist
    if mkdir -p "$dir" 2>/dev/null; then
      echo_color "$BLUE" "  Created and set ownership: $dir"
      chown -R "$REAL_USER:staff" "$dir" 2>/dev/null || true
    else
      echo_color "$YELLOW" "  ⚠️  Could not create $dir (may not be critical)"
    fi
  fi
done

# Start the agent as the actual user with proper environment
echo_color "$BLUE" "Starting buildkite-agent service..."

# Function to start service with retry
start_buildkite_service() {
  local brew_path="$1"
  local attempts=3
  local attempt=1
  
  while [ $attempt -le $attempts ]; do
    echo_color "$BLUE" "  Attempt $attempt/$attempts: Starting service with $brew_path"
    
    # Use -i flag to get clean environment and explicit PATH
    if sudo -u "$REAL_USER" -i bash -c "
      export PATH=\"$brew_path/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH\"
      export HOMEBREW_NO_AUTO_UPDATE=1
      cd '$REAL_HOME'
      '$brew_path/bin/brew' services start buildkite-agent
    " 2>/dev/null; then
      echo_color "$GREEN" "  ✅ Service started successfully"
      return 0
    else
      echo_color "$YELLOW" "  ⚠️  Attempt $attempt failed"
      ((attempt++))
      sleep 2
    fi
  done
  
  return 1
}

# Try with detected Homebrew path
SERVICE_STARTED=false
if [ -f "/opt/homebrew/bin/brew" ]; then
  if start_buildkite_service "/opt/homebrew"; then
    SERVICE_STARTED=true
    HOMEBREW_PREFIX="/opt/homebrew"
  fi
elif [ -f "/usr/local/bin/brew" ]; then
  if start_buildkite_service "/usr/local"; then
    SERVICE_STARTED=true
    HOMEBREW_PREFIX="/usr/local"
  fi
fi

if [ "$SERVICE_STARTED" != true ]; then
  echo_color "$RED" "❌ Failed to start buildkite-agent service after multiple attempts"
  echo_color "$YELLOW" "Manual start command:"
  echo_color "$YELLOW" "  sudo -u $REAL_USER brew services start buildkite-agent"
  
  # Still continue with verification
  HOMEBREW_PREFIX="/opt/homebrew"
  [ -f "/usr/local/bin/brew" ] && HOMEBREW_PREFIX="/usr/local"
else
  echo_color "$GREEN" "✅ Buildkite agent service started successfully"
fi

# Verify it's running with more robust check
echo_color "$BLUE" "Verifying service status..."
sleep 5

SERVICE_RUNNING=false
for check_attempt in {1..3}; do
  echo_color "$BLUE" "  Verification attempt $check_attempt/3..."
  
  # Check via brew services
  if sudo -u "$REAL_USER" -i bash -c "
    export PATH=\"$HOMEBREW_PREFIX/bin:\$PATH\"
    '$HOMEBREW_PREFIX/bin/brew' services list
  " 2>/dev/null | grep -q "buildkite-agent.*started"; then
    echo_color "$GREEN" "  ✅ Buildkite agent service is running"
    SERVICE_RUNNING=true
    break
  fi
  
  # Also check via process list as fallback
  if pgrep -f "buildkite-agent" >/dev/null; then
    echo_color "$GREEN" "  ✅ Buildkite agent process found running (via process check)"
    SERVICE_RUNNING=true
    break
  fi
  
  if [ $check_attempt -lt 3 ]; then
    echo_color "$YELLOW" "  Service not detected yet, waiting..."
    sleep 3
  fi
done

if [ "$SERVICE_RUNNING" != true ]; then
  echo_color "$YELLOW" "  ⚠️  Buildkite agent service status unclear"
  echo_color "$YELLOW" "  Check logs at: $HOMEBREW_PREFIX/var/log/buildkite-agent.log"
  echo_color "$YELLOW" "  Or try manual start: sudo -u $REAL_USER brew services start buildkite-agent"
fi

# --- Start monitoring services (if enabled) ---
if [ "${MONITORING_ENABLED:-false}" = true ]; then
  echo_color "$BLUE" "Starting monitoring services as $REAL_USER..."
  
  # Start Node Exporter with proper environment
  echo_color "$BLUE" "Starting Node Exporter..."
  if sudo -u "$REAL_USER" -i bash -c "
    export PATH=\"$HOMEBREW_PREFIX/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH\"
    export HOMEBREW_NO_AUTO_UPDATE=1
    cd '$REAL_HOME'
    '$HOMEBREW_PREFIX/bin/brew' services start prometheus-node-exporter
  " 2>/dev/null; then
    echo_color "$GREEN" "  ✅ Node Exporter started successfully"
  else
    echo_color "$YELLOW" "  ⚠️  Failed to start Node Exporter"
  fi
  
  # Start Grafana Alloy with proper environment
  echo_color "$BLUE" "Starting Grafana Alloy..."
  if sudo -u "$REAL_USER" -i bash -c "
    export PATH=\"$HOMEBREW_PREFIX/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH\"
    export HOMEBREW_NO_AUTO_UPDATE=1
    cd '$REAL_HOME'
    '$HOMEBREW_PREFIX/bin/brew' services start alloy
  " 2>/dev/null; then
    echo_color "$GREEN" "  ✅ Grafana Alloy started successfully"
  else
    echo_color "$YELLOW" "  ⚠️  Failed to start Grafana Alloy"
  fi
  
  # Verify monitoring services are running
  echo_color "$BLUE" "Verifying monitoring service status..."
  sleep 5
  
  MONITORING_STATUS=""
  
  # Check Node Exporter
  if sudo -u "$REAL_USER" -i bash -c "
    export PATH=\"$HOMEBREW_PREFIX/bin:\$PATH\"
    '$HOMEBREW_PREFIX/bin/brew' services list
  " 2>/dev/null | grep -q "prometheus-node-exporter.*started"; then
    MONITORING_STATUS+="✅ Node Exporter started\n"
  else
    MONITORING_STATUS+="⚠️  Node Exporter may not have started\n"
  fi
  
  # Check Grafana Alloy
  if sudo -u "$REAL_USER" -i bash -c "
    export PATH=\"$HOMEBREW_PREFIX/bin:\$PATH\"
    '$HOMEBREW_PREFIX/bin/brew' services list
  " 2>/dev/null | grep -q "alloy.*started"; then
    MONITORING_STATUS+="✅ Grafana Alloy started\n"
  else
    MONITORING_STATUS+="⚠️  Grafana Alloy may not have started\n"
  fi
  
  echo -e "$MONITORING_STATUS"
  
  echo_color "$BLUE" "Monitoring endpoints:"
  echo "  - Node Exporter metrics: http://localhost:9100/metrics"
  echo "  - Alloy status: http://localhost:12345"
  echo_color "$YELLOW" "Check Alloy logs at: $HOMEBREW_PREFIX/var/log/alloy.log"
fi

echo_color "$GREEN" "\n[3/3] Setup complete!"

# --- Final verification ---
echo_color "$BLUE" "\n🔍 Verifying installation..."

# Critical tools for CI
CRITICAL_TOOLS=(
  "brew:Homebrew"
  "buildkite-agent:Buildkite Agent"
  "node:Node.js"
  "git:Git"
  "tart:Tart VM"
  "jq:JSON processor"
)

# Optional tools
OPTIONAL_TOOLS=(
  "sshpass:SSH password utility"
  "tailscale:Tailscale VPN"
  "cmake:CMake build system"
  "ninja:Ninja build system"
  "ccache:Compiler cache"
  "python3:Python 3"
  "ruby:Ruby"
  "perl:Perl"
  "golang:Go language"
)

verify_tool() {
  local tool_cmd="$1"
  local tool_name="$2"
  local is_critical="$3"
  
  if command -v "$tool_cmd" &> /dev/null; then
    local version=""
    case "$tool_cmd" in
      "node") version=" ($(node --version))" ;;
      "buildkite-agent") version=" ($(buildkite-agent --version 2>/dev/null | head -1))" ;;
      "tart") version=" ($(tart --version 2>/dev/null))" ;;
      *) version="" ;;
    esac
    echo_color "$GREEN" "  ✅ $tool_name$version"
    return 0
  else
    if [ "$is_critical" = "true" ]; then
      echo_color "$RED" "  ❌ $tool_name - MISSING (CRITICAL)"
      return 1
    else
      echo_color "$YELLOW" "  ⚠️  $tool_name - missing (optional)"
      return 0
    fi
  fi
}

echo_color "$BLUE" "\nCritical tools:"
CRITICAL_MISSING=0
for tool_info in "${CRITICAL_TOOLS[@]}"; do
  IFS=':' read -r cmd name <<< "$tool_info"
  if ! verify_tool "$cmd" "$name" "true"; then
    CRITICAL_MISSING=$((CRITICAL_MISSING + 1))
  fi
done

echo_color "$BLUE" "\nOptional tools:"
for tool_info in "${OPTIONAL_TOOLS[@]}"; do
  IFS=':' read -r cmd name <<< "$tool_info"
  verify_tool "$cmd" "$name" "false"
done

# Check Buildkite agent service
echo_color "$BLUE" "\nServices:"

# Check Buildkite agent with proper user context
if sudo -u "$REAL_USER" -i bash -c "
  export PATH=\"$HOMEBREW_PREFIX/bin:\$PATH\"
  '$HOMEBREW_PREFIX/bin/brew' services list
" 2>/dev/null | grep -q "buildkite-agent.*started"; then
  echo_color "$GREEN" "  ✅ Buildkite agent service running"
else
  # Fallback check via process list
  if pgrep -f "buildkite-agent" >/dev/null; then
    echo_color "$GREEN" "  ✅ Buildkite agent process running (via process check)"
  else
    echo_color "$YELLOW" "  ⚠️  Buildkite agent service not running"
    echo_color "$YELLOW" "     Check logs: $HOMEBREW_PREFIX/var/log/buildkite-agent.log"
    echo_color "$YELLOW" "     Manual start: sudo -u $REAL_USER brew services start buildkite-agent"
  fi
fi

# Summary
if [ $CRITICAL_MISSING -eq 0 ]; then
  echo_color "$GREEN" "\n🎉 Setup completed successfully! All critical tools are installed."
  echo_color "$BLUE" "\nNext steps:"
  echo_color "$BLUE" "  • Your Buildkite agent should start receiving jobs"
  echo_color "$BLUE" "  • Tart VMs can be created and managed"
  echo_color "$BLUE" "  • CI builds should work with Node.js, Git, and build tools"
else
  echo_color "$RED" "\n⚠️  Setup completed with $CRITICAL_MISSING critical tool(s) missing."
  echo_color "$YELLOW" "Please install the missing tools manually before running CI jobs."
fi
