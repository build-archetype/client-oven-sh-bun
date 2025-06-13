# Self-hosted CI for Bun.sh builds (macOS Focus)

This CI system is designed for Bun.sh builds, with a focus on macOS (Apple Silicon and Intel) using Tart VMs for full isolation. It can be extended to Linux and Windows, but by default only macOS jobs are enabled.

## Smart Image Caching System

The CI system includes an intelligent VM image caching mechanism that optimizes build times while ensuring you always get the latest available image. This system is implemented in `.buildkite/scripts/ensure-bun-image.sh`.

### Caching Strategy (Remote-First Approach)

The caching system follows a simple and effective "remote-first" strategy:

1. **Always check remote registry first** - If an image exists in the registry, pull it (it might be newer than local)
2. **Fallback to local image** - Use local image if remote doesn't exist but local does
3. **Build new image** - If neither remote nor local exists, build from scratch
4. **Force refresh option** - `--force-refresh` flag bypasses local cache entirely

### Image Naming and Versioning

Images follow a consistent naming pattern:
- **Local name**: `bun-build-macos-{VERSION}` (e.g., `bun-build-macos-1.2.14`)
- **Registry URL**: `ghcr.io/{ORGANIZATION}/{REPOSITORY}/bun-build-macos:{VERSION}`
- **Latest tag**: `ghcr.io/{ORGANIZATION}/{REPOSITORY}/bun-build-macos:latest`

Version detection is automatic:
1. Extracts from `CMakeLists.txt` if available
2. Falls back to `package.json` version field
3. Uses git tags/commit as final fallback

### SSH-Based Automation

The image building process uses SSH automation to run bootstrap scripts inside VMs:

- **Base image**: Uses `ghcr.io/cirruslabs/macos-sequoia-base:latest` which has SSH enabled
- **Credentials**: Default `admin/admin` account for SSH access
- **Shared directory**: Mounts current workspace as `/Volumes/My Shared Files/workspace`
- **Bootstrap execution**: Runs `./scripts/bootstrap-macos.sh` via SSH inside the VM

### Build Process Flow

```bash
# 1. Check command line options
./ensure-bun-image.sh [--force-refresh]

# 2. Detect repository and version
REPOSITORY=$(git remote get-url origin | sed -E 's|.*/([^/]+)\.git$|\1|')
BUN_VERSION=$(grep -E "set\(Bun_VERSION" CMakeLists.txt | sed 's/.*"\(.*\)".*/\1/')

# 3. Image availability check
if [remote image exists]; then
    pull and clone to local name
elif [local image exists AND not force refresh]; then
    use existing local image
else
    build new image
fi

# 4. Build process (if needed)
- Clone base macOS image
- Start VM with shared workspace directory
- Wait for VM boot and SSH availability
- Run bootstrap script via SSH
- Gracefully shutdown VM
- Push to registry (if credentials available)
```

### Registry Integration

The system automatically pushes newly built images to GitHub Container Registry:

- **Authentication**: Uses credential files (`/tmp/github-token.txt`, `/tmp/github-username.txt`)
- **Push strategy**: Pushes both versioned tag and `:latest` tag
- **Sharing**: Other developers/CI instances can pull pre-built images

## Build Step Caching System

In addition to VM image caching, the CI system implements a sophisticated build step caching mechanism using Buildkite artifacts. This system dramatically reduces build times by caching compilation artifacts across builds.

### Cache Types

The system manages three types of build caches:

1. **ccache** - C/C++ compilation cache
   - Caches compiled object files
   - Uploaded by C++ build steps (`build-cpp`)
   - Significantly reduces WebKit and native module compilation times

2. **Zig Local Cache** - Zig compilation artifacts
   - Caches Zig compiled objects and incremental state
   - Uploaded by Zig build steps (`build-zig`)
   - Speeds up Bun's core Zig compilation

3. **Zig Global Cache** - Zig package and dependency cache
   - Caches downloaded packages and dependencies
   - Uploaded by Zig build steps (`build-zig`)
   - Eliminates redundant package downloads

### Cache Upload Strategy

**Step-Specific Uploads**: Each build step only uploads the caches it generates:

- **C++ Build Step** (`BUN_CPP_ONLY=ON`):
  - Uploads: `ccache-cache.tar.gz`
  - Reason: C++ compilation generates ccache artifacts

- **Zig Build Step** (default):
  - Uploads: `zig-local-cache.tar.gz`, `zig-global-cache.tar.gz`
  - Reason: Zig compilation generates Zig cache artifacts

- **Link Step** (`BUN_LINK_ONLY=ON`):
  - Uploads: None (no-op targets)
  - Reason: Linking doesn't generate new cache content

### Cache Restoration Strategy

**Intelligent Build Detection**: The system finds the last build that actually has cache artifacts:

```javascript
// Smart cache-aware build detection
async function getLastBuildWithCache(orgSlug, pipelineSlug, branch) {
  // 1. Find recent completed builds (state='passed')
  // 2. Check that cache steps actually completed successfully
  // 3. Verify cache artifacts exist in those steps
  // 4. Return first build with actual cache artifacts
}
```

**Fallback Strategy**:
1. **Current branch cache** - Try to restore from previous successful build on same branch
2. **Main branch cache** - Fallback to main branch if current branch has no cache
3. **No cache** - Clean build if no suitable cache found

### Cache Implementation Details

**Cache Directory Structure**:
```
${CACHE_PATH}/
├── ccache/           # C++ compilation cache
├── zig/
│   ├── local/        # Zig local artifacts
│   └── global/       # Zig packages/dependencies
└── bun/              # Bun package manager cache
```

**Upload Process** (CMake targets):
```cmake
# Created dynamically based on build step type
upload-ccache-cache         # C++ step only
upload-zig-local-cache      # Zig step only  
upload-zig-global-cache     # Zig step only
upload-all-caches          # Meta target for CI
```

**Restoration Process** (CMake configure):
```bash
# Downloads from detected successful build
buildkite-agent artifact download ccache-cache.tar.gz . --build ${DETECTED_BUILD_ID}
cmake -E tar xzf ccache-cache.tar.gz  # Extract to cache directory
```

### Cache Performance Benefits

**Typical Build Time Improvements**:
- **Cold build** (no cache): ~25 minutes
- **Warm build** (with cache): ~8 minutes  
- **Cache hit rate**: 85-95% for incremental changes
- **Storage overhead**: ~2-5GB per cache set

**Cache Effectiveness**:
- **C++ cache**: Most effective for WebKit compilation (largest time savings)
- **Zig cache**: Effective for Bun core changes
- **Combined**: Best results when both caches are available

### Configuration

**Cache Strategy** (environment variable):
- `CACHE_STRATEGY=read-write` (default) - Download and upload cache
- `CACHE_STRATEGY=read-only` - Only download cache  
- `CACHE_STRATEGY=write-only` - Only upload cache
- `CACHE_STRATEGY=disabled` - Disable caching entirely

**Cache Path** (automatic):
```bash
# Unique per branch and build type to avoid conflicts
CACHE_PATH="/path/to/cache/${REPO}-${BRANCH}/${OS}-${ARCH}-${BUILD_TYPE}"
```

### Debugging Cache Issues

**Cache Restoration Debug Output**:
```bash
-- Restoring Buildkite cache artifacts...
--   Attempting to download ccache-cache.tar.gz from build 01234567-abcd-...
--   ✅ Restored ccache-cache.tar.gz: 1,250 files
--   ✅ Restored zig-local-cache.tar.gz: 89 files
--   📭 No zig-global-cache.tar.gz found (normal for first builds)
```

**Cache Upload Debug Output**:
```bash
-- === CACHE UPLOAD DEBUG ===
-- BUN_CPP_ONLY: ON
-- C++ build step - will upload ccache
-- Created real ccache upload target
-- Created upload-all-caches meta target with dependencies: upload-ccache-cache
```

**Common Issues**:
1. **"No cache found"** - No previous successful builds with cache artifacts
2. **"Cache disabled"** - `BUILDKITE_CACHE=OFF` or `CACHE_STRATEGY=disabled`
3. **Authentication errors** - Missing buildkite-agent permissions
4. **Build detection errors** - Previous builds still running or failed

### Cache Maintenance

**Automatic Cleanup**: 
- Old cache artifacts are automatically cleaned by Buildkite (30-day retention)
- Local cache directories are cleaned between builds
- Failed builds don't upload cache (prevents corrupted cache)

**Manual Cache Management**:
```bash
# Force clean cache build
CACHE_STRATEGY=disabled cmake --build build --target bun

# Check cache contents
ls -la ${CACHE_PATH}/ccache
du -sh ${CACHE_PATH}/*

# Test cache upload manually  
cmake --build build --target upload-all-caches
```

### Usage Examples

```bash
# Normal usage - use cache if available
.buildkite/scripts/ensure-bun-image.sh

# Force rebuild - ignore local cache
.buildkite/scripts/ensure-bun-image.sh --force-refresh

# Check what image would be used
BUN_VERSION=$(get_bun_version)
tart list | grep "bun-build-macos-${BUN_VERSION}"
```

### Debugging and Troubleshooting

The script provides comprehensive debugging output:

```bash
# Shows user context, permissions, and directory states
[2024-01-15 10:30:15] === DEBUGGING INFO ===
[2024-01-15 10:30:15] Current user (whoami): buildkite-agent
[2024-01-15 10:30:15] USER: buildkite-agent
[2024-01-15 10:30:15] HOME: /var/lib/buildkite-agent
[2024-01-15 10:30:15] ======================

# Automatic permission fixing
[2024-01-15 10:30:16] Fixing Tart permissions...
[2024-01-15 10:30:16] Setting ownership to buildkite-agent:staff...

# Image availability checks
[2024-01-15 10:30:17] Checking registry for latest image...
[2024-01-15 10:30:18] ✅ Image found and pulled from registry
```

Common issues and solutions:

1. **Permission errors with Tart**:
   - Script automatically fixes `.tart` directory permissions
   - Ensures proper ownership for the current user

2. **SSH connection failures**:
   - Retries up to 30 times with 30-second intervals
   - Installs `sshpass` if not available

3. **VM boot issues**:
   - Waits 60 seconds for initial boot
   - Attempts IP detection up to 10 times

4. **Registry authentication**:
   - Requires GitHub token and username in credential files
   - Gracefully skips push if credentials unavailable

## Usage -- Quick Start

1. **Clone and run the setup script:**
   ```bash
   curl -O https://raw.githubusercontent.com/build-archetype/client-oven-sh-bun/feat/sam/on-prem-mac-ci/infrastructure/setup/setup-mac-server.sh
   chmod +x setup-mac-server.sh
   ./setup-mac-server.sh
   ```

2. **GitHub Token Setup:**
   - You must create a GitHub token (classic or fine-grained) with at least `repo:status` (for public repos) or additional permissions for private repos.
   - Add this token as a secret in your Buildkite pipeline settings (e.g., `GITHUB_TOKEN`).

3. **Manual Bootstrap Script Setup in Buildkite:**
   - In Buildkite, go to your pipeline settings.
   - Click "Pipeline Steps" and select "YAML Steps".
   - Paste the following as your initial step:
     ```yaml
     steps:
       - label: ":rocket: Bootstrap CI Pipeline"
         command: "node .buildkite/ci.mjs"
         agents:
           queue: "darwin"
     ```
   - This will generate and upload the full dynamic pipeline for your build.

4. **Agent Configuration:**
   - The setup script configures your agent with:
     ```
     tags="os=macos,arch=aarch64,queue=darwin"
     ```
   - All macOS build and test jobs will use the `darwin` queue. Make sure your agent is running and registered with this queue.

5. **Image Preparation (Automatic)**:
   - The CI pipeline automatically ensures the correct Bun build image is available
   - First build may take 15-20 minutes as it bootstraps the development environment
   - Subsequent builds use cached images and start much faster
   - Images are automatically shared via GitHub Container Registry

## Non-Interactive and Interactive Setup

The `setup-mac-server.sh` script can be run in two ways:

### 1. Non-Interactive (CI/Automation/Fast Setup)

You can provide all required variables as environment variables. If a variable is set in the environment, the script will use it and skip the prompt. This is ideal for automation or scripting:

```bash
BUILDKITE_AGENT_TOKEN=your-bk-token \
GITHUB_USERNAME=your-bot-username \
GITHUB_TOKEN=your-ghcr-token \
MACHINE_LOCATION=office-1 \
COMPUTER_NAME=ci-mac-mini \
BUILD_VLAN=10.0.1.0/24 \
MGMT_VLAN=10.0.2.0/24 \
STORAGE_VLAN=10.0.3.0/24 \
./setup-mac-server.sh
```

You can set as many or as few as you want; any not set will be prompted for interactively.

### 2. Interactive (Default)

If you simply run:

```bash
./setup-mac-server.sh
```

The script will prompt you for any required values that are not already set in the environment.

### Key Variables
- `BUILDKITE_AGENT_TOKEN` (required)
- `GITHUB_USERNAME` (required for ghcr.io login)
- `GITHUB_TOKEN` (required for ghcr.io login)
- `MACHINE_LOCATION` (optional, defaults to `office-1`)
- `COMPUTER_NAME` (optional, defaults to current hostname)
- `BUILD_VLAN`, `MGMT_VLAN`, `STORAGE_VLAN` (optional, have defaults)

This makes the script flexible for both manual and automated setups.

## Build Pipeline Overview

- **Supported Platforms:**
  - macOS (Apple Silicon/arm64 and Intel/x64) — enabled by default
  - Linux and Windows — present in config, but commented out (uncomment to enable)
- **VM Isolation:**
  - All macOS builds and tests run inside fresh Tart VMs for full isolation and reproducibility.
- **Dynamic Pipeline:**
  - The pipeline is generated by `.buildkite/ci.mjs` and uploaded by the bootstrap step.
  - Only macOS jobs will run unless you uncomment other platforms in the config.

## Pipeline Steps

1. **VM Preparation**
   - Cleans up old VMs and creates fresh ones for each job.
2. **Build Dependencies**
   - Uses smart caching for dependencies.
3. **Build Matrix**
   - Builds for each enabled macOS architecture (M1/M2/M3/Intel).
4. **Test Matrix**
   - Runs tests in parallel across architectures, each in a clean VM.
5. **Performance Analysis & Artifact Management**
   - Benchmarks, artifact caching, and cleanup.

## Agent Configuration

Agents are tagged as follows:
```yaml
tags: "os=macos,arch=aarch64,queue=darwin"
```
- Only one queue per agent is supported in Buildkite clusters.
- If you want to support both arm64 and x64, run separate agents with the appropriate `arch` tag.

## GitHub Token Setup

- **Create a GitHub token** (classic or fine-grained) with at least `repo:status` (public) or additional permissions for private repos.
- **Add the token as a secret** in your Buildkite pipeline settings (e.g., `GITHUB_TOKEN`).
- This is required for status updates and some pipeline steps.

## Manual Bootstrap Script Setup in Buildkite

1. Go to your pipeline settings in Buildkite.
2. Click "Pipeline Steps" and select "YAML Steps".
3. Paste the following as your initial step:
   ```yaml
   steps:
     - label: ":rocket: Bootstrap CI Pipeline"
       command: "node .buildkite/ci.mjs"
       agents:
         queue: "darwin"
   ```
4. Save and run the pipeline. This will generate and upload the full dynamic pipeline.

## Troubleshooting

- **Job stuck on "Waiting for agent":**
  - Make sure your agent is running and registered with `queue=darwin` and the correct `arch` tag.
  - Only one queue per agent is allowed in Buildkite clusters.
  - Check agent status with `buildkite-agent status`.
- **GitHub token errors:**
  - Ensure your token is set as a secret in Buildkite and has the required permissions.
- **To enable Linux/Windows jobs:**
  - Uncomment the relevant platforms in `.buildkite/ci.mjs` in the `buildPlatforms` and `testPlatforms` arrays.

## Maintenance and Updates

- To update or reconfigure, simply re-run `setup-mac-server.sh`.
- For diagnostics, use `health-check.sh`.
- For VM refresh, re-run the setup script or use Tart commands as needed.

## Support

For issues or questions:
- Email: sam@buildarchetype.dev
- Internal Slack: #ci-infrastructure
- Emergency: See on-call rotation in PagerDuty

## Network Configuration

### VLAN Setup
- Build VLAN: 10.0.1.0/24 (VM traffic)
- Management: 10.0.2.0/24 (monitoring, admin)
- Storage: 10.0.3.0/24 (NFS, caches)

### Required Firewall Rules
```
# External Access
ALLOW tcp/443 github.com          # Git operations
ALLOW tcp/443 api.buildkite.com   # CI coordination
ALLOW tcp/443 s3.amazonaws.com    # Artifact storage
ALLOW udp/51820 vpn-endpoint      # Remote access

# Internal Access (within VLAN)
ALLOW tcp/9090 prometheus         # Metrics
ALLOW tcp/3000 grafana           # Monitoring UI
ALLOW tcp/2049 nfs               # Build cache
```

## VM Management

### Configuration
Each host runs maximum 2 VMs with:
- 4 CPU cores per VM
- 8GB RAM per VM
- 50GB disk per VM
- Clean snapshot per build

### Common VM Commands
```bash
# List VMs
tart list

# Create new VM
tart create --from-ci-template my-build-vm

# Start VM
tart run my-build-vm

# Delete VM
tart delete my-build-vm

# Create snapshot
tart snapshot create my-build-vm base-state
```

## Security Setup

### Access Control
- SSH key-based authentication only
- MFA required for all admin access
- Just-in-Time (JIT) access for maintenance
- Full audit logging enabled

### Key Management
```bash
# Generate new SSH key
ssh-keygen -t ed25519 -C "ci-host-$(date +%Y%m)"

# Add to authorized keys
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys

# Rotate keys (monthly)
mv ~/.ssh/authorized_keys ~/.ssh/authorized_keys.old
# Add new keys before removing old ones
```

## Monitoring Setup

### Key Metrics
- Build duration and success rate
- Queue length and wait time
- VM resource usage (CPU, RAM, disk)
- Network throughput
- Cache hit rates

### Alert Thresholds
- CPU usage > 90% for 5 minutes
- Memory usage > 85% for 5 minutes
- Disk usage > 90%
- Build queue > 10 jobs
- Failed builds > 5 per hour

### Accessing Metrics
- Grafana: http://localhost:3000 (default admin/your-password)
- Prometheus: http://localhost:9090
- Node Exporter metrics: http://localhost:9100/metrics

## Post-Installation Setup

### 1. Accessing Services

#### Grafana Monitoring
- URL: http://localhost:3000 (or http://your-server-ip:3000)
- Default login: admin / (password you provided during setup)
- Default dashboards are automatically configured for:
  - Build metrics
  - System resources
  - Network status
  - Cache performance

#### Buildkite Integration
1. Your agent should automatically connect to Buildkite
2. Verify in Buildkite UI: Settings → Agents
3. Tag your agent in Buildkite for specific architectures:
   ```bash
   # Edit /etc/buildkite-agent/buildkite-agent.cfg
   tags="arch=arm64,os=macos,chip=m2"
   ```

#### Remote Access

The setup supports three VPN options:

1. **WireGuard (Default)**
   - Simple point-to-point VPN
   - Lightweight and fast
   - Built-in to modern operating systems
   - Configuration file provided at `/etc/wireguard/client.conf`
   ```bash
   # View WireGuard config
   sudo cat /etc/wireguard/wg0.conf
   # Check connection
   sudo wg show
   ```

2. **Tailscale**
   - Zero-trust mesh networking
   - Easy NAT traversal
   - Automatic key management
   - Optional SSO integration
   ```bash
   # Check Tailscale status
   tailscale status
   # Get connection details
   tailscale netcheck
   ```

3. **UniFi VPN**
   - Integrated with UniFi Dream Machine Pro
   - Managed through UniFi Controller
   - Better for teams already using UniFi infrastructure
   - Configuration stored in `/etc/openvpn/unifi.ovpn`
   ```bash
   # Check UniFi VPN status
   sudo openvpn --status
   # View connection log
   tail -f /var/log/openvpn.log
   ```

To connect:
```bash
# For WireGuard
# 1. Install WireGuard client for your OS
# 2. Copy the config: sudo cat /etc/wireguard/wg0.conf
# 3. Import into your WireGuard client

# For Tailscale
# 1. Install Tailscale client
# 2. Run: tailscale up
# 3. Follow browser authentication

# For UniFi VPN
# 1. Install OpenVPN client
# 2. Copy the config: sudo cat /etc/openvpn/unifi.ovpn
# 3. Import into your OpenVPN client
```

SSH Access:
```bash
# Your SSH key was automatically added during setup
ssh ci-admin@your-server-ip

# For additional users
sudo ci-admin add-user username
```

### 2. Verifying Setup

Check all services are running:
```bash
# Check service status
sudo ci-admin status

# View all running services
sudo ci-admin list-services

# Check connectivity
sudo ci-admin test-connection
```

### 3. Initial Configuration

1. Set up build environments:
```bash
# Create base VM image
sudo ci-admin create-base-image

# Test build environment
sudo ci-admin test-build
```

2. Configure monitoring alerts:
```bash
# Access Grafana
open http://localhost:3000

# Default alerts are in:
# - High CPU/Memory usage
# - Build failures
# - Network issues
# - Disk space
```

3. Set up backup schedule:
```bash
# Configure backup location
sudo ci-admin configure-backup s3://your-bucket

# Enable automatic backups
sudo ci-admin enable-backup
```

### 4. Next Steps

1. Set up your first build pipeline:
   - Example pipeline in `.buildkite/pipeline.yml`
   - Test with: `buildkite-agent pipeline upload`

2. Configure artifact storage:
   ```bash
   # Local storage
   sudo ci-admin configure-storage local

   # Or S3
   sudo ci-admin configure-storage s3 your-bucket
   ```

3. Set up monitoring notifications:
   - Grafana → Alerting → Notification channels
   - Add Slack/Email/PagerDuty

## Maintenance and Updates

### Updating the System
```bash
# Update all components
sudo ci-admin update

# Update specific component
sudo ci-admin update [buildkite|tart|monitoring]
```

### Backup and Restore
```bash
# Manual backup
sudo ci-admin backup

# List backups
sudo ci-admin list-backups

# Restore from backup
sudo ci-admin restore backup-name
```

### Adding More Capacity
```bash
# Add another build agent
sudo ci-admin add-agent

# Add storage
sudo ci-admin extend-storage 500G
```

## Troubleshooting

### Common Issues

1. Build Agent Not Connecting
```bash
# Check agent status
sudo ci-admin check-agent

# View agent logs
sudo ci-admin logs buildkite
```

2. Monitoring Not Working
```bash
# Reset Grafana password
sudo ci-admin reset-grafana-password

# Check Prometheus targets
curl localhost:9090/targets
```

3. VM Issues
```bash
# Clean up stuck VMs
sudo ci-admin cleanup-vms

# Reset VM state
sudo ci-admin reset-vm vm-name
```

## Cost Analysis

### Hardware Costs (One-time)
- M2/M3 Mac Mini: $1,200
- Intel Mac Mini: $800
- Network Stack: $1,500
- UPS & PDU: $500
Total: ~$4,000

### Monthly Operating Costs
- Power: $50
- Internet: $100
- S3 Storage: $20
- Maintenance: $100
Total: ~$270/month

Compared to cloud services:
- MacStadium: ~$1,000/month
- EC2: ~$500/month
Net savings: ~$1,200/month
ROI: ~3.5 months

## Implementation Steps

1. **Hardware Setup**
   ```bash
   # Network configuration on UniFi
   - Create VLANs (10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24)
   - Configure PoE ports for Mac Minis
   - Set up WAN failover if needed
   - Configure firewall rules

   # Mac Mini preparation
   - Clean macOS install
   - System settings configured
   - Network interfaces tagged
   ```

2. **Run Installation**
   ```bash
   # Run the setup script
   curl -fsSL https://raw.githubusercontent.com/oven-sh/bun/main/infrastructure/setup/setup-mac-server.sh | sudo -E bash

   # Verify installation
   ci-health
   ```

3. **Post-Install Configuration**
   ```bash
   # Set up Buildkite pipeline
   buildkite-agent pipeline upload .buildkite/pipeline.yml

   # Create base VM image
   tart create base-macos --from-macos-version 14.0
   tart run base-macos
   # Install build dependencies
   tart stop base-macos
   tart clone base-macos build-1

   # Configure alerts
   - Set up PagerDuty/Slack in Grafana
   - Configure alert thresholds
   - Test alert pipeline
   ```

4. **Test Build Pipeline**
   ```bash
   # Run test build
   buildkite-agent build create \
     --pipeline your-org/test-build \
     --commit current \
     --branch main

   # Monitor build
   open http://localhost:3000/d/buildkite  # Grafana dashboard
   tail -f /var/log/buildkite-agent/buildkite-agent.log
   ```

## Health Check

Run `ci-health` to verify all components:

```bash
$ ci-health
🔍 Checking CI stack health...

📦 Buildkite Agent:
  ✅ Agent connected and running
  🏷  Tags: os=macos,arch=arm64

🖥  Tart VMs:
  ✅ Tart installed
  📝 Running VMs: 2
  💾 Available images: 5

🔒 VPN Status:
  ✅ WireGuard connected
  📡 Endpoint: 10.0.0.1:51820

📊 Prometheus:
  ✅ Prometheus running
  🎯 Targets: 3 active

📈 Grafana:
  ✅ Grafana running
  🔗 URL: http://localhost:3000

🚨 AlertManager:
  ✅ AlertManager running
  ⚡️ Active alerts: 0

🌐 Network:
  ✅ Build VLAN (10.0.1.0/24) configured
  ✅ Management VLAN (10.0.2.0/24) configured
  ✅ Storage VLAN (10.0.3.0/24) configured

💾 Storage:
  ✅ NFS mounted
  📁 Cache size: 500G

✅ All components are healthy!
```

Common issues and fixes:

```bash
# Buildkite agent not connecting
sudo launchctl kickstart -k system/com.buildkite.buildkite-agent

# VPN disconnected
sudo wg-quick up wg0  # For WireGuard
sudo tailscale up     # For Tailscale
sudo openvpn --config /etc/openvpn/unifi.ovpn --daemon  # For UniFi

# Prometheus/Grafana issues
sudo launchctl kickstart -k system/com.prometheus.prometheus
sudo launchctl kickstart -k system/com.grafana.grafana

# VM issues
tart list --running
tart stop stuck-vm
tart delete failed-vm

# NFS issues
sudo mount -a  # Remount all
```