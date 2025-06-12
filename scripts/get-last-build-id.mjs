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
 */

import { getLastSuccessfulBuild, isBuildkite, getEnv, getBranch, curlSafe } from "./utils.mjs";

/**
 * Check if a build has cache artifacts uploaded
 * @param {string} buildId - Build ID to check
 * @param {string} orgSlug - Organization slug
 * @param {string} pipelineSlug - Pipeline slug
 * @returns {Promise<boolean>} - True if build has cache artifacts
 */
async function buildHasCacheArtifacts(buildId, orgSlug, pipelineSlug) {
  try {
    // Get build details using REST API
    const buildUrl = `https://api.buildkite.com/v2/organizations/${orgSlug}/pipelines/${pipelineSlug}/builds/${buildId}`;
    const buildResponse = await curlSafe(buildUrl, { json: true });
    
    if (!buildResponse || !buildResponse.jobs) {
      return false;
    }

    // Look for jobs that should have cache artifacts
    const cacheUploadSteps = buildResponse.jobs.filter(job => 
      job.step_key && 
      (job.step_key.includes("build-cpp") || job.step_key.includes("build-zig")) &&
      job.state === "passed"
    );

    if (cacheUploadSteps.length === 0) {
      return false;
    }

    // Check if any of these jobs have cache artifacts using REST API
    const cacheArtifactNames = ["ccache-cache.tar.gz", "zig-local-cache.tar.gz", "zig-global-cache.tar.gz"];
    
    for (const job of cacheUploadSteps) {
      const artifactsUrl = `https://api.buildkite.com/v2/organizations/${orgSlug}/pipelines/${pipelineSlug}/builds/${buildId}/jobs/${job.id}/artifacts`;
      
      try {
        const artifactsResponse = await curlSafe(artifactsUrl, { json: true });
        
        if (artifactsResponse && Array.isArray(artifactsResponse)) {
          const hasCache = artifactsResponse.some(artifact => 
            cacheArtifactNames.includes(artifact.filename || artifact.file_name || artifact.path)
          );
          
          if (hasCache) {
            console.error(`Found cache artifacts in build ${buildId}, job ${job.step_key}`);
            return true;
          }
        }
      } catch (error) {
        // Continue checking other jobs if one fails
        console.error(`Failed to check artifacts for job ${job.id}: ${error.message}`);
      }
    }
    
    return false;
  } catch (error) {
    console.error(`Failed to check build ${buildId} for cache artifacts: ${error.message}`);
    return false;
  }
}

/**
 * Find the last build with actual cache artifacts (not just "successful")
 * @param {string} orgSlug - Organization slug  
 * @param {string} pipelineSlug - Pipeline slug
 * @param {string} branch - Branch to search
 * @returns {Promise<object|undefined>} - Build object with cache artifacts
 */
async function getLastBuildWithCache(orgSlug, pipelineSlug, branch = "main") {
  try {
    // Get current build ID to exclude it from search
    const currentBuildId = getEnv("BUILDKITE_BUILD_ID", false);
    console.error(`Current build ID: ${currentBuildId} (will be excluded from cache search)`);
    
    // Get recent builds on the branch using REST API - include ALL builds, not just successful ones
    // Cache validity depends on build step success, not overall build success
    const buildsUrl = `https://api.buildkite.com/v2/organizations/${orgSlug}/pipelines/${pipelineSlug}/builds?branch=${branch}&per_page=20`;
    const buildsResponse = await curlSafe(buildsUrl, { json: true });
    
    if (!buildsResponse || !Array.isArray(buildsResponse)) {
      return undefined;
    }

    // Check each recent build for cache artifacts (excluding current build)
    for (const build of buildsResponse) {
      if (build.id || build.number) {
        // Use build number for artifact checking (consistent with other API usage)
        const buildId = build.number || build.id;
        
        // Skip the current build - we can't download cache from ourselves!
        if (currentBuildId && (build.id === currentBuildId || build.number?.toString() === currentBuildId)) {
          console.error(`Skipping current build ${buildId} (can't download cache from running build)`);
          continue;
        }
        
        // Check for cache regardless of overall build state
        // What matters is whether the cache-generating steps succeeded
        console.error(`Checking build ${buildId} (state: ${build.state}) for cache artifacts...`);
        
        if (await buildHasCacheArtifacts(buildId, orgSlug, pipelineSlug)) {
          return build;
        }
      }
    }
    
    return undefined;
  } catch (error) {
    console.error(`Error searching for builds with cache: ${error.message}`);
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

    let build;
    if (branchMode === "main") {
      console.error(`Searching for last build with cache artifacts on main branch`);
      const orgSlug = getEnv("BUILDKITE_ORGANIZATION_SLUG", false) || "bun";
      const pipelineSlug = getEnv("BUILDKITE_PIPELINE_SLUG", false) || "bun";
      build = await getLastBuildWithCache(orgSlug, pipelineSlug, "main");
    } else {
      // Use the existing utility function for current branch
      const currentBranch = getBranch() || getEnv("BUILDKITE_BRANCH", false) || "unknown";
      console.error(`Searching for last build with cache artifacts on current branch: ${currentBranch}`);
      
      const orgSlug = getEnv("BUILDKITE_ORGANIZATION_SLUG", false) || "bun";
      const pipelineSlug = getEnv("BUILDKITE_PIPELINE_SLUG", false) || "bun";
      build = await getLastBuildWithCache(orgSlug, pipelineSlug, currentBranch);
      
      // If no cache found on current branch, try main branch as fallback
      if (!build && currentBranch !== "main") {
        console.error(`No cache found on ${currentBranch}, trying main branch as fallback...`);
        build = await getLastBuildWithCache(orgSlug, pipelineSlug, "main");
      }
    }
    
    if (build && build.id) {
      console.error(`Found build with cache artifacts: ${build.id} (${build.commit_id?.slice(0, 8)}) [overall state: ${build.state}]`);
      // Output just the build ID for CMake to capture
      console.log(build.id);
      process.exit(0);
    } else {
      const target = branchMode === "main" ? "main branch" : "current branch";
      console.error(`No build with cache artifacts found on ${target}`);
      process.exit(1);
    }
  } catch (error) {
    // Error occurred during search
    console.error(`Error finding last build with cache: ${error.message}`);
    process.exit(1);
  }
}

await main(); 