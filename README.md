# Minecraft Tailscale Sync 🎮

Two-player Minecraft setup with **rsync** (fast handoff) + **Cloud Storage** (fallback + backup).

You and a friend run separate Minecraft servers on your own machines. This setup:

1. **Fast handoff** — uses `rsync` over Tailscale when both machines are online (incremental, seconds)
2. **Cloud fallback** — falls back to cloud storage (S3/B2) when the other machine is offline
3. **Cloud backup** — always backs up the world to cloud on shutdown (acts as safety net)
4. **Prevents conflicts** — only one server runs at a time
5. **Posts to Discord** via a simple webhook when a server starts/stops

## Why Hybrid?

| Approach | Daily handoff speed | Works when other is offline? | Corruption risk? |
|---|---|---|---|
| **rsync only** | ⚡ Fast (seconds) | ❌ No — world data stuck | ✅ None |
| **Cloud only** | 🐢 Slow (download+upload GBs) | ✅ Yes | ✅ None |
| **Hybrid (this repo)** | ⚡ Fast (seconds) **or** 🐢 cloud fallback | ✅ Yes | ✅ None |

## How It Works

```
Normal handoff (both machines online recently):
  Start → rsync from friend's machine (only changed chunks = seconds)
  Stop  → rsync to friend + rclone backup to cloud

Edge case (other machine offline):
  Start → rclone download from cloud (fallback)
  Stop  → rclone upload to cloud (backup)
         → rsync attempts to friend (skips if offline)
```

### What about a 2GB+ world?

Good concern. Here's how it breaks down:

- **rsync** is **incremental** — after the first sync, it only transfers chunks that changed. Most days: **5-30 seconds**
- **rclone** to cloud is also **incremental** — only uploads new/changed region files. A 30-minute play session might add only **5-50MB** of changes
- Full download from cloud only happens if:
  - It's the **very first time** (one-time ~5 min for 2GB)
  - The other machine has been offline for a long time and there's no local copy

**In practice:** 90% of handoffs use rsync (seconds). Cloud is just a safety net.

```
                    ┌──────────────────────┐
                    │   Cloud Storage      │
                    │  (S3 / B2 / R2)      │
                    │     world/           │
                    └──┬───────────────┬───┘
                       │   backup      │  fallback
                       │   (always)    │  (when offline)
              ┌────────┴──────┐  ┌────┴────────┐
              │ Your Machine  │  │ Friend's    │
              │ Server A      │  │ Server B    │
              │ 100.x.x.1     │  │ 100.x.x.2   │
              └───────┬───────┘  └──────┬───────┘
                      │  rsync ◄──────► │
                      │  (fast path)    │
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

## Prerequisites

- [Tailscale](https://tailscale.com/) installed on both machines
- Both machines pingable on their Tailscale IPs
- [rclone](https://rclone.org/) installed on both machines
- An S3-compatible storage bucket (Backblaze B2, AWS S3, Cloudflare R2, etc.)
- Discord channel with a [Webhook](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks) created
- `rsync`, `nc` (netcat), and `curl` available on both machines

## Setup

### 0. Configure Cloud Storage with rclone

On **both machines**:

```bash
# Install rclone
sudo -v ; curl https://rclone.org/install.sh | sudo bash

# Configure your storage provider
rclone config
```

**Recommended:** Backblaze B2 — ~$0.006/GB/month. A 2GB world = ~1.2 cents/month.

Test it:

```bash
rclone mkdir minecraft-b2:minecraft-world-bucket
rclone ls minecraft-b2:minecraft-world-bucket
```

### 1. Clone the repo on each machine

```bash
git clone https://github.com/pranav767/minecraft-tailscale-sync.git /opt/minecraft
cd /opt/minecraft
```

### 2. Configure the script

Edit `start-minecraft.sh`:

| Variable | Your Machine | Friend's Machine |
|---|---|---|
| `SERVER_NAME` | `server-a` | `server-b` |
| `SERVER_LABEL` | `"Your Server"` | `"Friend's Server"` |
| `OTHER_TAILSCALE_IP` | Friend's Tailscale IP | Your Tailscale IP |
| `DISCORD_WEBHOOK_URL` | Same webhook URL | Same webhook URL |
| `MINECRAFT_DIR` | Path to server dir | Path to server dir |
| `RCLONE_REMOTE` | Your rclone remote:bucket | Same rclone remote:bucket |

### 3. Make it executable

```bash
chmod +x /opt/minecraft/start-minecraft.sh
```

### 4. Start Minecraft!

```bash
./start-minecraft.sh
```

## What Happens on Each Action

```
START:
  ├─ Check: other server online? → Yes → ❌ Refuse, warn Discord
  ├─ Try rsync from friend → Success → ✅ Got latest world (seconds)
  └─ rsync failed → rclone from cloud → ✅ Got latest world (slower)
  └─ Discord: 🟢 "Server A is Online!"
  └─ java -jar server.jar

STOP:
  ├─ rclone to cloud (always) → 💾 Backup safe
  ├─ Try rsync to friend → Success → ✅ Friend has it immediately
  └─ rsync failed → Friend gets it from cloud next time
  └─ Discord: 🔴 "Server A is Offline"
```

## Discord Notifications

| Event | Color | Message |
|---|---|---|
| Server started | 🟢 Green | "Server A is Online!" |
| Server stopped | 🔴 Red | "Server A is Offline. World saved to cloud." |
| Conflict blocked | 🟡 Orange | "Server A tried to start but B is already online!" |

## Handoff Scenarios

### Best case (both online recently)
```
Friend stops B → rsyncs to you in 5 seconds
You start A → rsyncs from friend in 5 seconds → play immediately
```

### Worst case (you played, friend was offline, now friend wants to play)
```
You stop A → rclone uploads to cloud (only changed chunks = fast)
Next day, friend starts B → rclone downloads from cloud → plays
```

### First time ever
```
You start A → no rsync target, no cloud data → fresh world
You play, build, stop → rclone uploads to cloud
Friend starts B → rclone downloads from cloud → continues your build!
```

## Auto-Start

Minecraft should be started manually to avoid accidentally running both. But if desired:

### Ubuntu — systemd

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

### Talos — Docker

```bash
docker run -d \
  --restart unless-stopped \
  --name minecraft \
  --network host \
  -v /opt/minecraft:/opt/minecraft \
  -v /home/user/.config/rclone:/home/user/.config/rclone \
  itzg/minecraft-server:latest
```

### Crontab (both)

```bash
crontab -e
@reboot /opt/minecraft/start-minecraft.sh >> /var/log/minecraft.log 2>&1
```

## Performance Summary

| World Size | rsync handoff (normal) | Cloud fallback (first time) | Cloud backup (incremental) |
|---|---|---|---|
| 100 MB | ~1s | ~30s | ~1-5s |
| 500 MB | ~3s | ~2min | ~5-15s |
| 2 GB | ~10s | ~5min | ~10-30s |
| 10 GB | ~45s | ~25min | ~30s-2min |

After the first sync, **rsync and rclone only transfer changed chunks**, so daily use is fast regardless of world size.

## Notes

- Only **one** server should run at a time — the script enforces this
- Cloud storage acts as backup + fallback; rsync is the fast path
- Talos Linux, Ubuntu, Debian, Raspberry Pi — works on anything with bash

- Only **one** server should run at a time — the script enforces this
- Syncthing syncs the `world/` folder in real-time, so you always have the latest data
- Script uses a local lock file (`.server-lock.json`) to track who was last online
- Talos Linux, Ubuntu, Debian, Raspberry Pi — works on anything with bash + curl