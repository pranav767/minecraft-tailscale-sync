#!/bin/bash
# Sync script — runs as init container before Minecraft starts
# and as a sidecar on shutdown to handle world sync.

set -euo pipefail

SERVER_NAME="${SERVER_NAME:-server-a}"
OTHER_SERVER_NAME="${OTHER_SERVER_NAME:-server-b}"
OTHER_TAILSCALE_IP="${OTHER_TAILSCALE_IP:-}"
MINECRAFT_DIR="${MINECRAFT_DIR:-/data}"
RCLONE_REMOTE="${RCLONE_REMOTE:-minecraft-b2:minecraft-world-bucket}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

send_discord() {
    local color="$1"
    local title="$2"
    local desc="$3"
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
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
    fi
}

try_rsync_from_other() {
    echo "=== Trying rsync from $OTHER_SERVER_NAME ==="
    if [ -n "$OTHER_TAILSCALE_IP" ] && ping -c 1 -W 2 "$OTHER_TAILSCALE_IP" &> /dev/null; then
        rsync -avz --progress \
            "$OTHER_TAILSCALE_IP:$MINECRAFT_DIR/world" "$(dirname "$MINECRAFT_DIR")/" \
            && return 0
    fi
    echo "rsync failed (other machine offline). Falling back to cloud..."
    return 1
}

try_rsync_to_other() {
    echo "=== Trying rsync to $OTHER_SERVER_NAME ==="
    if [ -n "$OTHER_TAILSCALE_IP" ] && ping -c 1 -W 2 "$OTHER_TAILSCALE_IP" &> /dev/null; then
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

# Main logic based on argument
case "${1:-}" in
    pre-start)
        echo "=== Pre-start sync for $SERVER_NAME ==="
        # Try rsync first, fall back to cloud
        if ! try_rsync_from_other; then
            download_from_cloud
        fi
        send_discord 65280 "🟢 $SERVER_NAME is Online!" \
            "Minecraft server **$SERVER_NAME** is now live."
        ;;
    post-stop)
        echo "=== Post-stop sync for $SERVER_NAME ==="
        # Always upload to cloud
        upload_to_cloud
        # Try rsync to other machine
        try_rsync_to_other
        send_discord 16711680 "🔴 $SERVER_NAME is Offline" \
            "Minecraft server **$SERVER_NAME** has shut down. World saved to cloud."
        ;;
    *)
        echo "Usage: $0 {pre-start|post-stop}"
        exit 1
        ;;
esac
