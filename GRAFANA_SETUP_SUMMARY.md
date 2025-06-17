# Grafana Monitoring Setup - Quick Start

## 🎯 **What You Need to Do**

You now have everything needed to add Grafana monitoring to your Buildkite pipeline. Here's exactly what to do:

### 1. **Set Buildkite Secrets** (5 minutes)

Go to your Buildkite pipeline settings and add these 4 environment variables as **secrets**:

| Variable | Value | Where to Find |
|----------|-------|---------------|
| `GRAFANA_CLOUD_USERNAME` | Your stack ID | Grafana Cloud account |
| `GRAFANA_CLOUD_API_KEY` | `glc_xxxxx...` | Create in Access Policies |
| `GRAFANA_PROMETHEUS_URL` | `https://prometheus-prod-XX-XXX.grafana.net/api/prom/push` | Data Sources → Prometheus |
| `GRAFANA_LOKI_URL` | `https://logs-prod-XXX.grafana.net/loki/api/v1/push` | Data Sources → Loki |

### 2. **Choose Integration Method**

**Option A: Automatic (Recommended)**
- The monitoring will be added automatically before VM operations
- No pipeline changes needed
- Just make sure the secrets are set

**Option B: Manual Pipeline Integration**
Add this to your CI pipeline (in `.buildkite/ci.mjs`):

```javascript
// Add before macOS VM builds
if (macOSReleases.length > 0) {
  // Add monitoring setup step
  steps.push({
    key: "setup-grafana-monitoring",
    label: "📊 Setup Grafana Monitoring", 
    agents: { queue: "darwin" },
    command: "./scripts/setup-grafana-monitoring.sh",
    env: {
      GRAFANA_CLOUD_USERNAME: "${GRAFANA_CLOUD_USERNAME}",
      GRAFANA_CLOUD_API_KEY: "${GRAFANA_CLOUD_API_KEY}",
      GRAFANA_PROMETHEUS_URL: "${GRAFANA_PROMETHEUS_URL}",
      GRAFANA_LOKI_URL: "${GRAFANA_LOKI_URL}",
    },
    timeout_in_minutes: 10,
  });
  
  // Add VM builds with dependency
  steps.push({
    key: "build-macos-base-images",
    group: "🍎 macOS Base Images", 
    depends_on: ["setup-grafana-monitoring"],
    steps: macOSReleases.map(release => getMacOSVMBuildStep({ os: "darwin", release }, options))
  });
}
```

### 3. **Test the Setup** (2 minutes)

Before running a full build, test your configuration:

```bash
# Set your secrets locally for testing
export GRAFANA_CLOUD_USERNAME="your-stack-id"
export GRAFANA_CLOUD_API_KEY="glc_xxxxx..."
export GRAFANA_PROMETHEUS_URL="https://prometheus-prod-XX-XXX.grafana.net/api/prom/push"
export GRAFANA_LOKI_URL="https://logs-prod-XXX.grafana.net/loki/api/v1/push"

# Test the configuration
./scripts/test-grafana-config.sh
```

If all tests pass, you're ready!

### 4. **Run a Build**

Run any Buildkite build that uses macOS. The monitoring setup will:

1. ✅ Install Grafana Alloy + Node Exporter on the host
2. 📊 Start collecting system metrics + build process metrics  
3. 📋 Start collecting logs from Buildkite agents + builds
4. 🏷️ Tag everything with build context (machine, location, build ID)

### 5. **Verify It's Working**

After the build:

**Check Grafana Cloud:**
1. Go to your Grafana Cloud instance
2. Navigate to **Explore** → **Prometheus**
3. Query: `up{service_type="buildkite-agent"}`
4. You should see your CI machines

**Check Logs:**
1. Navigate to **Explore** → **Loki**
2. Query: `{machine_name=~".*"}`
3. You should see logs from your builds

## 📊 **What You Get**

Once running, you'll have:

- **Real-time metrics**: CPU, memory, disk, network usage during builds
- **Build process tracking**: bun, cmake, ninja, clang, zig, tart processes
- **Centralized logs**: All CI logs in one place with build context
- **Machine labeling**: Every metric tagged with machine info + build details
- **Zero maintenance**: Services auto-restart, configs persist

## 📁 **Files Created**

I've created these files for you:

```
client-oven-sh-bun/
├── scripts/
│   ├── setup-grafana-monitoring.sh     # Main setup script
│   └── test-grafana-config.sh           # Test configuration
├── .buildkite/steps/
│   └── setup-grafana-monitoring.yml     # Pipeline step template
└── docs/
    └── grafana-buildkite-integration.md # Complete documentation
```

## 🚨 **If Something Goes Wrong**

1. **Check secrets**: Make sure all 4 are set in Buildkite
2. **Test config**: Run `./scripts/test-grafana-config.sh`
3. **Check logs**: SSH to CI host and run `brew services | grep -E "(alloy|node_exporter)"`
4. **Read docs**: See `docs/grafana-buildkite-integration.md` for detailed troubleshooting

## 🎉 **Next Steps After Setup**

1. Import the Grafana dashboards from `@grafana-cloud-setup.md`
2. Set up alerts for machine down, high CPU, low disk space
3. Monitor build performance trends over time
4. Tune log retention policies in Grafana Cloud

---

**Ready to go?** Just set those 4 Buildkite secrets and run a build! 🚀 