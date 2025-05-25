// Get the organization from the repository URL
const getOrgFromRepo = () => {
  const repo = process.env.BUILDKITE_REPO || '';
  const match = repo.match(/github\.com[:/]([^/]+)/);
  return match ? match[1] : 'oven-sh'; // fallback to oven-sh if we can't determine
};

export const IMAGE_CONFIG = {
  registry: "ghcr.io",
  organization: getOrgFromRepo(),
  baseImage: {
    name: "base-bun-build-macos-darwin",
    tag: "latest",
    get fullName() {
      return `${this.registry}/${IMAGE_CONFIG.organization}/${this.name}:${this.tag}`;
    }
  }
};

// Helper function to get the full image name
export function getFullImageName(name, tag = "latest") {
  return `${IMAGE_CONFIG.registry}/${IMAGE_CONFIG.organization}/${name}:${tag}`;
} 