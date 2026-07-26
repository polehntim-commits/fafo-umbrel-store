# fafo-erpnext

ERPNext v15 + Agriculture + Frappe HR + farm_i9 + farm_precision_ag +
erpnext_mcp, packaged as a single-container Umbrel community app.

- **App ID:** `fafo-erpnext`
- **Port:** 5300
- **Image:** `polehntim/erpnext-umbrel:15`
- **Container:** `fafo-erpnext_server_1`
- **Host data:** `~/umbrel/app-data/fafo-erpnext/` (`sites/` and `db/`)

---

## First-time login

The app creates its Frappe site on first boot (5–10 minutes). It is
created with a single account — `Administrator` — whose password Umbrel
derives from your Umbrel seed.

### Where to find the password

There are four places, and on a healthy install they all show the same
value:

| # | Where | How |
|---|-------|-----|
| 1 | Umbrel dashboard | App tile → **Show credentials** |
| 2 | Container log | `docker logs fafo-erpnext_server_1 \| grep -A6 "FIRST-BOOT CREDENTIALS"` |
| 3 | Host file | `sudo cat ~/umbrel/app-data/fafo-erpnext/sites/.admin-password-initial.txt` |
| 4 | Container env | `docker exec fafo-erpnext_server_1 printenv ADMIN_PASS` |

**If they disagree, #2 wins.** The banner in the container log is printed
by the very same shell invocation that ran
`bench new-site --admin-password …`, so it is the password the site was
actually created with — it cannot drift. #3 is written from the same
variable moments later. #4 reflects the environment the container is
running with *now*, which is normally identical but would diverge if
someone edited `docker-compose.yml` after the site already existed
(changing `ADMIN_PASS` does **not** re-key an existing site). #1 depends
on umbrelOS rendering the manifest correctly.

> **Known bad state, fixed in v15.1.1.** Up to v15.1.0 the manifest used
> `defaultPassword: "$APP_PASSWORD"`. umbreld performs no variable
> substitution inside `umbrel-app.yml`, so some Umbrel builds showed the
> credentials modal containing the literal text `$APP_PASSWORD`. v15.1.1
> switches to `deterministicPassword: true`, which is what every official
> Umbrel app uses and what umbreld actually understands. If your dashboard
> still shows `$APP_PASSWORD`, you are on ≤ v15.1.0 — update the app, or
> just use channel #2/#3/#4 above.

### If none of them yield a working password

Set a new one directly. This works at any time and does not disturb the
rest of the site:

```sh
docker exec -u frappe fafo-erpnext_server_1 \
  bench --site frontend set-admin-password '<new-password>'
```

### What happens on that first login

ERPNext's **Setup Wizard** runs. It collects your region/language/currency
and then your Company details, and it creates *your own named admin user*
from the email and password you type into its account step.

Two things worth knowing:

- The Setup Wizard does **not** change the `Administrator` account's
  password. Frappe's `create_or_update_user` inserts a *new* `User` for
  the email you supply; `Administrator` keeps the boot password
  indefinitely. Change it yourself with `set-admin-password` above (or in
  the UI) once you are in, and delete
  `sites/.admin-password-initial.txt`.
- The wizard is gated on `Installed Application.is_setup_complete` for the
  `frappe` and `erpnext` apps — not on `System Settings.setup_complete`
  (a legacy mirror) and not on any `site_config.json` key. `bench
  new-site` leaves it at 0, and the entrypoint re-asserts 0 on first boot
  as a defensive measure.

---

## Upgrading an existing install

The entrypoint is idempotent and gated on
`sites/.site-created`. On an existing install, an upgrade:

- re-runs the asset canary / snapshot restore,
- reconciles every site's MariaDB user grant to `user@'%'` (v15.1.2 — this is
  what keeps a recreate from 500ing when Docker hands the container a new IP;
  it runs before the app reconcile below, which needs DB access to work),
- reconciles baked-in Frappe apps that aren't installed on the site yet,
- and starts supervisord.

It does **not** re-create the site, reset any password, write
`.admin-password-initial.txt`, print the credentials banner, or touch the
Setup Wizard state. Those are all first-boot-only.

---

## Operations

```sh
# Watch first boot
docker logs -f fafo-erpnext_server_1

# Restart the app (umbrelOS 1.x — scripts/app is deprecated since 1.0)
umbreld client apps.restart.mutate --appId fafo-erpnext

# Which Frappe apps are installed on the site?
docker exec -u frappe fafo-erpnext_server_1 bench --site frontend list-apps

# Shell in
docker exec -it -u frappe fafo-erpnext_server_1 bash
```

Self-healing behaviour (asset canary, healthcheck, app reconcile, asset
watchdog, DB grant reconcile) is documented in the header comment of
[`build/entrypoint.sh`](build/entrypoint.sh).

### "Internal Server Error" on every page after an update

Symptom: every request returns 500. The container log shows

```
pymysql.err.OperationalError: (1045, "Access denied for user
'_5e5899d8398b5f7b'@'10.21.0.24' (using password: YES)")
```

Cause: `bench new-site` pinned the site's MariaDB user to the container's IP
at creation time, and Docker gave the container a different IP when it was
recreated. The password in `sites/frontend/site_config.json` is still correct —
only the grant's *host* is wrong.

**Since v15.1.2 this repairs itself on every boot.** Restart the app and check
the log:

```sh
umbreld client apps.restart.mutate --appId fafo-erpnext
docker logs fafo-erpnext_server_1 | grep db-selfheal
```

A healthy boot prints one `OK` or `HEALED` line per site. If it prints
`ERROR`, the message says exactly what to fix — most often `DB_ROOT_PASS`
(`${APP_SEED}`) not matching the MariaDB volume's root password, which means
the db volume was initialized under a different seed and needs manual repair:

```sh
# Read the site's db_name and db_password, then regrant by hand.
docker exec fafo-erpnext_server_1 cat \
  /home/frappe/frappe-bench/sites/frontend/site_config.json
docker exec -it fafo-erpnext_db_1 mysql -uroot -p
#   CREATE USER IF NOT EXISTS `<db_name>`@'%' IDENTIFIED BY '<db_password>';
#   ALTER  USER            `<db_name>`@'%' IDENTIFIED BY '<db_password>';
#   GRANT ALL PRIVILEGES ON `<db_name>`.* TO `<db_name>`@'%';
#   FLUSH PRIVILEGES;
```

The reconcile can also be run on demand without a restart:

```sh
docker exec fafo-erpnext_server_1 \
  /home/frappe/frappe-bench/env/bin/python /usr/local/bin/db-grant-selfheal
```

Old IP-pinned grant rows are left in place (inert). Set
`DB_GRANT_PRUNE_STALE=1` in the compose environment to have them dropped after
a successful regrant.

---

## Security notes

- `.admin-password-initial.txt` is created mode `0600`, owned by
  `frappe`, on the bind-mounted `sites/` volume. It is generated at
  runtime and is never committed to this repository.
- The `erpnext_mcp` endpoint ships inert. It stays that way until an
  operator opens `/app/erpnext-mcp-settings`, generates a bearer token,
  and ticks **Enabled**. All five mutating MCP tools default to OFF.
