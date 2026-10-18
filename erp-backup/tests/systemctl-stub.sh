#!/bin/bash
# systemctl stand-in for the harness: "enabled" means the unit file exists in ERP_KIT_SYSTEMD_DIR and was enabled.
SD="${ERP_KIT_SYSTEMD_DIR:-/t/systemd}"; mkdir -p "$SD"
echo "systemctl $*" >> "$SD/.calls"
case "$1" in
  is-enabled) [ "$2" = --quiet ] && shift; [ -f "$SD/$2" ] && [ -f "$SD/.enabled.$2" ] ;;
  enable) shift; [ "$1" = --now ] && shift; touch "$SD/.enabled.$1" ;;
  disable) shift; [ "$1" = --now ] && shift; rm -f "$SD/.enabled.$1" ;;
  show) echo success ;;
  *) exit 0 ;;
esac
