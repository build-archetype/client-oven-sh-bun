# Agent VM Health Check System

This system enables dynamic agent tagging based on VM image availability for specific macOS versions, ensuring builds only run on hosts with the correct VM images ready.

## 🎯 How It Works

1. **Agents self-check** VM image availability for each macOS version (13, 14)
2. **Update version-specific meta-data** (`vm-ready-macos-13: true/false`, `vm-ready-macos-14: true/false`) 
3. **Jobs target agents with specific version ready** using meta-data selectors
4. **VM build jobs** target agents that DON'T have the specific version ready

## 📋 Benefits

- **Version-specific targeting** - macOS 13 builds only run on hosts with macOS 13 VMs
- **Efficient resource utilization** - agents can have some versions ready while building others
- **No wasted builds** on hosts without the required VM images
- **Automatic recovery** as agents become ready for each version
- **Graceful degradation** when specific VM versions are being built/updated

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

### Buildkite Dashboard

View agent meta-data in the Buildkite UI:
- Go to Agents page
- Click on individual agents
- View meta-data section
- Look for `vm-ready-macos-13` and `vm-ready-macos-14` fields

## 🔄 Automatic Recovery Flow

### Example Scenario:
1. **Agent starts**: No VM images → `vm-ready-macos-13: false`, `vm-ready-macos-14: false`
2. **macOS 14 VM build job**: Runs on this agent → creates macOS 14 image → sets `vm-ready-macos-14: true`
3. **macOS 14 builds**: Now target this agent
4. **macOS 13 VM build job**: Still runs on this agent → creates macOS 13 image → sets `vm-ready-macos-13: true`
5. **All builds**: Now target this agent for appropriate versions

### Mixed States:
An agent can have:
- `vm-ready-macos-13: true`, `vm-ready-macos-14: false` → Available for macOS 13 builds only
- `vm-ready-macos-13: false`, `vm-ready-macos-14: true` → Available for macOS 14 builds only
- `vm-ready-macos-13: true`, `vm-ready-macos-14: true` → Available for all builds

## 🚨 Troubleshooting

### Agent Stuck in Not-Ready State for Specific Version

```bash
# Check what's wrong
./scripts/agent-vm-health-check.sh status

# Check specific version details
buildkite-agent meta-data get "vm-status-reason-macos-13"
buildkite-agent meta-data get "vm-status-reason-macos-14"

# Common issues:
# - VM image missing for specific version
# - Bootstrap version mismatch for specific version
# - Tart permissions (affects all versions)
```

### Force Version-Specific Recovery

```bash
# Force ready state for all versions
./scripts/agent-vm-health-check.sh force-ready

# Or trigger VM build manually for specific version
./scripts/build-macos-vm.sh --release=13  # For macOS 13
./scripts/build-macos-vm.sh --release=14  # For macOS 14
```

### No Agents Available for Specific Version

If no agents show `vm-ready-macos-13: true`:

1. Check if macOS 13 VM build jobs are running/queued
2. Manually trigger macOS 13 VM build: `./scripts/build-macos-vm.sh --release=13`
3. Check agent logs for health check errors
4. Verify tart/VM functionality on agents

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