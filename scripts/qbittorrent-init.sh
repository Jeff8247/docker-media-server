#!/usr/bin/env sh
set -eu

config=/config/qBittorrent/qBittorrent.conf

# A brand-new config is created after custom init scripts run. Existing installs
# are hardened here; new installs must be started once and then recreated.
if [ ! -f "$config" ]; then
  exit 0
fi

set_preference() {
  key=$1
  value=$2

  if grep -q "^${key}=" "$config"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$config"
  else
    sed -i "/^\[Preferences\]$/a ${key}=${value}" "$config"
  fi
}

# Gluetun's PIA port-forward hook calls qBittorrent over their shared loopback.
set_preference 'WebUI\\LocalHostAuth' 'false'
# Keep qBittorrent's own host validation enabled behind Traefik.
set_preference 'WebUI\\ServerDomains' "\"${QBITTORRENT_SERVER_DOMAIN:?missing domain};gluetun;localhost;127.0.0.1\""
