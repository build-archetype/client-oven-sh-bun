# Bun CI/CD


## Runnging manually
```bash
brew install cirruslabs/cli/tart
```

```bash
brew install cirruslabs/cli/cirrus
```

23.3 GB compressed😬
```bash
tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest sequoia-base
```

```bash
tart run sequoia-base
```

Open up terminal and run:
```bash
brew install automake ccache cmake coreutils gnu-sed go icu4c libiconv libtool ninja pkg-config rust ruby
```

```bash
curl -fsSL https://bun.sh/install | bash
```

```bash
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/:$PATH"
```


```bash
brew install llvm@19
```

## Running with Cirrus CI YAML
**.cirrus.yml**
```bash
task:
  name: sr_bun
  macos_instance:
    image: ghcr.io/cirruslabs/macos-sequoia-base:latest
  sr_bun_script:
    - brew --version
    - brew install automake ccache cmake coreutils gnu-sed go icu4c libiconv libtool ninja pkg-config rust ruby
    - curl -fsSL https://bun.sh/install | bash
    - which $SHELL
    - echo 'export BUN_INSTALL="$HOME/.bun"' >> ~/.zshrc
    - echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> ~/.zshrc
    - source ~/.zshrc
    - bun --help
    - bun --version
    - brew install llvm@19
    - export PATH="$(brew --prefix llvm@19)/bin:$PATH"
    - which clang-19
```


### Buildkite

```bash
brew install buildkite/buildkite/buildkite-agent
```

```bash
brew install buildkite-agent 
```

```bash
buildkite-agent start \
  --token xxxx
```

Create token documentation:
https://buildkite.com/docs/agent/v3/tokens#create-a-token-using-the-buildkite-interface

In BuildKite, create a build
- Bun repo
- set branch

Running a cluster of buildkite agents 🪁🪁🪁 
