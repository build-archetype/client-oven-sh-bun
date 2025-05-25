export const IMAGE_CONFIG = {
  registry: "ghcr.io",
  organization: "oven-sh",
  baseImage: {
    name: "base-bun-build-macos-darwin",
    tag: "latest",
    fullName: "ghcr.io/oven-sh/base-bun-build-macos-darwin:latest"
  }
};

// Helper function to get the full image name
export function getFullImageName(name, tag = "latest") {
  return `${IMAGE_CONFIG.registry}/${IMAGE_CONFIG.organization}/${name}:${tag}`;
} 