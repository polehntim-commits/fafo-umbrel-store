#!/usr/bin/env bash
# Custom Tor entrypoint for fafo-farm-app
#
# This hook is no longer needed — iOS now connects on port 80 (Umbrel's
# default hidden-service mapping: port 80 → app_proxy → server:5000).
# Kept as a placeholder in case custom Tor config is needed in the future.

TORRC_PATH="/tmp/torrc"

echo "HiddenServiceDir ${HS_DIR}" > "${TORRC_PATH}"

for service in $HS_PORTS; do
  virtual_port=$(echo $service | cut -d : -f 1)
  source_host=$(echo $service | cut -d : -f 2)
  source_port=$(echo $service | cut -d : -f 3)
  echo "HiddenServicePort ${virtual_port} ${source_host}:${source_port}" >> "${TORRC_PATH}"
done

exec tor -f "${TORRC_PATH}"
