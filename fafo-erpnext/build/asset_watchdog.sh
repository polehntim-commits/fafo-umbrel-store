#!/bin/bash
# SPDX-License-Identifier: MIT
# ── Asset watchdog ────────────────────────────────────────────────
# Polls the asset floor every WATCHDOG_INTERVAL seconds and repairs it
# when it breaks mid-container-lifetime — closing the gap where a
# runtime `bench migrate` / `bench build` / `bench clear-website-cache`
# leaves nginx serving unstyled pages until manual intervention.
#
# v15.1.2: the check moved out of this script into asset_floor.py, which
# both this loop and entrypoint.sh now share. The old version tested one
# thing — is `sites/assets/assets.json` present and non-empty — and that
# is exactly the check that missed the 2026-07-26 incident: the manifest
# was present, non-empty, and *stale*, naming content-hashed bundle files
# from a previous image build that no longer existed on disk. Every CSS
# URL in the served HTML 404'd while this watchdog reported everything
# fine. See asset_floor.py's docstring for the full mechanism.
#
# What the shared checker validates now:
#   1. assets.json present, non-empty, parses  (the old canary, subsumed)
#   2. every path it names actually resolves on disk  (the stale case)
#   3. every app shipping public/ or www/ has its sites/assets/ entry
#
# and repairs via snapshot restore → rate-limited bench build.
#
# This loop passes --clear-cache because it runs mid-lifetime with Redis
# up, and Frappe caches the parsed manifest there: without dropping it,
# workers keep emitting the old bundle URLs after the files are fixed.
# (entrypoint.sh does NOT pass it — Redis is not started yet at boot, and
# this image runs Redis with persistence off, so the cache is empty.)
#
# --quiet-when-healthy keeps the steady state silent; a 30s loop that
# logged on every pass would bury the lines that matter.
#
# Log entries prefixed with [watchdog] / [asset-floor] so they're
# greppable in `docker logs`.
#
# Env inputs:
#   WATCHDOG_INTERVAL — poll interval in seconds (default 30)
#   ASSET_BUILD_MIN_INTERVAL — min seconds between `bench build` attempts
#                     (default 3600). Guards against a persistently broken
#                     tree turning a 30s loop into a rebuild storm.

set -o pipefail

INTERVAL="${WATCHDOG_INTERVAL:-30}"
BUILD_MIN_INTERVAL="${ASSET_BUILD_MIN_INTERVAL:-3600}"
FLOOR=/usr/local/bin/asset-floor
BENCH_PY=/home/frappe/frappe-bench/env/bin/python

echo "[watchdog] Starting asset watchdog (interval=${INTERVAL}s)."
echo "[watchdog] Floor checker: $FLOOR (build min interval=${BUILD_MIN_INTERVAL}s)"

if [ ! -f "$FLOOR" ]; then
    echo "[watchdog] ERROR: $FLOOR not found — this image is built wrong. Watchdog idling; assets will NOT self-heal at runtime."
    while true; do sleep 3600; done
fi

# Prefer the bench venv interpreter for consistency with the entrypoint,
# but the floor checker uses only the stdlib, so system python3 is a fine
# fallback if the venv is ever missing.
PY="$BENCH_PY"
[ -x "$PY" ] || PY=$(command -v python3)
if [ -z "$PY" ]; then
    echo "[watchdog] ERROR: no python3 interpreter found — watchdog idling."
    while true; do sleep 3600; done
fi

# Small initial grace period so the entrypoint's own floor check has
# finished before we start polling.
sleep "$INTERVAL"

while true; do
    if ! "$PY" "$FLOOR" \
            --clear-cache \
            --reload-nginx \
            --quiet-when-healthy \
            --build-min-interval "$BUILD_MIN_INTERVAL"; then
        echo "[watchdog] $(date -u +%Y-%m-%dT%H:%M:%SZ) Asset floor still failing after repair attempt — see [asset-floor] lines above."
    fi
    sleep "$INTERVAL"
done
