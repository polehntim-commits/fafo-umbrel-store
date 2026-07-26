#!/bin/bash
# SPDX-License-Identifier: MIT
#
# ── Self-healing strategy ─────────────────────────────────────────
# This container has four defense layers against runtime corruption:
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
#   4. Asset watchdog (supervisord). Polls sites/assets/ every 30
#      seconds. If the canary disappears mid-runtime (from bench
#      migrate/build/clear-cache), restores from snapshot and
#      reloads nginx. Closes the gap between "wipe" and "container
#      reboot" — no unstyled page for more than ~30 seconds.
#
#   5. DB grant self-heal (v15.1.2, this file + db_grant_selfheal.py,
#      runs every boot). `bench new-site` pins the site's MariaDB user
#      grant to the container's IP at creation time
#      (`user@10.21.0.27`). Docker reassigns container IPs on recreate,
#      after which every request 500s with
#      `Access denied for user 'X'@'<new-ip>'`. This block reconciles
#      each site's grant to the host-independent `user@'%'` using the
#      root credentials compose already supplies, so the next IP
#      change is a non-event. The incident that motivated it hit
#      Tim's mom's Umbrel on 2026-07-26 after the v0.4.0 MCP deploy.
#
# Combined: any single cache clear, asset delete, partial migration,
# or container-IP reassignment recovers automatically on the next
# container restart with zero manual intervention. Multiple
# simultaneous failures may still require operator attention.
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
#   6. Make sure the ERPNext Setup Wizard will run on first login
#      (v15.1.1 — defensive, this is already the default).
#   7. Stop the inline redis so supervisord can manage it cleanly.
#   8. Touch the marker file.
#   9. Save the initial Administrator password to a 0600 file on the
#      sites volume and print a credentials banner to stdout
#      (v15.1.1 — see "First-boot credentials UX" below).
#  10. Re-run the DB grant self-heal (v15.1.2) so the site bench just
#      created gets its host-independent `user@'%'` grant immediately,
#      rather than on the next boot.
#
# On EVERY boot (first or subsequent), before either path:
#   - Asset canary restore (layer 1 above).
#   - DB grant self-heal (layer 5 above).
#
# ── First-boot credentials UX (v15.1.1) ───────────────────────────
# umbrelOS shows the app's password in its credentials modal, derived
# from the Umbrel seed. That display broke on at least one Umbrel
# build (it rendered the literal string `$APP_PASSWORD`), which left
# the operator with no way to log in short of an SSH session. So the
# password is now surfaced through three independent channels, any
# one of which is sufficient:
#
#   a. Umbrel dashboard → app tile → "Show credentials"
#      (fixed in v15.1.1 via `deterministicPassword: true`)
#   b. `docker logs fafo-erpnext_server_1` — banner printed below,
#      once, at the end of first boot. GROUND TRUTH: it echoes the
#      exact ADMIN_PASS the site was created with.
#   c. `~/umbrel/app-data/fafo-erpnext/sites/.admin-password-initial.txt`
#      on the Umbrel host — owner-only (0600), survives container
#      recreates because Umbrel bind-mounts sites/.
#
# All of (a)/(b)/(c) resolve to the same value. If they ever
# disagree, (b) wins — it is emitted by the same shell invocation
# that ran `bench new-site --admin-password`.
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
# Export the DB coordinates so the v15.1.2 grant self-heal helper (a
# separate python process) sees the same values this script resolved,
# including the defaults above when compose didn't set them.
export DB_HOST DB_PORT DB_ROOT_PASS
MARKER=/home/frappe/frappe-bench/sites/.site-created
# Fallback copy of the initial Administrator password, written once at
# first boot with mode 0600. Lives on the bind-mounted sites volume,
# i.e. ~/umbrel/app-data/fafo-erpnext/sites/ on the Umbrel host. Never
# committed to git — it is generated at runtime from ADMIN_PASS.
PASSWORD_FILE=/home/frappe/frappe-bench/sites/.admin-password-initial.txt
# Public port the Umbrel app_proxy publishes (matches `port:` in
# umbrel-app.yml). Display-only — used in the credentials banner.
UMBREL_APP_PORT="${UMBREL_APP_PORT:-5300}"
# Bench's virtualenv interpreter. Used for the DB grant self-heal below,
# which needs pymysql — present in this venv (Frappe depends on it), NOT
# in the system python3.
BENCH_PY=/home/frappe/frappe-bench/env/bin/python

# ── wait_for_mariadb [tries] ──────────────────────────────────────
# Polls the DB port until it accepts TCP, then sleeps 3s so mysqld has
# finished its own init and is actually answering auth (nc reports the
# port open a beat before that). Returns 0 on success, 1 on timeout —
# it never exits, so each caller decides whether a missing DB is fatal.
# Callers: the v15.1.2 grant self-heal (non-fatal — a site that can't
# be healed still boots) and first-boot site creation (fatal — there is
# nothing to create the site in).
wait_for_mariadb() {
    local tries="${1:-60}"
    local i
    echo "[entrypoint] Waiting for MariaDB at $DB_HOST:$DB_PORT (up to $((tries * 2))s)..."
    for i in $(seq 1 "$tries"); do
        if nc -z "$DB_HOST" "$DB_PORT" 2>/dev/null; then
            echo "[entrypoint] MariaDB reachable after ${i} tries."
            sleep 3
            return 0
        fi
        sleep 2
    done
    echo "[entrypoint] MariaDB unreachable after $((tries * 2))s."
    return 1
}

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

# ── DB grant self-heal (v15.1.2) ──────────────────────────────────
# Runs on EVERY boot, and deliberately BEFORE the marker fast-path
# below — the drift this fixes only happens to sites that already
# exist, so putting it on the first-boot path would never fire for the
# case it was written for.
#
# `bench new-site` binds the site's MariaDB user to the container's
# current IP (`user@10.21.0.27`). Docker hands out a different IP on
# the next container recreate and Frappe's every query dies with
# "Access denied for user 'X'@'<new-ip>'" — a 500 on every request,
# with the correct password still sitting in site_config.json. Frappe
# ships no bench command that repairs this, so we reconcile against
# MariaDB directly: for each site, re-grant `user@'%'` (host-
# independent) using the root credentials compose already provides.
#
# Fully idempotent: on a healthy site the statements are no-ops. The
# helper prints a per-site before/after login probe so `docker logs`
# shows whether anything was actually healed.
#
# NON-FATAL BY DESIGN. Every failure path — DB down, wrong root
# password, malformed site_config.json — logs loudly and returns
# non-zero, and we continue to supervisord anyway. A site with a bad
# grant is still better than a container that will not start. The
# helper's own retry loop handles a slow MariaDB, so the wait below
# is short; `|| true` keeps `set -e` from turning either into a boot
# failure.
echo "[entrypoint] ── DB grant self-heal (v15.1.2) ──"
if [ -x "$BENCH_PY" ]; then
    wait_for_mariadb 15 || \
        echo "[entrypoint] WARNING: MariaDB not reachable before grant self-heal — running it anyway (it retries internally)."
    "$BENCH_PY" /usr/local/bin/db-grant-selfheal \
        || echo "[entrypoint] WARNING: DB grant self-heal reported failures (see [db-selfheal] lines above). Continuing boot — the site may return 500s until repaired."
else
    echo "[entrypoint] WARNING: $BENCH_PY not found — skipping DB grant self-heal. If the site 500s with \"Access denied for user\", regrant manually (see fafo-erpnext/README.md)."
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
        # ── Regenerate sites/apps.txt from apps/ dir ──────────────────────
        # `bench install-app` fails with "App not in apps.txt" when the site's
        # apps.txt is stale relative to the apps/ directory. This bit us on
        # 2026-07-09 when hrms was baked in but apps.txt still listed only
        # frappe/erpnext/agriculture/farm_i9. Regenerate on every boot from
        # the actual apps dir so the two stay in sync.
        echo "[entrypoint] Regenerating sites/apps.txt from apps/ dir..."
        su frappe -s /bin/bash -c "ls -1 /home/frappe/frappe-bench/apps > /home/frappe/frappe-bench/sites/apps.txt"
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
# Fatal here, unlike the self-heal's call above: there is no site yet
# and nothing to create it in. wait_for_mariadb already includes the
# post-connect settle sleep.
wait_for_mariadb 60 || {
    echo "[entrypoint] MariaDB unreachable — aborting first-boot site creation."
    exit 1
}

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

# ── farm_precision_ag install (Tim 2026-07-09) ────────────────────
# Precision agriculture Frappe app baked into image at
# /home/frappe/frappe-bench/apps/farm_precision_ag/. Install on
# the fresh site if the app dir exists. Failure is soft.
if [ -d /home/frappe/frappe-bench/apps/farm_precision_ag ]; then
    echo "[entrypoint] Installing farm_precision_ag on $SITE_NAME..."
    if su frappe -s /bin/bash -c "bench --site $SITE_NAME install-app farm_precision_ag"; then
        echo "[entrypoint] farm_precision_ag installed."
    else
        echo "[entrypoint] farm_precision_ag install-app failed — site is up without it. Install manually via UI."
    fi
else
    echo "[entrypoint] farm_precision_ag dir not present in image — running without it."
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

# ── Force the ERPNext Setup Wizard on first login (v15.1.1) ───────
# Frappe v15 decides whether to show the Setup Wizard in
# `frappe.is_setup_complete()`, which reads the `is_setup_complete`
# column of the `Installed Application` child table for the `frappe`
# and `erpnext` apps. It is NOT `System Settings.setup_complete`
# (that field still exists, but v15 only writes it as a legacy mirror
# from `disable_future_access()`), and it is NOT a `setup_complete`
# key in site_config.json — no such key exists in v15.
#
# `bench new-site --install-app erpnext` already leaves both rows at
# 0, so the wizard fires on first login by default. The writes below
# are belt-and-braces against a future bench/app release changing
# that default; on a normal boot they are no-ops. Both soft-fail — a
# bench version that renames the column must not brick the boot.
#
# Runs while the inline redis is still up (bench needs it) and
# strictly on the first-boot path, so an existing site is never
# touched.
#
# What the wizard does NOT do: rewrite the Administrator account's
# password. Its account slide CREATES a second User from the email +
# password typed into it (frappe.desk.page.setup_wizard →
# create_or_update_user); Administrator keeps ADMIN_PASS until
# somebody changes it explicitly. That is why the README tells
# operators to run `bench set-admin-password` once they are in.
echo "[entrypoint] Ensuring the ERPNext Setup Wizard runs on first login..."
SW_FRAPPE='{"dt": "Installed Application", "dn": {"app_name": "frappe"}, "field": "is_setup_complete", "val": 0}'
SW_ERPNEXT='{"dt": "Installed Application", "dn": {"app_name": "erpnext"}, "field": "is_setup_complete", "val": 0}'
SW_LEGACY='{"doctype": "System Settings", "fieldname": "setup_complete", "value": 0}'

for SW_KWARGS in "$SW_FRAPPE" "$SW_ERPNEXT"; do
    su frappe -s /bin/bash -c \
        "cd /home/frappe/frappe-bench && bench --site $SITE_NAME execute frappe.db.set_value --kwargs '$SW_KWARGS'" \
        >/dev/null 2>&1 \
        || echo "[entrypoint] WARNING: could not clear is_setup_complete for $SW_KWARGS — leaving bench's default (normally 0, i.e. the wizard still shows)."
done

su frappe -s /bin/bash -c \
    "cd /home/frappe/frappe-bench && bench --site $SITE_NAME execute frappe.db.set_single_value --kwargs '$SW_LEGACY'" \
    >/dev/null 2>&1 \
    || echo "[entrypoint] WARNING: could not clear System Settings.setup_complete — non-fatal, v15 reads Installed Application instead."

# ── Cleanup: stop inline redis so supervisord starts clean ────────
echo "[entrypoint] Stopping inline redis..."
redis-cli shutdown nosave 2>/dev/null || true
sleep 1

touch "$MARKER"
chown frappe:frappe "$MARKER"

# ── Pin the brand-new site's grant host-independent (v15.1.2) ─────
# `bench new-site` just created this site's MariaDB user pinned to the
# container's CURRENT IP. It works right now, and would break on the
# first container recreate that lands on a different address. The
# every-boot self-heal near the top of this script runs BEFORE the
# site exists on a first boot, so it found nothing to do — run it once
# more here to add the `user@'%'` grant while we still have the
# operator's attention in the first-boot log. Same non-fatal contract.
echo "[entrypoint] ── DB grant self-heal (post-new-site pass) ──"
if [ -x "$BENCH_PY" ]; then
    "$BENCH_PY" /usr/local/bin/db-grant-selfheal \
        || echo "[entrypoint] WARNING: post-new-site grant self-heal reported failures (see [db-selfheal] lines above). Site is up; the grant will be retried on next boot."
fi

# ── Persist the initial Administrator password (v15.1.1) ──────────
# Fallback channel (c) — see "First-boot credentials UX" at the top.
# Written only on this first-boot path, so an existing install
# upgrading to v15.1.1 never gets the file and never sees the banner
# below. The function body is a subshell so `umask 077` cannot leak
# into the rest of the boot; the file is created 0600 from the outset
# rather than chmod'ed after the fact, so the password is never
# world-readable even momentarily.
write_password_file() (
    umask 077
    cat > "$PASSWORD_FILE" <<PWFILE
ERPNext + Agriculture + Farm HR + Precision Ag — initial credentials
Written at first boot by fafo-erpnext entrypoint.sh (v15.1.1).

  Username: Administrator
  Password: $ADMIN_PASS

This is the password the site was CREATED with. It stays valid for the
Administrator account until you change it — the Setup Wizard's account
step creates a separate named user and leaves Administrator alone.

To change it:
  docker exec -u frappe fafo-erpnext_server_1 \\
    bench --site $SITE_NAME set-admin-password '<new-password>'

Safe to delete this file once you have logged in and set your own
password. The value is always recoverable with:
  docker exec fafo-erpnext_server_1 printenv ADMIN_PASS
PWFILE
)

if write_password_file; then
    chmod 600 "$PASSWORD_FILE" 2>/dev/null || true
    chown frappe:frappe "$PASSWORD_FILE" 2>/dev/null || true
    echo "[entrypoint] Initial Administrator password saved to $PASSWORD_FILE (mode 0600)."
else
    echo "[entrypoint] WARNING: could not write $PASSWORD_FILE — recover the password with 'docker exec fafo-erpnext_server_1 printenv ADMIN_PASS'."
fi

# ── Credentials banner (v15.1.1) ──────────────────────────────────
# Channel (b), and the authoritative one: this is the same shell that
# just ran `bench new-site --admin-password "$ADMIN_PASS"`, so what it
# prints is by construction the password the site actually has.
# First-boot only — `docker logs fafo-erpnext_server_1` keeps it for
# the life of the container, and `docker logs --since` still finds it
# after later restarts.
cat <<BANNER || true
================================================================================
 ERPNext + Agriculture + Farm HR + Precision Ag — FIRST-BOOT CREDENTIALS
================================================================================
  URL:       http://<your-umbrel-host>:$UMBREL_APP_PORT
             (e.g. http://umbrel.local:$UMBREL_APP_PORT)
  Username:  Administrator
  Password:  $ADMIN_PASS

  ERPNext's Setup Wizard runs on your first login. It walks you through
  Company setup and creates your own named admin user. The Administrator
  password above stays valid afterwards — change it when convenient.

  To retrieve this password later:
    docker exec fafo-erpnext_server_1 printenv ADMIN_PASS
  Or, on the Umbrel host:
    sudo cat ~/umbrel/app-data/fafo-erpnext/sites/.admin-password-initial.txt
================================================================================
BANNER

echo "[entrypoint] First-boot setup complete. Starting supervisord."
exec "$@"
