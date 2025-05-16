#!/bin/bash

set -euo pipefail

echo "🍎 Setting up Mac build server..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo -E)"
    exit 1
fi

# Function to prompt for input if env var not set
prompt_if_not_set() {
    local var_name=$1
    local prompt_text=$2
    local is_secret=$3

    if [ -z "${!var_name-}" ]; then
        if [ "$is_secret" = "true" ]; then
            read -rsp "$prompt_text: " input
            echo
        else
            read -rp "$prompt_text: " input
        fi
        export "$var_name=$input"
    fi
}

# Function to prompt for VPN choice
prompt_vpn_choice() {
    if [ -z "${VPN_TYPE-}" ]; then
        echo "Select VPN type:"
        echo "1) WireGuard (default)"
        echo "2) Tailscale"
        echo "3) UniFi VPN"
        read -rp "Choice [1]: " vpn_choice
        
        case "${vpn_choice:-1}" in
            1) export VPN_TYPE="wireguard" ;;
            2) export VPN_TYPE="tailscale" ;;
            3) export VPN_TYPE="unifi" ;;
            *) export VPN_TYPE="wireguard" ;;
        esac
    fi
}

# Interactive prompts for required information
echo "Welcome to Bun.sh CI Setup"
echo "-------------------------"
echo "Press enter to use defaults or provide custom values."
echo

prompt_if_not_set BUILDKITE_AGENT_TOKEN "Enter your Buildkite Agent Token" true
prompt_if_not_set GRAFANA_ADMIN_PASSWORD "Enter Grafana admin password" true

# VPN Configuration
echo
echo "VPN Configuration"
echo "----------------"
prompt_vpn_choice

case "${VPN_TYPE}" in
    wireguard)
        prompt_if_not_set WIREGUARD_PRIVATE_KEY "Enter WireGuard private key" true
        prompt_if_not_set WIREGUARD_PUBLIC_KEY "Enter WireGuard peer public key" true
        prompt_if_not_set WIREGUARD_ENDPOINT "Enter WireGuard endpoint" false
        ;;
    tailscale)
        prompt_if_not_set TAILSCALE_AUTH_KEY "Enter Tailscale auth key (optional)" true
        ;;
    unifi)
        prompt_if_not_set UNIFI_VPN_USER "Enter UniFi VPN username" false
        prompt_if_not_set UNIFI_VPN_PASSWORD "Enter UniFi VPN password" true
        prompt_if_not_set UNIFI_VPN_SERVER "Enter UniFi VPN server" false
        ;;
esac

# Optional network configuration
echo
echo "Optional Network Configuration"
echo "----------------------------"
prompt_if_not_set BUILD_VLAN "Build VLAN [default: 10.0.1.0/24]" false
prompt_if_not_set MGMT_VLAN "Management VLAN [default: 10.0.2.0/24]" false
prompt_if_not_set STORAGE_VLAN "Storage VLAN [default: 10.0.3.0/24]" false

# Install Homebrew if not present
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install core dependencies
echo "Installing core dependencies..."
brew install \
    tart \
    buildkite/buildkite/buildkite-agent \
    prometheus \
    grafana \
    terraform \
    jq \
    yq \
    wget \
    git

# Install VPN dependencies based on type
case "$VPN_TYPE" in
    wireguard)
        echo "Installing WireGuard..."
        brew install wireguard-tools
        ;;
    tailscale)
        echo "Installing Tailscale..."
        brew install tailscale
        ;;
    unifi)
        echo "Installing OpenVPN client..."
        brew install openvpn
        ;;
esac

# Install monitoring tools
echo "Installing monitoring tools..."
brew install \
    node_exporter \
    prometheus-node-exporter \
    alertmanager

# Create necessary directories
echo "Creating directories..."
mkdir -p /opt/buildkite-agent
mkdir -p /opt/tart/images
mkdir -p /opt/prometheus
mkdir -p /opt/grafana
mkdir -p /var/log/buildkite-agent

# Set up VPN
echo "Setting up VPN..."
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
        if [ -n "${TAILSCALE_AUTH_KEY-}" ]; then
            echo "Setting up Tailscale with auth key..."
            tailscale up --authkey="$TAILSCALE_AUTH_KEY"
        else
            echo "Setting up Tailscale..."
            echo "Please run 'tailscale up' and follow the authentication prompts"
            tailscale up
        fi
        ;;
    unifi)
        mkdir -p /etc/openvpn
        cat > /etc/openvpn/auth.txt << EOF
${UNIFI_VPN_USER}
${UNIFI_VPN_PASSWORD}
EOF
        chmod 600 /etc/openvpn/auth.txt
        
        echo "Downloading UniFi VPN configuration..."
        curl -k -u "${UNIFI_VPN_USER}:${UNIFI_VPN_PASSWORD}" \
            "https://${UNIFI_VPN_SERVER}:943/remote/client.ovpn" \
            -o /etc/openvpn/unifi.ovpn
        
        echo "auth-user-pass /etc/openvpn/auth.txt" >> /etc/openvpn/unifi.ovpn
        ;;
esac

# Set up Buildkite Agent
echo "Setting up Buildkite Agent..."
cat > /opt/buildkite-agent/buildkite-agent.cfg << EOF
token="${BUILDKITE_AGENT_TOKEN}"
name="%hostname-%n"
tags="os=macos,arch=$(uname -m)"
build-path="/opt/buildkite-agent/builds"
hooks-path="/opt/buildkite-agent/hooks"
plugins-path="/opt/buildkite-agent/plugins"
EOF

# Set up Prometheus
echo "Setting up Prometheus..."
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

# Set up Grafana
echo "Setting up Grafana..."
cat > /opt/grafana/grafana.ini << EOF
[server]
http_port = 3000
domain = localhost

[security]
admin_user = admin
admin_password = ${GRAFANA_ADMIN_PASSWORD}
EOF

# Set up SSH
echo "Setting up SSH..."
cat > /etc/ssh/sshd_config.d/build-server.conf << EOF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowGroups buildkite-agent wheel
EOF

# Create services
echo "Creating launch agents..."

# Buildkite Agent
cat > /Library/LaunchDaemons/com.buildkite.buildkite-agent.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.buildkite.buildkite-agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/buildkite-agent</string>
        <string>start</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/buildkite-agent/buildkite-agent.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/buildkite-agent/buildkite-agent.log</string>
</dict>
</plist>
EOF

# Prometheus
cat > /Library/LaunchDaemons/com.prometheus.prometheus.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.prometheus.prometheus</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/prometheus</string>
        <string>--config.file=/opt/prometheus/prometheus.yml</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/prometheus.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/prometheus.log</string>
</dict>
</plist>
EOF

# Start services
echo "Starting services..."
launchctl load /Library/LaunchDaemons/com.buildkite.buildkite-agent.plist
launchctl load /Library/LaunchDaemons/com.prometheus.prometheus.plist

# Start VPN service if applicable
case "$VPN_TYPE" in
    wireguard)
        echo "Starting WireGuard..."
        wg-quick up wg0
        ;;
    tailscale)
        echo "Starting Tailscale..."
        launchctl load /Library/LaunchDaemons/com.tailscale.tailscaled.plist
        ;;
    unifi)
        echo "Starting UniFi VPN..."
        openvpn --config /etc/openvpn/unifi.ovpn --daemon
        ;;
esac

echo "✅ Setup complete!"
echo "Next steps:"
echo "1. Configure Grafana at http://localhost:3000"
echo "2. Add your SSH keys to ~/.ssh/authorized_keys"

# VPN-specific next steps
case "$VPN_TYPE" in
    wireguard)
        echo "3. Test WireGuard connection: wg show"
        ;;
    tailscale)
        echo "3. Test Tailscale connection: tailscale status"
        ;;
    unifi)
        echo "3. Test UniFi VPN connection: openvpn --status"
        ;;
esac

echo "4. Set up Tart images in /opt/tart/images"
echo "5. Review and customize Prometheus config"

# Print environment variables for future use
echo ""
echo "🔑 Save these environment variables for future use:"
echo "export VPN_TYPE='${VPN_TYPE}'"
echo "export BUILDKITE_AGENT_TOKEN='${BUILDKITE_AGENT_TOKEN}'"

# VPN-specific variables
case "$VPN_TYPE" in
    wireguard)
        echo "export WIREGUARD_PRIVATE_KEY='${WIREGUARD_PRIVATE_KEY}'"
        echo "export WIREGUARD_PUBLIC_KEY='${WIREGUARD_PUBLIC_KEY}'"
        echo "export WIREGUARD_ENDPOINT='${WIREGUARD_ENDPOINT}'"
        ;;
    tailscale)
        [ -n "${TAILSCALE_AUTH_KEY-}" ] && echo "export TAILSCALE_AUTH_KEY='${TAILSCALE_AUTH_KEY}'"
        ;;
    unifi)
        echo "export UNIFI_VPN_USER='${UNIFI_VPN_USER}'"
        echo "export UNIFI_VPN_PASSWORD='${UNIFI_VPN_PASSWORD}'"
        echo "export UNIFI_VPN_SERVER='${UNIFI_VPN_SERVER}'"
        ;;
esac

echo "export GRAFANA_ADMIN_PASSWORD='${GRAFANA_ADMIN_PASSWORD}'"
