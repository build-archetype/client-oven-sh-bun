# Grafana Cloud Integration for Buildkite CI

This guide explains how to set up Grafana Cloud monitoring for your Bun CI host machines via Buildkite.

## Overview

The integration will:
- ✅ Set up Grafana Alloy (agent) and Node Exporter on CI host machines
- 📊 Collect system metrics (CPU, memory, disk, network) during builds
- 📋 Collect logs from Buildkite agents, builds, and Tart VMs
- 🏷️ Tag all data with build context (machine name, location, build ID, etc.)
- 🚀 Run automatically before VM operations to ensure monitoring is active

## 1. **Buildkite Secrets Setup**

In your Buildkite pipeline settings, add these environment variables as **secrets**:

### Required Secrets

| Secret Name | Description | Example Value |
|-------------|-------------|---------------|
| `GRAFANA_CLOUD_USERNAME` | Your Grafana Cloud stack ID | `your-stack-id` |
| `GRAFANA_CLOUD_API_KEY` | Grafana Cloud API key with metrics/logs write permissions | `glc_xxxxx...` |
| `GRAFANA_PROMETHEUS_URL` | Your Prometheus push endpoint | `https://prometheus-prod-XX-XXX.grafana.net/api/prom/push` |
| `GRAFANA_LOKI_URL` | Your Loki push endpoint | `https://logs-prod-XXX.grafana.net/loki/api/v1/push` |

### How to Get These Values

1. Go to your [Grafana Cloud](https://grafana.com) instance
2. Navigate to **My Account** → **Access Policies** → **Create Access Policy**
3. Create policy with scopes:
   - `metrics:write` (for Prometheus)
   - `logs:write` (for Loki)
4. Generate an **Access Policy Token** (this becomes your `GRAFANA_CLOUD_API_KEY`)
5. Find your endpoints in **Connections** → **Data Sources**:
   - Prometheus: Copy the "Remote Write" URL
   - Loki: Copy the push URL

### Setting Secrets in Buildkite

1. Go to your pipeline in Buildkite
2. Click **Settings** → **Environment Variables**
3. Add each secret with **"Prevent environment variable leaking"** enabled
4. Click **Save**

## 2. **Pipeline Integration**

### Option A: Automatic Integration (Recommended)

The monitoring setup will be automatically integrated into your CI pipeline. The script will:

1. Run before any macOS VM operations
2. Install Grafana Alloy and Node Exporter if not present
3. Configure monitoring with proper labels and endpoints
4. Start services and verify they're running

### Option B: Manual Integration

If you want more control, you can manually add the monitoring step to your pipeline.

**Method 1: Using the provided step file**

```bash
# Copy the step configuration to your pipeline
cat .buildkite/steps/setup-grafana-monitoring.yml >> .buildkite/pipeline.yml
```

**Method 2: Adding to ci.mjs (for dynamic pipelines)**

Add this step to your pipeline generation:

```javascript
// Add this function to ci.mjs
function getGrafanaMonitoringStep() {
  return {
    key: "setup-grafana-monitoring",
    label: "📊 Setup Grafana Monitoring",
    agents: {
      queue: "darwin",
    },
    command: "./scripts/setup-grafana-monitoring.sh",
    env: {
      GRAFANA_CLOUD_USERNAME: "${GRAFANA_CLOUD_USERNAME}",
      GRAFANA_CLOUD_API_KEY: "${GRAFANA_CLOUD_API_KEY}", 
      GRAFANA_PROMETHEUS_URL: "${GRAFANA_PROMETHEUS_URL}",
      GRAFANA_LOKI_URL: "${GRAFANA_LOKI_URL}",
    },
    timeout_in_minutes: 10,
    retry: {
      automatic: [
        { exit_status: 1, limit: 2 }
      ]
    }
  };
}

// Add to your pipeline steps before VM operations
if (macOSReleases.length > 0) {
  // Add monitoring setup first
  steps.push(getGrafanaMonitoringStep());
  
  // Then add VM builds with dependency
  steps.push({
    key: "build-macos-base-images", 
    group: "🍎 macOS Base Images",
    depends_on: ["setup-grafana-monitoring"],
    steps: macOSReleases.map(release => getMacOSVMBuildStep({ os: "darwin", release }, options))
  });
}
```

## 3. **What Gets Monitored**

### System Metrics (via Node Exporter)
- **CPU Usage**: Per-core and aggregate usage
- **Memory**: Usage, available, buffers, cache
- **Disk**: Usage, I/O rates, filesystem stats
- **Network**: Interface traffic, errors, packets
- **Processes**: Count, state, resource usage

### Build Tool Metrics (via Process Exporter)
- **bun**: Process metrics during builds
- **cmake/ninja**: Compilation process monitoring
- **clang**: Compiler process tracking
- **zig**: Zig compiler metrics
- **tart**: VM management process metrics
- **buildkite-agent**: Agent process monitoring

### Log Collection (via Alloy)
- **Buildkite Agent Logs**: Job execution, artifacts, etc.
- **Build Logs**: Compilation output, test results
- **System Logs**: macOS system events and errors
- **Tart VM Logs**: VM creation, networking, SSH issues

### Labels Applied to All Data
- `machine_name`: Unique identifier for the CI machine
- `machine_location`: Physical/logical location of the machine
- `machine_arch`: CPU architecture (arm64/x64)
- `build_id`: Buildkite build ID
- `pipeline_slug`: Buildkite pipeline name
- `service_type`: Always "buildkite-agent"

## 4. **Verification**

After running a build with monitoring enabled, verify it's working:

### Check Services on CI Host

```bash
# SSH to your CI host and check:
brew services | grep -E "(alloy|node_exporter)"

# Check if metrics are being collected
curl http://localhost:9100/metrics | head -20

# Check Alloy status
curl http://localhost:12345/-/healthy
```

### Check Grafana Cloud

1. Go to your Grafana Cloud instance
2. Navigate to **Explore**
3. Select your Prometheus data source
4. Query: `up{service_type="buildkite-agent"}`
5. You should see your CI machines appearing

### Check Logs in Grafana

1. Navigate to **Explore**
2. Select your Loki data source  
3. Query: `{machine_name="your-machine-name"}`
4. You should see logs from your CI builds

## 5. **Troubleshooting**

### Common Issues

#### **"Missing required environment variable" error**
- ✅ Verify all 4 Grafana secrets are set in Buildkite
- ✅ Check that secrets are not marked as "redacted" in build logs
- ✅ Ensure your Grafana Cloud API key has `metrics:write` and `logs:write` permissions

#### **Services not starting**
```bash
# Check Homebrew installation
brew doctor

# Check service logs
tail -f $(brew --prefix)/var/log/alloy.log
tail -f $(brew --prefix)/var/log/node_exporter.log

# Restart services
brew services restart grafana/grafana/alloy
brew services restart node_exporter
```

#### **No data appearing in Grafana**
- ✅ Verify network connectivity from CI host to Grafana Cloud
- ✅ Check API key permissions in Grafana Cloud
- ✅ Verify endpoints are correct (no trailing slashes)
- ✅ Check Alloy configuration: `cat ~/.grafana-monitoring/config.alloy`

#### **Authentication errors**
```bash
# Test manual push to verify credentials
curl -v -u "your-stack-id:your-api-key" \
  -H "Content-Type: application/x-protobuf" \
  -H "X-Prometheus-Remote-Write-Version: 0.1.0" \
  --data-binary @/dev/null \
  https://prometheus-prod-XX-XXX.grafana.net/api/prom/push
```

### Debug Commands

```bash
# Check what's running
ps aux | grep -E "(alloy|node_exporter)"

# Check network connections
netstat -an | grep -E "(9100|12345)"

# View Alloy config
cat ~/.grafana-monitoring/config.alloy

# Check Grafana Cloud connectivity
curl -I https://grafana.com

# View recent logs
tail -f /opt/homebrew/var/log/buildkite-agent.log
```

## 6. **Monitoring Dashboards**

Once data is flowing, import the pre-built dashboards from `@grafana-cloud-setup.md`:

1. **Bun CI Infrastructure Overview**: System health, resource usage
2. **Bun Build Performance**: Build duration, cache efficiency, resource usage during builds

## 7. **Security Notes**

- 🔐 **API Keys**: Stored securely in Buildkite secrets, never logged
- 🏠 **Local Storage**: Configuration stored in `~/.grafana-monitoring/`
- 🌐 **Network**: All communication over HTTPS to Grafana Cloud
- 🧹 **Cleanup**: Services will restart automatically if the host reboots

## 8. **Performance Impact**

The monitoring has minimal performance impact:
- **CPU**: <1% additional usage
- **Memory**: ~50MB for both services combined  
- **Network**: ~1KB/s metrics, ~10KB/s logs (typical)
- **Disk**: Rotating logs, ~100MB max storage

## 9. **Next Steps**

1. ✅ Set up Buildkite secrets (step 1)
2. ✅ Run a test build to verify monitoring works
3. 📊 Import the Grafana dashboards
4. 🚨 Set up alerts for critical metrics (machine down, high resource usage)
5. 📈 Monitor build performance over time
6. 🔧 Tune retention policies in Grafana Cloud as needed

## Support

For issues:
- 📖 Check this guide's troubleshooting section
- 🔍 Review `@grafana-cloud-setup.md` for detailed Grafana configuration
- 📋 Check build logs for specific error messages
- 🛠️ SSH to CI hosts to debug service issues directly 