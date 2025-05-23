#!/usr/bin/env node

/**
 * Build and test Bun on macOS, Linux, and Windows.
 * @link https://buildkite.com/docs/pipelines/defining-steps
 */

import { join } from "node:path";
import {
  getBootstrapVersion,
  getBuildkiteEmoji,
  getBuildMetadata,
  getBuildNumber,
  getCanaryRevision,
  getCommitMessage,
  getEmoji,
  getEnv,
  getLastSuccessfulBuild,
  isBuildkite,
  isBuildManual,
  isFork,
  isMainBranch,
  isMergeQueue,
  parseBoolean,
  spawnSafe,
  startGroup,
  toYaml,
  uploadArtifact,
  writeFile,
} from "../scripts/utils.mjs";
import { randomUUID } from "node:crypto";

/**
 * @typedef {"linux" | "darwin" | "windows"} Os
 * @typedef {"aarch64" | "x64"} Arch
 * @typedef {"musl"} Abi
 * @typedef {"debian" | "ubuntu" | "alpine" | "amazonlinux"} Distro
 * @typedef {"latest" | "previous" | "oldest" | "eol"} Tier
 * @typedef {"release" | "assert" | "debug" | "asan"} Profile
 */

/**
 * @typedef Target
 * @property {Os} os
 * @property {Arch} arch
 * @property {Abi} [abi]
 * @property {boolean} [baseline]
 * @property {Profile} [profile]
 */

/**
 * @param {Target} target
 * @returns {string}
 */
function getTargetKey(target) {
  const { os, arch, abi, baseline, profile } = target;
  let key = `${os}-${arch}`;
  if (abi) {
    key += `-${abi}`;
  }
  if (baseline) {
    key += "-baseline";
  }
  if (profile && profile !== "release") {
    key += `-${profile}`;
  }
  return key;
}

/**
 * @param {Target} target
 * @returns {string}
 */
function getTargetLabel(target) {
  const { os, arch, abi, baseline, profile } = target;
  let label = `${getBuildkiteEmoji(os)} ${arch}`;
  if (abi) {
    label += `-${abi}`;
  }
  if (baseline) {
    label += "-baseline";
  }
  if (profile && profile !== "release") {
    label += `-${profile}`;
  }
  return label;
}

/**
 * @typedef Platform
 * @property {Os} os
 * @property {Arch} arch
 * @property {Abi} [abi]
 * @property {boolean} [baseline]
 * @property {Profile} [profile]
 * @property {Distro} [distro]
 * @property {string} release
 * @property {Tier} [tier]
 * @property {string[]} [features]
 */

/**
 * @type {Platform[]}
 */
const buildPlatforms = [
  { os: "darwin", arch: "aarch64", release: "14" },
  { os: "darwin", arch: "x64", release: "14" },
  // Temporarily disabled non-macOS platforms
  // { os: "linux", arch: "aarch64", distro: "amazonlinux", release: "2023", features: ["docker"] },
  // { os: "linux", arch: "x64", distro: "amazonlinux", release: "2023", features: ["docker"] },
  // { os: "linux", arch: "x64", baseline: true, distro: "amazonlinux", release: "2023", features: ["docker"] },
  // { os: "linux", arch: "x64", profile: "asan", distro: "amazonlinux", release: "2023", features: ["docker"] },
  // { os: "linux", arch: "aarch64", abi: "musl", distro: "alpine", release: "3.21" },
  // { os: "linux", arch: "x64", abi: "musl", distro: "alpine", release: "3.21" },
  // { os: "linux", arch: "x64", abi: "musl", baseline: true, distro: "alpine", release: "3.21" },
  // { os: "windows", arch: "x64", release: "2019" },
  // { os: "windows", arch: "x64", baseline: true, release: "2019" },
];

/**
 * @type {Platform[]}
 */
const testPlatforms = [
  { os: "darwin", arch: "aarch64", release: "14", tier: "latest" },
  { os: "darwin", arch: "aarch64", release: "13", tier: "previous" },
  { os: "darwin", arch: "x64", release: "14", tier: "latest" },
  { os: "darwin", arch: "x64", release: "13", tier: "previous" },
  // Temporarily disabled non-macOS platforms
  // { os: "linux", arch: "aarch64", distro: "debian", release: "12", tier: "latest" },
  // { os: "linux", arch: "x64", distro: "debian", release: "12", tier: "latest" },
  // { os: "linux", arch: "x64", baseline: true, distro: "debian", release: "12", tier: "latest" },
  // { os: "linux", arch: "x64", profile: "asan", distro: "debian", release: "12", tier: "latest" },
  // { os: "linux", arch: "aarch64", distro: "ubuntu", release: "24.04", tier: "latest" },
  // { os: "linux", arch: "aarch64", distro: "ubuntu", release: "20.04", tier: "oldest" },
  // { os: "linux", arch: "x64", distro: "ubuntu", release: "24.04", tier: "latest" },
  // { os: "linux", arch: "x64", distro: "ubuntu", release: "20.04", tier: "oldest" },
  // { os: "linux", arch: "x64", baseline: true, distro: "ubuntu", release: "24.04", tier: "latest" },
  // { os: "linux", arch: "x64", baseline: true, distro: "ubuntu", release: "20.04", tier: "oldest" },
  // { os: "linux", arch: "aarch64", abi: "musl", distro: "alpine", release: "3.21", tier: "latest" },
  // { os: "linux", arch: "x64", abi: "musl", distro: "alpine", release: "3.21", tier: "latest" },
  // { os: "linux", arch: "x64", abi: "musl", baseline: true, distro: "alpine", release: "3.21", tier: "latest" },
  // { os: "windows", arch: "x64", release: "2019", tier: "oldest" },
  // { os: "windows", arch: "x64", release: "2019", baseline: true, tier: "oldest" },
];

/**
 * @param {Platform} platform
 * @returns {string}
 */
function getPlatformKey(platform) {
  const { distro, release } = platform;
  const target = getTargetKey(platform);
  const version = release.replace(/\./g, "");
  if (distro) {
    return `${target}-${distro}-${version}`;
  }
  return `${target}-${version}`;
}

/**
 * @param {Platform} platform
 * @returns {string}
 */
function getPlatformLabel(platform) {
  const { os, arch, baseline, profile, distro, release } = platform;
  let label = `${getBuildkiteEmoji(distro || os)} ${release} ${arch}`;
  if (baseline) {
    label += "-baseline";
  }
  if (profile && profile !== "release") {
    label += `-${profile}`;
  }
  return label;
}

/**
 * @param {Platform} platform
 * @returns {string}
 */
function getImageKey(platform) {
  const { os, arch, distro, release, features, abi } = platform;
  const version = release.replace(/\./g, "");
  let key = `${os}-${arch}-${version}`;
  if (distro) {
    key += `-${distro}`;
  }
  if (features?.length) {
    key += `-with-${features.join("-")}`;
  }

  if (abi) {
    key += `-${abi}`;
  }

  return key;
}

/**
 * @param {Platform} platform
 * @returns {string}
 */
function getImageLabel(platform) {
  const { os, arch, distro, release } = platform;
  return `${getBuildkiteEmoji(distro || os)} ${release} ${arch}`;
}

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @returns {string}
 */
function getImageName(platform, options) {
  const { os } = platform;
  const { buildImages, publishImages } = options;

  const name = getImageKey(platform);

  if (buildImages && !publishImages) {
    return `${name}-build-${getBuildNumber()}`;
  }

  return `${name}-v${getBootstrapVersion(os)}`;
}

/**
 * @param {number} [limit]
 * @link https://buildkite.com/docs/pipelines/command-step#retry-attributes
 */
function getRetry(limit = 0) {
  return {
    manual: {
      permit_on_passed: true,
    },
    automatic: [
      { exit_status: 1, limit },
      { exit_status: -1, limit: 1 },
      { exit_status: 255, limit: 1 },
      { signal_reason: "cancel", limit: 1 },
      { signal_reason: "agent_stop", limit: 1 },
    ],
  };
}

/**
 * @returns {number}
 * @link https://buildkite.com/docs/pipelines/managing-priorities
 */
function getPriority() {
  if (isFork()) {
    return -1;
  }
  if (isMainBranch()) {
    return 2;
  }
  if (isMergeQueue()) {
    return 1;
  }
  return 0;
}

/**
 * Agents
 */

/**
 * @typedef {Object} Ec2Options
 * @property {string} instanceType
 * @property {number} cpuCount
 * @property {number} threadsPerCore
 * @property {boolean} dryRun
 */

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @param {Ec2Options} ec2Options
 * @returns {Agent}
 */
function getEc2Agent(platform, options, ec2Options) {
  const { os, arch, abi, distro, release } = platform;
  const { instanceType, cpuCount, threadsPerCore } = ec2Options;
  return {
    os,
    arch,
    abi,
    distro,
    release,
    robobun: true,
    robobun2: true,
    "image-name": getImageName(platform, options),
    "instance-type": instanceType,
    "cpu-count": cpuCount,
    "threads-per-core": threadsPerCore,
    "preemptible": false,
    queue: "darwin",
  };
}

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @returns {string}
 */
function getCppAgent(platform, options) {
  const { os, arch, distro } = platform;

  if (os === "darwin") {
    return {
      queue: "darwin",
      os,
      arch,
      tart: true,
    };
  }

  return getEc2Agent(platform, options, {
    instanceType: arch === "aarch64" ? "c8g.16xlarge" : "c7i.16xlarge",
    cpuCount: 32,
    threadsPerCore: 1,
  });
}

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @returns {Agent}
 */
function getZigAgent(platform, options) {
  const { arch } = platform;

  // Uncomment to restore to using macOS on-prem for Zig.
  // return {
  //   queue: "build-zig",
  // };

  return getEc2Agent(
    {
      os: "linux",
      arch: "x64",
      abi: "musl",
      distro: "alpine",
      release: "3.21",
    },
    options,
    {
      instanceType: "c7i.2xlarge",
      cpuCount: 4,
      threadsPerCore: 1,
    },
  );
}

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @returns {Agent}
 */
function getTestAgent(platform, options) {
  const { os, arch } = platform;

  if (os === "darwin") {
    return {
      queue: "darwin",
      os,
      arch,
      tart: true,
    };
  }

  // TODO: `dev-server-ssr-110.test.ts` and `next-build.test.ts` run out of memory at 8GB of memory, so use 16GB instead.
  if (os === "windows") {
    return getEc2Agent(platform, options, {
      instanceType: "c7i.2xlarge",
      cpuCount: 2,
      threadsPerCore: 1,
    });
  }

  if (arch === "aarch64") {
    return getEc2Agent(platform, options, {
      instanceType: "c8g.xlarge",
      cpuCount: 2,
      threadsPerCore: 1,
    });
  }

  return getEc2Agent(platform, options, {
    instanceType: "c7i.xlarge",
    cpuCount: 2,
    threadsPerCore: 1,
  });
}

/**
 * Steps
 */

/**
 * @param {Target} target
 * @param {PipelineOptions} options
 * @returns {Record<string, string | undefined>}
 */
function getBuildEnv(target, options) {
  const { baseline, abi } = target;
  const { canary } = options;
  const revision = typeof canary === "number" ? canary : 1;

  return {
    ENABLE_BASELINE: baseline ? "ON" : "OFF",
    ENABLE_CANARY: revision > 0 ? "ON" : "OFF",
    CANARY_REVISION: revision,
    ABI: abi === "musl" ? "musl" : undefined,
    CMAKE_VERBOSE_MAKEFILE: "ON",
    CMAKE_TLS_VERIFY: "0",
  };
}

/**
 * @param {Target} target
 * @param {PipelineOptions} options
 * @returns {string}
 */
function getBuildCommand(target, options) {
  const { profile } = target;

  const label = profile || "release";
  return `bun run build:${label}`;
}

/**
 * @returns {Promise<boolean>}
 */
async function checkTartAvailability() {
  try {
    // Check if tart is installed
    await spawnSafe(["which", "tart"]);
    
    // Check if we can list VMs
    const { stdout } = await spawnSafe(["tart", "list"], { stdio: "pipe" });
    
    // Check if we have the base image
    const { stdout: images } = await spawnSafe(["tart", "list", "images"], { stdio: "pipe" });
    if (!images.includes("ghcr.io/cirruslabs/macos-sequoia-base:latest")) {
      console.log("Base image not found, attempting to pull...");
      await spawnSafe(["tart", "pull", "ghcr.io/cirruslabs/macos-sequoia-base:latest"]);
    }
    
    return true;
  } catch (error) {
    console.error("Tart environment check failed:", error);
    return false;
  }
}

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @returns {Step}
 */
function getBuildVendorStep(platform, options) {
  const { os } = platform;
  const baseStep = {
    key: `${getTargetKey(platform)}-build-vendor`,
    label: `${getTargetLabel(platform)} - build-vendor`,
    agents: getCppAgent(platform, options),
    retry: getRetry(),
    cancel_on_build_failing: isMergeQueue(),
    env: getBuildEnv(platform, options)
  };

  if (os === "darwin") {
    const vmName = `bun-build-${Date.now()}-${randomUUID()}`;
    return {
      ...baseStep,
      command: [
        'tart list | awk \'/stopped/ && $1 == "local" && $2 ~ /^bun-/ {print $2}\' | xargs -n1 tart delete || true',
        'log stream --predicate \'process == "tart" OR process CONTAINS "Virtualization"\' > tart.log 2>&1 &',
        'TART_LOG_PID=$!',
        `trap 'kill $TART_LOG_PID || true; tart list | grep -q "${vmName}" && tart delete ${vmName} || true; buildkite-agent artifact upload tart.log || true' EXIT`,
        'tart --version || echo "Failed to get tart version"',
        'uname -m || echo "Failed to get architecture"',
        'which tart || echo "Failed to find tart"',
        'ls -l $(which tart) || echo "Failed to list tart"',
        'tart list || echo "Failed to list VMs"',
        'tart pull ghcr.io/cirruslabs/macos-sequoia-base:latest || echo "Failed to pull base image"',
        `tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest ${vmName} || echo "Failed to clone VM"`,
        `(tart run ${vmName} --no-graphics) &`,
        'sleep 30',
        'echo "--- 🏗 Building vendor"',
        'echo "Waiting for VM to be healthy..."',
        'attempt=1',
        'max_attempts=5',
        'while [ $attempt -le $max_attempts ]; do',
        '  if tart exec ${vmName} -- echo "VM is healthy" > /dev/null 2>&1; then',
        '    echo "VM is healthy"',
        '    break',
        '  fi',
        '  if [ $attempt -eq $max_attempts ]; then',
        '    echo "VM failed to become healthy after $max_attempts attempts"',
        '    exit 1',
        '  fi',
        '  echo "Attempt $attempt: VM not ready yet, waiting..."',
        '  sleep 10',
        '  attempt=$((attempt + 1))',
        'done',
        `tart exec ${vmName} -- sh -c '${getBuildCommand(platform, options)} --target dependencies 2>&1 | tee /tmp/build.log'`,
        `tart copy-from ${vmName}:/tmp/build.log ./build.log || echo "No build log found"`,
        'buildkite-agent artifact upload build.log || echo "No build log to upload"'
      ]
    };
  }

  return {
    ...baseStep,
    command: `${getBuildCommand(platform, options)} --target dependencies`,
  };
}

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @returns {Step}
 */
function getBuildCppStep(platform, options) {
  const { os } = platform;
  const command = getBuildCommand(platform, options);
  const baseStep = {
    key: `${getTargetKey(platform)}-build-cpp`,
    label: `${getTargetLabel(platform)} - build-cpp`,
    agents: getCppAgent(platform, options),
    retry: getRetry(),
    cancel_on_build_failing: isMergeQueue(),
    env: {
      BUN_CPP_ONLY: "ON",
      ...getBuildEnv(platform, options)
    }
  };

  if (os === "darwin") {
    const vmName = `bun-build-${Date.now()}-${randomUUID()}`;
    return {
      ...baseStep,
      command: [
        'tart list | awk \'/stopped/ && $1 == "local" && $2 ~ /^bun-/ {print $2}\' | xargs -n1 tart delete || true',
        'log stream --predicate \'process == "tart" OR process CONTAINS "Virtualization"\' > tart.log 2>&1 &',
        'TART_LOG_PID=$!',
        `trap 'kill $TART_LOG_PID || true; tart list | grep -q "${vmName}" && tart delete ${vmName} || true; buildkite-agent artifact upload tart.log || true' EXIT`,
        'tart --version || echo "Failed to get tart version"',
        'uname -m || echo "Failed to get architecture"',
        'which tart || echo "Failed to find tart"',
        'ls -l $(which tart) || echo "Failed to list tart"',
        'tart list || echo "Failed to list VMs"',
        'tart pull ghcr.io/cirruslabs/macos-sequoia-base:latest || echo "Failed to pull base image"',
        `tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest ${vmName} || echo "Failed to clone VM"`,
        `(tart run ${vmName} --no-graphics) &`,
        'sleep 30',
        'echo "--- 🏗 Building C++"',
        'echo "Waiting for VM to be healthy..."',
        'attempt=1',
        'max_attempts=5',
        'while [ $attempt -le $max_attempts ]; do',
        '  if tart exec ${vmName} -- echo "VM is healthy" > /dev/null 2>&1; then',
        '    echo "VM is healthy"',
        '    break',
        '  fi',
        '  if [ $attempt -eq $max_attempts ]; then',
        '    echo "VM failed to become healthy after $max_attempts attempts"',
        '    exit 1',
        '  fi',
        '  echo "Attempt $attempt: VM not ready yet, waiting..."',
        '  sleep 10',
        '  attempt=$((attempt + 1))',
        'done',
        `tart exec ${vmName} -- sh -c '${command} --target bun'`,
        `tart exec ${vmName} -- sh -c '${command} --target dependencies'`
      ]
    };
  }

  return {
    ...baseStep,
    command: [`${command} --target bun`, `${command} --target dependencies`],
  };
}

/**
 * @param {Target} target
 * @returns {string}
 */
function getBuildToolchain(target) {
  const { os, arch, abi, baseline } = target;
  let key = `${os}-${arch}`;
  if (abi) {
    key += `-${abi}`;
  }
  if (baseline) {
    key += "-baseline";
  }
  return key;
}

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @returns {Step}
 */
function getBuildZigStep(platform, options) {
  const { os } = platform;
  const toolchain = getBuildToolchain(platform);
  const baseStep = {
    key: `${getTargetKey(platform)}-build-zig`,
    label: `${getTargetLabel(platform)} - build-zig`,
    agents: getZigAgent(platform, options),
    retry: getRetry(),
    cancel_on_build_failing: isMergeQueue(),
    env: getBuildEnv(platform, options),
    timeout_in_minutes: 35,
  };

  if (os === "darwin") {
    const vmName = `bun-build-${Date.now()}-${randomUUID()}`;
    return {
      ...baseStep,
      command: [
        `tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest ${vmName}`,
        `(tart run ${vmName} --no-graphics) &`,
        'sleep 30',
        'echo "--- 🏗 Building Zig"',
        `tart exec ${vmName} -- ${getBuildCommand(platform, options)} --target bun-zig --toolchain ${toolchain}`,
        `tart delete ${vmName}`,
      ],
    };
  }

  return {
    ...baseStep,
    command: `${getBuildCommand(platform, options)} --target bun-zig --toolchain ${toolchain}`,
  };
}

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @returns {Step}
 */
function getLinkBunStep(platform, options) {
  const { os } = platform;
  const baseStep = {
    key: `${getTargetKey(platform)}-build-bun`,
    label: `${getTargetLabel(platform)} - build-bun`,
    depends_on: [`${getTargetKey(platform)}-build-cpp`, `${getTargetKey(platform)}-build-zig`],
    agents: getCppAgent(platform, options),
    retry: getRetry(),
    cancel_on_build_failing: isMergeQueue(),
    env: {
      BUN_LINK_ONLY: "ON",
      ...getBuildEnv(platform, options),
    },
  };

  if (os === "darwin") {
    const vmName = `bun-build-${Date.now()}-${randomUUID()}`;
    return {
      ...baseStep,
      command: [
        `tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest ${vmName}`,
        `(tart run ${vmName} --no-graphics) &`,
        'sleep 30',
        'echo "--- 🔗 Linking Bun"',
        `tart exec ${vmName} -- ${getBuildCommand(platform, options)} --target bun`,
        `tart delete ${vmName}`,
      ],
    };
  }

  return {
    ...baseStep,
    command: `${getBuildCommand(platform, options)} --target bun`,
  };
}

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @returns {Step}
 */
function getBuildBunStep(platform, options) {
  return {
    key: `${getTargetKey(platform)}-build-bun`,
    label: `${getTargetLabel(platform)} - build-bun`,
    agents: getCppAgent(platform, options),
    retry: getRetry(),
    cancel_on_build_failing: isMergeQueue(),
    env: getBuildEnv(platform, options),
    command: getBuildCommand(platform, options),
  };
}

/**
 * @typedef {Object} TestOptions
 * @property {string} [buildId]
 * @property {boolean} [unifiedTests]
 * @property {string[]} [testFiles]
 * @property {boolean} [dryRun]
 */

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @param {TestOptions} [testOptions]
 * @returns {Step}
 */
function getTestBunStep(platform, options, testOptions = {}) {
  const { os, profile } = platform;
  const { buildId, unifiedTests, testFiles } = testOptions;

  const args = [`--step=${getTargetKey(platform)}-build-bun`];
  if (buildId) {
    args.push(`--build-id=${buildId}`);
  }
  if (testFiles) {
    args.push(...testFiles.map(testFile => `--include=${testFile}`));
  }

  const depends = [];
  if (!buildId) {
    depends.push(`${getTargetKey(platform)}-build-bun`);
  }

  const baseStep = {
    key: `${getPlatformKey(platform)}-test-bun`,
    label: `${getPlatformLabel(platform)} - test-bun`,
    depends_on: depends,
    agents: getTestAgent(platform, options),
    retry: getRetry(),
    cancel_on_build_failing: isMergeQueue(),
    parallelism: unifiedTests ? undefined : os === "darwin" ? 2 : 10,
    timeout_in_minutes: profile === "asan" ? 90 : 30,
  };

  if (os === "darwin") {
    const vmName = `bun-test-${Date.now()}-${randomUUID()}`;
    return {
      ...baseStep,
      command: [
        `tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest ${vmName}`,
        `(tart run ${vmName} --no-graphics) &`,
        'sleep 30',
        'echo "--- 🧪 Testing"',
        `tart exec ${vmName} -- ./scripts/runner.node.mjs ${args.join(" ")}`,
        `tart delete ${vmName}`,
      ],
    };
  }

  return {
    ...baseStep,
    command:
      os === "windows"
        ? `node .\\scripts\\runner.node.mjs ${args.join(" ")}`
        : `./scripts/runner.node.mjs ${args.join(" ")}`,
  };
}

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @returns {Step}
 */
function getBuildImageStep(platform, options) {
  const { os, arch, distro, release, features } = platform;
  const { publishImages } = options;
  const action = publishImages ? "publish-image" : "create-image";

  const command = [
    "node",
    "./scripts/machine.mjs",
    action,
    `--os=${os}`,
    `--arch=${arch}`,
    distro && `--distro=${distro}`,
    `--release=${release}`,
    "--cloud=aws",
    "--ci",
    "--authorized-org=oven-sh",
  ];
  for (const feature of features || []) {
    command.push(`--feature=${feature}`);
  }

  return {
    key: `${getImageKey(platform)}-build-image`,
    label: `${getImageLabel(platform)} - build-image`,
    agents: {
      queue: "darwin",
    },
    env: {
      DEBUG: "1",
    },
    retry: getRetry(),
    cancel_on_build_failing: isMergeQueue(),
    command: command.filter(Boolean).join(" "),
    timeout_in_minutes: 3 * 60,
  };
}

/**
 * @param {Platform[]} buildPlatforms
 * @param {PipelineOptions} options
 * @returns {Step}
 */
function getReleaseStep(buildPlatforms, options) {
  const { canary } = options;
  const revision = typeof canary === "number" ? canary : 1;

  return {
    key: "release",
    label: getBuildkiteEmoji("rocket"),
    agents: {
      queue: "darwin",
    },
    depends_on: buildPlatforms.map(platform => `${getTargetKey(platform)}-build-bun`),
    env: {
      CANARY: revision,
    },
    command: ".buildkite/scripts/upload-release.sh",
  };
}

/**
 * @param {Platform[]} buildPlatforms
 * @returns {Step}
 */
function getBenchmarkStep() {
  return {
    key: "benchmark",
    label: "📊",
    agents: {
      queue: "darwin",
    },
    depends_on: `linux-x64-build-bun`,
    command: "node .buildkite/scripts/upload-benchmark.mjs",
  };
}

/**
 * @typedef {Object} Pipeline
 * @property {Step[]} [steps]
 * @property {number} [priority]
 */

/**
 * @typedef {Record<string, string | undefined>} Agent
 */

/**
 * @typedef {GroupStep | CommandStep | BlockStep} Step
 */

/**
 * @typedef {Object} GroupStep
 * @property {string} key
 * @property {string} group
 * @property {Step[]} steps
 * @property {string[]} [depends_on]
 */

/**
 * @typedef {Object} CommandStep
 * @property {string} key
 * @property {string} [label]
 * @property {Record<string, string | undefined>} [agents]
 * @property {Record<string, string | undefined>} [env]
 * @property {string} command
 * @property {string[]} [depends_on]
 * @property {Record<string, string | undefined>} [retry]
 * @property {boolean} [cancel_on_build_failing]
 * @property {boolean} [soft_fail]
 * @property {number} [parallelism]
 * @property {number} [concurrency]
 * @property {string} [concurrency_group]
 * @property {number} [priority]
 * @property {number} [timeout_in_minutes]
 * @link https://buildkite.com/docs/pipelines/command-step
 */

/**
 * @typedef {Object} BlockStep
 * @property {string} key
 * @property {string} block
 * @property {string} [prompt]
 * @property {"passed" | "failed" | "running"} [blocked_state]
 * @property {(SelectInput | TextInput)[]} [fields]
 */

/**
 * @typedef {Object} TextInput
 * @property {string} key
 * @property {string} text
 * @property {string} [default]
 * @property {boolean} [required]
 * @property {string} [hint]
 */

/**
 * @typedef {Object} SelectInput
 * @property {string} key
 * @property {string} select
 * @property {string | string[]} [default]
 * @property {boolean} [required]
 * @property {boolean} [multiple]
 * @property {string} [hint]
 * @property {SelectOption[]} [options]
 */

/**
 * @typedef {Object} SelectOption
 * @property {string} label
 * @property {string} value
 */

/**
 * @typedef {Object} PipelineOptions
 * @property {string | boolean} [skipEverything]
 * @property {string | boolean} [skipBuilds]
 * @property {string | boolean} [skipTests]
 * @property {string | boolean} [forceBuilds]
 * @property {string | boolean} [forceTests]
 * @property {string | boolean} [buildImages]
 * @property {string | boolean} [publishImages]
 * @property {number} [canary]
 * @property {Platform[]} [buildPlatforms]
 * @property {Platform[]} [testPlatforms]
 * @property {string[]} [testFiles]
 * @property {boolean} [unifiedBuilds]
 * @property {boolean} [unifiedTests]
 */

/**
 * @param {Step} step
 * @param {(string | undefined)[]} dependsOn
 * @returns {Step}
 */
function getStepWithDependsOn(step, ...dependsOn) {
  const { depends_on: existingDependsOn = [] } = step;
  return {
    ...step,
    depends_on: [...existingDependsOn, ...dependsOn.filter(Boolean)],
  };
}

/**
 * @returns {BlockStep}
 */
function getOptionsStep() {
  const booleanOptions = [
    {
      label: `${getEmoji("true")} Yes`,
      value: "true",
    },
    {
      label: `${getEmoji("false")} No`,
      value: "false",
    },
  ];

  return {
    key: "options",
    block: getBuildkiteEmoji("clipboard"),
    blocked_state: "running",
    fields: [
      {
        key: "canary",
        select: "If building, is this a canary build?",
        hint: "If you are building for a release, this should be false",
        required: false,
        default: "true",
        options: booleanOptions,
      },
      {
        key: "skip-builds",
        select: "Do you want to skip the build?",
        hint: "If true, artifacts will be downloaded from the last successful build",
        required: false,
        default: "false",
        options: booleanOptions,
      },
      {
        key: "skip-tests",
        select: "Do you want to skip the tests?",
        required: false,
        default: "false",
        options: booleanOptions,
      },
      {
        key: "force-builds",
        select: "Do you want to force run the build?",
        hint: "If true, the build will run even if no source files have changed",
        required: false,
        default: "false",
        options: booleanOptions,
      },
      {
        key: "force-tests",
        select: "Do you want to force run the tests?",
        hint: "If true, the tests will run even if no test files have changed",
        required: false,
        default: "false",
        options: booleanOptions,
      },
      {
        key: "build-profiles",
        select: "If building, which profiles do you want to build?",
        required: false,
        multiple: true,
        default: ["release"],
        options: [
          {
            label: `${getEmoji("release")} Release`,
            value: "release",
          },
          {
            label: `${getEmoji("assert")} Release with Assertions`,
            value: "assert",
          },
          {
            label: `${getEmoji("asan")} Release with ASAN`,
            value: "asan",
          },
          {
            label: `${getEmoji("debug")} Debug`,
            value: "debug",
          },
        ],
      },
      {
        key: "build-platforms",
        select: "If building, which platforms do you want to build?",
        hint: "If this is left blank, all platforms are built",
        required: false,
        multiple: true,
        default: [],
        options: buildPlatforms.map(platform => {
          const { os, arch, abi, baseline } = platform;
          let label = `${getEmoji(os)} ${arch}`;
          if (abi) {
            label += `-${abi}`;
          }
          if (baseline) {
            label += `-baseline`;
          }
          return {
            label,
            value: getTargetKey(platform),
          };
        }),
      },
      {
        key: "test-platforms",
        select: "If testing, which platforms do you want to test?",
        hint: "If this is left blank, all platforms are tested",
        required: false,
        multiple: true,
        default: [],
        options: [...new Map(testPlatforms.map(platform => [getImageKey(platform), platform])).entries()].map(
          ([key, platform]) => {
            const { os, arch, abi, distro, release } = platform;
            let label = `${getEmoji(os)} ${arch}`;
            if (abi) {
              label += `-${abi}`;
            }
            if (distro) {
              label += ` ${distro}`;
            }
            if (release) {
              label += ` ${release}`;
            }
            return {
              label,
              value: key,
            };
          },
        ),
      },
      {
        key: "test-files",
        text: "If testing, which files do you want to test?",
        hint: "If specified, only run test paths that include the list of strings (e.g. 'test/js', 'test/cli/hot/watch.ts')",
        required: false,
      },
      {
        key: "build-images",
        select: "Do you want to re-build the base images?",
        hint: "This can take 2-3 hours to complete, only do so if you've tested locally",
        required: false,
        default: "false",
        options: booleanOptions,
      },
      {
        key: "publish-images",
        select: "Do you want to re-build and publish the base images?",
        hint: "This can take 2-3 hours to complete, only do so if you've tested locally",
        required: false,
        default: "false",
        options: booleanOptions,
      },
      {
        key: "unified-builds",
        select: "Do you want to build each platform in a single step?",
        hint: "If true, builds will not be split into seperate steps (this will likely slow down the build)",
        required: false,
        default: "false",
        options: booleanOptions,
      },
      {
        key: "unified-tests",
        select: "Do you want to run tests in a single step?",
        hint: "If true, tests will not be split into seperate steps (this will be very slow)",
        required: false,
        default: "false",
        options: booleanOptions,
      },
    ],
  };
}

/**
 * @returns {Step}
 */
function getOptionsApplyStep() {
  const command = getEnv("BUILDKITE_COMMAND");
  return {
    key: "options-apply",
    label: getBuildkiteEmoji("gear"),
    command: `${command} --apply`,
    depends_on: ["options"],
    agents: {
      queue: getEnv("BUILDKITE_AGENT_META_DATA_QUEUE", false),
    },
  };
}

/**
 * @returns {Promise<PipelineOptions | undefined>}
 */
async function getPipelineOptions() {
  const isManual = isBuildManual();
  if (isManual && !process.argv.includes("--apply")) {
    return;
  }

  let filteredBuildPlatforms = buildPlatforms;
  if (isMainBranch()) {
    filteredBuildPlatforms = buildPlatforms.filter(({ profile }) => profile !== "asan");
  }

  const canary = await getCanaryRevision();
  const buildPlatformsMap = new Map(filteredBuildPlatforms.map(platform => [getTargetKey(platform), platform]));
  const testPlatformsMap = new Map(testPlatforms.map(platform => [getPlatformKey(platform), platform]));

  if (isManual) {
    const { fields } = getOptionsStep();
    const keys = fields?.map(({ key }) => key) ?? [];
    const values = await Promise.all(keys.map(getBuildMetadata));
    const options = Object.fromEntries(keys.map((key, index) => [key, values[index]]));

    /**
     * @param {string} value
     * @returns {string[] | undefined}
     */
    const parseArray = value =>
      value
        ?.split("\n")
        ?.map(item => item.trim())
        ?.filter(Boolean);

    const buildProfiles = parseArray(options["build-profiles"]);
    const buildPlatformKeys = parseArray(options["build-platforms"]);
    const testPlatformKeys = parseArray(options["test-platforms"]);
    return {
      canary: parseBoolean(options["canary"]) ? canary : 0,
      skipBuilds: parseBoolean(options["skip-builds"]),
      forceBuilds: parseBoolean(options["force-builds"]),
      skipTests: parseBoolean(options["skip-tests"]),
      buildImages: parseBoolean(options["build-images"]),
      publishImages: parseBoolean(options["publish-images"]),
      testFiles: parseArray(options["test-files"]),
      unifiedBuilds: parseBoolean(options["unified-builds"]),
      unifiedTests: parseBoolean(options["unified-tests"]),
      buildPlatforms: buildPlatformKeys?.length
        ? buildPlatformKeys.flatMap(key => buildProfiles.map(profile => ({ ...buildPlatformsMap.get(key), profile })))
        : Array.from(buildPlatformsMap.values()),
      testPlatforms: testPlatformKeys?.length
        ? testPlatformKeys.flatMap(key => buildProfiles.map(profile => ({ ...testPlatformsMap.get(key), profile })))
        : Array.from(testPlatformsMap.values()),
      dryRun: parseBoolean(options["dry-run"]),
    };
  }

  const commitMessage = getCommitMessage();

  /**
   * @param {RegExp} pattern
   * @returns {string | boolean}
   */
  const parseOption = pattern => {
    const match = pattern.exec(commitMessage);
    if (match) {
      const [, value] = match;
      return value;
    }
    return false;
  };

  const isCanary =
    !parseBoolean(getEnv("RELEASE", false) || "false") &&
    !/\[(release|build release|release build)\]/i.test(commitMessage);
  return {
    canary: isCanary ? canary : 0,
    skipEverything: parseOption(/\[(skip ci|no ci)\]/i),
    skipBuilds: parseOption(/\[(skip builds?|no builds?|only tests?)\]/i),
    forceBuilds: parseOption(/\[(force builds?)\]/i),
    skipTests: parseOption(/\[(skip tests?|no tests?|only builds?)\]/i),
    buildImages: parseOption(/\[(build images?)\]/i),
    dryRun: parseOption(/\[(dry run)\]/i),
    publishImages: parseOption(/\[(publish images?)\]/i),
    buildPlatforms: Array.from(buildPlatformsMap.values()),
    testPlatforms: Array.from(testPlatformsMap.values()),
  };
}

/**
 * @param {PipelineOptions} [options]
 * @returns {Promise<Pipeline | undefined>}
 */
async function getPipeline(options = {}) {
  const priority = getPriority();
  const steps = [];

  // Add options step for manual builds
  if (isBuildManual()) {
    steps.push(getOptionsStep());
    steps.push(getOptionsApplyStep());
  }

  // Get filtered platforms based on options
  const { buildPlatforms: filteredBuildPlatforms = buildPlatforms, testPlatforms: filteredTestPlatforms = testPlatforms } = options;

  // Add build steps for each platform
  for (const platform of filteredBuildPlatforms) {
    const { os } = platform;
    if (os === "darwin") {
      // Only add the self-contained steps for macOS
      steps.push(getBuildVendorStep(platform, options));
      steps.push(getBuildCppStep(platform, options));
      steps.push(getBuildZigStep(platform, options));
      steps.push(getLinkBunStep(platform, options));
    } else {
      // Original steps for non-macOS platforms
      steps.push(getBuildVendorStep(platform, options));
      steps.push(getBuildCppStep(platform, options));
      steps.push(getBuildZigStep(platform, options));
      steps.push(getLinkBunStep(platform, options));
    }
  }

  // Add test steps for each platform
  for (const platform of filteredTestPlatforms) {
    const { os } = platform;
    if (os === "darwin") {
      // Only add the self-contained test step for macOS
      steps.push(getTestBunStep(platform, options));
    } else {
      // Original test steps for non-macOS platforms
      steps.push(getTestBunStep(platform, options));
    }
  }

  // Add release step if needed
  if (!options.skipBuilds) {
    steps.push(getReleaseStep(filteredBuildPlatforms, options));
  }

  // Add benchmark step
  steps.push(getBenchmarkStep());

  return {
    priority,
    steps,
  };
}

/**
 * @param {Platform} platform
 * @param {PipelineOptions} options
 * @returns {string[]}
 */
function getTestArgs(platform, options) {
  const { buildId, unifiedTests, testFiles } = options;
  const args = [`--step=${getTargetKey(platform)}-build-bun`];
  
  if (buildId) {
    args.push(`--build-id=${buildId}`);
  }
  if (testFiles) {
    args.push(...testFiles.map(testFile => `--include=${testFile}`));
  }
  
  return args;
}

async function main() {
  startGroup("Generating options...");
  const options = await getPipelineOptions();
  if (options) {
    console.log("Generated options:", options);
  }

  startGroup("Generating pipeline...");
  const pipeline = await getPipeline(options);
  if (!pipeline) {
    console.log("Generated pipeline is empty, skipping...");
    return;
  }

  const content = toYaml(pipeline);
  const contentPath = join(process.cwd(), ".buildkite", "ci.yml");
  writeFile(contentPath, content);

  console.log("Generated pipeline:");
  console.log(" - Path:", contentPath);
  console.log(" - Size:", (content.length / 1024).toFixed(), "KB");

  if (isBuildkite) {
    startGroup("Uploading pipeline...");
    try {
      await spawnSafe(["buildkite-agent", "pipeline", "upload", contentPath], { stdio: "inherit" });
    } finally {
      await uploadArtifact(contentPath);
    }
  }
}

await main();