#!/usr/bin/env node

/**
 * Helper script to get the last successful build ID for cache restoration
 * Used by CMake when BUILDKITE_BUILD_ID is not provided
 * 
 * Usage:
 *   node get-last-build-id.mjs [--branch=main|current]
 *   
 * Default: --branch=current (searches current branch)
 */

import { getLastSuccessfulBuild, isBuildkite, getEnv, getBranch, curlSafe } from "./utils.mjs";

/**
 * Find the last successful build on a specific branch
 * @param {string} targetBranch - The branch to search (e.g., "main", "feat/my-feature")
 * @returns {Promise<object|undefined>} - Build object with id, or undefined if not found
 */
async function getLastSuccessfulBuildOnBranch(targetBranch) {
  if (!isBuildkite) {
    return undefined;
  }

  const orgSlug = getEnv("BUILDKITE_ORGANIZATION_SLUG", false) || "bun";
  const pipelineSlug = getEnv("BUILDKITE_PIPELINE_SLUG", false) || "bun";
  
  // Search for builds on the target branch
  const buildsUrl = `https://buildkite.com/${orgSlug}/${pipelineSlug}/builds?branch=${encodeURIComponent(targetBranch)}&state=passed&state=failed&state=canceled`;
  
  try {
    const response = await curlSafe(buildsUrl, { json: true });
    
    if (!response || !Array.isArray(response)) {
      return undefined;
    }

    // Look through recent builds on this branch
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
    console.error(`Error searching builds on branch ${targetBranch}:`, error.message);
  }
  
  return undefined;
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
        process.exit(0);
      }
    }

    // Check if we're in a Buildkite environment
    if (!isBuildkite) {
      console.error("Not running in Buildkite environment - cache restoration not available");
      process.exit(1);
    }

    // Determine target branch
    let targetBranch;
    if (branchMode === "main") {
      targetBranch = "main";
    } else {
      // Use current branch
      targetBranch = getBranch() || getEnv("BUILDKITE_BRANCH", false);
      if (!targetBranch) {
        console.error("Could not determine current branch");
        process.exit(1);
      }
    }

    console.error(`Searching for last successful build on branch: ${targetBranch}`);

    // Search for successful build on the target branch
    const build = await getLastSuccessfulBuildOnBranch(targetBranch);
    
    if (build && build.id) {
      console.error(`Found successful build: ${build.id} (${build.commit_id?.slice(0, 8)})`);
      // Output just the build ID for CMake to capture
      console.log(build.id);
      process.exit(0);
    } else {
      console.error(`No suitable successful build found on branch: ${targetBranch}`);
      process.exit(1);
    }
  } catch (error) {
    // Error occurred during search
    console.error(`Error finding last successful build: ${error.message}`);
    process.exit(1);
  }
}

await main(); 