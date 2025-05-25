# Read GitHub token from shared file if present
GITHUB_TOKEN_PATH="/Volumes/My Shared Files/workspace/github_token.txt"
if [ -f "$GITHUB_TOKEN_PATH" ]; then
  export GITHUB_TOKEN="$(cat "$GITHUB_TOKEN_PATH")"
  echo "GITHUB_TOKEN loaded from $GITHUB_TOKEN_PATH"
  # Optionally, securely delete the token file after loading
  rm -f "$GITHUB_TOKEN_PATH"
else
  echo "Warning: GITHUB_TOKEN file not found at $GITHUB_TOKEN_PATH"
fi 