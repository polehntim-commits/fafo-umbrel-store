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
#   * farmops-api — erpnext_mcp v0.18.0's mobile API via gunicorn on
#                   0.0.0.0:5250 in-container, published to the host
#                   as 127.0.0.1:5250 by the compose. It serves the
#                   eleven methods the Farm Ops iOS app calls, OFF
#                   Frappe's /api/method handler — through the
#                   Tailscale funnel that handler answered every
#                   credential carrier with the Desk's HTML login
#                   page. It still imports Frappe and calls the same
#                   guarded functions; Frappe is just no longer the
#                   thing that reads the request. NO NEW PACKAGES:
#                   gunicorn is already in the bench venv and
#                   Werkzeug ships with Frappe. See supervisord.conf.
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
# Base image is `frappe/erpnext:v15.123.0` (Frappe Technologies'
# official, has bench + all Python deps preinstalled). It ships
# Frappe v15.123.1 + ERPNext v15.123.0. We just layer supervisord,
# redis-server, and our config on top.
#
# Pinned by tag AND digest (2026-10-18). The digest makes a rebuild
# of this Dockerfile reproduce the same Frappe/ERPNext code even if
# upstream re-pushes the tag; bumping the base means changing both.
# Previous base: v15.115.0 (Frappe 15.113.4) — see CHANGELOG.md,
# "Base image v15.123.0" (2026-10-18).
#
# Apps baked into the image (cloned at build time so they survive
# container recreates — Umbrel bind-mounts sites/ but not apps/):
#   * agriculture — frappe/agriculture (branch develop)
#   * farm_i9     — polehntim-commits/farm_i9 (branch main, PRIVATE), the
#                   US-compliance layer (workspace: Farm HR)
#   * hrms        — frappe/hrms (tag HRMS_REF, v15.64.5), Frappe HR +
#                   Payroll framework that farm_i9 rides on top of
#   * farm_precision_ag — polehntim-commits/farm_precision_ag (branch
#                   main, PRIVATE), precision-ag suite (Phase B: USDA Market
#                   Pricing; Land/Blocks/Spray/IPM/Costing follow)

FROM frappe/erpnext:v15.123.0@sha256:ad1f567771a87961c20f1516df6b11228a3eac31cfba00d358b23803b7b44f4b

# Self-heal advertisement — lets an operator confirm at a glance
# (`docker inspect`) that this image carries the runtime recovery
# behavior: asset canary restore, healthcheck-driven restart, and
# idempotent app reconcile. See entrypoint.sh for the full strategy.
# NOTE: this pair is superseded by the LABEL near the COPY of
# db-grant-selfheal at the bottom of this file (a later LABEL wins for the
# same key). It is kept here, unchanged, purely so editing the self-heal
# inventory does not invalidate the build cache for the ~6 GB of app clones
# and `bench build` layers that follow.
LABEL org.polehnfarm.self-heal="asset-canary,healthcheck,app-reconcile"
LABEL org.polehnfarm.self-heal.version="1"

USER root

# ── Restore the `frappe` group (base image v15.123.0, 2026-10-18) ─
# Up to v15.115.0 the base image's frappe user was uid 1000 / gid
# 1000(frappe). From the v15.12x images it is uid 1000 / gid 0(root),
# and there is NO group named `frappe` at all — so every
# `chown frappe:frappe` in this Dockerfile, entrypoint.sh and
# asset_floor.py fails with "invalid group". At build time that kills
# the asset-snapshot layer; at runtime the `|| true` guards would hide
# it and leave new files group-owned by root.
#
# Re-adding the group at gid 1000 (free in the new image) makes those
# calls mean what they always meant, and keeps new files in line with
# what every existing sites volume already holds (1000:1000). The
# user's primary group is deliberately left as upstream set it.
RUN getent group frappe >/dev/null || groupadd -g 1000 frappe

# Install supervisord to orchestrate the multiple Frappe processes,
# plus redis-server (bundled inside the container so we stay one
# service from Umbrel's perspective).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        supervisor \
        redis-server \
        netcat-openbsd \
        libreoffice-writer \
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
# Same pattern as hrms below. Less frequently updated so the
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

# ── frappe/hrms is pinned to a release tag (2026-10-18) ───────────
# It used to track the version-15 branch HEAD, which meant the HRMS
# in the image was whatever HEAD happened to be at build time — not
# something a rollback note or an advisory check can name. It is now
# a tag, bumped deliberately alongside the base image above. The
# commits endpoint accepts a tag as the ref, so the cache key still
# changes when HRMS_REF does.
ARG HRMS_REF=v15.64.5
ADD https://api.github.com/repos/frappe/hrms/commits/${HRMS_REF} /tmp/.hrms_head.json

# ── Bake frappe/hrms into the image ───────────────────────────────
# Frappe Technologies' official HR + Payroll app. Layers Employee,
# Attendance, Timesheet, Leave, Salary Component/Structure/Slip,
# Payroll Entry, Recruitment, Onboarding on top of ERPNext. Tim's
# farm_i9 (workspace: Farm HR) rides on top of these DocTypes for
# US-specific compliance (I-9, W-4, W-2, etc.).
#
# HRMS_REF is a v15 tag matching the ERPNext v15.123.0 base image. Two-
# step install (get-app + explicit pip install -e) matches the
# farm_i9 and agriculture blocks — bench get-app has a silent-fail
# pip step, so we always follow with an explicit pip install to
# guarantee the app is importable at runtime.
USER frappe
RUN cd /home/frappe/frappe-bench && \
    (bench get-app --branch ${HRMS_REF} hrms https://github.com/frappe/hrms.git \
     || echo "[dockerfile] hrms get-app failed at build — will attempt pip install anyway") && \
    (if [ -d apps/hrms ]; then \
        env/bin/pip install -e apps/hrms --force-reinstall --no-deps \
            || echo "[dockerfile] hrms pip install failed — image ships without a runnable hrms"; \
     else \
        echo "[dockerfile] apps/hrms dir missing — nothing to pip install"; \
     fi)
USER root


# ── FAST BUILD (2026-11-04): the slow, stable layers come first ───
# Everything above this line changes only when a pin changes: the base
# image digest, the apt list, agriculture's develop head, HRMS_REF, or
# the pip set below. Everything after it is Tim's own apps, which
# change on most builds. With the standard (cached) build, a new
# erpnext_mcp commit rebuilds only the layers from its clone down;
# apt, agriculture, hrms and this full asset build come from cache.
# A clean rebuild (`--no-cache --pull`) is the monthly / base-change
# variant in the deploy file.
USER frappe
# erpnext_mcp declares these and imports every one of them defensively: without
# shapely and h3 the six boundary tools go unavailable, without reportlab the two
# tax-form PDF tools do (v0.36.0), and in both cases they say so by name rather
# than taking the rest of the app down with them. Baked in so the image never
# ships in that degraded state.
RUN cd /home/frappe/frappe-bench && \
    echo "[dockerfile] installing erpnext_mcp dependencies (shapely, h3, reportlab)" && \
    env/bin/pip install shapely h3 reportlab

# Full production build of the STABLE apps' assets (frappe, erpnext,
# agriculture, hrms — the apps in apps.txt at this point). Cached until
# one of them changes. The private apps get their own small build after
# they are cloned: Frappe's build merges assets.json (it never drops
# another app's entries) and `--apps` limits the bundle and the
# translation compile to the named apps, while every app's
# sites/assets/<app> link is (re)made either way.
RUN cd /home/frappe/frappe-bench && \
    (bench build --production || echo "[dockerfile] bench build (stable apps) failed — will retry in entrypoint")
USER root

# ── Bake polehntim/farm_i9 into the image ─────────────────────────
# Custom I-9 employment eligibility workflow app, cloned at build time
# so the code survives container recreates (Umbrel bind-mounts sites/
# but not apps/). Explicit `pip install -e` after get-app, because
# `bench get-app` has a silent-fail pip step.
#
# PRIVATE REPO (2026-10-26): read with the same BuildKit secret as
# erpnext_mcp (see "erpnext_mcp is a PRIVATE repo" below for the build
# command). The commit is the FARM_I9_SHA build arg (2026-11-04: it
# replaced a RUN that asked the commits API, which a cached build never
# re-ran); the clone must land on exactly that commit, and the build
# record /tmp/.farm_i9_head.json (sha only) is written from it. The clone is the erpnext_mcp
# recipe: the token goes to git as an http.extraheader through this
# command's GIT_CONFIG_* environment (never in the URL), remotes are
# reset to the plain URL, docs/tests are stripped, and the build FAILS
# if the clone, the pip install or the import fails, or the token (raw
# or base64) is found under apps/farm_i9, sites/ or logs/. No `|| echo`
# fallback: an image without this app is a failed build.
# Plain `git clone` (the exact command bench get-app runs) instead of
# `bench get-app`: get-app's own install step ALWAYS fails here — the
# app's requirements.txt lists `frappe`, and uv cannot re-resolve
# Frappe's git-pinned pypika ("URL dependencies must be expressed as
# direct requirements"). The old `|| echo` hid that on every build;
# the `pip install --no-deps` below is what has always installed it.
# The app is added to sites/apps.txt here so `bench build` builds its
# assets (the entrypoint regenerates apps.txt from apps/ at boot).
USER root
# The commit to bake is a BUILD ARG (FARM_I9_SHA, the full 40-hex SHA the deploy command reads from
# GitHub just before the build). It is what busts this app's cache — and only from here down —
# when farm_i9 moves; the clone below must land on exactly that commit or the build fails.
ARG FARM_I9_SHA
USER frappe
RUN --mount=type=secret,id=gh_token,required=true,uid=1000,mode=0400 \
    set -eu; \
    echo "${FARM_I9_SHA}" | grep -Eqx '[0-9a-f]{40}' || { echo "[dockerfile] pass --build-arg FARM_I9_SHA=<the 40-hex commit of farm_i9 main> — failing the build" >&2; exit 1; }; \
    cd /home/frappe/frappe-bench; \
    tok="$(cat /run/secrets/gh_token)"; \
    auth="$(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')"; \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${auth}" \
      git clone https://github.com/polehntim-commits/farm_i9.git --branch main --depth 1 --origin upstream apps/farm_i9; \
    test -f apps/farm_i9/farm_i9/__init__.py || { echo "[dockerfile] farm_i9 clone left no app at apps/farm_i9 — failing the build" >&2; exit 1; }; \
    got="$(git -C apps/farm_i9 rev-parse HEAD)"; \
    [ "$got" = "${FARM_I9_SHA}" ] || { echo "[dockerfile] farm_i9 main is $got, not the FARM_I9_SHA ${FARM_I9_SHA} this build was asked for (pushed mid-build?) — failing the build" >&2; exit 1; }; \
    printf '{"sha": "%s", "branch": "main"}' "$got" > /tmp/.farm_i9_head.json; \
    for r in $(git -C apps/farm_i9 remote); do git -C apps/farm_i9 remote set-url "$r" https://github.com/polehntim-commits/farm_i9.git; done; \
    if git -C apps/farm_i9 config --get-all http.https://github.com/.extraheader >/dev/null; then \
      git -C apps/farm_i9 config --unset-all http.https://github.com/.extraheader; \
    fi; \
    rm -rf apps/farm_i9/docs apps/farm_i9/tests apps/farm_i9/tests_standalone apps/farm_i9/RELEASES apps/farm_i9/CHANGELOG.md; \
    env/bin/pip install -e apps/farm_i9 --force-reinstall --no-deps; \
    env/bin/python -c "import farm_i9"; \
    if ! grep -qxF farm_i9 sites/apps.txt; then \
      { cat sites/apps.txt; echo; echo farm_i9; } | sed '/^$/d' > sites/apps.txt.new; \
      mv sites/apps.txt.new sites/apps.txt; \
    fi; \
    if grep -rqsF -e "$tok" -e "$auth" apps/farm_i9 sites logs; then \
      echo "[dockerfile] the GitHub token was found in the image tree after farm_i9 — failing the build" >&2; exit 1; \
    fi
USER root

# ── Bake polehntim/farm_precision_ag into the image ──────────────
# Precision agriculture Frappe app. Phase B (USDA Market Pricing)
# is the initial feature — Land/Blocks/Implements/Spray/IPM/
# Attestations/Costing follow in later phases.
#
# PRIVATE REPO (2026-10-26): read with the same BuildKit secret as
# erpnext_mcp (see "erpnext_mcp is a PRIVATE repo" below for the build
# command). The commit is the FARM_PRECISION_AG_SHA build arg (2026-11-04: it
# replaced a RUN that asked the commits API, which a cached build never
# re-ran); the clone must land on exactly that commit, and the build
# record /tmp/.farm_precision_ag_head.json (sha only) is written from it. The clone is the erpnext_mcp
# recipe: the token goes to git as an http.extraheader through this
# command's GIT_CONFIG_* environment (never in the URL), remotes are
# reset to the plain URL, docs/tests are stripped, and the build FAILS
# if the clone, the pip install or the import fails, or the token (raw
# or base64) is found under apps/farm_precision_ag, sites/ or logs/. No `|| echo`
# fallback: an image without this app is a failed build.
# Plain `git clone` (the exact command bench get-app runs) instead of
# `bench get-app`: get-app's own install step ALWAYS fails here — the
# app's requirements.txt lists `frappe`, and uv cannot re-resolve
# Frappe's git-pinned pypika ("URL dependencies must be expressed as
# direct requirements"). The old `|| echo` hid that on every build;
# the `pip install --no-deps` below is what has always installed it.
# The app is added to sites/apps.txt here so `bench build` builds its
# assets (the entrypoint regenerates apps.txt from apps/ at boot).
USER root
# The commit to bake is a BUILD ARG (FARM_PRECISION_AG_SHA, the full 40-hex SHA the deploy command reads from
# GitHub just before the build). It is what busts this app's cache — and only from here down —
# when farm_precision_ag moves; the clone below must land on exactly that commit or the build fails.
ARG FARM_PRECISION_AG_SHA
USER frappe
RUN --mount=type=secret,id=gh_token,required=true,uid=1000,mode=0400 \
    set -eu; \
    echo "${FARM_PRECISION_AG_SHA}" | grep -Eqx '[0-9a-f]{40}' || { echo "[dockerfile] pass --build-arg FARM_PRECISION_AG_SHA=<the 40-hex commit of farm_precision_ag main> — failing the build" >&2; exit 1; }; \
    cd /home/frappe/frappe-bench; \
    tok="$(cat /run/secrets/gh_token)"; \
    auth="$(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')"; \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${auth}" \
      git clone https://github.com/polehntim-commits/farm_precision_ag.git --branch main --depth 1 --origin upstream apps/farm_precision_ag; \
    test -f apps/farm_precision_ag/farm_precision_ag/__init__.py || { echo "[dockerfile] farm_precision_ag clone left no app at apps/farm_precision_ag — failing the build" >&2; exit 1; }; \
    got="$(git -C apps/farm_precision_ag rev-parse HEAD)"; \
    [ "$got" = "${FARM_PRECISION_AG_SHA}" ] || { echo "[dockerfile] farm_precision_ag main is $got, not the FARM_PRECISION_AG_SHA ${FARM_PRECISION_AG_SHA} this build was asked for (pushed mid-build?) — failing the build" >&2; exit 1; }; \
    printf '{"sha": "%s", "branch": "main"}' "$got" > /tmp/.farm_precision_ag_head.json; \
    for r in $(git -C apps/farm_precision_ag remote); do git -C apps/farm_precision_ag remote set-url "$r" https://github.com/polehntim-commits/farm_precision_ag.git; done; \
    if git -C apps/farm_precision_ag config --get-all http.https://github.com/.extraheader >/dev/null; then \
      git -C apps/farm_precision_ag config --unset-all http.https://github.com/.extraheader; \
    fi; \
    rm -rf apps/farm_precision_ag/docs apps/farm_precision_ag/tests apps/farm_precision_ag/tests_standalone apps/farm_precision_ag/RELEASES apps/farm_precision_ag/CHANGELOG.md; \
    env/bin/pip install -e apps/farm_precision_ag --force-reinstall --no-deps; \
    env/bin/python -c "import farm_precision_ag"; \
    if ! grep -qxF farm_precision_ag sites/apps.txt; then \
      { cat sites/apps.txt; echo; echo farm_precision_ag; } | sed '/^$/d' > sites/apps.txt.new; \
      mv sites/apps.txt.new sites/apps.txt; \
    fi; \
    if grep -rqsF -e "$tok" -e "$auth" apps/farm_precision_ag sites logs; then \
      echo "[dockerfile] the GitHub token was found in the image tree after farm_precision_ag — failing the build" >&2; exit 1; \
    fi
USER root

# ── erpnext_mcp is a PRIVATE repo: the build needs a read-only token ──
# The clone below authenticates with a fine-grained PAT
# (Contents: read-only on erpnext_mcp, farm_i9 and farm_precision_ag)
# passed as a BuildKit SECRET; farm_i9 and farm_precision_ag above use
# the same one:
#
#   cd fafo-erpnext/build
#   export GH_TOKEN=<fine-grained read-only token>
#   docker buildx build --builder colima --provenance=false --sbom=false \
#       --secret id=gh_token,env=GH_TOKEN \
#       --build-arg ERPNEXT_MCP_VERSION=<x.y.z> \
#       --build-arg ERPNEXT_MCP_SHA=<40-hex> --build-arg FARM_I9_SHA=<40-hex> \
#       --build-arg FARM_PRECISION_AG_SHA=<40-hex> \
#       -t polehntim/erpnext-umbrel:15 .
#   docker push polehntim/erpnext-umbrel:15
#
# The deploy file reads the three SHAs from GitHub with the same token
# right before the build. A CACHED build is the standard one: only the
# layers from the first changed app down rebuild. Add `--no-cache
# --pull` for the monthly clean rebuild, or when the base image changes.
#
# The secret is mounted at /run/secrets/gh_token for one RUN step
# only. NEVER pass the token as an ARG or ENV: those are recorded in
# the image config / `docker history` for anyone who can pull it.
# `required=true` fails the build if the secret is missing, instead of
# silently shipping an image without erpnext_mcp.
#
# ── Build record: the erpnext_mcp commit this image was built from ──
# deploy_status.py reads /tmp/.erpnext_mcp_head.json ({"sha": ...}).
# Only the sha is kept — the full API response would bake the last
# commit's diff into the image. It is written from ERPNEXT_MCP_SHA
# once the clone is proved to be that commit. ERPNEXT_MCP_SHA (and
# ERPNEXT_MCP_VERSION, expanded into the RUN command) are what change
# the layer key: a comment would not — Docker strips comments before
# hashing the instruction.
# The commit to bake is a BUILD ARG (ERPNEXT_MCP_SHA, the full 40-hex SHA the deploy command reads from
# GitHub just before the build). It is what busts this app's cache — and only from here down —
# when erpnext_mcp moves; the clone below must land on exactly that commit or the build fails.
ARG ERPNEXT_MCP_SHA
ARG ERPNEXT_MCP_VERSION=0.18.0

# ── Bake polehntim/erpnext_mcp into the image ─────────────────────
# MCP (Model Context Protocol) server exposed as a Frappe custom
# app. Ships a bearer-token HTTP+SSE endpoint plus two doctypes:
#   * ERPNext MCP Settings (Single) — token, CIDR allowlist, per-
#                                     tool kill switches (mutating
#                                     tools default OFF, read tools
#                                     default ON, master `enabled`
#                                     default OFF — install is inert)
#   * MCP Action Log — append-only audit trail of every call
# The entrypoint's reconcile loop (line ~140) picks this up and
# runs `bench install-app erpnext_mcp` on both fresh sites and
# existing sites — no entrypoint change needed.
#
# After first boot, an operator opens /app/erpnext-mcp-settings,
# generates a token, ticks Enabled, saves. Until then the endpoint
# returns 404. Same two-step install (get-app + explicit pip
# install -e) as sibling apps to guarantee importable at runtime.
#
# Private-repo clone, done so the token never reaches the image:
#   * The token goes to git as an http.extraheader through the
#     GIT_CONFIG_* environment of this one command — NOT in the clone
#     URL, which bench would record in apps/erpnext_mcp/.git/config
#     and logs/bench.log.
#   * Like farm_i9 and farm_precision_ag, a failed get-app or pip
#     install FAILS THE BUILD. The old `|| echo` fallback would quietly ship an image
#     with no erpnext_mcp if the token were missing or expired.
#   * Docs, release notes, the standalone test suite, the changelog
#     and .git are removed IN THE SAME RUN (a later RUN cannot remove
#     files from an earlier layer). The app never reads them at
#     runtime; deploy_status.py takes the commit from the build record
#     above when .git is absent.
#   * The last step fails the build if the token (raw or base64) is
#     found anywhere under apps/erpnext_mcp, sites/ or logs/.
USER frappe
RUN --mount=type=secret,id=gh_token,required=true,uid=1000,mode=0400 \
    set -eu; \
    cd /home/frappe/frappe-bench; \
    echo "${ERPNEXT_MCP_SHA}" | grep -Eqx '[0-9a-f]{40}' || { echo "[dockerfile] pass --build-arg ERPNEXT_MCP_SHA=<the 40-hex commit of erpnext_mcp main> — failing the build" >&2; exit 1; }; \
    echo "[dockerfile] baking erpnext_mcp target ${ERPNEXT_MCP_VERSION} at ${ERPNEXT_MCP_SHA}"; \
    tok="$(cat /run/secrets/gh_token)"; \
    auth="$(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')"; \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${auth}" \
      bench get-app --branch main erpnext_mcp https://github.com/polehntim-commits/erpnext_mcp.git; \
    test -f apps/erpnext_mcp/erpnext_mcp/__init__.py || { echo "[dockerfile] erpnext_mcp get-app left no app at apps/erpnext_mcp — failing the build" >&2; exit 1; }; \
    got="$(git -C apps/erpnext_mcp rev-parse HEAD)"; \
    [ "$got" = "${ERPNEXT_MCP_SHA}" ] || { echo "[dockerfile] erpnext_mcp main is $got, not the ERPNEXT_MCP_SHA ${ERPNEXT_MCP_SHA} this build was asked for (pushed mid-build?) — failing the build" >&2; exit 1; }; \
    printf '{"sha": "%s", "branch": "main"}' "$got" > /tmp/.erpnext_mcp_head.json; \
    rm -rf apps/erpnext_mcp/.git apps/erpnext_mcp/docs apps/erpnext_mcp/RELEASES \
           apps/erpnext_mcp/tests_standalone apps/erpnext_mcp/CHANGELOG.md; \
    env/bin/pip install -e apps/erpnext_mcp --force-reinstall --no-deps; \
    if grep -rqsF -e "$tok" -e "$auth" apps/erpnext_mcp sites logs; then \
      echo "[dockerfile] the GitHub token was found in the image tree — failing the build" >&2; exit 1; \
    fi
# ── Last token check over everything the three private clones touched ──
# Each clone checks its own app; this also covers /tmp (the head
# records) and every git config a clone could have written.
USER root
RUN --mount=type=secret,id=gh_token,required=true \
    set -eu; \
    tok="$(cat /run/secrets/gh_token)"; \
    auth="$(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')"; \
    if grep -rqsF -e "$tok" -e "$auth" /home/frappe/frappe-bench/apps /home/frappe/frappe-bench/sites \
         /home/frappe/frappe-bench/logs /tmp /root /etc/gitconfig /home/frappe/.gitconfig /home/frappe/.config; then \
      echo "[dockerfile] the GitHub token was found in the image — failing the build" >&2; exit 1; \
    fi
USER frappe

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
    (bench build --apps erpnext_mcp,farm_i9,farm_precision_ag --production \
     || echo "[dockerfile] bench build (private apps) failed — will retry in entrypoint")
USER root
RUN if [ -d /home/frappe/frappe-bench/sites/assets ]; then \
        mkdir -p /var/lib/frappe-assets && \
        cp -r /home/frappe/frappe-bench/sites/assets/. /var/lib/frappe-assets/ && \
        chown -R frappe:frappe /var/lib/frappe-assets; \
    fi

# ── farmops-api's log directory (erpnext_mcp v0.18.0) ─────────────
# supervisord writes /home/frappe/frappe-bench/logs/farmops-api.log,
# and supervisord does NOT create a missing parent — it fails the
# program at startup instead, which on a fresh container looks like
# "the mobile API is down" with nothing in `docker logs` to say why.
# The bench normally has this dir, but `sites/` is the only path the
# Umbrel compose bind-mounts, so `logs/` is whatever the image says
# it is. Cheap insurance, one layer, no cache impact on anything above.
RUN mkdir -p /home/frappe/frappe-bench/logs && \
    chown -R frappe:frappe /home/frappe/frappe-bench/logs

# NOTE ON DEPENDENCIES: farmops-api deliberately adds NONE. It runs on
# the bench venv's own gunicorn (the same binary the `backend` program
# uses) and on Werkzeug, which Frappe already depends on. `pip install
# flask` here would resolve against Frappe's pinned Werkzeug inside the
# venv that runs a production ledger; the failure mode of getting that
# wrong is the whole site, not one endpoint.

# Supervisord process definitions + our first-boot entrypoint.
COPY supervisord.conf /etc/supervisor/conf.d/erpnext.conf
# supervisord.conf's websocket program runs nvm's `current` node. Fail the
# build here if the base image stops providing it (see the note there).
RUN test -x /home/frappe/.nvm/current/bin/node && \
    /home/frappe/.nvm/current/bin/node --version
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# DB grant self-heal (v15.1.2). Reconciles each site's MariaDB user to a
# host-independent `user@'%'` grant on every boot, so Docker reassigning
# the container's IP stops producing "Access denied for user 'X'@'<ip>'"
# on every request. Invoked by entrypoint.sh with the BENCH venv
# interpreter — it needs pymysql, which lives in
# /home/frappe/frappe-bench/env, not in the system python3. See the
# module docstring for the full incident write-up.
COPY db_grant_selfheal.py /usr/local/bin/db-grant-selfheal
RUN chmod +x /usr/local/bin/db-grant-selfheal

# Asset floor check (v15.1.2). Shared by entrypoint.sh (boot) and
# asset-watchdog (every 30s at runtime). Validates that assets.json's
# entries actually resolve on disk — the stale-manifest case that the
# old present-and-non-empty canary could not see — and repairs from the
# /var/lib/frappe-assets snapshot. Stdlib only, so it runs under either
# the bench venv interpreter or the system python3.
COPY asset_floor.py /usr/local/bin/asset-floor
RUN chmod +x /usr/local/bin/asset-floor

# ── wkhtmltopdf's fontconfig cache (2026-08-07) ───────────────────
# Every Print → PDF in the Desk goes through wkhtmltopdf, which starts
# by asking fontconfig to build its font cache. fontconfig wants
# /var/cache/fontconfig to be writable; in this image it either does
# not exist or is root-owned, and the Frappe processes run as the
# `frappe` user. fontconfig then dies before a single glyph is laid
# out, and Frappe surfaces it as
#
#     Fontconfig error: No writable cache directories
#
# with an empty or failed PDF. The symptom looks like a broken print
# format — it is not; no template can work around a renderer that
# cannot start, which is why the fix is here and not in the app.
#
# 0777 rather than `chown frappe:frappe` on purpose: the same cache is
# wanted by whatever user each supervisord program happens to run as
# (backend, the queue workers and farmops-api are `frappe`; a `docker
# exec` for a one-off bench command is often root), and a cache
# directory only one of them can write is the same outage for the
# others. Nothing secret is ever written there — it is a font index.
#
# Placed at the very bottom with the other cheap layers so it costs
# nothing against the ~6 GB of app clones and `bench build` above.
RUN mkdir -p /var/cache/fontconfig && \
    chmod 777 /var/cache/fontconfig

# Authoritative self-heal inventory (overrides the same keys set near the top
# of this file). Placed down here so bumping it re-runs only the last few
# cheap layers instead of the whole app-clone + bench-build chain.
LABEL org.polehnfarm.self-heal="asset-floor,healthcheck,app-reconcile,db-grant"
LABEL org.polehnfarm.self-heal.version="2"

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
# base frappe/erpnext image (no apt install needed). Grace
# period of 5 min accommodates cold-boot bench new-site +
# agriculture/farm_i9 install.
#
# v15.1.2 NOTE — deliberately NOT extended to the full asset floor check.
# Running `asset-floor --check-only` here would catch the stale-manifest
# case, but it would also report unhealthy for the entire 5-10 minutes the
# watchdog spends inside `bench build --production`. At 30s × 3 retries
# Umbrel would restart the container mid-build, every time, turning a
# recoverable state into a loop. The floor is covered by the entrypoint
# (boot) and the watchdog (every 30s at runtime); this healthcheck stays a
# liveness probe for nginx, which is what it is good at.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD curl -f -o /dev/null http://127.0.0.1:8080/assets/assets.json || exit 1

# Entrypoint handles first-boot site creation + agriculture install,
# then execs supervisord to run all the Frappe processes.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
