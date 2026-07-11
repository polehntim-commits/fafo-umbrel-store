# Single-container ERPNext + Agriculture image for Umbrel packaging.
#
# Umbrel's community app store strips docker-compose services outside
# its whitelist, so multi-service compose files (like the 10-service
# frappe/frappe_docker canonical setup) never actually run under
# Umbrel. This image collapses all Frappe processes into ONE container
# with supervisord orchestrating them, so the Umbrel compose can be
# the classic `db + server + app_proxy` triple that we KNOW Umbrel
# accepts.
#
# Processes managed inside the container by supervisord:
#   * asset-watchdog — polls sites/assets/ every 30s, restores from
#                   the image snapshot if a runtime command wipes it
#   * redis      — local, 3 logical DBs (0=cache, 1=queue, 2=socketio)
#   * backend    — Frappe Python via gunicorn on 127.0.0.1:8000
#   * frontend   — nginx on 0.0.0.0:8080 (Umbrel app_proxy target)
#   * websocket  — Node socket.io on 127.0.0.1:9000
#   * queue-short — background worker for short + default queues
#   * queue-long  — background worker for the long queue
#   * scheduler   — cron-like scheduler
#
# Nginx config drop-in (not a supervisord process):
#   * cache-control.conf — forces no-cache/must-revalidate on HTML so
#                   browsers never cache stale hashed-asset references;
#                   hashed CSS/JS bundles stay long-cached + immutable
#
# MariaDB stays as an external `db` sidecar (persistence, upgrade
# semantics, RAM isolation). Redis stays IN this container because
# it's ephemeral cache — losing it on container restart is fine.
#
# Base image is `frappe/erpnext:v15.115.0` (Frappe Technologies'
# official, has bench + all Python deps preinstalled). We just
# layer supervisord, redis-server, and our config on top.
#
# Apps baked into the image (cloned at build time so they survive
# container recreates — Umbrel bind-mounts sites/ but not apps/):
#   * agriculture — frappe/agriculture (branch develop)
#   * farm_i9     — polehntim-commits/farm_i9 (branch main), the
#                   US-compliance layer (workspace: Farm HR)
#   * hrms        — frappe/hrms (branch version-15), Frappe HR +
#                   Payroll framework that farm_i9 rides on top of
#   * farm_precision_ag — polehntim-commits/farm_precision_ag (branch
#                   main), precision-ag suite (Phase B: USDA Market
#                   Pricing; Land/Blocks/Spray/IPM/Costing follow)

FROM frappe/erpnext:v15.115.0

# Self-heal advertisement — lets an operator confirm at a glance
# (`docker inspect`) that this image carries the runtime recovery
# behavior: asset canary restore, healthcheck-driven restart, and
# idempotent app reconcile. See entrypoint.sh for the full strategy.
LABEL org.polehnfarm.self-heal="asset-canary,healthcheck,app-reconcile"
LABEL org.polehnfarm.self-heal.version="1"

USER root

# Install supervisord to orchestrate the multiple Frappe processes,
# plus redis-server (bundled inside the container so we stay one
# service from Umbrel's perspective).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        supervisor \
        redis-server \
        netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Redis tuning: bind localhost only (no external access), cap memory
# so a runaway job can't OOM the container, LRU eviction so the
# oldest cache entries drop first.
RUN sed -i 's/^bind .*/bind 127.0.0.1 ::1/' /etc/redis/redis.conf && \
    sed -i 's/^# maxmemory .*/maxmemory 256mb/' /etc/redis/redis.conf && \
    sed -i 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf && \
    sed -i 's/^daemonize yes/daemonize no/' /etc/redis/redis.conf && \
    sed -i 's|^dir /var/lib/redis|dir /tmp|' /etc/redis/redis.conf && \
    sed -i 's|^logfile .*|logfile ""|' /etc/redis/redis.conf && \
    sed -i 's|^pidfile .*|pidfile /tmp/redis-server.pid|' /etc/redis/redis.conf && \
    sed -i 's|^save .*|save ""|' /etc/redis/redis.conf && \
    sed -i 's|^stop-writes-on-bgsave-error yes|stop-writes-on-bgsave-error no|' /etc/redis/redis.conf

# ── Bake frappe/agriculture into the image ────────────────────────
# The app lives in `apps/agriculture/`. Umbrel bind-mounts `sites/`
# but not `apps/`, so cloning at runtime via `bench get-app` gets
# wiped on container recreate. Cloning here at build time makes
# agriculture a permanent image layer. Then the entrypoint's
# `bench install-app agriculture` finds the code and completes
# cleanly.
#
# `bench get-app` runs as frappe (the base image's default user for
# bench operations) — we `su frappe` to preserve venv activation
# and file ownership. Fails soft with `|| true` so a network hiccup
# during build doesn't kill the whole image; entrypoint will note
# the missing app and skip cleanly.
#
# TWO-STEP install to defeat two long-standing footguns:
#   1. `bench get-app` sometimes reports success but leaves the app
#      un-pip-installed. We follow with an explicit `pip install -e`
#      + --force-reinstall so the editable install is guaranteed.
#   2. Docker's layer cache doesn't know when GitHub has new commits.
#      The ADD https://api.github.com/... below returns the current
#      HEAD SHA in its body; when agriculture develop advances the
#      SHA changes and Docker invalidates every layer from here down,
#      forcing a fresh clone + install.

# ── Cache-bust when frappe/agriculture develop advances ──────────
# Same pattern as farm_i9 below. Less frequently updated so the
# cache-bust rarely fires, but consistency is worth the one extra
# HTTP request at build time.
ADD https://api.github.com/repos/frappe/agriculture/commits/develop /tmp/.agriculture_head.json
USER frappe
RUN cd /home/frappe/frappe-bench && \
    (bench get-app --branch develop agriculture https://github.com/frappe/agriculture.git \
     || echo "[dockerfile] agriculture get-app failed at build — will attempt pip install anyway") && \
    (if [ -d apps/agriculture ]; then \
        env/bin/pip install -e apps/agriculture --force-reinstall --no-deps \
            || echo "[dockerfile] agriculture pip install failed — image ships without a runnable agriculture"; \
     else \
        echo "[dockerfile] apps/agriculture dir missing — nothing to pip install"; \
     fi)
USER root

# ── Bake polehntim/farm_i9 into the image ─────────────────────────
# Custom I-9 employment eligibility workflow app. Same pattern as
# agriculture above — clone at build time so the code survives
# container recreates (Umbrel bind-mounts sites/ but not apps/).
#
# TWO-STEP install to defeat two long-standing footguns:
#   1. `bench get-app` sometimes reports success but leaves the app
#      un-pip-installed. We follow with an explicit `pip install -e`
#      + --force-reinstall so the editable install is guaranteed.
#   2. Docker's layer cache doesn't know when GitHub has new commits.
#      The ADD https://api.github.com/... above returns the current
#      HEAD SHA in its body; when Tim pushes new farm_i9 code the
#      SHA changes and Docker invalidates every layer from here down,
#      forcing a fresh clone + install.
#
# The `|| echo "..."` guards keep a network hiccup or one-off failure
# from killing the whole build — the entrypoint's app-reconcile
# block also runs `bench install-app` at runtime and can fill in the
# gap if this step went sideways.

# ── Cache-bust when farm_i9 main branch advances ──────────────────
# Docker's ADD instruction fetches the URL response body as a cache
# key. GitHub's commits API returns the current HEAD commit SHA in
# its response — when Tim pushes new commits, the SHA changes and
# Docker invalidates every layer below this line, forcing a fresh
# `bench get-app` + `pip install`. Without this, `docker build`
# happily reuses the stale layer from a previous build even when
# there's newer farm_i9 code on GitHub.
ADD https://api.github.com/repos/polehntim-commits/farm_i9/commits/main /tmp/.farm_i9_head.json
USER frappe
RUN cd /home/frappe/frappe-bench && \
    (bench get-app --branch main farm_i9 https://github.com/polehntim-commits/farm_i9.git \
     || echo "[dockerfile] farm_i9 get-app failed at build — will attempt pip install anyway") && \
    (if [ -d apps/farm_i9 ]; then \
        env/bin/pip install -e apps/farm_i9 --force-reinstall --no-deps \
            || echo "[dockerfile] farm_i9 pip install failed — image ships without a runnable farm_i9"; \
     else \
        echo "[dockerfile] apps/farm_i9 dir missing — nothing to pip install"; \
     fi)
USER root

# ── Cache-bust when frappe/hrms version-15 branch advances ────────
# Same pattern as farm_i9 and agriculture above — GitHub's commits
# endpoint returns the current HEAD SHA in the response body, which
# Docker uses as a cache key. When Frappe pushes fixes to
# version-15, Tim's next `docker build` invalidates this layer and
# every layer below it, forcing a fresh clone + install.
ADD https://api.github.com/repos/frappe/hrms/commits/version-15 /tmp/.hrms_head.json

# ── Bake frappe/hrms into the image ───────────────────────────────
# Frappe Technologies' official HR + Payroll app. Layers Employee,
# Attendance, Timesheet, Leave, Salary Component/Structure/Slip,
# Payroll Entry, Recruitment, Onboarding on top of ERPNext. Tim's
# farm_i9 (workspace: Farm HR) rides on top of these DocTypes for
# US-specific compliance (I-9, W-4, W-2, etc.).
#
# Version-15 branch matches the ERPNext v15.115.0 base image. Two-
# step install (get-app + explicit pip install -e) matches the
# farm_i9 and agriculture blocks — bench get-app has a silent-fail
# pip step, so we always follow with an explicit pip install to
# guarantee the app is importable at runtime.
USER frappe
RUN cd /home/frappe/frappe-bench && \
    (bench get-app --branch version-15 hrms https://github.com/frappe/hrms.git \
     || echo "[dockerfile] hrms get-app failed at build — will attempt pip install anyway") && \
    (if [ -d apps/hrms ]; then \
        env/bin/pip install -e apps/hrms --force-reinstall --no-deps \
            || echo "[dockerfile] hrms pip install failed — image ships without a runnable hrms"; \
     else \
        echo "[dockerfile] apps/hrms dir missing — nothing to pip install"; \
     fi)
USER root

# ── Cache-bust when polehntim/farm_precision_ag main branch advances ─
# Same pattern as farm_i9 and hrms above.
ADD https://api.github.com/repos/polehntim-commits/farm_precision_ag/commits/main /tmp/.farm_precision_ag_head.json

# ── Bake polehntim/farm_precision_ag into the image ──────────────
# Precision agriculture Frappe app. Phase B (USDA Market Pricing)
# is the initial feature — Land/Blocks/Implements/Spray/IPM/
# Attestations/Costing follow in later phases. Same two-step
# install (get-app + explicit pip install -e) as sibling apps to
# guarantee importable at runtime.
USER frappe
RUN cd /home/frappe/frappe-bench && \
    (bench get-app --branch main farm_precision_ag https://github.com/polehntim-commits/farm_precision_ag.git \
     || echo "[dockerfile] farm_precision_ag get-app failed at build — will attempt pip install anyway") && \
    (if [ -d apps/farm_precision_ag ]; then \
        env/bin/pip install -e apps/farm_precision_ag --force-reinstall --no-deps \
            || echo "[dockerfile] farm_precision_ag pip install failed — image ships without a runnable farm_precision_ag"; \
     else \
        echo "[dockerfile] apps/farm_precision_ag dir missing — nothing to pip install"; \
     fi)
USER root

# ── Pre-build all app assets AND cache them for restore ───────────
# `bench build` compiles CSS + JS bundles for every installed app
# into `sites/assets/`. On first boot Umbrel's bind-mount hides that
# dir, so we snapshot it to `/var/lib/frappe-assets/` here. The
# entrypoint restores from the snapshot into the empty mounted
# `sites/assets/` at first boot, so nginx serves everything
# immediately without a 15-min Pi-side rebuild.
USER frappe
RUN cd /home/frappe/frappe-bench && \
    (bench build --production || echo "[dockerfile] bench build failed — will retry in entrypoint")
USER root
RUN if [ -d /home/frappe/frappe-bench/sites/assets ]; then \
        mkdir -p /var/lib/frappe-assets && \
        cp -r /home/frappe/frappe-bench/sites/assets/. /var/lib/frappe-assets/ && \
        chown -R frappe:frappe /var/lib/frappe-assets; \
    fi

# Supervisord process definitions + our first-boot entrypoint.
COPY supervisord.conf /etc/supervisor/conf.d/erpnext.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Asset watchdog script (see supervisord.conf entry). Restores
# sites/assets/ if runtime commands wipe it. See design notes in
# asset_watchdog.sh's header.
COPY asset_watchdog.sh /usr/local/bin/asset-watchdog
RUN chmod +x /usr/local/bin/asset-watchdog

# Cache-Control header rules — force fresh HTML, long-cache hashed
# assets. See file header for rationale. Dropped into conf.d/ so
# nginx's default http{} block includes it (the base image's
# nginx-entrypoint.sh generates the server{} block from a template
# we can't easily edit, but conf.d/*.conf is included regardless).
COPY nginx-cache-control.conf /etc/nginx/conf.d/cache-control.conf

# Frontend nginx is the only externally-exposed port. Everything
# else (backend gunicorn, websocket, redis) is localhost-only.
EXPOSE 8080

# Sites volume is where Frappe stores common_site_config.json, per-
# site configs, uploaded files, and the .site-created marker.
# Persisting this across container recreates is what keeps the site
# alive between updates.
VOLUME ["/home/frappe/frappe-bench/sites"]

# HEALTHCHECK — nginx serves an unstyled page when assets are missing.
# Poll the asset manifest endpoint; if it 404s or 500s for 90s+
# (30s interval × 3 retries) Docker marks the container unhealthy.
# Umbrel's watchdog restarts unhealthy containers, which triggers the
# entrypoint's self-heal path.
#
# We poll /assets/assets.json (the esbuild manifest) rather than a
# specific bundle: Frappe v15 content-hashes bundle filenames
# (frappe-web.bundle.<HASH>.js), so there is no stable bundle URL to
# hardcode, but assets.json always lives at a fixed path and is the
# exact file wiped by `clear-website-cache`. `curl -f` makes any
# non-2xx status count as failure. `curl` is already present in the
# base frappe/erpnext:v15.115.0 image (no apt install needed). Grace
# period of 5 min accommodates cold-boot bench new-site +
# agriculture/farm_i9 install.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD curl -f -o /dev/null http://127.0.0.1:8080/assets/assets.json || exit 1

# Entrypoint handles first-boot site creation + agriculture install,
# then execs supervisord to run all the Frappe processes.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
