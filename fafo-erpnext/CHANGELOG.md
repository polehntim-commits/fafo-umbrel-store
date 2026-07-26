# Changelog — fafo-erpnext

## 15.1.2

Boot-time self-healing for MariaDB grant host drift. No schema change, no
data migration — this only repairs permissions. Existing sites pick the fix
up on their next container restart.

### Fixed

- **Every request returned Internal Server Error 500 after a container
  recreate.** Hit a production Umbrel on 2026-07-26, right after the v0.4.0
  ERPNext MCP deploy. The Frappe log showed:

  ```
  pymysql.err.OperationalError: (1045, "Access denied for user
  '_5e5899d8398b5f7b'@'10.21.0.24' (using password: YES)")
  ```

  This is **host** drift, not password drift — `sites/frontend/site_config.json`
  still held the correct `db_password`. `bench new-site` creates the site's
  MariaDB user pinned to whatever IP the server container happened to have at
  creation time (`'_5e5899d8398b5f7b'@'10.21.0.27'`). Docker allocates bridge
  IPs on a first-come basis, so any recreate — an app update, an Umbrel reboot,
  a compose edit — can bring the container up on a different address, and from
  that moment no grant matches the connecting host.

  Frappe ships no repair command for this; `bench set-mariadb-user-password`
  does not exist ("No such command"). The manual unblock was a hand-written
  `CREATE USER … @'%'` over `docker exec`, which had to be repeated after every
  recreate.

### Added

- **DB grant self-heal — defense layer 5.** New
  `build/db_grant_selfheal.py`, baked in as `/usr/local/bin/db-grant-selfheal`
  and invoked by `entrypoint.sh` on **every** boot, after MariaDB is up and
  before supervisord starts serving traffic. For each site under `sites/` it
  reads `db_name` / `db_user` / `db_password` from `site_config.json` and
  reconciles a host-independent grant using the root credentials compose
  already supplies (`DB_ROOT_PASS` = `${APP_SEED}`):

  ```sql
  CREATE USER IF NOT EXISTS `user`@'%' IDENTIFIED BY '<db_password>';
  ALTER  USER            `user`@'%' IDENTIFIED BY '<db_password>';
  GRANT ALL PRIVILEGES ON `db_name`.* TO `user`@'%';
  FLUSH PRIVILEGES;
  ```

  `@'%'` matches from any address, so the next IP reassignment is a non-event.
  The `ALTER USER` is not redundant: `CREATE USER IF NOT EXISTS` is a silent
  no-op when the row already exists, so it alone would not correct a password
  that has drifted away from `site_config.json`.

  It runs deliberately **before** the `.site-created` marker fast-path, since
  the drift only affects sites that already exist — on the first-boot path it
  would never fire for the case it was written for. First boot also gets a
  second pass right after `bench new-site`, so a brand-new site is pinned
  host-independent immediately rather than one restart later.

- **Per-site before/after login probe in the log.** The helper connects the way
  Frappe will, both before and after the regrant, and prints
  `already reachable` / `ACCESS DENIED (1045): …` / `HEALED` / `OK` per site —
  so `docker logs fafo-erpnext_server_1` shows whether anything was actually
  repaired rather than just that the code ran. Existing IP-pinned grant hosts
  are named explicitly when found.

- **`DB_GRANT_PRUNE_STALE=1`** (opt-in, off by default) drops the leftover
  IP-pinned user rows after a successful regrant. Off by default because those
  rows are inert and dropping them is the only irreversible thing the script
  could do; turn it on if `mysql.user` accumulates noise over many recreates.

- **`DB_SELFHEAL_ATTEMPTS`** (default 6) bounds the root-connection retry loop.
  Worst case adds ~80s to boot when the DB is genuinely unreachable, after
  which boot continues regardless.

### Notes on failure behavior

Every failure path is **loud and non-fatal** — the container always reaches
supervisord. A site with a broken grant still beats a container that will not
start.

- DB unreachable → retries `DB_SELFHEAL_ATTEMPTS` times, then logs the
  connection error and skips reconciliation.
- Wrong `DB_ROOT_PASS` → MySQL 1045 is reported immediately and **not**
  retried (it will not become right in 30s), naming `${APP_SEED}` as the
  source.
- Empty `DB_ROOT_PASS` → refuses to run, with the reason.
- Malformed `site_config.json` → names the file and the parse error, skips
  that site, and still heals the others.
- `db_name` / `db_user` outside `[A-Za-z0-9_$]` → refused rather than
  interpolated into DDL.
- Site whose database was never created → reported as MySQL 1049 after the
  regrant, since that is a genuinely broken state a human must resolve.

Written in Python against `pymysql` (already in the bench venv) rather than a
`mysql` heredoc so that passwords containing quotes or shell metacharacters are
escaped correctly, JSON parse errors are catchable and named, and 1045 can be
distinguished from "not up yet" — none of which a
`mysql … | grep -v Warning || true` pipeline can do.

## 15.1.1

First-boot credentials UX. No functional change to an existing site.

### Fixed

- **Umbrel credentials modal showed the literal string `$APP_PASSWORD`.**
  `umbrel-app.yml` used `defaultPassword: "$APP_PASSWORD"`, but umbreld
  does no variable substitution inside `umbrel-app.yml` — its manifest
  schema types that field as a plain optional string, so whatever is
  written there is displayed verbatim. `${APP_PASSWORD}` is only
  substituted in `docker-compose.yml`. Replaced with
  `deterministicPassword: true`, the field umbreld actually acts on: it
  derives and displays
  `HMAC-SHA256(<umbrel-seed>, "app-fafo-erpnext-seed-APP_PASSWORD")`,
  which is bit-for-bit the value `${APP_PASSWORD}` resolves to in our
  compose file and therefore exactly what lands in `ADMIN_PASS`. This is
  the mechanism every official Umbrel app with a login uses (pi-hole,
  nextcloud, photoprism, code-server, lndg, passky-server), supported
  since umbrelOS 0.4.8.

### Added

- **Credentials banner in the container log.** At the end of first boot
  the entrypoint prints a framed block with the URL, `Administrator`, and
  the actual password, plus recovery instructions. Visible forever via
  `docker logs fafo-erpnext_server_1`. This is the authoritative channel —
  it is emitted by the same shell invocation that ran
  `bench new-site --admin-password`, so it cannot drift from reality.
- **`sites/.admin-password-initial.txt`.** Fallback copy of the initial
  password, created mode `0600` (via `umask 077` in a subshell, so the
  file is never even momentarily world-readable) and owned by `frappe`.
  On the Umbrel host: `~/umbrel/app-data/fafo-erpnext/sites/`. Generated
  at runtime only; never committed to this repository.
- **Defensive Setup Wizard reset on first boot.** Clears
  `Installed Application.is_setup_complete` for `frappe` and `erpnext`
  (the flag Frappe v15's `frappe.is_setup_complete()` actually reads) plus
  the legacy `System Settings.setup_complete` mirror. `bench new-site`
  already leaves these at 0, so on a normal boot this is a no-op — it
  guards against a future bench/app release changing that default. Both
  writes soft-fail with a warning.

  Note: the prompt-suggested `bench set-config setup_complete 0` would
  have had no effect — there is no such `site_config.json` key in v15.
- **`fafo-erpnext/README.md`** with a "First-time login" section covering
  all four password channels, which one is authoritative and why, the
  `bench set-admin-password` fallback, and what the Setup Wizard does and
  does not do.
- **`fafo-erpnext/CHANGELOG.md`** (this file).
- SPDX-License-Identifier header on `build/entrypoint.sh`.

### Notes

- Every new entrypoint step is gated behind the existing
  `sites/.site-created` marker check. Upgrading an existing install does
  not re-create the site, reset a password, write the password file,
  print the banner, or touch Setup Wizard state.
- The ERPNext Setup Wizard's account step creates a *new* named `User`
  from the email/password entered; it does **not** re-key `Administrator`.
  `Administrator` keeps the boot password until changed explicitly. This
  is Frappe upstream behaviour, now documented in the README.

## 15.1.0

- Renamed the MariaDB sidecar `db` → `erpnext-db` to stop the network
  alias collision with `bankbridge-db` / `bucketlog-db` on the shared
  Umbrel Docker network. Host bind-mount path `${APP_DATA_DIR}/db` kept,
  so existing data survives the rename in place.
- `DB_HOST` now uses service-name DNS (`erpnext-db`) instead of the
  fully-qualified container name.
- Baked `polehntim/erpnext_mcp` v0.1.0 into the image; MCP endpoint ships
  inert until a bearer token is generated at `/app/erpnext-mcp-settings`.
- `PROXY_AUTH_ADD: "false"` on `app_proxy`.
