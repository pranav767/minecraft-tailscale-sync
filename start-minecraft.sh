#!/bin/bash
# Minecraft Server Startup Script with Sync + Discord Webhook
# Place this on both machines, configure the variables below

# ===== CONFIGURATION =====
SERVER_NAME="server-a"     # Change to "server-b" on friend's machine
SERVER_LABEL="Your Server"  # Friendly name shown in Discord
OTHER_SERVER_NAME="server-b"
OTHER_TAILSCALE_IP="100.x.x.2"  # Friend's Tailscale IP
MINECRAFT_PORT=25565
MINECRAFT_DIR="/opt/minecraft/server"
SYNC_DIR="/opt/minecraft/synced"
JAR_FILE="server.jar"
JAVA_ARGS="-Xmx4G -Xms2G -jar $JAR_FILE nogui"

# Discord Webhook URL — create one in your Discord channel:
#   Channel Settings → Integrations → Webhooks → New Webhook
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN"

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

# ===== FUNCTIONS =====

is_other_server_online() {
    nc -z -w 3 "$OTHER_TAILSCALE_IP" "$MINECRAFT_PORT" 2>/dev/null
    return $?
}

sync_from_other() {
    echo "=== Syncing world data from $OTHER_SERVER_NAME ==="
    rsync -avz --progress \
        --exclude='server-status.json' \
        "$OTHER_TAILSCALE_IP:$MINECRAFT_DIR/" "$MINECRAFT_DIR/"
    echo "=== Sync complete ==="
}

sync_to_other() {
    echo "=== Pushing world data to $OTHER_SERVER_NAME ==="
    rsync -avz --progress \
        --exclude='server-status.json' \
        "$MINECRAFT_DIR/" "$OTHER_TAILSCALE_IP:$MINECRAFT_DIR/"
    echo "=== Push complete ==="
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

# 2. Sync latest world data from the other machine
echo "Checking for latest world data..."
sync_from_other

# 3. Notify Discord — server is starting
send_discord 65280 "🟢 $SERVER_LABEL is Online!" \
    "Minecraft server **$SERVER_LABEL** is now live and ready for players."

# 4. Start the Minecraft server
echo "=== Starting Minecraft server ==="
cd "$MINECRAFT_DIR"
java $JAVA_ARGS

# ===== ON SHUTDOWN =====
echo "=== Server stopping... ==="

# 5. Push latest data to the other machine
sync_to_other

# 6. Notify Discord — server is offline
send_discord 16711680 "🔴 $SERVER_LABEL is Offline" \
    "Minecraft server **$SERVER_LABEL** has shut down. World data has been synced."

echo "=== $SERVER_NAME stopped ==="
update_status_file "false"

# 7. Push latest data to the other machine
sync_to_other

echo "=== $SERVER_NAME stopped ==="