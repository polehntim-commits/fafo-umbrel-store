# erp-backup — encrypted ERPNext backups with automated restore tests

`erp-backup-kit.sh` installs a small set of scripts and systemd timers on two boxes that each run the
`fafo-erpnext` app. One box is the **primary** (the farm's live ERPNext). The other is the
**secondary**: it holds the primary's copies, restores them every night, and can take over if needed.
Either box can also back itself up to the other.

Nothing in this directory is specific to one farm. Box names, hosts and paths are set when the kit is
installed and live only in `<root>/erp-backup/erp-backup.conf` on each box. No secrets are stored
anywhere:

- Archives are encrypted to a public **age** key. The private key stays off both boxes.
- The MariaDB root password is read from the database container at run time and held in memory only.
- Second-target credentials, if used, are created on the box by `rclone config`.

## What runs, and when (UTC, defaults)

| Timer | Primary | Secondary | What it does |
|---|---|---|---|
| `erp-backup` | 02:30 | 03:00 | `bench backup --with-files` → verify → age-encrypt → `own/daily`. Hard-links a weekly (day `WEEKLY_DOW`) and a monthly (first of the month) copy. Prunes to 14 / 8 / 12. Then `push.sh`. |
| `erp-standby` | — | 05:30 | Loads the newest **complete** standby set from the primary into the read-only `standby-<peer>` site. Waits up to `STANDBY_WAIT_MIN` for a set still in transit. Then verifies it, writes a receipt and sends it back. |
| `erp-recv-check` | 07:30 | 07:00 | Prunes what the peer sent and proves the newest complete set is fresh and intact. This is the dead-man switch. |
| `erp-offsite` | 04:30 | 04:30 | Optional. Copies **encrypted** archives to a second target: a mounted share or disk, or any rclone remote such as SMB, S3 or B2. |
| `erp-scrub` | Sun 08:30 | Sun 08:30 | Re-verifies the checksums of **every** stored set, own and peer. |
| `erp-progress` | every 2 min | every 2 min | While a job runs or a set is arriving: refreshes `status.json` so ERPNext shows live progress. Resumes a **failed** push after 60 min (`PUSH_RESUME_AFTER_MIN`; at most 6 times a day; never alongside another push) through the on-demand `erp-push.service`. |
| `erp-watchdog` | 07:45 | 07:15 | Re-installs timers that went missing, and checks ERPNext can see the status. Sends **one** notification when something is wrong (and once when it recovers). |

## How a restore is verified

The nightly standby restore is a full `bench restore` into a read-only site. Its result is **Pass** only
if all of these hold:

- **Row counts** of GL Entry, Journal Entry, Sales Invoice, Purchase Invoice, Payment Entry, Employee and
  File match the source within 0–5. The counts are taken just before the dump.
- **Files** match by name: none missing.
- Every stored **secret** decrypts with the copied encryption key.
- **Sanity**, compared with the source's `SANITY.txt`:
  - the company count matches;
  - enabled users within ±2;
  - accounts within 0–5;
  - GL debits minus credits per company is zero, or unchanged from the source;
  - the latest GL posting date is not older than the source's.

Anything else is **Partial**, or **Fail** if the job itself failed. The receipt carries the details back
to the primary. The primary's ERPNext then shows them through `get_backup_status` and files them on the
Backup Record.

`archive-test.sh` is the other half. It proves the **encrypted** archive is useless without the key and
restorable with it. It needs the private key pasted in by a person, so it stays manual and is
reminded by `ARCHIVE_TEST_DUE`.

## What goes over the wire, and how fast

- **Encrypted sets** go whole every night: about the size of the backup. They have new names each night, and
  age uses a fresh random key per file, so identical data never encrypts to the same bytes. No rsync option
  (`--partial`, `--inplace`, `--no-whole-file`) can turn that into a delta.
- **The plaintext standby set** goes as a delta (`DELTA_STANDBY=1`, the default):
  - The receiver keeps the set it last restored as `standby/.basis`, costing one extra set of disk.
  - The sender runs `rsync -yy --copy-dest=/standby/.basis --mkpath`. rrsync anchors the leading `/` at the
    jail and refuses `..`.
  - Files are matched by similar name, and only changed blocks travel: mostly new photos, plus the
    gzip'd database dump.
  - If the peer refuses those options, the push falls back to a full send by itself.
- Each push records `bytes_sent`, `duration_s` and `rate_kbps`, in its state and in the status file that
  goes to the peer.
- `link-test.sh` and the daily watchdog read the path from the Tailscale container (`tailscale status --json`,
  `tailscale ping`):
  - **direct**, with its endpoint, or **DERP**, with the relay region;
  - whether tailscaled runs with userspace networking.
- `LINK_RELAYED` means the push runs through a DERP relay, which typically gives about 1 Mbit/s.
  `LINK_SLOW` means the last push of more than 50 MB ran under `LINK_MIN_RATE_KBPS`. Userspace networking
  costs CPU, but it is rarely what limits a push below a few Mbit/s.

## Installing over a running kit

From 2026-10-19.3 the installer:

- writes every script to a staging directory and renames it into `bin/`, so a running script keeps its file;
- waits while any `erp-*` job runs (`--no-wait` refuses instead; `--force` installs anyway);
- pauses the timers while it writes, and re-arms them afterwards.

Earlier kits overwrote scripts in place. bash reads a script as it runs, so a push running during an
install died mid-line ("syntax error near unexpected token") on 2026-10-19.

## Sets are complete only when their marker arrives

Each transfer is two passes:

1. every file except the set's marker;
2. the marker: `SHA256SUMS` for encrypted archives, `MANIFEST.sha256` for the plaintext standby set.

Receivers only use sets that have their marker, and only after checking it. A set cut off mid-transfer
is skipped and reported:

- `STANDBY_SET_INCOMPLETE` / `PEER_SET_INCOMPLETE` are raised for it.
- A plaintext set that never completes is removed after 36 h.

Before kit 2026-10-19.1, receivers took the newest folder by name. A push interrupted on 2026-10-17
left a half-copied set there, and the next restore failed on it.

## One push at a time

A push can take hours over the tailnet; the nightly one is often still running in the early morning.

- Every push holds `<root>/erp-backup/.push.lock`. Pushes from kits older than 2026-10-19.2 hold no lock,
  so a running push is also recognised by its process: `push.sh`, or rsync to the peer.
- A second push started meanwhile (`run-now.sh`, a manual `push.sh`) **waits** instead of failing:
  - It says so at once and then every 5 minutes, with how long the other push has run and how much it
    has read.
  - It gives up after `PUSH_WAIT_MIN` (default 300).
- The peer's rrsync refusing with "Another instance of rrsync is already accessing this directory" is
  treated the same way: waited out, not counted as one of the three attempts.
- `backup.sh` also waits before replacing the outgoing plaintext standby set, so it never deletes the set
  a running push is sending. Kit 2026-10-19.1 did, once, on 2026-10-19.

`push.sh` on its own is always safe to re-run:

- it never deletes anything on the peer;
- it re-sends whatever the peer is missing;
- it keeps the outgoing standby set until a push of it succeeds.

`run-now.sh --push-only` is the same, plus the summary.

## Watching a backup as it runs

`sudo bash bin/progress.sh --watch` (default refresh 10 s; `--json` for machines). It shows:

- **NOW**: the job running on this box, with phase, step, set, bytes done of total, %, rate, ETA, and since
  when. The phases are backup, push, restore test, offsite, scrub, staged upgrade. The steps:
  - backup: bench backup → copy out → verify → encrypt
  - push: notice → archives → markers → standby set → manifest
  - restore test: waiting for the push → copy in → bench restore → checks
- **LAST**: the last finished job.
- On a receiving box, **PEER / IN**: what the sender announced, and each set still arriving, sized on disk
  against that.

How it works:

- Pushes feed `rsync --info=progress2 --stats` into `bin/progress.py`. Those flags are client-side only,
  so the peer's rrsync never sees them.
- Encryption is sampled from the bytes written so far.
- Steps with no byte counter (bench backup, bench restore) estimate from the last run's duration, marked
  "(est.)".
- The same data goes into `status.json` under `progress`, refreshed at most once a minute while a job runs.
  The 2-minute `erp-progress` timer refreshes it while a set is arriving.

The nightly runs are also in the journal:

- `journalctl -u erp-backup.service -f` (backup + push)
- `journalctl -u erp-standby.service -f` (restore test)
- `journalctl -u erp-push.service -f` (a push resumed after a failure)

A manual `run-now.sh` prints to its terminal instead.

## Every restore run says how it ended

From 2026-10-19.4, every run of `standby-refresh.sh` writes one `status.log` line and `state/standby_run.env`, and
`status.sh` shows the last one. The possible outcomes:

- `restored` (with the check result)
- `already-current`
- `no-new-set`
- `waiting-for-peer`: the peer's shared status names a newer backup that has not arrived complete. The message
  says which, and how the peer's last push went. It raises `STANDBY_WAITING_FOR_PEER`.
- `deferred`
- `not-due`
- `failed`

When a complete set lands after a run gave up (no-new-set / waiting-for-peer / deferred / failed), the 2-minute
`erp-progress` tick starts a **catch-up restore** through the on-demand `erp-standby-now.service`, at most
`STANDBY_CATCHUP_MAX_PER_DAY` (4) a day.

Earlier kits exited 0 with only a journal line when nothing new had arrived. That is how a standby box's 05:32 run
on 2026-10-19 "succeeded" without a trace while the 0403 set was still on its way.

The restore timer runs at `STANDBY_AT`. `STANDBY_TIME` (older kits) was never read for that, and the installer
now comments it out.

## Status, alerts, notifications

`report.sh` writes `status.json` (schema `erp-backup-status/1`, additive) and copies it into the ERPNext
container at `sites/erp_backup_status/<box>.json`. ERPNext's `get_backup_status` reads it there and
recomputes the age-based alerts, so a stale file can't hide a problem.

Each box also sends its status to the peer along with its receipts. With `PEER_STATUS_TO_CONTAINER=1`,
the peer's file is copied into this box's ERPNext as well. That lets either site notice when the other
goes silent.

**Before turning that on, set the `backup_box` Farm Feature Flag on that site.** With two files present
and no flag, ingest writes nothing.

Alert codes the kit raises:

- From the `erp-backup-status/1` set:
  - `BACKUP_FAILED`, `BACKUP_STALE`, `BACKUP_UNENCRYPTED`, `PUSH_STALE_OR_FAILED`
  - `NO_REMOTE_RESTORE`, `REMOTE_RESTORE_STALE`, `REMOTE_RESTORE_NOT_PASS`
  - `PEER_COPIES_BAD`, `STANDBY_FAILED`, `STANDBY_STALE`, `STANDBY_CHECK_NOT_PASS`, `STANDBY_DEFERRED`
  - `ARCHIVE_TEST_DUE`, `PROMOTED`, `FENCED`
- New in kit 2026-10-19.1:
  - `OFFSITE_FAILED`, `OFFSITE_STALE`
  - `SCRUB_FAILED`, `SCRUB_STALE`
  - `TIMERS_MISSING`, `STATUS_NOT_IN_CONTAINER`
  - `STANDBY_SET_INCOMPLETE`, `PEER_SET_INCOMPLETE`

`NOTIFY_URL` is optional. From 2026-10-19.4 the 2-minute tick checks as well as the daily watchdog, so a new problem goes out within minutes. Nothing counts as announced while `NOTIFY_URL` is empty or a send fails. Setting it with `set-conf.sh` sends a test message, then every problem already open. `ARCHIVE_TEST_DUE_SOON` warns 7 days (`ARCHIVE_TEST_WARN_DAYS`) before the `ARCHIVE_TEST_MAX_DAYS` limit (30 for new installs). When set, the watchdog POSTs a one-line message to it; an ntfy topic URL is
one option. Set it with `sudo bash bin/set-conf.sh NOTIFY_URL --prompt` so it never lands in shell
history.

## Install

```sh
sudo bash erp-backup-kit.sh primary   --me=NAME --peer=NAME --peer-host=TAILNET_HOST
sudo bash erp-backup-kit.sh secondary --me=NAME --peer=NAME --peer-host=TAILNET_HOST --primary-hostname=PRIMARY_HOSTNAME
sudo bash <root>/erp-backup/bin/install.sh
```

First install on each box, once: `get-age.sh`, `set-recipient.sh`, `setup-send.sh` here and
`setup-recv.sh` on the peer, `link-test.sh`, then on the secondary `standby-init.sh`.

Re-running the kit upgrades the scripts and keeps the conf. Names and hosts come from the conf; new keys
are appended. Change values with `bin/set-conf.sh KEY VALUE`, then run `bin/install.sh` if a schedule
changed. `oml` and `umbrellocal` remain accepted as role names for boxes installed before 2026-10-19.

## Everyday commands

| Command | |
|---|---|
| `bin/status.sh` | Read-only report, safe to paste anywhere (no secrets). |
| `bin/progress.sh [--watch [N]] [--json]` | Live progress of the running backup / push / restore and of sets arriving from the peer. |
| `bin/link-test.sh` | Path to the peer: reachable, host key pinned, key jailed, and direct vs DERP relay, plus the last push's rate. |
| `bin/run-now.sh [--push-only] [--restore]` | Back up, push and copy to the second target now, and print a summary. Waits for a push already running. `--push-only` skips the backup and just sends what is waiting. `--restore` (secondary) also runs the restore test now. `--restore-only` runs just the restore test, with no backup or push of the secondary's own data (the quick pre-upgrade check). |
| `bin/stage-upgrade.sh --image=IMAGE` | Secondary only. Restores a copy of the standby into a throwaway ERPNext built from IMAGE, runs `bench migrate`, checks it, then removes it. Use it before any image or framework upgrade. |
| `bin/offsite.sh config` | Create the rclone remote for a second target (interactive). |
| `bin/archive-test.sh peer\|own` | Encrypted-archive restore test (needs the private age key). |
| `bin/promote-standby.sh`, `demote.sh`, `fence.sh` | Failover and failback (see the runbook). |

## Tests

`tests/e2e.sh` drives two real ERPNext containers through every path above:

- backup and two-phase push;
- the 2026-10-17 cut-off set, and a set still arriving;
- one push at a time: a lock holder, an older kit's lock-less push, the peer's rrsync lock, a backup during
  a push, `--push-only`;
- first standby and nightly refresh with sanity checks;
- receipts back to the primary;
- second target;
- scrub catching a flipped byte;
- watchdog repairing a removed timer;
- notification dedupe and recovery;
- peer status in ERPNext;
- `run-now`, and optionally `stage-upgrade`.

It runs inside `tests/Dockerfile` with the docker socket mounted; see the header of `e2e.sh`.
