#!/usr/bin/env bash
# Custom Tor entrypoint for fafo-farm-app
# Replicates umbreld's tor-entrypoint.sh logic, then permanently adds
# HiddenServicePort 5000 so the iOS app can reach Flask directly over Tor.

TORRC_PATH="/tmp/torrc"

echo "HiddenServiceDir ${HS_DIR}" > "${TORRC_PATH}"

for service in $HS_PORTS; do
  virtual_port=$(echo $service | cut -d : -f 1)
  source_host=$(echo $service | cut -d : -f 2)
  source_port=$(echo $service | cut -d : -f 3)
  echo "HiddenServicePort ${virtual_port} ${source_host}:${source_port}" >> "${TORRC_PATH}"
done

# Always expose port 5000 on the .onion address directly to Flask (bypasses app_proxy auth)
echo "HiddenServicePort 5000 fafo-farm-app_server_1:5001" >> "${TORRC_PATH}"

exec tor -f "${TORRC_PATH}"
