#!/bin/bash
set -euo pipefail

# This script triggers the base image build pipeline
# It is called by the bootstrap pipeline to ensure the base image is built and published

# Trigger the base image build pipeline
buildkite-agent pipeline upload .buildkite/base-bun-build-macos-darwin.yml 