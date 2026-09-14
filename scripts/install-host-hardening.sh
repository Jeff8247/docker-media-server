#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this installer as root" >&2
  exit 1
fi

readonly project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

install -d -m 0700 /opt/docker/wg-easy-v15

# Remove access for other host users without changing owners or owner execute bits.
for path in \
  /opt/docker/bazarr \
  /opt/docker/lidarr \
  /opt/docker/prowlarr \
  /opt/docker/qbittorrent \
  /opt/docker/radarr \
  /opt/docker/sonarr \
  /opt/docker/tautulli; do
  if [[ -e "$path" ]]; then
    chmod -R go-rwx "$path"
  fi
done

# Minecraft may contain old root-owned world backups. Only the credential-bearing
# files need this permission change, avoiding an unnecessary recursive world scan.
for path in \
  /opt/docker/minecraft-creative/server.properties \
  /opt/docker/minecraft-creative/.rcon-cli.yaml \
  /opt/docker/minecraft-survival/server.properties \
  /opt/docker/minecraft-survival/.rcon-cli.yaml; do
  if [[ -e "$path" ]]; then
    chmod go-rwx "$path"
  fi
done

sed "s|@PROJECT_DIR@|${project_dir}|g" \
  "$project_dir/systemd/mediaserver-update.service" \
  > /etc/systemd/system/mediaserver-update.service
chmod 0644 /etc/systemd/system/mediaserver-update.service
install -o root -g root -m 0755 \
  "$project_dir/scripts/update-containers.sh" \
  /usr/local/sbin/mediaserver-update
install -m 0644 "$project_dir/systemd/mediaserver-update.timer" /etc/systemd/system/mediaserver-update.timer
install -m 0644 "$project_dir/systemd/mediaserver-traefik.logrotate" /etc/logrotate.d/mediaserver-traefik

systemctl daemon-reload
systemctl enable --now mediaserver-update.timer
systemctl list-timers mediaserver-update.timer --no-pager
