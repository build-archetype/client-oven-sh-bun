# Bash Bunny Payload: Automate Mac CI Setup

This payload automates the setup of a self-hosted Buildkite CI agent on a Mac using the Bash Bunny. It provides all required secrets and configuration non-interactively.

## Files Needed (on Bash Bunny storage)
- `payload.txt` (this file, in the correct payload switch folder)
- `automate-setup.sh` (fill in your secrets and config)

## How It Works
- When you plug the Bash Bunny into a Mac and flip the switch to this payload:
  1. The Bash Bunny emulates a keyboard and storage device.
  2. It opens Terminal on the Mac.
  3. It sources `automate-setup.sh` to set all required environment variables.
  4. It downloads the latest `setup-mac-server.sh` script.
  5. It runs the setup script non-interactively, using your provided secrets.
  6. All output is saved to `setup-mac-server.log` on the Bash Bunny storage.

## How to Prepare
1. Copy `payload.txt` to `/payloads/switch1/` or `/payloads/switch2/` on the Bash Bunny.
2. Copy `automate-setup.sh` to the root of the Bash Bunny storage partition.
3. Edit `automate-setup.sh` and fill in your secrets and configuration values.

## How to Use
1. Plug the Bash Bunny into the target Mac.
2. Flip the switch to the correct payload slot.
3. Wait for the LED to finish (setup is complete).
4. Check `setup-mac-server.log` on the Bash Bunny storage for output and troubleshooting.

**Note:** This payload is designed for initial setup and automation. Do not store sensitive secrets on the Bash Bunny long-term. 