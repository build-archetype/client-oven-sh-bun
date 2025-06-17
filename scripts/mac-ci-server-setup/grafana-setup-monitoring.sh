#!/bin/bash
set -euo pipefail

# Setup Grafana monitoring on macOS CI hosts using Official Grafana Cloud Alloy Integration
# This script uses the official Grafana Cloud setup for proper dashboard compatibility

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "🔧 Setting up Official Grafana Cloud Alloy monitoring on CI host..."

# Detect the CI user (following setup-mac-server.sh pattern)
if [ "$EUID" -eq 0 ]; then
    # Running as root, find the real CI user
    if [ -n "${SUDO_USER:-}" ]; then
        REAL_USER="$SUDO_USER"
    else
        # Look for buildkite-agent process owner
        REAL_USER=$(ps aux | grep buildkite-agent | grep -v grep | head -1 | awk '{print $1}' || echo "")
        if [ -z "$REAL_USER" ]; then
            # Fallback: look for who owns the buildkite config
            if [ -f "/opt/homebrew/etc/buildkite-agent/buildkite-agent.cfg" ]; then
                REAL_USER=$(stat -f "%Su" "/opt/homebrew/etc/buildkite-agent/buildkite-agent.cfg")
            elif [ -f "/usr/local/etc/buildkite-agent/buildkite-agent.cfg" ]; then
                REAL_USER=$(stat -f "%Su" "/usr/local/etc/buildkite-agent/buildkite-agent.cfg")
            else
                log "❌ Cannot determine CI user. Please run as the CI user or with sudo."
                exit 1
            fi
        fi
    fi
else
    # Running as regular user
    REAL_USER="$USER"
fi

REAL_HOME=$(eval echo ~$REAL_USER)
log "🔍 Detected CI user: $REAL_USER"
log "🏠 CI user home: $REAL_HOME"

# Validate required environment variables for Official Grafana Cloud setup
REQUIRED_VARS=(
    "GCLOUD_HOSTED_METRICS_ID"
    "GCLOUD_HOSTED_METRICS_URL"
    "GCLOUD_HOSTED_LOGS_ID"
    "GCLOUD_HOSTED_LOGS_URL"
    "GCLOUD_FM_URL"
    "GCLOUD_FM_POLL_FREQUENCY"
    "GCLOUD_FM_HOSTED_ID"
    "GCLOUD_RW_API_KEY"
    "ARCH"
)

# Check required variables
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log "❌ Missing required environment variable: $var"
        log "   Please set it in your environment:"
        log "   export $var='your-value-here'"
        log ""
        log "   Get your integration details from: https://grafana.com/orgs/<your-org>/integrations/alloy"
        log ""
        log "   Quick setup:"
        log "   1. Copy: cp grafana-env.template grafana-env.sh"
        log "   2. Edit: vi grafana-env.sh  # Add your values"
        log "   3. Load: source grafana-env.sh"
        log "   4. Run:  ./setup-grafana-monitoring.sh"
        exit 1
    fi
done

log "✅ All required Grafana Cloud Alloy credentials found"

# Show configuration being used
log "📋 Official Grafana Cloud Alloy configuration:"
log "   Metrics ID: $GCLOUD_HOSTED_METRICS_ID"
log "   Metrics URL: $GCLOUD_HOSTED_METRICS_URL"
log "   Logs ID: $GCLOUD_HOSTED_LOGS_ID"
log "   Logs URL: $GCLOUD_HOSTED_LOGS_URL"
log "   Fleet Management: $GCLOUD_FM_URL"
log "   Architecture: $ARCH"
log "   API Key: ${GCLOUD_RW_API_KEY:0:10}..." # Show first 10 chars only

# Detect machine info for labeling
MACHINE_UUID=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}' 2>/dev/null || echo "unknown")
MACHINE_ARCH="${ARCH:-$(uname -m)}"

# Get Buildkite agent name from config file (more reliable than env var)
BUILDKITE_AGENT_NAME=""
if [ -f "/opt/homebrew/etc/buildkite-agent/buildkite-agent.cfg" ]; then
    BUILDKITE_AGENT_NAME=$(grep '^name=' "/opt/homebrew/etc/buildkite-agent/buildkite-agent.cfg" | cut -d'"' -f2 2>/dev/null)
elif [ -f "/usr/local/etc/buildkite-agent/buildkite-agent.cfg" ]; then
    BUILDKITE_AGENT_NAME=$(grep '^name=' "/usr/local/etc/buildkite-agent/buildkite-agent.cfg" | cut -d'"' -f2 2>/dev/null)
fi

# Use Buildkite agent name if found, otherwise fall back to hostname + UUID
if [ -n "$BUILDKITE_AGENT_NAME" ]; then
    MACHINE_NAME="$BUILDKITE_AGENT_NAME"
    log "✅ Using Buildkite agent name: $BUILDKITE_AGENT_NAME"
else
    MACHINE_NAME="$(hostname -s)-${MACHINE_UUID:0:8}"
    log "⚠️ Buildkite agent name not found, using hostname: $MACHINE_NAME"
fi

MACHINE_LOCATION="${BUILDKITE_AGENT_META_DATA_MACHINE_LOCATION:-unknown}"

log "Machine info:"
log "  Name: $MACHINE_NAME"
log "  Arch: $MACHINE_ARCH"
log "  Location: $MACHINE_LOCATION"
log "  Build ID: ${BUILDKITE_BUILD_ID:-unknown}"

# Stop any existing services first
log "🛑 Stopping any existing Alloy services..."
sudo brew services stop alloy 2>/dev/null || true
brew services stop alloy 2>/dev/null || true

# Run the Official Grafana Cloud Alloy Installation
log "📦 Installing Official Grafana Cloud Alloy using official script..."

# Export all required environment variables for the installation script
export GCLOUD_HOSTED_METRICS_ID
export GCLOUD_HOSTED_METRICS_URL
export GCLOUD_HOSTED_LOGS_ID
export GCLOUD_HOSTED_LOGS_URL
export GCLOUD_FM_URL
export GCLOUD_FM_POLL_FREQUENCY
export GCLOUD_FM_HOSTED_ID
export GCLOUD_RW_API_KEY
export ARCH

# Run the official installation script
if /bin/sh -c "$(curl -fsSL https://storage.googleapis.com/cloud-onboarding/alloy/scripts/install-macos-homebrew.sh)"; then
    log "✅ Official Grafana Cloud Alloy installation completed"
else
    log "❌ Failed to install Official Grafana Cloud Alloy"
    exit 1
fi

# Install Node Exporter separately (as the CI user for consistency)
log "📦 Installing Node Exporter for additional system metrics..."

# Setup Homebrew PATH for CI environments
run_as_ci_user() {
    local cmd="$1"
    sudo -u "$REAL_USER" bash -c "
        # Load Homebrew environment
        if [ -f '/opt/homebrew/bin/brew' ]; then
            eval \"\$(/opt/homebrew/bin/brew shellenv)\"
            export HOMEBREW_PREFIX='/opt/homebrew'
        elif [ -f '/usr/local/bin/brew' ]; then
            eval \"\$(/usr/local/bin/brew shellenv)\"
            export HOMEBREW_PREFIX='/usr/local'
        else
            echo 'Homebrew not found in standard locations'
            exit 1
        fi
        export HOMEBREW_NO_AUTO_UPDATE=1
        export HOMEBREW_NO_INSTALL_CLEANUP=1
        cd '$REAL_HOME'
        $cmd
    "
}

# Install Node Exporter if not present
if ! run_as_ci_user "brew list node_exporter" &>/dev/null; then
    log "📦 Installing node_exporter as $REAL_USER..."
    if run_as_ci_user "brew install node_exporter"; then
        log "✅ node_exporter installed successfully"
    else
        log "❌ Failed to install node_exporter"
        exit 1
    fi
else
    log "✅ node_exporter already installed"
fi

# Add the Official macOS Integration Configuration
log "📝 Adding Official macOS Integration to Alloy configuration..."

# Get the Homebrew prefix
if [ -f '/opt/homebrew/bin/brew' ]; then
    HOMEBREW_PREFIX='/opt/homebrew'
elif [ -f '/usr/local/bin/brew' ]; then
    HOMEBREW_PREFIX='/usr/local'
else
    log "❌ Homebrew not found"
    exit 1
fi

# Backup existing config if present
if [ -f "$HOMEBREW_PREFIX/etc/alloy/config.alloy" ]; then
    log "💾 Backing up existing Alloy config..."
    cp "$HOMEBREW_PREFIX/etc/alloy/config.alloy" "$HOMEBREW_PREFIX/etc/alloy/config.alloy.backup.$(date +%s)"
fi

# Create the Official macOS configuration
cat > "$HOMEBREW_PREFIX/etc/alloy/config.alloy" << EOF
// Official Grafana Cloud Alloy configuration for macOS integration
// Generated automatically by setup-grafana-monitoring.sh
// Based on: https://grafana.com/orgs/<your-org>/integrations/alloy

prometheus.exporter.unix "integrations_node_exporter" { }

discovery.relabel "integrations_node_exporter" {
	targets = prometheus.exporter.unix.integrations_node_exporter.targets

	rule {
		target_label = "instance"
		replacement  = "$MACHINE_NAME"
	}

	rule {
		target_label = "job"
		replacement  = "integrations/macos-node"
	}
	
	// Add CI-specific labels for build tracking
	rule {
		target_label = "machine_name"
		replacement = "$MACHINE_NAME"
	}
	
	rule {
		target_label = "machine_location"
		replacement = "$MACHINE_LOCATION"
	}
	
	rule {
		target_label = "machine_arch"
		replacement = "$MACHINE_ARCH"
	}
	
	rule {
		target_label = "service_type"
		replacement = "buildkite-agent"
	}
	
	rule {
		target_label = "build_id"
		replacement = "${BUILDKITE_BUILD_ID:-unknown}"
	}
	
	rule {
		target_label = "pipeline_slug"
		replacement = "${BUILDKITE_PIPELINE_SLUG:-unknown}"
	}
}

prometheus.scrape "integrations_node_exporter" {
	targets    = discovery.relabel.integrations_node_exporter.output
	forward_to = [prometheus.relabel.integrations_node_exporter.receiver]
	job_name   = "integrations/node_exporter"
}

prometheus.relabel "integrations_node_exporter" {
	forward_to = [prometheus.remote_write.metrics_service.receiver]

	rule {
		source_labels = ["__name__"]
		regex         = "up|node_boot_time_seconds|node_cpu_seconds_total|node_disk_io_time_seconds_total|node_disk_read_bytes_total|node_disk_written_bytes_total|node_filesystem_avail_bytes|node_filesystem_files|node_filesystem_files_free|node_filesystem_readonly|node_filesystem_size_bytes|node_load1|node_load15|node_load5|node_memory_compressed_bytes|node_memory_internal_bytes|node_memory_purgeable_bytes|node_memory_swap_total_bytes|node_memory_swap_used_bytes|node_memory_total_bytes|node_memory_wired_bytes|node_network_receive_bytes_total|node_network_receive_drop_total|node_network_receive_errs_total|node_network_receive_packets_total|node_network_transmit_bytes_total|node_network_transmit_drop_total|node_network_transmit_errs_total|node_network_transmit_packets_total|node_os_info|node_textfile_scrape_error|node_uname_info"
		action        = "keep"
	}
}

local.file_match "logs_integrations_integrations_node_exporter_direct_scrape" {
	path_targets = [{
		__address__ = "localhost",
		__path__    = "/var/log/*.log",
		instance    = "$MACHINE_NAME",
		job         = "integrations/macos-node",
	}]
}

loki.process "logs_integrations_integrations_node_exporter_direct_scrape" {
	forward_to = [loki.write.grafana_cloud_loki.receiver]

	stage.multiline {
		firstline     = "^([\\\\w]{3} )?[\\\\w]{3} +[\\\\d]+ [\\\\d]+:[\\\\d]+:[\\\\d]+|[\\\\w]{4}-[\\\\w]{2}-[\\\\w]{2} [\\\\w]{2}:[\\\\w]{2}:[\\\\w]{2}(?:[+-][\\\\w]{2})?"
		max_lines     = 0
		max_wait_time = "10s"
	}

	stage.regex {
		expression = "(?P<timestamp>([\\\\w]{3} )?[\\\\w]{3} +[\\\\d]+ [\\\\d]+:[\\\\d]+:[\\\\d]+|[\\\\w]{4}-[\\\\w]{2}-[\\\\w]{2} [\\\\w]{2}:[\\\\w]{2}:[\\\\w]{2}(?:[+-][\\\\w]{2})?) (?P<hostname>\\\\S+) (?P<sender>.+?)\\\\[(?P<pid>\\\\d+)\\\\]:? (?P<message>(?s:.*))$"
	}

	stage.labels {
		values = {
			hostname = null,
			pid      = null,
			sender   = null,
		}
	}

	stage.match {
		selector = "{sender!=\"\", pid!=\"\"}"

		stage.template {
			source   = "message"
			template = "{{ .sender }}[{{ .pid }}]: {{ .message }}"
		}

		stage.label_drop {
			values = ["pid"]
		}

		stage.output {
			source = "message"
		}
	}
}

loki.source.file "logs_integrations_integrations_node_exporter_direct_scrape" {
	targets    = local.file_match.logs_integrations_integrations_node_exporter_direct_scrape.targets
	forward_to = [loki.process.logs_integrations_integrations_node_exporter_direct_scrape.receiver]
}

// Send metrics to Grafana Cloud (Official Integration)
prometheus.remote_write "metrics_service" {
	endpoint {
		url = "$GCLOUD_HOSTED_METRICS_URL"
		basic_auth {
			username = "$GCLOUD_HOSTED_METRICS_ID"
			password = "$GCLOUD_RW_API_KEY"
		}
	}
}

// Send logs to Grafana Cloud (Official Integration)
loki.write "grafana_cloud_loki" {
	endpoint {
		url = "$GCLOUD_HOSTED_LOGS_URL"
		basic_auth {
			username = "$GCLOUD_HOSTED_LOGS_ID"
			password = "$GCLOUD_RW_API_KEY"
		}
	}
}

EOF

log "✅ Official macOS integration configuration created"

# Start Node Exporter service 
log "🚀 Starting Node Exporter as $REAL_USER..."
if run_as_ci_user "brew services start node_exporter"; then
    log "✅ Node Exporter started successfully"
else
    log "⚠️ Node Exporter may have failed to start, but continuing..."
fi

# Fix Alloy storage permissions (required for official installation)
log "🔧 Setting up Alloy storage directory permissions..."
if sudo mkdir -p "$HOMEBREW_PREFIX/var/lib/alloy/data"; then
    if sudo chown -R "$REAL_USER:staff" "$HOMEBREW_PREFIX/var/lib/alloy"; then
        log "✅ Alloy storage directory created with proper permissions"
    else
        log "⚠️ Failed to set ownership on Alloy storage directory, but continuing..."
    fi
else
    log "⚠️ Failed to create Alloy storage directory, but continuing..."
fi

# Start the Official Alloy service
log "🚀 Starting Official Grafana Cloud Alloy service..."
if brew services start alloy; then
    log "✅ Official Grafana Cloud Alloy started successfully"
else
    log "❌ Failed to start Official Grafana Cloud Alloy"
    exit 1
fi

# Wait a moment for services to start
sleep 10

# Verify services are running
log "🔍 Verifying services..."

if curl -s http://localhost:9100/metrics > /dev/null; then
    log "✅ Node Exporter is running (port 9100)"
else
    log "⚠️  Node Exporter may not be running properly"
fi

if curl -s http://localhost:12345/-/healthy > /dev/null; then
    log "✅ Alloy is running (port 12345)"
else
    log "⚠️  Alloy may not be running properly"
fi

# Show final status
log "📊 Final service status:"
brew services list | grep -E '(alloy|node_exporter)' || true

log "✅ Official Grafana Cloud Alloy monitoring setup complete!"
log "📈 Metrics will be sent to: $GCLOUD_HOSTED_METRICS_URL"
log "📋 Logs will be sent to: $GCLOUD_HOSTED_LOGS_URL"
log "🏷️  Machine tagged as: $MACHINE_NAME ($MACHINE_LOCATION)"
log "🌐 Fleet Management: $GCLOUD_FM_URL"

log "💾 Configuration saved to: $HOMEBREW_PREFIX/etc/alloy/config.alloy"
log "🔧 To check Alloy status: brew services info alloy"
log "🔧 To view Alloy logs: tail -f $HOMEBREW_PREFIX/var/log/alloy.log"
log "📊 View your metrics in Grafana Cloud: https://<your-org>.grafana.net" 