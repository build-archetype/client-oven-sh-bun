# VM Management Guide

## Smart Incremental Updates

Instead of rebuilding VMs from scratch (30+ minutes), use these surgical update options:

### 🎯 Bun-only Update (30 seconds)
```bash
./scripts/build-macos-vm.sh --release=13 --update-bun-only
```
- Updates only the Bun version
- Preserves all other installed tools
- Perfect for version bumps

### 🍺 Homebrew-only Update (2-5 minutes)  
```bash
./scripts/build-macos-vm.sh --release=13 --update-homebrew-only
```
- Updates Homebrew and packages
- Doesn't reinstall everything
- Good for security updates

### 📋 Show Pinned Versions
```bash
./scripts/bootstrap-macos.sh --show-versions
```
- Displays all pinned component versions
- Useful for debugging version drift

## Pipeline Integration

### Option 1: Separate VM Build Step
Create a separate pipeline step that builds/updates VMs:

```yaml
steps:
  - label: "🔧 VM Prep"
    command: "./scripts/build-macos-vm.sh --release=13"
    agents:
      queue: "macos"
    
  - wait
  
  - label: "🚀 Build Bun"
    command: "./scripts/ci-macos.sh --release=13"
    agents:
      queue: "macos"
```

### Option 2: Smart Cache with Manual Override
Use existing VMs by default, manually trigger rebuilds when needed:

```bash
# Normal builds use existing VMs
./scripts/ci-macos.sh --release=13

# Manual rebuild when needed  
FORCE_BASE_IMAGE_REBUILD=true ./scripts/ci-macos.sh --release=13
```

## Version Management

### Current Pinned Versions
- **Node.js**: 22.9.0  
- **Bun**: 1.2.0
- **LLVM**: 19.1.7
- **Buildkite Agent**: 3.87.0

### Updating Pinned Versions
Edit these functions in `scripts/bootstrap-macos.sh`:
- `nodejs_version_exact()` - Node.js version
- `bun_version_exact()` - Bun bootstrap version  
- `llvm_version_exact()` - LLVM/Clang version

## Troubleshooting

### VM Build Failures
1. **Check versions**: `./scripts/bootstrap-macos.sh --show-versions`
2. **Try incremental update**: `--update-bun-only` or `--update-homebrew-only`  
3. **Force fresh build**: `--force-refresh` (last resort)

### Upstream Merge Issues
1. **Don't force rebuild everything** - use incremental updates
2. **Target specific changes** - if only lolhtml changed, just update related packages
3. **Use version pinning** - prevents unexpected drift

## Best Practices

✅ **Use incremental updates** for version bumps
✅ **Pin all component versions** for reproducibility  
✅ **Separate VM prep from builds** in pipeline
✅ **Cache VMs across builds** for speed

❌ **Don't force full rebuilds** unless absolutely necessary
❌ **Don't auto-rebuild on every change** - breaks working systems
❌ **Don't mix development and CI VM management** - use different approaches 