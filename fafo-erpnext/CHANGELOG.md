# Changelog — fafo-erpnext

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
