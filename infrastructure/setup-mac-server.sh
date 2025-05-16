#!/bin/bash

set -euo pipefail

echo "🍎 Setting up Mac build server..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

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
    wireguard-tools \
    tailscale \
    terraform \
    jq \
    yq \
    wget \
    git

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
mkdir -p /etc/wireguard
mkdir -p /var/log/buildkite-agent

# Set up Buildkite Agent
echo "Setting up Buildkite Agent..."
read -p "Enter your Buildkite Agent token: " BUILDKITE_AGENT_TOKEN

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
EOF

# Set up WireGuard
echo "Setting up WireGuard..."
read -p "Enter WireGuard private key: " WIREGUARD_PRIVATE_KEY
read -p "Enter WireGuard endpoint: " WIREGUARD_ENDPOINT

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = ${WIREGUARD_PRIVATE_KEY}
Address = 10.0.0.2/24
ListenPort = 51820

[Peer]
PublicKey = # TODO: Add server public key
Endpoint = ${WIREGUARD_ENDPOINT}:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

# Set up Tailscale
echo "Setting up Tailscale..."
tailscale up

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

echo "✅ Setup complete!"
echo "Next steps:"
echo "1. Configure Grafana at http://localhost:3000"
echo "2. Add your SSH keys to ~/.ssh/authorized_keys"
echo "3. Configure WireGuard with peer public key"
echo "4. Set up Tart images in /opt/tart/images"
echo "5. Review and customize Prometheus config"
