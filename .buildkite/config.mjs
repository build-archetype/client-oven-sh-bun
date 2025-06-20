import { readFileSync, existsSync } from 'fs';
import { getBootstrapVersion } from '../scripts/utils.mjs';

// Get the organization from the repository URL
const getOrgFromRepo = () => {
  const repo = process.env.BUILDKITE_REPO || '';
  const match = repo.match(/github\.com[:/]([^/]+)/);
  return match ? match[1] : 'oven-sh'; // fallback to oven-sh if we can't determine
};

// Get Bun version from various sources
const getBunVersion = () => {
  try {
    // Try to read from CMakeLists.txt
    if (existsSync('CMakeLists.txt')) {
      const content = readFileSync('CMakeLists.txt', 'utf8');
      const match = content.match(/set\(Bun_VERSION\s+"([^"]+)"/);
      if (match) {
        return match[1];
      }
    }

    // Try to read from package.json
    if (existsSync('package.json')) {
      const packageJson = JSON.parse(readFileSync('package.json', 'utf8'));
      if (packageJson.version) {
        return packageJson.version.replace(/^v/, '');
      }
    }

    // Fallback
    return "1.2.14";
  } catch (error) {
    console.warn("Could not determine Bun version, using default:", error.message);
    return "1.2.14";
  }
};

export const IMAGE_CONFIG = {
  baseImage: {
    registry: "ghcr.io",
    organization: "build-archetype",
    repository: "client-oven-sh-bun",
    name: "bun-build-macos",
    tag: "latest",
    get versionedName() {
      const release = envVar("MACOS_RELEASE") ?? "13";
      const arch = "arm64"; // Default architecture
      const version = envVar("BUN_VERSION") ?? getBunVersion();
      const bootstrapVersion = getBootstrapVersion("darwin"); // Single source of truth from bootstrap_new.sh
      return `bun-build-macos-${release}-${arch}-${version}-bootstrap-${bootstrapVersion}`;
    },
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