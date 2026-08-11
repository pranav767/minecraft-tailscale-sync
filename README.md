# Minecraft Tailscale Sync 🎮

Two-player Minecraft sync across **Talos Linux** (Kubernetes) and **Ubuntu** (bare metal).

You and a friend run separate Minecraft servers on your own machines. This setup keeps the world in sync no matter which server is running — with a **cloud-first** architecture that prioritizes data safety over speed.

## Quick Command Reference

### 🟢 Start Server

| Machine | Command |
|---|---|
| **Talos** | `kubectl -n games scale deployment minecraft --replicas=1` |
| **Ubuntu** | `cd /opt/minecraft && ./start-minecraft.sh` |

### 🔴 Stop Server

| Machine | Command |
|---|---|
| **Talos** | `kubectl -n games scale deployment minecraft --replicas=0` |
| **Ubuntu** | Press `Ctrl+C` or `kill` the process — backup happens automatically |

### 🔄 Restart (stop + backup + download + start)

| Machine | Command |
|---|---|
| **Talos** | `kubectl -n games rollout restart deployment minecraft` |
| **Ubuntu** | `Ctrl+C` then `./start-minecraft.sh` again |

### 📋 Check Status

| Machine | Command |
|---|---|
| **Talos** | `kubectl -n games get pods` |
| **Ubuntu** | Look at terminal output |

### 📡 Connect to Server

Use your **Tailscale machine IP** on port **25565** (shown in Discord when it starts).

---

## The Architecture

```
                    ┌──────────────────────────┐
                    │     Cloud Storage         │
                    │   (Backblaze B2 / S3)     │
                    │                           │
                    │     world/  ← SOURCE      │
                    │            OF TRUTH       │
                    │                           │
                    │     backups/              │
                    │     └─ periodic-...       │
                    │     └─ shutdown-...       │
                    └──┬────────────────────┬───┘
                       │                    │
          ↓ start: DOWNLOAD    shutdown: UPLOAD + backup-dir
                       │                    │
              ┌────────┴──────┐    ┌───────┴────────┐
              │  Talos Linux  │    │    Ubuntu       │
              │  (Server A)   │    │  (Server B)     │
              │               │    │                 │
              │  Kubernetes   │    │  bare metal     │
              │  itzg/mc-srv  │    │  vanilla java   │
              │  Tailscale    │    │  Tailscale      │
              │  sidecar      │    │  rclone + rsync │
              └───────┬───────┘    └───────┬─────────┘
                      │                    │
                      │  rsync ◄─────────► │
                      │  (shutdown only)   │
                      └────────────────────┘

                        Discord Webhook
                        ┌──────────────┐
                        │ 🟢 Online!   │
                        │ 🔴 Offline!  │
                        │ ⚠️ Conflict! │
                        └──────────────┘
```

## Philosophy: Cloud is the Source of Truth

This is the most important design decision in this repo. Here's **why** cloud is the source of truth (not rsync):

| Approach | Power loss? | Split-brain? | Large world? | Complexity |
|---|---|---|---|---|
| **Rsync first** | ❌ Data lost if machine dies before upload | ❌ Server A running, B rsyncs → corrupt | ❌ Timeouts, partial transfers | Simple |
| **Cloud first (ours)** | ✅ At most 5 min lost (periodic backups) | ✅ Warned via Discord | ✅ Incremental rclone, 5-min grace | Moderate |

**The rule:** Every server **always downloads from cloud on start** and **always uploads to cloud on stop**. Rsync is only used as a **speed optimization** on shutdown — if the other machine is reachable, it gets the world instantly instead of waiting for the next cloud download.

## How Sync Works — Step by Step

### Server Starting
```
1. Init container (K8s) / script (Ubuntu) starts
2. rclone sync FROM cloud/world → local world/  ← ALWAYS
3. Optional: rsync FROM friend (if reachable + stopped) for speed
4. Minecraft starts
5. Discord: 🟢 "Server A is Online!"
6. Periodic backup sidecar starts — uploads to cloud every 5 min
   (with --backup-dir, so old versions are saved in cloud/backups/)
```

### Server Stopping (graceful shutdown)
```
1. Minecraft stops (15s wait for final save)
2. rclone sync TO cloud/world  ← ALWAYS (with --backup-dir)
3. Optional: rsync TO friend (if reachable + stopped) for instant handoff
4. Discord: 🔴 "Server A is Offline"
```

### Server Dies (power loss)
```
1. preStop hook NEVER RUNS
2. BUT: periodic backups ran every 5 min while server was running
3. At most 5 minutes of progress is lost
4. Friend starts their server → downloads from cloud → gets last periodic backup
```

## Failure Scenarios — What Can Go Wrong

| # | Scenario | What happens | How bad? |
|---|---|---|---|
| 1 | **Normal handoff**: A→stop→B→start | A uploads to cloud. B downloads from cloud. Rsync to B for speed. | ✅ Safe |
| 2 | **Power loss** 💥 | preStop lost. Periodic backups every 5 min save you. **Max 5 min lost.** | ⚠️ Minor |
| 3 | **preStop timeout** (10GB upload) | 5-min grace period. `--backup-dir` keeps previous safe state in `backups/`. | ⚠️ Recoverable |
| 4 | **Split-brain** (both running) | Sync-agent detects other's open port → **Discord warning**. Both run. **Whoever stops LAST overwrites the other. Manual fix needed.** | ⚠️ Requires manual restore |
| 5 | **Corrupt cloud download** | Old state in `backups/`. Run: `rclone sync remote:backups/.../world ./world` to roll back. | ✅ Recoverable |
| 6 | **First time ever** | Cloud has nothing → fresh world. First periodic backup uploads it. Friend downloads next start. | ✅ Fine |

### How to recover from split-brain (Scenario 4)

If both servers accidentally run at once:

```bash
# 1. Stop both servers
# 2. Decide whose progress to keep (whoever played last)
# 3. On the LOSING machine, restore from the WINNING server's backup:
rclone sync minecraft-b2:minecraft-world-bucket/backups/shutdown-20260811-235959/world ./world
# 4. Start only the winning server
```

## Setup Overview

This repo supports **two different machine types**:

| Machine | OS | How Minecraft runs | Sync method |
|---|---|---|---|
| **Server A** (yours) | **Talos Linux** | Kubernetes (itzg/minecraft-server) | K8s Deployment with init container + sidecar |
| **Server B** (friend's) | **Ubuntu** | Vanilla java server | Bash script (start-minecraft.sh) |

Both connect to the **same cloud bucket** and the **same Tailscale network**.

---

## Part 1: Prerequisites (Both Machines)

### 1. Install Tailscale on both machines

**Ubuntu:**
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

**Talos Linux:** Already handled by the K8s sidecar (see Talos setup below).

### 2. Set up rclone on both machines

```bash
# Install rclone
sudo -v ; curl https://rclone.org/install.sh | sudo bash

# Configure your storage provider (Backblaze B2 recommended — ~$0.006/GB/month)
rclone config
```

Test it:
```bash
rclone mkdir minecraft-b2:minecraft-world-bucket
rclone ls minecraft-b2:minecraft-world-bucket
```

### 3. Create a Discord webhook

1. Go to your Discord channel
2. Channel Settings → Integrations → Webhooks → New Webhook
3. Copy the webhook URL

---

## Part 2: Ubuntu Server (Friend's Machine)

This is a standard Ubuntu server where you run Minecraft directly.

### 2.1 Install dependencies

```bash
sudo apt update
sudo apt install -y rsync netcat-openbsd curl openjdk-21-jre-headless
```

### 2.2 Clone the repo

```bash
git clone https://github.com/pranav767/minecraft-tailscale-sync.git /opt/minecraft
cd /opt/minecraft
```

### 2.3 Configure `start-minecraft.sh`

Edit the configuration section at the top:

```bash
SERVER_NAME="server-agis"           # Unique name for this server
SERVER_LABEL="Agis's Server"         # Friendly name for Discord
OTHER_SERVER_NAME="server-jinx"      # The other server's name
OTHER_TAILSCALE_IP="100.x.x.x"       # Talos server's Tailscale IP
MINECRAFT_PORT=25565
MINECRAFT_DIR="/opt/minecraft/server"
JAR_FILE="server.jar"                # Your Minecraft server jar
JAVA_ARGS="-Xmx4G -Xms2G -jar $JAR_FILE nogui"
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
RCLONE_REMOTE="minecraft-b2:minecraft-world-bucket"
```

### 2.4 Set up the Minecraft server

```bash
mkdir -p /opt/minecraft/server
cd /opt/minecraft/server
# Download your server.jar (Paper, Vanilla, etc.)
wget https://api.papermc.io/v2/projects/paper/versions/1.21.1/builds/.../downloads/paper-...jar -O server.jar
# Accept EULA
echo "eula=true" > eula.txt
chmod +x /opt/minecraft/start-minecraft.sh
```

### 2.5 Start/Stop

```bash
# 🟢 Start server (downloads world from cloud, notifies Discord)
cd /opt/minecraft && ./start-minecraft.sh

# 🔴 Stop server (press Ctrl+C or send SIGTERM)
# The script handles: cloud backup → rsync to friend → Discord notification
```

That's it. The script does everything automatically.

---

## Part 3: Talos Linux (Your Machine)

Talos doesn't allow SSH — everything runs in Kubernetes via `kubectl`.

### 3.1 Talos machine patches (one-time)

Apply these patches to mount the USB storage and allow scheduling on control plane:

```bash
# Note: use 'patch' not 'apply-config' — these are partial patches, not full configs
talosctl patch machineconfig --patch @talos-linux/usb-volume-patch.yaml
talosctl patch machineconfig --patch @talos-linux/allow-scheduling-patch.yaml
```

After patching, reboot the Talos node for the USB disk to be detected:
```bash
talosctl reboot
```

### 3.2 Create secrets

Run these from your local machine (where `kubectl` is configured):

```bash
# rclone config (from your machine where rclone is already configured)
kubectl create secret generic rclone-config \
  --namespace games \
  --from-file=rclone.conf=$HOME/.config/rclone/rclone.conf

# Discord webhook
kubectl create secret generic discord-webhook \
  --namespace games \
  --from-literal=url="https://discord.com/api/webhooks/..."

# Tailscale auth key (create one at https://login.tailscale.com/admin/settings/authkeys)
kubectl create secret generic tailscale-auth \
  --namespace games \
  --from-literal=TS_AUTHKEY="tskey-auth-xxxxxxxxxxxx"
```

### 3.3 Apply Kubernetes manifests

```bash
# In order:
kubectl apply -f talos-linux/pv.yaml
kubectl apply -f talos-linux/tailscale-pv.yaml
kubectl apply -f talos-linux/pvc.yaml
kubectl apply -f talos-linux/tailscale-state-pvc.yaml
kubectl apply -f talos-linux/minecraft-deployment.yaml
kubectl apply -f talos-linux/minecraft-service.yaml
```

### 3.4 What the K8s deployment contains

The `minecraft-deployment.yaml` runs three containers in one pod:

| Container | Role |
|---|---|
| **minecraft** | `itzg/minecraft-server` — the actual game server |
| **sync-agent** | Alpine container running rclone. Handles periodic backups (every 5 min) + preStop shutdown hook. Also checks for split-brain via Tailscale. |
| **tailscale** | Tailscale sidecar — connects the pod to your Tailnet |

Plus an **init container** (`sync-pre-start`) that downloads the world from cloud before Minecraft starts.

### 3.5 Start/Stop

```bash
# 🟢 Start server (downloads world from cloud, notifies Discord)
kubectl -n games scale deployment minecraft --replicas=1

# 🔴 Stop server (triggers cloud backup → rsync → Discord notification)
kubectl -n games scale deployment minecraft --replicas=0

# 🔄 Restart (stop → backup → download world → start)
kubectl -n games rollout restart deployment minecraft
```

### 3.6 Monitoring

```bash
# View all container logs
kubectl -n games logs -l app=minecraft

# Watch sync agent logs (periodic backups, Discord)
kubectl -n games logs -l app=minecraft -c sync-agent -f

# Watch Minecraft server logs
kubectl -n games logs -l app=minecraft -c minecraft -f
```

### 3.7 Connect

Use the **Tailscale IP** of the pod on port **25565**. The IP is shown in the Discord message when the server starts.

Or connect via the Talos node IP on port **30565** (NodePort).

---

## Part 4: Discord Notifications

| Event | Color | Message |
|---|---|---|
| Server started | 🟢 Green | "Server A is Online!" |
| Server stopped | 🔴 Red | "Server A is Offline. World saved to cloud." |
| Split-brain detected | 🟡 Orange | Warning that both servers are running simultaneously |

---

## Part 5: Performance & Data Safety

### How much data can you lose?

| Scenario | Data loss | Why |
|---|---|---|
| Graceful shutdown | **None** | preStop uploads to cloud |
| Power loss | **≤5 minutes** | Periodic backup ran within last 5 min |
| preStop timeout (huge world) | **Previous backup safe** | `--backup-dir` preserves old state |
| Both run at once | **Depends on who stops last** | Manual recovery needed |

### Transfer speeds

| World Size | Cloud download (init) | Cloud backup (periodic) | Rsync to friend |
|---|---|---|---|
| 100 MB | ~30s | ~1-5s | ~1s |
| 500 MB | ~2min | ~5-15s | ~3s |
| 2 GB | ~5min | ~10-30s | ~10s |
| 10 GB | ~25min | ~30s-2min | ~45s |

All times are incremental — after the first sync, only changed chunks are transferred.

---

## Part 6: Recovery Commands

```bash
# List available backups in cloud
rclone ls minecraft-b2:minecraft-world-bucket/backups/

# Restore from a specific backup (Ubuntu)
cd /opt/minecraft/server
rclone sync minecraft-b2:minecraft-world-bucket/backups/shutdown-20260811-235959/world ./world

# Restore from a specific backup (Talos)
kubectl -n games exec deploy/minecraft -c sync-agent -- \
  rclone sync minecraft-b2:minecraft-world-bucket/backups/shutdown-20260811-235959/world /data/world

# Manual restore using helper pod (Talos)
kubectl apply -f talos-linux/mc-restore-helper.yaml
kubectl -n games exec mc-restore-helper -- \
  rclone sync minecraft-b2:minecraft-world-bucket/backups/.../world /data/world
kubectl delete pod mc-restore-helper
```

---

## File Reference

| File | Used on | Purpose |
|---|---|---|
| `start-minecraft.sh` | **Ubuntu** | Bash script with full sync logic (cloud + rsync + Discord) |
| `talos-linux/minecraft-deployment.yaml` | **Talos** | K8s Deployment (Minecraft server + sync-agent + Tailscale) |
| `talos-linux/minecraft-service.yaml` | **Talos** | NodePort service on port 30565 |
| `talos-linux/pv.yaml` / `talos-linux/pvc.yaml` | **Talos** | USB persistent storage for world data |
| `talos-linux/tailscale-pv.yaml` / `talos-linux/tailscale-state-pvc.yaml` | **Talos** | Tailscale state persistence |
| `talos-linux/usb-volume-patch.yaml` | **Talos** | Machine config patch to mount USB disk |
| `talos-linux/allow-scheduling-patch.yaml` | **Talos** | Machine config patch for control plane scheduling |
| `talos-linux/mc-restore-helper.yaml` | **Talos** | Helper pod for manual world restore |
