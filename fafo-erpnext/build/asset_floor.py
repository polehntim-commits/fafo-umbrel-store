#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Asset floor check + repair for sites/assets/ (v15.1.2).

The incident this fixes
───────────────────────
2026-07-26, right after the DB-grant outage on the same box: the site loaded
but rendered as raw HTML with no CSS. `sites/assets/` looked populated, the
asset canary was present and non-empty, and every app's directory was there —
so neither the entrypoint canary restore nor the asset-watchdog fired. The
manual unblock was a snapshot copy followed by `bench clear-cache` +
`bench clear-website-cache`.

What actually breaks — the split between image and volume
──────────────────────────────────────────────────────────
Compiled bundles do NOT live in the sites volume. They live in the image, at
`apps/<app>/<app>/public/dist/`, and are reached through per-app SYMLINKS in
the volume::

    sites/assets/erpnext -> /home/frappe/frappe-bench/apps/erpnext/erpnext/public

Frappe v15 content-hashes every bundle filename
(`erpnext.bundle.SLWNYXYQ.css`) and records the mapping in
`sites/assets/assets.json` — which DOES live in the volume, and therefore
survives a container recreate.

So when the image is rebuilt, `bench build` emits new hashes into the new
image's `dist/` dirs, but the bind-mounted volume still holds the PREVIOUS
build's `assets.json`. Every bundle URL in the served HTML then points at a
hash that no longer exists on disk:

    /assets/erpnext/dist/css/erpnext.bundle.SLWNYXYQ.css -> 404

Result: unstyled raw HTML. Verified in a controlled reproduction — all LTR CSS
bundles 404 while the canary, the per-app dirs, and the symlinks are all intact.

Why the existing layers missed it
─────────────────────────────────
  * **Asset canary** (entrypoint + watchdog) tests `assets.json` for
    presence and non-emptiness. A stale manifest is present and non-empty.
  * **Per-app directory check** — `sites/assets/<app>` is a symlink into the
    image, so it resolves fine even when every hash behind it is wrong. It also
    cannot fire for `agriculture`, `farm_i9`, `farm_precision_ag`, or
    `erpnext_mcp`: none of them ship a `public/` or `www/` dir, so they
    correctly have no `sites/assets/` entry and never will.

The check here is therefore about *referential integrity*, not presence: read
the manifest and confirm every path it names actually resolves on disk. That is
the condition that was violated, and it is the one that maps directly to what
the browser experiences.

The floor
─────────
A site passes when all three hold:

  1. `assets.json` exists, is non-empty, and parses as a JSON object.
     (Subsumes the old canary check.)
  2. Every `/assets/...` path it names resolves on disk. On a healthy boot this
     is 46/46 entries. `assets-rtl.json` is checked the same way when present.
  3. Every installed app that ships a `public/` or `www/` dir has its
     `sites/assets/<app>` entry. Apps with no frontend assets are skipped —
     they are *supposed* to be absent.

Repair ladder (cheapest first, each step re-validated)
──────────────────────────────────────────────────────
  1. **Restore from the image snapshot** at `/var/lib/frappe-assets/`. This is
     almost always the right fix and costs a directory copy: the snapshot was
     taken from the same image whose `dist/` dirs the manifest must match, so
     its `assets.json` is by construction the correct one. The snapshot is
     validated BEFORE being trusted — a broken snapshot must not overwrite a
     working tree.
  2. **`bench build --production`**, only if the snapshot is missing or itself
     fails validation. Slow (5-10 min on a Pi), so it is rate-limited via a
     stamp file; the watchdog must never be able to trigger it every 30s.
  3. Give up loudly, leaving the site serving whatever it has.

`cp -a` (clobbering), NOT `cp -n`: the whole point is to overwrite a stale
`assets.json`. A no-clobber copy would leave the broken manifest in place and
silently report success.

Cache invalidation
──────────────────
Frappe caches the parsed manifest in Redis under `assets_json`. A repair does
not take effect until that is dropped — this is why the manual fix needed
`bench clear-cache` + `bench clear-website-cache`. `--clear-cache` does it.

The entrypoint does NOT need it: supervisord has not started Redis yet at that
point, and this image runs Redis with persistence disabled (`save ""`,
`dir /tmp`), so a boot-time repair always comes up against an empty cache.
The watchdog, running mid-lifetime with Redis up, DOES need it.

Usage
─────
    asset_floor.py [--check-only] [--clear-cache] [--reload-nginx]
                   [--build-min-interval SECONDS] [--quiet-when-healthy]

Exit codes: 0 = healthy (or repaired), 1 = still broken after the ladder,
2 = check-only found a problem. Callers treat non-zero as advisory: a site with
degraded assets still boots.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

BENCH = "/home/frappe/frappe-bench"
SITES = os.environ.get("SITES_DIR", f"{BENCH}/sites")
ASSETS = f"{SITES}/assets"
APPS = f"{BENCH}/apps"
SNAPSHOT = os.environ.get("ASSET_SNAPSHOT_DIR", "/var/lib/frappe-assets")
# Stamp file recording the last `bench build` this script triggered, so the
# 30s watchdog loop cannot turn a persistently broken tree into a rebuild
# storm. Lives in /tmp: per-container, deliberately not on the sites volume —
# a fresh container should be allowed one immediate rebuild attempt.
BUILD_STAMP = "/tmp/.asset-floor-last-build"

MANIFESTS = ("assets.json", "assets-rtl.json")


def log(msg: str) -> None:
    print(f"[asset-floor] {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"[asset-floor] WARNING: {msg}", flush=True)


def error(msg: str) -> None:
    print(f"[asset-floor] ERROR: {msg}", flush=True)


def resolve(url: str, assets_root: str) -> str | None:
    """Map an `/assets/...` manifest value to a path under assets_root."""
    if not url.startswith("/assets/"):
        return None
    return os.path.join(assets_root, url[len("/assets/"):])


def check_manifest(assets_root: str, name: str) -> tuple[bool, str, int, int]:
    """Validate one manifest. Returns (ok, reason, n_entries, n_missing)."""
    path = os.path.join(assets_root, name)
    if not os.path.exists(path):
        # assets-rtl.json is optional; assets.json is not. The caller decides.
        return False, f"{name} is missing", 0, 0
    if os.path.getsize(path) == 0:
        return False, f"{name} is zero-byte", 0, 0
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as exc:
        return False, f"{name} is not valid JSON ({exc})", 0, 0
    except OSError as exc:
        return False, f"{name} is unreadable ({exc})", 0, 0
    if not isinstance(data, dict) or not data:
        return False, f"{name} is not a non-empty JSON object", 0, 0

    missing = []
    for key, url in data.items():
        if not isinstance(url, str):
            continue
        target = resolve(url, assets_root)
        if target is None:
            continue
        if not os.path.exists(target):
            missing.append((key, url))

    if missing:
        shown = ", ".join(f"{k} -> {u}" for k, u in missing[:3])
        more = f" (+{len(missing) - 3} more)" if len(missing) > 3 else ""
        return (False,
                f"{name}: {len(missing)}/{len(data)} entries point at files "
                f"that do not exist — {shown}{more}",
                len(data), len(missing))
    return True, f"{name}: {len(data)}/{len(data)} entries resolve", len(data), 0


def apps_with_frontend_assets() -> list[str]:
    """Apps that ship a public/ or www/ dir, i.e. that bench build emits for.

    Apps without either (agriculture, farm_i9, farm_precision_ag, erpnext_mcp
    as of this writing) are SUPPOSED to have no sites/assets/ entry — flagging
    them would be a permanent false positive.
    """
    found = []
    if not os.path.isdir(APPS):
        return found
    for app in sorted(os.listdir(APPS)):
        mod = os.path.join(APPS, app, app)
        if os.path.isdir(os.path.join(mod, "public")) or \
           os.path.isdir(os.path.join(mod, "www")):
            found.append(app)
    return found


def check_floor(assets_root: str = ASSETS) -> tuple[bool, list[str]]:
    """Full floor check. Returns (healthy, [human-readable problems])."""
    problems: list[str] = []

    if not os.path.isdir(assets_root):
        return False, [f"{assets_root} does not exist"]

    ok, reason, _, _ = check_manifest(assets_root, "assets.json")
    if not ok:
        problems.append(reason)

    # RTL manifest is optional — only complain if it exists and is broken.
    if os.path.exists(os.path.join(assets_root, "assets-rtl.json")):
        ok_rtl, reason_rtl, _, _ = check_manifest(assets_root, "assets-rtl.json")
        if not ok_rtl:
            problems.append(reason_rtl)

    for app in apps_with_frontend_assets():
        entry = os.path.join(assets_root, app)
        # os.path.isdir follows symlinks, which is what we want: the entry is
        # a symlink into the image and must resolve to a real directory.
        if not os.path.isdir(entry):
            problems.append(
                f"app `{app}` ships frontend assets but has no resolvable "
                f"{assets_root}/{app} entry")

    return (not problems), problems


def snapshot_is_trustworthy() -> bool:
    """Validate the snapshot before letting it overwrite the live tree."""
    if not os.path.isdir(SNAPSHOT):
        warn(f"no snapshot at {SNAPSHOT} — cannot restore from image.")
        return False
    ok, reason, n, _ = check_manifest(SNAPSHOT, "assets.json")
    if not ok:
        warn(f"snapshot at {SNAPSHOT} fails its own manifest check ({reason}) "
             f"— refusing to copy it over the live tree.")
        return False
    log(f"snapshot at {SNAPSHOT} validates ({reason}).")
    return True


def restore_from_snapshot() -> bool:
    """`cp -a snapshot/. assets/` — CLOBBERING, which is the point.

    Shelling out to cp rather than using shutil.copytree, which cannot do
    this job: with dirs_exist_ok=True and symlinks=True it raises
    FileExistsError on every per-app symlink that already exists
    (`sites/assets/erpnext` -> apps/erpnext/erpnext/public), because it
    calls os.symlink without unlinking first. Measured: the restore aborted
    on all three symlinks and fell through to a full `bench build` — turning
    a two-second repair into a five-to-ten-minute one on a Pi.

    `cp -a` replaces existing symlinks correctly, preserves them as symlinks
    rather than dereferencing into copies, and is the same command the
    original entrypoint restore and the manual 2026-07-26 fix both used.
    Trailing `/.` copies the CONTENTS of the snapshot into assets/ rather
    than nesting a `frappe-assets/` dir inside it.
    """
    try:
        os.makedirs(ASSETS, exist_ok=True)
        proc = subprocess.run(["cp", "-a", f"{SNAPSHOT}/.", f"{ASSETS}/"],
                              capture_output=True, text=True, timeout=600)
    except Exception as exc:  # noqa: BLE001
        error(f"snapshot restore could not be started ({exc.__class__.__name__}: {exc}).")
        return False
    if proc.returncode != 0:
        error(f"snapshot restore failed (cp exited {proc.returncode}): "
              f"{(proc.stderr or '').strip()[:400]}")
        return False
    chown_assets()
    log("restored sites/assets/ from image snapshot.")
    return True


def refresh_snapshot() -> None:
    """Re-take the image snapshot from a freshly validated assets tree.

    Best-effort and non-fatal: if it fails, the only cost is that the next
    repair falls back to another `bench build` instead of a two-second copy.
    """
    try:
        os.makedirs(SNAPSHOT, exist_ok=True)
        proc = subprocess.run(["cp", "-a", f"{ASSETS}/.", f"{SNAPSHOT}/"],
                              capture_output=True, text=True, timeout=600)
        if proc.returncode == 0:
            log(f"refreshed {SNAPSHOT} from the rebuilt tree — the next repair "
                f"can use the fast snapshot path again.")
        else:
            warn(f"could not refresh {SNAPSHOT} (cp exited {proc.returncode}) — "
                 f"harmless, but the next repair will need another bench build.")
    except Exception as exc:  # noqa: BLE001
        warn(f"could not refresh {SNAPSHOT} ({exc}) — harmless, but the next "
             f"repair will need another bench build.")


def chown_assets() -> None:
    try:
        subprocess.run(["chown", "-R", "frappe:frappe", ASSETS],
                       check=False, capture_output=True)
    except Exception as exc:  # noqa: BLE001
        warn(f"chown of {ASSETS} failed ({exc}) — nginx may still serve fine.")


def build_rate_limited(min_interval: int) -> bool:
    """True if a `bench build` is allowed right now."""
    try:
        last = os.path.getmtime(BUILD_STAMP)
    except OSError:
        return True
    age = time.time() - last
    if age < min_interval:
        warn(f"skipping `bench build` — last one was {int(age)}s ago and the "
             f"minimum interval is {min_interval}s. Assets stay degraded "
             f"rather than rebuilding in a loop.")
        return False
    return True


def bench_build(min_interval: int) -> bool:
    if not build_rate_limited(min_interval):
        return False
    log("running `bench build --production` (this is slow — 5-10 min on a Pi)...")
    try:
        with open(BUILD_STAMP, "w") as fh:
            fh.write(str(int(time.time())))
    except OSError:
        pass
    try:
        proc = subprocess.run(
            ["su", "frappe", "-s", "/bin/bash", "-c",
             f"cd {BENCH} && bench build --production"],
            capture_output=True, text=True, timeout=1800,
        )
    except subprocess.TimeoutExpired:
        error("`bench build --production` timed out after 30 min.")
        return False
    except Exception as exc:  # noqa: BLE001
        error(f"`bench build --production` could not be started ({exc}).")
        return False
    tail = (proc.stdout or "").strip().splitlines()[-10:]
    for line in tail:
        log(f"  build| {line}")
    if proc.returncode != 0:
        # Reported, but NOT treated as decisive. Observed in testing:
        # `bench build --production` exited 1 (a translation-compile
        # complaint) while still emitting a complete, correct asset tree.
        # The caller re-runs check_floor() either way and believes that
        # instead — the tree on disk is the thing that matters, not the
        # exit status of the tool that wrote it.
        err = (proc.stderr or "").strip().splitlines()[-5:]
        for line in err:
            warn(f"  build| {line}")
        warn(f"`bench build --production` exited {proc.returncode} — "
             f"re-checking the floor anyway, since a non-zero exit here does "
             f"not reliably mean the assets are bad.")
    else:
        log("`bench build --production` completed.")
    chown_assets()
    return True


def clear_frappe_cache() -> None:
    """Drop Frappe's cached copy of the manifest so a repair takes effect.

    Without this the workers keep serving the old, now-wrong bundle URLs from
    Redis until the key expires — the reason the manual repair needed
    `bench clear-cache` + `bench clear-website-cache`.
    """
    site = os.environ.get("SITE_NAME", "frontend")
    for cmd in ("clear-cache", "clear-website-cache"):
        try:
            proc = subprocess.run(
                ["su", "frappe", "-s", "/bin/bash", "-c",
                 f"cd {BENCH} && bench --site {site} {cmd}"],
                capture_output=True, text=True, timeout=180,
            )
            if proc.returncode == 0:
                log(f"bench --site {site} {cmd}: ok")
            else:
                warn(f"bench --site {site} {cmd} exited {proc.returncode} — "
                     f"workers may serve stale bundle URLs until restart.")
        except Exception as exc:  # noqa: BLE001
            warn(f"bench --site {site} {cmd} failed ({exc}).")


def reload_nginx() -> None:
    """Restart nginx so it re-opens FDs on the freshly restored files."""
    try:
        proc = subprocess.run(["supervisorctl", "restart", "frontend"],
                              capture_output=True, text=True, timeout=120)
        if proc.returncode == 0:
            log("nginx (frontend) restarted.")
        else:
            warn("supervisorctl restart frontend failed — nginx may 404 on "
                 "hashed bundles until the container is restarted.")
    except Exception as exc:  # noqa: BLE001
        warn(f"supervisorctl restart frontend failed ({exc}).")


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--check-only", action="store_true",
                    help="report only; never modify sites/assets/")
    ap.add_argument("--clear-cache", action="store_true",
                    help="run bench clear-cache + clear-website-cache after a repair")
    ap.add_argument("--reload-nginx", action="store_true",
                    help="supervisorctl restart frontend after a repair")
    ap.add_argument("--build-min-interval", type=int, default=3600,
                    help="minimum seconds between bench build attempts (default 3600)")
    ap.add_argument("--quiet-when-healthy", action="store_true",
                    help="print nothing when the floor passes (for the 30s watchdog loop)")
    args = ap.parse_args()

    healthy, problems = check_floor()

    if healthy:
        if not args.quiet_when_healthy:
            ok, reason, n, _ = check_manifest(ASSETS, "assets.json")
            log(f"floor OK — {reason}; "
                f"apps with frontend assets: {', '.join(apps_with_frontend_assets()) or 'none'}.")
        return 0

    error("asset floor FAILED:")
    for p in problems:
        error(f"  - {p}")

    if args.check_only:
        return 2

    # ── Ladder step 1: snapshot restore (cheap, almost always correct) ──
    repaired = False
    if snapshot_is_trustworthy() and restore_from_snapshot():
        healthy, problems = check_floor()
        if healthy:
            log("floor restored from image snapshot.")
            repaired = True
        else:
            warn("snapshot restore did not satisfy the floor:")
            for p in problems:
                warn(f"  - {p}")

    # ── Ladder step 2: full rebuild (slow, rate-limited) ──
    if not repaired:
        if bench_build(args.build_min_interval):
            healthy, problems = check_floor()
            if healthy:
                log("floor restored by bench build.")
                repaired = True
                # A runtime build emits NEW hashes into apps/*/public/dist,
                # which leaves the image snapshot describing files that no
                # longer exist — so the next break would fail the snapshot
                # check and force another 5-10 minute rebuild. Re-snapshot
                # now that the tree is verified good, keeping the cheap path
                # available for the rest of this container's life. Only ever
                # runs AFTER check_floor() passed, so a bad build cannot
                # poison the fallback. /var/lib/frappe-assets is an image
                # layer, so a container recreate restores the pristine one.
                refresh_snapshot()
            else:
                error("bench build completed but the floor still fails:")
                for p in problems:
                    error(f"  - {p}")

    if repaired:
        if args.clear_cache:
            clear_frappe_cache()
        if args.reload_nginx:
            reload_nginx()
        return 0

    error("asset floor could NOT be repaired. The site will render unstyled "
          "until this is resolved. Manual repair:\n"
          f"    docker exec fafo-erpnext_server_1 cp -a {SNAPSHOT}/. {ASSETS}/\n"
          f"    docker exec fafo-erpnext_server_1 chown -R frappe:frappe {ASSETS}\n"
          "    docker exec -u frappe fafo-erpnext_server_1 bash -c \\\n"
          "        'cd /home/frappe/frappe-bench && bench --site frontend clear-cache "
          "&& bench --site frontend clear-website-cache'")
    return 1


if __name__ == "__main__":
    sys.exit(main())
