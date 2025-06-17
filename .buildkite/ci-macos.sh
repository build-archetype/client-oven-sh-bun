#!/bin/bash
set -euo pipefail

# Set unbound variables for Buildkite environment
export HOME=${HOME:-/tmp/root-home}
export USER=${USER:-root}

# Ensure HOME directory exists and is writable
if [[ ! -d "$HOME" ]]; then
  mkdir -p "$HOME"
fi

# Clean up any leftover symlinks from previous script versions
rm -f /tmp/bun-workspace /tmp/bun-build

# Parse command line arguments
RELEASE=""
CACHE_RESTORE=false
CACHE_SAVE=false
COMMAND=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --release=*)
      RELEASE="${1#*=}"
      shift
      ;;
    --cache-restore)
      CACHE_RESTORE=true
      shift
      ;;
    --cache-save)
      CACHE_SAVE=true
      shift
      ;;
    *)
      # Remaining arguments are the command to execute
      COMMAND="$*"
      break
      ;;
  esac
done

echo "🚀 Running CI macOS script with:"
echo "  Release: $RELEASE"
echo "  Cache restore: $CACHE_RESTORE" 
echo "  Cache save: $CACHE_SAVE"
echo "  Command: $COMMAND"

# Execute the provided command
if [[ -n "$COMMAND" ]]; then
  echo "▶️ Executing: $COMMAND"
  eval "$COMMAND"
  EXIT_CODE=$?
  
  if [[ $EXIT_CODE -eq 0 ]]; then
    echo "✅ Command completed successfully"
  else
    echo "❌ Command failed with exit code $EXIT_CODE"
  fi
  
  exit $EXIT_CODE
else
  echo "❌ No command provided to execute"
  exit 1
fi 