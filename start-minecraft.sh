#!/bin/bash
# Minecraft Server Startup — Hybrid Cloud + rsync
# Uses rsync over Tailscale for fast handoffs, falls back to cloud storage.
# Always backs up world to cloud on shutdown.

# ===== CONFIGURATION =====
SERVER_NAME="server-a"     # Change to "server-b" on friend's machine
SERVER_LABEL="Your Server"  # Friendly name shown in Discord
OTHER_SERVER_NAME="server-b"
OTHER_TAILSCALE_IP="100.x.x.2"  # Friend's Tailscale IP
MINECRAFT_PORT=25565
MINECRAFT_DIR="/opt/minecraft/server"
JAR_FILE="server.jar"
JAVA_ARGS="-Xmx4G -Xms2G -jar $JAR_FILE nogui"

# Discord Webhook URL — create one in your Discord channel:
#   Channel Settings → Integrations → Webhooks → New Webhook
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN"

# rclone remote for cloud storage (configured with `rclone config`)
# Used as fallback + backup. Backblaze B2 ~$0.006/GB/month.
RCLONE_REMOTE="minecraft-b2:minecraft-world-bucket"

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

try_rsync_from_other() {
    echo "=== Trying rsync from $OTHER_SERVER_NAME ==="
    # Check if other machine is reachable at all (Tailscale ping)
    if ping -c 1 -W 2 "$OTHER_TAILSCALE_IP" &> /dev/null; then
        rsync -avz --progress \
            "$OTHER_TAILSCALE_IP:$MINECRAFT_DIR/world" "$(dirname "$MINECRAFT_DIR")/" \
            && return 0
    fi
    echo "rsync failed (other machine offline). Falling back to cloud..."
    return 1
}

try_rsync_to_other() {
    echo "=== Trying rsync to $OTHER_SERVER_NAME ==="
    if ping -c 1 -W 2 "$OTHER_TAILSCALE_IP" &> /dev/null; then
        rsync -avz --progress \
            "$MINECRAFT_DIR/world" "$OTHER_TAILSCALE_IP:$MINECRAFT_DIR/world" \
            && return 0
    fi
    echo "rsync failed (other machine offline). Cloud backup will suffice."
    return 1
}

download_from_cloud() {
    echo "=== Downloading world from cloud ==="
    rclone sync "$RCLONE_REMOTE/world" "$MINECRAFT_DIR/world" \
        --progress --verbose
    echo "=== Download complete ==="
}

upload_to_cloud() {
    echo "=== Uploading world to cloud ==="
    rclone sync "$MINECRAFT_DIR/world" "$RCLONE_REMOTE/world" \
        --progress --verbose
    echo "=== Upload complete ==="
}

# ===== FUNCTIONS =====

is_other_server_online() {
    nc -z -w 3 "$OTHER_TAILSCALE_IP" "$MINECRAFT_PORT" 2>/dev/null
    return $?
}

# ===== MAIN =====

echo "=== Starting $SERVER_NAME ==="

# 1. Check if other server is already running
if is_other_server_online; then
    echo "WARNING: $OTHER_SERVER_NAME is already running!"
    send_discord 16755456 "⚠️ Conflict" \
        "**$SERVER_LABEL** tried to start but **$OTHER_SERVER_NAME** is already online!"
    exit 1
fi

# 2. Get latest world — try rsync first (fast, incremental), fall back to cloud
echo "Getting latest world data..."
if ! try_rsync_from_other; then
    download_from_cloud
fi

# 3. Notify Discord — server is starting
send_discord 65280 "🟢 $SERVER_LABEL is Online!" \
    "Minecraft server **$SERVER_LABEL** is now live and ready for players."

# 4. Start the Minecraft server
echo "=== Starting Minecraft server ==="
cd "$MINECRAFT_DIR"
java $JAVA_ARGS

# ===== ON SHUTDOWN =====
echo "=== Server stopping... ==="

# 5. Upload world to cloud (always — acts as backup)
echo "Backing up world to cloud..."
upload_to_cloud

# 6. Try rsync to other machine (only if online, otherwise cloud is enough)
try_rsync_to_other

# 7. Notify Discord — server is offline
send_discord 16711680 "🔴 $SERVER_LABEL is Offline" \
    "Minecraft server **$SERVER_LABEL** has shut down. World saved to cloud."

echo "=== $SERVER_NAME stopped ==="