# Frappe / ERPNext / HRMS v16 — upgrade assessment

2026-10-18. Research only: nothing here changes code. Written after the v15
security bump (commit 92cea86, base `frappe/erpnext:v15.123.0`), which stays the
thing to deploy now.

**Short answer.** v16 is mature (GA 2026-01-12, ten months of patches) and has a
few things we would use, chiefly the **Consolidated Trial Balance** and the
**Financial Report Template** for the holding-company structure. It does not
add US or state payroll, and nothing in it replaces what erpnext_mcp already
does for OR/WA. The cost is a **runtime jump to Python 3.14 / Node 24 /
Debian trixie**, a query-builder rewrite of `get_all` / `get_list` that touches
the most-used call in erpnext_mcp (1,282 sites), and **frappe/agriculture, which
is unmaintained and has no v16 branch**. v15 is supported until the **end of
2027 (planned)**. Recommendation: stay on v15 through the 2027 season and
plan the move for winter 2027–28, starting with a staging rehearsal in
summer 2027. Details and a staging plan are in §5.

---

## 1. Where v16 stands (verified)

| | Frappe | ERPNext | HRMS |
|---|---|---|---|
| v16.0.0 GA | 2026-01-12 | 2026-01-12 | 2026-01-12 |
| Latest v16 (today) | v16.52.0 (10-14) | v16.51.1 (10-15) | v16.51.0 (10-15) |
| Latest v15 (we run) | v15.123.1 | v15.123.0 | v15.64.5 |

* Support windows ([frappe.io/support-versions](https://frappe.io/support-versions)):
  v14 EOL 31 Jan 2026; **v15 end of 2027 (planned)**; v16 end of 2029 (planned).
  v14's precedent is that EOL means no more fixes, security included. The
  v15 window is therefore the deadline.
* Cadence: 5–13 releases a month per app since January. v15 still gets the
  same security fixes as v16 (all of this month's advisories list both lines).
* **v16.50 (2026-10-06/07) was a large UI release shipped as a minor.** It
  added a new Desk / dock / sidebars (opt-in via Desktop Settings), a Print
  Format Designer and an import wizard. ERPNext 16.50.0 carries a
  **"Breaking Changes"** section: user permissions are now enforced on
  records used in accounting, stock, asset, manufacturing and project
  actions, and role access changed for Payment Terms Template, POS Invoice,
  Serial and Batch Bundle and Address
  ([release](https://github.com/frappe/erpnext/releases/tag/v16.50.0), PR
  #59360). So v16 is still moving under app developers.
* erpnext / hrms `version-16` require `frappe >=16.50.0,<17`. All three move
  together.
* Open v16 issues relevant to us (sampled; nothing data-losing found): Tax
  Withholding regressions; Balance Sheet "Report Template" filter duplicated;
  Purchase Invoice before Purchase Receipt forced into SRBNB; Asset Activity
  ignoring company User Permissions.

## 2. What v16 would give us

| Area | In v16 | Value to us |
|---|---|---|
| Multi-company / holding | **Consolidated Trial Balance** (multi-company, reporting-currency translation, FCTR line; erpnext #49712). Consolidated Financial Statement cash-flow fix (#40716). No new inter-company feature found. | **High.** This is the holding-company roll-up we currently assemble by hand. |
| Financial reports | **Financial Report Template** (rows = account data / formula / custom API; opening / closing / movement; multi-company; #49098). Account name and number in separate columns. "Show Group Accounts" on TB. Dimension filters on party ledger summaries. | **Medium–high.** Could replace parts of erpnext_mcp's statement code. **TTM / period comparison is not an upstream feature.** erpnext_mcp's own TTM report (v0.333.0) stays. |
| Bank reconciliation | MT940 import (#48013); Bank Clearance validates all rows before updating. | **Low.** Bank Bridge does our import; it already ingests the bank feeds. |
| Assets | "Composite component" assets (no depreciation, #47602); Asset Repair against several invoices. | **Low–medium** (equipment repairs). |
| HR / payroll | Overtime (#2886), salary arrears, Leave Adjustment, Earned Leave Schedule, multi-currency claims, auto-attendance as a background job. **`hrms/regional` is still only India + UAE; no US or state payroll.** | **Low.** OR/WA/BOLI rules stay in erpnext_mcp. The overtime model may conflict with ours rather than help. |
| Mobile / API | `/api/v2` already exists in v15. Whitelist defaults are unchanged. `logout`, `upload_file` and `send_login_link` become POST-only. Desk moves `/app` → `/desk` (old URLs redirect). | **None.** FarmOps talks only to our `/farmops/api` sidecar. |
| Performance | Lock-free cache, cached pricing / stock / budget checks, scheduled jobs staggered to a maintenance queue. | **Modest.** Our bottlenecks are Pi-class hardware and wkhtmltopdf. |
| Desk UI | New Desk (16.50, opt-in), Print Format Designer, data-import wizard, Kanban / list improvements. Standard workspaces **reset on migrate**. | **Mixed.** It is nicer for Tim, but our 11 workspaces and the "hide default workspace" tool need rework. |
| Workflow | Transitions can trigger tasks / server scripts / webhooks, now or in the background (frappe #33255). | **Medium.** It overlaps erpnext_mcp's own workflow tooling. |
| Agriculture | **Nothing.** frappe/agriculture: `develop` only, last commit 2025-05-26, no pyproject (PR to add one closed unmerged 2026-05-30), v15 workspace fix still open. | **Negative.** See §3. |

## 3. Breaking changes and our exposure

Sources: [Frappe "Migrating to version 16"](https://github.com/frappe/frappe/wiki/Migrating-to-version-16),
[Query Builder migration](https://github.com/frappe/frappe/wiki/Query-Builder-Migration),
[ERPNext v16 migration guide](https://github.com/frappe/erpnext/wiki/Migration-Guide-To-ERPNext-Version-16).
Counts are from read-only greps on 2026-10-18 (erpnext_mcp at 0ec33cb,
excluding worktrees and the stray `api/mobile 2.py`).

What we have: erpnext_mcp is about 442k LOC of Python, with 257 doctypes, 565
whitelisted methods, 455 sidecar routes, 37 scheduled jobs, 5 Desk pages, 5
Jinja print formats, 11 workspaces, 3 script reports and 34 JS files. Smaller
pieces: farm_i9 (1.1k LOC), farm_precision_ag (2.0k LOC), and Bank Bridge (a
REST client, 49k LOC). It installs no `doc_events`, no `override_*` and no
fixtures. Its one monkeypatch is `pdf_base` → `frappe.utils.pdf`.

| Area | v16 change | Our exposure | Size | Risk |
|---|---|---|---|---|
| **Runtime** | Python **>=3.14,<3.15**; Node **>=24**; frappe_docker v16 builds on Debian **trixie**. | Every app's wheels rebuild. erpnext_mcp parses clean under 3.14 and uses no removed stdlib. Undeclared deps (cryptography, requests, httpx, jinja2, werkzeug) come from Frappe's pins. shapely / h3 / reportlab / pypdf need 3.14 wheels (check arm64 for h3 and shapely). | Dockerfile, all deps | **Medium** |
| **`get_all` / `get_list` on the query builder** | SQL strings in `fields`, function filter keys, `distinct x`, expression `order_by` and `run=False` change behaviour or break. **Default sort moves `modified` → `creation`.** | 1,282 `db.get_all` + 10 `get_list/get_all`. **9** SQL-function field strings, **2** `"distinct …"`, **116** `order_by` with a comma or expression, **2** `run=False`, 0 function-key filters. About **1,270 calls have no `order_by`**, so any that rely on "latest modified first" silently change order. | ~130 sites to edit; ~1,270 to audit for ordering | **High** (the ordering is silent) |
| Single doctype values | `db.get_value` on Singles returns typed values. | 12 `get_single_value` calls, 1 `== "1"` compare. | small | Low |
| **Commits in doc hooks** | `frappe.db.commit()` raises inside hooks.py doc events. | erpnext_mcp has no doc_events. **farm_precision_ag does:** Commodity Price Watch → `chart_factory.py:107` commits. farm_i9's Employee.on_update needs a check. | 1–2 files | **Medium** (fails at runtime) |
| Permissions | `has_permission` hooks must return `True` explicitly. `has_permission(raise_exception=)` is gone. ERPNext 16.50 enforces user permissions on accounting / stock / asset actions. | Our 2 hooks return booleans: OK. **The 16.50 user-permission enforcement plus `mcp_system_user` and mobile roles is the real risk.** It is the same class as the v15.12x File and Item permission tightening found this week. | roles.py, mcp_user_plan.py, mobile write paths | **High** |
| Workspaces / Desk | Standard workspaces reset on migrate. New Workspace Sidebar / Desktop Icon doctypes. `add_to_apps_screen` drives the dock. Report / Page JS runs as an IIFE. | 9 workspace specs + 2 built in code; `hide_default_workspace` edits core ones. 5 Desk pages use `frappe.ui.make_app_page` and inject `<script>` tags. 65 `/app/` URLs in Python, 17 in JS (redirects cover them; links should move to `/desk`). | ~20 files | **Medium** |
| Print / PDF | Builder print formats are deprecated. Jinja formats are unaffected. wkhtmltopdf is still the default and still bundled; Chromium is installed alongside. | 5 Jinja formats, which depend heavily on wkhtmltopdf (51 references: absolute-mm badge layout, inline-SVG workarounds). They keep working as long as we stay on wkhtmltopdf. `pdf_base` targets still exist in v16 (`scrub_urls` import, `get_cookie_options`, `get_pdf`). | 0 now | Low (Medium if we switch to Chromium) |
| Hooks we use | `auth_hooks`, `page_renderer`, `before_request` / `before_job`, `after_migrate`, `doctype_js`, `jinja`, `scheduler_events` all still exist. | 2 auth hooks, 1 page renderer (plain class, not BaseRenderer). | — | Low–Medium (needs re-testing, not rewriting) |
| farmops-api sidecar | Bootstraps Frappe itself (`frappe.init/connect`, sets `frappe.local.request` / `form_dict`, manual commit and destroy). | 4k LOC. Depends on Frappe's internal request lifecycle, which v16 reworked (site config cached 60 s, `after_response`). It serves **all** FarmOps traffic. | 4 files | **Medium–High** |
| Tests | `FrappeTestCase` deprecated (removed in v17). `test_dependencies` renamed. | Bench suite already prefers `IntegrationTestCase`. The standalone harness fakes Frappe and **cannot** catch any of this. | small | Low |
| ERPNext removals | `item_wise_tax_detail` JSON → child table; `make_bank_account` / `make_pricing_rule` removed; Sales Invoice no longer pulls timesheets. | 0 uses of `item_wise_tax_detail` (erpnext_mcp and Bank Bridge). | 0 | Low |
| **Bank Bridge** (REST client) | `/api/resource` and `/api/method` semantics unchanged; `upload_file` POST-only; 16.50 permission enforcement. | It uses token auth, CRUD on ~20 doctypes, creates DocTypes and Custom Fields over REST, and calls `reconcile_vouchers` and `make_reverse_journal_entry` (**both still present in v16.51.1**). It relies on Bank Transaction fields (`deposit`, `withdrawal`, `unallocated_amount`, `payment_entries`) in ~30 places. | 1 client + tests | **Medium** (permission tightening on its API user) |
| **FarmOps iOS** | Desk URL move only. | All traffic is `POST /farmops/api/...` to our sidecar. App code makes no direct Frappe REST calls. **The contract is ours, so v16 doesn't touch it** as long as the sidecar keeps its routes. | 0 Swift changes expected | Low |
| **frappe/agriculture** | No v16 branch, no pyproject. "Modern bench" rejects it as "Not a valid Frappe App". It duplicates ERPNext's Linked Location doctype. | Crop, Land Unit, Crop Cycle, Disease, Fertilizer, Water / Soil Analysis, Weather. | fork or replace | **High** (blocker until we vendor it or move its doctypes into farm_precision_ag) |
| farm_precision_ag monkeypatch | — | `boot_session` replaces `Report.execute_module`. That method still exists in v16 with the same signature, but behaviour needs re-testing. | 1 file | Low–Medium |

**Size estimate.** erpnext_mcp: about 130 call sites to edit, plus an ordering
audit across ~1,270 `get_all` calls. That audit is mechanical, but each call
needs a decision: add `order_by="modified desc"` or accept the creation order.
On top of that, the sidecar, the workspaces / Desk pages, and a permission
pass over every mobile write path. Small fixes in farm_precision_ag and
farm_i9. A fork or replacement for agriculture. A permission check for
Bank Bridge's API user. No iOS change. Expect **one dedicated release cycle
of erpnext_mcp (2–4 weeks of focused work)** plus a staging soak. It is not
a weekend bump.

## 4. Docker / Umbrel image impact

| | v15 image (now) | v16 image |
|---|---|---|
| Base | `frappe/erpnext:v15.123.0`, Debian 12 bookworm | `frappe/erpnext:v16.x`, Debian 13 **trixie** in current frappe_docker builds |
| Python | 3.11.17 | **3.14** |
| Node | 22.23.3 | **24** |
| Compressed size (amd64) | 859 MB | 972 MB (+13%) |
| PDF | wkhtmltopdf | wkhtmltopdf (bookworm .deb) **and** chromium-headless-shell |
| MariaDB | 10.6 sidecar | 10.6 still accepted (Frappe warns below 10.6 and above 11.8); frappe_docker now ships 11.8 |
| Redis | in-container | no stated minimum; in-container is fine |

Our Dockerfile carries over, with two caveats. The fontconfig / wkhtmltopdf
workaround needs re-checking on trixie. This week's two base-image surprises
are the kind of thing to expect again: the dropped `frappe` group and the
Node path. Each was a one-line fix, but each only showed up in a rehearsal.
The extra deps (shapely, h3, reportlab) need cp314 wheels for both
architectures. Without them they build from source, which takes a long time
on a Pi and may fail outright.

**Data migration time.** No official v15→v16 timing exists. OML's nightly
backup set is 563 MB encrypted, including files. Restoring it onto
umbrel.local takes about 6 min. A v16 migrate runs every v16 patch across
ERPNext, including the tax-detail child-table conversion and the
Tax Withholding Entry backfill. Those scale with transaction count, and ours
is modest. Estimate **15–45 min of downtime per server**, plus the 5–10 min
image start. A staging run measures the real number.

## 5. Recommendation

**When.** Not now, and not before the 2027 harvest. Stay on v15, which gets
the same security fixes, and keep taking the v15 bumps like this week's.
Target **winter 2027–28** for the cut-over: after harvest and payroll year-end,
before v15's planned end-2027 EOL bites. If Frappe extends v15, slide it. If
the consolidated statements become urgent sooner, the cheapest bridge is an
erpnext_mcp report, not a framework upgrade.

**Prerequisites, in order:**
1. **agriculture decision.** Either vendor a fork (pyproject, workspace fix,
   drop the duplicate Linked Location), or move the doctypes we actually use
   into farm_precision_ag. Do this on v15 first. It's the long pole.
2. erpnext_mcp v16-readiness release, still running on v15:
   * pin `order_by` explicitly on every `get_all` / `get_list` where order matters;
   * rewrite the ~11 SQL-string fields / `distinct` uses and the 2 `run=False`;
   * remove the `db.commit()` from farm_precision_ag's doc-event path;
   * move `/app/` links to a helper that knows the Desk base.

   All of it is backward-compatible on v15, so it ships early and gets
   real-world mileage.
3. A permission pass on mobile write paths and on `mcp_system_user`. It is
   needed anyway: v15.12x already started tightening, with the File parent-write
   and Item read checks found this week.
4. A bench integration run in CI on a set-up site. The standalone harness
   cannot see framework changes. This week the in-bench suite ran only on a
   site without a company, so about 50 tests error for environmental reasons.
5. cp314 wheels confirmed for shapely / h3 / reportlab on the Umbrels'
   architectures.

**Staging approach.**
* umbrel.local already restores OML's nightly backup. That job is the
  staging feed. **It is currently 180 h stale and its last result was Partial,
  so fix that first.**
* On the Mac, or on umbrel.local in a separate compose project:
  1. Restore the latest OML set into a v15 container.
  2. Swap to the v16 image.
  3. Run `bench migrate`, timed.
  4. Run the bench suite.
  5. Click through Desk with Tim.
  6. Point a TestFlight FarmOps build at the staging sidecar for a week.
* Use a separate ports block, as in this week's rehearsal on
  localhost:8081/5251.
* Never against the live site.

**Rollback plan.** It is the same shape as the v15 deploy steps, but stricter.
A v16 migrate is **one-way**: v16 patches rewrite tables, so a v15 image will
not run on a migrated database.
* Before cut-over, take a fresh `bench backup --with-files`, copy it
  off-box, and record the image ID / digest.
* Push the last v15 image under its own tag (`:15-final`).
* If anything fails, restore that backup onto the v15 image, then
  `enable-scheduler`, `restart all`, and recreate farmops-fwd.
* Decide a go / no-go time box in advance (e.g. 2 h). Anything entered
  after the backup is lost, so cut over in a no-entry window and tell the
  crews the phones will queue offline.
