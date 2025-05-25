#!/usr/bin/env node

import { toYaml, writeFile } from "../scripts/utils.mjs";
import { IMAGE_CONFIG } from "./config.mjs";

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
        // Login to GitHub Container Registry
        "echo $GITHUB_TOKEN | tart login ghcr.io",
        "chmod +x .buildkite/scripts/ensure-bun-image.sh",
        ".buildkite/scripts/ensure-bun-image.sh",
        // After successful build, push to container registry
        `tart push ${IMAGE_CONFIG.baseImage.name} ${IMAGE_CONFIG.baseImage.fullName}`
      ],
      retry: {
        automatic: [
          { exit_status: 1, limit: 2 },
          { exit_status: -1, limit: 1 },
          { exit_status: 255, limit: 1 }
        ]
      }
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