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

`NOTIFY_URL` is optional. When set, the watchdog POSTs a one-line message to it; an ntfy topic URL is
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
| `bin/run-now.sh [--restore]` | Back up, push and copy to the second target now, and print a summary. `--restore` (secondary) also runs the restore test now. |
| `bin/stage-upgrade.sh --image=IMAGE` | Secondary only. Restores a copy of the standby into a throwaway ERPNext built from IMAGE, runs `bench migrate`, checks it, then removes it. Use it before any image or framework upgrade. |
| `bin/offsite.sh config` | Create the rclone remote for a second target (interactive). |
| `bin/archive-test.sh peer\|own` | Encrypted-archive restore test (needs the private age key). |
| `bin/promote-standby.sh`, `demote.sh`, `fence.sh` | Failover and failback (see the runbook). |

## Tests

`tests/e2e.sh` drives two real ERPNext containers through every path above:

- backup and two-phase push;
- the 2026-10-17 cut-off set, and a set still arriving;
- first standby and nightly refresh with sanity checks;
- receipts back to the primary;
- second target;
- scrub catching a flipped byte;
- watchdog repairing a removed timer;
- notification dedupe and recovery;
- peer status in ERPNext;
- `run-now`, and optionally `stage-upgrade`.

It runs inside `tests/Dockerfile` with the docker socket mounted; see the header of `e2e.sh`.
