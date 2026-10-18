# erpnext_mcp: backup alerting (spec for routing)

2026-10-18. This is for the erpnext_mcp code session, in a release **after** the v0.336.0 now in
progress. Nothing here is implemented, and nothing in erpnext_mcp was edited to write it.

The companion host kit is `erp-backup/erp-backup-kit.sh` 2026-10-19.1, in fafo-umbrel-store. The kit
already works without any of this. Its alerts reach `get_backup_status` today, because that tool
passes the kit's own `alerts` through. What is missing is someone being **told**. Today an alert only
exists if a person or agent calls `get_backup_status`. That is how umbrel.local's status read
"critical" on 2026-10-18 and nobody heard.

## 1. Hourly evaluator → Compliance Alert (raise and clear)

Add a new scheduler job, `erpnext_mcp.backup_status.alerts_scheduled`. It runs hourly, after
`ingest_scheduled`, and never raises.

- Compute the same answer `get_backup_status` returns: one function shared by both, so the tool and
  the job can't disagree.
- For every alert at level `warning` or `critical`, upsert one **Compliance Alert**:
  - `alert_key = backup|<box>|<code>`
  - `alert_type = Backup`
  - `category = IT General Controls`
  - `severity` = the alert's level
  - `alert_message` = the alert's message
  - `company` = the `backup_record_company` flag, or the default company
  - `source_doctype`/`source_docname` = the latest Backup Record, when there is one
  - `can_dismiss = 1`
- Refresh `last_refreshed` on every run. Keep `first_seen`.
- An open `backup|<box>|*` alert whose code is no longer present gets `auto_dismissed = 1` and
  `dismissed_reason = "cleared: <iso time>"`.
- Snoozing respects `snoozed_until`, as other alerts do.
- Seed a Compliance Rule `backup_health` at **Advisory**, ON, next to CRULE `backup_verification`, so it
  shows on the compliance calendar like the rest.

## 2. Push to Tim

A new field on ERPNext MCP Settings: **Backup Alert Recipients** (Table MultiSelect → User), seeded
empty. Tim adds himself.

- When a run sees a **new critical code**, or the set of critical codes changes, send one push:
  - recipients: the push tokens of those users;
  - function: `services/push.send_push`;
  - priority: immediate;
  - `collapse_id = backup-<box>`.
- Warnings never push on their own.
- If nothing changes, repeat at most once every 24 h. Send one "Backups OK again" push when the last
  critical code clears.
- Keep the last-sent code set per box in a small Singles field or a cache key that survives a restart.
  Never send more than one push per box per hour.
- Payload:
  - title: `Backups: <box> <critical|ok>`
  - body: the first two messages
  - deep link: the Backup Record list
- No data beyond that. Push bodies are visible on the lock screen.

## 3. Morning brief / Today

- `get_owner_dashboard` gets a `backups` block per box:
  - `overall`
  - last backup age
  - last restore result and age
  - second-target result
  - open backup Compliance Alerts
- The phone's Today feed shows one card to System Managers while `overall` is not ok. The card
  disappears when it clears.
- A morning-brief consumer (Claude's morning skill, or any other) then needs no new tool. It reads
  `get_owner_dashboard` or `get_backup_status`.

## 4. `get_backup_status` learns kit 2026-10-19.1

All of these are additive; older files keep working.

- `KIT_EXPECTED = "2026-10-19.1"`.
- New per-box blocks:
  - `retention` (daily / weekly / monthly)
  - `offsite`
  - `target2_kind`
  - `scrub`
  - `watchdog`
  - `last_stage_upgrade`
  - `push.duration_s` and `push.attempts`
  - `standby_of_peer.sanity_ok` and `.skipped_incomplete`
  - the receipt's `sanity_ok`
- Recompute from timestamps, as the tool already does for the older codes, so a stale file can't hide
  these:
  - `OFFSITE_STALE`: 30 h, only when `target2_kind != none`
  - `SCRUB_STALE`: 9 days
  - `REPORTER_DEAD` for **every** file present, including a peer's file copied in by
    `PEER_STATUS_TO_CONTAINER=1`. A primary that goes silent then raises an alarm on the secondary's
    site, which is still up.
- New critical codes for the levels table: `OFFSITE_FAILED`, `SCRUB_FAILED`, `TIMERS_MISSING`.
- A receipt with `sanity_ok` other than `yes` maps to `REMOTE_RESTORE_NOT_PASS` with the reason.

## 5. Ingest

- `push.result == FAIL` → a Backup Record:
  - `status = Failed`
  - `backup_type` = the replica type
  - `ingest_key = <box>|<at>|push-failed`
  - notes = the message
- Today a failed push leaves no trace once the next night succeeds. 2026-10-17 has no row at all.
- `offsite.result == OK` with a new set → a Backup Record:
  - `backup_type = Offsite Replica`
  - `offsite = 1` only if the `backup_target2_is_offsite` flag is set
  - `location` = `target2_kind:target`
  - `ingest_key = <box>|<set>|target2`
- `last_stage_upgrade` → no Backup Record (it is not a backup). Instead a **Change Management Log**
  draft:
  - image
  - check
  - migrate seconds
  - versions
  - linked to the report path

  The next framework bump then has its rehearsal on file.
- With two status files on a site, ingest needs `backup_box`. Make `ingest_blocker()` say so in the
  same sentence the tool prints, so the deploy step is obvious.

## 6. Settings and flags (deploy, per site)

- OML:
  - `backup_box = oml` (needed before the peer file is copied in)
  - Backup Alert Recipients = Tim
- umbrel.local:
  - `backup_box = umbrellocal`
  - `backup_record_company` (it is multi-company; today its ingest writes nothing)
  - Backup Alert Recipients = Tim

## 7. Tests (standalone harness)

- Fixture files from kit 2026-10-19.1. Generate them with `erp-backup/tests/e2e.sh`, or hand-write
  them from its `status.json` shape.
- Alert raised, refreshed, then auto-dismissed when the code clears.
- Push sent once per new critical set, not on warnings, not more than hourly; "OK again" once.
- `REPORTER_DEAD` on a peer file older than 26 h.
- Ingest of a push failure is idempotent.
- `get_backup_status` on a site with only kit 2026-10-07.8 files is unchanged.
