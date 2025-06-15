#!/usr/bin/env node

import { spawn as nodeSpawn } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { basename, join, relative, resolve } from "node:path";
import {
  formatAnnotationToHtml,
  isCI,
  parseAnnotations,
  printEnvironment,
  reportAnnotationToBuildKite,
  startGroup,
} from "./utils.mjs";

// https://cmake.org/cmake/help/latest/manual/cmake.1.html#generate-a-project-buildsystem
const generateFlags = [
  ["-S", "string", "path to source directory"],
  ["-B", "string", "path to build directory"],
  ["-D", "string", "define a build option (e.g. -DCMAKE_BUILD_TYPE=Release)"],
  ["-G", "string", "build generator (e.g. -GNinja)"],
  ["-W", "string", "enable warnings (e.g. -Wno-dev)"],
  ["--fresh", "boolean", "force a fresh build"],
  ["--log-level", "string", "set the log level"],
  ["--debug-output", "boolean", "print debug output"],
  ["--toolchain", "string", "the toolchain to use"],
];

// https://cmake.org/cmake/help/latest/manual/cmake.1.html#generate-a-project-buildsystem
const buildFlags = [
  ["--config", "string", "build configuration (e.g. --config Release)"],
  ["--target", "string", "build target"],
  ["-t", "string", "same as --target"],
  ["--parallel", "number", "number of parallel jobs"],
  ["-j", "number", "same as --parallel"],
  ["--verbose", "boolean", "enable verbose output"],
  ["-v", "boolean", "same as --verbose"],
];

async function build(args) {
  const startTime = Date.now();

  if (process.platform === "win32" && !process.env["VSINSTALLDIR"]) {
    const shellPath = join(import.meta.dirname, "vs-shell.ps1");
    const scriptPath = import.meta.filename;
    return spawn("pwsh", ["-NoProfile", "-NoLogo", "-File", shellPath, process.argv0, scriptPath, ...args]);
  }

  if (isCI) {
    printEnvironment();
  }

  const env = {
    ...process.env,
    FORCE_COLOR: "1",
    CLICOLOR_FORCE: "1",
  };

  const generateOptions = parseOptions(args, generateFlags);
  const buildOptions = parseOptions(args, buildFlags);

  const buildPath = resolve(generateOptions["-B"] || buildOptions["--build"] || "build");
  generateOptions["-B"] = buildPath;
  buildOptions["--build"] = buildPath;

  if (!generateOptions["-S"]) {
    generateOptions["-S"] = process.cwd();
  }

  const cacheRead = isCacheReadEnabled();
  const cacheWrite = isCacheWriteEnabled();
  if (cacheRead || cacheWrite) {
    const cachePath = getCachePath();
    if (cacheRead && !existsSync(cachePath)) {
      const mainCachePath = getCachePath(getDefaultBranch());
      if (existsSync(mainCachePath)) {
        mkdirSync(cachePath, { recursive: true });
        try {
          cpSync(mainCachePath, cachePath, { recursive: true, force: true });
        } catch (error) {
          const { code } = error;
          switch (code) {
            case "EPERM":
            case "EACCES":
              try {
                chmodSync(mainCachePath, 0o777);
                cpSync(mainCachePath, cachePath, { recursive: true, force: true });
              } catch (error) {
                console.warn("Failed to copy cache with permissions fix", error);
              }
              break;
            default:
              console.warn("Failed to copy cache", error);
          }
        }
      }
    }
    generateOptions["-DCACHE_PATH"] = cmakePath(cachePath);
    generateOptions["--fresh"] = undefined;
    if (cacheRead && cacheWrite) {
      generateOptions["-DCACHE_STRATEGY"] = "read-write";
    } else if (cacheRead) {
      generateOptions["-DCACHE_STRATEGY"] = "read-only";
    } else if (cacheWrite) {
      generateOptions["-DCACHE_STRATEGY"] = "write-only";
    }
  }

  // Add Buildkite artifact-based cache flags if environment variables are set
  if (process.env.BUILDKITE_CACHE_RESTORE === "ON") {
    generateOptions["-DBUILDKITE_CACHE_RESTORE"] = "ON";
    console.log("Buildkite cache restore enabled via environment variable");
  }
  
  if (process.env.BUILDKITE_CACHE_SAVE === "ON") {
    generateOptions["-DBUILDKITE_CACHE_SAVE"] = "ON";
    console.log("Buildkite cache save enabled via environment variable");
  }

  // Download build artifacts if BUN_LINK_ONLY is enabled
  await downloadBuildArtifacts();

  const toolchain = generateOptions["--toolchain"];
  if (toolchain) {
    const toolchainPath = resolve(import.meta.dirname, "..", "cmake", "toolchains", `${toolchain}.cmake`);
    generateOptions["--toolchain"] = toolchainPath;
  }

  const generateArgs = Object.entries(generateOptions).flatMap(([flag, value]) =>
    flag.startsWith("-D") ? [`${flag}=${value}`] : [flag, value],
  );

  await startGroup("CMake Configure", () => spawn("cmake", generateArgs, { env }));

  const envPath = resolve(buildPath, ".env");
  if (existsSync(envPath)) {
    const envFile = readFileSync(envPath, "utf8");
    for (const line of envFile.split(/\r\n|\n|\r/)) {
      const [key, value] = line.split("=");
      env[key] = value;
    }
  }

  // Cache restore step (before main build)
  if (process.env.BUILDKITE_CACHE_RESTORE === "ON") {
    // Skip CMake cache operations for persistent cache (handled by rsync)
    if (process.env.BUILDKITE_CACHE_TYPE === "persistent") {
      console.log("Skipping CMake cache restore (using persistent workspace cache)");
    } else {
      console.log("Running cache restore step...");
      try {
        await startGroup("Cache Restore", () => 
          spawn("cmake", ["--build", buildPath, "--target", "cache-restore"], { env })
        );
      } catch (error) {
        console.warn("Cache restore failed (continuing with build):", error.message);
      }
    }
  }

  const buildArgs = Object.entries(buildOptions)
    .sort(([a], [b]) => (a === "--build" ? -1 : a.localeCompare(b)))
    .flatMap(([flag, value]) => [flag, value]);

  await startGroup("CMake Build", () => spawn("cmake", buildArgs, { env }));

  // Upload build artifacts for linking step
  if (process.env.BUN_CPP_ONLY === "ON") {
    console.log("📤 Uploading C++ build artifacts for linking step...");
    try {
      // Check for both compressed and uncompressed versions
      const artifacts = ["build/release/libbun-profile.a", "build/release/libbun-profile.a.gz"];
      const artifactToUpload = artifacts.find(path => existsSync(path));
      
      if (artifactToUpload) {
        await spawn("buildkite-agent", ["artifact", "upload", artifactToUpload], {
          stdio: "inherit"
        });
        console.log(`✅ C++ artifacts uploaded successfully: ${artifactToUpload}`);
      } else {
        console.warn("⚠️ No C++ artifacts found to upload:", artifacts);
      }
    } catch (error) {
      console.warn("⚠️ Failed to upload C++ artifacts:", error.message);
    }
  }
  
  // Upload zig artifacts if they exist (for zig build step)
  const zigArtifacts = ["build/release/bun-zig.o", "build/release/bun-zig.o.gz"];
  const zigArtifactToUpload = zigArtifacts.find(path => existsSync(path));
  if (zigArtifactToUpload) {
    console.log("📤 Uploading Zig build artifacts for linking step...");
    try {
      await spawn("buildkite-agent", ["artifact", "upload", zigArtifactToUpload], {
        stdio: "inherit"
      });
      console.log(`✅ Zig artifacts uploaded successfully: ${zigArtifactToUpload}`);
    } catch (error) {
      console.warn("⚠️ Failed to upload Zig artifacts:", error.message);
    }
  }

  // Cache save step (after main build)
  if (process.env.BUILDKITE_CACHE_SAVE === "ON") {
    // Skip CMake cache operations for persistent cache (handled by rsync)
    if (process.env.BUILDKITE_CACHE_TYPE === "persistent") {
      console.log("Skipping CMake cache save (using persistent workspace cache)");
    } else {
      console.log("Running cache save step...");
      try {
        await startGroup("Cache Save", () => 
          spawn("cmake", ["--build", buildPath, "--target", "cache-save"], { env })
        );
      } catch (error) {
        console.warn("Cache save failed:", error.message);
      }
    }
  }

  printDuration("total", Date.now() - startTime);
}

function cmakePath(path) {
  return path.replace(/\\/g, "/");
}

/** @param {string} str */
const toAlphaNumeric = str => str.replace(/[^a-z0-9]/gi, "-");
function getCachePath(branch) {
  const {
    BUILDKITE_BUILD_PATH: buildPath,
    BUILDKITE_REPO: repository,
    BUILDKITE_PULL_REQUEST_REPO: fork,
    BUILDKITE_BRANCH,
    BUILDKITE_STEP_KEY,
  } = process.env;

  // NOTE: settings that could be long should be truncated to avoid hitting max
  // path length limit on windows (4096)
  const repositoryKey = toAlphaNumeric(
    // remove domain name, only leaving 'org/repo'
    (fork || repository).replace(/^https?:\/\/github\.com\/?/, ""),
  );
  const branchName = toAlphaNumeric(branch || BUILDKITE_BRANCH);
  const branchKey = branchName.startsWith("gh-readonly-queue-")
    ? branchName.slice(18, branchName.indexOf("-pr-"))
    : branchName.slice(0, 32);
  const stepKey = toAlphaNumeric(BUILDKITE_STEP_KEY);
  return resolve(buildPath, "..", "cache", repositoryKey, branchKey, stepKey);
}

function isCacheReadEnabled() {
  return (
    isBuildkite() &&
    process.env.BUILDKITE_CLEAN_CHECKOUT !== "true" &&
    process.env.BUILDKITE_BRANCH !== getDefaultBranch()
  );
}

function isCacheWriteEnabled() {
  return isBuildkite();
}

function isBuildkite() {
  return process.env.BUILDKITE === "true";
}

function getDefaultBranch() {
  return process.env.BUILDKITE_PIPELINE_DEFAULT_BRANCH || "main";
}

function parseOptions(args, flags = []) {
  const options = {};

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    for (const [flag, type] of flags) {
      if (arg === flag) {
        if (type === "boolean") {
          options[arg] = undefined;
        } else {
          options[arg] = args[++i];
        }
      } else if (arg.startsWith(flag)) {
        const delim = arg.indexOf("=");
        if (delim === -1) {
          options[flag] = arg.slice(flag.length);
        } else {
          options[arg.slice(0, delim)] = arg.slice(delim + 1);
        }
      }
    }
  }

  return options;
}

async function spawn(command, args, options, label) {
  const effectiveArgs = args.filter(Boolean);
  const description = [command, ...effectiveArgs].map(arg => (arg.includes(" ") ? JSON.stringify(arg) : arg)).join(" ");
  console.log("$", description);

  label ??= basename(command);

  const pipe = process.env.CI === "true" && !(options?.stdio === "inherit");
  const subprocess = nodeSpawn(command, effectiveArgs, {
    stdio: pipe ? "pipe" : "inherit",
    ...options,
  });

  let timestamp;
  subprocess.on("spawn", () => {
    timestamp = Date.now();
  });

  let stdoutBuffer = "";

  let done;
  if (pipe && subprocess.stdout && subprocess.stderr) {
    const stdout = new Promise(resolve => {
      subprocess.stdout.on("end", resolve);
      subprocess.stdout.on("data", data => {
        stdoutBuffer += data.toString();
        process.stdout.write(data);
      });
    });

    const stderr = new Promise(resolve => {
      subprocess.stderr.on("end", resolve);
      subprocess.stderr.on("data", data => {
        stdoutBuffer += data.toString();
        process.stderr.write(data);
      });
    });

    done = Promise.all([stdout, stderr]);
  }

  const { error, exitCode, signalCode } = await new Promise(resolve => {
    subprocess.on("error", error => resolve({ error }));
    subprocess.on("exit", (exitCode, signalCode) => resolve({ exitCode, signalCode }));
  });

  if (done) {
    await done;
  }

  printDuration(label, Date.now() - timestamp);

  if (exitCode === 0) {
    return;
  }

  if (isBuildkite()) {
    let annotated;
    try {
      const { annotations } = parseAnnotations(stdoutBuffer);
      for (const annotation of annotations) {
        const content = formatAnnotationToHtml(annotation);
        reportAnnotationToBuildKite({
          priority: 10,
          label: annotation.title || annotation.filename,
          content,
        });
        annotated = true;
      }
    } catch (error) {
      console.error(`Failed to parse annotations:`, error);
    }

    if (!annotated) {
      const content = formatAnnotationToHtml({
        filename: relative(process.cwd(), import.meta.filename),
        title: "build failed",
        content: stdoutBuffer,
        source: "build",
        level: "error",
      });
      reportAnnotationToBuildKite({
        priority: 10,
        label: "build failed",
        content,
      });
    }
  }

  if (signalCode) {
    console.error(`Command killed: ${signalCode}`);
  } else {
    console.error(`Command exited: code ${exitCode}`);
  }

  process.exit(exitCode ?? 1);
}

function printDuration(label, duration) {
  if (duration > 60000) {
    console.log(`${label} took ${(duration / 60000).toFixed(2)} minutes`);
  } else {
    console.log(`${label} took ${(duration / 1000).toFixed(2)} seconds`);
  }
}

async function downloadBuildArtifacts() {
  // Set up persistent cache environment for ALL macOS build steps (not just linking)
  if (process.env.BUILDKITE_CACHE_TYPE === "persistent") {
    console.log("🔧 Setting up persistent cache environment for macOS build...");
    
    // Use workspace-relative cache path (will be copied to VM via rsync)
    const cacheBase = process.env.BUILDKITE_CACHE_BASE || "./buildkite-cache";
    
    // Set environment variables for CMake and build tools to use workspace cache
    process.env.ZIG_GLOBAL_CACHE_DIR = `${cacheBase}/zig/global`;
    process.env.ZIG_LOCAL_CACHE_DIR = `${cacheBase}/zig/local`;
    process.env.CCACHE_DIR = `${cacheBase}/ccache`;
    process.env.NPM_CONFIG_CACHE = `${cacheBase}/npm`;
    
    console.log("✅ Persistent cache environment configured:");
    console.log(`   Cache base path: ${cacheBase} (workspace-relative)`);
    console.log(`   ZIG_GLOBAL_CACHE_DIR=${process.env.ZIG_GLOBAL_CACHE_DIR}`);
    console.log(`   ZIG_LOCAL_CACHE_DIR=${process.env.ZIG_LOCAL_CACHE_DIR}`);
    console.log(`   CCACHE_DIR=${process.env.CCACHE_DIR}`);
    console.log(`   NPM_CONFIG_CACHE=${process.env.NPM_CONFIG_CACHE}`);
  }
  
  // Download build artifacts when BUN_LINK_ONLY=ON (linking step only)
  if (process.env.BUN_LINK_ONLY === "ON") {
    console.log("🔗 BUN_LINK_ONLY=ON detected - downloading artifacts from previous build steps");
    
    const buildPath = resolve("build", "release");
    
    // Create build directory if it doesn't exist
    if (!existsSync(buildPath)) {
      mkdirSync(buildPath, { recursive: true });
      console.log(`Created build directory: ${buildPath}`);
    }
    
    // Determine the target platform key for job names (e.g., "darwin-aarch64")
    // This should match the getTargetKey function in ci.mjs
    const os = process.platform === "darwin" ? "darwin" : process.platform === "win32" ? "windows" : "linux";
    const arch = process.arch === "arm64" ? "aarch64" : "x64";
    const targetKey = `${os}-${arch}`;
    
    const buildCppJob = `${targetKey}-build-cpp`;
    const buildZigJob = `${targetKey}-build-zig`;
    
    console.log(`Target platform: ${targetKey}`);
    console.log(`Build C++ job: ${buildCppJob}`);
    console.log(`Build Zig job: ${buildZigJob}`);
    
    // Download artifacts from previous build steps using buildkite-agent
    try {
      console.log("📥 Downloading libbun-profile.a from build-cpp step...");
      // Try downloading compressed version first, then uncompressed
      try {
        await spawn("buildkite-agent", ["artifact", "download", "--job", buildCppJob, "build/release/libbun-profile.a.gz", "."], {
          stdio: "inherit"
        });
        
        // If compressed version downloaded, decompress it
        const compressedPath = join(buildPath, "libbun-profile.a.gz");
        const uncompressedPath = join(buildPath, "libbun-profile.a");
        if (existsSync(compressedPath)) {
          console.log("🗜️  Decompressing libbun-profile.a.gz...");
          await spawn("gunzip", [compressedPath], { stdio: "inherit" });
          console.log("✅ Decompressed libbun-profile.a");
        }
      } catch (error) {
        console.log("Compressed version not found, trying uncompressed...");
        await spawn("buildkite-agent", ["artifact", "download", "--job", buildCppJob, "build/release/libbun-profile.a", "."], {
          stdio: "inherit"
        });
      }
      
      console.log("📥 Downloading bun-zig.o from build-zig step...");
      // Try downloading compressed version first, then uncompressed
      try {
        await spawn("buildkite-agent", ["artifact", "download", "--job", buildZigJob, "build/release/bun-zig.o.gz", "."], {
          stdio: "inherit"
        });
        
        // If compressed version downloaded, decompress it
        const compressedPath = join(buildPath, "bun-zig.o.gz");
        const uncompressedPath = join(buildPath, "bun-zig.o");
        if (existsSync(compressedPath)) {
          console.log("🗜️  Decompressing bun-zig.o.gz...");
          await spawn("gunzip", [compressedPath], { stdio: "inherit" });
          console.log("✅ Decompressed bun-zig.o");
        }
      } catch (error) {
        console.log("Compressed version not found, trying uncompressed...");
        await spawn("buildkite-agent", ["artifact", "download", "--job", buildZigJob, "build/release/bun-zig.o", "."], {
          stdio: "inherit"
        });
      }
      
      console.log("✅ Build artifacts downloaded successfully");
    } catch (error) {
      console.error("❌ Failed to download build artifacts:", error.message);
      console.error("Make sure build-cpp and build-zig steps completed successfully");
      process.exit(1);
    }
    
    // Verify artifacts exist after download
    const requiredArtifacts = [
      join(buildPath, "libbun-profile.a"),
      join(buildPath, "bun-zig.o"),
    ];
    
    const missingArtifacts = requiredArtifacts.filter(file => !existsSync(file));
    
    if (missingArtifacts.length > 0) {
      console.error("❌ Build artifacts still missing after download:");
      missingArtifacts.forEach(file => console.error(`   ${file}`));
      process.exit(1);
    }
    
    console.log("✅ All required artifacts verified");
  }
}

build(process.argv.slice(2));
