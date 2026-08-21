#!/bin/bash
# Minecraft Server Startup — Simple cloud sync
# Cloud is the SOURCE OF TRUTH. Download on start, upload on stop. That's it.
# No rsync, no periodic backups, no daily snapshots — just clean sync.

# ===== CONFIGURATION =====
SERVER_NAME="server-jinx"     # Change to "server-b" on friend's machine
SERVER_LABEL="Jinx's Server"  # Friendly name shown in Discord
MINECRAFT_PORT=25565
MINECRAFT_DIR="/opt/minecraft/server"
JAR_FILE="server.jar"
JAVA_ARGS="-Xmx5G -Xms2G -jar $JAR_FILE nogui"

# Discord Webhook URL — create one in your Discord channel:
#   Channel Settings → Integrations → Webhooks → New Webhook
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."  # Replace with your webhook URL

# rclone remote for cloud storage (configured with `rclone config`)
# Google Drive 15GB free — no transaction limits like B2.
# Create a remote named 'gdrive' via `rclone config` → drive.
RCLONE_REMOTE="minecraft-gdrive:minecraft-world-sync"

# ===== DISCORD WEBHOOK =====

send_discord() {
    local color="$1"    # 65280 (green) or 16711680 (red)
    local title="$2"
    local desc="$3"

    curl -s -H "Content-Type: application/json" \
        -X POST "$DISCORD_WEBHOOK_URL" \
        -d "$(cat <<EOF
{
  "embeds": [{
    "title": "$title",
    "description": "$desc",
    "color": $color,
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }]
}
EOF
    )" > /dev/null
}

# ===== SYNC FUNCTIONS =====

download_from_cloud() {
    echo "=== Downloading world from cloud ==="
    rclone sync "$RCLONE_REMOTE/world" "$MINECRAFT_DIR/world" \
        --checksum --progress --verbose
    echo "=== Download complete ==="
}

upload_to_cloud() {
    echo "=== Uploading world to cloud ==="
    rclone sync "$MINECRAFT_DIR/world" "$RCLONE_REMOTE/world" \
        --checksum --progress --verbose
    echo "=== Upload complete ==="
}

# ===== FUNCTIONS =====

get_my_tailscale_ip() {
    tailscale ip -4 2>/dev/null || echo "unavailable"
}

get_world_size() {
    du -sh "$MINECRAFT_DIR/world" 2>/dev/null | cut -f1 || echo "unknown"
}

# ===== MAIN =====

echo "=== Starting $SERVER_NAME ==="

# 1. Download world from cloud (source of truth)
echo "Downloading world from cloud..."
download_from_cloud

# 2. Notify Discord — server is starting
MY_IP=$(get_my_tailscale_ip)
send_discord 65280 "🟢 $SERVER_NAME is Online!" \
    "**$SERVER_LABEL** is now live and ready for players.
📡 **Tailscale IP:** \`$MY_IP\`
🎮 **Connect:** \`$MY_IP:$MINECRAFT_PORT\`

Join via the Tailscale IP from your Minecraft client."

# 3. Start the Minecraft server
echo "=== Starting Minecraft server ==="
cd "$MINECRAFT_DIR"
java $JAVA_ARGS

# ===== ON SHUTDOWN =====
echo "=== Server stopping... ==="

# Wait for Minecraft to finish saving
echo "Waiting 15s for Minecraft to save world..."
sleep 15

# 4. Upload world to cloud (always)
echo "Backing up world to cloud..."
upload_to_cloud

# 5. Notify Discord — server is offline
MY_IP=$(get_my_tailscale_ip)
WORLD_SIZE=$(get_world_size)
send_discord 16711680 "🔴 $SERVER_NAME is Offline" \
    "**$SERVER_LABEL** has shut down.
📡 **Was at:** \`$MY_IP\`
💾 **World size:** $WORLD_SIZE
☁️ **World uploaded** to cloud

The other server can now be started safely."

echo "=== $SERVER_NAME stopped ==="