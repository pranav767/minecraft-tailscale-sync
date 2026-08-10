# Minecraft Tailscale Sync 🎮

Two-player Minecraft setup with **Cloud Storage** + **Tailscale** + **Discord Webhook**.

You and a friend run separate Minecraft servers on your own machines. This setup:

1. **World data lives in the cloud** (S3 / Backblaze B2 / any S3-compatible storage)
2. **Downloads on start, uploads on stop** — no sync conflicts, no daemon needed
3. **Prevents conflicts** — only one server runs at a time
4. **Posts to Discord** via a simple webhook when a server starts/stops

## Why Cloud Storage?

| Approach | Problem |
|---|---|
| **rsync** | ❌ Fails when the other machine is offline — world data never moves |
| **Syncthing** | ⚠️ If both servers somehow run, conflict files appear → world corruption risk |
| **Cloud Storage** | ✅ Single source of truth. Download → play → upload. No conflicts possible. |

## How It Works

```
                    ┌──────────────────────┐
                    │   Cloud Storage      │
                    │  (S3 / B2 / R2)      │
                    │                      │
                    │     world/           │
                    └──┬───────────────┬───┘
                       │               │
                 download           download
                 on start           on start
                 upload             upload
                 on stop            on stop
                       │               │
              ┌────────┴──────┐  ┌────┴────────┐
              │ Your Machine  │  │ Friend's    │
              │ Server A      │  │ Server B    │
              │ 100.x.x.1     │  │ 100.x.x.2   │
              └───────┬───────┘  └──────┬───────┘
                      │                 │
                      │  Discord        │
                      │  Webhook        │
                      └─────┬───────────┘
                            │
                            ▼
                  ┌──────────────────┐
                  │   Discord Chat   │
                  │ 🟢 A is Online!  │
                  │ 🔴 A is Offline  │
                  └──────────────────┘
```

**No sync daemon. No conflict files. Just download, play, upload.**

## Prerequisites

- [Tailscale](https://tailscale.com/) installed on both machines
- Both machines can reach each other's Tailscale IP on port `25565`
- [rclone](https://rclone.org/) installed on both machines
- An S3-compatible storage bucket (Backblaze B2, AWS S3, Cloudflare R2, etc.)
- Discord channel with a [Webhook](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks) created
- `nc` (netcat) and `curl` available on both machines

## Setup

### 0. Configure Cloud Storage with rclone

On **both machines**, install rclone and set up your storage:

```bash
# Install rclone
sudo -v ; curl https://rclone.org/install.sh | sudo bash

# Configure your storage provider
rclone config
```

**Recommended:** Backblaze B2 — ~$0.006/GB/month. A Minecraft world is ~100MB = less than a penny per month.

Follow the prompts to create a remote. Then test it:

```bash
# Create a bucket (B2 example)
rclone mkdir minecraft-b2:minecraft-world-bucket

# Test it works
rclone ls minecraft-b2:minecraft-world-bucket
```

### 1. Clone the repo on each machine

```bash
git clone https://github.com/pranav767/minecraft-tailscale-sync.git /opt/minecraft
cd /opt/minecraft
```

### 2. Configure the script

Edit `start-minecraft.sh` and set these variables:

| Variable | Your Machine | Friend's Machine |
|---|---|---|
| `SERVER_NAME` | `server-a` | `server-b` |
| `SERVER_LABEL` | `"Your Server"` | `"Friend's Server"` |
| `OTHER_TAILSCALE_IP` | Friend's Tailscale IP | Your Tailscale IP |
| `DISCORD_WEBHOOK_URL` | Same webhook URL | Same webhook URL |
| `MINECRAFT_DIR` | Path to server dir | Path to server dir |
| `RCLONE_REMOTE` | Your rclone remote + bucket | Same rclone remote + bucket |

### 3. Make it executable

```bash
chmod +x /opt/minecraft/start-minecraft.sh
```

### 4. Start Minecraft!

```bash
./start-minecraft.sh
```

The script will:
1. ✅ Check the other server isn't already running
2. 📥 Download the latest world from cloud storage
3. 🟢 Post "Online!" to Discord
4. 🎮 Start Minecraft
5. On shutdown: 📤 Upload world to cloud
6. 🔴 Post "Offline" to Discord

## Discord Notifications

| Event | Color | Message |
|---|---|---|
| Server started | 🟢 Green | "Server A is Online!" |
| Server stopped | 🔴 Red | "Server A is Offline. World saved to cloud." |
| Conflict blocked | 🟡 Orange | "Server A tried to start but B is already online!" |

## Handoff Flow

```
1. Friend plays on Server B, builds cool stuff
2. Friend stops Server B → world uploads to cloud
3. You start Server A → world downloads from cloud
4. You see everything friend built! Play on Server A
5. You stop Server A → world uploads to cloud
6. Friend starts Server B → world downloads from cloud
7. Friend sees everything you built! Continue playing
```

## Auto-Start

The Minecraft server should be started manually (so you don't accidentally run both). But if you want auto-start:

### Ubuntu — systemd service

```bash
sudo nano /etc/systemd/system/minecraft.service
```

```ini
[Unit]
Description=Minecraft Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=minecraft
WorkingDirectory=/opt/minecraft/server
ExecStart=/opt/minecraft/start-minecraft.sh
Restart=no

[Install]
WantedBy=multi-user.target
```

### Talos Linux — Docker

```bash
docker run -d \
  --restart unless-stopped \
  --name minecraft \
  --network host \
  -v /opt/minecraft:/opt/minecraft \
  -v /home/user/.config/rclone:/home/user/.config/rclone \
  itzg/minecraft-server:latest
```

### Crontab @reboot (both OS)

```bash
crontab -e
# Add:
@reboot /opt/minecraft/start-minecraft.sh >> /var/log/minecraft.log 2>&1
```

## Notes

- Only **one** server should run at a time — the script enforces this
- World data is stored in the cloud — no sync conflicts, no corruption risk
- Works even if machines are never online at the same time
- Backblaze B2 costs ~$0.006/GB/month — a Minecraft world is pennies
- Talos Linux, Ubuntu, Debian, Raspberry Pi — works on anything with bash + curl

- Only **one** server should run at a time — the script enforces this
- Syncthing syncs the `world/` folder in real-time, so you always have the latest data
- Script uses a local lock file (`.server-lock.json`) to track who was last online
- Talos Linux, Ubuntu, Debian, Raspberry Pi — works on anything with bash + curl