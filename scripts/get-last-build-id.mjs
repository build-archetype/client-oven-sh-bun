#!/usr/bin/env node

/**
 * Helper script to get the last build with cache artifacts for cache restoration
 * Used by CMake when BUILDKITE_BUILD_ID is not provided
 *
 * Searches for builds where cache-generating steps (build-cpp, build-zig) succeeded
 * and uploaded cache artifacts, regardless of overall build success.
 * This is because compilation cache validity is independent of test results.
 *
 * Usage:
 *   node get-last-build-id.mjs [--branch=main|current]
 *
 * Default: --branch=current (searches current branch for cache artifacts)
 *
 * Version: Enhanced with detailed logging for transparent cache detection
 */

import { curlSafe, getBranch, getEnv, isBuildkite } from "./utils.mjs";

/**
 * Check if a build has cache artifacts uploaded for the specific build step type
 * @param {string} buildId - Build ID to check
 * @param {string} orgSlug - Organization slug
 * @param {string} pipelineSlug - Pipeline slug
 * @param {string[]} neededCacheTypes - Array of cache artifact names needed (e.g., ["ccache-cache.tar.gz"])
 * @returns {Promise<boolean>} - True if build has the needed cache artifacts
 */
async function buildHasCacheArtifacts(buildId, orgSlug, pipelineSlug, neededCacheTypes = []) {
  try {
    console.error(`    🔍 Checking build ${buildId} for cache artifacts: ${neededCacheTypes.join(", ")}`);

    // Get build details using REST API
    const buildUrl = `https://api.buildkite.com/v2/organizations/${orgSlug}/pipelines/${pipelineSlug}/builds/${buildId}`;
    const buildResponse = await curlSafe(buildUrl, { json: true });

    if (!buildResponse || !buildResponse.jobs) {
      console.error(`    ❌ Build ${buildId}: No jobs data available`);
      return false;
    }

    console.error(`    📋 Build ${buildId}: Found ${buildResponse.jobs.length} jobs`);

    // Look for jobs that should have cache artifacts
    const cacheUploadSteps = buildResponse.jobs.filter(
      job =>
        job.step_key &&
        (job.step_key.includes("build-cpp") || job.step_key.includes("build-zig")) &&
        job.state === "passed",
    );

    if (cacheUploadSteps.length === 0) {
      const relevantJobs = buildResponse.jobs.filter(
        job => job.step_key && (job.step_key.includes("build-cpp") || job.step_key.includes("build-zig")),
      );

      if (relevantJobs.length === 0) {
        console.error(`    ❌ Build ${buildId}: No cache-generating jobs found (build-cpp/build-zig)`);
      } else {
        console.error(`    ❌ Build ${buildId}: Found ${relevantJobs.length} cache-generating jobs, but none passed:`);
        relevantJobs.forEach(job => {
          console.error(`      - ${job.step_key}: ${job.state}`);
        });
      }
      return false;
    }

    console.error(`    ✅ Build ${buildId}: Found ${cacheUploadSteps.length} passed cache-generating steps:`);
    cacheUploadSteps.forEach(job => {
      console.error(`      - ${job.step_key}: ${job.state}`);
    });

    // Check if any of these jobs have the specific cache artifacts we need
    const foundCacheTypes = new Set();

    for (const job of cacheUploadSteps) {
      console.error(`    🔎 Checking artifacts for job: ${job.step_key} (id: ${job.id})`);
      const artifactsUrl = `https://api.buildkite.com/v2/organizations/${orgSlug}/pipelines/${pipelineSlug}/builds/${buildId}/jobs/${job.id}/artifacts`;

      try {
        const artifactsResponse = await curlSafe(artifactsUrl, { json: true });

        if (artifactsResponse && Array.isArray(artifactsResponse)) {
          console.error(`    📦 Job ${job.step_key}: Found ${artifactsResponse.length} artifacts`);

          // Check which needed cache types are present
          for (const artifact of artifactsResponse) {
            const filename = artifact.filename || artifact.file_name || artifact.path;
            if (neededCacheTypes.includes(filename)) {
              // Verify the artifact has actual size (not empty or too small)
              const fileSize = artifact.file_size || artifact.size || 0;
              if (fileSize > 1024) {
                // Minimum 1KB for meaningful cache content
                foundCacheTypes.add(filename);
                console.error(`    ✅ Job ${job.step_key}: Found ${filename} (${fileSize} bytes)`);
              } else {
                console.error(
                  `    ⚠️  Job ${job.step_key}: Found ${filename} but it's too small (${fileSize} bytes, need >1024)`,
                );
              }
            }
          }

          if (foundCacheTypes.size === 0) {
            const allArtifacts = artifactsResponse.map(a => a.filename || a.file_name || a.path).join(", ");
            console.error(`    ❌ Job ${job.step_key}: No needed cache artifacts found (has: ${allArtifacts})`);
          }
        } else {
          console.error(`    ❌ Job ${job.step_key}: Invalid artifacts response`);
        }
      } catch (error) {
        // Continue checking other jobs if one fails
        console.error(`    💥 Job ${job.step_key}: Failed to check artifacts - ${error.message}`);
      }
    }

    // Check if we found all needed cache types
    if (foundCacheTypes.size > 0) {
      const found = Array.from(foundCacheTypes);
      const missing = neededCacheTypes.filter(cache => !foundCacheTypes.has(cache));

      if (missing.length === 0) {
        console.error(`    ✅ Build ${buildId}: Found ALL needed cache artifacts: ${found.join(", ")}`);
        return true;
      } else {
        console.error(
          `    ⚠️  Build ${buildId}: Found SOME cache artifacts: ${found.join(", ")}, missing: ${missing.join(", ")}`,
        );
        // For now, accept partial cache (better than no cache)
        return true;
      }
    }

    console.error(`    ❌ Build ${buildId}: No needed cache artifacts found`);
    return false;
  } catch (error) {
    console.error(`    💥 Build ${buildId}: Failed to check for cache artifacts - ${error.message}`);
    return false;
  }
}

/**
 * Determine which cache types are needed based on current build step
 * @returns {string[]} Array of cache artifact names needed
 */
function getNeededCacheTypes() {
  const bunCppOnly = getEnv("BUN_CPP_ONLY", false) === "ON" || getEnv("BUN_CPP_ONLY", false) === "1";
  const bunLinkOnly = getEnv("BUN_LINK_ONLY", false) === "ON" || getEnv("BUN_LINK_ONLY", false) === "1";

  let needed = [];

  if (bunCppOnly) {
    // C++ step needs ccache
    needed.push("ccache-cache.tar.gz");
    console.error(`🎯 C++ build step detected - looking for: ccache-cache.tar.gz`);
  } else if (!bunLinkOnly) {
    // Zig step needs zig caches
    needed.push("zig-local-cache.tar.gz", "zig-global-cache.tar.gz");
    console.error(`🎯 Zig build step detected - looking for: zig-local-cache.tar.gz, zig-global-cache.tar.gz`);
  } else {
    // Link step - accept any cache type for maximum benefit
    needed.push("ccache-cache.tar.gz", "zig-local-cache.tar.gz", "zig-global-cache.tar.gz");
    console.error(`🎯 Link step detected - looking for any available cache`);
  }

  return needed;
}

/**
 * Find the last build with actual cache artifacts (not just "successful")
 * @param {string} orgSlug - Organization slug
 * @param {string} pipelineSlug - Pipeline slug
 * @param {string} branch - Branch to search
 * @param {string[]} neededCacheTypes - Array of cache artifact names needed
 * @returns {Promise<object|undefined>} - Build object with cache artifacts
 */
async function getLastBuildWithCache(orgSlug, pipelineSlug, branch = "main", neededCacheTypes = []) {
  try {
    // Get current build ID to exclude it from search
    const currentBuildId = getEnv("BUILDKITE_BUILD_ID", false);
    console.error(`🔍 Searching for cache artifacts on branch: ${branch}`);
    console.error(`📋 Current build ID: ${currentBuildId} (will be excluded from cache search)`);

    // Get recent builds on the branch using REST API - include ALL builds, not just successful ones
    // Cache validity depends on build step success, not overall build success
    const buildsUrl = `https://api.buildkite.com/v2/organizations/${orgSlug}/pipelines/${pipelineSlug}/builds?branch=${branch}&per_page=20`;
    console.error(`🌐 API URL: ${buildsUrl}`);

    const buildsResponse = await curlSafe(buildsUrl, { json: true });

    if (!buildsResponse || !Array.isArray(buildsResponse)) {
      console.error(`❌ Invalid response from builds API: ${typeof buildsResponse}`);
      return undefined;
    }

    console.error(`📊 Found ${buildsResponse.length} recent builds on branch '${branch}'`);

    // Check each recent build for cache artifacts (excluding current build)
    let checkedCount = 0;
    let skippedCount = 0;

    for (const build of buildsResponse) {
      if (build.id || build.number) {
        // Use build number for artifact checking (consistent with other API usage)
        const buildId = build.number || build.id;
        const shortCommit = build.commit?.substring(0, 8) || "unknown";

        // Skip the current build - we can't download cache from ourselves!
        if (currentBuildId && (build.id === currentBuildId || build.number?.toString() === currentBuildId)) {
          console.error(
            `⏭️  Skipping current build ${buildId} (${shortCommit}) - can't download cache from running build`,
          );
          skippedCount++;
          continue;
        }

        // Check for cache regardless of overall build state
        // What matters is whether the cache-generating steps succeeded
        console.error(
          `🔎 Checking build ${buildId} (${shortCommit}) - state: ${build.state}, created: ${build.created_at}`,
        );
        checkedCount++;

        if (await buildHasCacheArtifacts(buildId, orgSlug, pipelineSlug, neededCacheTypes)) {
          console.error(`✅ Found build with cache artifacts: ${buildId} (${shortCommit})`);
          console.error(
            `📈 Search summary: checked ${checkedCount} builds, skipped ${skippedCount} builds on branch '${branch}'`,
          );
          return build;
        } else {
          console.error(`❌ Build ${buildId} (${shortCommit}) has no needed cache artifacts`);
        }
      } else {
        console.error(`⚠️  Skipping malformed build entry: ${JSON.stringify(build)}`);
        skippedCount++;
      }
    }

    console.error(
      `📈 Search complete: checked ${checkedCount} builds, skipped ${skippedCount} builds on branch '${branch}'`,
    );
    console.error(`❌ No builds with needed cache artifacts found on branch '${branch}'`);
    return undefined;
  } catch (error) {
    console.error(`💥 Error searching for builds with cache on branch '${branch}': ${error.message}`);
    return undefined;
  }
}

async function main() {
  try {
    // Parse command line arguments
    const args = process.argv.slice(2);
    let branchMode = "current"; // Default to current branch

    for (const arg of args) {
      if (arg.startsWith("--branch=")) {
        branchMode = arg.split("=")[1];
        if (branchMode !== "main" && branchMode !== "current") {
          console.error("Invalid branch mode. Use --branch=main or --branch=current");
          process.exit(1);
        }
      } else if (arg === "--help" || arg === "-h") {
        console.log("Usage: node get-last-build-id.mjs [--branch=main|current]");
        console.log("Default: --branch=current (searches current branch)");
        console.log("Searches for builds where cache-generating steps succeeded, regardless of overall build state.");
        process.exit(0);
      }
    }

    // Check if we're in a Buildkite environment
    if (!isBuildkite) {
      console.error("Not running in Buildkite environment - cache restoration not available");
      process.exit(1);
    }

    console.error("🚀 Starting cache artifact search...");
    console.error(
      `🎯 Search strategy: ${branchMode === "main" ? "main branch only" : "current branch with main fallback"}`,
    );

    const orgSlug = getEnv("BUILDKITE_ORGANIZATION_SLUG", false) || "bun";
    const pipelineSlug = getEnv("BUILDKITE_PIPELINE_SLUG", false) || "bun";
    console.error(`🏢 Organization: ${orgSlug}`);
    console.error(`🔧 Pipeline: ${pipelineSlug}`);

    // Determine what cache types we need
    const neededCacheTypes = getNeededCacheTypes();

    let build;
    if (branchMode === "main") {
      console.error(`📋 Searching main branch for cache artifacts...`);
      build = await getLastBuildWithCache(orgSlug, pipelineSlug, "main", neededCacheTypes);
    } else {
      // Use the existing utility function for current branch
      const currentBranch = getBranch() || getEnv("BUILDKITE_BRANCH", false) || "unknown";
      console.error(`📋 Step 1: Searching current branch '${currentBranch}' for cache artifacts...`);

      build = await getLastBuildWithCache(orgSlug, pipelineSlug, currentBranch, neededCacheTypes);

      // If no cache found on current branch, try main branch as fallback
      if (!build && currentBranch !== "main") {
        console.error(`🔄 Step 2: No cache found on '${currentBranch}', falling back to main branch...`);
        console.error(`📋 Searching main branch for cache artifacts...`);
        build = await getLastBuildWithCache(orgSlug, pipelineSlug, "main", neededCacheTypes);

        if (build) {
          console.error(`✅ Fallback successful: Found cache artifacts on main branch`);
        } else {
          console.error(`❌ Fallback failed: No cache artifacts found on main branch either`);
        }
      } else if (currentBranch === "main") {
        console.error(`📋 Current branch is main - no fallback needed`);
      }
    }

    if (build && build.id) {
      const shortCommit = build.commit?.substring(0, 8) || "unknown";
      console.error(`🎉 SUCCESS: Found build with cache artifacts!`);
      console.error(`📊 Build details:`);
      console.error(`   - Build ID: ${build.id}`);
      console.error(`   - Commit: ${shortCommit}`);
      console.error(`   - Branch: ${build.branch}`);
      console.error(`   - State: ${build.state}`);
      console.error(`   - Created: ${build.created_at}`);
      console.error(`   - URL: ${build.web_url}`);

      // Output just the build ID for CMake to capture
      console.log(build.id);
      process.exit(0);
    } else {
      const searchTarget = branchMode === "main" ? "main branch" : `current branch with main fallback`;
      console.error(`💔 FAILURE: No build with cache artifacts found using strategy: ${searchTarget}`);
      console.error(`🔧 This means either:`);
      console.error(`   - No previous builds have uploaded cache artifacts yet`);
      console.error(`   - Previous builds failed during cache-generating steps`);
      console.error(`   - Cache artifacts were not properly uploaded`);
      console.error(`   - API authentication issues (check BUN_CACHE_API_TOKEN secret)`);
      process.exit(1);
    }
  } catch (error) {
    // Error occurred during search
    console.error(`💥 FATAL ERROR during cache search: ${error.message}`);
    console.error(`Stack trace: ${error.stack}`);
    process.exit(1);
  }
}

await main();
