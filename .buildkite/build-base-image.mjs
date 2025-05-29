#!/usr/bin/env node

import { toYaml, writeFile } from "../scripts/utils.mjs";
import { IMAGE_CONFIG } from "./config.mjs";
import { spawnSync } from "node:child_process";

const pipeline = {
  steps: [
    {
      label: "Build Base Image",
      key: "build-base-image",
      agents: {
        queue: "darwin",
        tart: true
      },
      command: [
        "echo \"$GITHUB_TOKEN\" | tart login ghcr.io --password-stdin",
        "chmod +x .buildkite/scripts/ensure-bun-image.sh",
        // Ensure we capture all output and preserve timestamps
        "set -x",
        ".buildkite/scripts/ensure-bun-image.sh 2>&1 | tee -a base-image-build.log",
        // After successful build, push to container registry
        `echo \"$GITHUB_TOKEN\" | tart push ${IMAGE_CONFIG.baseImage.name} ${IMAGE_CONFIG.baseImage.fullName} --password-stdin`
      ],
      retry: {
        automatic: [
          { exit_status: 1, limit: 2 },
          { exit_status: -1, limit: 1 },
          { exit_status: 255, limit: 1 }
        ]
      },
      artifact_paths: [
        "base-image-build.log",
        ".buildkite/base-image-pipeline.yml"
      ],
      soft_fail: false,
      timeout_in_minutes: 30
    }
  ]
};

// Write the pipeline to a file
const content = toYaml(pipeline);
const contentPath = ".buildkite/base-image-pipeline.yml";
writeFile(contentPath, content);

console.log("Generated base image pipeline:");
console.log(" - Path:", contentPath);
console.log(" - Size:", (content.length / 1024).toFixed(), "KB");

// Upload the pipeline YAML as an artifact
spawnSync("buildkite-agent", ["artifact", "upload", contentPath], { stdio: "inherit" });

// Upload the pipeline
spawnSync("buildkite-agent", ["pipeline", "upload", contentPath], { stdio: "inherit" }); 