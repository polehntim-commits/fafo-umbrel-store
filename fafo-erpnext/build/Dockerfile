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
#   * redis      — local, 3 logical DBs (0=cache, 1=queue, 2=socketio)
#   * backend    — Frappe Python via gunicorn on 127.0.0.1:8000
#   * frontend   — nginx on 0.0.0.0:8080 (Umbrel app_proxy target)
#   * websocket  — Node socket.io on 127.0.0.1:9000
#   * queue-short — background worker for short + default queues
#   * queue-long  — background worker for the long queue
#   * scheduler   — cron-like scheduler
#
# MariaDB stays as an external `db` sidecar (persistence, upgrade
# semantics, RAM isolation). Redis stays IN this container because
# it's ephemeral cache — losing it on container restart is fine.
#
# Base image is `frappe/erpnext:v15.115.0` (Frappe Technologies'
# official, has bench + all Python deps preinstalled). We just
# layer supervisord, redis-server, and our config on top.

FROM frappe/erpnext:v15.115.0

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
    sed -i 's|^dir /var/lib/redis|dir /tmp|' /etc/redis/redis.conf

# Supervisord process definitions + our first-boot entrypoint.
COPY supervisord.conf /etc/supervisor/conf.d/erpnext.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Frontend nginx is the only externally-exposed port. Everything
# else (backend gunicorn, websocket, redis) is localhost-only.
EXPOSE 8080

# Sites volume is where Frappe stores common_site_config.json, per-
# site configs, uploaded files, and the .site-created marker.
# Persisting this across container recreates is what keeps the site
# alive between updates.
VOLUME ["/home/frappe/frappe-bench/sites"]

# Entrypoint handles first-boot site creation + agriculture install,
# then execs supervisord to run all the Frappe processes.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
