// Get the organization from the repository URL
const getOrgFromRepo = () => {
  const repo = process.env.BUILDKITE_REPO || '';
  const match = repo.match(/github\.com[:/]([^/]+)/);
  return match ? match[1] : 'oven-sh'; // fallback to oven-sh if we can't determine
};

export const IMAGE_CONFIG = {
  baseImage: {
    registry: "ghcr.io",
    organization: "build-archetype",
    name: "base-bun-build-macos-darwin",
    tag: "latest",
    get fullName() {
      return `${this.registry}/${this.organization}/${this.name}:${this.tag}`;
    }
  }
};

// Helper function to get the full image name
export function getFullImageName(name, tag = "latest") {
  // Use baseImage's registry and organization for consistency
  return `${IMAGE_CONFIG.baseImage.registry}/${IMAGE_CONFIG.baseImage.organization}/${name}:${tag}`;
} 