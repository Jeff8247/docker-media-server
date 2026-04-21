# Media Server Docker Stack

This project sets up a comprehensive, automated media server environment using Docker Compose. It integrates media management, downloading, and streaming services, all protected by a VPN and accessible via a secure reverse proxy with a Cloudflare Tunnel for zero-open-port exposure.

## Overview

| Service | Role |
|---|---|
| **Traefik v3** | Reverse proxy — SSL via Let's Encrypt (Cloudflare DNS challenge), security headers, routes all traffic |
| **Cloudflared** | Cloudflare Tunnel client — exposes services without opening any inbound firewall ports |
| **socket-proxy** | Docker socket proxy — Traefik and Watchtower access Docker via this instead of mounting the socket directly |
| **Gluetun** | VPN client (PIA, OpenVPN) — all download traffic is tunnelled through here |
| **qBittorrent** | BitTorrent client — runs inside Gluetun's network namespace, all traffic goes through the VPN |
| **Plex** | Media server — hardware transcoding via VAAPI |
| **Tautulli** | Plex monitoring and statistics |
| **Sonarr** | TV show automation |
| **Radarr** | Movie automation |
| **Lidarr** | Music automation |
| **Bazarr** | Subtitle automation |
| **Prowlarr** | Central indexer manager — syncs torrent indexers to all arrs |
| **Watchtower** | Automatically updates running containers (nickfedor/watchtower fork) |
| **wg-easy** | WireGuard VPN server with a web UI for managing client configs |
| **minecraft-survival** | Minecraft Java server — survival world, port 25565 |
| **minecraft-creative** | Minecraft Java server — creative world, port 25566 |

## Prerequisites

- Docker and Docker Compose installed
- A domain name with Cloudflare DNS
- A Private Internet Access (PIA) subscription
- A Cloudflare Zero Trust account (free tier) for the tunnel
- AMD GPU with VAAPI support (for hardware transcoding)
- Root media directory (e.g. `/mnt/media`) with the structure below

## Required Directory Structure

The unified mount approach requires a specific layout on the host. Create this before starting the stack:

```
/mnt/media/          ← ROOT_MEDIA_DIR
├── downloads/
│   ├── complete/         ← qBittorrent saves finished downloads here
│   └── incomplete/       ← qBittorrent in-progress downloads
├── movies/               ← Radarr library
├── tv/                   ← Sonarr library
├── music/                ← Lidarr library
└── transcode/            ← Plex temporary transcoding segments (safe to clear at any time)
```

All containers mount `ROOT_MEDIA_DIR` at `/data`, so paths are consistent across services — `/data/downloads/complete/` in qBittorrent is the same directory as `/data/downloads/complete/` in Radarr.

## Docker Data Directory

Container config and persistent data is stored under `/opt/docker/`. This is a common convention for bind-mount volumes — it keeps container data separate from both the Docker engine (`/var/lib/docker/`) and user home directories.

`/opt/` is root-owned, so create the directories with `sudo` before starting the stack:

```bash
sudo mkdir -p /opt/docker/{traefik/letsencrypt,traefik/logs,gluetun,plex,tautulli,qbittorrent,prowlarr,sonarr,radarr,lidarr,bazarr,wg-easy,minecraft-survival,minecraft-creative}
sudo chown -R $USER:$USER /opt/docker
```

## Configuration

### 1. .env File

| Variable | Description |
|---|---|
| `DOMAIN` | Your root domain (e.g. `yourdomain.com`). Subdomains for each service are derived from this. |
| `SERVER_IP` | Your server's public IP. Run `curl ifconfig.me` to find it. Used by Plex for direct client connections and wg-easy for WireGuard. |
| `LOCAL_SUBNET` | Your LAN subnet in CIDR notation (e.g. `192.168.1.0/24`). Used to restrict qBittorrent access to local IPs only. |
| `ACME_EMAIL` | Email address for Let's Encrypt certificate expiry notifications. |
| `TZ` | Timezone in tz database format (e.g. `America/New_York`). Full list at [Wikipedia](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones). |
| `PUID` / `PGID` | User/group ID that containers run as for file permissions. Run `id -u` and `id -g` to get your values. Default on a fresh Linux install is `1000`/`1000`. |
| `ROOT_MEDIA_DIR` | Absolute path to your media root directory (e.g. `/mnt/media`). All media containers mount this at `/data`. |
| `VPN_USER` / `VPN_PASSWORD` | PIA credentials. `VPN_USER` is the `p1234567`-style username from your PIA OpenVPN config (PIA dashboard → Downloads → OpenVPN), not your login email. `VPN_PASSWORD` is your PIA account password. |
| `VPN_REGION` | PIA server region (e.g. `Switzerland`). Full list of valid region names in the [Gluetun wiki](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/private-internet-access.md). |
| `CF_DNS_API_TOKEN` | Cloudflare API token for Traefik to complete the DNS-01 challenge. Create at **Cloudflare → My Profile → API Tokens → Create Token** using the "Edit zone DNS" template. Scope it to your specific zone. |
| `CLOUDFLARE_TUNNEL_TOKEN` | Token for the Cloudflare Tunnel. Found at **Cloudflare Zero Trust → Networks → Tunnels → your tunnel → Configure**. See Cloudflare Tunnel Setup below. |
| `PASSWORD_HASH` | Bcrypt hash of your wg-easy web UI password. Generate with: `docker run --rm ghcr.io/wg-easy/wg-easy wgpw YOUR_PASSWORD` |

### 2. Cloudflare Tunnel Setup

The `cloudflared` service creates an outbound-only tunnel to Cloudflare's edge — **no inbound firewall ports need to be opened**.

1. Go to **Cloudflare Zero Trust → Networks → Tunnels**
2. Click **Create a tunnel** → select **Cloudflared** → give it a name
3. Copy the tunnel token and set it as `CLOUDFLARE_TUNNEL_TOKEN` in `.env`
4. Under the tunnel's **Public Hostnames** tab, add a route for each service pointing to `http://traefik:80`

See **SETUP.md → Step 7** for the full hostnames table.

### 3. Unified Volumes (TRaSH Guides)

The stack uses a single mount point (`/data`) inside all media-handling containers. This is critical for:

- **Atomic Moves:** Instant file moves from downloads to library (same filesystem, no copying).
- **Hardlinks:** Seed torrents while the library copy exists as a hardlink — zero extra disk space used.

Plex mounts `/data` as **read-only** (`:ro`) since it only reads media. The arrs and qBittorrent retain write access.

### 4. Hardware Transcoding (AMD GPU / VAAPI)

The GPU supports **VAAPI** for hardware-accelerated encode/decode. Plex is pre-configured to use `/dev/dri/renderD128`.

#### Host Prerequisites

Install the Mesa VAAPI driver and verify the GPU is visible:
```bash
sudo apt install mesa-va-drivers vainfo
vainfo
```
You should see `VAProfileH264` and `VAProfileHEVC` in the output. If the device node is missing:
```bash
lsmod | grep amdgpu
# If missing:
sudo modprobe amdgpu
```

Add your user to the `render` and `video` groups so the containers can access the device:
```bash
sudo usermod -aG render,video $USER
# Log out and back in for this to take effect
```

Confirm the node exists before starting the stack:
```bash
ls -la /dev/dri/
# Should show renderD128 and card0
```

#### Enable in Plex

1. Open Plex Web → **Settings → Transcoder**
2. Enable **"Use hardware acceleration when available"**
3. Enable **"Use hardware-accelerated video encoding"**
4. Save. When a transcode session starts you'll see `(hw)` next to the stream in **Now Playing**.

> **Note:** Check your GPU's VAAPI capabilities with `vainfo`. AV1 decode is not supported on all hardware — unsupported codecs fall back to software transcoding.

### 5. Security

- **Socket Proxy:** Traefik and Watchtower connect to Docker via `socket-proxy` (`tecnativa/docker-socket-proxy`) instead of mounting `/var/run/docker.sock` directly. The proxy exposes only the specific API endpoints each service needs.
- **Security Headers:** HSTS, X-Frame-Options, XSS protection, Content-Type sniffing protection, `Referrer-Policy: strict-origin-when-cross-origin`, and `Permissions-Policy` applied globally to all public-facing services via a shared Traefik middleware.
- **Read-only media mount:** Plex mounts media as `:ro` — it cannot modify or delete files.
- **Traefik dashboard:** Protected by Cloudflare Access — unauthenticated requests are blocked at the Cloudflare edge before reaching Traefik.
- **VPN kill switch:** qBittorrent runs inside Gluetun's network namespace — if the VPN drops, all download traffic stops immediately.
- **qBittorrent IP allowlist:** qBittorrent is not behind the Cloudflare Tunnel. Its DNS record is DNS-only (grey cloud), and access is restricted to trusted IPs via a Traefik `ipAllowList` middleware defined in the container labels.
- **Access logging:** Traefik logs all 4xx/5xx error responses to `/opt/docker/traefik/logs/access.log`. Normal traffic is not logged, keeping disk usage minimal.
- **Health checks:** All containers include health checks. Traefik exposes a `/ping` endpoint used by its health check.

#### Traefik Dashboard — Cloudflare Access Setup

The Traefik dashboard is protected solely by Cloudflare Access. Any unauthenticated request is blocked at the Cloudflare edge before reaching Traefik.

1. Go to **Cloudflare Zero Trust → Access → Applications → Add an application**
2. Choose **Self-hosted**
3. Set **Application domain** to `traefik.${DOMAIN}`
4. Create a policy: **Action:** Allow, **Include rule:** Emails → your email address
5. Click **Add application**

The `cloudflared` daemon bypasses the Access check automatically via its service token.

## Usage

### Starting the Stack
```bash
docker compose up -d
```

### Viewing Logs
```bash
docker compose logs -f <service>
# e.g.
docker compose logs -f gluetun
docker compose logs -f cloudflared
```

### Stopping the Stack
```bash
docker compose down
```

### Recreating Gluetun

If you need to force-recreate gluetun (e.g. after a credential change), qBittorrent must also be recreated — it runs inside gluetun's network namespace and will be stuck in the old one after gluetun is replaced:

```bash
docker compose up -d --force-recreate gluetun
docker compose up -d --force-recreate qbittorrent
```

## First-Time App Configuration

Once the stack is running, open each app and configure paths. All media containers mount `ROOT_MEDIA_DIR` at `/data`.

### qBittorrent

| Setting | Value |
|---|---|
| Default Save Path | `/data/downloads/complete` |
| Incomplete Downloads | `/data/downloads/incomplete` |

### Radarr

| Setting | Value |
|---|---|
| Root Folder | `/data/movies` |
| Download Client — Host | `gluetun` |
| Download Client — Port | `8080` |
| Download Client — Category | `radarr` |

### Sonarr

| Setting | Value |
|---|---|
| Root Folder | `/data/tv` |
| Download Client — Host | `gluetun` |
| Download Client — Port | `8080` |
| Download Client — Category | `sonarr` |

### Lidarr

| Setting | Value |
|---|---|
| Root Folder | `/data/music` |
| Download Client — Host | `gluetun` |
| Download Client — Port | `8080` |
| Download Client — Category | `lidarr` |

> **Why `gluetun` and not `qbittorrent`?** qBittorrent runs inside Gluetun's network namespace (`network_mode: service:gluetun`), so it has no hostname of its own on the Docker network. All traffic to qBittorrent must go through `gluetun:8080`.

### Prowlarr

Prowlarr is the central indexer manager — add your torrent indexers here once and it automatically syncs them to Radarr, Sonarr, and Lidarr.

**Step 1 — Add your indexers:**
Go to **Indexers → Add Indexer** and search for the torrent sites you use.

**Step 2 — Connect to the arrs:**
Go to **Settings → Apps** and add each arr:

| App | URL | API Key location |
|---|---|---|
| Radarr | `http://radarr:7878` | Radarr → Settings → General |
| Sonarr | `http://sonarr:8989` | Sonarr → Settings → General |
| Lidarr | `http://lidarr:8686` | Lidarr → Settings → General |

### Bazarr

Connect via **Settings → Sonarr** (`http://sonarr:8989`) and **Settings → Radarr** (`http://radarr:7878`) using the API keys from each app. Bazarr pulls media paths from the APIs automatically — no manual path configuration needed.

### Plex

1. Add libraries pointing to `/data/movies`, `/data/tv`, `/data/music`
2. **Settings → Transcoder** → enable hardware acceleration and hardware-accelerated encoding

### Tautulli

On first launch, Tautulli will prompt you to connect to Plex. Use the internal Docker address `http://plex:32400` and your Plex token, or sign in via your Plex account.

## Accessing Services

| Service | URL |
|---|---|
| Traefik Dashboard | `https://traefik.yourdomain.com` |
| Plex | `https://plex.yourdomain.com` (or direct: `http://<server-ip>:32400/web`) |
| Tautulli | `https://tautulli.yourdomain.com` |
| Sonarr | `https://sonarr.yourdomain.com` |
| Radarr | `https://radarr.yourdomain.com` |
| Lidarr | `https://lidarr.yourdomain.com` |
| Bazarr | `https://bazarr.yourdomain.com` |
| Prowlarr | `https://prowlarr.yourdomain.com` |
| qBittorrent | `https://qbittorrent.yourdomain.com` |
| WireGuard | `https://wireguard.yourdomain.com` |
| Minecraft Survival | `<server-ip>:25565` (direct TCP — not behind Traefik) |
| Minecraft Creative | `<server-ip>:25566` (direct TCP — not behind Traefik) |
