# Bash Bunny: Automated macOS CI Setup

This payload automates the complete setup of a Bun CI agent on macOS using the Bash Bunny. It provides all secrets non-interactively and runs the full setup process.

## Quick Setup

### 1. Prepare Your Secrets
```bash
# Copy the example file
cp secrets.env.example secrets.env

# Edit with your actual values
nano secrets.env
```

### 2. Required Values
Fill in these required values in `secrets.env`:

- **BUILDKITE_AGENT_TOKEN**: Your Buildkite agent token
- **GITHUB_USERNAME**: Your GitHub username (for ghcr.io)
- **GITHUB_TOKEN**: GitHub token with `packages:write` permission
- **MACHINE_LOCATION**: Physical location (e.g., "office-1", "datacenter-2")
- **COMPUTER_NAME**: Name for this CI machine

### 3. Copy to Bash Bunny

**Option A: Use the automated setup script (recommended)**
```bash
# Ensure Bash Bunny is in arming mode (switch position 3) and plugged in
./setup-bash-bunny.sh
```

**Option B: Manual setup**
```bash
# Mount your Bash Bunny in Arming Mode
# Copy these files to the root of the Bash Bunny storage:
cp payload.txt /Volumes/BashBunny/
cp secrets.env /Volumes/BashBunny/

# Copy payload.txt to the appropriate switch directory
cp payload.txt /Volumes/BashBunny/payloads/switch1/

# Safely eject
diskutil eject /Volumes/BashBunny
```

### 4. Execute
1. Unplug Bash Bunny from this computer
2. Set switch to position 1 (where payload was copied)
3. Plug Bash Bunny into target Mac
4. Watch LED indicator:
   - **STAGE1**: Opening Terminal
   - **STAGE2**: Running CI setup  
   - **FINISH**: Setup complete!
5. Wait 15-30 minutes for full setup
6. Check results: switch back to position 3, plug into computer, and view `/Volumes/BashBunny/setup-mac-server.log`

## How It Works

1. **LED STAGE1**: Mounts storage and opens Terminal
2. **LED STAGE2**: Sources secrets, downloads script, and executes setup with sudo
3. **LED FINISH**: Setup complete

The payload executes these commands:
```bash
# Step 1: Go home, source secrets, download script
cd ~ && source /Volumes/BashBunny/secrets.env && curl -fsSL -o setup-mac-server.sh https://raw.githubusercontent.com/build-archetype/client-oven-sh-bun/feat/sam/on-prem-mac-ci/infrastructure/setup/setup-mac-server.sh

# Step 2: Make executable and run with sudo -E (preserves environment)
chmod +x setup-mac-server.sh && sudo -E ./setup-mac-server.sh 2>&1 | tee /Volumes/BashBunny/setup-mac-server.log
```

**Note**: The `-E` flag preserves environment variables when running with sudo, ensuring your secrets are available to the setup script.

## Files

- `payload.txt` - Bash Bunny payload script
- `secrets.env` - Your secrets (create from example)
- `secrets.env.example` - Template with placeholders
- `setup-bash-bunny.sh` - Automated setup script
- `setup-mac-server.log` - Output log (created during execution)

## Security Notes

- **Never commit `secrets.env`** - it contains sensitive tokens
- Use a dedicated GitHub token with minimal permissions
- Consider using a dedicated GitHub account for CI operations
- Review the log file for any credential exposure
- The script requires sudo access for system configuration

## Troubleshooting

**Payload doesn't start:**
- Verify Bash Bunny is in attack mode (not arming mode)
- Check that `payload.txt` is in the correct switch directory

**Setup fails:**
- Check `setup-mac-server.log` on Bash Bunny storage
- Verify all required secrets are filled in
- Ensure GitHub token has `packages:write` permission
- Make sure Mac has internet connectivity
- Ensure the user has sudo access

**Permission denied:**
- The script requires sudo access to configure system settings
- User must be in the admin group or have sudo privileges
- Check if password is required for sudo (may need manual intervention)

**Download fails:**
- Ensure Mac has internet connectivity
- Check that the GitHub URL is accessible
- Verify curl is installed (standard on macOS)

**Terminal doesn't open:**
- Some Macs may have different delay requirements
- Try increasing delays in `payload.txt` if needed 