#!/bin/bash



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

  read -rp $'\033[1;32mContinue with setup? (y/n): \033[0m' confirm_start
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

  # 0. VPN setup optional
  while true; do
    read -rp "Do you want to configure VPN access (WireGuard/Tailscale/UniFi)? (y/n): " vpn_enable
    case "$(echo "$vpn_enable" | tr '[:upper:]' '[:lower:]')" in
      y|yes) VPN_ENABLED=true; break ;;
      n|no) VPN_ENABLED=false; break ;;
      *) echo_color "$YELLOW" "Please enter 'y' or 'n'." ;;
    esac
  done

  # 1. Buildkite token
  prompt_secret BUILDKITE_AGENT_TOKEN "Enter your Buildkite Agent Token"

  # 2. Grafana password
  prompt_secret GRAFANA_ADMIN_PASSWORD "Enter Grafana admin password"

  # 3. VPN type and details (if enabled)
  if [ "$VPN_ENABLED" = true ]; then
    while true; do
      echo_color "$BLUE" "Select VPN type:"
      echo "  1) WireGuard (default)"
      echo "  2) Tailscale"
      echo "  3) UniFi VPN"
      read -rp "Choice [1]: " vpn_choice
      case "${vpn_choice:-1}" in
        1|"") VPN_TYPE="wireguard"; break ;;
        2) VPN_TYPE="tailscale"; break ;;
        3) VPN_TYPE="unifi"; break ;;
        *) echo_color "$YELLOW" "Invalid choice. Please enter 1, 2, or 3." ;;
      esac
    done
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
    esac
  fi

  # 4. Optional network config
  prompt_text BUILD_VLAN "Build VLAN" "10.0.1.0/24"
  prompt_text MGMT_VLAN "Management VLAN" "10.0.2.0/24"
  prompt_text STORAGE_VLAN "Storage VLAN" "10.0.3.0/24"

  # --- Show summary and confirm ---
  echo_color "$YELLOW" "\nSummary of your choices:"
  echo "  Buildkite Agent Token:   [hidden]"
  echo "  Grafana Admin Password:   [hidden]"
  echo "  VPN Setup:                $([[ "$VPN_ENABLED" = true ]] && echo "Enabled" || echo "Skipped")"
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
    esac
  fi
  echo "  Build VLAN:               $BUILD_VLAN"
  echo "  Management VLAN:          $MGMT_VLAN"
  echo "  Storage VLAN:             $STORAGE_VLAN"

  read -rp "Proceed with installation? (y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    echo_color "$RED" "Aborted by user."
    exit 1
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
    brew install buildkite/buildkite/buildkite-agent prometheus grafana terraform jq yq wget git wireguard-tools openvpn node_exporter node
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

    echo_color "$BLUE" "Switching to root for system configuration..."
    export_vars="BUILDKITE_AGENT_TOKEN=\"$BUILDKITE_AGENT_TOKEN\" GRAFANA_ADMIN_PASSWORD=\"$GRAFANA_ADMIN_PASSWORD\" VPN_ENABLED=\"$VPN_ENABLED\" BUILD_VLAN=\"$BUILD_VLAN\" MGMT_VLAN=\"$MGMT_VLAN\" STORAGE_VLAN=\"$STORAGE_VLAN\""
    if [ "$VPN_ENABLED" = true ]; then
      export_vars+=" VPN_TYPE=\"$VPN_TYPE\""
      case "$VPN_TYPE" in
        wireguard)
          export_vars+=" WIREGUARD_PRIVATE_KEY=\"$WIREGUARD_PRIVATE_KEY\" WIREGUARD_PUBLIC_KEY=\"$WIREGUARD_PUBLIC_KEY\" WIREGUARD_ENDPOINT=\"$WIREGUARD_ENDPOINT\"" ;;
        tailscale)
          export_vars+=" TAILSCALE_AUTH_KEY=\"$TAILSCALE_AUTH_KEY\"" ;;
        unifi)
          export_vars+=" UNIFI_VPN_USER=\"$UNIFI_VPN_USER\" UNIFI_VPN_PASSWORD=\"$UNIFI_VPN_PASSWORD\" UNIFI_VPN_SERVER=\"$UNIFI_VPN_SERVER\"" ;;
      esac
    fi
    eval exec sudo $export_vars "$0" "$@"
  fi
fi

# --- Privileged setup (root) ---
echo_color "$BLUE" "\n[2/3] Running privileged setup..."

# Ensure buildkite-agent user exists before any chown or file operations
if ! id -u buildkite-agent >/dev/null 2>&1; then
  echo_color "$YELLOW" "Creating buildkite-agent user..."
  sudo dscl . -create /Users/buildkite-agent
  sudo dscl . -create /Users/buildkite-agent UserShell /bin/bash
  sudo dscl . -create /Users/buildkite-agent RealName "Buildkite Agent"
  sudo dscl . -create /Users/buildkite-agent UniqueID "$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1 | awk '{print $1+1}')"
  sudo dscl . -create /Users/buildkite-agent PrimaryGroupID 20
  sudo dscl . -create /Users/buildkite-agent NFSHomeDirectory /Users/buildkite-agent
  sudo mkdir -p /Users/buildkite-agent
  sudo chown buildkite-agent:staff /Users/buildkite-agent
  sudo dscl . -append /Groups/wheel GroupMembership buildkite-agent
  echo_color "$GREEN" "User 'buildkite-agent' created."
fi

mkdir -p /opt/buildkite-agent /opt/tart/images /opt/prometheus /opt/grafana /var/log/buildkite-agent

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
  esac
fi

# Buildkite Agent config
cat > /opt/buildkite-agent/buildkite-agent.cfg << EOF
token="${BUILDKITE_AGENT_TOKEN}"
name="%hostname-%n"
tags="os=macos,arch=$(uname -m),queue=build-darwin"
build-path="/opt/buildkite-agent/builds"
hooks-path="/opt/buildkite-agent/hooks"
plugins-path="/opt/buildkite-agent/plugins"
EOF

# Prometheus config
cat > /opt/prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
  - job_name: 'buildkite'
    static_configs:
      - targets: ['localhost:9200']
EOF

# Grafana config
cat > /opt/grafana/grafana.ini << EOF
[server]
http_port = 3400
domain = localhost
[security]
admin_user = admin
admin_password = ${GRAFANA_ADMIN_PASSWORD}
EOF

# SSH config
cat > /etc/ssh/sshd_config.d/build-server.conf << EOF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowGroups buildkite-agent wheel
EOF

# --- Final summary and next steps ---
echo_color "$GREEN" "\n[3/3] Setup complete!"
echo_color "$BLUE" "Log file: $LOGFILE"
echo_color "$YELLOW" "Summary of what was done:"
echo "  - Homebrew and dependencies installed"
echo "  - Tart installed via Cirrus Labs tap"
echo "  - Buildkite agent configured"
echo "  - Prometheus and Grafana configured"
echo "  - SSH configuration updated"
if [ "$VPN_ENABLED" = true ]; then
  echo "  - VPN setup completed"
fi
echo_color "$YELLOW" "Next steps:"
echo "  1. Configure Grafana at http://localhost:3400 (user: admin, pass: $GRAFANA_ADMIN_PASSWORD)"
echo "  2. Open Prometheus at http://localhost:9090 (no login required by default)"
echo "  3. Add your SSH keys to ~/.ssh/authorized_keys"
if [ "$VPN_ENABLED" = true ]; then
  case "$VPN_TYPE" in
    wireguard)
      echo "  4. Test WireGuard connection: wg show" ;;
    tailscale)
      echo "  4. Test Tailscale connection: tailscale status" ;;
    unifi)
      echo "  4. Test UniFi VPN connection: openvpn --status" ;;
  esac
else
  echo "  4. VPN setup was skipped (local access only)" ;
fi
echo "  5. Set up Tart images in /opt/tart/images"
echo "  6. Review and customize Prometheus config"
echo "  7. Buildkite is ready to run. Start the agent with: sudo -u buildkite-agent /opt/buildkite-agent/bin/buildkite-agent start"
echo "  8. Create base VMs with: tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest sequoia-base"
echo "  9. Start Buildkite agent with: sudo -u buildkite-agent /opt/buildkite-agent/bin/buildkite-agent start"
echo "  10. Use these Buildkite aliases:"
echo "      - bk-start: Start the agent"
echo "      - bk-stop: Stop the agent"
echo "      - bk-restart: Restart the agent"
echo "      - bk-status: Check agent status"
echo "      - bk-token: View the agent token"
echo "      - bk-update-config: Edit agent config"
echo_color "$GREEN" "\nAll done!"

# --- Prompt to create all base VMs (single y/n) ---
read -rp "Do you want to create the base VMs? (y/n): " yn_vms
if [[ "$(echo "$yn_vms" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
  base_vms=("base-macos-arm" "base-macos-intel" "base-m1" "base-m2" "base-m3" "base-m4")
  echo_color "$BLUE" "Creating all base VMs..."
  for vm in "${base_vms[@]}"; do
    tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest "$vm"
  done
fi

# --- Write Buildkite agent config to Homebrew location ---
BK_CFG="/opt/homebrew/etc/buildkite-agent/buildkite-agent.cfg"
echo_color "$BLUE" "Writing Buildkite agent config to $BK_CFG..."
sudo mkdir -p /opt/homebrew/etc/buildkite-agent
sudo tee "$BK_CFG" > /dev/null << EOF
token="$BUILDKITE_AGENT_TOKEN"
name="%hostname-%n"
tags="os=macos,arch=$(uname -m),queue=build-darwin"
build-path="/opt/buildkite-agent/builds"
hooks-path="/opt/buildkite-agent/hooks"
plugins-path="/opt/buildkite-agent/plugins"
EOF
sudo chown buildkite-agent:staff "$BK_CFG"

# --- Save Buildkite token and create aliases ---
echo_color "$BLUE" "Setting up Buildkite aliases and token storage..."
# Create a secure directory for the token
sudo mkdir -p /opt/buildkite-agent/.secrets
echo "$BUILDKITE_AGENT_TOKEN" | sudo tee /opt/buildkite-agent/.secrets/token > /dev/null
sudo chown -R buildkite-agent:staff /opt/buildkite-agent/.secrets
sudo chmod 700 /opt/buildkite-agent/.secrets
sudo chmod 600 /opt/buildkite-agent/.secrets/token

# Create aliases for the buildkite-agent user
sudo tee /Users/buildkite-agent/.zshrc > /dev/null << 'EOF'
# Buildkite aliases
alias bk='buildkite-agent'
alias bk-start='sudo -u buildkite-agent /opt/homebrew/bin/buildkite-agent start'
alias bk-stop='sudo -u buildkite-agent /opt/homebrew/bin/buildkite-agent stop'
alias bk-restart='bk-stop && bk-start'
alias bk-status='sudo -u buildkite-agent /opt/homebrew/bin/buildkite-agent status'
alias bk-token='cat /opt/buildkite-agent/.secrets/token'

# Function to update Buildkite config
bk-update-config() {
  sudo vim /opt/homebrew/etc/buildkite-agent/buildkite-agent.cfg
  bk-restart
}
EOF

# Also add aliases for the current user
tee ~/.zshrc > /dev/null << 'EOF'
# Buildkite aliases
alias bk='buildkite-agent'
alias bk-start='sudo -u buildkite-agent /opt/homebrew/bin/buildkite-agent start'
alias bk-stop='sudo -u buildkite-agent /opt/homebrew/bin/buildkite-agent stop'
alias bk-restart='bk-stop && bk-start'
alias bk-status='sudo -u buildkite-agent /opt/homebrew/bin/buildkite-agent status'
alias bk-token='sudo cat /opt/buildkite-agent/.secrets/token'

# Function to update Buildkite config
bk-update-config() {
  sudo vim /opt/homebrew/etc/buildkite-agent/buildkite-agent.cfg
  bk-restart
}
EOF

# --- Start Buildkite agent as buildkite-agent user using Homebrew path and correct HOME ---
AGENT_BIN="$(brew --prefix buildkite-agent)/bin/buildkite-agent"
echo_color "$BLUE" "Starting Buildkite agent as 'buildkite-agent' using $AGENT_BIN..."
sudo mkdir -p /opt/buildkite-agent/builds
sudo chown -R buildkite-agent:staff /opt/buildkite-agent
sudo mkdir -p /Users/buildkite-agent
sudo chown buildkite-agent:staff /Users/buildkite-agent
sudo -u buildkite-agent env HOME=/Users/buildkite-agent "$AGENT_BIN" start --config "$BK_CFG" &

# --- Update Grafana config to use port 3400 ---
sed -i '' 's/^http_port = .*/http_port = 3400/' /opt/grafana/grafana.ini 2>/dev/null || true

# --- Start Prometheus server if not running ---
if ! pgrep -f 'prometheus' > /dev/null; then
  echo_color "$BLUE" "Starting Prometheus server on port 9090..."
  (prometheus --config.file=/opt/prometheus/prometheus.yml --storage.tsdb.path=/opt/prometheus &)
  sleep 2
  if pgrep -f 'prometheus' > /dev/null; then
    echo_color "$GREEN" "Prometheus started successfully on http://localhost:9090"
  else
    echo_color "$RED" "Failed to start Prometheus. Please check logs or try manually: prometheus --config.file=/opt/prometheus/prometheus.yml --storage.tsdb.path=/opt/prometheus"
  fi
else
  echo_color "$GREEN" "Prometheus is already running."
fi

# --- Start Grafana server if not running (port 3400) ---
sed -i '' 's/^http_port = .*/http_port = 3400/' /opt/grafana/grafana.ini 2>/dev/null || true
if ! pgrep -f 'grafana server' > /dev/null; then
  echo_color "$BLUE" "Starting Grafana server on port 3400..."
  (grafana server --config=/opt/grafana/grafana.ini --homepath=$(brew --prefix grafana)/share/grafana &)
  sleep 2
  if pgrep -f 'grafana server' > /dev/null; then
    echo_color "$GREEN" "Grafana started successfully on http://localhost:3400"
  else
    echo_color "$RED" "Failed to start Grafana. Please check logs or try manually: grafana server --config=/opt/grafana/grafana.ini --homepath=$(brew --prefix grafana)/share/grafana"
  fi
else
  echo_color "$GREEN" "Grafana is already running."
fi

# --- After starting Prometheus and Grafana, print login info ---
echo_color "$YELLOW" "\nAccess your monitoring dashboards:"
echo "  - Prometheus: http://localhost:9090 (no login required by default)"
echo "  - Grafana:    http://localhost:3400"
echo "      Username: admin"
echo "      Password: $GRAFANA_ADMIN_PASSWORD"
echo ""
echo_color "$YELLOW" "If you want to secure Prometheus with a password, see: https://prometheus.io/docs/prometheus/latest/configuration/https/ (not set by this script)"

# --- Automatically open Prometheus and Grafana in browser ---
open http://localhost:9090
open http://localhost:3400
