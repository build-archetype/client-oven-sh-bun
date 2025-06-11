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
 * Find the last successful build on main branch specifically
 * @returns {Promise<object|undefined>} - Build object with id, or undefined if not found
 */
async function getLastSuccessfulBuildOnMain() {
  if (!isBuildkite) {
    return undefined;
  }

  const orgSlug = getEnv("BUILDKITE_ORGANIZATION_SLUG", false) || "bun";
  const pipelineSlug = getEnv("BUILDKITE_PIPELINE_SLUG", false) || "bun";
  
  // Search for builds on main branch
  const buildsUrl = `https://buildkite.com/${orgSlug}/${pipelineSlug}/builds?branch=main&state=passed&state=failed&state=canceled`;
  
  try {
    const response = await curlSafe(buildsUrl, { json: true });
    
    if (!response || !Array.isArray(response)) {
      return undefined;
    }

    // Look through recent builds on main branch
    for (const build of response) {
      const { state, steps, id } = build;
      
      // Only consider finished builds
      if (state !== "passed" && state !== "failed" && state !== "canceled") {
        continue;
      }
      
      // Check if this build has successful build-bun steps
      const buildSteps = steps.filter(({ label }) => label && label.endsWith("build-bun"));
      if (buildSteps.length > 0) {
        if (buildSteps.every(({ outcome }) => outcome === "passed")) {
          return build; // Found a successful build
        }
      }
    }
  } catch (error) {
    console.error(`Error searching builds on main branch:`, error.message);
  }
  
  return undefined;
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
        build = await getLastSuccessfulBuildOnMain();
      } else {
        // TODO: Implement getLastBuildOnMain() for any-state mode
        console.error("--any-state with main branch not yet implemented, falling back to successful builds");
        build = await getLastSuccessfulBuildOnMain();
      }
    } else {
      // Use the existing utility function for current branch
      const currentBranch = getBranch() || getEnv("BUILDKITE_BRANCH", false) || "unknown";
      const successText = requireSuccess ? "successful" : "latest";
      console.error(`Searching for last ${successText} build on current branch: ${currentBranch}`);
      
      if (requireSuccess) {
        build = await getLastSuccessfulBuild();
      } else {
        // For scope reduction: just get the last build regardless of state
        // TODO: Implement getLastBuild() or modify existing function
        console.error("--any-state mode not yet implemented, falling back to successful builds");
        build = await getLastSuccessfulBuild();
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