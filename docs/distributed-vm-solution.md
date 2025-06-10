# Distributed VM Image Problem & Solution

## **Problem Statement**

When running macOS CI across multiple machines, VM image checks and builds can run on different machines:
- Machine A: Runs VM check, finds/builds image locally 
- Machine B: Runs actual build, but doesn't have the image → **FAILURE**

## **Root Cause**

All macOS build steps use the same agent configuration:
```javascript
{
  queue: "darwin",
  os: "darwin", 
  arch: "arm64",
  tart: "true"
}
```

Buildkite distributes work randomly across all `darwin` queue machines.

## **Solution: Machine Affinity with Concurrency Groups**

Use **Buildkite concurrency groups** to ensure all steps for a given platform run on the same machine.

### **Implementation Steps**

Add these properties to **all macOS build steps** in `.buildkite/ci.mjs`:

```javascript
// In getBuildVendorStep, getBuildCppStep, getBuildZigStep, getLinkBunStep:
if (platform.os === "darwin") {
  step.command = [
    // existing VM command...
  ];
  // ADD THESE LINES:
  step.concurrency_group = getTargetKey(platform);  // e.g., "darwin-aarch64"
  step.concurrency = 1;
}
```

### **Files to Modify**

In `.buildkite/ci.mjs`, add concurrency configuration to:

1. **getBuildVendorStep()** 
2. **getBuildCppStep()**
3. **getBuildZigStep()** 
4. **getLinkBunStep()**
5. **getMacOSVMBuildStep()** (VM preparation step)

### **How It Works**

1. **Concurrency Group**: Groups related steps (e.g., all `darwin-aarch64` steps)
2. **Concurrency Limit**: `concurrency = 1` forces sequential execution  
3. **Machine Affinity**: Buildkite assigns the entire group to one machine
4. **Result**: VM preparation + all builds run on the same machine

### **Benefits**

✅ **Solves distributed VM issue**: All related steps run on same machine  
✅ **Zero impact on other platforms**: Only affects `platform.os === "darwin"`  
✅ **Uses existing infrastructure**: Leverages `getTargetKey(platform)` already in use  
✅ **Scalable**: Multiple platforms can still run in parallel on different machines  

### **Example Before/After**

**Before (Random Distribution):**
```
Machine A: darwin-aarch64-build-vendor (builds VM)
Machine B: darwin-aarch64-build-cpp (VM missing! ❌)
Machine C: darwin-aarch64-build-zig (VM missing! ❌)
```

**After (Machine Affinity):**
```
Machine A: darwin-aarch64-build-vendor (builds VM)
Machine A: darwin-aarch64-build-cpp (VM available ✅)
Machine A: darwin-aarch64-build-zig (VM available ✅)
```

### **Testing**

To verify the fix:
1. Trigger a macOS build on multiple-machine setup
2. Check Buildkite logs - all steps for same platform should show same agent
3. Confirm no "VM image missing" errors

---

**Status**: Ready to implement  
**Risk**: Low (only affects macOS steps, uses existing Buildkite features)  
**Impact**: Fixes critical distributed VM issue 