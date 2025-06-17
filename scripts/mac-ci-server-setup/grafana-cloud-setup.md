# Grafana Cloud Setup for Bun Mac CI Monitoring

This guide helps you set up comprehensive monitoring for your Bun Mac CI servers using Grafana Cloud. You can set this up either as part of the main setup script or separately.

## 🚀 **Quick Start - Integrated Setup**

The easiest way is to enable monitoring during the main setup process:

```bash
# Run the main setup script with monitoring enabled
MONITORING_ENABLED=true MONITORING_TYPE="grafana-cloud" ./setup-mac-server.sh
```

During setup, you'll be prompted for:

- Grafana Cloud organization ID
- Grafana Cloud API key
- Prometheus endpoint URL
- Loki endpoint URL

## 🔧 **Separate Setup**

If you want to add monitoring to an existing CI setup, follow these steps:

### 1. **Get Grafana Cloud Credentials**

1. Sign up at [grafana.com](https://grafana.com/auth/sign-up/create-user)
2. Create a new stack or use existing
3. Go to **Connections** → **Add new connection** → **Hosted Prometheus metrics**
4. Follow the setup wizard to get:
   - **Organization ID** (your user ID number)
   - **API Key** (starts with `glc_`)
   - **Prometheus URL** (e.g., `https://prometheus-prod-13-prod-us-east-0.grafana.net/api/prom/push`)
   - **Loki URL** (e.g., `https://logs-prod-008-prod-us-east-0.grafana.net/loki/api/v1/push`)

### 2. **Configure Environment Variables**

Create a configuration file:

```bash
# Copy the template
cp grafana-env.template grafana-env.sh

# Edit with your actual values
nano grafana-env.sh
```

Set these values in `grafana-env.sh`:

```bash
export GCLOUD_HOSTED_METRICS_ID="your-organization-id"
export GCLOUD_RW_API_KEY="your-grafana-cloud-api-key"
export GCLOUD_HOSTED_METRICS_URL="https://prometheus-prod-XX-prod-us-east-0.grafana.net/api/prom/push"
export GCLOUD_HOSTED_LOGS_URL="https://logs-prod-XXX-prod-us-east-0.grafana.net/loki/api/v1/push"
```

### 3. **Install Monitoring Tools**

```bash
# Source your configuration
source grafana-env.sh

# Install required tools
brew tap grafana/grafana
brew install grafana/grafana/alloy
brew install prometheus-node-exporter

# Start services
brew services start prometheus-node-exporter
brew services start alloy
```

### 4. **Configure Alloy**

The setup script automatically creates an Alloy configuration. For manual setup, create `~/.alloy/config.alloy` with the appropriate configuration (see the setup script for the full template).

## 🛡️ **macOS Permissions Requirements**

### **Full Disk Access for Terminal**

The setup script needs to enable SSH and configure system settings. macOS requires Full Disk Access for these operations:

1. **Open System Settings** → **Privacy & Security** → **Full Disk Access**
2. **Click the + button** to add applications
3. **Add your Terminal application**:
   - **Terminal.app** (built-in terminal)
   - **iTerm2** (if you use iTerm)
   - **VS Code Terminal** (if running from VS Code)
4. **Quit and reopen** your terminal application
5. **Re-run the setup script**

### **Full Disk Access for Buildkite Agent (if needed)**

If you encounter permission issues with the Buildkite agent accessing certain directories:

1. **System Settings** → **Privacy & Security** → **Full Disk Access**
2. **Add Buildkite Agent**:
   - Navigate to `/opt/homebrew/bin/buildkite-agent`
   - Or `/usr/local/bin/buildkite-agent` (Intel Macs)
3. **Restart the Buildkite agent service**:
   ```bash
   brew services restart buildkite-agent
   ```

### **Alternative SSH Setup (if Full Disk Access not available)**

If you can't grant Full Disk Access, you can enable SSH manually:

1. **System Settings** → **General** → **Sharing**
2. **Turn on "Remote Login"**
3. **Add users who can connect**: Select your CI user (`mac-ci`)

## 📊 **Environment Variables Reference**

The monitoring setup uses these environment variables:

```bash
# Required - Grafana Cloud credentials
export GCLOUD_HOSTED_METRICS_ID="1234567"              # Your organization ID
export GCLOUD_RW_API_KEY="glc_xxxxx..."                # Your API key

# Required - Grafana Cloud endpoints
export GCLOUD_HOSTED_METRICS_URL="https://prometheus-prod-XX-prod-us-east-0.grafana.net/api/prom/push"
export GCLOUD_HOSTED_LOGS_URL="https://logs-prod-XXX-prod-us-east-0.grafana.net/loki/api/v1/push"

# Optional - Additional settings
export GCLOUD_REGION="prod-us-east-0"                  # Auto-detected from API key
export GCLOUD_SCRAPE_INTERVAL="60s"                    # Metrics collection frequency
export GCLOUD_INSTANCE_LABELS="environment=ci,service=buildkite"  # Additional labels
```

## 🔍 **Verification**

After setup, verify monitoring is working:

```bash
# Check services are running
brew services list | grep -E "(alloy|node-exporter)"

# Check metrics endpoint
curl http://localhost:9100/metrics

# Check Alloy status
curl http://localhost:12345

# View Alloy logs
tail -f /opt/homebrew/var/log/alloy.log
```

You should see in the logs:

```
level=info msg="Samples sent" count=684
level=info msg="Remote write completed" status=200
```

## 📈 **Using with setup-mac-server.sh**

The main setup script supports monitoring through environment variables:

```bash
# Option 1: Set all variables upfront
export MONITORING_ENABLED=true
export MONITORING_TYPE="grafana-cloud"
export GCLOUD_HOSTED_METRICS_ID="your-org-id"
export GCLOUD_RW_API_KEY="your-api-key"
export GCLOUD_HOSTED_METRICS_URL="your-prometheus-url"
export GCLOUD_HOSTED_LOGS_URL="your-loki-url"
./setup-mac-server.sh

# Option 2: Enable during interactive setup
./setup-mac-server.sh
# Choose option 1 when prompted for monitoring
# Enter credentials when prompted
```

The script will:

- ✅ Install monitoring tools (Alloy, Node Exporter)
- ✅ Configure Alloy with your Grafana Cloud credentials
- ✅ Start monitoring services automatically
- ✅ Store credentials securely in macOS keychain
- ✅ Set up automatic startup on boot

## 🆘 **Troubleshooting**

### **Common Issues**

#### **Permission Denied Errors**

```bash
# Grant Full Disk Access to Terminal (see above)
# Or manually enable SSH in System Settings
```

#### **Services Not Starting**

```bash
# Check Homebrew services
brew services list

# Restart if needed
brew services restart alloy
brew services restart prometheus-node-exporter
```

#### **No Metrics in Grafana Cloud**

```bash
# Check Alloy configuration
cat ~/.alloy/config.alloy

# Test credentials
curl -u "$GCLOUD_HOSTED_METRICS_ID:$GCLOUD_RW_API_KEY" "$GCLOUD_HOSTED_METRICS_URL"

# Check for authentication errors in logs
tail -f /opt/homebrew/var/log/alloy.log | grep -i "error\|auth"
```

#### **Wrong Endpoints**

Make sure your endpoints match your region:

- US East: `prometheus-prod-XX-prod-us-east-0.grafana.net`
- US Central: `prometheus-prod-XX-prod-us-central-0.grafana.net`
- EU West: `prometheus-prod-XX-prod-eu-west-0.grafana.net`

## 📚 **Next Steps**

Once monitoring is set up:

1. **Import dashboards** - Use the dashboard JSON in this document
2. **Set up alerts** - Configure notifications for critical metrics
3. **Create custom views** - Build dashboards for your specific needs
4. **Monitor build performance** - Track build times and success rates

## 📊 **Dashboard Templates**

### **Dashboard 1: Bun CI Infrastructure Overview**

Import this JSON into Grafana Cloud:

```json
{
  "dashboard": {
    "id": null,
    "title": "Bun CI Infrastructure Overview",
    "tags": ["bun", "ci", "infrastructure"],
    "timezone": "browser",
    "panels": [
      {
        "id": 1,
        "title": "Machine Status",
        "type": "stat",
        "targets": [
          {
            "expr": "up{service_type=\"buildkite-agent\"}",
            "legendFormat": "{{machine_name}} ({{machine_location}})"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": { "mode": "thresholds" },
            "thresholds": {
              "steps": [
                { "color": "red", "value": 0 },
                { "color": "green", "value": 1 }
              ]
            }
          }
        }
      },
      {
        "id": 2,
        "title": "CPU Usage by Machine",
        "type": "timeseries",
        "targets": [
          {
            "expr": "100 - (avg by(machine_name) (irate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
            "legendFormat": "{{machine_name}}"
          }
        ]
      },
      {
        "id": 3,
        "title": "Memory Usage by Machine",
        "type": "timeseries",
        "targets": [
          {
            "expr": "100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))",
            "legendFormat": "{{machine_name}}"
          }
        ]
      },
      {
        "id": 4,
        "title": "Disk Usage by Machine",
        "type": "timeseries",
        "targets": [
          {
            "expr": "100 * (1 - (node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay\"}))",
            "legendFormat": "{{machine_name}} - {{mountpoint}}"
          }
        ]
      },
      {
        "id": 5,
        "title": "Network I/O by Machine",
        "type": "timeseries",
        "targets": [
          {
            "expr": "irate(node_network_receive_bytes_total{device!~\"lo|veth.*|docker.*|br-.*\"}[5m])",
            "legendFormat": "{{machine_name}} - {{device}} RX"
          },
          {
            "expr": "irate(node_network_transmit_bytes_total{device!~\"lo|veth.*|docker.*|br-.*\"}[5m])",
            "legendFormat": "{{machine_name}} - {{device}} TX"
          }
        ]
      },
      {
        "id": 6,
        "title": "Active Buildkite Jobs",
        "type": "stat",
        "targets": [
          {
            "expr": "count by(machine_name) (node_processes_state{state=\"R\", comm=\"buildkite-agent\"})",
            "legendFormat": "{{machine_name}}"
          }
        ]
      }
    ],
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "refresh": "30s"
  }
}
```

### **Log Queries**

Useful LogQL queries for troubleshooting:

```logql
# All logs from a specific machine
{machine_name="your-machine-name"}

# Buildkite agent logs only
{log_type="buildkite"}

# Build failure logs
{log_type="build"} |= "error" or "failed" or "ERROR"

# System errors
{log_type="system"} |= "error" or "ERROR"

# Memory pressure warnings
{log_type="system"} |= "memory pressure" or "low memory"
```

## 🔐 **Security Best Practices**

1. **Rotate API Keys**: Set up calendar reminders for quarterly rotation
2. **Use Least Privilege**: Only grant necessary scopes (`metrics:write`, `logs:write`)
3. **Monitor Access**: Check Grafana audit logs regularly
4. **Secure Storage**: Credentials stored in macOS keychain, not plain text
5. **Network Security**: Use VPN for remote monitoring access

## 📚 **Additional Resources**

- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/)
- [Grafana Cloud Free Tier Limits](https://grafana.com/pricing/)
- [LogQL Query Language](https://grafana.com/docs/loki/latest/logql/)
- [PromQL Query Language](https://prometheus.io/docs/prometheus/latest/querying/basics/)

## 🎯 **Next Steps**

1. **Import the dashboards** above into your Grafana Cloud instance
2. **Set up alerts** for critical metrics
3. **Configure notification channels** (Slack, PagerDuty, etc.)
4. **Create custom dashboards** for your specific needs
5. **Set up log parsing** for structured log analysis
