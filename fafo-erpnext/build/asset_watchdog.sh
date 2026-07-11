#!/bin/bash
# ── Asset watchdog ────────────────────────────────────────────────
# Polls sites/assets/ every WATCHDOG_INTERVAL seconds. When the
# canary (assets.json) is missing or empty, restores the entire
# assets tree from the image snapshot at /var/lib/frappe-assets/
# and reloads nginx.
#
# Runs under supervisord as a top-priority process (starts before
# nginx) so any runtime-triggered asset wipe recovers within 30
# seconds instead of requiring container force-recreate.
#
# Log entries prefixed with [watchdog] so they're greppable in
# `docker logs`.
#
# Env inputs:
#   WATCHDOG_INTERVAL — poll interval in seconds (default 30)

set -o pipefail

INTERVAL="${WATCHDOG_INTERVAL:-30}"
ASSETS_DIR=/home/frappe/frappe-bench/sites/assets
SNAPSHOT_DIR=/var/lib/frappe-assets
CANARY="$ASSETS_DIR/assets.json"

echo "[watchdog] Starting asset watchdog (interval=${INTERVAL}s)."
echo "[watchdog] Monitoring canary: $CANARY"
echo "[watchdog] Snapshot source: $SNAPSHOT_DIR"

# Small initial grace period so entrypoint's first-boot restore has
# time to complete before we start polling.
sleep "$INTERVAL"

while true; do
    # Canary missing OR zero-byte
    if [ ! -f "$CANARY" ] || [ ! -s "$CANARY" ]; then
        echo "[watchdog] $(date -u +%Y-%m-%dT%H:%M:%SZ) Canary missing/empty at $CANARY — triggering restore."

        if [ ! -d "$SNAPSHOT_DIR" ]; then
            echo "[watchdog] ERROR: No snapshot at $SNAPSHOT_DIR — cannot restore. Container needs rebuild."
            sleep "$INTERVAL"
            continue
        fi

        # Restore (cp -a preserves symlinks/timestamps like the
        # entrypoint's own restore path)
        mkdir -p "$ASSETS_DIR"
        if cp -a "$SNAPSHOT_DIR/." "$ASSETS_DIR/"; then
            chown -R frappe:frappe "$ASSETS_DIR"
            echo "[watchdog] Assets restored from snapshot."
        else
            echo "[watchdog] ERROR: cp failed during restore."
            sleep "$INTERVAL"
            continue
        fi

        # Restart nginx so it re-opens FDs on the freshly restored
        # files. supervisorctl talks to the parent supervisord over
        # its unix socket.
        if supervisorctl restart frontend > /dev/null 2>&1; then
            echo "[watchdog] nginx (frontend) restarted."
        else
            echo "[watchdog] WARN: supervisorctl restart frontend failed — nginx may still serve 404 for hashed bundles until manual restart."
        fi

        echo "[watchdog] Recovery complete."
    fi
    sleep "$INTERVAL"
done
