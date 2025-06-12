#!/usr/bin/env node

/**
 * Helper script to get the last successful build ID for cache restoration
 * Used by CMake when BUILDKITE_BUILD_ID is not provided
 * 
 * Usage:
 *   node get-last-build-id.mjs [--branch=main|current]
 *   
 * Default: --branch=current (searches current branch using existing utils)
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
    // Get build details
    const buildUrl = `https://buildkite.com/${orgSlug}/${pipelineSlug}/builds/${buildId}.json`;
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

    // Check if any of these jobs have cache artifacts
    const cacheArtifactNames = ["ccache-cache.tar.gz", "zig-local-cache.tar.gz", "zig-global-cache.tar.gz"];
    
    for (const job of cacheUploadSteps) {
      const artifactsUrl = `https://buildkite.com/organizations/${orgSlug}/pipelines/${pipelineSlug}/builds/${buildId}/jobs/${job.id}/artifacts.json`;
      
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
    // Get recent builds on the branch
    const buildsUrl = `https://buildkite.com/${orgSlug}/${pipelineSlug}/builds?branch=${branch}&state=passed&per_page=10`;
    const buildsResponse = await curlSafe(buildsUrl, { json: true });
    
    if (!buildsResponse || !Array.isArray(buildsResponse)) {
      return undefined;
    }

    // Check each recent build for cache artifacts
    for (const build of buildsResponse) {
      if (build.state === "passed" && build.id) {
        console.error(`Checking build ${build.id} for cache artifacts...`);
        
        if (await buildHasCacheArtifacts(build.id, orgSlug, pipelineSlug)) {
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
    let requireSuccess = true; // Default to requiring successful builds
    
    for (const arg of args) {
      if (arg.startsWith("--branch=")) {
        branchMode = arg.split("=")[1];
        if (branchMode !== "main" && branchMode !== "current") {
          console.error("Invalid branch mode. Use --branch=main or --branch=current");
          process.exit(1);
        }
      } else if (arg === "--any-state") {
        requireSuccess = false; // Allow any build state (for scope reduction)
      } else if (arg === "--help" || arg === "-h") {
        console.log("Usage: node get-last-build-id.mjs [--branch=main|current] [--any-state]");
        console.log("Default: --branch=current (searches current branch)");
        console.log("--any-state: Accept builds regardless of success/failure (scope reduction)");
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
      const successText = requireSuccess ? "successful" : "latest";
      console.error(`Searching for last ${successText} build on main branch`);
      if (requireSuccess) {
        const orgSlug = getEnv("BUILDKITE_ORGANIZATION_SLUG", false) || "bun";
        const pipelineSlug = getEnv("BUILDKITE_PIPELINE_SLUG", false) || "bun";
        build = await getLastBuildWithCache(orgSlug, pipelineSlug, "main");
      } else {
        // TODO: Implement getLastBuildOnMain() for any-state mode
        console.error("--any-state with main branch not yet implemented, falling back to successful builds");
        const orgSlug = getEnv("BUILDKITE_ORGANIZATION_SLUG", false) || "bun";
        const pipelineSlug = getEnv("BUILDKITE_PIPELINE_SLUG", false) || "bun";
        build = await getLastBuildWithCache(orgSlug, pipelineSlug, "main");
      }
    } else {
      // Use the existing utility function for current branch
      const currentBranch = getBranch() || getEnv("BUILDKITE_BRANCH", false) || "unknown";
      const successText = requireSuccess ? "successful" : "latest";
      console.error(`Searching for last ${successText} build on current branch: ${currentBranch}`);
      
      if (requireSuccess) {
        // Use our improved cache-aware build detection instead of the flawed getLastSuccessfulBuild
        const orgSlug = getEnv("BUILDKITE_ORGANIZATION_SLUG", false) || "bun";
        const pipelineSlug = getEnv("BUILDKITE_PIPELINE_SLUG", false) || "bun";
        build = await getLastBuildWithCache(orgSlug, pipelineSlug, currentBranch);
      } else {
        // For scope reduction: just get the last build regardless of state
        // TODO: Implement getLastBuild() or modify existing function
        console.error("--any-state mode not yet implemented, falling back to successful builds");
        const orgSlug = getEnv("BUILDKITE_ORGANIZATION_SLUG", false) || "bun";
        const pipelineSlug = getEnv("BUILDKITE_PIPELINE_SLUG", false) || "bun";
        build = await getLastBuildWithCache(orgSlug, pipelineSlug, currentBranch);
      }
    }
    
    if (build && build.id) {
      const stateText = requireSuccess ? "successful" : "found";
      console.error(`Found ${stateText} build: ${build.id} (${build.commit_id?.slice(0, 8)})`);
      // Output just the build ID for CMake to capture
      console.log(build.id);
      process.exit(0);
    } else {
      const target = branchMode === "main" ? "main branch" : "current branch";
      const stateText = requireSuccess ? "successful" : "any";
      console.error(`No suitable ${stateText} build found on ${target}`);
      process.exit(1);
    }
  } catch (error) {
    // Error occurred during search
    console.error(`Error finding last successful build: ${error.message}`);
    process.exit(1);
  }
}

await main(); 