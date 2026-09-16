# Bare-metal rebuild and hardened setup guide

This runbook rebuilds the current Debian 13 media server from an empty system.
Read the storage warnings before touching the media disks. Commands assume you
are logged in as the non-root administrator and clone this repository to
`~/MediaServer`.

## 0. Keep a recoverable backup

A Git checkout is not a server backup. Keep encrypted, recurring copies of:

- `~/MediaServer/.env` (secrets; mode `0600`);
- all of `/opt/docker/` (application databases, Plex metadata, Minecraft
  worlds, qBittorrent state, WireGuard keys, and Traefik certificates);
- the media filesystem mounted at `/mnt/media`;
- `/etc/fstab`, `/etc/mdadm/mdadm.conf`, and the host firewall configuration;
- an inventory of the Cloudflare account, zone, Tunnel, Access applications,
  policies, and where replacement API/tunnel tokens can be issued.

A RAID mirror protects against one disk failure; it is not a backup. Test a
restore periodically. For a consistent manual backup, stop writers and use a
tool that preserves ownership, permissions, ACLs, and extended attributes:

```bash
cd ~/MediaServer
docker compose down
sudo rsync -aHAX --numeric-ids /opt/docker/ /path/to/backup/opt-docker/
sudo rsync -aHAX --numeric-ids /mnt/media/ /path/to/backup/media/
sudo install -D -m 0600 .env /path/to/backup/MediaServer/.env
docker compose up -d --wait --wait-timeout 300
```

`/path/to/backup` is deliberately a placeholder. Verify it is a mounted,
independent destination first. For unattended backups, use application-aware
snapshots or stop the containers during capture.

## 1. Install Debian and Docker

Install Debian 13 (`trixie`), create a non-root administrator, apply updates,
and install the host tools. Record this account's numeric IDs for `PUID` and
`PGID` later:

```bash
sudo apt update
sudo apt full-upgrade
sudo apt install ca-certificates curl git mdadm rsync
id -u
id -g
```

Install Docker Engine and Compose from Docker's official Debian repository, not
the legacy `docker-compose` package:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker.service containerd.service
sudo usermod -aG docker "$USER"
```

The `docker` group grants root-equivalent access. Log out fully and back in,
then verify and clone the repository at the path expected by the updater:

```bash
docker version
docker compose version
docker run --rm hello-world
REPOSITORY_URL="REPLACE_WITH_REPOSITORY_URL"
git clone "$REPOSITORY_URL" ~/MediaServer
cd ~/MediaServer
```

## 2. Recover and mount the media RAID

The server uses a two-member Linux software RAID1:

| Item | Current value |
|---|---|
| Members | Discover by RAID metadata and disk serial number |
| Array | `/dev/md0` (metadata 1.2) |
| RAID level | RAID1 with two members |
| Filesystem | ext4; discover its UUID with `blkid` |
| Mount point | `/mnt/media` |

Device letters can change. Identify disks by RAID metadata, serial numbers, and
UUIDs rather than assuming `sda` and `sdb` stayed the same:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,UUID,MOUNTPOINTS
sudo mdadm --examine --scan
sudo mdadm --examine /dev/disk/by-id/REPLACE_WITH_FIRST_MEMBER_PARTITION
sudo mdadm --examine /dev/disk/by-id/REPLACE_WITH_SECOND_MEMBER_PARTITION
```

For disks already containing this array, assemble without creating or
formatting anything and inspect it read-only first:

```bash
sudo mdadm --assemble --scan
cat /proc/mdstat
sudo mdadm --detail /dev/md0
sudo mkdir -p /mnt/media
sudo mount -o ro /dev/md0 /mnt/media
findmnt /mnt/media
ls -la /mnt/media/plex
sudo blkid /dev/md0
sudo umount /mnt/media
```

Stop if the array is unexpectedly degraded, the UUID differs, or media is
absent. Never use `mdadm --create`, `mkfs`, `wipefs`, or partitioning commands
when recovering an existing array.

Record the discovered ARRAY line from `sudo mdadm --detail --scan` in
`/etc/mdadm/mdadm.conf`, run `sudo update-initramfs -u`, and add:

```fstab
UUID=<filesystem-uuid-from-blkid> /mnt/media ext4 defaults 0 2
```

Validate the persistent mount:

```bash
sudo mount -a
findmnt -no SOURCE,FSTYPE,OPTIONS /mnt/media
test -w /mnt/media/plex && echo "media path is writable"
cat /proc/mdstat
```

Do not start the stack unless `/mnt/media/plex` is mounted read-write. For blank
replacement disks, restore from backup; designing a new array is a separate,
deliberately destructive procedure.

The active `ROOT_MEDIA_DIR` is `/mnt/media/plex` and expects:

```text
/mnt/media/plex/
├── Audio/
├── Movies/
├── TV/
├── downloads/
│   ├── complete/
│   └── incomplete/
└── transcode/
```

After mounting, create only missing empty directories:

```bash
sudo install -d -o 1000 -g 1000 -m 0775 \
  /mnt/media/plex/{Audio,Movies,TV,downloads/complete,downloads/incomplete,transcode}
```

## 3. Restore secrets and application state

Restore before the first container start:

```bash
sudo install -d -m 0755 /opt/docker
sudo rsync -aHAX --numeric-ids /path/to/backup/opt-docker/ /opt/docker/
install -m 0600 /path/to/backup/MediaServer/.env ~/MediaServer/.env
```

Without an `.env` backup, create it and fill every value:

```bash
cd ~/MediaServer
cp .env.example .env
chmod 600 .env
editor .env
docker compose config --quiet
```

Important values:

- `ROOT_MEDIA_DIR=/mnt/media/plex` on this server.
- `LAN_IP` is the reserved private address, not the public address.
- `LOCAL_SUBNET` is the trusted household LAN CIDR used by Traefik.
- `SERVER_IP` is the public address Plex advertises.
- `PUID` and `PGID` must match application/media data ownership.
- Replace Cloudflare and PIA credentials if no trusted backup exists.

Without `LAN_IP`, HTTPS and both Minecraft ports intentionally bind to
`127.0.0.1`. Limit the Cloudflare DNS token to DNS edit for this zone. Never
commit `.env`.

## 4. Prepare the host

Load WireGuard and wg-easy firewall modules before Docker:

```bash
echo -e 'wireguard\nip_tables\nip6_tables' | sudo tee /etc/modules-load.d/wg-easy.conf >/dev/null
sudo systemctl restart systemd-modules-load.service
lsmod | grep -E '^(wireguard|ip_tables|ip6_tables) '
```

All three must appear on the current Debian 13/6.12 host. If a future kernel
builds them in, confirm its kernel configuration instead.

Plex requires the Intel hardware-transcoding device mapped by Compose:

```bash
ls -l /dev/dri/renderD128
getent group render
```

If absent, enable the iGPU in firmware, install the appropriate Debian
firmware/VA-API packages for the actual GPU, reboot, and check again. Never
create a device node manually. On a host without a compatible GPU, remove the
Plex `devices` mapping before deployment and accept software transcoding.

For a new installation without restored application state:

```bash
sudo mkdir -p /opt/docker/{traefik/letsencrypt,traefik/logs,gluetun,plex,tautulli,qbittorrent,prowlarr,sonarr,radarr,lidarr,bazarr,minecraft-survival,minecraft-creative,wg-easy-v15}
sudo chown -R 1000:1000 /opt/docker/traefik /opt/docker/plex /opt/docker/tautulli /opt/docker/qbittorrent /opt/docker/prowlarr /opt/docker/sonarr /opt/docker/radarr /opt/docker/lidarr /opt/docker/bazarr /opt/docker/minecraft-survival /opt/docker/minecraft-creative
sudo chmod 700 /opt/docker/wg-easy-v15
```

Adjust ownership when `PUID`/`PGID` differ. Do not recursively change ownership
after a numeric-ID-preserving restore. Install hardening, the updater/timer, and
Traefik log rotation:

```bash
sudo ./scripts/install-host-hardening.sh
systemctl list-timers mediaserver-update.timer
```

Re-run this installer after moving the checkout or changing the updater; the
systemd unit embeds the project path and the updater is copied root-owned.

## 5. Configure DNS, Cloudflare, firewall, and router

Reserve `LAN_IP` in DHCP. Configure local DNS so `plex.${DOMAIN}` and
`qbittorrent.${DOMAIN}` resolve directly to `LAN_IP`; public DNS must not expose
qBittorrent.

Create Cloudflare Tunnel hostnames pointing to `http://traefik:80` for:

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

Do not create Tunnel routes for Plex or qBittorrent. For each listed hostname:

1. Attach an Access application and allow policy for intended identities.
2. Enable **Protect with Access** in the Tunnel route and select that audience.
3. Keep the origin as HTTP; it uses only the dedicated Docker edge network.

The tunnel token authenticates the connector; it does not satisfy Access.

Forward only TCP 32400 to `LAN_IP` for Plex (if needed) and UDP 51820 for
WireGuard. Never forward TCP 80, TCP 443, TCP 25565-25566, or TCP/UDP 6881.

Allow the LAN to TCP 443 and 25565-25566 on the host, allow the intended WAN
ports, and reject everything else. Docker-published ports can bypass simple
ufw/firewalld rules; filter in the `DOCKER-USER` iptables chain or upstream
router. Back up the tested ruleset rather than improvising it during recovery,
and verify SSH access before enabling default-deny.

## 6. Preflight and deploy

```bash
cd ~/MediaServer
test "$(stat -c %a .env)" = 600
test -w /mnt/media/plex
findmnt -no OPTIONS /mnt/media | grep -qw rw
test -e /dev/dri/renderD128
docker compose config --quiet
bash -n scripts/*.sh
./tests/test-update-containers.sh
docker compose pull
docker compose up -d --remove-orphans --wait --wait-timeout 300
docker compose ps
```

For a brand-new qBittorrent config, recreate it once after its first successful
start so the initialization script can harden the newly generated file:

```bash
docker compose up -d --force-recreate qbittorrent
```

## 7. Restore or configure applications

Restored `/opt/docker` state should retain accounts, API keys, paths, Plex
metadata, Minecraft worlds, and WireGuard peers. For a fresh setup configure:

| Application | Setting | Value |
|---|---|---|
| qBittorrent | Complete / incomplete | `/data/downloads/complete` / `/data/downloads/incomplete` |
| Radarr | Root / download client | `/data/Movies` / `http://gluetun:8080` |
| Sonarr | Root / download client | `/data/TV` / `http://gluetun:8080` |
| Lidarr | Root / download client | `/data/Audio` / `http://gluetun:8080` |
| Bazarr | Sonarr / Radarr | `http://sonarr:8989` / `http://radarr:7878` |
| Tautulli | Plex | `http://plex:32400` |

Configure Prowlarr applications/API keys using arr service names and standard
ports. Claim Plex and check libraries, remote access, and transcoding. Confirm
both Minecraft worlds and their allowlists/operators.

wg-easy v15 state is in `/opt/docker/wg-easy-v15`. After startup:

1. Open `https://wireguard.${DOMAIN}` through Cloudflare Access.
2. Complete administrator setup only for a genuinely new database.
3. Confirm the public server address and UDP port 51820.
4. Create or verify every expected client.
5. Run `docker exec wg-easy wg show` and compare server key and peers.
6. Test each client over mobile data.

## 8. End-to-end validation

```bash
docker compose config --quiet
docker compose exec traefik traefik version
docker compose ps
docker compose exec gluetun wget -qO- https://ipinfo.io/ip
docker compose exec qbittorrent wget -qO- https://ipinfo.io/ip
docker exec wg-easy wg show
systemctl status mediaserver-update.timer --no-pager
```

Confirm:

- every container is healthy and survives a host reboot;
- the RAID automatically assembles and `/mnt/media` mounts read-write first;
- Traefik is at least 3.7.13 and has no Docker socket mount;
- unauthenticated tunneled requests are rejected by Cloudflare Access;
- TCP 80 is unreachable from the LAN and internet;
- local DNS directs Plex and qBittorrent to `LAN_IP`;
- qBittorrent is LAN-only and its port matches
  `/tmp/gluetun/forwarded_port` after PIA connects;
- stopping Gluetun prevents qBittorrent internet access;
- Plex remote access and hardware transcoding work;
- every arr application and Tautulli can reach its dependencies;
- Minecraft works over LAN/WireGuard but not an external port scan;
- all WireGuard peers reconnect after reboot;
- `/opt/docker` credentials are not group/world-readable;
- a fresh off-host backup completes and restore instructions are offline.

Plex's LAN-wide unauthenticated exception is intentionally unchanged. Any
device on that subnet is treated as the owner; revisit it when no longer needed.

After kernel, Docker, storage, network, or application changes, repeat the
relevant checks and update this runbook while the details are still known.
