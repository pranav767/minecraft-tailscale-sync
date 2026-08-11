# Kubernetes Deployment for Talos Linux

Since Talos Linux doesn't allow SSH, everything runs in Kubernetes. This setup uses:

- **`itzg/minecraft-server`** — the Minecraft server container
- **Tailscale sidecar** — connects the pod to your Tailnet so pods can talk to each other
- **Init container** — syncs the world before Minecraft starts (rsync → cloud fallback)
- **preStop hook** — syncs the world on shutdown (cloud backup + rsync to friend)

## Prerequisites on Talos

```bash
# You need kubectl and talosctl configured
export TALOSCONFIG=~/talosconfig
export KUBECONFIG=~/kubeconfig
```

## Setup

### 1. Create the namespace

```bash
kubectl apply -f k8s/namespace.yaml
```

### 2. Set up rclone config

On your local machine (where you have `rclone` configured):

```bash
kubectl create secret generic rclone-config \
  --namespace minecraft \
  --from-file=rclone.conf=$HOME/.config/rclone/rclone.conf
```

### 3. Set up Discord webhook

```bash
kubectl create secret generic discord-webhook \
  --namespace minecraft \
  --from-literal=url="https://discord.com/api/webhooks/your-webhook-url"
```

### 4. Set up Tailscale auth (optional but recommended)

Create an [auth key](https://login.tailscale.com/admin/settings/authkeys) in the Tailscale admin panel:

```bash
kubectl create secret generic tailscale-auth \
  --namespace minecraft \
  --from-literal=authkey="tskey-auth-xxxxxxxxxxxx"
```

Without this, you'll need to authenticate the pod manually via `kubectl exec`.

### 5. Configure the StatefulSet

Edit `k8s/statefulset.yaml` and update:

| Field | Your Machine | Friend's Machine |
|---|---|---|
| `SERVER_NAME` | `server-a` | `server-b` |
| `OTHER_TAILSCALE_IP` | Friend's Tailscale IP | Your Tailscale IP |
| `RCLONE_REMOTE` | Your rclone remote:bucket | Same rclone remote:bucket |

### 6. Deploy

```bash
# Apply the sync script ConfigMap
kubectl apply -f k8s/sync-configmap.yaml

# Deploy the StatefulSet
kubectl apply -f k8s/statefulset.yaml

# Expose the service (if you want external access)
kubectl apply -f k8s/service.yaml
```

### 7. Check status

```bash
kubectl -n minecraft get pods
kubectl -n minecraft logs -l app=minecraft --tail=50
```

## How It Works on Talos

```
Pod startup:
  Init Container (sync-pre-start):
    ├─ Try rsync from friend's pod (via Tailscale IP)
    │  └─ Success → world synced in seconds
    └─ rsync failed → rclone download from cloud
  └─ Minecraft container starts

Pod shutdown (kubectl delete pod, or scale to 0):
  preStop hook:
    ├─ rclone upload to cloud (always)
    └─ Try rsync to friend's pod
  └─ Container stops
```

## Managing the Server

```bash
# View logs
kubectl -n minecraft logs -f deployment/minecraft

# Stop the server (triggers cloud backup)
kubectl -n minecraft scale statefulset minecraft --replicas=0

# Start the server (triggers world sync)
kubectl -n minecraft scale statefulset minecraft --replicas=1

# Exec into the pod (for troubleshooting)
kubectl -n minecraft exec -it deployment/minecraft -c minecraft -- /bin/bash

# Delete everything
kubectl delete namespace minecraft
```

## Important Notes

- **Only one pod should run at a time** across both machines — the script doesn't enforce this in K8s, so coordinate manually
- The Tailscale sidecar gives the pod a Tailscale IP, which is how pods on different machines discover each other
- Persistent storage is handled by a `PersistentVolumeClaim` — data survives pod restarts
- If you're on a single-node Talos cluster, make sure you have enough RAM (at least 6GB free for Minecraft + overhead)
