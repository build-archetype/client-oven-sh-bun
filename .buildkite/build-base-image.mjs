#!/usr/bin/env node

import { toYaml, writeFile } from "../scripts/utils.mjs";
import { IMAGE_CONFIG } from "./config.mjs";
import { spawnSync } from "node:child_process";

const pipeline = [
  {
    label: "Build Base Image",
    key: "build-base-image",
    agents: {
      queue: "darwin",
      tart: true
    },
    command: [
      'echo "GITHUB_USERNAME:',
      'echo $GITHUB_USERNAME',
      'echo "GITHUB_TOKEN:',
      'echo $GITHUB_TOKEN',
      'bash -c "echo -e "$GITHUB_USERNAME\\n$GITHUB_TOKEN" | tart login ghcr.io 2>&1 | tee -a base-image-build.log; LOGIN_EXIT_CODE=${PIPESTATUS[1]:-${PIPESTATUS[0]}}; if [ $LOGIN_EXIT_CODE -ne 0 ]; then echo "$tart login failed with exit code $LOGIN_EXIT_CODE" | tee -a base-image-build.log; exit $LOGIN_EXIT_CODE; fi"',
      "chmod +x .buildkite/scripts/ensure-bun-image.sh",
      ".buildkite/scripts/ensure-bun-image.sh 2>&1 | tee -a base-image-build.log",
      // After successful build, push to container registry
      `tart push ${IMAGE_CONFIG.baseImage.name} ${IMAGE_CONFIG.baseImage.fullName}`
    ],
    retry: {
      automatic: [
        { exit_status: 1, limit: 2 },
        { exit_status: -1, limit: 1 },
        { exit_status: 255, limit: 1 }
      ]
    },
    artifact_paths: ["base-image-build.log"]
  }
];

// Write the pipeline to a file
const content = toYaml(pipeline);
const contentPath = ".buildkite/base-image-pipeline.yml";
writeFile(contentPath, content);

console.log("Generated base image pipeline:");
console.log(" - Path:", contentPath);
console.log(" - Size:", (content.length / 1024).toFixed(), "KB");

// Upload the pipeline YAML as an artifact
spawnSync("buildkite-agent", ["artifact", "upload", contentPath], { stdio: "inherit" });

spawnSync("buildkite-agent", ["pipeline", "upload", contentPath], { stdio: "inherit" }); 