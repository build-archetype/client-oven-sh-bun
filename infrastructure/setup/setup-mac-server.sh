#!/bin/bash

# last updated 2025-05-25 at 10:12 PM

set -euo pipefail

# Only show welcome/confirmation if not already in privileged (sudo/root) mode
if [ "$EUID" -ne 0 ]; then
  # --- Welcome message ---
  echo -e "\033[1;36m" # Cyan bold
  cat <<WELCOME
Bun.sh On-Prem Mac CI Server Setup
==================================
This script will:
  - Install and configure Homebrew and dependencies
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

  # Store GITHUB_USERNAME and GITHUB_TOKEN in temp files for root context
  echo "$GITHUB_USERNAME" > /tmp/github-username.txt
  chmod 600 /tmp/github-username.txt
  echo "$GITHUB_TOKEN" > /tmp/github-token.txt
  chmod 600 /tmp/github-token.txt

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
    echo_color "$BLUE" "\n[1/3] Installing Homebrew and dependencies..."
    if ! command -v brew &> /dev/null; then
      echo_color "$YELLOW" "Homebrew not found. Installing..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      # Add Homebrew to PATH for current shell
      if [ -d "/opt/homebrew/bin" ]; then
        eval "$('/opt/homebrew/bin/brew' shellenv)"
        echo 'eval "$('/opt/homebrew/bin/brew' shellenv)"' >> ~/.zprofile
      elif [ -d "/usr/local/bin" ]; then
        eval "$('/usr/local/bin/brew' shellenv)"
        echo 'eval "$('/usr/local/bin/brew' shellenv)"' >> ~/.bash_profile
      fi
      if ! command -v brew &> /dev/null; then
        echo_color "$RED" "Homebrew installation failed or not found in PATH. Aborting."
        exit 1
      fi
    fi
    # Always install Tailscale and check for it
    brew install tailscale || { echo_color "$RED" "Failed to install Tailscale."; exit 1; }
    if ! command -v tailscale &> /dev/null; then
      echo_color "$RED" "Tailscale is not in PATH after installation. Aborting."; exit 1;
    fi
    brew install buildkite/buildkite/buildkite-agent terraform jq yq wget git wireguard-tools openvpn node
    echo_color "$GREEN" "✅ Homebrew and dependencies installed."

    # Verify Node.js installation
    if ! command -v node &> /dev/null; then
      echo_color "$RED" "Node.js installation failed or not found in PATH. Aborting."
      exit 1
    fi
    NODE_VERSION=$(node --version)
    echo_color "$GREEN" "✅ Node.js installed (version: $NODE_VERSION)"

    # --- Tart install via Cirrus Labs tap ---
    if ! command -v tart &> /dev/null; then
      echo_color "$YELLOW" "Tart is not installed. Installing from cirruslabs/cli tap..."
      brew tap cirruslabs/cli
      brew install cirruslabs/cli/tart
      if command -v tart &> /dev/null; then
        echo_color "$GREEN" "✅ Tart installed successfully."
      else
        echo_color "$RED" "Tart installation failed. Please install manually from https://github.com/cirruslabs/tart."
        exit 1
      fi
    else
      echo_color "$GREEN" "Tart is already installed."
    fi

    # --- Install sshpass for Tart plugin ---
    if ! command -v sshpass &> /dev/null; then
      echo_color "$YELLOW" "sshpass is not installed. Installing from cirruslabs/cli tap..."
      brew install cirruslabs/cli/sshpass
      if command -v sshpass &> /dev/null; then
        echo_color "$GREEN" "✅ sshpass installed successfully."
      else
        echo_color "$RED" "sshpass installation failed. Please install manually: brew install cirruslabs/cli/sshpass"
        exit 1
      fi
    else
      echo_color "$GREEN" "sshpass is already installed."
    fi

    echo_color "$BLUE" "Switching to root for system configuration..."
    export_vars="BUILDKITE_AGENT_TOKEN=\"$BUILDKITE_AGENT_TOKEN\" VPN_ENABLED=\"$VPN_ENABLED\" BUILD_VLAN=\"$BUILD_VLAN\" MGMT_VLAN=\"$MGMT_VLAN\" STORAGE_VLAN=\"$STORAGE_VLAN\" MACHINE_LOCATION=\"$MACHINE_LOCATION\" COMPUTER_NAME=\"$COMPUTER_NAME\""
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

# Create CI user
CI_USER="ci-mac"
CI_HOME="/Users/$CI_USER"

echo_color "$BLUE" "Setting up CI user $CI_USER..."
# Create user if it doesn't exist
if ! id "$CI_USER" &>/dev/null; then
    # Create user with home directory
    dscl . -create "/Users/$CI_USER"
    dscl . -create "/Users/$CI_USER" UserShell /bin/bash
    dscl . -create "/Users/$CI_USER" RealName "CI Mac User"
    dscl . -create "/Users/$CI_USER" UniqueID 1001
    dscl . -create "/Users/$CI_USER" PrimaryGroupID 20
    dscl . -create "/Users/$CI_USER" NFSHomeDirectory "$CI_HOME"
    
    # Create home directory
    mkdir -p "$CI_HOME"
    chown "$CI_USER:staff" "$CI_HOME"
    chmod 755 "$CI_HOME"
    
    echo_color "$GREEN" "✅ Created CI user $CI_USER"
else
    echo_color "$GREEN" "✅ CI user $CI_USER already exists"
fi

# Ensure proper ownership of home directory
echo_color "$BLUE" "Ensuring proper home directory ownership..."
chown -R "$CI_USER:staff" "$CI_HOME"
chmod -R 755 "$CI_HOME"

# Create necessary directories with proper permissions
mkdir -p "$CI_HOME/Library/Keychains"
chown -R "$CI_USER:staff" "$CI_HOME/Library"
chmod -R 755 "$CI_HOME/Library"

# Set up keychain for CI user
echo_color "$BLUE" "Setting up keychain for CI user..."

# Create a dedicated keychain for CI user
CI_KEYCHAIN="$CI_HOME/Library/Keychains/ci.keychain"
echo_color "$BLUE" "Setting up CI keychain..."

# 1. Ensure keychain directory exists with correct permissions
echo_color "$BLUE" "Setting up keychain directory..."
mkdir -p "$(dirname "$CI_KEYCHAIN")"
chown -R "$CI_USER:staff" "$(dirname "$CI_KEYCHAIN")"

# 2. Remove any existing keychain that might be in a bad state
echo_color "$BLUE" "Cleaning up any existing keychain..."
sudo -u "$CI_USER" env HOME="$CI_HOME" security delete-keychain "$CI_KEYCHAIN" 2>/dev/null || true
rm -f "$CI_KEYCHAIN" "$CI_KEYCHAIN-db" 2>/dev/null || true

# 3. Create fresh keychain with a known password
echo_color "$BLUE" "Creating new keychain..."
sudo -u "$CI_USER" env HOME="$CI_HOME" security create-keychain -p "ci-keychain-password" "$CI_KEYCHAIN" || {
    echo_color "$RED" "Failed to create keychain"
    exit 1
}

# 4. Remove from search list first to ensure clean state
echo_color "$BLUE" "Resetting keychain search list..."
sudo -u "$CI_USER" env HOME="$CI_HOME" security list-keychains | while read -r keychain; do
    sudo -u "$CI_USER" env HOME="$CI_HOME" security list-keychains -d user -s "$keychain" 2>/dev/null || true
done

# 5. Add our keychain to search list
echo_color "$BLUE" "Adding keychain to search list..."
sudo -u "$CI_USER" env HOME="$CI_HOME" security list-keychains -d user -s "$CI_KEYCHAIN" || {
    echo_color "$RED" "Failed to add keychain to search list"
    exit 1
}

# 6. Unlock the keychain with the known password
echo_color "$BLUE" "Unlocking keychain..."
sudo -u "$CI_USER" env HOME="$CI_HOME" security unlock-keychain -p "ci-keychain-password" "$CI_KEYCHAIN" || {
    echo_color "$RED" "Failed to unlock keychain"
    exit 1
}

# 7. Configure for non-interactive use
echo_color "$BLUE" "Configuring keychain for non-interactive use..."
sudo -u "$CI_USER" env HOME="$CI_HOME" security set-keychain-settings -t 3600 -u -l "$CI_KEYCHAIN" || {
    echo_color "$RED" "Failed to set keychain settings"
    exit 1
}

# 8. Add GitHub token if available
if [ -n "$GITHUB_TOKEN" ]; then
    echo_color "$BLUE" "Adding GitHub token to keychain..."
    # Remove existing token if it exists
    sudo -u "$CI_USER" env HOME="$CI_HOME" security delete-generic-password -a "$CI_USER" -s "GitHub Token" "$CI_KEYCHAIN" 2>/dev/null || true
    # Add new token
    sudo -u "$CI_USER" env HOME="$CI_HOME" security add-generic-password -a "$CI_USER" -s "GitHub Token" -w "$GITHUB_TOKEN" "$CI_KEYCHAIN" || {
        echo_color "$RED" "Failed to add GitHub token"
        exit 1
    }
fi

# 9. Final verification
echo_color "$BLUE" "Verifying keychain access..."
if sudo -u "$CI_USER" env HOME="$CI_HOME" security show-keychain-info "$CI_KEYCHAIN" 2>/dev/null; then
    echo_color "$GREEN" "✅ Keychain setup successful"
else
    echo_color "$RED" "❌ Failed to set up keychain"
    exit 1
fi

# Create necessary directories
mkdir -p "$CI_HOME/builds" "$CI_HOME/hooks" "$CI_HOME/plugins" "$CI_HOME/.tart/vms"
chown -R "$CI_USER:staff" "$CI_HOME"

# --- Prevent system sleep (server mode) ---
echo_color "$BLUE" "Configuring system to never sleep (server mode)..."
sudo systemsetup -setcomputersleep Never
sudo systemsetup -setdisplaysleep Never
sudo systemsetup -setharddisksleep Never
sudo pmset -a sleep 0
sudo pmset -a disablesleep 1

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
      sudo brew services start tailscale
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
        brew install cloudflared
        if ! command -v cloudflared &> /dev/null; then
          echo_color "$RED" "Failed to install cloudflared. Please install manually: brew install cloudflared"
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

# Get a unique machine identifier
get_machine_info() {
  # Get hardware UUID
  local uuid
  uuid=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}')
  if [ -z "$uuid" ]; then
    # Fallback: use serial number
    uuid=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
  fi
  if [ -z "$uuid" ]; then
    # Fallback: use hostname
    uuid=$(hostname)
  fi

  # Return all info as a JSON-like string
  echo "{\"uuid\":\"$uuid\",\"location\":\"$MACHINE_LOCATION\",\"computer_name\":\"$COMPUTER_NAME\"}"
}

# Parse machine info
MACHINE_INFO=$(get_machine_info)
AGENT_UUID=$(echo "$MACHINE_INFO" | grep -o '"uuid":"[^"]*"' | cut -d'"' -f4)
AGENT_LOCATION=$(echo "$MACHINE_INFO" | grep -o '"location":"[^"]*"' | cut -d'"' -f4)
AGENT_COMPUTER_NAME=$(echo "$MACHINE_INFO" | grep -o '"computer_name":"[^"]*"' | cut -d'"' -f4)

# Create a sanitized location name (remove spaces, special chars)
AGENT_LOCATION_SANITIZED=$(echo "$AGENT_LOCATION" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')

# Store the machine info in persistent files
echo "$MACHINE_LOCATION" > "$CI_HOME/.machine-location"
echo "$COMPUTER_NAME" > "$CI_HOME/.computer-name"
chown "$CI_USER:staff" "$CI_HOME/.machine-location" "$CI_HOME/.computer-name"

# Create the agent name
AGENT_NAME="macos-${AGENT_LOCATION_SANITIZED}-${AGENT_COMPUTER_NAME}-${AGENT_UUID:0:8}"
echo_color "$BLUE" "Debug: Final AGENT_NAME: $AGENT_NAME"

# Buildkite Agent config
cat > "$CI_HOME/buildkite-agent.cfg" << EOF
token="${BUILDKITE_AGENT_TOKEN}"
name="${AGENT_NAME}"
tags="os=darwin,arch=aarch64,queue=darwin,tart=true"
build-path="$CI_HOME/builds"
hooks-path="$CI_HOME/hooks"
plugins-path="$CI_HOME/plugins"
EOF
chown "$CI_USER:staff" "$CI_HOME/buildkite-agent.cfg"

# SSH config
cat > /etc/ssh/sshd_config.d/build-server.conf << EOF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowGroups wheel
EOF

# --- Final summary and next steps ---
echo_color "$GREEN" "\n[3/3] Setup complete!"
echo_color "$BLUE" "Log file: $LOGFILE"
echo_color "$YELLOW" "Summary of what was done:"
echo "  - Created CI user $CI_USER"
echo "  - Homebrew and dependencies installed"
echo "  - Tart installed via Cirrus Labs tap"
echo "  - Buildkite agent configured"
echo "  - SSH configuration updated"
if [ "$VPN_ENABLED" = true ]; then
  echo "  - VPN setup completed"
fi

# Define AGENT_BIN before using it in help text
AGENT_BIN="$(brew --prefix buildkite-agent)/bin/buildkite-agent"

echo_color "$YELLOW" "Next steps:"
echo "  1. Add your SSH keys to $CI_HOME/.ssh/authorized_keys"
if [ "$VPN_ENABLED" = true ]; then
  case "$VPN_TYPE" in
    wireguard)
      echo "  2. Test WireGuard connection: wg show" ;;
    tailscale)
      echo "  2. Test Tailscale connection: tailscale status" ;;
    unifi)
      echo "  2. Test UniFi VPN connection: openvpn --status" ;;
    cloudflare)
      echo "  2. Test Cloudflare Tunnel connection: cloudflared tunnel info" ;;
  esac
else
  echo "  2. VPN setup was skipped (local access only)"
fi
echo "  3. Set up Tart images in $CI_HOME/.tart/vms"
echo "  4. Buildkite is ready to run. Start the agent with: sudo -u $CI_USER $AGENT_BIN start"
echo "  5. Create base VMs with: sudo -u $CI_USER tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest sequoia-base"
echo "  6. Start Buildkite agent with: sudo -u $CI_USER $AGENT_BIN start"
echo_color "$GREEN" "\nAll done!"

# --- Prompt to create all base VMs (single y/n) ---
read -rp "Do you want to create the base VMs? (y/n): " yn_vms
if [[ "$(echo "$yn_vms" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
  base_vms=("base-macos-arm" "base-macos-intel" "base-m1" "base-m2" "base-m3" "base-m4")
  echo_color "$BLUE" "Creating all base VMs..."
  for vm in "${base_vms[@]}"; do
    sudo -u "$CI_USER" tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest "$vm"
  done
fi

# --- Write Buildkite agent config to Homebrew location ---
BK_CFG="/opt/homebrew/etc/buildkite-agent/buildkite-agent.cfg"
echo_color "$BLUE" "Writing Buildkite agent config to $BK_CFG..."

# Create Buildkite agent directories with correct permissions
echo_color "$BLUE" "Creating Buildkite agent directories..."
sudo mkdir -p /opt/homebrew/etc/buildkite-agent
sudo mkdir -p /opt/homebrew/etc/buildkite-agent/hooks
sudo mkdir -p /opt/homebrew/etc/buildkite-agent/plugins
sudo mkdir -p /opt/homebrew/var/log
sudo mkdir -p "$CI_HOME/builds"
sudo mkdir -p "$CI_HOME/hooks"
sudo mkdir -p "$CI_HOME/plugins"
sudo chown -R "$CI_USER:staff" /opt/homebrew/etc/buildkite-agent
sudo chown -R "$CI_USER:staff" /opt/homebrew/var/log
sudo chown -R "$CI_USER:staff" "$CI_HOME/builds" "$CI_HOME/hooks" "$CI_HOME/plugins"

sudo tee "$BK_CFG" > /dev/null << EOF
token="$BUILDKITE_AGENT_TOKEN"
name="${AGENT_NAME}"
tags="os=darwin,arch=aarch64,queue=darwin,tart=true"
build-path="$CI_HOME/builds"
hooks-path="$CI_HOME/hooks"
plugins-path="$CI_HOME/plugins"
log-file="/opt/homebrew/var/log/buildkite-agent.log"
EOF
sudo chown "$CI_USER:staff" "$BK_CFG"

# --- Set up Buildkite agent service to run as CI user ---
PLIST_PATH="/opt/homebrew/opt/buildkite-agent/homebrew.mxcl.buildkite-agent.plist"
echo_color "$BLUE" "Configuring Buildkite agent service to run as $CI_USER..."

# Fix permissions on the plist file
sudo chown root:wheel "$PLIST_PATH"
sudo chmod 644 "$PLIST_PATH"

# Ensure the CI user has access to Homebrew
echo_color "$BLUE" "Setting up Homebrew permissions for CI user..."
sudo chown -R "$CI_USER:staff" /opt/homebrew
sudo chmod -R 755 /opt/homebrew

# Set up Homebrew environment for CI user
echo_color "$BLUE" "Setting up Homebrew environment for CI user..."
sudo mkdir -p "$CI_HOME/Library/Caches/Homebrew"
sudo mkdir -p "$CI_HOME/Library/Logs/Homebrew"
sudo mkdir -p "$CI_HOME/Library/Application Support/Homebrew"
sudo chown -R "$CI_USER:staff" "$CI_HOME/Library"
sudo chmod -R 755 "$CI_HOME/Library"

# Set up Homebrew environment variables for CI user
echo_color "$BLUE" "Setting up Homebrew environment variables..."
sudo tee "$CI_HOME/.zprofile" > /dev/null << EOF
eval "\$(/opt/homebrew/bin/brew shellenv)"
export HOMEBREW_CACHE="\$HOME/Library/Caches/Homebrew"
export HOMEBREW_LOGS="\$HOME/Library/Logs/Homebrew"
export HOMEBREW_NO_ANALYTICS=1
EOF
sudo chown "$CI_USER:staff" "$CI_HOME/.zprofile"
sudo chmod 644 "$CI_HOME/.zprofile"

# Get the buildkite-agent binary path
AGENT_BIN="/opt/homebrew/opt/buildkite-agent/bin/buildkite-agent"

# Stop any existing service
echo_color "$BLUE" "Stopping any existing Buildkite agent service..."
cd "$CI_HOME" && sudo -u "$CI_USER" env HOME="$CI_HOME" brew services stop buildkite-agent || true

# Start the service as the CI user
echo_color "$BLUE" "Starting Buildkite agent service as $CI_USER..."
cd "$CI_HOME" && sudo -u "$CI_USER" env HOME="$CI_HOME" brew services start buildkite-agent

# Verify the service is running
sleep 5
if cd "$CI_HOME" && sudo -u "$CI_USER" env HOME="$CI_HOME" brew services list | grep -q "buildkite-agent.*started"; then
  echo_color "$GREEN" "✅ Buildkite agent service started successfully"
else
  echo_color "$RED" "❌ Failed to start Buildkite agent service"
  echo_color "$YELLOW" "Trying alternative start method..."
  sudo -u "$CI_USER" "$AGENT_BIN" start
fi

echo_color "$GREEN" "✅ Buildkite agent configured to run as $CI_USER"

# --- Final summary and next steps ---
echo_color "$GREEN" "\n[3/3] Setup complete!"
