# Minecraft Tailscale Sync 🎮

Two-player Minecraft setup with **Tailscale** + **rsync** + **Discord Webhook**.

You and a friend run separate Minecraft servers on your own machines. This setup:

1. **Syncs world data** between machines via Tailscale + rsync
2. **Prevents conflicts** — only one server runs at a time
3. **Posts to Discord** via a simple webhook when a server starts/stops

## How It Works

```
┌─────────────────┐    Tailscale     ┌─────────────────┐
│  Your Machine   │◄───────────────►│  Friend's Machine│
│  Server A       │   rsync over     │  Server B        │
│  100.x.x.1      │   WireGuard      │  100.x.x.2       │
└────────┬────────┘                  └────────┬────────┘
         │                                    │
         │         Discord Webhook            │
         └────────────────┬───────────────────┘
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
- Both machines can reach each other's Tailscale IP on port `25565`
- Discord channel with a [Webhook](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks) created
- `rsync`, `nc` (netcat), and `curl` available on both machines

## Setup

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
| `MINECRAFT_DIR` | Path to your server dir | Path to your server dir |

### 3. Make the script executable

```bash
chmod +x /opt/minecraft/start-minecraft.sh
```

### 4. Run it!

```bash
./start-minecraft.sh
```

This replaces your normal `java -jar server.jar` command.

## Discord Notifications

The script sends embedded Discord messages via webhook:

| Event | Color | Message |
|---|---|---|
| Server started | 🟢 Green | "Server A is Online!" |
| Server stopped | 🔴 Red | "Server A is Offline. World synced." |
| Conflict | 🟡 Orange | "Server A tried to start but B is already online!" |

## Handoff Flow

1. **Server A** starts → syncs world from B (if B was last online) → notifies Discord
2. Players join Server A, play, build stuff
3. **Server A** stops → pushes world data to B → notifies Discord
4. **Server B** starts → pulls latest world from A → notifies Discord
5. Players join Server B and continue where they left off

## Optional: systemd Service

```ini
# /etc/systemd/system/minecraft.service
[Unit]
Description=Minecraft Server
After=network.target

[Service]
Type=simple
User=minecraft
ExecStart=/opt/minecraft/start-minecraft.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## Notes

- Only **one** server should run at a time
- Syncthing is optional — rsync over Tailscale is fast enough for two machines
- Talos Linux, Ubuntu, Debian, Raspberry Pi — works on anything with bash + curl