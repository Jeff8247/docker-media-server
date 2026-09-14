# Hardened Setup Guide

Follow these steps before recreating the stack. The wg-easy v15 migration and `LAN_IP` setting are required to preserve access.

## 1. Configure the environment

Use [.env.example](.env.example) as the reference and keep the real `.env` at mode `0600`.

`LAN_IP` must be the server's private address on the household LAN, not its public address. If it is omitted, Traefik 443 and both Minecraft ports deliberately bind to `127.0.0.1` and will not be reachable from other devices.

```bash
chmod 600 .env
docker compose config --quiet
```

Keep the Cloudflare DNS token limited to DNS edit access for this single zone.

## 2. Prepare directories and permissions

```bash
sudo mkdir -p /opt/docker/{traefik/letsencrypt,traefik/logs,gluetun,plex,tautulli,qbittorrent,prowlarr,sonarr,radarr,lidarr,bazarr,minecraft-survival,minecraft-creative,wg-easy-v15}
sudo chown -R 1000:1000 /opt/docker/traefik /opt/docker/plex /opt/docker/tautulli /opt/docker/qbittorrent /opt/docker/prowlarr /opt/docker/sonarr /opt/docker/radarr /opt/docker/lidarr /opt/docker/bazarr /opt/docker/minecraft-survival /opt/docker/minecraft-creative
sudo chmod 700 /opt/docker/wg-easy-v15
```

Adjust `1000:1000` if `PUID` and `PGID` differ. The installer removes group/world access from application configuration without changing ownership:

```bash
sudo ./scripts/install-host-hardening.sh
```

It also installs the updater timer and Traefik access-log rotation. Confirm the timer:

```bash
systemctl list-timers mediaserver-update.timer
```

## 3. Prepare or verify wg-easy v15

The running stack uses `/opt/docker/wg-easy-v15`. For a one-time migration from v14, make a protected external backup of `/opt/docker/wg-easy/wg0.json` and `wg0.conf` before deployment. The browser upload must be the v14 JSON file and should retain a `.json` filename extension.

After v15 starts:

1. Open `https://wireguard.${DOMAIN}` through Cloudflare Access.
2. Complete the v15 administrator setup.
3. Select the existing-setup migration and upload the old `wg0.json`.
4. Confirm the server address and UDP port 51820.
5. Restart wg-easy so the imported database is rendered into `wg0.conf` and synchronized with the live interface:

   ```bash
   docker restart wg-easy
   docker exec wg-easy wg show
   ```

6. Confirm the original server public key and all expected `peer:` entries are present.
7. Test every existing peer over mobile data before deleting any v14 data.

The v15 administrator and WireGuard state are stored in `wg-easy.db`. Back up `/opt/docker/wg-easy-v15` for ongoing recovery; the old v14 JSON does not include later v15 changes.

## 4. Configure Cloudflare Tunnel and Access

Create Tunnel public-hostname routes pointing to `http://traefik:80` for:

| Hostname |
|---|
| `traefik.${DOMAIN}` |
| `tautulli.${DOMAIN}` |
| `sonarr.${DOMAIN}` |
| `radarr.${DOMAIN}` |
| `lidarr.${DOMAIN}` |
| `bazarr.${DOMAIN}` |
| `prowlarr.${DOMAIN}` |
| `wireguard.${DOMAIN}` |

Do not create Tunnel routes for Plex or qBittorrent.

For every listed hostname:

1. Attach a Cloudflare Access allow policy for the intended identities.
2. In the Tunnel route's additional application settings, enable **Protect with Access** and select the matching Access application/audience.
3. Keep the origin URL as HTTP; it travels only across the dedicated Docker edge network.

The tunnel token authenticates the connector. It is not an Access service token and does not itself bypass or satisfy an Access policy.

## 5. Firewall and router policy

Allow only:

| Source | Destination |
|---|---|
| Internet | TCP 32400 for Plex, if direct remote access is required |
| Internet | UDP 51820 for WireGuard |
| `LOCAL_SUBNET` | `LAN_IP`: TCP 443, 25565, 25566 |
| WireGuard clients | `LAN_IP`: TCP 25565, 25566 and other explicitly approved LAN services |

Explicitly reject WAN TCP 80, TCP 443, TCP 25565-25566, and TCP/UDP 6881. Ensure the router has no forwards for those ports. Docker binds 443 and Minecraft to `LAN_IP`, but firewall policy remains required defense in depth.

## 6. Start and validate

```bash
docker compose pull
docker compose up -d --remove-orphans --wait --wait-timeout 300
docker compose ps
```

For an existing migrated installation, verify that WireGuard loaded its peers:

```bash
docker exec wg-easy wg show
```

`--remove-orphans` removes the retired Watchtower and Docker socket-proxy containers. Their removal is intentional; automatic updates now run from the host timer.

Existing qBittorrent installations are updated during container initialization to:

- allow Gluetun's shared-loopback port-forward callback;
- restrict qBittorrent's accepted Host header to its configured hostname.

For a completely new qBittorrent config, recreate it once after its first successful start so the initialization script can update the newly created file:

```bash
docker compose up -d --force-recreate qbittorrent
```

## 7. Application paths

| Application | Setting | Value |
|---|---|---|
| qBittorrent | Complete downloads | `/data/downloads/complete` |
| qBittorrent | Incomplete downloads | `/data/downloads/incomplete` |
| Radarr | Root folder / download client | `/data/movies` / `http://gluetun:8080` |
| Sonarr | Root folder / download client | `/data/tv` / `http://gluetun:8080` |
| Lidarr | Root folder / download client | `/data/music` / `http://gluetun:8080` |
| Bazarr | Sonarr / Radarr | `http://sonarr:8989` / `http://radarr:7878` |
| Tautulli | Plex | `http://plex:32400` |

Prowlarr reaches the arr services by their service names and standard ports over the internal indexer network.

## 8. Security validation

Run these checks after deployment:

```bash
docker compose config --quiet
docker compose exec traefik traefik version
docker compose ps
docker compose exec gluetun wget -qO- https://ipinfo.io/ip
docker compose exec qbittorrent wget -qO- https://ipinfo.io/ip
```

Confirm:

- Traefik is at least 3.7.13 and has no Docker socket mounted.
- An unauthenticated request to every tunneled hostname is rejected by Cloudflare Access.
- TCP 80 is unreachable on the host and from the internet.
- qBittorrent is available from the LAN hostname but rejected from non-LAN sources.
- qBittorrent's listening port matches `/tmp/gluetun/forwarded_port` after PIA connects.
- Stopping Gluetun prevents qBittorrent from reaching the internet.
- Minecraft connects from LAN and WireGuard, but an external port scan cannot reach 25565 or 25566.
- Existing WireGuard peers still connect after the v15 import.
- `/opt/docker` application credentials are not group/world-readable.

Plex's existing LAN-wide unauthenticated exception is intentionally unchanged. Revisit it when legacy LAN access is no longer needed.
