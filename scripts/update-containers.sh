#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

# Do not let the unattended updater replace a working v14 VPN before the
# one-time v15 import has been completed manually.
if docker inspect wg-easy --format '{{.Config.Image}}' 2>/dev/null | grep -vq ':15$'; then
  if [[ ! -s /opt/docker/wg-easy-v15/wg-easy.db ]]; then
    echo "wg-easy v15 migration is not complete; refusing unattended updates" >&2
    exit 1
  fi
fi

exec 9>"/run/lock/mediaserver-update.lock"
flock -n 9 || {
  echo "Another media-server update is already running"
  exit 0
}

before_gluetun_image="$(docker inspect --format '{{.Image}}' gluetun 2>/dev/null || true)"

docker compose pull
docker compose up -d --remove-orphans --wait --wait-timeout 300

after_gluetun_image="$(docker inspect --format '{{.Image}}' gluetun 2>/dev/null || true)"
if [[ -n "$before_gluetun_image" && "$before_gluetun_image" != "$after_gluetun_image" ]]; then
  # network_mode: service:gluetun keeps the old namespace unless qBittorrent
  # is explicitly recreated after Gluetun changes.
  docker compose up -d --force-recreate qbittorrent
fi

docker compose ps
