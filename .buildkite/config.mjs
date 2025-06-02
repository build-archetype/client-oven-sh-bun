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
    repository: "client-oven-sh-bun",
    name: "bun-build-macos",
    tag: "latest",
    get fullName() {
      return `${this.registry}/${this.organization}/${this.repository}/${this.name}:${this.tag}`;
    }
  },
  sourceImage: {
    registry: "ghcr.io",
    organization: "cirruslabs",
    name: "macos-sequoia-base",
    tag: "latest",
    get fullName() {
      return `${this.registry}/${this.organization}/${this.name}:${this.tag}`;
    }
  }
};

// Helper function to get the full image name
export function getFullImageName(name, tag = "latest") {
  // Use baseImage's registry and organization for consistency
  return `${IMAGE_CONFIG.baseImage.registry}/${IMAGE_CONFIG.baseImage.organization}/${IMAGE_CONFIG.baseImage.repository}/${name}:${tag}`;
} 