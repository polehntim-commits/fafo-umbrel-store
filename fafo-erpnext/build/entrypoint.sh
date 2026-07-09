#!/bin/bash
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

# ── Restore pre-built assets from the image ───────────────────────
# Umbrel bind-mounts sites/ so the image's built assets get hidden.
# Dockerfile snapshots them to /var/lib/frappe-assets/ at build
# time; here we restore into the empty mounted sites/assets/ if
# it's missing. Uses a marker file so we don't clobber assets an
# operator might have customized post-install.
if [ ! -f /home/frappe/frappe-bench/sites/assets/.restored ]; then
    if [ -d /var/lib/frappe-assets ]; then
        echo "[entrypoint] Restoring pre-built assets from image snapshot..."
        mkdir -p /home/frappe/frappe-bench/sites/assets
        cp -r /var/lib/frappe-assets/. /home/frappe/frappe-bench/sites/assets/
        chown -R frappe:frappe /home/frappe/frappe-bench/sites/assets
        touch /home/frappe/frappe-bench/sites/assets/.restored
        chown frappe:frappe /home/frappe/frappe-bench/sites/assets/.restored
        echo "[entrypoint] Assets restored — no bench build needed at runtime."
    else
        echo "[entrypoint] No asset snapshot at /var/lib/frappe-assets — first request may 404 on CSS/JS."
    fi
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
            # Only consider apps that have a proper Frappe app structure
            [ -f "$APP_DIR/setup.py" ] || continue
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

# NOTE: no runtime `bench build` — assets are pre-built into
# /var/lib/frappe-assets/ by the Dockerfile and restored to
# sites/assets/ at the top of this entrypoint on first boot. Saves
# 5-10 min of Pi-side compilation on every fresh install.

# ── Cleanup: stop inline redis so supervisord starts clean ────────
echo "[entrypoint] Stopping inline redis..."
redis-cli shutdown nosave 2>/dev/null || true
sleep 1

touch "$MARKER"
chown frappe:frappe "$MARKER"

echo "[entrypoint] First-boot setup complete. Starting supervisord."
exec "$@"
