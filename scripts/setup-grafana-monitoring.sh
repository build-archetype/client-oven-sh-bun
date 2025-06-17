#!/bin/bash
set -euo pipefail

# Setup Grafana monitoring on macOS CI hosts
# This script installs and configures Alloy (Grafana agent) and Node Exporter
# for monitoring CI build performance and system metrics

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "🔧 Setting up Grafana monitoring on CI host..."

# Validate required environment variables
REQUIRED_VARS=(
    "GRAFANA_CLOUD_USERNAME"
    "GRAFANA_CLOUD_API_KEY"
    "GRAFANA_PROMETHEUS_URL"
    "GRAFANA_LOKI_URL"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log "❌ Missing required environment variable: $var"
        log "   Please ensure Buildkite secrets are configured properly"
        exit 1
    fi
done

log "✅ All required Grafana credentials found"

# Detect machine info for labeling
MACHINE_UUID=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}' 2>/dev/null || echo "unknown")
MACHINE_ARCH=$(uname -m)
MACHINE_NAME="${BUILDKITE_AGENT_NAME:-$(hostname -s)}-${MACHINE_UUID:0:8}"
MACHINE_LOCATION="${BUILDKITE_AGENT_META_DATA_MACHINE_LOCATION:-unknown}"

log "Machine info:"
log "  Name: $MACHINE_NAME"
log "  Arch: $MACHINE_ARCH"
log "  Location: $MACHINE_LOCATION"
log "  Build ID: ${BUILDKITE_BUILD_ID:-unknown}"

# Install Homebrew packages if not already installed
install_if_missing() {
    local package="$1"
    if ! brew list "$package" &>/dev/null; then
        log "📦 Installing $package..."
        brew install "$package"
    else
        log "✅ $package already installed"
    fi
}

# Install required packages
log "📦 Installing monitoring tools..."
install_if_missing "grafana/grafana/alloy"
install_if_missing "node_exporter"

# Create config directory
CONFIG_DIR="$HOME/.grafana-monitoring"
mkdir -p "$CONFIG_DIR"

log "📝 Creating Alloy configuration..."

# Create Alloy configuration
cat > "$CONFIG_DIR/config.alloy" << EOF
// Grafana Alloy configuration for Bun CI monitoring
// Based on official Grafana macOS integration best practices
// Generated automatically by setup-grafana-monitoring.sh

// ===== SYSTEM METRICS COLLECTION (Official Pattern) =====

// Node Exporter for system metrics (official component name)
prometheus.exporter.unix "integrations_node_exporter" {
  include_exporter_metrics = true
  enable_collectors = [
    "cpu", "disk", "filesystem", "memory", "network", 
    "processes", "systemd", "textfile", "boottime", "loadavg"
  ]
}

// Discovery and relabeling (official pattern)
discovery.relabel "integrations_node_exporter" {
  targets = prometheus.exporter.unix.integrations_node_exporter.targets

  rule {
    target_label = "instance"
    replacement  = constants.hostname
  }

  rule {
    target_label = "job"
    replacement  = "integrations/macos-node"
  }
  
  // Add CI-specific labels
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

// Scrape metrics (official pattern)
prometheus.scrape "integrations_node_exporter" {
  targets    = discovery.relabel.integrations_node_exporter.output
  forward_to = [prometheus.relabel.integrations_node_exporter.receiver]
  job_name   = "integrations/node_exporter"
  scrape_interval = "15s"
  scrape_timeout  = "10s"
}

// Metric filtering for efficiency (official recommended metrics only)
prometheus.relabel "integrations_node_exporter" {
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]

  // Only keep essential metrics (reduces bandwidth and storage costs)
  rule {
    source_labels = ["__name__"]
    regex = "up|node_boot_time_seconds|node_cpu_seconds_total|node_disk_io_time_seconds_total|node_disk_read_bytes_total|node_disk_written_bytes_total|node_filesystem_avail_bytes|node_filesystem_files|node_filesystem_files_free|node_filesystem_readonly|node_filesystem_size_bytes|node_load1|node_load15|node_load5|node_memory_compressed_bytes|node_memory_internal_bytes|node_memory_purgeable_bytes|node_memory_swap_total_bytes|node_memory_swap_used_bytes|node_memory_total_bytes|node_memory_wired_bytes|node_network_receive_bytes_total|node_network_receive_drop_total|node_network_receive_errs_total|node_network_receive_packets_total|node_network_transmit_bytes_total|node_network_transmit_drop_total|node_network_transmit_errs_total|node_network_transmit_packets_total|node_os_info|node_textfile_scrape_error|node_uname_info|node_processes_state|node_processes_total"
    action = "keep"
  }
}

// ===== BUILD PROCESS MONITORING (Custom Addition) =====

// Process metrics specifically for build tools
prometheus.exporter.process "build_tools" {
  matcher {
    name = "bun"
  }
  matcher {
    name = "cmake"
  }
  matcher {
    name = "ninja" 
  }
  matcher {
    name = "clang"
  }
  matcher {
    name = "zig"
  }
  matcher {
    name = "tart"
  }
  matcher {
    name = "buildkite-agent"
  }
}

// Scrape build process metrics
prometheus.scrape "build_process_metrics" {
  targets = [
    {"__address__" = "localhost:9256", "job" = "build-processes"},
  ]
  forward_to = [prometheus.relabel.build_processes.receiver]
  scrape_interval = "15s"
  scrape_timeout = "10s"
}

// Add labels to build process metrics
prometheus.relabel "build_processes" {
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
  
  rule {
    target_label = "machine_name"
    replacement = "$MACHINE_NAME"
  }
  rule {
    target_label = "build_id"
    replacement = "${BUILDKITE_BUILD_ID:-unknown}"
  }
  rule {
    target_label = "service_type"
    replacement = "buildkite-agent"
  }
}

// Send metrics to Grafana Cloud
prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = "$GRAFANA_PROMETHEUS_URL"
    basic_auth {
      username = "$GRAFANA_CLOUD_USERNAME"
      password = "$GRAFANA_CLOUD_API_KEY"
    }
  }
}

// ===== LOG COLLECTION (Official Pattern + CI Enhancements) =====

// System logs with official multiline processing
local.file_match "logs_integrations_system" {
  path_targets = [{
    __address__ = "localhost",
    __path__    = "/var/log/*.log",
    instance    = constants.hostname,
    job         = "integrations/macos-node",
    log_type    = "system",
  }]
}

loki.process "logs_integrations_system" {
  forward_to = [loki.write.grafana_cloud.receiver]

  // Official multiline processing for macOS logs
  stage.multiline {
    firstline     = "^([\\w]{3} )?[\\w]{3} +[\\d]+ [\\d]+:[\\d]+:[\\d]+|[\\w]{4}-[\\w]{2}-[\\w]{2} [\\w]{2}:[\\w]{2}:[\\w]{2}(?:[+-][\\w]{2})?"
    max_lines     = 0
    max_wait_time = "10s"
  }

  // Official regex parsing for macOS system logs
  stage.regex {
    expression = "(?P<timestamp>([\\w]{3} )?[\\w]{3} +[\\d]+ [\\d]+:[\\d]+:[\\d]+|[\\w]{4}-[\\w]{2}-[\\w]{2} [\\w]{2}:[\\w]{2}:[\\w]{2}(?:[+-][\\w]{2})?) (?P<hostname>\\S+) (?P<sender>.+?)\\[(?P<pid>\\d+)\\]:? (?P<message>(?s:.*))$"
  }

  stage.labels {
    values = {
      hostname = null,
      pid      = null,
      sender   = null,
      machine_name = "$MACHINE_NAME",
      build_id = "${BUILDKITE_BUILD_ID:-unknown}",
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

loki.source.file "logs_integrations_system" {
  targets    = local.file_match.logs_integrations_system.targets
  forward_to = [loki.process.logs_integrations_system.receiver]
}

// Buildkite-specific logs (CI enhancement)
local.file_match "logs_buildkite" {
  path_targets = [
    {
      __address__ = "localhost",
      __path__    = "/opt/homebrew/var/log/buildkite-agent.log",
      log_type    = "buildkite",
      machine_name = "$MACHINE_NAME",
      build_id    = "${BUILDKITE_BUILD_ID:-unknown}",
    },
    {
      __address__ = "localhost", 
      __path__    = "/var/log/buildkite-agent.log",
      log_type    = "buildkite",
      machine_name = "$MACHINE_NAME",
      build_id    = "${BUILDKITE_BUILD_ID:-unknown}",
    }
  ]
}

loki.process "logs_buildkite" {
  forward_to = [loki.write.grafana_cloud.receiver]

  stage.labels {
    values = {
      machine_name = null,
      build_id = null,
      log_type = null,
    }
  }
}

loki.source.file "logs_buildkite" {
  targets    = local.file_match.logs_buildkite.targets
  forward_to = [loki.process.logs_buildkite.receiver]
}

// Build logs (CI enhancement)
local.file_match "logs_build" {
  path_targets = [
    {
      __address__ = "localhost",
      __path__    = "/tmp/bun-build-*.log",
      log_type    = "build",
      machine_name = "$MACHINE_NAME",
      build_id    = "${BUILDKITE_BUILD_ID:-unknown}",
    },
    {
      __address__ = "localhost",
      __path__    = "/tmp/cmake-*.log", 
      log_type    = "build",
      machine_name = "$MACHINE_NAME",
      build_id    = "${BUILDKITE_BUILD_ID:-unknown}",
    },
    {
      __address__ = "localhost",
      __path__    = "$HOME/builds/**/*.log",
      log_type    = "build", 
      machine_name = "$MACHINE_NAME",
      build_id    = "${BUILDKITE_BUILD_ID:-unknown}",
    }
  ]
}

loki.process "logs_build" {
  forward_to = [loki.write.grafana_cloud.receiver]

  stage.labels {
    values = {
      machine_name = null,
      build_id = null,
      log_type = null,
    }
  }
}

loki.source.file "logs_build" {
  targets    = local.file_match.logs_build.targets
  forward_to = [loki.process.logs_build.receiver]
}

// Send logs to Grafana Cloud
loki.write "grafana_cloud" {
  endpoint {
    url = "$GRAFANA_LOKI_URL"
    basic_auth {
      username = "$GRAFANA_CLOUD_USERNAME"
      password = "$GRAFANA_CLOUD_API_KEY"
    }
  }
}

EOF

log "✅ Alloy configuration created"

# Start services
log "🚀 Starting monitoring services..."

# Stop services if running
brew services stop grafana/grafana/alloy 2>/dev/null || true
brew services stop node_exporter 2>/dev/null || true

# Start Node Exporter
log "Starting Node Exporter..."
brew services start node_exporter

# Start Alloy with our config
log "Starting Alloy..."
brew services start grafana/grafana/alloy

# Configure Alloy to use our config file
log "Configuring Alloy..."
mkdir -p "$(brew --prefix)/etc/alloy"
cp "$CONFIG_DIR/config.alloy" "$(brew --prefix)/etc/alloy/config.alloy"

# Restart Alloy to pick up the config
brew services restart grafana/grafana/alloy

# Wait a moment for services to start
sleep 5

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
brew services | grep -E "(alloy|node_exporter)" || true

log "✅ Grafana monitoring setup complete!"
log "📈 Metrics will be sent to: $GRAFANA_PROMETHEUS_URL"
log "📋 Logs will be sent to: $GRAFANA_LOKI_URL"
log "🏷️  Machine tagged as: $MACHINE_NAME ($MACHINE_LOCATION)"

# Save the config for debugging
log "💾 Configuration saved to: $CONFIG_DIR/config.alloy"
log "🔧 To check Alloy status: brew services info grafana/grafana/alloy"
log "🔧 To view Alloy logs: tail -f \$(brew --prefix)/var/log/alloy.log" 