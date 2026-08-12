#!/bin/bash
# Minecraft Server Startup — Hybrid Cloud + rsync
# Cloud is the SOURCE OF TRUTH. Rsync is a speed optimization for shutdown.
# Periodic backups run every 5 min to limit data loss on power failure.
# Always backs up world to cloud on shutdown with --backup-dir for safety.

# ===== CONFIGURATION =====
SERVER_NAME="server-jinx"     # Change to "server-b" on friend's machine
SERVER_LABEL="Jinx's Server"  # Friendly name shown in Discord
OTHER_SERVER_NAME="server-agis"
OTHER_TAILSCALE_IP="100.x.x.x"  # Friend's Tailscale IP
MINECRAFT_PORT=25565
MINECRAFT_DIR="/opt/minecraft/server"
JAR_FILE="server.jar"
JAVA_ARGS="-Xmx4G -Xms2G -jar $JAR_FILE nogui"

# Discord Webhook URL — create one in your Discord channel:
#   Channel Settings → Integrations → Webhooks → New Webhook
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."  # Replace with your webhook URL

# rclone remote for cloud storage (configured with `rclone config`)
# Used as source of truth + backup. Backblaze B2 ~$0.006/GB/month.
RCLONE_REMOTE="minecraft-b2:minecraft-world-sync"

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

# Only rsync if the other server is confirmed STOPPED (port closed)
try_rsync_from_other() {
    echo "=== Trying rsync from $OTHER_SERVER_NAME ==="
    if [ -z "$OTHER_TAILSCALE_IP" ]; then
        echo "No other Tailscale IP configured, skipping rsync."
        return 1
    fi
    # Check if other server is running — rsync from a live server can cause corruption
    if nc -z -w 3 "$OTHER_TAILSCALE_IP" "$MINECRAFT_PORT" 2>/dev/null; then
        echo "WARNING: $OTHER_SERVER_NAME is still running! Skipping rsync (corruption risk)."
        return 1
    fi
    if ping -c 1 -W 2 "$OTHER_TAILSCALE_IP" &> /dev/null; then
        rsync -avz --progress \
            "$OTHER_TAILSCALE_IP:$MINECRAFT_DIR/world" "$(dirname "$MINECRAFT_DIR")/" \
            && return 0
    fi
    echo "rsync failed (other machine unreachable)."
    return 1
}

# Only rsync if the other server is confirmed STOPPED (port closed)
try_rsync_to_other() {
    echo "=== Trying rsync to $OTHER_SERVER_NAME ==="
    if [ -z "$OTHER_TAILSCALE_IP" ]; then
        echo "No other Tailscale IP configured, skipping rsync."
        return 1
    fi
    if nc -z -w 3 "$OTHER_TAILSCALE_IP" "$MINECRAFT_PORT" 2>/dev/null; then
        echo "WARNING: $OTHER_SERVER_NAME is still running! Skipping rsync (corruption risk)."
        return 1
    fi
    if ping -c 1 -W 2 "$OTHER_TAILSCALE_IP" &> /dev/null; then
        rsync -avz --progress \
            "$MINECRAFT_DIR/world" "$OTHER_TAILSCALE_IP:$MINECRAFT_DIR/world" \
            && return 0
    fi
    echo "rsync failed (other machine unreachable)."
    return 1
}

download_from_cloud() {
    echo "=== Downloading world from cloud ==="
    rclone sync "$RCLONE_REMOTE/world" "$MINECRAFT_DIR/world" \
        --checksum --progress --verbose
    echo "=== Download complete ==="
}

upload_to_cloud() {
    local tag="${1:-$(date -u +%Y%m%d-%H%M%S)}"
    echo "=== Uploading world to cloud (tag: $tag) ==="
    # Use sync + backup-dir: old versions of changed/deleted files are preserved
    local backup_path="$RCLONE_REMOTE/backups/$tag"
    rclone sync "$MINECRAFT_DIR/world" "$RCLONE_REMOTE/world" \
        --checksum --progress --verbose \
        --backup-dir "$backup_path"
    echo "=== Upload complete. Previous state backed up to $backup_path ==="
}

# ===== FUNCTIONS =====

is_other_server_online() {
    nc -z -w 3 "$OTHER_TAILSCALE_IP" "$MINECRAFT_PORT" 2>/dev/null
    return $?
}

get_my_tailscale_ip() {
    tailscale ip -4 2>/dev/null || echo "unavailable"
}

get_world_size() {
    du -sh "$MINECRAFT_DIR/world" 2>/dev/null | cut -f1 || echo "unknown"
}

# ===== MAIN =====

echo "=== Starting $SERVER_NAME ==="

# 1. Check if other server is already running
if is_other_server_online; then
    echo "WARNING: $OTHER_SERVER_NAME is already running!"
    send_discord 16755456 "⚠️ Conflict" \
        "**$SERVER_LABEL** tried to start but **$OTHER_SERVER_NAME** is already online at \`$OTHER_TAILSCALE_IP\`!
Only one server should run at a time — world corruption risk. Stop the other server first."
    exit 1
fi

# 2. PRIMARY: Download world from cloud (source of truth)
echo "Downloading world from cloud..."
download_from_cloud

# 3. OPTIMIZATION: Try rsync from friend for speed (only if friend is stopped)
if try_rsync_from_other; then
    echo "rsync succeeded — world is up-to-date."
else
    echo "Using cloud download (already done above)."
fi

# 4. Notify Discord — server is starting
MY_IP=$(get_my_tailscale_ip)
send_discord 65280 "🟢 $SERVER_NAME is Online!" \
    "**$SERVER_LABEL** is now live and ready for players.
📡 **Tailscale IP:** \`$MY_IP\`
🎮 **Connect:** \`$MY_IP:$MINECRAFT_PORT\`

Join via the Tailscale IP from your Minecraft client."

# 5. Start periodic backups in background (every 5 min, first after 60s)
periodic_backup_pid=""
do_periodic_backups() {
    sleep 60
    while true; do
        ts="periodic-$(date -u +%Y%m%d-%H%M%S)"
        echo "[$ts] Periodic backup..."
        # Use copy to avoid file conflicts with Minecraft (read-only from source)
        rclone copy "$MINECRAFT_DIR/world" "$RCLONE_REMOTE/backups/$ts" \
            --checksum --progress --verbose
        echo "[$ts] Backup complete."
        sleep 300
    done
}
do_periodic_backups &
periodic_backup_pid=$!
echo "Periodic backups started (every 5 min, PID: $periodic_backup_pid)"

# 6. Start the Minecraft server
echo "=== Starting Minecraft server ==="
cd "$MINECRAFT_DIR"
java $JAVA_ARGS

# ===== ON SHUTDOWN =====
echo "=== Server stopping... ==="

# Kill the periodic backup process
if [ -n "$periodic_backup_pid" ]; then
    kill "$periodic_backup_pid" 2>/dev/null || true
fi

# Wait for Minecraft to finish saving
echo "Waiting 15s for Minecraft to save world..."
sleep 15

# 7. PRIMARY: Upload world to cloud (always — with --backup-dir for safety)
echo "Backing up world to cloud..."
upload_to_cloud

# 8. OPTIMIZATION: Try rsync to other machine (only if stopped)
try_rsync_to_other

# 9. Notify Discord — server is offline
MY_IP=$(get_my_tailscale_ip)
WORLD_SIZE=$(get_world_size)
send_discord 16711680 "🔴 $SERVER_NAME is Offline" \
    "**$SERVER_LABEL** has shut down.
📡 **Was at:** \`$MY_IP\`
💾 **World size:** $WORLD_SIZE
☁️ **Backed up** to cloud with \`--backup-dir\`

The other server can now be started safely."

echo "=== $SERVER_NAME stopped ==="