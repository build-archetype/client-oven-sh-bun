import { readFileSync, existsSync } from 'fs';
import { getBootstrapVersion } from '../scripts/utils.mjs';

// Get the organization from the repository URL
const getOrgFromRepo = () => {
  const repo = process.env.BUILDKITE_REPO || '';
  const match = repo.match(/github\.com[:/]([^/]+)/);
  return match ? match[1] : 'oven-sh'; // fallback to oven-sh if we can't determine
};

// Get current architecture
const getArchitecture = () => {
  const arch = process.arch;
  switch (arch) {
    case 'arm64':
    case 'aarch64':
      return 'arm64';
    case 'x64':
    case 'x86_64':
    case 'amd64':
      return 'x64';
    default:
      throw new Error(`Unsupported architecture: ${arch}`);
  }
};

// Get macOS release version
const getMacOSRelease = () => {
  // Default to macOS 14 (Sonoma), but this could be made configurable
  return process.env.MACOS_RELEASE || '14';
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
      const macosRelease = getMacOSRelease();
      const arch = getArchitecture();
      return `bun-build-macos-${macosRelease}-${arch}`;
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

// Helper function to create versioned tag (version + bootstrap info)
export function getVersionedTag() {
  const version = getBunVersion();
  const bootstrapVersion = getBootstrapVersion("darwin");
  return `${version}-bootstrap-${bootstrapVersion}`;
}

// Helper function to get full versioned image URL
export function getVersionedImageURL() {
  const imageName = IMAGE_CONFIG.baseImage.versionedName;
  const tag = getVersionedTag();
  return getFullImageName(imageName, tag);
} 