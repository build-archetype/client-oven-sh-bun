# Agent VM Health Check System

This system enables dynamic agent management for macOS VM images, automatically building missing VMs and updating agent status based on VM availability for specific macOS versions.

## 🎯 How It Works

1. **Agents self-check** VM image availability for each macOS version (13, 14)
2. **Automatically build** missing VM images when detected
3. **Update version-specific meta-data** (`vm-ready-macos-13: true/false`, `vm-ready-macos-14: true/false`) 
4. **Jobs run normally** on available agents without VM dependencies
5. **Background VM management** ensures all agents eventually have required VMs

## 📋 Benefits

- **Automatic VM building** - missing VMs are built without manual intervention
- **Version-specific management** - each macOS version handled independently
- **No build dependencies** - regular builds run immediately on available agents
- **Efficient resource utilization** - VMs built in background while builds continue
- **Self-healing** - agents automatically recover from missing VMs
- **Parallel execution** - multiple agents can build different VMs simultaneously

## 🛠️ Health Check Behavior

The health check script now performs these actions:

### For Each macOS Version (13, 14):
1. **Check if VM exists locally**
2. **If missing**: Call `./scripts/build-macos-vm.sh --release=VERSION`
3. **If bootstrap mismatch**: Rebuild VM with correct version
4. **Update agent meta-data** with current status
5. **Continue to next version**

### Build Process:
- Downloads base macOS image if needed
- Runs bootstrap script to install dependencies
- Validates all required tools are present
- Optionally pushes to registry for sharing
- Updates agent meta-data to show ready status

## ⏱️ Timing Considerations

- **Health check runs every 5 minutes** via scheduled pipeline
- **VM builds can take 1-12 hours** depending on network/resources
- **Timeout set to 720 minutes (12 hours)** to accommodate builds
- **Regular builds continue** on other agents while VMs build in background

## 🎯 Agent Meta-data Structure

Each agent tracks separate meta-data for each macOS version:

### macOS 13:
- `vm-ready-macos-13`: `true` or `false`
- `vm-image-macos-13`: VM image name for macOS 13
- `vm-bootstrap-version-macos-13`: Bootstrap version for macOS 13
- `vm-status-reason-macos-13`: Status reason for macOS 13

### macOS 14:
- `vm-ready-macos-14`: `true` or `false`
- `vm-image-macos-14`: VM image name for macOS 14
- `vm-bootstrap-version-macos-14`: Bootstrap version for macOS 14
- `vm-status-reason-macos-14`: Status reason for macOS 14

## 🛠️ Setup Instructions

### 1. Agent Health Check Script

The health check script is provided at `scripts/agent-vm-health-check.sh`.

### 2. Deployment Options

#### **Option A: Dedicated Pipeline (Recommended)**

Create a separate health check pipeline that runs every 5 minutes:

```bash
# Set up the health check pipeline
./scripts/create-health-check-pipeline.sh

# This creates a Buildkite pipeline that:
# - Runs every 5 minutes automatically  
# - Targets all darwin agents simultaneously
# - Updates agent meta-data
# - Provides visibility in Buildkite UI
```

**Benefits:**
- ✅ Centralized management (no agent setup needed)
- ✅ Visible in Buildkite dashboard
- ✅ Easy to update/modify
- ✅ Better error handling and monitoring

#### **Option B: Cron Jobs (Manual)**

Add to each agent's cron if preferred:

```bash
# Run health check every 5 minutes
*/5 * * * * cd /path/to/repo && ./scripts/agent-vm-health-check.sh check
```

**Note:** Pipeline approach is recommended for easier management.

### 3. Agent Launch Configuration

Configure which macOS versions to check:

```bash
# Default: check both macOS 13 and 14
export MACOS_VERSIONS_TO_CHECK="13 14"
./scripts/agent-vm-health-check.sh check

# Agent that only supports macOS 14
export MACOS_VERSIONS_TO_CHECK="14"
./scripts/agent-vm-health-check.sh check

# Agent that only supports macOS 13
export MACOS_VERSIONS_TO_CHECK="13"
./scripts/agent-vm-health-check.sh check
```

### 4. Job Targeting

Jobs automatically target agents with the right version ready:

```javascript
// macOS 13 build jobs
agents: {
  queue: "darwin",
  "vm-ready-macos-13": "true"
}

// macOS 14 build jobs
agents: {
  queue: "darwin", 
  "vm-ready-macos-14": "true"
}

// VM build jobs target agents that DON'T have the version ready
// macOS 13 VM build
agents: {
  queue: "darwin",
  "vm-ready-macos-13": "false"
}

// macOS 14 VM build
agents: {
  queue: "darwin",
  "vm-ready-macos-14": "false"  
}
```

## 📊 Monitoring

### Check Agent Status

```bash
# Check current agent status for all versions
./scripts/agent-vm-health-check.sh status

# Force agent to ready state for all versions (testing)
./scripts/agent-vm-health-check.sh force-ready

# Force agent to not-ready state for all versions (testing)
./scripts/agent-vm-health-check.sh force-not-ready
```

### Build Progress Tracking

Agent meta-data shows real-time status:
- `vm-status-reason-macos-13`: "Building VM image" (during build)
- `vm-status-reason-macos-14`: "VM image built successfully" (after completion)
- `vm-last-check-macos-13`: Timestamp of last check/build

## 🚨 Troubleshooting

### Agent Building VMs for Too Long

```bash
# Check what's happening
./scripts/agent-vm-health-check.sh status

# Check specific version build progress
buildkite-agent meta-data get "vm-status-reason-macos-13"
buildkite-agent meta-data get "vm-last-check-macos-13"

# Manual intervention if needed
./scripts/build-macos-vm.sh --release=13 --force-refresh
```

### Build Failures

Common issues and solutions:
- **Network timeouts**: Retry automatically on next health check
- **Disk space**: Clean up old VMs automatically
- **Permissions**: Tart permission fixes built into scripts
- **Bootstrap failures**: Validates tools and retries if needed

## ⚙️ Configuration

### Environment Variables

- `MACOS_VERSIONS_TO_CHECK`: Space-separated macOS versions to check (default: "13 14")
- `REQUIRED_BOOTSTRAP_VERSION`: Bootstrap version required (default: 3.6)

### Health Check Frequency

Recommended: Every 5 minutes via cron

```bash
# Add to agent user's crontab
*/5 * * * * cd /path/to/buildkite/builds && ./scripts/agent-vm-health-check.sh check
```

## 🎯 Use Cases

### Dedicated Version Agents
Some agents might only support specific macOS versions:

```bash
# macOS 13 specialist agent
export MACOS_VERSIONS_TO_CHECK="13"

# macOS 14 specialist agent  
export MACOS_VERSIONS_TO_CHECK="14"

# Universal agent (default)
export MACOS_VERSIONS_TO_CHECK="13 14"
```

### Resource Optimization
- High-performance agents can handle both versions
- Lower-spec agents can focus on single versions
- Automatic load balancing based on VM availability

## 🔮 Future Enhancements

- **Queue-based routing**: Move agents between version-specific queues
- **Health check webhooks**: Notify when specific version becomes ready
- **Advanced VM caching**: Parallel VM builds for different versions
- **Version priority**: Prefer certain macOS versions on specific agents 