#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="${MEDIASERVER_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly pull_parallel_limit="${PULL_PARALLEL_LIMIT:-4}"
readonly pull_max_attempts="${PULL_MAX_ATTEMPTS:-4}"
readonly pull_retry_delays="${PULL_RETRY_DELAYS:-30 90 180}"
readonly update_lock_file="${UPDATE_LOCK_FILE:-/run/lock/mediaserver-update.lock}"
cd "$project_dir"

pull_images() {
  local attempt=1
  local -a delays
  read -r -a delays <<<"$pull_retry_delays"

  while ((attempt <= pull_max_attempts)); do
    echo "Pull attempt ${attempt}/${pull_max_attempts} (parallel limit: ${pull_parallel_limit})"
    if COMPOSE_PARALLEL_LIMIT="$pull_parallel_limit" docker compose pull; then
      return 0
    fi

    if ((attempt == pull_max_attempts)); then
      echo "Image pull failed after ${pull_max_attempts} attempts" >&2
      return 1
    fi

    local delay="${delays[attempt-1]:-${delays[-1]:-180}}"
    echo "Image pull attempt ${attempt} failed; retrying in ${delay} seconds" >&2
    sleep "$delay"
    ((attempt += 1))
  done
}

# Do not let the unattended updater replace a working v14 VPN before the
# one-time v15 import has been completed manually.
if docker inspect wg-easy --format '{{.Config.Image}}' 2>/dev/null | grep -vq ':15$'; then
  if [[ ! -s /opt/docker/wg-easy-v15/wg-easy.db ]]; then
    echo "wg-easy v15 migration is not complete; refusing unattended updates" >&2
    exit 1
  fi
fi

exec 9>"$update_lock_file"
flock -n 9 || {
  echo "Another media-server update is already running"
  exit 0
}

before_gluetun_image="$(docker inspect --format '{{.Image}}' gluetun 2>/dev/null || true)"

pull_images
docker compose up -d --remove-orphans --wait --wait-timeout 300

after_gluetun_image="$(docker inspect --format '{{.Image}}' gluetun 2>/dev/null || true)"
if [[ -n "$before_gluetun_image" && "$before_gluetun_image" != "$after_gluetun_image" ]]; then
  # network_mode: service:gluetun keeps the old namespace unless qBittorrent
  # is explicitly recreated after Gluetun changes.
  docker compose up -d --force-recreate qbittorrent
fi

docker compose ps
