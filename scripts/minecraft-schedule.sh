#!/usr/bin/env bash
# Keep the Minecraft servers running only during the daily play window.
set -Eeuo pipefail

readonly start_hour="${MINECRAFT_START_HOUR:-9}"
readonly stop_hour="${MINECRAFT_STOP_HOUR:-19}"
readonly stop_timeout="${MINECRAFT_STOP_TIMEOUT:-60}"
readonly containers=(minecraft-survival minecraft-creative)

hour=$((10#$(date +%H)))
if ((hour >= start_hour && hour < stop_hour)); then
  echo "Inside ${start_hour}:00-${stop_hour}:00 window; starting Minecraft"
  docker start "${containers[@]}"
else
  echo "Outside ${start_hour}:00-${stop_hour}:00 window; stopping Minecraft"
  docker stop -t "$stop_timeout" "${containers[@]}"
fi
