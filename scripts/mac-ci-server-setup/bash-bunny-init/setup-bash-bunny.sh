#!/bin/bash
set -e

echo "🔧 Setting up Bash Bunny for macOS CI automation..."
echo

# Check if secrets.env exists
if [ ! -f "secrets.env" ]; then
    echo "❌ Error: secrets.env not found!"
    echo "Please copy secrets.env.example to secrets.env and fill in your values:"
    echo "  cp secrets.env.example secrets.env"
    echo "  nano secrets.env"
    exit 1
fi

# Check if Bash Bunny is mounted
if [ ! -d "/Volumes/BashBunny" ]; then
    echo "❌ Error: Bash Bunny not found at /Volumes/BashBunny"
    echo "Please ensure:"
    echo "  1. Bash Bunny switch is in position 3 (arming mode)"
    echo "  2. Bash Bunny is plugged into your computer"
    echo "  3. It has mounted as a USB drive"
    exit 1
fi

# Create payload directory if it doesn't exist
mkdir -p /Volumes/BashBunny/payloads/switch1/

# Copy files
echo "📂 Copying secrets to Bash Bunny storage..."
cp secrets.env /Volumes/BashBunny/

echo "📂 Copying payload to switch1 directory..."
cp payload.txt /Volumes/BashBunny/payloads/switch1/

# Verify files were copied
echo
echo "✅ Verifying files were copied successfully..."
echo
echo "Root directory contents:"
ls -la /Volumes/BashBunny/ | grep -E "(secrets\.env|payloads)"

echo
echo "Switch1 payload directory contents:"
ls -la /Volumes/BashBunny/payloads/switch1/ | grep "payload.txt"

echo
echo "🎉 Bash Bunny setup complete!"
echo
echo "📋 Summary of what was configured:"
echo "  ✓ secrets.env copied to /Volumes/BashBunny/"
echo "  ✓ payload.txt copied to /Volumes/BashBunny/payloads/switch1/"
echo "  ✓ Bash Bunny ready for macOS CI automation"
echo

# Prompt for safe ejection
echo "⚠️  Before unplugging, the Bash Bunny should be safely ejected."
read -p "Press ENTER to safely eject the Bash Bunny, or Ctrl+C to cancel: "

echo "💾 Safely ejecting Bash Bunny..."
diskutil eject /Volumes/BashBunny

echo
echo "✅ Bash Bunny safely ejected!"
echo
echo "🚀 How to trigger the macOS CI setup:"
echo
echo "  1. 📌 Unplug Bash Bunny from this computer"
echo "  2. 🔄 Set switch to position 1 (where payload was copied)"  
echo "  3. 🖥️  Plug Bash Bunny into target Mac"
echo "  4. 👀 Watch LED indicator:"
echo "     • STAGE1: Opening Terminal"
echo "     • STAGE2: Running CI setup"
echo "     • FINISH: Setup complete!"
echo "  5. ⏱️  Wait 15-30 minutes for full setup"
echo "  6. 📋 Check results: switch back to position 3, plug into computer,"
echo "     and view /Volumes/BashBunny/setup-mac-server.log"
echo
echo "⚠️  Note: Target Mac user may need to enter sudo password during setup"
echo