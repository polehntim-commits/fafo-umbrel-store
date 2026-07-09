#!/bin/bash
# ── Self-healing strategy ─────────────────────────────────────────
# This container has three defense layers against runtime corruption:
#
#   1. Asset canary + snapshot restore (this file, runs every boot).
#      Detects a missing/empty `sites/assets/` manifest and restores
#      it from the image's `/var/lib/frappe-assets/` snapshot without
#      a full bench build. Handles the most common failure mode
#      (someone ran `bench clear-website-cache` and killed nginx's
#      asset manifest — the incident that hit Tim on 2026-07-08).
#
#   2. Docker HEALTHCHECK (Dockerfile). If nginx returns 404/500 for
#      the manifest URL for 90s+ (30s interval × 3 retries), Docker
#      marks the container unhealthy. Umbrel's watchdog then restarts
#      it — which triggers layer 1 to self-heal.
#
#   3. Idempotent app installer (this file, existing behavior). If a
#      baked-in Frappe app is missing from the site's installed apps
#      list, install it on the fly. See the reconcile block below.
#
# Combined: any single cache clear, asset delete, or partial
# migration recovers automatically on the next container restart with
# zero manual intervention. Multiple simultaneous failures may still
# require operator attention.
#
# NOTE on the "clear-cache Redis safety net": intentionally omitted.
# Redis isn't running when this entrypoint executes (supervisord
# starts it only after we exec), so `bench clear-cache` can't reach
# it here, and this image already runs Redis with persistence
# disabled (`save ""`, `dir /tmp`) — there is no dump.rdb to purge.
# Redis cache is ephemeral and rebuilds lazily on first connect, so
# no boot-time action is needed. Asset canary + healthcheck are the
# real self-heal mechanisms.
#
# First-boot initializer for the ERPNext + Agriculture single-image
# container. Runs BEFORE supervisord takes over.
#
# On first boot (no `.site-created` marker):
#   1. Wait for MariaDB (external `db` sidecar) to accept connections.
#   2. Write common_site_config.json with db + redis hostnames the
#      Frappe workers read on startup.
#   3. Start redis in the background (site creation needs it — but
#      supervisord isn't running yet so we do it inline).
#   4. Run `bench new-site` to create the site + install erpnext.
#   5. Best-effort: fetch + install frappe/agriculture. Failure here
#      doesn't fail the whole boot — the site is usable without it,
#      and the user can install manually via the ERPNext UI later.
#   6. Stop the inline redis so supervisord can manage it cleanly.
#   7. Touch the marker file.
#
# On subsequent boots (marker exists):
#   - Skip straight to `exec "$@"` which runs supervisord (via CMD).
#
# Env inputs (set by the Umbrel docker-compose):
#   SITE_NAME     — Frappe site name. Default "frontend".
#   DB_HOST       — MariaDB hostname (usually fafo-erpnext_db_1).
#   DB_PORT       — 3306.
#   DB_ROOT_PASS  — MariaDB root password (= ${APP_SEED} in compose).
#   ADMIN_PASS    — ERPNext Administrator password (= ${APP_PASSWORD}
#                   in compose, so Umbrel's credentials screen shows it).

set -e

SITE_NAME="${SITE_NAME:-frontend}"
DB_HOST="${DB_HOST:-fafo-erpnext_db_1}"
DB_PORT="${DB_PORT:-3306}"
DB_ROOT_PASS="${DB_ROOT_PASS:-changeme}"
ADMIN_PASS="${ADMIN_PASS:-admin}"
MARKER=/home/frappe/frappe-bench/sites/.site-created

# Fix volume ownership on EVERY boot. Umbrel creates
# ${APP_DATA_DIR}/sites on the host as root:root, so the container's
# frappe user (UID 1000) can't write to it until we chown. Run on
# every boot (not just first) so it's idempotent — after the first
# fix subsequent runs are a no-op.
echo "[entrypoint] Fixing ownership of sites volume..."
chown -R frappe:frappe /home/frappe/frappe-bench/sites || true

# ── Restore pre-built assets from the image (self-healing) ────────
# Runs on EVERY boot, not just first. Detects three failure modes:
#   1. Fresh volume — sites/assets/ empty or missing (first boot)
#   2. Someone ran `clear-website-cache` — wiped the manifest but
#      left the dir structure
#   3. Partial migration or accidental delete — canary file gone
#
# The canary is `sites/assets/assets.json` — the esbuild asset
# manifest that maps every logical bundle name (e.g.
# "frappe-web.bundle.js") to its content-hashed file on disk. We use
# the manifest rather than a specific bundle because Frappe v15
# fingerprints bundle filenames (e.g. frappe-web.bundle.YEFNLNZD.js),
# so the hash changes every build and there is no stable bundle path
# to hardcode. assets.json, by contrast, always lives at a fixed
# path and is exactly what gets wiped when the asset dir is cleared —
# if it's missing, nginx serves unstyled HTML (the symptom that hit
# Tim on 2026-07-08). Restore from /var/lib/frappe-assets/ snapshot
# which was baked into the image at build time.
CANARY=/home/frappe/frappe-bench/sites/assets/assets.json
if [ ! -f "$CANARY" ] || [ ! -s "$CANARY" ]; then
    echo "[entrypoint] Asset canary missing or empty ($CANARY) — restoring from image snapshot."
    if [ -d /var/lib/frappe-assets ]; then
        mkdir -p /home/frappe/frappe-bench/sites/assets
        # Use cp -a to preserve symlinks/timestamps — cp -r on some
        # implementations drops symlink metadata Frappe depends on.
        cp -a /var/lib/frappe-assets/. /home/frappe/frappe-bench/sites/assets/
        chown -R frappe:frappe /home/frappe/frappe-bench/sites/assets

        # Verify the restore actually populated the canary — if it
        # didn't, the snapshot is broken too and we fall through to
        # bench build (slow but guaranteed).
        if [ ! -f "$CANARY" ] || [ ! -s "$CANARY" ]; then
            echo "[entrypoint] Snapshot restore failed to populate canary — falling back to bench build."
            su frappe -s /bin/bash -c "cd /home/frappe/frappe-bench && bench build --production" \
                || echo "[entrypoint] bench build ALSO failed — nginx will serve 404s for assets until manual intervention."
        else
            echo "[entrypoint] Assets restored — no bench build needed."
        fi
    else
        echo "[entrypoint] No snapshot at /var/lib/frappe-assets — running bench build (this is slow)."
        su frappe -s /bin/bash -c "cd /home/frappe/frappe-bench && bench build --production" \
            || echo "[entrypoint] bench build failed — nginx will 404 on assets."
    fi
else
    echo "[entrypoint] Asset canary present — no restore needed."
fi

# ── Fast path: existing site → idempotent app install, then run ───
# The marker means the site was created on a previous boot, so we
# skip new-site. But we DON'T skip app installs anymore: when the
# image adds a new baked-in app between container recreates (e.g.
# farm_i9 landing after Tim's site was already up), the existing
# site would never get it. So before jumping to supervisord we
# reconcile — install any image-baked app that isn't on the site
# yet. This makes the entrypoint idempotent about app installation.
if [ -f "$MARKER" ]; then
    echo "[entrypoint] Marker exists — checking for baked-in apps not yet installed on site."

    # For each app baked into the image (apps/ dir), check if it's
    # installed on the site. If not, install it. This makes the
    # entrypoint idempotent when the image adds new apps between
    # container recreates.
    #
    # `bench --site $SITE_NAME list-apps` returns installed apps one
    # per line. Compare against the apps present in the image dir.
    if [ -d /home/frappe/frappe-bench/apps ]; then
        INSTALLED_APPS=$(su frappe -s /bin/bash -c "cd /home/frappe/frappe-bench && bench --site $SITE_NAME list-apps 2>/dev/null" | awk '{print $1}' || echo "")
        for APP_DIR in /home/frappe/frappe-bench/apps/*/; do
            APP_NAME=$(basename "$APP_DIR")
            # Skip frappe itself — it's always installed as a base
            [ "$APP_NAME" = "frappe" ] && continue
            # Only consider apps that have a proper Frappe app structure.
            # Older apps ship setup.py; newer ones (e.g. hrms
            # version-15) ship only pyproject.toml — accept either so
            # the reconcile picks up hrms on existing sites too.
            { [ -f "$APP_DIR/setup.py" ] || [ -f "$APP_DIR/pyproject.toml" ]; } || continue
            if ! echo "$INSTALLED_APPS" | grep -q "^$APP_NAME$"; then
                echo "[entrypoint] $APP_NAME baked into image but missing on site — installing..."
                if su frappe -s /bin/bash -c "bench --site $SITE_NAME install-app $APP_NAME"; then
                    echo "[entrypoint] $APP_NAME installed on existing site."
                else
                    echo "[entrypoint] $APP_NAME install-app failed — site up without it. Install manually via UI."
                fi
            fi
        done
    fi

    echo "[entrypoint] App check complete, starting supervisord."
    exec "$@"
fi

echo "[entrypoint] First boot — creating site $SITE_NAME."

# ── Wait for MariaDB ──────────────────────────────────────────────
echo "[entrypoint] Waiting for MariaDB at $DB_HOST:$DB_PORT (up to 120s)..."
for i in $(seq 1 60); do
    if nc -z "$DB_HOST" "$DB_PORT" 2>/dev/null; then
        echo "[entrypoint] MariaDB reachable after ${i} tries."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "[entrypoint] MariaDB unreachable after 120s — aborting."
        exit 1
    fi
    sleep 2
done

# Give MariaDB an extra beat for the mysqld to be actually accepting
# auth (nc says the port's open but the server's own init might
# still be in progress).
sleep 3

# ── Prep bench state ──────────────────────────────────────────────
cd /home/frappe/frappe-bench

# Bootstrap sites/ when the bind-mounted volume is fresh. Umbrel
# uses BIND mounts (not named volumes), so Docker doesn't
# auto-copy the image's default sites/ contents into the volume on
# first mount — which means common_site_config.json is missing and
# `bench set-config` throws FileNotFoundError trying to read it.
# Seeding with `{}` lets bench populate keys via the normal write
# path.
if [ ! -f /home/frappe/frappe-bench/sites/common_site_config.json ]; then
    echo "[entrypoint] Seeding empty common_site_config.json..."
    echo '{}' > /home/frappe/frappe-bench/sites/common_site_config.json
    chown frappe:frappe /home/frappe/frappe-bench/sites/common_site_config.json
fi

# apps.txt tells bench which apps to load — must include frappe +
# erpnext at minimum. Regenerate from the actual apps dir in case
# the image was built with a different set.
su frappe -s /bin/bash -c "ls -1 apps > sites/apps.txt"

# Write common_site_config.json via bench so the format matches
# whatever bench version is in the image.
su frappe -s /bin/bash -c "bench set-config -g db_host $DB_HOST"
su frappe -s /bin/bash -c "bench set-config -gp db_port $DB_PORT"
su frappe -s /bin/bash -c "bench set-config -g redis_cache 'redis://127.0.0.1:6379/0'"
su frappe -s /bin/bash -c "bench set-config -g redis_queue 'redis://127.0.0.1:6379/1'"
su frappe -s /bin/bash -c "bench set-config -g redis_socketio 'redis://127.0.0.1:6379/2'"
su frappe -s /bin/bash -c "bench set-config -gp socketio_port 9000"

# ── Start redis inline so bench new-site can reach it ─────────────
echo "[entrypoint] Starting inline redis for site creation..."
redis-server /etc/redis/redis.conf --daemonize yes
sleep 1

# ── Create the site ───────────────────────────────────────────────
echo "[entrypoint] Running bench new-site (this can take 3-5 min)..."
su frappe -s /bin/bash -c "bench new-site $SITE_NAME \
    --db-root-username root \
    --db-root-password $DB_ROOT_PASS \
    --admin-password $ADMIN_PASS \
    --install-app erpnext \
    --set-default \
    --force" || {
    echo "[entrypoint] bench new-site failed — check DB connectivity + credentials."
    redis-cli shutdown nosave 2>/dev/null || true
    exit 1
}

# ── Agriculture install (Tim 2026-07-08 revised) ──────────────────
# Agriculture code is now baked into the image at
# `/home/frappe/frappe-bench/apps/agriculture/` by the Dockerfile,
# so it survives container recreates. If the app dir exists,
# install it on the fresh site. Failure here is soft — site still
# usable without it.
if [ -d /home/frappe/frappe-bench/apps/agriculture ]; then
    echo "[entrypoint] Installing agriculture on $SITE_NAME..."
    if su frappe -s /bin/bash -c "bench --site $SITE_NAME install-app agriculture"; then
        echo "[entrypoint] Agriculture installed."
    else
        echo "[entrypoint] agriculture install-app failed — site is up without it. Install manually via UI."
    fi
else
    echo "[entrypoint] agriculture dir not present in image — running vanilla ERPNext."
fi

# ── farm_i9 install (Tim 2026-07-08) ──────────────────────────────
# Custom I-9 workflow app baked into image at
# /home/frappe/frappe-bench/apps/farm_i9/. Install on the fresh site
# if the app dir exists. Failure is soft — site still usable without it.
if [ -d /home/frappe/frappe-bench/apps/farm_i9 ]; then
    echo "[entrypoint] Installing farm_i9 on $SITE_NAME..."
    if su frappe -s /bin/bash -c "bench --site $SITE_NAME install-app farm_i9"; then
        echo "[entrypoint] farm_i9 installed."
    else
        echo "[entrypoint] farm_i9 install-app failed — site is up without it. Install manually via UI."
    fi
else
    echo "[entrypoint] farm_i9 dir not present in image — running without it."
fi

# ── hrms install (Tim 2026-07-09) ─────────────────────────────────
# Frappe HR + Payroll app baked into the image at
# /home/frappe/frappe-bench/apps/hrms/. Install on the fresh site if
# the app dir exists. Failure is soft — site still usable without it,
# though Farm HR loses ~40% of its underlying framework.
if [ -d /home/frappe/frappe-bench/apps/hrms ]; then
    echo "[entrypoint] Installing hrms on $SITE_NAME..."
    if su frappe -s /bin/bash -c "bench --site $SITE_NAME install-app hrms"; then
        echo "[entrypoint] hrms installed."
    else
        echo "[entrypoint] hrms install-app failed — site is up without it. Install manually via UI."
    fi
else
    echo "[entrypoint] hrms dir not present in image — running without it."
fi

# ── HRMS US-mode defaults ─────────────────────────────────────────
# OMITTED (Phase 3). Frappe HR gates region-specific payroll features
# (PF/ESI/TDS vs US) off the Company's `country` field, which is
# per-Company in ERPNext, not per-site — so a site-level set-config
# or a raw tabCompany UPDATE here would be fragile and easy to get
# wrong. Tim's "Testing" Company already has country="United States"
# from `bench new-site`, so US defaults are effectively in place. Any
# remaining US-mode anchoring (Salary Components/Structures) is a
# deliberate Phase 3 task handled via the Company record UI.

# NOTE: no runtime `bench build` — assets are pre-built into
# /var/lib/frappe-assets/ by the Dockerfile and restored to
# sites/assets/ by the self-healing canary check at the top of this
# entrypoint (which re-runs on every boot). Saves 5-10 min of
# Pi-side compilation on every fresh install.

# ── Cleanup: stop inline redis so supervisord starts clean ────────
echo "[entrypoint] Stopping inline redis..."
redis-cli shutdown nosave 2>/dev/null || true
sleep 1

touch "$MARKER"
chown frappe:frappe "$MARKER"

echo "[entrypoint] First-boot setup complete. Starting supervisord."
exec "$@"
