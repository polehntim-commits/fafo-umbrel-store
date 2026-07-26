#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Boot-time self-healing for Frappe site DB-user grant host drift (v15.1.2).

The problem this fixes
──────────────────────
`bench new-site` creates the site's MariaDB user with a grant pinned to the
*current container IP*::

    CREATE USER '_5e5899d8398b5f7b'@'10.21.0.27' IDENTIFIED BY '…'

Docker hands out container IPs from the bridge pool on a first-come basis, so
any container recreate (an app update, an Umbrel reboot, a compose edit) can
bring the server container up on a different address. The grant no longer
matches the connecting host and *every* request 500s with::

    pymysql.err.OperationalError: (1045, "Access denied for user
    '_5e5899d8398b5f7b'@'10.21.0.24' (using password: YES)")

This is host drift, not password drift — `sites/<site>/site_config.json` still
holds the correct `db_password`. It bit Tim's mom's Umbrel on 2026-07-26 after
the v0.4.0 ERPNext MCP deploy.

Why not `bench`
───────────────
Frappe ships no `bench set-mariadb-user-password` (or equivalent regrant)
command — invoking it errors with "No such command". The repair has to be done
against MariaDB directly.

The fix
───────
On every boot, before supervisord starts serving traffic, walk every site in
`sites/`, read its `db_name` / `db_user` / `db_password` from
`site_config.json`, and reconcile a host-independent grant using the MariaDB
root credentials the compose already supplies (`DB_ROOT_PASS` = `${APP_SEED}`,
the same value that initialized the MariaDB volume)::

    CREATE USER IF NOT EXISTS `user`@'%' IDENTIFIED BY '<db_password>';
    ALTER USER `user`@'%' IDENTIFIED BY '<db_password>';
    GRANT ALL PRIVILEGES ON `db_name`.* TO `user`@'%';
    FLUSH PRIVILEGES;

`@'%'` matches from any address, so the next IP reassignment is a non-event.
The `ALTER USER` covers the case where the user row exists but its password has
drifted from site_config.json (CREATE USER IF NOT EXISTS is a silent no-op
there, so CREATE alone would not be enough).

Written in Python rather than a `mysql` heredoc for three reasons, all of which
bit the shell sketch this replaces:

  1. **Quoting.** Frappe generates alphanumeric passwords *today*, but a
     restored or hand-edited site_config.json can hold anything. pymysql's
     literal escaping is correct for every byte; `'$DB_PASS'` inside a shell
     heredoc breaks on the first apostrophe and silently sets a wrong password.
  2. **Malformed JSON.** A truncated site_config.json makes `json.load` raise a
     catchable error naming the file; the shell version's `2>/dev/null` swallows
     it and `continue`s past a site that genuinely needs attention.
  3. **Error classification.** Bad root credentials (1045) deserve a different,
     louder message than "MariaDB isn't up yet" — and neither should look like
     success. `mysql | grep -v Warning || true` reports success unconditionally.

Design guarantees
─────────────────
  * **Idempotent.** Safe to run on every boot, many times a day. On an already
    healthy site the four statements are no-ops that cost one round trip.
  * **Non-blocking.** Any failure — DB unreachable, wrong root password,
    unparseable config — is logged loudly and this exits non-zero; the
    entrypoint tolerates that and boots anyway. A site with a broken grant
    still beats a container that refuses to start.
  * **Loud.** Every site prints its pre-state (reachable / access-denied) and
    post-state, so `docker logs` shows whether the heal actually did anything.
  * **Secret-safe.** Passwords are never logged, not even truncated. Identifiers
    (db name / user) are logged — they are not secrets.
  * **Fresh-DB safe.** On a brand-new MariaDB volume the sites dir is empty, the
    loop body never runs, and this reports "no sites yet". On a fresh DB *with*
    existing site configs (volume restored out of sync) CREATE + GRANT still
    does the right thing.

Env inputs (all set by the Umbrel docker-compose, see fafo-erpnext/docker-compose.yml):
    DB_HOST       — MariaDB hostname. Default "erpnext-db".
    DB_PORT       — Default 3306.
    DB_ROOT_USER  — Default "root".
    DB_ROOT_PASS  — MariaDB root password (= ${APP_SEED}). Required.
    DB_GRANT_PRUNE_STALE — "1" to DROP the leftover IP-pinned user rows after a
                  successful regrant. Off by default: they are inert, and
                  dropping rows is the one irreversible thing this script could
                  do. Turn it on if mysql.user accumulates noise over many
                  recreates.

Exit codes: 0 = every site reconciled (or nothing to do). 1 = at least one site
failed, or MariaDB/root auth was unusable. The entrypoint ignores the code and
continues booting either way; it exists for humans and for `docker exec` runs.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time

try:
    import pymysql
except ImportError:  # pragma: no cover - only when run outside the bench venv
    sys.stderr.write(
        "[db-selfheal] FATAL: pymysql not importable. Run this with the bench "
        "venv interpreter: /home/frappe/frappe-bench/env/bin/python\n"
    )
    sys.exit(1)

SITES_DIR = os.environ.get("SITES_DIR", "/home/frappe/frappe-bench/sites")

# Directory entries under sites/ that are never Frappe sites.
NOT_A_SITE = {"assets", "logs", "__pycache__"}

# MariaDB identifiers we are willing to interpolate into DDL. Frappe generates
# db names/users as `_<16 hex chars>`; this is deliberately a little wider (the
# legal unquoted-identifier charset) but still refuses anything containing a
# backtick, quote, space, or newline — i.e. anything that could break out of the
# `\`ident\`` quoting below. Identifiers cannot be bound as parameters, so this
# allowlist is the escaping.
IDENT_RE = re.compile(r"^[A-Za-z0-9_$]{1,64}$")

# Host patterns we consider "stale IP pin" candidates for optional pruning:
# a bare IPv4 literal. '%', 'localhost', and hostname grants are left alone.
IPV4_RE = re.compile(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$")


def log(msg: str) -> None:
    print(f"[db-selfheal] {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"[db-selfheal] WARNING: {msg}", flush=True)


def error(msg: str) -> None:
    print(f"[db-selfheal] ERROR: {msg}", flush=True)


def discover_sites(sites_dir: str) -> list[tuple[str, dict]]:
    """Return [(site_name, site_config_dict)] for every readable site.

    Unreadable or malformed configs are reported and skipped — one bad site
    must not stop the others from being healed.
    """
    found: list[tuple[str, dict]] = []
    if not os.path.isdir(sites_dir):
        warn(f"sites dir {sites_dir} does not exist — nothing to reconcile.")
        return found

    for entry in sorted(os.listdir(sites_dir)):
        if entry in NOT_A_SITE or entry.startswith("."):
            continue
        site_path = os.path.join(sites_dir, entry)
        if not os.path.isdir(site_path):
            continue
        cfg_path = os.path.join(site_path, "site_config.json")
        if not os.path.isfile(cfg_path):
            # Plenty of non-site dirs can live here (backups, custom mounts).
            continue
        try:
            with open(cfg_path, "r", encoding="utf-8") as fh:
                cfg = json.load(fh)
        except json.JSONDecodeError as exc:
            error(f"site {entry}: {cfg_path} is not valid JSON ({exc}) — skipping. "
                  f"This site will NOT be healed; fix the file and restart.")
            continue
        except OSError as exc:
            error(f"site {entry}: cannot read {cfg_path} ({exc}) — skipping.")
            continue
        if not isinstance(cfg, dict):
            error(f"site {entry}: {cfg_path} is not a JSON object — skipping.")
            continue
        found.append((entry, cfg))
    return found


def connect_root(host: str, port: int, user: str, password: str,
                 attempts: int = 6, delay: float = 3.0):
    """Open a root connection, retrying while MariaDB finishes coming up.

    Auth failures (1045) are NOT retried — a wrong root password will still be
    wrong in 30 seconds, and retrying just delays the boot.
    """
    last: Exception | None = None
    for i in range(1, attempts + 1):
        try:
            return pymysql.connect(
                host=host, port=port, user=user, password=password,
                connect_timeout=10, read_timeout=30, write_timeout=30,
                autocommit=True, charset="utf8mb4",
            )
        except pymysql.err.OperationalError as exc:
            code = exc.args[0] if exc.args else None
            if code == 1045:
                error(f"root auth rejected by {host}:{port} as user '{user}' "
                      f"(MySQL 1045). DB_ROOT_PASS does not match this MariaDB "
                      f"volume's root password. On Umbrel that value is "
                      f"${{APP_SEED}} — if the db volume was initialized under a "
                      f"different seed, the grants cannot be repaired from here. "
                      f"No sites reconciled.")
                return None
            last = exc
            if i < attempts:
                log(f"MariaDB not ready yet ({exc.args[:1]}); retry {i}/{attempts} in {delay:.0f}s...")
                time.sleep(delay)
        except Exception as exc:  # noqa: BLE001 - report anything unexpected
            last = exc
            if i < attempts:
                log(f"connect attempt {i}/{attempts} failed ({exc.__class__.__name__}: {exc}); retrying in {delay:.0f}s...")
                time.sleep(delay)
    error(f"could not reach MariaDB at {host}:{port} after {attempts} attempts "
          f"({last.__class__.__name__ if last else 'unknown'}: {last}). "
          f"No sites reconciled — the container will still boot, but Frappe "
          f"will fail on its own DB connection too.")
    return None


def probe_site_login(host: str, port: int, user: str, password: str, db: str) -> tuple[bool, str]:
    """Try to log in the way Frappe will. Returns (ok, human-readable reason)."""
    try:
        conn = pymysql.connect(
            host=host, port=port, user=user, password=password, database=db,
            connect_timeout=10, autocommit=True, charset="utf8mb4",
        )
        conn.close()
        return True, "already reachable"
    except pymysql.err.OperationalError as exc:
        code = exc.args[0] if exc.args else None
        detail = exc.args[1] if len(exc.args) > 1 else str(exc)
        if code == 1045:
            # This is the incident signature. Show it verbatim — it names the
            # IP the grant is missing for, which is the whole diagnosis.
            return False, f"ACCESS DENIED (1045): {detail}"
        if code == 1049:
            return False, f"database `{db}` does not exist (1049) — site config points at a DB that was never created"
        return False, f"{code}: {detail}"
    except Exception as exc:  # noqa: BLE001
        return False, f"{exc.__class__.__name__}: {exc}"


def stale_ip_hosts(cur, db_user: str) -> list[str]:
    """Existing grant hosts for db_user that are bare IPv4 literals."""
    cur.execute("SELECT Host FROM mysql.user WHERE User = %s", (db_user,))
    return [row[0] for row in cur.fetchall() if IPV4_RE.match(row[0] or "")]


def reconcile_site(conn, site: str, db_name: str, db_user: str, db_password: str,
                   prune_stale: bool) -> bool:
    """Ensure db_user@'%' exists with db_password and full rights on db_name."""
    with conn.cursor() as cur:
        before = stale_ip_hosts(cur, db_user)
        if before:
            log(f"site {site}: existing IP-pinned grant host(s) for `{db_user}`: "
                f"{', '.join(before)} — these are what break on container recreate.")

        # Identifiers are allowlisted by IDENT_RE (validated by the caller) and
        # backtick-quoted; the password is bound as a parameter so pymysql does
        # the literal escaping. IDENTIFIED BY takes a string literal, which
        # pymysql's %s substitution produces correctly.
        #
        # NOTE the `'%%'` vs `'%'` split below: pymysql only applies %-formatting
        # to the query when `args` is not None. Statements that bind the password
        # must escape the wildcard host as `%%`; the statements with no args must
        # NOT, or the literal `%%` reaches MariaDB and creates a host named `%%`.
        cur.execute(
            f"CREATE USER IF NOT EXISTS `{db_user}`@'%%' IDENTIFIED BY %s",
            (db_password,),
        )
        # CREATE USER IF NOT EXISTS is a no-op when the row already exists, so
        # it will NOT correct a password that has drifted from site_config.json.
        # ALTER USER makes the password authoritative either way.
        cur.execute(
            f"ALTER USER `{db_user}`@'%%' IDENTIFIED BY %s",
            (db_password,),
        )
        cur.execute(
            f"GRANT ALL PRIVILEGES ON `{db_name}`.* TO `{db_user}`@'%'"
        )
        cur.execute("FLUSH PRIVILEGES")

        if prune_stale and before:
            for host in before:
                try:
                    cur.execute(f"DROP USER IF EXISTS `{db_user}`@%s", (host,))
                    log(f"site {site}: pruned stale grant `{db_user}`@'{host}' "
                        f"(DB_GRANT_PRUNE_STALE=1).")
                except Exception as exc:  # noqa: BLE001
                    warn(f"site {site}: could not drop `{db_user}`@'{host}' ({exc}) — "
                         f"harmless, it is inert.")
            cur.execute("FLUSH PRIVILEGES")
    return True


def main() -> int:
    host = os.environ.get("DB_HOST", "erpnext-db")
    try:
        port = int(os.environ.get("DB_PORT", "3306"))
    except ValueError:
        warn(f"DB_PORT={os.environ.get('DB_PORT')!r} is not an integer — using 3306.")
        port = 3306
    root_user = os.environ.get("DB_ROOT_USER", "root")
    root_pass = os.environ.get("DB_ROOT_PASS", "")
    prune_stale = os.environ.get("DB_GRANT_PRUNE_STALE", "") == "1"
    # Bounded on purpose: this runs on the boot path, and compose already
    # gates the server on `depends_on: erpnext-db: condition: service_healthy`,
    # so a genuinely unreachable DB here means something is broken rather than
    # slow. 6 × 3s keeps the worst case (unroutable host, 10s connect timeout
    # each) under ~80s of added boot time before we give up and let supervisord
    # start anyway.
    try:
        attempts = max(1, int(os.environ.get("DB_SELFHEAL_ATTEMPTS", "6")))
    except ValueError:
        attempts = 6

    if not root_pass:
        error("DB_ROOT_PASS is empty — cannot authenticate to MariaDB as root, "
              "so site grants cannot be reconciled. On Umbrel this comes from "
              "${APP_SEED} in docker-compose.yml. Skipping self-heal; boot continues.")
        return 1

    log(f"scanning {SITES_DIR} for sites to reconcile against {host}:{port}"
        + (" [prune-stale ON]" if prune_stale else ""))
    sites = discover_sites(SITES_DIR)
    if not sites:
        log(f"no sites found under {SITES_DIR} — nothing to reconcile "
            f"(normal on first boot, before bench new-site runs).")
        return 0

    log(f"found {len(sites)} site(s): {', '.join(s for s, _ in sites)}")

    conn = connect_root(host, port, root_user, root_pass, attempts=attempts)
    if conn is None:
        return 1

    failures = 0
    healed = 0
    try:
        for site, cfg in sites:
            db_type = str(cfg.get("db_type") or "mariadb").lower()
            if db_type not in ("mariadb", "mysql"):
                log(f"site {site}: db_type={db_type} is not MariaDB — skipping.")
                continue

            db_name = cfg.get("db_name") or ""
            # Frappe uses db_name as the user name; newer configs may carry an
            # explicit db_user. Prefer the explicit one when present.
            db_user = cfg.get("db_user") or db_name
            db_password = cfg.get("db_password") or ""

            if not db_name or not db_password:
                error(f"site {site}: site_config.json is missing "
                      f"{'db_name' if not db_name else 'db_password'} — cannot "
                      f"reconcile this site. Skipping.")
                failures += 1
                continue
            # for/else: the else body runs only if no identifier was rejected.
            for label, ident in (("db_name", db_name), ("db_user", db_user)):
                if not IDENT_RE.match(str(ident)):
                    error(f"site {site}: {label}={ident!r} contains characters "
                          f"outside [A-Za-z0-9_$] — refusing to build DDL from "
                          f"it. Skipping this site.")
                    failures += 1
                    break
            else:
                ok_before, reason = probe_site_login(
                    host, port, str(db_user), str(db_password), str(db_name))
                log(f"site {site}: user `{db_user}` on db `{db_name}` — {reason}")

                try:
                    reconcile_site(conn, site, str(db_name), str(db_user),
                                   str(db_password), prune_stale)
                except Exception as exc:  # noqa: BLE001
                    error(f"site {site}: regrant FAILED ({exc.__class__.__name__}: {exc}). "
                          f"This site may still return 500s. Manual repair:\n"
                          f"    mysql -h {host} -uroot -p'<APP_SEED>' -e \"CREATE USER IF NOT "
                          f"EXISTS \\`{db_user}\\`@'%' IDENTIFIED BY '<db_password from "
                          f"sites/{site}/site_config.json>'; GRANT ALL PRIVILEGES ON "
                          f"\\`{db_name}\\`.* TO \\`{db_user}\\`@'%'; FLUSH PRIVILEGES;\"")
                    failures += 1
                    continue

                ok_after, reason_after = probe_site_login(
                    host, port, str(db_user), str(db_password), str(db_name))
                if ok_after:
                    if ok_before:
                        log(f"site {site}: OK — grant for `{db_user}`@'%' confirmed "
                            f"(was already working; now pinned host-independent).")
                    else:
                        healed += 1
                        log(f"site {site}: HEALED — login now succeeds after "
                            f"regranting `{db_user}`@'%'.")
                else:
                    error(f"site {site}: still cannot log in after regrant — "
                          f"{reason_after}. Frappe will 500 on this site.")
                    failures += 1
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass

    if failures:
        error(f"reconciliation finished with {failures} failure(s), {healed} healed. "
              f"Boot continues — see messages above.")
        return 1
    log(f"reconciliation complete — {len(sites)} site(s) OK, {healed} healed this boot.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
