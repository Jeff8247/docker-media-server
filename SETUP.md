# Setup Guide

Follow these steps in order before starting the stack for the first time.

---

## Step 1 — Fill in `.env`

```bash
nano .env
```

| Variable | Where to get it |
|---|---|
| `VPN_USER` | The `p1234567`-style username from your PIA OpenVPN config file (download from PIA → Downloads → OpenVPN) |
| `VPN_PASSWORD` | Your PIA account password (the same one used to log into the PIA website) |
| `CF_DNS_API_TOKEN` | Cloudflare → My Profile → API Tokens → Create Token → "Edit zone DNS" template |
| `CLOUDFLARE_TUNNEL_TOKEN` | Cloudflare Zero Trust → Networks → Tunnels → your tunnel → Configure → copy token |

---

## Step 2 — Set Media Directory Permissions

Confirm your user's UID and GID match `PUID` and `PGID` in `.env`:

```bash
id
```

The default on a fresh Linux install is `1000:1000`. Set ownership and permissions on the media directory:

```bash
export ROOT_MEDIA_DIR=/path/to/your/media
sudo chown -R 1000:1000 $ROOT_MEDIA_DIR
find $ROOT_MEDIA_DIR -type d -exec chmod 755 {} \;
find $ROOT_MEDIA_DIR -type f -exec chmod 644 {} \;
```

---

## Step 3 — Pre-create Config Directories

Docker creates volume mount points as root if they don't exist, which breaks container startup. Create them first with the correct ownership:

```bash
sudo mkdir -p /opt/docker/traefik/letsencrypt \
              /opt/docker/traefik/logs \
              /opt/docker/gluetun \
              /opt/docker/plex \
              /opt/docker/tautulli \
              /opt/docker/qbittorrent \
              /opt/docker/prowlarr \
              /opt/docker/sonarr \
              /opt/docker/radarr \
              /opt/docker/lidarr \
              /opt/docker/bazarr \
              /opt/docker/wg-easy \
              /opt/docker/ollama \
              /opt/docker/open-webui
sudo chown -R 1000:1000 /opt/docker
```

---

## Step 4 — Create Download Directories

```bash
mkdir -p $ROOT_MEDIA_DIR/downloads/complete
mkdir -p $ROOT_MEDIA_DIR/downloads/incomplete
```

---

## Step 5 — Install VAAPI Drivers (Hardware Transcoding)

```bash
sudo apt install mesa-va-drivers vainfo
```

Add your user to the `render` and `video` groups so containers can access the GPU:

```bash
sudo usermod -aG render,video $USER
```

**Log out and back in** for the group change to take effect, then verify:

```bash
ls -la /dev/dri/
# Should show renderD128 and card0

vainfo
# Should list VAProfileH264 and VAProfileHEVC
```

If `renderD128` is missing, load the amdgpu kernel module:

```bash
sudo modprobe amdgpu
```

---

## Step 6 — Configure Cloudflare Tunnel Public Hostnames

In **Cloudflare Zero Trust → Networks → Tunnels → your tunnel → Public Hostnames**, add a route for each service pointing to Traefik:

| Subdomain | URL |
|---|---|
| `traefik.yourdomain.com` | `http://traefik:80` |
| `plex.yourdomain.com` | `http://traefik:80` |
| `tautulli.yourdomain.com` | `http://traefik:80` |
| `sonarr.yourdomain.com` | `http://traefik:80` |
| `radarr.yourdomain.com` | `http://traefik:80` |
| `lidarr.yourdomain.com` | `http://traefik:80` |
| `bazarr.yourdomain.com` | `http://traefik:80` |
| `prowlarr.yourdomain.com` | `http://traefik:80` |
| `wireguard.yourdomain.com` | `http://traefik:80` |
| `chat.yourdomain.com` | `http://traefik:80` |

> All traffic routes through Traefik — Cloudflare Tunnel does not connect directly to individual containers.
>
> **Why HTTP and not HTTPS?** Cloudflare terminates public TLS at the edge. The internal connection from `cloudflared` to Traefik uses plain HTTP on port 80, which avoids certificate verification issues.

> **qBittorrent is not in this list.** Its DNS record is set to DNS-only (grey cloud) in Cloudflare — traffic goes directly to the server on port 443, handled by Traefik. Access is restricted to allowed IPs via Traefik middleware.

---

## Step 7 — Start the Stack

```bash
docker compose up -d
```

Watch the logs to confirm everything comes up cleanly:

```bash
docker compose logs -f
```

Check Gluetun specifically to confirm the VPN connects before continuing:

```bash
docker compose logs -f gluetun
# Look for: "Healthy!" in the Gluetun output
```

---

## Step 8 — Configure Apps

Open each app and configure paths. See **README.md → First-Time App Configuration** for full details. Quick reference:

### qBittorrent — `https://qbittorrent.yourdomain.com`
- Default Save Path → `/data/downloads/complete`
- Incomplete Downloads → `/data/downloads/incomplete`

### Prowlarr — `https://prowlarr.yourdomain.com`
1. **Indexers → Add Indexer** — add your torrent indexers
2. **Settings → Apps** — connect to Radarr, Sonarr, and Lidarr:

| App | URL | API Key |
|---|---|---|
| Radarr | `http://radarr:7878` | Radarr → Settings → General |
| Sonarr | `http://sonarr:8989` | Sonarr → Settings → General |
| Lidarr | `http://lidarr:8686` | Lidarr → Settings → General |

### Radarr — `https://radarr.yourdomain.com`
- Root Folder → `/data/movies`
- Settings → Download Clients → Add qBittorrent → Host: `gluetun`, Port: `8080`, Category: `radarr`

### Sonarr — `https://sonarr.yourdomain.com`
- Root Folder → `/data/tv`
- Settings → Download Clients → Add qBittorrent → Host: `gluetun`, Port: `8080`, Category: `sonarr`

### Lidarr — `https://lidarr.yourdomain.com`
- Root Folder → `/data/music`
- Settings → Download Clients → Add qBittorrent → Host: `gluetun`, Port: `8080`, Category: `lidarr`

### Bazarr — `https://bazarr.yourdomain.com`
- Settings → Sonarr → Host: `sonarr`, Port: `8989`, API Key: *(from Sonarr → Settings → General)*
- Settings → Radarr → Host: `radarr`, Port: `7878`, API Key: *(from Radarr → Settings → General)*

### Plex — `https://plex.yourdomain.com`
- Sign in and add libraries: Movies → `/data/movies`, TV Shows → `/data/tv`, Music → `/data/music`
- Settings → Transcoder → Enable hardware acceleration and hardware-accelerated encoding

### Tautulli — `https://tautulli.yourdomain.com`
- Sign in with your Plex account when prompted, or connect manually via `http://plex:32400`

### WireGuard — `https://wireguard.yourdomain.com`
- Set your password hash via `PASSWORD_HASH` in `.env` before starting (generate with `docker run --rm ghcr.io/wg-easy/wg-easy wgpw YOUR_PASSWORD`)
- Add VPN clients via the web UI

### Open WebUI — `https://chat.yourdomain.com`
- On first launch, create an admin account
- Ollama is pre-configured via `OLLAMA_BASE_URL` — models are available immediately once Ollama has finished pulling on startup
