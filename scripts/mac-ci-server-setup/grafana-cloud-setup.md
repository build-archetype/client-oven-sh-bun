# Grafana Cloud Setup for Bun Mac CI Monitoring

This guide helps you set up comprehensive monitoring for your Bun Mac CI servers using Grafana Cloud.

## 🚀 **Quick Start**

### 1. **Get Grafana Cloud Credentials**

1. Sign up at [grafana.com](https://grafana.com/auth/sign-up/create-user)
2. Create a new stack or use existing
3. Go to **My Account** → **Access Policies** → **Create Access Policy**
4. Create policy with scopes:
   - `metrics:write` (for Prometheus)
   - `logs:write` (for Loki)
   - `stacks:read` (optional, for stack info)

5. Generate an **Access Policy Token**
6. Note your endpoints:
   - **Prometheus**: `https://prometheus-prod-XX-XXX.grafana.net/api/prom/push`
   - **Loki**: `https://logs-prod-XXX.grafana.net/loki/api/v1/push`

### 2. **Run Setup Script**

When running the `setup-mac-server.sh` script:

```bash
# Enable monitoring
Choose monitoring option: 1 (Grafana Cloud)

# Enter your credentials:
Grafana Cloud username: your-stack-id
Grafana Cloud API key: glc_xxxxx...
Prometheus URL: https://prometheus-prod-XX-XXX.grafana.net/api/prom/push  
Loki URL: https://logs-prod-XXX.grafana.net/loki/api/v1/push
```

## 📊 **Dashboards Configuration**

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
            "color": {"mode": "thresholds"},
            "thresholds": {
              "steps": [
                {"color": "red", "value": 0},
                {"color": "green", "value": 1}
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

### **Dashboard 2: Bun Build Performance**

```json
{
  "dashboard": {
    "id": null,
    "title": "Bun Build Performance",
    "tags": ["bun", "ci", "builds"],
    "panels": [
      {
        "id": 1,
        "title": "Build Duration Trends",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rate(node_processes_total[5m])",
            "legendFormat": "Process Rate - {{machine_name}}"
          }
        ]
      },
      {
        "id": 2,
        "title": "Compile Cache Hit Rate",
        "type": "stat",
        "description": "Monitor ccache effectiveness",
        "targets": [
          {
            "expr": "100 * rate(node_disk_reads_completed_total[5m]) / rate(node_disk_io_now[5m])",
            "legendFormat": "Cache Efficiency - {{machine_name}}"
          }
        ]
      },
      {
        "id": 3,
        "title": "Memory Usage During Builds",
        "type": "timeseries",
        "targets": [
          {
            "expr": "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes",
            "legendFormat": "Memory Used - {{machine_name}}"
          }
        ]
      },
      {
        "id": 4,
        "title": "Disk I/O During Builds",
        "type": "timeseries",
        "targets": [
          {
            "expr": "irate(node_disk_read_bytes_total[5m])",
            "legendFormat": "Disk Read - {{machine_name}}"
          },
          {
            "expr": "irate(node_disk_written_bytes_total[5m])",
            "legendFormat": "Disk Write - {{machine_name}}"
          }
        ]
      }
    ]
  }
}
```

## 🔍 **Log Queries**

### **Useful LogQL Queries**

```logql
# All logs from a specific machine
{machine_name="your-machine-name"}

# Buildkite agent logs only
{log_type="buildkite"}

# Build failure logs
{log_type="build"} |= "error" or "failed" or "ERROR"

# Tart VM logs
{log_type="tart"}

# System errors
{log_type="system"} |= "error" or "ERROR"

# Logs from specific build
{log_type="build", build_id="your-build-id"}

# Memory pressure warnings
{log_type="system"} |= "memory pressure" or "low memory"

# Network connectivity issues
{log_type="system"} |= "network" and ("unreachable" or "timeout")
```

## 🚨 **Alerting Rules**

### **Create These Alerts in Grafana Cloud**

#### **1. Machine Down Alert**
```yaml
- alert: MacCIServerDown
  expr: up{service_type="buildkite-agent"} == 0
  for: 2m
  labels:
    severity: critical
  annotations:
    summary: "Mac CI server {{$labels.machine_name}} is down"
    description: "Machine {{$labels.machine_name}} in {{$labels.machine_location}} has been down for more than 2 minutes"
```

#### **2. High CPU Usage**
```yaml
- alert: HighCPUUsage
  expr: 100 - (avg by(machine_name) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "High CPU usage on {{$labels.machine_name}}"
    description: "CPU usage has been above 80% for more than 5 minutes"
```

#### **3. Low Disk Space**
```yaml
- alert: LowDiskSpace  
  expr: 100 * (1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"})) > 85
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Low disk space on {{$labels.machine_name}}"
    description: "Disk usage is above 85% on {{$labels.mountpoint}}"
```

#### **4. Build Failures**
```yaml
- alert: BuildFailures
  expr: increase(rate({log_type="build"} |= "error" or "failed")[5m]) > 0.5
  for: 1m
  labels:
    severity: warning
  annotations:
    summary: "High build failure rate on {{$labels.machine_name}}"
    description: "Build failure rate has increased significantly"
```

## 🔧 **Advanced Configuration**

### **Custom Metrics Collection**

Add this to your Alloy config for additional Bun-specific metrics:

```alloy
// Custom Bun build metrics
prometheus.exporter.process "bun_processes" {
  matcher {
    name = "bun"
  }
  matcher {
    name = "node"
  }
  matcher {
    name = "tart"
  }
}

// File descriptor usage
prometheus.exporter.unix "extended_node" {
  include_exporter_metrics = true
  enable_collectors = ["processes", "systemd", "textfile"]
}
```

### **Log Retention Policies**

Configure different retention for different log types:

```yaml
# In Grafana Cloud UI
Log Retention:
  - build logs: 30 days (high volume)
  - system logs: 90 days (important for debugging)
  - buildkite logs: 60 days (audit trail)
  - tart logs: 14 days (usually not needed long-term)
```

## 📈 **Performance Tuning**

### **Optimize Data Collection**

```alloy
// Reduce scrape frequency for less critical metrics
prometheus.scrape "low_priority_metrics" {
  scrape_interval = "60s"  // instead of 15s
  scrape_timeout  = "30s"
}

// Use relabeling to drop unnecessary metrics
prometheus.relabel "drop_unused" {
  rule {
    source_labels = ["__name__"]
    regex = "node_scrape_collector_.*|node_textfile_scrape_error"
    action = "drop"
  }
}
```

## 🔐 **Security Best Practices**

1. **Rotate API Keys Regularly**: Set calendar reminders
2. **Use Least Privilege**: Only grant necessary scopes
3. **Monitor Access Logs**: Check for unauthorized access
4. **Secure Storage**: Credentials are stored in macOS keychain
5. **Network Security**: Use VPN for external access

## 🆘 **Troubleshooting**

### **Common Issues**

#### **Alloy Not Starting**
```bash
# Check logs
tail -f /opt/homebrew/var/log/alloy.log

# Verify config syntax
alloy fmt --write ~/.alloy/config.alloy

# Test connectivity
curl -v https://prometheus-prod-XX-XXX.grafana.net/api/prom/push
```

#### **Missing Metrics**
```bash
# Check if Node Exporter is running
brew services list | grep node-exporter

# Test metrics endpoint
curl http://localhost:9100/metrics
```

#### **No Logs Appearing**
```bash
# Check file permissions
ls -la /opt/homebrew/var/log/buildkite-agent.log

# Verify log paths in config
grep -A 10 "loki.source.file" ~/.alloy/config.alloy
```

#### **Authentication Errors**
```bash
# Test credentials
curl -u "user:api_key" https://prometheus-prod-XX-XXX.grafana.net/api/prom/push

# Regenerate API key if needed
```

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