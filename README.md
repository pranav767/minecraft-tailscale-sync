# Minecraft Tailscale Sync 🎮

Multi-player Minecraft sync across **Talos Linux** (Kubernetes) and **Ubuntu** (bare metal).

Up to **6-7 players** can play at a time. Only one server runs at a time. The world syncs via **Google Drive** — download on start, upload on stop. Simple.

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
| **Ubuntu** | Press `Ctrl+C` — backup happens automatically |

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
                    │   (Google Drive 15GB)     │
                    │                           │
                    │     world/  ← SOURCE      │
                    │            OF TRUTH       │
                    └──────┬────────────────┬───┘
                           │                │
              ↓ start: DOWNLOAD   stop: UPLOAD
                           │                │
                  ┌────────┴──────┐  ┌─────┴──────────┐
                  │  Talos Linux  │  │    Ubuntu       │
                  │  (Server A)   │  │  (Server B)     │
                  │               │  │                 │
                  │  Kubernetes   │  │  bare metal     │
                  │  itzg/mc-srv  │  │  vanilla java   │
                  │  Tailscale    │  │  Tailscale      │
                  │  sidecar      │  │  rclone         │
                  └───────┬───────┘  └───────┬─────────┘
                          │                  │
                          └──────┬──────┬────┘
                                 │      │
                           Discord Webhook
                           ┌──────────────┐
                           │ 🟢 Online!   │
                           │ 🔴 Offline!  │
                           └──────────────┘
```

## How It Works

### Server Starting
```
1. Init container (K8s) / script (Ubuntu) starts
2. rclone sync FROM cloud/world → local world/
3. Minecraft starts
4. Discord: 🟢 "Server is Online!"
```

### Server Stopping
```
1. Minecraft stops (Ctrl+C or scale to 0)
2. Wait 15s for world save
3. rclone sync local world/ → cloud/world
4. Discord: 🔴 "Server is Offline"
5. Other machine can now start safely
```

That's it. No rsync, no periodic backups, no daily snapshots. Cloud is the source of truth.

## Why This Simplicity

| Concern | How it's handled |
|---|---|
| **6-7 players** | 2.5-3GB RAM allocated, PaperMC for performance |
| **World sync** | Download on start, upload on stop — always |
| **Data loss risk** | At most 1 session lost (if machine dies before upload) |
| **Split-brain** | Don't run both servers at once. Discord tells you when it's online/offline |
| **Backup** | Every shutdown uploads to cloud. That's your backup. |
| **Power failure** | Rare. If it happens, the last successful upload is your world. |

## Setup

### Prerequisites (Both Machines)

#### 1. Install Tailscale

**Ubuntu:**
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

**Talos Linux:** Handled by the K8s sidecar (see Talos setup below).

#### 2. Set up rclone with Google Drive

```bash
# Install rclone
sudo -v ; curl https://rclone.org/install.sh | sudo bash

# Configure Google Drive remote (OAuth — you'll get a URL to authorize)
rclone config
# → n (new remote)
# → name: minecraft-gdrive
# → Storage: drive
# → client_id: (leave blank)
# → client_secret: (leave blank)
# → scope: drive
# → root_folder_id: (leave blank)
# → service_account_file: (leave blank)
# → Edit advanced config? n
# → Use auto config? y   ← opens browser to authorize with your Google account
# → Configure this as a Shared Drive? n
# → y (yes this is OK)
```

Test it:
```bash
rclone mkdir minecraft-gdrive:minecraft-world-sync
rclone ls minecraft-gdrive:minecraft-world-sync
```

> ⚠️ **Important**: Both machines must authorize with the **same Google account** and use the **same remote name** (`gdrive`). The rclone config file contains the auth token — share the `rclone.conf` between machines (see Talos setup below).

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

### Ubuntu Server Setup

```bash
# Install dependencies
sudo apt update
sudo apt install -y openjdk-21-jre-headless curl

# Clone repo
git clone https://github.com/pranav767/minecraft-tailscale-sync.git /opt/minecraft
cd /opt/minecraft

# Edit configuration — set SERVER_NAME, SERVER_LABEL, RCLONE_REMOTE,
# DISCORD_WEBHOOK_URL, and JAVA_ARGS at the top of the script

# Download PaperMC server
mkdir -p /opt/minecraft/server
cd /opt/minecraft/server
# Download paper-1.21.1.jar (or latest version)
echo "eula=true" > eula.txt
chmod +x /opt/minecraft/start-minecraft.sh

# Start (downloads world from cloud, notifies Discord)
cd /opt/minecraft && ./start-minecraft.sh

# Stop with Ctrl+C — uploads world to cloud automatically
```

### Talos Linux Setup

#### Machine Patches (one-time)

```bash
talosctl patch machineconfig --patch @talos-linux/usb-volume-patch.yaml
talosctl patch machineconfig --patch @talos-linux/allow-scheduling-patch.yaml
talosctl reboot
```

#### Create Secrets

```bash
# rclone config
kubectl create secret generic rclone-config \
  --namespace games \
  --from-file=rclone.conf=$HOME/.config/rclone/rclone.conf

# Discord webhook
kubectl create secret generic discord-webhook \
  --namespace games \
  --from-literal=url="https://discord.com/api/webhooks/..."

# Tailscale auth key (create at https://login.tailscale.com/admin/settings/authkeys)
kubectl create secret generic tailscale-auth \
  --namespace games \
  --from-literal=TS_AUTHKEY="tskey-auth-xxxxxxxxxxxx"
```

#### Apply Manifests

```bash
kubectl apply -f talos-linux/pv.yaml
kubectl apply -f talos-linux/tailscale-pv.yaml
kubectl apply -f talos-linux/pvc.yaml
kubectl apply -f talos-linux/tailscale-state-pvc.yaml
kubectl apply -f talos-linux/minecraft-deployment.yaml
kubectl apply -f talos-linux/minecraft-service.yaml
```

#### K8s Pod Architecture

| Container | Role |
|---|---|
| **minecraft** | `itzg/minecraft-server` — PaperMC with 2.5GB RAM |
| **sync-agent** | Discord notifications + preStop shutdown hook (upload to cloud) |
| **tailscale** | Tailscale sidecar — connects pod to your tailnet |

Plus an **init container** that downloads world from cloud before Minecraft starts.

#### Start/Stop

```bash
# 🟢 Start
kubectl -n games scale deployment minecraft --replicas=1

# 🔴 Stop
kubectl -n games scale deployment minecraft --replicas=0

# View logs
kubectl -n games logs -l app=minecraft -c minecraft -f
kubectl -n games logs -l app=minecraft -c sync-agent -f
```

#### Connect

Use the **Tailscale IP** of the pod on port **25565** (shown in Discord when server starts). Or use the Talos node IP on port **30565** (NodePort).

---

## Discord Notifications

| Event | Color | Message |
|---|---|---|
| Server started | 🟢 Green | "Server is Online!" with Tailscale IP |
| Server stopped | 🔴 Red | "Server is Offline. World uploaded to cloud." |

---

## Failure Scenarios

| Scenario | Impact |
|---|---|
| **Graceful shutdown** | ✅ World saved to cloud |
| **Power loss** | ⚠️ Session lost. Last clean upload is safe |
| **Both run at once** | ⚠️ Whoever stops last overwrites. Check Discord to avoid |
| **Corrupt world** | ✅ Restore from cloud world/ or use mc-restore-helper |

---

## Files

| File | Purpose |
|---|---|
| `start-minecraft.sh` | Ubuntu startup/shutdown script |
| `talos-linux/minecraft-deployment.yaml` | K8s deployment (Minecraft + sync + Tailscale) |
| `talos-linux/minecraft-service.yaml` | K8s NodePort service |
| `talos-linux/pv.yaml` | USB storage PersistentVolume |
| `talos-linux/pvc.yaml` | USB storage PersistentVolumeClaim |
| `talos-linux/tailscale-pv.yaml` | Tailscale state PV |
| `talos-linux/tailscale-state-pvc.yaml` | Tailscale state PVC |
| `talos-linux/allow-scheduling-patch.yaml` | Allow pods on control plane |
| `talos-linux/usb-volume-patch.yaml` | Mount USB disk in Talos |
| `talos-linux/mc-restore-helper.yaml` | Debug pod for manual restore |
