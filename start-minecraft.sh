#!/bin/bash
# Minecraft Server Startup — Hybrid Cloud + rsync
# Cloud is the SOURCE OF TRUTH. Rsync is a speed optimization for shutdown.
# Periodic backups run every 5 min to limit data loss on power failure.
# Always backs up world to cloud on shutdown.

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

# Only rsync if the other server is confirmed STOPPED (port closed)
try_rsync_from_other() {
    echo "=== Trying rsync from $OTHER_SERVER_NAME ==="
    if [ -z "$OTHER_TAILSCALE_IP" ]; then
        echo "No other Tailscale IP configured, skipping rsync."
        return 1
    fi
    # Check if other server is running — rsync from a live server can cause corruption
    if is_other_server_online; then
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
    if is_other_server_online; then
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
    rclone sync "$MINECRAFT_DIR/world" "$RCLONE_REMOTE/world" \
        --checksum --progress --verbose
    echo "=== Upload complete ==="
}

# ===== FUNCTIONS =====

is_other_server_online() {
    # Check if the OTHER server's Minecraft port is open.
    # Both machines are on the same tailnet now, so TCP works directly.
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

# 5. Daily snapshot in background (world sync to cloud happens on shutdown — once per session)
backup_pid=""
do_daily_backup() {
    # Wait 1 hour before first check, then snapshot once per day (keep latest 1)
    sleep 3600
    last_snapshot_date=""
    while true; do
        current_date="$(date -u +%Y%m%d)"
        if [ "$current_date" != "$last_snapshot_date" ]; then
            last_snapshot_date="$current_date"
            ts="snapshot-$(date -u +%Y%m%d-%H%M%S)"
            echo "[$ts] Daily snapshot..."
            rclone copy "$MINECRAFT_DIR/world" "$RCLONE_REMOTE/backups/$ts" \
                --checksum --progress --verbose
            # Keep only latest 1 snapshot
            latest=$(rclone lsd "$RCLONE_REMOTE/backups" 2>/dev/null | awk '{print $NF}' | sort | tail -1)
            rclone lsd "$RCLONE_REMOTE/backups" 2>/dev/null | awk '{print $NF}' | sort | while read old; do
                if [ -n "$old" ] && [ "$old" != "$latest" ]; then
                    rclone purge "$RCLONE_REMOTE/backups/$old" 2>/dev/null || true
                fi
            done
            echo "[$ts] Snapshot done (kept latest 1)."
        fi
        sleep 21600  # check every 6 hours
    done
}
do_daily_backup &
backup_pid=$!
echo "Daily snapshot backup started (PID: $backup_pid)"

# 6. Start the Minecraft server
echo "=== Starting Minecraft server ==="
cd "$MINECRAFT_DIR"
java $JAVA_ARGS

# ===== ON SHUTDOWN =====
echo "=== Server stopping... ==="

# Kill the daily backup process
if [ -n "$backup_pid" ]; then
    kill "$backup_pid" 2>/dev/null || true
fi

# Wait for Minecraft to finish saving
echo "Waiting 15s for Minecraft to save world..."
sleep 15

# 7. PRIMARY: Upload world to cloud (always)
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
☁️ **World uploaded** to cloud

The other server can now be started safely."

echo "=== $SERVER_NAME stopped ==="