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

## ⚠️ Important: What About Syncthing?

**You don't need Syncthing.** The script uses `rsync` directly over Tailscale to sync world data. Here's why:

- **rsync over Tailscale** is already fast, encrypted, and direct — no third-party service needed
- **Syncthing would cause conflicts** — if both servers somehow ran at the same time, Syncthing would try to merge two independently-modified worlds, corrupting chunks and causing data loss
- **rsync is one-directional** — the script always syncs from the *last running* server to the *next starting* server, which is exactly what you want

### What If Both Servers Are On at the Same Time?

The script **prevents this** — but here's what happens in each scenario:

| Scenario | What Happens |
|---|---|
| **Script is used correctly** | ✅ The `is_other_server_online()` check pings the other machine's port. If it's reachable, the script **refuses to start** and sends a ⚠️ warning to Discord |
| **Someone bypasses the script** (runs `java -jar` directly) | ⚠️ Both servers run independently. Worlds **diverge** — changes on A are lost when B syncs next. Players might see different worlds. **Don't do this.** |
| **Network issue / Tailscale down** | ❌ The port check fails to detect the other server. Both could start. The Discord webhook will also fail silently. |

**Bottom line:** Always use the script to start the server, and make sure Tailscale is running. The script is your safety net.

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

## 🤖 Auto-Start on Boot

You don't want to run the script manually every time. Here's how to set it up for each OS.

### Ubuntu / Debian (Friend's Machine) — systemd Service

Create a service file:

```bash
sudo nano /etc/systemd/system/minecraft.service
```

```ini
[Unit]
Description=Minecraft Server
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=minecraft
WorkingDirectory=/opt/minecraft/server
ExecStart=/opt/minecraft/start-minecraft.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable it to start on boot:

```bash
sudo systemctl daemon-reload
sudo systemctl enable minecraft.service
sudo systemctl start minecraft.service   # starts now
sudo systemctl status minecraft.service  # check status
```

### Talos Linux (Your Machine)

Talos Linux doesn't have systemd. You have a few options depending on how you run Minecraft:

#### Option A: If running as a static pod (recommended for Talos)

Create a static pod manifest. The script runs in a sidecar init container, or you can run the whole thing in a container:

```yaml
# /var/lib/rancher/kubelet/static-pods/minecraft.yaml
apiVersion: v1
kind: Pod
metadata:
  name: minecraft-server
  namespace: default
  labels:
    app: minecraft
spec:
  hostNetwork: true  # Needed for Tailscale reachability
  containers:
  - name: minecraft
    image: itzg/minecraft-server:latest
    env:
    - name: EULA
      value: "TRUE"
    - name: ONLINE_MODE
      value: "false"
    ports:
    - containerPort: 25565
    volumeMounts:
    - name: data
      mountPath: /data
  - name: sync-sidecar
    image: alpine:latest
    command:
    - /bin/sh
    - -c
    - |
      apk add --no-cache rsync curl netcat-openbsd
      # Copy the script and run it
      /opt/minecraft/start-minecraft.sh
    volumeMounts:
    - name: data
      mountPath: /data
    - name: scripts
      mountPath: /opt/minecraft
  volumes:
  - name: data
    hostPath:
      path: /opt/minecraft/server
  - name: scripts
    hostPath:
      path: /opt/minecraft
```

#### Option B: If running as a regular process on Talos (using `talosctl`)

Talos supports running arbitrary containers via `talosctl`. Wrap the script in a container:

```dockerfile
# Dockerfile
FROM alpine:latest
RUN apk add --no-cache bash rsync curl netcat-openbsd openjdk17-jre
COPY start-minecraft.sh /start-minecraft.sh
RUN chmod +x /start-minecraft.sh
CMD ["/start-minecraft.sh"]
```

Then build and run with:

```bash
docker build -t minecraft-sync .
docker run -d --name minecraft \
  --network host \
  -v /opt/minecraft/server:/opt/minecraft/server \
  minecraft-sync
```

And set it to restart automatically via a Talos scheduled task or your container runtime's restart policy.

#### Option C: Crontab @reboot

Simplest option — works on both Talos and Ubuntu if you have a traditional shell:

```bash
crontab -e
```

Add this line:
```
@reboot /opt/minecraft/start-minecraft.sh >> /var/log/minecraft.log 2>&1
```

## Notes

- Only **one** server should run at a time — the script enforces this
- Syncthing is **not recommended** — rsync over Tailscale is faster and safer for this use case
- Talos Linux, Ubuntu, Debian, Raspberry Pi — works on anything with bash + curl