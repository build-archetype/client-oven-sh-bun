# Agent VM Health Check System

This system enables dynamic agent tagging based on VM image availability, ensuring builds only run on hosts with the correct VM images ready.

## 🎯 How It Works

1. **Agents self-check** VM image availability periodically
2. **Update meta-data** (`vm-ready: true/false`) based on VM status  
3. **Jobs target only ready agents** using meta-data selectors
4. **VM build jobs** run on any agent to create missing images

## 📋 Benefits

- **No wasted builds** on hosts without VM images
- **Automatic recovery** as agents become ready  
- **Better resource utilization** across the CI cluster
- **Graceful degradation** when VMs are being built/updated

## 🛠️ Setup Instructions

### 1. Agent Health Check Script

The health check script is provided at `scripts/agent-vm-health-check.sh`.

### 2. Agent Configuration

Add this to your Buildkite agent's startup script or cron:

```bash
# Run health check every 5 minutes
*/5 * * * * cd /path/to/repo && ./scripts/agent-vm-health-check.sh check

# Or run on agent startup
./scripts/agent-vm-health-check.sh check
```

### 3. Agent Launch Configuration

Set macOS release per agent if needed:

```bash
# For macOS 13 agents
export MACOS_RELEASE=13
./scripts/agent-vm-health-check.sh check

# For macOS 14 agents  
export MACOS_RELEASE=14
./scripts/agent-vm-health-check.sh check
```

### 4. Job Targeting

Jobs automatically target ready agents:

```javascript
// Build/test jobs require vm-ready agents
agents: {
  queue: "darwin",
  "vm-ready": "true"
}

// VM build jobs can run on any agent
agents: {
  queue: "darwin"
  // No vm-ready requirement
}
```

## 📊 Monitoring

### Check Agent Status

```bash
# Check current agent status
./scripts/agent-vm-health-check.sh status

# Force agent to ready state (testing)
./scripts/agent-vm-health-check.sh force-ready

# Force agent to not-ready state (testing)
./scripts/agent-vm-health-check.sh force-not-ready
```

### Agent Meta-data

Each agent tracks these meta-data fields:

- `vm-ready`: `true` or `false`
- `vm-image`: Expected VM image name
- `vm-bootstrap-version`: Current bootstrap version
- `vm-bun-version`: Current Bun version  
- `vm-status-reason`: Reason for current status
- `vm-last-check`: Last health check timestamp

### Buildkite Dashboard

View agent meta-data in the Buildkite UI:
- Go to Agents page
- Click on individual agents
- View meta-data section

## 🔄 Automatic Recovery Flow

1. **Agent starts**: No VM images → `vm-ready: false`
2. **VM build job**: Runs on this agent (no vm-ready requirement)
3. **VM created**: Health check detects new image → `vm-ready: true` 
4. **Build jobs**: Now target this agent for actual builds

## 🚨 Troubleshooting

### Agent Stuck in Not-Ready State

```bash
# Check what's wrong
./scripts/agent-vm-health-check.sh status

# Common issues:
# - VM image missing (wait for VM build or run manually)
# - Bootstrap version mismatch (update REQUIRED_BOOTSTRAP_VERSION)
# - Tart permissions (check .tart directory ownership)
```

### Force Agent Recovery

```bash
# Force ready state for testing
./scripts/agent-vm-health-check.sh force-ready

# Or trigger VM build manually
./scripts/build-macos-vm.sh --release=14
```

### No Agents Available

If all agents show `vm-ready: false`:

1. Check if VM build jobs are running/queued
2. Manually trigger VM build: `./scripts/build-macos-vm.sh`
3. Check agent logs for health check errors
4. Verify tart/VM functionality on agents

## ⚙️ Configuration

### Environment Variables

- `REQUIRED_BOOTSTRAP_VERSION`: Bootstrap version required (default: 3.6)
- `MACOS_RELEASE`: macOS version for this agent (default: 14)  
- `BUN_VERSION`: Override Bun version detection

### Health Check Frequency

Recommended: Every 5 minutes via cron

```bash
# Add to agent user's crontab
*/5 * * * * cd /path/to/buildkite/builds && ./scripts/agent-vm-health-check.sh check
```

## 🔮 Future Enhancements

- **Queue-based routing**: Move agents between `darwin-ready`/`darwin-prep` queues
- **Health check webhooks**: Notify Buildkite when agent status changes
- **Advanced VM caching**: Support multiple VM versions per agent
- **Auto-cleanup**: Remove outdated VMs when bootstrap version changes 