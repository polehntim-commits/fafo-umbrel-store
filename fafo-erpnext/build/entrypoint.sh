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

# Fast path: marker present → jump to supervisord immediately.
if [ -f "$MARKER" ]; then
    echo "[entrypoint] Marker exists — site already created, starting supervisord."
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

# ── Best-effort: fetch + install frappe/agriculture ───────────────
echo "[entrypoint] Fetching frappe/agriculture..."
if su frappe -s /bin/bash -c "bench get-app --branch develop agriculture https://github.com/frappe/agriculture.git"; then
    echo "[entrypoint] Installing agriculture on $SITE_NAME..."
    if su frappe -s /bin/bash -c "bench --site $SITE_NAME install-app agriculture"; then
        echo "[entrypoint] Agriculture installed."
    else
        echo "[entrypoint] agriculture install-app failed — site is up without it. Install manually via UI."
    fi
else
    echo "[entrypoint] agriculture get-app failed (probably framework compat) — continuing without it."
fi

# ── Cleanup: stop inline redis so supervisord starts clean ────────
echo "[entrypoint] Stopping inline redis..."
redis-cli shutdown nosave 2>/dev/null || true
sleep 1

touch "$MARKER"
chown frappe:frappe "$MARKER"

echo "[entrypoint] First-boot setup complete. Starting supervisord."
exec "$@"
