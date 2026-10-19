#!/bin/bash
# erp-backup-kit.sh — symmetric, encrypted ERPNext backup + automated restore test + warm standby
# for two boxes (a PRIMARY that serves the farm, a SECONDARY that holds its copies and restores them).
#
# Usage (on each box):
#   first install:  sudo bash erp-backup-kit.sh primary   --me=NAME --peer=NAME --peer-host=HOST
#                   sudo bash erp-backup-kit.sh secondary --me=NAME --peer=NAME --peer-host=HOST --primary-hostname=HOST
#   upgrade:        sudo bash erp-backup-kit.sh primary|secondary      (names and hosts come from the existing conf)
#   Legacy aliases: "oml" = primary (me=oml, peer=umbrellocal); "umbrellocal" = secondary (the reverse).
#   Other options:  --root=DIR (default /home/umbrel/umbrel)  --container=NAME (default fafo-erpnext_server_1)
#                   --no-wait (refuse instead of waiting while a backup / push / restore runs)  --force (install anyway)
#
# SAFE WHILE JOBS RUN (2026-10-19.3): every script is written to a staging dir and moved into bin/ with rename(2),
# so a script that is running keeps reading its old file (bash reads scripts incrementally; kits before .3 wrote in
# place, which is how a running push died with "syntax error near unexpected token" on 2026-10-19). The installer
# also waits while any erp-* job runs (or refuses with --no-wait), pauses the timers while it writes, and re-arms them.
#
# Installs into <root>/erp-backup/. Safe to re-run: scripts are refreshed; an existing erp-backup.conf is kept
# (new keys are appended; change values with bin/set-conf.sh). Never edits app compose files or app-data, never
# restarts the ERPNext containers, never writes secrets to disk. Hosts, names and paths live only in the conf.
set -euo pipefail
KIT_VERSION="2026-10-19.3"

ROLE="${1:-}"; [ $# -gt 0 ] && shift
ARG_ME=""; ARG_PEER=""; ARG_PEER_HOST=""; ARG_PRIMARY_HOSTNAME=""; ARG_CONTAINER=""; FORCE_INSTALL=0; NO_WAIT=0
for a in "$@"; do case "$a" in
  --me=*) ARG_ME="${a#--me=}";; --peer=*) ARG_PEER="${a#--peer=}";; --peer-host=*) ARG_PEER_HOST="${a#--peer-host=}";;
  --primary-hostname=*) ARG_PRIMARY_HOSTNAME="${a#--primary-hostname=}";; --container=*) ARG_CONTAINER="${a#--container=}";;
  --root=*) ERP_KIT_ROOT="${a#--root=}";;
  --force) FORCE_INSTALL=1;; --no-wait) NO_WAIT=1;;
  *) echo "unknown option $a"; exit 1;; esac; done
ROOT_DIR="${ERP_KIT_ROOT:-/home/umbrel/umbrel}"        # Umbrel's persistent data dir
UMBREL_HOME="${ERP_KIT_UMBREL_HOME:-/home/umbrel}"     # home of the user peers push as
HOST="${ERP_KIT_HOSTNAME:-$(hostname)}"                # override only for testing

[ "$(id -u)" = 0 ] || { echo "Run with sudo:  sudo bash $0 $ROLE"; exit 1; }
[ -d "$ROOT_DIR" ] || { echo "No $ROOT_DIR here. Is this an Umbrel box? (or pass --root=DIR)"; exit 1; }
EXISTING_CONF="$ROOT_DIR/erp-backup/erp-backup.conf"
cget() { [ -f "$EXISTING_CONF" ] && sed -n "s/^$1=//p" "$EXISTING_CONF" | tail -n1 | sed -e 's/^"//' -e 's/"$//' || true; }
valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,30}$ ]]; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$ ]]; }

case "$ROLE" in
  primary|oml)
    KIND=primary; DEF_ME=primary; DEF_PEER=secondary; [ "$ROLE" = oml ] && { DEF_ME=oml; DEF_PEER=umbrellocal; }
    BACKUP_TIME=02:30; STANDBY_TIME=05:00; CHECK_TIME=07:30; WATCHDOG_TIME=07:45
    PROMOTE_ALLOWED=0; ALLOW_ARCHIVE_TEST=0
    ALLOW_STANDBY=0; SEND_STANDBY_SET=1; EXPECT_REMOTE_RESTORE=1
    STANDBY_EVERY=daily; REMOTE_RESTORE_MAX_HOURS=36 ;;
  secondary|umbrellocal)
    KIND=secondary; DEF_ME=secondary; DEF_PEER=primary; [ "$ROLE" = umbrellocal ] && { DEF_ME=umbrellocal; DEF_PEER=oml; }
    BACKUP_TIME=03:00; STANDBY_TIME=05:30; CHECK_TIME=07:00; WATCHDOG_TIME=07:15
    PROMOTE_ALLOWED=1; ALLOW_ARCHIVE_TEST=1
    ALLOW_STANDBY=1; SEND_STANDBY_SET=0; EXPECT_REMOTE_RESTORE=0
    STANDBY_EVERY=daily; REMOTE_RESTORE_MAX_HOURS=30 ;;
  *) echo "Usage: sudo bash $0 primary|secondary [--me=NAME --peer=NAME --peer-host=HOST --primary-hostname=HOST]"; exit 1 ;;
esac

# names and hosts: existing conf first (an upgrade never changes them), then options, then the legacy defaults
ME="$(cget ME)"; ME="${ME:-${ARG_ME:-$DEF_ME}}"
PEER_NAME="$(cget PEER_NAME)"; PEER_NAME="${PEER_NAME:-${ARG_PEER:-$DEF_PEER}}"
PEER_HOST="$(cget PEER_HOST)"; PEER_HOST="${PEER_HOST:-$ARG_PEER_HOST}"
PRIMARY_HOSTNAME="$(cget PRIMARY_HOSTNAME)"; [ -n "$PRIMARY_HOSTNAME" ] || PRIMARY_HOSTNAME="$(cget OML_HOSTNAME)"
PRIMARY_HOSTNAME="${PRIMARY_HOSTNAME:-$ARG_PRIMARY_HOSTNAME}"
[ "$KIND" = primary ] && [ -z "$PRIMARY_HOSTNAME" ] && PRIMARY_HOSTNAME="$HOST"
[ -z "$ARG_ME" ] || [ "$ARG_ME" = "$ME" ] || { echo "Refusing: this box's conf says ME=$ME, not $ARG_ME."; exit 1; }
valid_name "$ME" && valid_name "$PEER_NAME" && [ "$ME" != "$PEER_NAME" ] || { echo "Bad --me / --peer names ('$ME', '$PEER_NAME')."; exit 1; }
[ -n "$PEER_HOST" ] || { echo "First install needs --peer-host=<the peer's tailnet IP or name>."; exit 1; }
valid_host "$PEER_HOST" || { echo "Bad --peer-host '$PEER_HOST'."; exit 1; }
if [ -n "$PRIMARY_HOSTNAME" ]; then
  if [ "$KIND" = primary ]; then [ "$HOST" = "$PRIMARY_HOSTNAME" ] || { echo "Refusing: role primary but this host is '$HOST' (the conf's primary is $PRIMARY_HOSTNAME)."; exit 1; }
  else [ "$HOST" != "$PRIMARY_HOSTNAME" ] || { echo "Refusing: this is the primary ($HOST). Role secondary is for the other box."; exit 1; }; fi
else
  echo "NOTE: no --primary-hostname given; the 'never run restore tests on the primary' guard is off until it is set."
fi

BASE="$ROOT_DIR/erp-backup"
umask 077
mkdir -p "$BASE"/bin "$BASE"/systemd "$BASE"/keys "$BASE"/state "$BASE"/standby "$BASE"/work/standby \
         "$BASE"/own/daily "$BASE"/own/weekly "$BASE"/own/receipts "$BASE"/restore-tests
chmod 700 "$BASE" "$BASE/keys" "$BASE/work" "$BASE/standby"

# ---------------------------------------------------------------- wait until nothing is running
SDIR_SYS="${ERP_KIT_SYSTEMD_DIR:-/etc/systemd/system}"
self_or_ancestor() { local q="$$"; while [ -n "$q" ] && [ "$q" -ge 1 ] 2>/dev/null; do [ "$q" = "$1" ] && return 0; [ "$q" = 1 ] && break; q=$(awk '/^PPid:/{print $2}' "/proc/$q/status" 2>/dev/null); done; return 1; }
busy_now() { # prints what is running, empty if nothing
  local u f p out=""
  for u in erp-backup erp-push erp-standby erp-recv-check erp-offsite erp-scrub erp-watchdog; do
    systemctl is-active --quiet "$u.service" 2>/dev/null && out="$out $u.service"
  done
  for f in .lock .push.lock .standby.lock .offsite.lock .scrub.lock .stage.lock; do
    [ -e "$BASE/$f" ] || continue
    exec 7>>"$BASE/$f"; flock -n 7 || out="$out $f"; exec 7>&-
  done
  if command -v pgrep >/dev/null 2>&1; then
    for p in $(pgrep -f "$BASE/bin/[a-z-]+\.sh" 2>/dev/null || true); do
      self_or_ancestor "$p" && continue
      [ -d "/proc/$p" ] && out="$out $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -oE "bin/[a-z-]+\.sh" | head -n1)"
    done
  fi
  echo "${out# }"
}
if [ -d "$BASE/bin" ] && [ -n "$(ls -A "$BASE/bin" 2>/dev/null)" ]; then
  W=0; WMAX=$(( ${INSTALL_WAIT_MIN:-360} * 60 ))
  while B_NOW=$(busy_now); [ -n "$B_NOW" ]; do
    if [ "$FORCE_INSTALL" = 1 ]; then echo "Running: $B_NOW - installing anyway (--force; running scripts keep their old files)"; break; fi
    [ "$NO_WAIT" = 1 ] && { echo "Refusing: erp-backup jobs are running ($B_NOW). Re-run when they finish, or without --no-wait to wait."; exit 1; }
    [ "$W" -ge "$WMAX" ] && { echo "Still running after ${INSTALL_WAIT_MIN:-360} min ($B_NOW). Not installing."; exit 1; }
    [ $(( W % 300 )) = 0 ] && echo "$(date -Is) waiting for running erp-backup jobs to finish before installing: $B_NOW ($((W / 60)) min so far; Ctrl-C to stop, --force to install anyway)"
    sleep 15; W=$((W + 15))
  done
fi
# pause the timers while files change (a job starting halfway through an install would mix versions)
TIMERS_WERE=""
for t in erp-backup erp-standby erp-recv-check erp-offsite erp-scrub erp-watchdog erp-progress; do
  if systemctl is-active --quiet "$t.timer" 2>/dev/null; then TIMERS_WERE="$TIMERS_WERE $t"; systemctl stop "$t.timer" >/dev/null 2>&1 || true; fi
done
NB="$BASE/.bin.new.$$"; rm -rf "$NB"; mkdir -p "$NB"; chmod 700 "$NB"
trap 'rm -rf "$NB"; for t in $TIMERS_WERE; do systemctl start "$t.timer" >/dev/null 2>&1 || true; done' EXIT

# ---------------------------------------------------------------- config (create, or append missing keys)
CONF="$BASE/erp-backup.conf"
[ -f "$CONF" ] || { echo "# erp-backup settings for $ME. After editing, run: sudo bash $BASE/bin/install.sh" > "$CONF"; echo "Creating $CONF"; }
addconf() { grep -q "^$1=" "$CONF" || { echo "$1=$2" >> "$CONF"; echo "  conf + $1=$2"; }; }
addconf ME "$ME"
addconf CONTAINER "${ARG_CONTAINER:-fafo-erpnext_server_1}"
addconf SITE frontend
addconf BENCH /home/frappe/frappe-bench
addconf BASE "$BASE"
addconf UMBREL_HOME "$UMBREL_HOME"
addconf PRIMARY_HOSTNAME "${PRIMARY_HOSTNAME:-\"\"}"
addconf KEEP_DAILY 14
addconf KEEP_WEEKLY 8
addconf KEEP_MONTHLY 12
addconf WEEKLY_DOW 7
addconf BACKUP_TIME "$BACKUP_TIME"
addconf STANDBY_TIME "$STANDBY_TIME"
addconf CHECK_TIME "$CHECK_TIME"
addconf PEER_NAME "$PEER_NAME"
addconf PEER_HOST "$PEER_HOST"
addconf PEER_USER umbrel
addconf RECV_DIR "$ROOT_DIR/erp-backup-from-$PEER_NAME"
addconf MAX_AGE_HOURS 30
addconf SEND_ENABLED 0
addconf RECV_ENABLED 0
addconf ARCHIVE_RECIPIENT '""'
addconf SEND_STANDBY_SET "$SEND_STANDBY_SET"
addconf STANDBY_ENABLED 0
addconf ALLOW_STANDBY "$ALLOW_STANDBY"
addconf EXPECT_REMOTE_RESTORE "$EXPECT_REMOTE_RESTORE"
addconf ARCHIVE_TEST_MAX_DAYS 35
addconf DB_CONTAINER '""'
addconf DBPW_SOURCE auto
addconf STANDBY_EVERY "$STANDBY_EVERY"
addconf STANDBY_DAY Sun
addconf STANDBY_AT 03:00
addconf STANDBY_MIN_AVAIL_MB 2500
addconf STANDBY_MAX_SWAP_PCT 80
addconf STANDBY_STOP_APPS_ENABLED 0
addconf STANDBY_STOP_APPS '""'
addconf STANDBY_APP_STOP_CMD "'umbreld client apps.stop.mutate --appId {app}'"
addconf STANDBY_APP_START_CMD "'umbreld client apps.start.mutate --appId {app}'"
addconf REMOTE_RESTORE_MAX_HOURS "$REMOTE_RESTORE_MAX_HOURS"
addconf TS_MODE auto
addconf TS_CONTAINER '""'
addconf TS_SOCKET '""'
addconf STANDBY_SITE "standby-$PEER_NAME"
addconf PROMOTE_ALLOWED "$PROMOTE_ALLOWED"
addconf ALLOW_ARCHIVE_TEST "$ALLOW_ARCHIVE_TEST"
addconf PURGE_BENCH_PLAINTEXT 1
addconf STATUS_TO_CONTAINER 1
addconf NOTIFY_URL '""'
addconf NOTIFY_REPEAT_HOURS 24
addconf WATCHDOG_TIME "$WATCHDOG_TIME"
addconf STANDBY_WAIT_MIN 240
addconf PUSH_WAIT_MIN 300
addconf PUSH_BWLIMIT_KBPS 0
addconf DELTA_STANDBY 1
addconf PUSH_RESUME_AFTER_MIN 60
addconf PUSH_RESUME_MAX_PER_DAY 6
addconf LINK_MIN_RATE_KBPS 1000
addconf PUSH_TRANSPORT ssh
addconf PEER_LOCAL_DIR '""'
addconf PEER_STATUS_TO_CONTAINER 0
addconf TARGET2_KIND none
addconf TARGET2_PATH '""'
addconf TARGET2_TIME 04:30
addconf TARGET2_REQUIRE_MOUNT 1
addconf RCLONE_IMAGE rclone/rclone:1.68.2
addconf RCLONE_CONFIG_DIR /root/.config/rclone
addconf SCRUB_CALENDAR "'Sun *-*-* 08:30:00'"
addconf STAGE_IMAGE '""'
addconf STAGE_DB_IMAGE mariadb:10.6
addconf STAGE_PORT 8090
addconf STAGE_MIN_AVAIL_MB 3500

# ---------------------------------------------------------------- common.sh (shared helpers)
cat > "$NB/common.sh" <<'EOF_COMMON'
# sourced by every erp-backup script
_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_BIN_DIR/../erp-backup.conf"
SSH_KEY="$BASE/keys/send_ed25519"
KNOWN_HOSTS="$BASE/keys/known_hosts"
STATUS="$BASE/status.log"
STATE="$BASE/state"
STAGE="${STAGE:-misc}"
AGE="$BASE/bin/age"; [ -x "$AGE" ] || AGE="$(command -v age || echo "$BASE/bin/age")"
DOCTYPES=("GL Entry" "Journal Entry" "Sales Invoice" "Purchase Invoice" "Payment Entry" "Employee" "File")
log()    { echo "$(date -Is) [$ME/$STAGE] $*"; }
status() { echo "$(date -Is) $*" >> "$STATUS"; }
notify() { if [ -n "${NOTIFY_URL:-}" ]; then curl -fsS -m 10 -d "[$ME] $*" "$NOTIFY_URL" >/dev/null 2>&1 || true; fi; }
die()    { log "FAIL: $*"; status "FAIL $STAGE $*"; notify "FAIL $STAGE $*"; state_fail "$STAGE" "$*"; prog end FAIL "$*"; report_quiet; exit 1; }
# live progress (progress.py): prog begin PHASE STEP SET [--total BYTES] [--expect SECONDS] | prog bytes N [TOTAL] | prog end RESULT [NOTE]
prog() { ERPB_STATE="$STATE" ERPB_ME="$ME" ERPB_PEER="$PEER_NAME" ERPB_RECV_DIR="${RECV_DIR:-}" ERPB_REPORT="$_BIN_DIR/report.sh" \
           python3 "$_BIN_DIR/progress.py" "$@" 2>/dev/null || true; }
PROG_WATCH_PID=""
prog_watch()   { ERPB_STATE="$STATE" ERPB_ME="$ME" ERPB_REPORT="$_BIN_DIR/report.sh" python3 "$_BIN_DIR/progress.py" watchdir "$1" "$2" 5 >/dev/null 2>&1 & PROG_WATCH_PID=$!; }
prog_unwatch() { [ -n "$PROG_WATCH_PID" ] && kill "$PROG_WATCH_PID" 2>/dev/null; PROG_WATCH_PID=""; return 0; }
bytes_of() { du -sb "$@" 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
need_root() { [ "$(id -u)" = 0 ] || { echo "Run with sudo."; exit 1; }; }
setconf() { sed -i "s|^$1=.*|$1=$2|" "$BASE/erp-backup.conf"; }
# state_put STAGE k=v k=v ... (replaces the stage's state file; values must be single-line)
state_put() { local f="$STATE/$1.env"; shift; : > "$f.tmp"; for kv in "$@"; do printf '%s\n' "${kv//$'\n'/ }" >> "$f.tmp"; done; mv "$f.tmp" "$f"; }
state_get() { { sed -n "s/^$2=//p" "$STATE/$1.env" 2>/dev/null || true; } | tail -n1; }
# state_fail STAGE MSG : mark failure but keep the last good details (set, size, ...) and remember last_ok_at
state_fail() {
  local f="$STATE/$1.env" lok; lok=$(state_get "$1" last_ok_at)
  [ "$(state_get "$1" result)" = OK ] && lok=$(state_get "$1" at)
  { grep -v -e '^result=' -e '^at=' -e '^msg=' -e '^last_ok_at=' "$f" 2>/dev/null || true; } > "$f.tmp"
  printf 'result=FAIL\nat=%s\nmsg=%s\nlast_ok_at=%s\n' "$(date -Is)" "${2//$'\n'/ }" "$lok" >> "$f.tmp"; mv "$f.tmp" "$f"
}
report_quiet() { bash "$_BIN_DIR/report.sh" >/dev/null 2>&1 || true; }
prune_keep() { # prune_keep DIR N : keep newest N subdirs (names sort by date)
  [ -d "$1" ] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' ! -name '.*' | sort | head -n -"$2" | xargs -r rm -rf --
}
newest_dir() { find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' ! -name '.*' 2>/dev/null | sort | tail -n1; }
# A set is COMPLETE only once its marker file is there. Senders push every other file first and the marker
# last (push.sh), so a set that was cut off mid-transfer never looks complete. Never pick a set by name alone.
#   newest_complete DIR MARKER   -> newest complete set dir (empty if none)
#   incomplete_sets DIR MARKER   -> names of set dirs without the marker, oldest first
newest_complete() { local d; for d in $(find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' ! -name '.*' 2>/dev/null | sort -r); do [ -f "$d/$2" ] && { echo "$d"; return 0; }; done; return 0; }
incomplete_sets() { local d; for d in $(find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' ! -name '.*' 2>/dev/null | sort); do [ -f "$d/$2" ] || basename "$d"; done; return 0; }
dir_age_min() { echo $(( ( $(date +%s) - $(stat -c %Y "$1") ) / 60 )); }
# Where pushes go. PUSH_TRANSPORT=ssh (default): the peer's write-only rrsync jail over the tailnet.
# PUSH_TRANSPORT=local: a directory on this machine (PEER_LOCAL_DIR) - single-box installs, a USB disk, tests.
# ---- one push at a time (2026-10-19.2) ------------------------------------------------------------------
# A push to the peer can take hours over the tailnet. A second one started meanwhile (run-now.sh, a manual
# push.sh) used to fail three times on the peer's "Another instance of rrsync is already accessing this
# directory" and give up - and backup.sh replaced the plaintext standby set the running push was sending.
# Now: every push holds $BASE/.push.lock; pushes from kits older than 2026-10-19.2 hold no lock, so a running
# push is ALSO recognised by its process (push.sh, or rsync to the peer). Anything that would collide waits.
PUSH_LOCK="$BASE/.push.lock"
ppid_of() { awk '/^PPid:/{print $2}' "/proc/$1/status" 2>/dev/null; }
# is_mine PID: this process, something it started, or something that started it (sudo bash push.sh, run-now.sh)
is_mine() {
  local p="$1" q="$$"
  [ -d "/proc/$1" ] || return 0   # gone already (a short-lived subshell of this very lookup): not a push
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do [ "$p" = "$$" ] && return 0; p=$(ppid_of "$p"); done
  while [ -n "$q" ] && [ "$q" -ge 1 ] 2>/dev/null; do [ "$q" = "$1" ] && return 0; [ "$q" = 1 ] && break; q=$(ppid_of "$q"); done
  return 1
}
other_push_pids() { # pids of a push to the peer that this process did not start
  command -v pgrep >/dev/null 2>&1 || return 0
  local p
  { pgrep -f "$BASE/bin/push.sh" || true
    pgrep -f "rsync .*@${PEER_HOST}:" || true
    [ -n "${PEER_LOCAL_DIR:-}" ] && { pgrep -f "rsync .* ${PEER_LOCAL_DIR%/}" || true; }
  } 2>/dev/null | sort -un | while read -r p; do if [ -n "$p" ] && ! is_mine "$p"; then echo "$p"; fi; done
  return 0
}
push_progress() { # one line about the running push: since when, and how much rsync has read so far
  local p el="" mb=0 b
  for p in "$@"; do
    [ -z "$el" ] && el=$(ps -o etime= -p "$p" 2>/dev/null | tr -d ' ')
    b=$(awk '/^rchar:/{print $2}' "/proc/$p/io" 2>/dev/null || echo 0); mb=$(( mb + ${b:-0} / 1048576 ))
  done
  echo "running ${el:-?}, ${mb} MB read so far"
}
# wait_push_idle WHY : take the push lock, waiting (up to PUSH_WAIT_MIN) while any other push runs.
# The lock is held on fd 8 until this script exits.
wait_push_idle() {
  local max=$(( ${PUSH_WAIT_MIN:-300} * 60 )) poll="${PUSH_WAIT_POLL_S:-60}" w=0 pids last=-1
  exec 8>"$PUSH_LOCK"
  while :; do
    pids=$(other_push_pids | tr '\n' ' '); pids="${pids% }"
    if [ -z "$pids" ] && flock -n 8; then
      [ "$w" -gt 0 ] && log "the other push has finished; going ahead ($1) after $((w / 60)) min"
      PUSH_WAITED=$w; export PUSH_WAITED; return 0
    fi
    [ "$w" -ge "$max" ] && die "a push to $PEER_NAME is still running after ${PUSH_WAIT_MIN:-300} min; not starting ($1). Run it again later."
    if [ $(( w / 300 )) -ne "$last" ]; then   # say so at once, then every 5 minutes
      last=$(( w / 300 ))
      if [ -n "$pids" ]; then log "a push to $PEER_NAME is in progress (nightly or manual: $(push_progress $pids)), waiting... ($((w / 60)) of ${PUSH_WAIT_MIN:-300} min)"
      else log "another push holds $PUSH_LOCK, waiting... ($((w / 60)) of ${PUSH_WAIT_MIN:-300} min)"; fi
    fi
    sleep "$poll"; w=$((w + poll))
  done
}
peer_dest() { if [ "${PUSH_TRANSPORT:-ssh}" = local ]; then echo "${PEER_LOCAL_DIR%/}/${1:-}"; else echo "$PEER_USER@$PEER_HOST:./${1:-}"; fi; }
origin_now() { if [ -f "$BASE/PROMOTED" ]; then sed -n 's/^ORIGIN=//p' "$BASE/PROMOTED"; else echo "$ME"; fi; }
# run a command inside the ERPNext container as frappe, with selected env passed through (values never on argv)
bx() { docker exec -i -u frappe -w "$BENCH" -e DBPW -e ADMINPW -e TS -e TMPD -e DBF -e PUBF -e PRIVF -e SCOPE "$CONTAINER" "$@"; }
primary_host() { echo "${PRIMARY_HOSTNAME:-${OML_HOSTNAME:-}}"; }
site_exists() { docker exec "$CONTAINER" test -f "$BENCH/sites/$1/site_config.json"; }
# split a plaintext set dir into DBF / PUBF / PRIVF / CFGF (basenames)
set_files() {
  local d="$1" f; DBF=""; PUBF=""; PRIVF=""; CFGF=""
  for f in "$d"/*-database.sql.gz; do [ -e "$f" ] && DBF="$(basename "$f")"; done
  for f in "$d"/*-private-files.t*; do [ -e "$f" ] && PRIVF="$(basename "$f")"; done
  for f in "$d"/*-files.t*; do [ -e "$f" ] && [ "$(basename "$f")" != "$PRIVF" ] && PUBF="$(basename "$f")"; done
  for f in "$d"/*-site_config_backup.json; do [ -e "$f" ] && CFGF="$(basename "$f")"; done
  export DBF PUBF PRIVF CFGF
  [ -n "$DBF" ] && [ -n "$PUBF" ] && [ -n "$PRIVF" ] && [ -n "$CFGF" ]
}
# ---- status vocabulary (schema erp-backup-status/1):
#   result = did the JOB run:            OK | FAIL           (every stage's state file)
#   check  = did the RESTORE VERIFY:     Pass | Partial | Fail  (standby / archive-test only)
#   receipts carry both: "job" (OK|FAIL) and "check" (Pass|Partial|Fail); "result" there = check (kept for older readers)
# ---- tailnet path. Umbrel's Tailscale app runs in a container, usually in userspace-networking mode:
# the host has no tailscale0 and host processes cannot dial 100.x addresses. Box-to-box SSH therefore goes
# through the container:  ssh -o ProxyCommand="docker exec -i <ts> tailscale nc %h %p"
# TS_MODE=auto|direct|container   TS_CONTAINER=<name> (auto-detected)   TS_SOCKET=<tailscaled socket> (optional)
_TSC_CACHE=""
find_ts_container() {
  if [ -n "${TS_CONTAINER:-}" ]; then echo "$TS_CONTAINER"; return 0; fi
  if [ -n "$_TSC_CACHE" ]; then echo "$_TSC_CACHE"; return 0; fi
  local c
  # Umbrel's Tailscale app container is normally tailscale_web_1; try it first, skip Tor-related containers
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -i tailscale | grep -vi tor | sort -t_ -k2,2r | awk '/^tailscale_web/{print; next} {rest=rest" "$0} END{print rest}' || true); do
    if docker exec "$c" tailscale ${TS_SOCKET:+--socket=$TS_SOCKET} version >/dev/null 2>&1; then _TSC_CACHE="$c"; echo "$c"; return 0; fi
  done
  return 0
}
link_mode() { # direct | container | none
  case "${TS_MODE:-auto}" in direct|container) echo "$TS_MODE"; return 0;; esac
  if ip -4 addr show tailscale0 >/dev/null 2>&1; then echo direct; return 0; fi
  if [ -n "$(find_ts_container)" ]; then echo container; else echo none; fi
}
ssh_proxy() { # ProxyCommand value, or empty for direct
  [ "$(link_mode)" = container ] || return 0
  local c; c=$(find_ts_container); [ -n "$c" ] || return 0
  echo "docker exec -i $c tailscale${TS_SOCKET:+ --socket=$TS_SOCKET} nc %h %p"
}
init_ssh() { # SSH_ARGS (array, for ssh) and RSYNC_RSH (string, for rsync -e)
  local px; px=$(ssh_proxy)
  local base="-i $SSH_KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
  read -r -a SSH_ARGS <<<"$base"
  RSYNC_RSH="ssh $base"
  if [ -n "$px" ]; then SSH_ARGS+=(-o "ProxyCommand=$px"); RSYNC_RSH="$RSYNC_RSH -o 'ProxyCommand=$px'"; fi
  [ -n "${ERP_KIT_TEST_RSH:-}" ] && RSYNC_RSH="$ERP_KIT_TEST_RSH"   # tests only: a stand-in ssh that runs the real rrsync jail
}
peer_banner() { # first line the peer's sshd sends, via the same path SSH will use (empty if unreachable)
  local c
  if [ "$(link_mode)" = container ]; then
    c=$(find_ts_container); [ -n "$c" ] || return 0
    { sleep 4; } | timeout 12 docker exec -i "$c" tailscale ${TS_SOCKET:+--socket=$TS_SOCKET} nc "$PEER_HOST" 22 2>/dev/null | head -n1 | tr -d '\r' || true
  else
    timeout 10 bash -c "exec 3<>/dev/tcp/$PEER_HOST/22; head -n1 <&3" 2>/dev/null | tr -d '\r' || true
  fi
}
peer_reachable() { peer_banner | grep -q '^SSH-'; }
link_desc() { echo "mode=$(link_mode) ts_container=$(find_ts_container || true)${TS_SOCKET:+ socket=$TS_SOCKET}"; }
# link_probe: how packets to the peer travel (2026-10-19.3). Prints k=v lines: path=direct|derp|unknown derp=<region>
# endpoint=<ip:port> ping_ms tun=yes|no (no = userspace networking / netstack) online. Read-only; ~10 s.
link_probe() {
  local mode c st pg tsx=()
  mode=$(link_mode)
  if [ "$mode" = container ]; then c=$(find_ts_container); [ -n "$c" ] || { echo "path=unknown"; return 0; }; tsx=(docker exec "$c" tailscale ${TS_SOCKET:+--socket=$TS_SOCKET})
  elif [ "$mode" = direct ] && command -v tailscale >/dev/null; then tsx=(tailscale)
  else echo "path=unknown"; return 0; fi
  st=$(timeout 20 "${tsx[@]}" status --json 2>/dev/null || true)
  pg=$(timeout 30 "${tsx[@]}" ping -c 3 --timeout 5s "$PEER_HOST" 2>&1 | tail -n 3 || true)
  ERPB_PEER_HOST="$PEER_HOST" python3 - "$st" "$pg" <<'PY'
import json, os, re, sys
st, pg, host = sys.argv[1], sys.argv[2], os.environ["ERPB_PEER_HOST"]
out = {"path": "unknown"}
try:
    d = json.loads(st); out["tun"] = "yes" if d.get("TUN") else "no"
    for p in (d.get("Peer") or {}).values():
        names = [p.get("HostName", ""), (p.get("DNSName") or "").split(".")[0]] + (p.get("TailscaleIPs") or [])
        if host in names or any(n and host.startswith(n + ".") for n in names[:2]):
            out["online"] = "yes" if p.get("Online") else "no"
            if p.get("CurAddr"): out.update(path="direct", endpoint=p["CurAddr"])
            elif p.get("Relay"): out.update(path="derp", derp=p["Relay"])
            break
except Exception: pass
m = re.findall(r"via (DERP\(([^)]+)\)|[\[\]0-9a-fA-F.:]+:\d+) in ([\d.]+)ms", pg)
if m:
    v, region, ms = m[-1]; out["ping_ms"] = ms
    if v.startswith("DERP"): out.update(path="derp", derp=region)
    else: out.update(path="direct", endpoint=v)
for k, v in out.items(): print(f"{k}={v}")
PY
}
EOF_COMMON

# ---------------------------------------------------------------- lib-site.sh (restore/standby helpers)
cat > "$NB/lib-site.sh" <<'EOF_LIB'
# sourced by standby-*, archive-test, promote, demote, fence
keep_basis() { # the set just restored becomes standby/.basis (the peer sends tomorrow's set as a delta against it);
  # everything else up to and including it, by name, goes
  local set="$1" d
  if [ "${DELTA_STANDBY:-1}" = 1 ]; then rm -rf "$RECV_DIR/standby/.basis"; mv "$set" "$RECV_DIR/standby/.basis"; else rm -rf "$RECV_DIR/standby/.basis"; fi
  for d in $(find "$RECV_DIR/standby" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' ! -name '.*' | sort); do [[ "$(basename "$d")" > "$(basename "$set")" ]] || rm -rf "$d"; done
  return 0
}
copy_set_in() { # copy_set_in HOSTDIR -> $TMPD in container
  docker exec -u root "$CONTAINER" sh -c "rm -rf '$TMPD' && mkdir -p '$TMPD'"
  docker cp "$1/." "$CONTAINER:$TMPD/" >/dev/null 2>&1 || die "docker cp into container failed"
  docker exec -u root "$CONTAINER" chown -R frappe:frappe "$TMPD"
}
clean_tmp() { docker exec -u root "$CONTAINER" rm -rf "$TMPD" >/dev/null 2>&1 || true; }
readonly_on() { # site in read-only standby mode: reads allowed, writes/scheduler/email off
  local s="$1"
  bx bench --site "$s" set-config -p pause_scheduler 1 >/dev/null
  bx bench --site "$s" set-config -p mute_emails 1 >/dev/null
  bx bench --site "$s" set-config -p allow_reads_during_maintenance 1 >/dev/null
  bx bench --site "$s" set-config -p maintenance_mode 1 >/dev/null
}
fence_ro() { # production read-only for fencing: reads OK, no writes, scheduler paused (email setting untouched)
  local s="$1"
  bx bench --site "$s" set-config -p pause_scheduler 1 >/dev/null
  bx bench --site "$s" set-config -p allow_reads_during_maintenance 1 >/dev/null
  bx bench --site "$s" set-config -p maintenance_mode 1 >/dev/null
}
readonly_off() {
  local s="$1"
  bx bench --site "$s" set-config -p maintenance_mode 0 >/dev/null
  bx bench --site "$s" set-config -p allow_reads_during_maintenance 0 >/dev/null
  bx bench --site "$s" set-config -p pause_scheduler 0 >/dev/null
}
set_enc_key() { # copy encryption_key from the set's site_config_backup.json into site $TS (value never printed)
  bx python3 - <<'PY'
import json, glob, os, subprocess
src = glob.glob(os.path.join(os.environ["TMPD"], "*-site_config_backup.json"))[0]
key = json.load(open(src)).get("encryption_key")
if not key:
    # a site that never stored a secret has no key yet (Frappe makes it on first use): nothing to carry over
    print("note: source site_config has no encryption_key (no encrypted secrets to carry over)")
    raise SystemExit(0)
subprocess.run(["bench", "--site", os.environ["TS"], "set-config", "encryption_key", key], check=True, stdout=subprocess.DEVNULL)
PY
}
save_source_conf() { # keep non-DB keys of the source site_config for promotion (root-only file)
  bx python3 - <<'PY' > "$BASE/standby/source-config.json.tmp"
import json, glob, os
src = glob.glob(os.path.join(os.environ["TMPD"], "*-site_config_backup.json"))[0]
c = json.load(open(src))
drop = {"db_name", "db_password", "db_host", "db_port", "db_type", "db_user", "db_socket", "encryption_key",
        "maintenance_mode", "pause_scheduler", "allow_reads_during_maintenance"}
print(json.dumps({k: v for k, v in c.items() if k not in drop}))
PY
  chmod 600 "$BASE/standby/source-config.json.tmp"; mv "$BASE/standby/source-config.json.tmp" "$BASE/standby/source-config.json"
}
wipe_standby_files() { # empty the STANDBY site's file dirs so the restore is an exact copy (never production)
  [ "$TS" != "$SITE" ] && [[ "$TS" == standby-* || "$TS" == restoretest ]] || die "refusing to wipe files of site '$TS'"
  bx sh -c 'rm -rf "sites/$TS/public/files" "sites/$TS/private/files"; mkdir -p "sites/$TS/public/files" "sites/$TS/private/files"'
}
extract_files_into() { # replace site's public+private files with the set's archives (same code path bench restore uses)
  bx sh -c 'rm -rf "sites/$TS/public/files" "sites/$TS/private/files"; mkdir -p "sites/$TS/public/files" "sites/$TS/private/files"'
  docker exec -i -u frappe -w "$BENCH/sites" -e TS -e TMPD -e PUBF -e PRIVF "$CONTAINER" ../env/bin/python - <<'PY'
import os, frappe
from frappe.installer import extract_files
for f in (os.environ["PUBF"], os.environ["PRIVF"]):
    extract_files(os.environ["TS"], os.path.join(os.environ["TMPD"], f))
PY
}
counts_sql() {
  local q="SELECT CONCAT_WS(' '" d
  for d in "${DOCTYPES[@]}"; do q="$q, (SELECT COUNT(*) FROM \`tab$d\`)"; done
  echo "$q) AS counts;"
}
site_counts() { counts_sql | bx bench --site "$1" mariadb 2>/dev/null | tail -n1; }
# SANITY: companies, enabled users, accounts, GL imbalance (sum over companies of |debit - credit|, posted
# entries only) and the latest GL posting date. Taken at backup time into SANITY.txt, compared after restore.
sanity_sql() {
  echo "SELECT CONCAT_WS(' ', (SELECT COUNT(*) FROM \`tabCompany\`), (SELECT COUNT(*) FROM \`tabUser\` WHERE enabled=1),"
  echo " (SELECT COUNT(*) FROM \`tabAccount\`),"
  echo " (SELECT FORMAT(COALESCE(SUM(ABS(d)),0),2,'en_US') FROM (SELECT SUM(debit)-SUM(credit) d FROM \`tabGL Entry\` WHERE is_cancelled=0 GROUP BY company) x),"
  echo " (SELECT COALESCE(MAX(posting_date),'none') FROM \`tabGL Entry\` WHERE is_cancelled=0)) AS sanity;"
}
site_sanity() { sanity_sql | bx bench --site "$1" mariadb 2>/dev/null | tail -n1 | tr -d ','; }
# sanity_compare RESTORED SOURCE -> "yes" or the first reason it is not
sanity_compare() {
  local -a rv sv; read -r -a rv <<<"$1"; read -r -a sv <<<"$2"
  [ ${#rv[@]} -eq 5 ] || { echo "no-sanity-on-restore"; return 0; }
  [ ${#sv[@]} -eq 5 ] || { echo "yes"; return 0; }   # sets from older kits carry no SANITY.txt
  [ "${rv[0]}" = "${sv[0]}" ] || { echo "companies ${rv[0]}!=${sv[0]}"; return 0; }
  local du=$(( ${rv[1]} - ${sv[1]} )); [ "${du#-}" -le 2 ] || { echo "users ${rv[1]} vs ${sv[1]}"; return 0; }
  local da=$(( ${rv[2]} - ${sv[2]} )); { [ "$da" -ge 0 ] && [ "$da" -le 5 ]; } || { echo "accounts ${rv[2]} vs ${sv[2]}"; return 0; }
  awk -v a="${rv[3]}" -v b="${sv[3]}" 'BEGIN{ exit !((a+0) <= 0.05 || (a-b) <= 0.05 && (b-a) <= 0.05) }' || { echo "gl-imbalance ${rv[3]} (source ${sv[3]})"; return 0; }
  [ "${rv[4]}" = "${sv[4]}" ] || [[ "${rv[4]}" > "${sv[4]}" ]] || { echo "latest-gl ${rv[4]} < ${sv[4]}"; return 0; }
  echo yes
}
run_checks() { # run_checks SITE SETDIR -> CHK_* vars + CHK_RESULT
  local s="$1" setdir="$2" i
  CHK_APPS=$(bx bench --site "$s" list-apps 2>/dev/null | tr '\n' ' ' | tr -s ' ')
  CHK_COUNTS=$(site_counts "$s")
  CHK_SRC_COUNTS=$(cat "$setdir/COUNTS.txt" 2>/dev/null || echo "")
  CHK_COUNTS_OK=unknown
  if [ -n "$CHK_SRC_COUNTS" ] && [ -n "$CHK_COUNTS" ]; then
    read -r -a a <<<"$CHK_COUNTS"; read -r -a b <<<"$CHK_SRC_COUNTS"; CHK_COUNTS_OK=yes
    [ ${#a[@]} -eq ${#b[@]} ] || CHK_COUNTS_OK=no
    for i in "${!b[@]}"; do d=$(( ${a[$i]:-0} - ${b[$i]:-0} )); { [ "$d" -ge 0 ] && [ "$d" -le 5 ]; } || CHK_COUNTS_OK=no; done
  fi
  # file check by NAME, not just count: missing = in the archive but not restored (a real problem);
  # extra = on disk but not in the archive (stale leftovers; harmless for recovery, reported only)
  local fc; fc=$(bx sh -c 'export LC_ALL=C; for k in public private; do
      arc=$PUBF; [ $k = private ] && arc=$PRIVF
      (cd "sites/$TS/$k/files" 2>/dev/null && find . -type f | cut -c3- | sort) > "$TMPD/.disk.$k"
      tar -tf "$TMPD/$arc" | grep "/$k/files/.*[^/]$" | sed "s|^.*/$k/files/||" | sort > "$TMPD/.arc.$k"
      echo "$k $(wc -l < "$TMPD/.disk.$k") $(wc -l < "$TMPD/.arc.$k") $(comm -13 "$TMPD/.disk.$k" "$TMPD/.arc.$k" | wc -l) $(comm -23 "$TMPD/.disk.$k" "$TMPD/.arc.$k" | wc -l) $(comm -13 "$TMPD/.disk.$k" "$TMPD/.arc.$k" | head -n 3 | tr "\n" "|")$(comm -23 "$TMPD/.disk.$k" "$TMPD/.arc.$k" | head -n 3 | sed "s/^/+/" | tr "\n" "|")"
    done')
  local k n a m e ex
  CHK_MISSING=0; CHK_EXTRA=0; CHK_FILE_EXAMPLES=""
  while read -r k n a m e ex; do
    [ "$k" = public ] && { CHK_PUBN=$n; CHK_PUBA=$a; }
    [ "$k" = private ] && { CHK_PRIVN=$n; CHK_PRIVA=$a; }
    CHK_MISSING=$((CHK_MISSING + ${m:-0})); CHK_EXTRA=$((CHK_EXTRA + ${e:-0})); [ -n "$ex" ] && CHK_FILE_EXAMPLES="$CHK_FILE_EXAMPLES $k:$ex"
  done <<<"$fc"
  local dec; dec=$(docker exec -i -u frappe -w "$BENCH/sites" -e TS "$CONTAINER" ../env/bin/python - <<'PY' 2>/dev/null | tail -n1
import os, frappe
frappe.init(site=os.environ["TS"], sites_path="."); frappe.connect()
from frappe.utils.password import decrypt
rows = frappe.db.sql("select `password` from `__Auth` where encrypted=1", as_dict=True)
bad = 0
for r in rows:
    try:
        decrypt(r.password)
    except Exception:
        bad += 1
print(f"{len(rows)} {bad}")
frappe.destroy()
PY
)
  read -r CHK_SECRETS CHK_DECRYPT_FAIL <<<"${dec:-? ?}"
  CHK_SANITY=$(site_sanity "$s"); CHK_SRC_SANITY=$(cat "$setdir/SANITY.txt" 2>/dev/null || echo "")
  CHK_SANITY_OK=$(sanity_compare "$CHK_SANITY" "$CHK_SRC_SANITY")
  CHK_RESULT=Pass
  [ "$CHK_COUNTS_OK" = yes ] || CHK_RESULT=Partial
  [ "$CHK_SANITY_OK" = yes ] || CHK_RESULT=Partial
  [ "${CHK_MISSING:-1}" = 0 ] || CHK_RESULT=Partial
  [ "$CHK_DECRYPT_FAIL" = 0 ] || CHK_RESULT=Partial
  echo "apps: $CHK_APPS"
  echo "counts (${DOCTYPES[*]}): restored [$CHK_COUNTS] source [$CHK_SRC_COUNTS] ok=$CHK_COUNTS_OK"
  echo "sanity (companies users accounts gl-imbalance latest-gl): restored [$CHK_SANITY] source [$CHK_SRC_SANITY] ok=$CHK_SANITY_OK"
  echo "files public $CHK_PUBN/$CHK_PUBA private $CHK_PRIVN/$CHK_PRIVA (missing $CHK_MISSING, extra $CHK_EXTRA${CHK_FILE_EXAMPLES:+:$CHK_FILE_EXAMPLES}); secrets $CHK_SECRETS, decrypt failures $CHK_DECRYPT_FAIL -> $CHK_RESULT"
}
ask_dbpw() { [ -t 0 ] || die "DB root password could not be read from the db container and there is no terminal to ask (set DB_CONTAINER, or run by hand)"; read -rsp "MariaDB root password for THIS box's ERPNext database (hidden): " DBPW; echo; [ -n "$DBPW" ] || die "no password entered"; export DBPW; }
# Find the app's MariaDB container: DB_CONTAINER from conf, else the container in the same compose project
# whose environment defines (MARIADB|MYSQL)_ROOT_PASSWORD[_FILE].
find_db_container() {
  if [ -n "${DB_CONTAINER:-}" ]; then echo "$DB_CONTAINER"; return 0; fi
  local p c
  p=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$CONTAINER" 2>/dev/null || true)
  [ -n "$p" ] || return 0
  for c in $(docker ps --filter "label=com.docker.compose.project=$p" --format '{{.Names}}' 2>/dev/null); do
    if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null | grep -qE '^(MARIADB|MYSQL)_ROOT_PASSWORD(_FILE)?='; then echo "$c"; return 0; fi
  done
}
# get_dbpw: read the DB root password from the db container's env at runtime (memory only; never printed or stored),
# verify it by connecting, else fall back to a hidden prompt. DBPW_SOURCE=prompt in conf forces the prompt.
get_dbpw() {
  DBPW=""; export DBPW
  if [ "${DBPW_SOURCE:-auto}" = auto ]; then
    local dbc envs f
    dbc=$(find_db_container || true)
    if [ -n "$dbc" ]; then
      envs=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$dbc" 2>/dev/null || true)
      DBPW=$(printf '%s\n' "$envs" | sed -n 's/^MARIADB_ROOT_PASSWORD=//p' | head -n1)
      [ -n "$DBPW" ] || DBPW=$(printf '%s\n' "$envs" | sed -n 's/^MYSQL_ROOT_PASSWORD=//p' | head -n1)
      if [ -z "$DBPW" ]; then
        f=$(printf '%s\n' "$envs" | sed -n -E 's/^(MARIADB|MYSQL)_ROOT_PASSWORD_FILE=//p' | head -n1)
        [ -n "$f" ] && DBPW=$(docker exec "$dbc" cat "$f" 2>/dev/null || true)
      fi
      envs=""; export DBPW
      if [ -n "$DBPW" ] && MYSQL_PWD="$DBPW" docker exec -e MYSQL_PWD "$dbc" sh -c 'mariadb -uroot -e "SELECT 1" >/dev/null 2>&1 || mysql -uroot -e "SELECT 1" >/dev/null 2>&1'; then
        log "DB root password read from $dbc environment and verified (not shown, not stored)"; return 0
      fi
      log "could not use the password from $dbc environment; asking instead"
    else
      log "db container not found automatically (set DB_CONTAINER in conf); asking instead"
    fi
  fi
  ask_dbpw
}
new_empty_site() { # new_empty_site NAME (needs DBPW)
  export TS="$1"
  ADMINPW=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20); export ADMINPW
  SCOPE="--mariadb-user-host-login-scope=%"
  docker exec -u frappe -w "$BENCH" "$CONTAINER" bench new-site --help 2>/dev/null | grep -q -- '--mariadb-user-host-login-scope' || SCOPE="--no-mariadb-socket"
  export SCOPE
  bx sh -c 'bench new-site "$TS" --db-root-password "$DBPW" --admin-password "$ADMINPW" $SCOPE' 2>&1 | tail -n 5 || true
  site_exists "$TS" || die "new-site $TS failed (wrong DB root password?)"
}
check_versions() { # die if any app in the set's VERSIONS.txt is missing here or newer than this bench (restore would refuse / prompt)
  local src="$1/VERSIONS.txt" mine bad="" app ver lv
  [ -s "$src" ] || return 0
  mine=$(docker exec -u frappe -w "$BENCH" "$CONTAINER" bench version 2>/dev/null || true)
  while read -r app ver _; do
    [[ "$app" =~ ^[a-z0-9_]+$ ]] && [[ "$ver" =~ ^v?[0-9] ]] || continue
    lv=$(awk -v a="$app" '$1==a{print $2}' <<<"$mine")
    if [ -z "$lv" ]; then bad="$bad $app(missing here; source $ver)"; continue; fi
    [ "$(printf '%s\n%s\n' "${ver#v}" "${lv#v}" | sort -V | tail -n1)" = "${lv#v}" ] || bad="$bad $app(here $lv < source $ver)"
  done < "$src"
  [ -z "$bad" ] || die "this bench is older than the backup:$bad. Update the ERPNext app on $(hostname) first, then run standby-refresh.sh --now"
}
full_restore() { # full_restore SITE (needs DBPW, set copied to $TMPD)
  export TS="$1"
  bx sh -c 'bench --site "$TS" restore "$TMPD/$DBF" --with-public-files "$TMPD/$PUBF" --with-private-files "$TMPD/$PRIVF" --db-root-password "$DBPW"' || die "bench restore into $TS failed"
}
drop_test_site() { # only ever drops sites named restoretest
  export TS="$1"; [ "$TS" = restoretest ] || die "refusing to drop $TS"
  bx sh -c 'bench drop-site "$TS" --db-root-password "$DBPW" --no-backup --force' || die "drop-site failed"
  docker exec -u root "$CONTAINER" sh -c "rm -rf '$BENCH'/archived_sites/${TS}*"
}
# Memory pre-check (2026-10-19.3). The test is MemAvailable from /proc/meminfo (what the kernel can hand out
# without swapping; NOT "free"). Swap that is merely OCCUPIED is not pressure: pages swapped out days ago and never
# touched again sit there harmlessly (seen on a standby box: 3.5 GiB available with 4.1 GiB of swap used). So a high swap
# percentage only defers a restore when swap is ACTIVE: swap-ins in a short sample, or memory PSI stall.
mem_snapshot() { # sets MEM_AVAIL_MB, SWAP_PCT, SWAPIN_PS (pages/s over MEM_SAMPLE_S), PSI_SOME10
  local f="${ERP_MEMINFO:-/proc/meminfo}" v="${ERP_VMSTAT:-/proc/vmstat}" a st sf i1 i2
  a=$(awk '/^MemAvailable:/{print $2}' "$f"); st=$(awk '/^SwapTotal:/{print $2}' "$f"); sf=$(awk '/^SwapFree:/{print $2}' "$f")
  MEM_AVAIL_MB=$(( ${a:-0} / 1024 )); SWAP_PCT=0
  [ "${st:-0}" -gt 0 ] && SWAP_PCT=$(( (st - sf) * 100 / st ))
  SWAPIN_PS=0
  if [ "$SWAP_PCT" -gt 0 ] && [ -r "$v" ]; then
    i1=$(awk '/^pswpin /{print $2}' "$v"); sleep "${MEM_SAMPLE_S:-5}"; i2=$(awk '/^pswpin /{print $2}' "$v")
    SWAPIN_PS=$(( ( ${i2:-0} - ${i1:-0} ) / ${MEM_SAMPLE_S:-5} ))
  fi
  PSI_SOME10=$(awk '/^some/{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i}}' "${ERP_PSI:-/proc/pressure/memory}" 2>/dev/null || true)
  PSI_SOME10="${PSI_SOME10:-0}"
  return 0
}
swap_active() { [ "$SWAPIN_PS" -ge "${STANDBY_MAX_SWAPIN_PS:-50}" ] || awk -v p="$PSI_SOME10" -v m="${STANDBY_MAX_PSI:-10}" 'BEGIN{exit !(p+0 >= m+0)}'; }
mem_ok() { mem_snapshot; [ "$MEM_AVAIL_MB" -ge "${STANDBY_MIN_AVAIL_MB:-2500}" ] || return 1; [ "$SWAP_PCT" -le "${STANDBY_MAX_SWAP_PCT:-80}" ] && return 0; ! swap_active; }
mem_desc() { echo "MemAvailable ${MEM_AVAIL_MB} MB (need >= ${STANDBY_MIN_AVAIL_MB:-2500}), swap ${SWAP_PCT}% used ($( [ "$SWAP_PCT" -le "${STANDBY_MAX_SWAP_PCT:-80}" ] && echo "under ${STANDBY_MAX_SWAP_PCT:-80}%" || { swap_active && echo "ACTIVE: ${SWAPIN_PS} swap-ins/s, PSI ${PSI_SOME10}" || echo "idle: ${SWAPIN_PS} swap-ins/s, PSI ${PSI_SOME10} - not counted"; }))"; }
standby_due() { # weekly: due on STANDBY_DAY, or after a deferral/failure, or if the last good refresh is > 8 days old
  [ "${STANDBY_EVERY:-daily}" = weekly ] || return 0
  [ -f "$STATE/standby_defer.env" ] && return 0
  [ "$(state_get standby result)" = OK ] || return 0
  [ "$(state_get standby check)" = Pass ] || return 0   # Partial/Fail: retry the next night, not next week
  local at; at=$(state_get standby at); [ -n "$at" ] || return 0
  local age_h=$(( ( $(date +%s) - $(date -d "$at" +%s) ) / 3600 ))
  [ "$(LC_ALL=C date +%a)" = "${STANDBY_DAY:-Sun}" ] && [ "$age_h" -ge 20 ] && return 0
  [ "$age_h" -ge 192 ] && return 0
  return 1
}
STOPPED_APPS=""
stop_apps() { # optional, default off: stop named Umbrel apps through umbreld (never docker restart)
  [ "${STANDBY_STOP_APPS_ENABLED:-0}" = 1 ] && [ -n "${STANDBY_STOP_APPS:-}" ] || return 1
  local app
  for app in $STANDBY_STOP_APPS; do
    log "stopping Umbrel app $app for the standby refresh"
    if bash -c "${STANDBY_APP_STOP_CMD//\{app\}/$app}" >/dev/null 2>&1; then STOPPED_APPS="$STOPPED_APPS $app"; else log "WARN: could not stop $app"; fi
  done
  trap start_apps EXIT
  sleep "${STANDBY_APP_SETTLE_S:-30}"
  return 0
}
start_apps() {
  local app
  for app in $STOPPED_APPS; do
    log "starting Umbrel app $app again"
    bash -c "${STANDBY_APP_START_CMD//\{app\}/$app}" >/dev/null 2>&1 || { log "WARN: could not start $app - start it from the Umbrel UI"; notify "could not restart app $app after standby refresh"; }
  done
  STOPPED_APPS=""
}
defer_standby() { # record a skipped refresh (not a failure) and exit cleanly
  state_put standby_defer at="$(date -Is)" reason="$1" mem_avail_mb="$MEM_AVAIL_MB" swap_pct="$SWAP_PCT"
  log "DEFERRED: $1"; status "DEFER standby $1"; notify "standby refresh deferred: $1"
  report_quiet; exit 0
}
write_receipt() { # write_receipt SET SITE DURATION METHOD : "your backup set X was restored here and checked" (for the peer)
  cat > "$BASE/own/receipts/standby-of-$PEER_NAME.json" <<JSON
{"restored_by":"$ME","restored_on_host":"$(hostname)","data_of":"$PEER_NAME","set":"$1","site":"$2","at":"$(date -Is)","duration_s":$3,"method":"$4","job":"OK","check":"$CHK_RESULT","result":"$CHK_RESULT","counts_ok":"$CHK_COUNTS_OK","files":"$CHK_PUBN/$CHK_PUBA,$CHK_PRIVN/$CHK_PRIVA","files_missing":${CHK_MISSING:-0},"files_extra":${CHK_EXTRA:-0},"secrets":"$CHK_SECRETS","decrypt_fail":"$CHK_DECRYPT_FAIL","sanity_ok":"$CHK_SANITY_OK","kit":"$(cat "$BASE/KIT_VERSION" 2>/dev/null)","waited_for_push_s":${WAITED:-0},"progress":{"restore_s":$3,"set_bytes":$(bytes_of "$RECV_DIR/standby/$1" "$RECV_DIR/standby/.basis" | head -n1)}}
JSON
}
confirm_word() { local w; read -rp "Type $1 to continue: " w; [ "$w" = "$1" ] || die "not confirmed"; }
EOF_LIB

# ---------------------------------------------------------------- get-age.sh
cat > "$NB/get-age.sh" <<'EOF_GETAGE'
#!/bin/bash
# Install the age encryption tool (static binary, pinned v1.3.1, checksum-verified) into erp-backup/bin.
set -euo pipefail
STAGE=get-age
. "$(dirname "$0")/common.sh"
need_root
V=v1.3.1
case "$(uname -m)" in
  aarch64|arm64) A=linux-arm64; SUM=c6878a324421b69e3e20b00ba17c04bc5c6dab0030cfe55bf8f68fa8d9e9093a ;;
  x86_64|amd64)  A=linux-amd64; SUM=bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377 ;;
  armv7l|armv6l) A=linux-arm;   SUM=0af5d0dd1664d43dda955938280a668fdd298ad0df90058b409067dfdec74ba3 ;;
  *) die "unsupported CPU $(uname -m)" ;;
esac
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
curl -fsSL -o "$T/age.tgz" "https://github.com/FiloSottile/age/releases/download/$V/age-$V-$A.tar.gz" || die "download failed"
echo "$SUM  $T/age.tgz" | sha256sum -c --quiet - || die "CHECKSUM MISMATCH - not installing"
tar -xzf "$T/age.tgz" -C "$T"
install -m 755 "$T/age/age" "$BASE/bin/age"
install -m 755 "$T/age/age-keygen" "$BASE/bin/age-keygen"
log "installed $("$BASE/bin/age" --version) ($A), checksum verified"
EOF_GETAGE

# ---------------------------------------------------------------- set-recipient.sh
cat > "$NB/set-recipient.sh" <<'EOF_RCPT'
#!/bin/bash
# Store the PUBLIC age recipient (age1...) used to encrypt archives. The private key never comes to this box.
set -euo pipefail
STAGE=set-recipient
. "$(dirname "$0")/common.sh"
need_root
echo "Paste the age PUBLIC key (starts with age1...), then press Enter:"
read -r R
[[ "$R" =~ ^age1[0-9a-z]{58}$ ]] || die "that is not an age public key (expected age1 + 58 chars)"
setconf ARCHIVE_RECIPIENT "\"$R\""
[ -x "$AGE" ] || die "age not installed; run get-age.sh first"
echo "self-test" | "$AGE" -r "$R" -a >/dev/null || die "age could not encrypt to that recipient"
if echo "x" | "$AGE" -r "$R" | "$AGE" -d -i /dev/null >/dev/null 2>&1; then die "unexpected: decrypted without a key"; fi
status "OK set-recipient ${R:0:12}..."
echo "Archive recipient set: ${R:0:16}...${R: -6}  (public key only; this box cannot decrypt archives)"
EOF_RCPT

# ---------------------------------------------------------------- backup.sh
cat > "$NB/backup.sh" <<'EOF_BACKUP'
#!/bin/bash
# Nightly: bench backup --with-files -> verify -> encrypted archive in own/daily/<stamp>
#          (+ plaintext standby set in work/standby/<stamp> for the peer's warm standby) -> weekly link -> prune
set -euo pipefail
umask 077
STAGE=backup
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/lib-site.sh"
need_root
trap 'die "unexpected error at line $LINENO"' ERR
exec 9>"$BASE/.lock"
if ! flock -n 9; then
  [ "${BACKUP_LOCK_WAIT_S:-0}" -gt 0 ] || die "another backup is already running"
  log "another backup is running, waiting up to $(( BACKUP_LOCK_WAIT_S / 60 )) min..."
  flock -w "$BACKUP_LOCK_WAIT_S" 9 || die "another backup is still running after $(( BACKUP_LOCK_WAIT_S / 60 )) min"
fi
[ -n "$ARCHIVE_RECIPIENT" ] || die "ARCHIVE_RECIPIENT not set (run set-recipient.sh); refusing to write unencrypted archives"
[ -x "$AGE" ] || die "age not installed (run get-age.sh)"

BK="$BENCH/sites/$SITE/private/backups"
START=$(date +%s); STAMP=$(date +%F_%H%M)
WORK="$BASE/work/$STAMP"; ARCH="$BASE/own/daily/$STAMP"
[ ! -e "$ARCH" ] || die "$ARCH already exists (ran twice in one minute?)"
ORIGIN=$(origin_now)

export TS="$SITE"
SRC_COUNTS=$(site_counts "$SITE" || true)
SRC_SANITY=$(site_sanity "$SITE" || true)
log "bench --site $SITE backup --with-files  (container $CONTAINER, data origin $ORIGIN)"
prog begin backup "bench backup (dump + tar inside ERPNext)" "$STAMP" --expect "$(state_get backup bench_s)"
TB=$SECONDS
docker exec -u frappe -w "$BENCH" "$CONTAINER" bench --site "$SITE" backup --with-files >/dev/null || die "bench backup failed"
BENCH_S=$((SECONDS - TB))

NEWEST=$(docker exec "$CONTAINER" sh -c "ls -1t '$BK'/*-database.sql.gz 2>/dev/null | head -n1" || true)
[ -n "$NEWEST" ] || die "no *-database.sql.gz found in $BK"
[ "$(docker exec "$CONTAINER" stat -c %Y "$NEWEST")" -ge $((START - 5)) ] || die "newest backup $NEWEST is older than this run"
PREFIX="${NEWEST%-database.sql.gz}"

mkdir -p "$WORK.partial"
prog begin backup "copy out of the container" "$STAMP" --total "$(docker exec "$CONTAINER" sh -c "du -cb '$PREFIX'-* | tail -n1 | cut -f1" 2>/dev/null || echo 0)"
prog_watch "$WORK.partial" "$(docker exec "$CONTAINER" sh -c "du -cb '$PREFIX'-* | tail -n1 | cut -f1" 2>/dev/null || echo 0)"
for f in $(docker exec "$CONTAINER" sh -c "ls -1 '$PREFIX'-*"); do
  docker cp "$CONTAINER:$f" "$WORK.partial/" >/dev/null 2>&1 || die "docker cp failed for $f"
done
docker exec -u frappe -w "$BENCH" "$CONTAINER" bench version > "$WORK.partial/VERSIONS.txt" 2>&1 || true
echo "$ORIGIN" > "$WORK.partial/ORIGIN.txt"
echo "$SRC_COUNTS" > "$WORK.partial/COUNTS.txt"
echo "$SRC_SANITY" > "$WORK.partial/SANITY.txt"
chmod -R go-rwx "$WORK.partial"

prog_unwatch
prog begin backup "verify the dump" "$STAMP"
set_files "$WORK.partial" || die "backup set incomplete (need database, public files, private files, site_config)"
gzip -t "$WORK.partial/$DBF" || die "database archive is corrupt"
for t in "$PUBF" "$PRIVF"; do tar -tf "$WORK.partial/$t" >/dev/null || die "archive unreadable: $t"; done
[ "$(stat -c %s "$WORK.partial/$DBF")" -gt 102400 ] || die "database dump suspiciously small (<100 KB)"
( cd "$WORK.partial" && sha256sum -- "$DBF" "$PUBF" "$PRIVF" "$CFGF" > MANIFEST.sha256 )
mv "$WORK.partial" "$WORK"

# encrypted archive (public-key encryption; this box cannot decrypt it)
mkdir -p "$ARCH.partial"
ETOT=$(bytes_of "$WORK/$DBF" "$WORK/$PUBF" "$WORK/$PRIVF" "$WORK/$CFGF")
prog begin backup "encrypt (age)" "$STAMP" --total "$ETOT"; prog_watch "$ARCH.partial" "$ETOT"
for f in "$DBF" "$PUBF" "$PRIVF" "$CFGF"; do
  "$AGE" -r "$ARCHIVE_RECIPIENT" -o "$ARCH.partial/$f.age" "$WORK/$f" || die "encryption failed for $f"
  head -c 22 "$ARCH.partial/$f.age" | grep -q '^age-encryption.org/v1' || die "encrypted file has no age header: $f"
done
cp "$WORK/VERSIONS.txt" "$WORK/ORIGIN.txt" "$WORK/COUNTS.txt" "$WORK/SANITY.txt" "$WORK/MANIFEST.sha256" "$ARCH.partial/"
echo "${ARCHIVE_RECIPIENT}" > "$ARCH.partial/RECIPIENT.txt"
prog_unwatch
( cd "$ARCH.partial" && sha256sum -- *.age *.txt MANIFEST.sha256 > SHA256SUMS )
mv "$ARCH.partial" "$ARCH"

# plaintext standby set for the peer (pushed, then deleted); otherwise drop the plaintext now
if [ "$SEND_ENABLED" = 1 ] && { [ "$SEND_STANDBY_SET" = 1 ] || [ -f "$BASE/PROMOTED" ]; }; then
  # the set in work/standby may be the one a running push is sending right now: wait for it to finish
  wait_push_idle "backup.sh replacing the outgoing standby set"
  find "$BASE/work/standby" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
  mv "$WORK" "$BASE/work/standby/$STAMP"
else
  rm -rf "$WORK"
fi
find "$BASE/work" -mindepth 1 -maxdepth 1 -type d ! -name standby -mmin +720 -exec rm -rf {} +

# remove this run's plaintext copy from the container's backup folder
if [ "$PURGE_BENCH_PLAINTEXT" = 1 ]; then docker exec -u frappe "$CONTAINER" sh -c "rm -f '$PREFIX'-*" || log "WARN: could not purge bench copy"; fi

WK="$BASE/own/weekly/$(date +%G-W%V)"
if [ "$(date +%u)" = "$WEEKLY_DOW" ] && [ ! -e "$WK" ]; then cp -al "$ARCH" "$WK"; log "weekly copy linked: $(basename "$WK")"; fi
# monthly: the first good backup of each calendar month (hard link, no extra space until daily pruning)
mkdir -p "$BASE/own/monthly"; MO="$BASE/own/monthly/$(date +%Y-%m)"
if [ ! -e "$MO" ]; then cp -al "$ARCH" "$MO"; log "monthly copy linked: $(basename "$MO")"; fi
find "$BASE/own/daily" -mindepth 1 -maxdepth 1 -type d -name '*.partial' -mmin +720 -exec rm -rf {} +
prune_keep "$BASE/own/daily" "$KEEP_DAILY"
prune_keep "$BASE/own/weekly" "$KEEP_WEEKLY"
prune_keep "$BASE/own/monthly" "${KEEP_MONTHLY:-12}"

SIZE_MB=$(du -sm "$ARCH" | cut -f1)
prog end OK "${SIZE_MB} MB encrypted"
log "OK $STAMP ${SIZE_MB}MB encrypted (origin $ORIGIN)"
status "OK backup $STAMP ${SIZE_MB}MB encrypted origin=$ORIGIN"
state_put backup result=OK at="$(date -Is)" started="$(date -Is -d @"$START")" set="$STAMP" size_mb="$SIZE_MB" encrypted=yes \
  recipient="${ARCHIVE_RECIPIENT:0:12}" origin="$ORIGIN" counts="$SRC_COUNTS" sanity="$SRC_SANITY" location="$(hostname):$ARCH" bench_s="$BENCH_S" duration_s="$(( $(date +%s) - START ))" \
  daily="$(find "$BASE/own/daily" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' ! -name '.*' | wc -l)" \
  weekly="$(find "$BASE/own/weekly" -mindepth 1 -maxdepth 1 -type d | wc -l)" monthly="$(find "$BASE/own/monthly" -mindepth 1 -maxdepth 1 -type d | wc -l)"
report_quiet
EOF_BACKUP

# ---------------------------------------------------------------- push.sh
cat > "$NB/push.sh" <<'EOF_PUSH'
#!/bin/bash
# Push encrypted archives (+ standby set, + receipts, + this box's status) to the peer. Never deletes on the peer.
# Usage: push.sh            # everything
#        push.sh receipts   # only own/receipts (used right after a standby refresh)
#
# TWO PHASES, so the peer can never mistake a half-copied set for a finished one: every file except the
# set's completion marker (SHA256SUMS for archives, MANIFEST.sha256 for the plaintext standby set) goes
# first; the markers go in a second pass, which only happens after the first one succeeded. A transfer that
# is cut off (2026-10-17) leaves a set without its marker, which the receiver skips instead of failing on.
set -euo pipefail
STAGE=push
. "$(dirname "$0")/common.sh"
need_root
MODE="${1:-all}"
if [ "$SEND_ENABLED" != 1 ]; then log "SEND_ENABLED=0, nothing to push"; exit 0; fi
if [ "${PUSH_TRANSPORT:-ssh}" = local ]; then
  [ -n "${PEER_LOCAL_DIR:-}" ] && [ -d "$PEER_LOCAL_DIR" ] || die "PUSH_TRANSPORT=local but PEER_LOCAL_DIR '${PEER_LOCAL_DIR:-}' is not a directory"
  RSYNC_E=()
else
  [ -f "$SSH_KEY" ] && [ -s "$KNOWN_HOSTS" ] || die "send key or known_hosts missing; run setup-send.sh"
  init_ssh; RSYNC_E=(-e "$RSYNC_RSH")
fi
wait_push_idle "push.sh $MODE"
T0=$SECONDS; ATTEMPTS=0; BUSY_WAIT=0
ERRF=$(mktemp); trap 'rm -f "$ERRF"' EXIT
STATSF="$STATE/push-stats.json"; rm -f "$STATSF"
BW=(); [ "${PUSH_BWLIMIT_KBPS:-0}" -gt 0 ] && BW=(--bwlimit="$PUSH_BWLIMIT_KBPS")
PSET=""; PSTEP=""
# up ARGS... : one rsync. --info=progress2/--stats are client-side only (the peer's rrsync never sees them); the
# output feeds progress.py, which keeps state/progress.json current and adds the byte counts to push-stats.json.
up() {
  local rc
  prog begin push "$PSTEP" "$PSET" --total "${PTOTAL:-0}"
  set +e
  rsync -aH --partial --timeout=600 --exclude '*.partial' "${BW[@]}" --info=progress2 --stats "${RSYNC_E[@]}" "$@" 2>"$ERRF" \
    | ERPB_STATE="$STATE" ERPB_ME="$ME" ERPB_REPORT="$(dirname "$0")/report.sh" python3 "$(dirname "$0")/progress.py" rsync "$STATSF"
  rc=${PIPESTATUS[0]}; set -e
  cat "$ERRF" >&2; return "$rc"
}
# try_up ARGS... : up to 3 real attempts. The peer's rrsync refusing because another push is still writing
# there (e.g. one started by an older kit that holds no lock) is NOT a failed attempt: wait and try again.
try_up() {
  local t=1 poll="${PUSH_WAIT_POLL_S:-60}" max=$(( ${PUSH_WAIT_MIN:-300} * 60 ))
  while :; do
    ATTEMPTS=$((ATTEMPTS + 1))
    up "$@" && return 0
    if grep -q "Another instance of rrsync is already accessing" "$ERRF"; then
      [ "$BUSY_WAIT" -ge "$max" ] && { log "$PEER_NAME still busy with another push after ${PUSH_WAIT_MIN:-300} min"; return 1; }
      [ $(( BUSY_WAIT % 300 )) -lt "$poll" ] && log "$PEER_NAME is still receiving another push (its rrsync lock), waiting... ($((BUSY_WAIT / 60)) of ${PUSH_WAIT_MIN:-300} min)"
      sleep "$poll"; BUSY_WAIT=$((BUSY_WAIT + poll)); continue
    fi
    # the peer's rrsync refusing an option or a path is permanent: retrying cannot change it
    if grep -q "rrsync error:" "$ERRF"; then log "$PEER_NAME's rrsync refused this transfer: $(grep -m1 'rrsync error:' "$ERRF" | cut -c1-200)"; return 1; fi
    [ "$t" -ge 3 ] && return 1
    log "attempt $t failed, retrying"; sleep "${PUSH_RETRY_SLEEP:-300}"; t=$((t + 1))
  done
}
share_status() { # this box's status rides along with the receipts, so the peer's ERPNext can watch us too
  bash "$(dirname "$0")/report.sh" >/dev/null 2>&1 || true
  [ -f "$BASE/status.json" ] && cp "$BASE/status.json" "$BASE/own/receipts/status-$ME.json" 2>/dev/null || true
}
mkdir -p "$BASE/own/receipts" "$BASE/own/monthly"
if [ "$MODE" = receipts ]; then
  share_status
  PSET=receipts; PSTEP="receipts"; PTOTAL=0
  try_up "$BASE/own/receipts" "$(peer_dest)" || die "receipt push to $PEER_NAME failed"
  prog end OK receipts; log "OK receipts pushed"; exit 0
fi
share_status
N=$(basename "$(newest_dir "$BASE/own/daily")"); SB=$(newest_dir "$BASE/work/standby"); SBS=no; PSET="$N"
NEWB=$(bytes_of "$BASE/own/daily/$N"); SBB=0; [ -n "$SB" ] && SBB=$(bytes_of "$SB")
# tell the peer first what is coming (a few hundred bytes): its progress.sh / restore test read this
inflight() { printf '{"schema":"erp-backup-inflight/1","box":"%s","state":"%s","set":"%s","archive_bytes":%s,"standby_set":"%s","standby_bytes":%s,"started_at":"%s","updated_at":"%s"}\n' \
  "$ME" "$1" "$N" "$NEWB" "$(basename "${SB:-none}")" "$SBB" "$PSTART" "$(date -Is)" > "$BASE/own/receipts/inflight-$ME.json"; }
PSTART=$(date -Is); inflight sending
PSTEP="notice to $PEER_NAME (0/4)"; PTOTAL=0
try_up "$BASE/own/receipts" "$(peer_dest)" || die "push to $PEER_NAME ($PEER_HOST) failed 3 times ($(link_desc))"
SRC=("$BASE/own/daily" "$BASE/own/weekly" "$BASE/own/monthly" "$BASE/own/receipts")
PSTEP="encrypted archives (1/4)"; PTOTAL="$NEWB"
try_up --exclude SHA256SUMS "${SRC[@]}" "$(peer_dest)" || die "archive push to $PEER_NAME ($PEER_HOST) failed 3 times ($(link_desc))"
PSTEP="archive completion markers (2/4)"; PTOTAL=0
try_up "${SRC[@]}" "$(peer_dest)" || die "archive push to $PEER_NAME: the completion markers did not go (sets stay incomplete there)"
if [ -n "$SB" ]; then
  SN="$(basename "$SB")"; PSTEP="plaintext standby set $SN (3/4)"; PTOTAL="$SBB"
  # DELTA_STANDBY=1: the peer keeps the set it last restored as standby/.basis; rsync matches today's files against
  # it by similar name (-yy with --copy-dest) and sends only what changed - mostly the new photos, not the whole tar.
  # PUSH_TRANSPORT=local has no jail to anchor "/" at, so it gives the basis as a real path.
  # The peer's rrsync may refuse those options: then the set goes in full, as before.
  # (--mkpath creates standby/ on a first push; rsync >= 3.2.3 on both ends, rrsync allows it)
  DELTAOK=0
  if [ "${DELTA_STANDBY:-1}" = 1 ]; then
    # rrsync refuses ".." in --copy-dest; a leading "/" is anchored at the jail root (= RECV_DIR on the peer)
    BASISARG=/standby/.basis; [ "${PUSH_TRANSPORT:-ssh}" = local ] && BASISARG="${PEER_LOCAL_DIR%/}/standby/.basis"
    if try_up --exclude MANIFEST.sha256 --mkpath -yy --copy-dest="$BASISARG" "$SB/" "$(peer_dest "standby/$SN/")"; then DELTAOK=1
    else log "the delta push of the standby set failed or its options were refused; sending it in full"; fi
  fi
  if [ "$DELTAOK" = 1 ]; then
    PSTEP="standby manifest (4/4)"; PTOTAL=0
    try_up --mkpath "$SB/" "$(peer_dest "standby/$SN/")" || die "standby-set push to $PEER_NAME: MANIFEST did not go (set stays incomplete there)"
  else
    try_up --exclude MANIFEST.sha256 "$SB" "$(peer_dest standby/)" || die "standby-set push to $PEER_NAME failed"
    PSTEP="standby manifest (4/4)"; PTOTAL=0
    try_up "$SB" "$(peer_dest standby/)" || die "standby-set push to $PEER_NAME: MANIFEST did not go (set stays incomplete there)"
  fi
  rm -rf "$SB"; SBS=yes
fi
inflight "done"; PSTEP="finish"; PTOTAL=0; try_up "$BASE/own/receipts" "$(peer_dest)" || true
DUR=$((SECONDS - T0))
read -r SENT XFER <<<"$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("bytes_sent",0), d.get("transferred_file_bytes",0))' "$STATSF" 2>/dev/null || echo "0 0")"
RATE=0; [ "$DUR" -gt 0 ] && RATE=$(( SENT / DUR / 1024 ))
prog end OK "$((SENT / 1048576)) MB sent in ${DUR}s (${RATE} KB/s)"
log "OK pushed through $N to $PEER_NAME in ${DUR}s: $((SENT / 1048576)) MB sent at ${RATE} KB/s ($((XFER / 1048576)) MB of file data; standby set as delta: ${DELTAOK:-0}), $ATTEMPTS rsync call(s) (standby set sent: $SBS)"
status "OK push $N -> $PEER_NAME standby=$SBS ${DUR}s attempts=$ATTEMPTS sent=${SENT}B rate=${RATE}KB/s"
state_put push result=OK at="$(date -Is)" set="$N" peer="$PEER_NAME" standby_set_sent="$SBS" duration_s="$DUR" attempts="$ATTEMPTS" transport="${PUSH_TRANSPORT:-ssh}" \
  waited_for_other_push_s="${PUSH_WAITED:-0}" waited_for_peer_s="$BUSY_WAIT" bytes_sent="$SENT" file_bytes="$XFER" rate_kbps="$RATE" \
  new_set_bytes="$NEWB" standby_bytes="$SBB" delta_standby="${DELTAOK:-0}"
report_quiet
EOF_PUSH

# ---------------------------------------------------------------- recv-check.sh
cat > "$NB/recv-check.sh" <<'EOF_CHECK'
#!/bin/bash
# Prune what the peer sent us, then prove the newest COMPLETE encrypted set is fresh and intact (dead-man switch).
# A set without its SHA256SUMS marker is still in transit (or was cut off): it is reported, never trusted.
set -euo pipefail
STAGE=check
. "$(dirname "$0")/common.sh"
need_root
if [ "$RECV_ENABLED" != 1 ]; then log "RECV_ENABLED=0, nothing to check"; exit 0; fi
R="$RECV_DIR"
[ -d "$R/daily" ] || die "nothing received from $PEER_NAME yet ($R/daily missing)"
prune_keep "$R/daily" "$KEEP_DAILY"
prune_keep "$R/weekly" "$KEEP_WEEKLY"
[ -d "$R/monthly" ] && prune_keep "$R/monthly" "${KEEP_MONTHLY:-12}"
STALE_INC=""
if [ -d "$R/standby" ]; then
  # a plaintext standby set without MANIFEST.sha256 for 36 h will never complete (the sender deletes its
  # plaintext after the next backup): drop it, and say so
  for n in $(incomplete_sets "$R/standby" MANIFEST.sha256); do
    if [ "$(dir_age_min "$R/standby/$n")" -ge 2160 ]; then rm -rf "${R:?}/standby/$n"; STALE_INC="$STALE_INC $n"; log "dropped incomplete standby set $n (cut off in transfer)"; fi
  done
  KEEP=$(newest_complete "$R/standby" MANIFEST.sha256)
  # keep the newest complete plaintext set (what a failover refreshes from) and anything newer still arriving
  for d in $(find "$R/standby" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' ! -name '.*' | sort); do
    [ -n "$KEEP" ] && [[ "$(basename "$d")" < "$(basename "$KEEP")" ]] && rm -rf "$d"
  done
  if [ "$ALLOW_STANDBY" != 1 ]; then  # no standby here: drop plaintext sets unless they are our own data (failback)
    for d in "$R"/standby/*/; do [ -d "$d" ] && [ "$(cat "$d/ORIGIN.txt" 2>/dev/null)" != "$ME" ] && rm -rf "$d"; done; true
  fi
fi
NEWEST=$(newest_complete "$R/daily" SHA256SUMS)
[ -n "$NEWEST" ] || die "no complete daily sets from $PEER_NAME"
N=$(basename "$NEWEST")
INC=""; for n in $(incomplete_sets "$R/daily" SHA256SUMS); do [[ "$n" > "$N" ]] && [ "$(dir_age_min "$R/daily/$n")" -ge 360 ] && INC="$INC $n"; done; true  # >6 h without its marker: cut off, not in transit
AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$NEWEST/SHA256SUMS") ) / 3600 ))
[ "$AGE_H" -le "$MAX_AGE_HOURS" ] || die "STALE: newest complete $PEER_NAME set $N is ${AGE_H}h old${INC:+ (incomplete newer:$INC)}"
( cd "$NEWEST" && sha256sum -c --quiet SHA256SUMS ) || die "checksum mismatch in $PEER_NAME set $N"
ls "$NEWEST"/*.age >/dev/null 2>&1 || die "$PEER_NAME set $N is not encrypted"
ND=$(find "$R/daily" -mindepth 1 -maxdepth 1 -type d | wc -l || true)
NW=$(find "$R/weekly" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || true)
NM=$(find "$R/monthly" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || true)
SZ=$(du -sh "$R" | cut -f1)
log "OK $PEER_NAME $N age ${AGE_H}h, ${ND} daily/${NW} weekly/${NM} monthly, $SZ${INC:+, still arriving:$INC}"
status "OK check $PEER_NAME $N age ${AGE_H}h ${ND}d/${NW}w/${NM}m $SZ"
state_put check result=OK at="$(date -Is)" peer="$PEER_NAME" newest_set="$N" age_hours="$AGE_H" daily="$ND" weekly="$NW" monthly="$NM" size="$SZ" encrypted=yes \
  incomplete_newer="${INC# }" dropped_incomplete_standby="${STALE_INC# }"
report_quiet
EOF_CHECK

# ---------------------------------------------------------------- standby-init.sh
cat > "$NB/standby-init.sh" <<'EOF_SINIT'
#!/bin/bash
# ONE-TIME (interactive): create the read-only standby site for the peer's data and load the newest standby set.
set -euo pipefail
STAGE=standby-init
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/lib-site.sh"
need_root
SS="$STANDBY_SITE"; TMPD=/tmp/erp-standby; export TMPD
[ "$SS" != "$SITE" ] || die "standby site name equals production site name"
[ ! -f "$BASE/PROMOTED" ] || die "this box is PROMOTED; no standby while serving the peer's data"
site_exists "$SS" && die "site $SS already exists. The scheduled refresh maintains it (standby-refresh.sh --now to refresh immediately)."
SET=$(newest_complete "$RECV_DIR/standby" MANIFEST.sha256)
[ -n "$SET" ] || die "no complete standby set received from $PEER_NAME yet (run push on $PEER_NAME first)"
( cd "$SET" && sha256sum -c --quiet MANIFEST.sha256 ) || die "standby set checksum mismatch"
set_files "$SET" || die "standby set incomplete"
SETORIGIN=$(cat "$SET/ORIGIN.txt" 2>/dev/null || echo "$PEER_NAME")
if [ "$ALLOW_STANDBY" != 1 ] && [ "$SETORIGIN" != "$ME" ]; then
  die "no standby of $PEER_NAME's data on $ME (ALLOW_STANDBY=0). standby-init here is only for FAILBACK (data origin $ME); this set's origin is $SETORIGIN."
fi
mem_snapshot
if ! mem_ok && [ "${1:-}" != --force ]; then die "low memory: $(mem_desc). Free memory (stop heavy apps in the Umbrel UI) or re-run with --force"; fi
echo "Creating read-only standby site '$SS' on $(hostname) from $PEER_NAME set $(basename "$SET"). $(mem_desc)"
get_dbpw
copy_set_in "$SET"
check_versions "$SET"
new_empty_site "$SS"
readonly_on "$SS"
set_enc_key
T0=$SECONDS
full_restore "$SS"
readonly_on "$SS"
DUR=$((SECONDS - T0))
save_source_conf
cp "$SET/ORIGIN.txt" "$BASE/standby/ORIGIN" 2>/dev/null || echo "$PEER_NAME" > "$BASE/standby/ORIGIN"
export TS="$SS"; run_checks "$SS" "$SET"
clean_tmp
[ "$ALLOW_STANDBY" = 1 ] && setconf STANDBY_ENABLED 1
state_put standby result=OK at="$(date -Is)" site="$SS" set="$(basename "$SET")" origin="$(cat "$BASE/standby/ORIGIN")" duration_s="$DUR" \
  check="$CHK_RESULT" counts_ok="$CHK_COUNTS_OK" files="$CHK_PUBN/$CHK_PUBA,$CHK_PRIVN/$CHK_PRIVA" files_missing="$CHK_MISSING" files_extra="$CHK_EXTRA" secrets="$CHK_SECRETS" decrypt_fail="$CHK_DECRYPT_FAIL" method=full-restore
status "OK standby-init $SS set=$(basename "$SET") ${DUR}s check=$CHK_RESULT"
write_receipt "$(basename "$SET")" "$SS" "$DUR" full-restore
keep_basis "$SET"
if [ "$SEND_ENABLED" = 1 ]; then bash "$(dirname "$0")/push.sh" receipts || true; fi
report_quiet
if [ "$ALLOW_STANDBY" = 1 ]; then echo "Standby '$SS' ready (read-only). STANDBY_ENABLED=1. Now run: sudo bash $BASE/bin/install.sh"
else echo "Failback copy loaded into '$SS' (read-only). Next: sudo bash $BASE/bin/promote-standby.sh"; fi
EOF_SINIT

# ---------------------------------------------------------------- standby-refresh.sh
cat > "$NB/standby-refresh.sh" <<'EOF_SREF'
#!/bin/bash
# NIGHTLY: load the peer's newest standby set into the read-only standby site, verify, report.
# Full "bench restore" into the standby site (Frappe's partial-restore refuses full backups).
# The DB root password is read from the db container's env at runtime (memory only, never stored).
set -euo pipefail
STAGE=standby
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/lib-site.sh"
need_root
trap 'die "unexpected error at line $LINENO"' ERR
# Usage: standby-refresh.sh [--now] [--force] [--wait-min=N]
#   --now ignores the weekly schedule; --force also ignores the memory check;
#   --wait-min=N waits at most N minutes for a set still arriving (default STANDBY_WAIT_MIN; 0 = do not wait).
#   (An option, not an environment variable: the conf is sourced after the environment and would win.)
NOW=0; FORCE=0; WAITMIN_ARG=""
for a in "$@"; do case "$a" in --now) NOW=1;; --force) NOW=1; FORCE=1;; --wait-min=*) WAITMIN_ARG="${a#--wait-min=}";; *) die "unknown option $a";; esac; done
[ -z "$WAITMIN_ARG" ] || [[ "$WAITMIN_ARG" =~ ^[0-9]+$ ]] || die "--wait-min needs a number of minutes"
if [ "$STANDBY_ENABLED" != 1 ]; then log "STANDBY_ENABLED=0, skipping"; exit 0; fi
if [ -f "$BASE/PROMOTED" ]; then log "box is PROMOTED; standby refresh disabled"; exit 0; fi
if [ "$NOW" != 1 ] && ! standby_due; then log "standby refresh not due (STANDBY_EVERY=$STANDBY_EVERY, day $STANDBY_DAY; last $(state_get standby at))"; exit 0; fi
exec 9>"$BASE/.standby.lock"; flock -n 9 || die "another standby refresh is running"
SS="$STANDBY_SITE"; TMPD=/tmp/erp-standby; export TMPD TS="$SS"
site_exists "$SS" || die "standby site $SS missing; run standby-init.sh"
# Pick the newest COMPLETE set (MANIFEST.sha256 present; push.sh sends it last). If a newer set is still
# arriving, wait for it (up to STANDBY_WAIT_MIN) rather than restoring yesterday's or failing on a half copy.
LAST="$(state_get standby set)"
WAITED=0; WAIT_MAX=$(( ${WAITMIN_ARG:-${STANDBY_WAIT_MIN:-240}} * 60 ))
while :; do
  SET=$(newest_complete "$RECV_DIR/standby" MANIFEST.sha256)
  ARRIVING=""; for n in $(incomplete_sets "$RECV_DIR/standby" MANIFEST.sha256); do
    if [ -z "$SET" ] || [[ "$n" > "$(basename "$SET")" ]]; then [ "$(dir_age_min "$RECV_DIR/standby/$n")" -lt 2160 ] && ARRIVING="$ARRIVING $n"; fi
  done
  # the peer announces a push before its first byte (receipts/inflight-<peer>.json): a set it is still sending
  # counts as arriving even while the encrypted archives go first and its standby folder does not exist yet
  ANN=$(python3 -c 'import json,sys,datetime as dt
d=json.load(open(sys.argv[1])); t=dt.datetime.fromisoformat(d.get("updated_at") or d["started_at"])
ok=d.get("state")=="sending" and (dt.datetime.now().astimezone()-t).total_seconds() < 8*3600
print(d.get("standby_set","") if ok else "")' "$RECV_DIR/receipts/inflight-$PEER_NAME.json" 2>/dev/null || true)
  if [ -n "$ANN" ] && [ "$ANN" != none ] && { [ -z "$SET" ] || [[ "$ANN" > "$(basename "$SET")" ]]; } && [[ " $ARRIVING " != *" $ANN "* ]]; then ARRIVING="$ARRIVING $ANN(announced)"; fi
  [ -n "$ARRIVING" ] && [ "$WAITED" -lt "$WAIT_MAX" ] || break
  if [ $(( WAITED % 900 )) -lt "${STANDBY_WAIT_POLL_S:-300}" ]; then log "a newer standby set is still arriving:$ARRIVING; waiting (${WAITED}s of ${WAIT_MAX}s)"; fi
  prog begin "restore test" "waiting for $PEER_NAME's push to finish" "${ARRIVING# }" --expect "$WAIT_MAX"
  sleep "${STANDBY_WAIT_POLL_S:-300}"; WAITED=$((WAITED + ${STANDBY_WAIT_POLL_S:-300}))
done
SKIPPED="$(incomplete_sets "$RECV_DIR/standby" MANIFEST.sha256 | tr '\n' ' ')"; SKIPPED="${SKIPPED% }"
[ -n "$SKIPPED" ] && log "skipping incomplete standby set(s): $SKIPPED"
if [ -z "$SET" ]; then
  [ -n "$LAST" ] || die "no complete standby set from $PEER_NAME${SKIPPED:+ (incomplete: $SKIPPED)}"
  log "no new complete standby set; standby stays at $LAST"; report_quiet; exit 0
fi
SN=$(basename "$SET")
if [ "$SN" = "$LAST" ] && [ "$(state_get standby result)" = OK ] && [ "$(state_get standby check)" = Pass ]; then log "standby already at $SN (check Pass)"; rm -f "$STATE/standby_defer.env"; exit 0; fi
[ -z "$LAST" ] || [ "$LAST" = none ] || ! [[ "$SN" < "$LAST" ]] || die "newest complete standby set $SN is older than the one already loaded ($LAST)"
# memory pre-flight: never start a restore that would push the box into swap thrash
if [ "$FORCE" != 1 ] && ! mem_ok; then
  log "low memory: $(mem_desc)"
  if stop_apps; then mem_ok || defer_standby "low memory even after stopping apps:$STOPPED_APPS - $(mem_desc)"
  else defer_standby "low memory - $(mem_desc)"; fi
fi
mem_snapshot; log "memory ok: $(mem_desc)"
( cd "$SET" && sha256sum -c --quiet MANIFEST.sha256 ) || die "standby set $SN checksum mismatch"
set_files "$SET" || die "standby set $SN incomplete"
check_versions "$SET"
get_dbpw
prog begin "restore test" "copy set into the ERPNext container" "$SN" --total "$(bytes_of "$SET")"
copy_set_in "$SET"
readonly_on "$SS"
set_enc_key
wipe_standby_files
prog begin "restore test" "bench restore into $SS" "$SN" --expect "$(state_get standby restore_s)"
T0=$SECONDS
RLOG="$STATE/standby-restore.log"
if ! bx sh -c 'bench --site "$TS" restore "$TMPD/$DBF" --with-public-files "$TMPD/$PUBF" --with-private-files "$TMPD/$PRIVF" --db-root-password "$DBPW"' </dev/null > "$RLOG" 2>&1; then
  die "bench restore into $SS failed: $(grep -v '^\s*$' "$RLOG" | tail -n 3 | tr '\n' ' ' | cut -c1-300) (full log: $RLOG)"
fi
set_enc_key
bx bench --site "$SS" clear-cache >/dev/null || true
readonly_on "$SS"
DUR=$((SECONDS - T0))
prog begin "restore test" "checks (counts, sanity, files, secrets)" "$SN"
save_source_conf
cp "$SET/ORIGIN.txt" "$BASE/standby/ORIGIN" 2>/dev/null || echo "$PEER_NAME" > "$BASE/standby/ORIGIN"
run_checks "$SS" "$SET"
clean_tmp
keep_basis "$SET"
R="$CHK_RESULT"
rm -f "$STATE/standby_defer.env"
state_put standby result=OK at="$(date -Is)" site="$SS" set="$SN" origin="$(cat "$BASE/standby/ORIGIN")" duration_s="$DUR" \
  every="$STANDBY_EVERY" mem_avail_mb_at_start="$MEM_AVAIL_MB" apps_stopped="${STOPPED_APPS# }" check="$R" counts_ok="$CHK_COUNTS_OK" counts="$CHK_COUNTS" src_counts="$CHK_SRC_COUNTS" files="$CHK_PUBN/$CHK_PUBA,$CHK_PRIVN/$CHK_PRIVA" files_missing="$CHK_MISSING" files_extra="$CHK_EXTRA" \
  secrets="$CHK_SECRETS" decrypt_fail="$CHK_DECRYPT_FAIL" sanity="$CHK_SANITY" src_sanity="$CHK_SRC_SANITY" sanity_ok="$CHK_SANITY_OK" \
  skipped_incomplete="$SKIPPED" waited_s="$WAITED" restore_s="$DUR" method=full-restore readonly=yes job=OK
write_receipt "$SN" "$SS" "$DUR" full-restore
prog end "$R" "restored in ${DUR}s"
[ "$R" = Pass ] && status "OK standby $SN ${DUR}s check=Pass" || { status "WARN standby $SN ${DUR}s check=$R"; notify "standby check $R for $SN"; }
log "standby $SS refreshed to $SN in ${DUR}s, check=$R"
[ "$SEND_ENABLED" = 1 ] && bash "$(dirname "$0")/push.sh" receipts || true
report_quiet
EOF_SREF

# ---------------------------------------------------------------- archive-test.sh
cat > "$NB/archive-test.sh" <<'EOF_ATEST'
#!/bin/bash
# Prove the ENCRYPTED archive is (a) useless without Tim's key and (b) fully restorable with it.
# Restores into throwaway site "restoretest" on THIS box, then drops it. Key is pasted, held in memory only.
# Usage: sudo bash archive-test.sh peer|own [SET]
set -euo pipefail
STAGE=archive-test
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/lib-site.sh"
need_root
trap 'die "unexpected error at line $LINENO"' ERR
[ "$ALLOW_ARCHIVE_TEST" = 1 ] || die "archive tests disabled on this box (ALLOW_ARCHIVE_TEST=0)"
[ -z "$(primary_host)" ] || [ "$(hostname)" != "$(primary_host)" ] || die "never run archive restore tests on the primary ($(primary_host))"
TMPD=/tmp/erp-restore; export TMPD TS=restoretest
case "${1:-}" in peer) SRC="$RECV_DIR";; own) SRC="$BASE/own";; *) echo "Usage: sudo bash $0 peer|own [SET]"; exit 1;; esac
SET="$SRC/daily/${2:-$(basename "$(newest_dir "$SRC/daily")")}"
[ -f "$SET/SHA256SUMS" ] || die "no such set: $SET"
site_exists restoretest && die "site restoretest already exists (leftover). Drop it: sudo bash $(dirname "$0")/drop-restoretest.sh"
REPORT="$BASE/restore-tests/$(date +%F_%H%M)-archive-$1-$(basename "$SET").txt"
exec > >(tee -a "$REPORT") 2>&1
echo "===== ARCHIVE TEST on $(hostname): $SET -> restoretest, $(date -Is)"
( cd "$SET" && sha256sum -c --quiet SHA256SUMS ) || die "archive checksum mismatch"
DBA=$(ls "$SET"/*-database.sql.gz.age | head -n1)

echo "--- A. without the key, decryption must FAIL"
if "$AGE" -d -o /dev/null "$DBA" >/dev/null 2>&1; then die "decrypted WITHOUT any identity"; fi
WRONG=$(mktemp); "$(dirname "$AGE")/age-keygen" 2>/dev/null > "$WRONG" || die "age-keygen not found next to age"
if "$AGE" -d -i "$WRONG" -o /dev/null "$DBA" >/dev/null 2>&1; then rm -f "$WRONG"; die "decrypted with a WRONG key"; fi
rm -f "$WRONG"
echo "no key: refused. wrong key: refused.  -> PASS"
NOKEY=Pass

echo "--- B. with Tim's key (paste AGE-SECRET-KEY-1..., hidden; kept in memory only)"
read -rsp "age secret key: " KEY; echo
[[ "$KEY" =~ ^AGE-SECRET-KEY-1[0-9A-Z]{58}$ ]] || die "that is not an age secret key"
PLAIN="$BASE/work/archive-test"; rm -rf "$PLAIN"; mkdir -p "$PLAIN"; trap 'rm -rf "$PLAIN"' EXIT
for f in "$SET"/*.age; do "$AGE" -d -i <(printf '%s\n' "$KEY") -o "$PLAIN/$(basename "${f%.age}")" "$f" || die "decrypt failed: $f"; done
unset KEY
cp "$SET/COUNTS.txt" "$SET/VERSIONS.txt" "$SET/ORIGIN.txt" "$PLAIN/" 2>/dev/null || true
( cd "$PLAIN" && sha256sum -c --quiet "$SET/MANIFEST.sha256" ) || die "decrypted files do not match the original checksums"
echo "decrypted, plaintext matches original checksums"
set_files "$PLAIN" || die "decrypted set incomplete"

echo "--- C. restore into throwaway site restoretest"
echo "source:"; sed 's/^/  /' "$PLAIN/VERSIONS.txt"; echo "this bench:"; docker exec -u frappe -w "$BENCH" "$CONTAINER" bench version | sed 's/^/  /'
get_dbpw
copy_set_in "$PLAIN"
new_empty_site restoretest
readonly_on restoretest
set_enc_key
T0=$SECONDS; full_restore restoretest; DUR=$((SECONDS - T0)); readonly_on restoretest
run_checks restoretest "$PLAIN"
clean_tmp
RES="$CHK_RESULT"
echo
echo "SUMMARY set=$(basename "$SET") no_key_test=$NOKEY restore_minutes=$(( (DUR+59)/60 )) result=$RES"
state_put archive_test result=OK at="$(date -Is)" set="$(basename "$SET")" source="$1" no_key_test="$NOKEY" duration_s="$DUR" check="$RES" \
  counts_ok="$CHK_COUNTS_OK" files="$CHK_PUBN/$CHK_PUBA,$CHK_PRIVN/$CHK_PRIVA" files_missing="$CHK_MISSING" files_extra="$CHK_EXTRA" decrypt_fail="$CHK_DECRYPT_FAIL"
status "OK archive-test $(basename "$SET") ${DUR}s nokey=$NOKEY check=$RES"
report_quiet
read -rp "Drop restoretest now? [Y/n] " A
if [ "${A:-Y}" != n ] && [ "${A:-Y}" != N ]; then drop_test_site restoretest; echo "dropped"; fi
echo "Report: $REPORT"
EOF_ATEST

cat > "$NB/drop-restoretest.sh" <<'EOF_DROP'
#!/bin/bash
set -euo pipefail
STAGE=drop
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/lib-site.sh"
need_root
site_exists restoretest || { echo "no restoretest site"; exit 0; }
get_dbpw; drop_test_site restoretest; docker exec -u root "$CONTAINER" rm -rf /tmp/erp-restore; echo "dropped restoretest"
EOF_DROP

# ---------------------------------------------------------------- fence.sh
cat > "$NB/fence.sh" <<'EOF_FENCE'
#!/bin/bash
# fence.sh on  : put THIS box's production site into read-only mode (reads OK, no writes/scheduler/email)
# fence.sh off : back to normal
set -euo pipefail
STAGE=fence
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/lib-site.sh"
need_root
export TS="$SITE"
case "${1:-}" in
  on)  fence_ro "$SITE";  touch "$BASE/FENCED";  status "OK fence on";  echo "$SITE on $(hostname) is now READ-ONLY." ;;
  off) readonly_off "$SITE"; rm -f "$BASE/FENCED"; status "OK fence off"; echo "$SITE on $(hostname) is writable again." ;;
  *) echo "Usage: sudo bash $0 on|off"; exit 1 ;;
esac
report_quiet
EOF_FENCE

# ---------------------------------------------------------------- promote-standby.sh
cat > "$NB/promote-standby.sh" <<'EOF_PROMOTE'
#!/bin/bash
# FAILOVER / FAILBACK: make the standby site this box's live "frontend".
#   standby site  -> frontend            (now served at this box's ERPNext URL)
#   old frontend  -> frontend.parked-<stamp>  (kept, read-only, scheduler off)
set -euo pipefail
STAGE=promote
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/lib-site.sh"
need_root
SS="$STANDBY_SITE"; STAMP=$(date +%Y%m%d%H%M)
ORIGIN=$(cat "$BASE/standby/ORIGIN" 2>/dev/null || echo unknown)
site_exists "$SS" || die "no standby site $SS on this box"
if [ "$ORIGIN" = "$ME" ]; then KIND=failback
elif [ "$PROMOTE_ALLOWED" = 1 ]; then KIND=failover
else die "PROMOTE_ALLOWED=0 on $ME: promoting $ORIGIN's data here would replace this box's own production. See runbook."; fi
[ ! -f "$BASE/PROMOTED" ] || die "already PROMOTED ($(cat "$BASE/PROMOTED" | tr '\n' ' '))"

echo "===== PROMOTE ($KIND) on $(hostname)"
echo "standby site : $SS  (data of: $ORIGIN)"
echo "standby state: set=$(state_get standby set) at=$(state_get standby at) check=$(state_get standby check)"
echo "this box's current $SITE will be parked as $SITE.parked-$STAMP (not deleted)."
if [ "$KIND" = failover ]; then
  if peer_reachable; then echo "WARNING: $PEER_NAME ($PEER_HOST) still answers on Tailscale. If its ERPNext is still in use you will get SPLIT-BRAIN."; confirm_word "PEER-IS-DOWN"; fi
fi
confirm_word "PROMOTE"

export TS="$SITE"
log "safety backup of current $SITE"; bash "$(dirname "$0")/backup.sh" || log "WARN: safety backup failed (continuing; old site is parked, not deleted)"
readonly_on "$SITE"
docker exec -u frappe "$CONTAINER" sh -c "cd '$BENCH/sites' && mv '$SITE' '$SITE.parked-$STAMP' && mv '$SS' '$SITE'" || die "site swap failed"
export TS="$SITE"
# re-apply the source's non-DB settings, then make it live
if [ -s "$BASE/standby/source-config.json" ]; then
  docker cp "$BASE/standby/source-config.json" "$CONTAINER:/tmp/erp-source-config.json" >/dev/null 2>&1
  docker exec -u root "$CONTAINER" chown frappe /tmp/erp-source-config.json
  bx python3 - <<'PY'
import json, subprocess, os
c = json.load(open("/tmp/erp-source-config.json"))
for k, v in c.items():
    subprocess.run(["bench", "--site", os.environ["TS"], "set-config", "-p", k, json.dumps(v)], check=True, stdout=subprocess.DEVNULL)
os.remove("/tmp/erp-source-config.json")
PY
fi
readonly_off "$SITE"
grep -q '"mute_emails"' "$BASE/standby/source-config.json" 2>/dev/null || bx bench --site "$SITE" set-config -p mute_emails 0 >/dev/null
bx bench --site "$SITE" clear-cache >/dev/null || true
bx bench --site "$SITE" clear-website-cache >/dev/null || true
if [ "$KIND" = failback ]; then
  # this box's stale copy becomes the standby slot again (next refresh overwrites it with the peer's data)
  if [ "$ALLOW_STANDBY" = 1 ]; then
    docker exec -u frappe "$CONTAINER" sh -c "cd '$BENCH/sites' && mv '$SITE.parked-$STAMP' '$SS'"
    readonly_on "$SS"; state_put standby result=STALE at="$(date -Is)" site="$SS" set=none check=none
  else
    docker exec -u frappe "$CONTAINER" sh -c "cd '$BENCH/sites' && mv '$SITE.parked-$STAMP' '$SITE.stale-$STAMP'"
    readonly_on "$SITE.stale-$STAMP"; setconf STANDBY_ENABLED 0; rm -f "$STATE/standby.env"
    log "stale copy kept read-only as $SITE.stale-$STAMP (drop it later with bench drop-site)"
  fi
  rm -f "$BASE/FENCED"
  status "OK promote failback: $ORIGIN data is live as $SITE"
  echo "FAILBACK done: $SITE on $(hostname) now serves the latest data."
else
  printf 'ORIGIN=%s\nAT=%s\nPARKED=%s\nSET=%s\n' "$ORIGIN" "$(date -Is)" "$SITE.parked-$STAMP" "$(state_get standby set)" > "$BASE/PROMOTED"
  status "OK promote failover: $ORIGIN data is live as $SITE; own site parked as $SITE.parked-$STAMP"
  notify "PROMOTED: $(hostname) now serves $ORIGIN's ERPNext"
  echo "FAILOVER done: $SITE on $(hostname) now serves $ORIGIN's data. Next: runbook section 'Point users at the survivor'."
fi
report_quiet
EOF_PROMOTE

# ---------------------------------------------------------------- demote.sh
cat > "$NB/demote.sh" <<'EOF_DEMOTE'
#!/bin/bash
# After FAILBACK completed on the peer: give this box its own site back.
#   frontend (peer's data)          -> standby site (read-only; nightly refresh resumes)
#   frontend.parked-<stamp> (own)   -> frontend
set -euo pipefail
STAGE=demote
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/lib-site.sh"
need_root
[ -f "$BASE/PROMOTED" ] || die "this box is not PROMOTED"
PARKED=$(sed -n 's/^PARKED=//p' "$BASE/PROMOTED"); SS="$STANDBY_SITE"
site_exists "$PARKED" || die "parked site $PARKED not found"
site_exists "$SS" && die "a site named $SS already exists"
echo "Will move: $SITE (=$PEER_NAME data) -> $SS (read-only standby);  $PARKED -> $SITE (this box's own data)."
echo "Only do this AFTER the peer has finished failback and is serving users."
confirm_word "DEMOTE"
export TS="$SITE"; readonly_on "$SITE"
docker exec -u frappe "$CONTAINER" sh -c "cd '$BENCH/sites' && mv '$SITE' '$SS' && mv '$PARKED' '$SITE'" || die "site swap failed"
export TS="$SITE"; readonly_off "$SITE"; bx bench --site "$SITE" set-config -p mute_emails 0 >/dev/null || true
bx bench --site "$SITE" clear-cache >/dev/null || true
export TS="$SS"; readonly_on "$SS"
rm -f "$BASE/PROMOTED" "$BASE/FENCED"
state_put standby result=STALE at="$(date -Is)" site="$SS" set=none check=none
status "OK demote: own site restored; $SS is standby again"
report_quiet
echo "Done. $SITE on $(hostname) is this box's own site again; $SS will be refreshed tonight."
EOF_DEMOTE

# ---------------------------------------------------------------- setup-send.sh
cat > "$NB/setup-send.sh" <<'EOF_SSEND'
#!/bin/bash
# Make this box a SENDER: create its push key, pin the peer's host key, print the one line to copy.
set -euo pipefail
STAGE=setup-send
. "$(dirname "$0")/common.sh"
need_root
for t in rsync ssh ssh-keygen flock sha256sum python3; do command -v "$t" >/dev/null || die "missing tool on this box: $t"; done
[ -f "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "erp-backup-$ME" -f "$SSH_KEY"
echo "tailnet path: $(link_desc)"
[ "$(link_mode)" != none ] || die "no tailscale0 interface and no running Tailscale container found (set TS_CONTAINER in erp-backup.conf)"
BANNER=$(peer_banner)
[[ "$BANNER" == SSH-* ]] || die "cannot reach $PEER_NAME ($PEER_HOST) port 22 via $(link_desc)"
echo "peer sshd answers: $BANNER"
rm -f "$KNOWN_HOSTS.new"
PX=$(ssh_proxy); PXA=(); [ -n "$PX" ] && PXA=(-o "ProxyCommand=$PX")
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS.new" -o HostKeyAlgorithms=ssh-ed25519 \
    -o PreferredAuthentications=none -o ConnectTimeout=20 "${PXA[@]}" "$PEER_USER@$PEER_HOST" true >/dev/null 2>&1 || true
[ -s "$KNOWN_HOSTS.new" ] || { rm -f "$KNOWN_HOSTS.new"; die "reached $PEER_NAME but could not read its ed25519 host key"; }
mv "$KNOWN_HOSTS.new" "$KNOWN_HOSTS"
setconf SEND_ENABLED 1
echo
echo "== $PEER_NAME host key as seen from here (must match what setup-recv.sh prints on $PEER_NAME):"
ssh-keygen -lf "$KNOWN_HOSTS"
echo
echo "== COPY THIS ONE LINE and paste it into setup-recv.sh on $PEER_NAME:"
echo
echo "$(cut -d' ' -f1,2 "$SSH_KEY.pub") erp-backup-$ME"
echo
EOF_SSEND

# ---------------------------------------------------------------- setup-recv.sh
cat > "$NB/setup-recv.sh" <<'EOF_SRECV'
#!/bin/bash
# Make this box a RECEIVER for the peer: separate write-only folder + restricted key.
# Optional: --from=IP[,IP]  (default: the peer's Tailscale IP)
set -euo pipefail
STAGE=setup-recv
. "$(dirname "$0")/common.sh"
need_root
FROM=""
for a in "$@"; do case "$a" in --from=*) FROM="${a#--from=}";; *) die "unknown option $a";; esac; done
# What does sshd see as the source of tailnet SSH? With Umbrel's userspace Tailscale the container forwards
# inbound tailnet connections to the host's sshd from loopback, so from="<peer tailnet IP>" would never match.
SEEN=$(ss -Htn state established '( sport = :22 )' 2>/dev/null | awk '{print $4}' | sed -E 's/:[0-9]+$//; s/^\[//; s/\]$//; s/^::ffff://' | sort -u | tr '\n' ' ')
echo "current SSH sessions to this box arrive from: ${SEEN:-none seen}"
if [ -z "$FROM" ]; then
  if ip -4 addr show tailscale0 >/dev/null 2>&1 && ! grep -qE '(^| )(127\.0\.0\.1|::1)( |$)' <<<"$SEEN"; then
    FROM="$PEER_HOST"
  else
    FROM="127.0.0.1,::1,$PEER_HOST"
    echo "NOTE: Tailscale here is userspace (no tailscale0) or forwards via loopback, so the peer arrives as 127.0.0.1."
    echo "      from= allows 127.0.0.1,::1,$PEER_HOST. The key is still required and still write-only."
  fi
fi
command -v rsync >/dev/null || die "rsync is not installed on this box"
RRSYNC=$(command -v rrsync || true)
[ -n "$RRSYNC" ] || die "rrsync not found (expected /usr/bin/rrsync from the rsync package)"
if head -n1 "$RRSYNC" | grep -q python; then command -v python3 >/dev/null || die "rrsync needs python3"; fi
RROPTS="-wo"; RRHELP=$("$RRSYNC" -h 2>&1 || true)
[[ "$RRHELP" == *-no-del* ]] && RROPTS="-wo -no-del"
mkdir -p "$RECV_DIR"; chown umbrel:umbrel "$RECV_DIR"; chmod 700 "$RECV_DIR"
echo "Paste the ONE line printed by setup-send.sh on $PEER_NAME, then press Enter:"
read -r LINE
KT=$(awk '{print $1}' <<<"$LINE"); KB=$(awk '{print $2}' <<<"$LINE")
[ "$KT" = ssh-ed25519 ] && [[ "$KB" =~ ^AAAA[A-Za-z0-9+/]+=*$ ]] || die "that is not an ssh-ed25519 public key line"
AK="$UMBREL_HOME/.ssh/authorized_keys"
install -d -o umbrel -g umbrel -m 700 "$UMBREL_HOME/.ssh"
touch "$AK"; chown umbrel:umbrel "$AK"; chmod 600 "$AK"
TAG="erp-backup-from-$PEER_NAME"
sed -i "/ $TAG\$/d" "$AK"
echo "from=\"$FROM\",restrict,command=\"$RRSYNC $RROPTS $RECV_DIR\" $KT $KB $TAG" >> "$AK"
setconf RECV_ENABLED 1
status "OK setup-recv $PEER_NAME from=$FROM"
state_put recv_auth result=OK at="$(date -Is)" from="$FROM" seen="$SEEN"
echo
echo "== Authorized $PEER_NAME (from $FROM) to WRITE ONLY into $RECV_DIR ($RROPTS)."
echo "== This box's host key (must match what setup-send.sh printed on $PEER_NAME):"
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
EOF_SRECV

# ---------------------------------------------------------------- link-test.sh
cat > "$NB/link-test.sh" <<'EOF_LTEST'
#!/bin/bash
# Sender-side check of the path to the peer: reachability, pinned host key, and that the key is jailed (write-only).
set -euo pipefail
STAGE=link-test
. "$(dirname "$0")/common.sh"
need_root
echo "tailnet path: $(link_desc)"
B=$(peer_banner); [[ "$B" == SSH-* ]] && echo "PASS reach: $PEER_NAME sshd answers ($B)" || die "cannot reach $PEER_NAME ($PEER_HOST) port 22"
[ -f "$SSH_KEY" ] && [ -s "$KNOWN_HOSTS" ] || die "no send key / pinned host key; run setup-send.sh"
init_ssh
OUT=$(ssh "${SSH_ARGS[@]}" "$PEER_USER@$PEER_HOST" ls / 2>&1 || true)
if grep -qiE 'rrsync|SSH_ORIGINAL_COMMAND|not.*rsync' <<<"$OUT"; then echo "PASS jail: key accepted, but only rrsync may run (shell refused)"
elif grep -qiE 'permission denied|not from a permitted host' <<<"$OUT"; then die "key REFUSED by $PEER_NAME (check setup-recv / from= on $PEER_NAME): $OUT"
elif grep -qE '^(bin|etc|home|usr)$' <<<"$OUT"; then die "DANGER: got a shell listing on $PEER_NAME - key is not restricted"
else die "unexpected answer from $PEER_NAME: $OUT"; fi
echo "--- path to $PEER_NAME (tailscale status / ping)"
LP=$(link_probe); echo "$LP" | sed 's/^/  /'
case "$(sed -n 's/^path=//p' <<<"$LP")" in
  direct) echo "PASS path: direct ($(sed -n 's/^endpoint=//p' <<<"$LP"))" ;;
  derp)   echo "WARN path: relayed through DERP $(sed -n 's/^derp=//p' <<<"$LP") - pushes run at relay speed (~1 Mbit/s); see the deploy notes for getting a direct path" ;;
  *)      echo "WARN path: unknown (could not read tailscale status)" ;;
esac
[ "$(sed -n 's/^tun=//p' <<<"$LP")" = no ] && echo "NOTE tailscaled runs with userspace networking (netstack): fine for tens of Mbit/s, not the cause of a ~1 Mbit/s push"
R=$(state_get push rate_kbps); [ -n "$R" ] && echo "last push: $(state_get push bytes_sent) bytes in $(state_get push duration_s) s = ${R} KB/s"
# shellcheck disable=SC2046
state_put link at="$(date -Is)" $(tr '\n' ' ' <<<"$LP") last_push_rate_kbps="$R"
status "OK link-test $PEER_NAME $(link_desc) path=$(sed -n 's/^path=//p' <<<"$LP")"
EOF_LTEST

# ---------------------------------------------------------------- offsite.sh (optional second target)
cat > "$NB/offsite.sh" <<'EOF_OFFSITE'
#!/bin/bash
# A second copy of THIS box's ENCRYPTED archives (never plaintext) somewhere other than the peer:
#   TARGET2_KIND=dir     TARGET2_PATH=<a mount point>   (an SMB/NFS share or USB disk mounted on this box;
#                        refuses to write when nothing is mounted there, unless TARGET2_REQUIRE_MOUNT=0)
#   TARGET2_KIND=rclone  TARGET2_PATH=<remote>:<path>   (any rclone backend - smb, s3, b2, drive ...; rclone runs as
#                        the pinned RCLONE_IMAGE container; its credentials live only in RCLONE_CONFIG_DIR on this
#                        box, created interactively by: sudo bash offsite.sh config)
# Same retention as own/ (KEEP_DAILY / KEEP_WEEKLY / KEEP_MONTHLY). Same two-phase copy as push.sh.
# Usage: offsite.sh | offsite.sh config | offsite.sh list
set -euo pipefail
STAGE=offsite
. "$(dirname "$0")/common.sh"
need_root
rc() { docker run --rm -v "$RCLONE_CONFIG_DIR:/config/rclone" -v "$BASE/own:/data:ro" "$RCLONE_IMAGE" "$@"; }
case "${1:-run}" in
  config) mkdir -p "$RCLONE_CONFIG_DIR"; chmod 700 "$RCLONE_CONFIG_DIR"
          docker run --rm -it -v "$RCLONE_CONFIG_DIR:/config/rclone" "$RCLONE_IMAGE" config; exit 0 ;;
  list)   [ "$TARGET2_KIND" = rclone ] && rc lsf --dirs-only "${TARGET2_PATH%/}/$ME/daily" || ls -1 "${TARGET2_PATH%/}/$ME/daily"; exit 0 ;;
  run) ;;
  *) echo "Usage: sudo bash $0 [config|list]"; exit 1 ;;
esac
case "${TARGET2_KIND:-none}" in none) log "TARGET2_KIND=none, nothing to do"; exit 0;; dir|rclone) ;; *) die "unknown TARGET2_KIND '$TARGET2_KIND' (none|dir|rclone)";; esac
[ -n "${TARGET2_PATH:-}" ] || die "TARGET2_PATH is empty"
exec 9>"$BASE/.offsite.lock"; flock -n 9 || die "another offsite copy is running"
T0=$SECONDS
NEWEST=$(newest_complete "$BASE/own/daily" SHA256SUMS); [ -n "$NEWEST" ] || die "no complete own archive to copy yet"
N=$(basename "$NEWEST"); D="${TARGET2_PATH%/}/$ME"
prog begin offsite "copy to $TARGET2_KIND target" "$N" --expect "$(state_get offsite duration_s)"
if [ "$TARGET2_KIND" = dir ]; then
  if [ "${TARGET2_REQUIRE_MOUNT:-1}" = 1 ]; then mountpoint -q "$TARGET2_PATH" || die "$TARGET2_PATH is not mounted (refusing to fill the local disk; mount it, or set TARGET2_REQUIRE_MOUNT=0)"; fi
  mkdir -p "$D"
  for k in daily weekly monthly; do
    [ -d "$BASE/own/$k" ] || continue
    rsync -rlt --exclude '*.partial' --exclude SHA256SUMS "$BASE/own/$k" "$D/" || die "copy of $k to $D failed"
    rsync -rlt --exclude '*.partial' "$BASE/own/$k" "$D/" || die "copy of $k markers to $D failed"
    prune_keep "$D/$k" "$(case $k in daily) echo "$KEEP_DAILY";; weekly) echo "$KEEP_WEEKLY";; monthly) echo "${KEEP_MONTHLY:-12}";; esac)"
  done
  ( cd "$D/daily/$N" && sha256sum -c --quiet SHA256SUMS ) || die "copy of $N on $D does not match its checksums"
  SIZE=$(du -sh "$D" | cut -f1)
else
  [ -f "$RCLONE_CONFIG_DIR/rclone.conf" ] || die "no rclone.conf in $RCLONE_CONFIG_DIR (run: sudo bash $(dirname "$0")/offsite.sh config)"
  for k in daily weekly monthly; do
    [ -d "$BASE/own/$k" ] || continue
    rc copy "/data/$k" "$D/$k" --exclude '*.partial/**' --exclude 'SHA256SUMS' --quiet || die "rclone copy of $k failed"
    rc copy "/data/$k" "$D/$k" --exclude '*.partial/**' --quiet || die "rclone copy of $k markers failed"
    KEEPN=$(case $k in daily) echo "$KEEP_DAILY";; weekly) echo "$KEEP_WEEKLY";; monthly) echo "${KEEP_MONTHLY:-12}";; esac)
    for x in $(rc lsf --dirs-only "$D/$k" 2>/dev/null | sed 's|/$||' | sort | head -n -"$KEEPN"); do rc purge "$D/$k/$x" --quiet || log "WARN: could not prune $k/$x"; done
  done
  rc check "/data/daily/$N" "$D/daily/$N" --one-way --quiet || die "copy of $N on $TARGET2_PATH does not match (rclone check)"
  SIZE=$(rc size "$D" --json 2>/dev/null | python3 -c 'import json,sys; print("%dM" % (json.load(sys.stdin)["bytes"] // 1000000))' || echo "?")
fi
DUR=$((SECONDS - T0))
prog end OK "$SIZE there"
log "OK $N copied to $TARGET2_KIND target in ${DUR}s ($SIZE there)"
status "OK offsite $N $TARGET2_KIND ${DUR}s $SIZE"
state_put offsite result=OK at="$(date -Is)" set="$N" kind="$TARGET2_KIND" target="$TARGET2_PATH" duration_s="$DUR" size="$SIZE"
report_quiet
EOF_OFFSITE

# ---------------------------------------------------------------- scrub.sh (weekly bit-rot check of every stored set)
cat > "$NB/scrub.sh" <<'EOF_SCRUB'
#!/bin/bash
# Re-verify the checksums of EVERY complete encrypted set this box holds (its own and the peer's), not just the
# newest. A disk that silently corrupts an old weekly is found on the Sunday it happens, not on the day it is needed.
set -euo pipefail
STAGE=scrub
. "$(dirname "$0")/common.sh"
need_root
exec 9>"$BASE/.scrub.lock"; flock -n 9 || die "another scrub is running"
T0=$SECONDS; N=0; BAD=""; declare -A SEEN=()
prog begin scrub "re-verify every stored set" "all" --expect "$(state_get scrub duration_s)"
for root in "$BASE/own" "$RECV_DIR"; do
  for k in daily weekly monthly; do
    for d in "$root/$k"/*/; do
      [ -f "$d/SHA256SUMS" ] || continue
      ino=$(stat -c %i "$d/SHA256SUMS"); [ -n "${SEEN[$ino]:-}" ] && continue; SEEN[$ino]=1   # weekly/monthly are hard links of a daily
      N=$((N + 1))
      ( cd "$d" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1 ) || BAD="$BAD $(basename "$root")/$k/$(basename "$d")"
    done
  done
done
[ -z "$BAD" ] || die "checksum mismatch in:$BAD"
DUR=$((SECONDS - T0))
prog end OK "$N sets"
log "OK $N sets verified in ${DUR}s"; status "OK scrub $N sets ${DUR}s"
state_put scrub result=OK at="$(date -Is)" sets="$N" duration_s="$DUR"
report_quiet
EOF_SCRUB

# ---------------------------------------------------------------- watchdog.sh (daily: timers, status, notify)
cat > "$NB/watchdog.sh" <<'EOF_WATCH'
#!/bin/bash
# Daily self-check. Re-installs timers that went missing (e.g. after an OS update), makes sure ERPNext can see this
# box's status, and sends ONE notification (NOTIFY_URL) when the overall state is not ok - again only when the set
# of problems changes or NOTIFY_REPEAT_HOURS have passed, plus one "recovered" message.
# The ERPNext side (get_backup_status, and REPORTER_DEAD when this file stops updating) is the alarm of record;
# this is the belt to its braces, and the only one that still works when ERPNext itself is down.
set -euo pipefail
STAGE=watchdog
. "$(dirname "$0")/common.sh"
need_root
SDIR="${ERP_KIT_SYSTEMD_DIR:-/etc/systemd/system}"
want="erp-scrub erp-watchdog erp-progress"
[ "$SEND_ENABLED" = 1 ] && want="$want erp-backup"
[ "$STANDBY_ENABLED" = 1 ] && want="$want erp-standby"
[ "$RECV_ENABLED" = 1 ] && want="$want erp-recv-check"
[ "${TARGET2_KIND:-none}" != none ] && want="$want erp-offsite"
missing() { local m="" t; for t in $want; do { [ -f "$SDIR/$t.timer" ] && systemctl is-enabled --quiet "$t.timer" 2>/dev/null; } || m="$m $t"; done; echo "${m# }"; }
MISS=$(missing); REPAIRED=""
if [ -n "$MISS" ]; then
  log "timers missing: $MISS - reinstalling"
  bash "$(dirname "$0")/install.sh" >/dev/null 2>&1 || true
  REPAIRED="$MISS"; MISS=$(missing)
fi
INC=no
[ "${STATUS_TO_CONTAINER:-1}" = 1 ] && docker exec "$CONTAINER" test -f "$BENCH/sites/erp_backup_status/$ME.json" 2>/dev/null && INC=yes
state_put watchdog result=OK at="$(date -Is)" timers_missing="$MISS" timers_repaired="$REPAIRED" status_in_container="$INC"
if [ "$SEND_ENABLED" = 1 ] && [ "${PUSH_TRANSPORT:-ssh}" = ssh ]; then   # how do pushes reach the peer? (read-only)
  # shellcheck disable=SC2046
  state_put link at="$(date -Is)" $(link_probe | tr '\n' ' ') last_push_rate_kbps="$(state_get push rate_kbps)"
fi
bash "$(dirname "$0")/report.sh" >/dev/null 2>&1 || true
read -r OVERALL CODES MSG < <(python3 - "$BASE/status.json" <<'PY'
import json, sys
try: s = json.load(open(sys.argv[1]))
except Exception: print("critical STATUS_UNREADABLE status.json unreadable"); raise SystemExit
codes = sorted({a["code"] for a in s.get("alerts", [])})
msg = "; ".join(f'{a["code"]}: {a["message"]}' for a in s.get("alerts", []))[:600].replace("\n", " ")
print(s.get("overall", "critical"), ",".join(codes) or "-", msg or "-")
PY
)
LASTC=$(state_get notify codes); LASTAT=$(state_get notify at)
AGE_H=999; [ -n "$LASTAT" ] && AGE_H=$(( ( $(date +%s) - $(date -d "$LASTAT" +%s) ) / 3600 ))
if [ "$OVERALL" != ok ]; then
  if [ "$CODES" != "$LASTC" ] || [ "$AGE_H" -ge "${NOTIFY_REPEAT_HOURS:-24}" ]; then
    notify "$OVERALL - $MSG"; state_put notify at="$(date -Is)" codes="$CODES" overall="$OVERALL"
  fi
elif [ -n "$LASTC" ] && [ "$LASTC" != "-" ]; then
  notify "recovered: backups ok again (was: $LASTC)"; state_put notify at="$(date -Is)" codes="-" overall=ok
fi
log "overall=$OVERALL alerts=$CODES timers_missing=${MISS:-none}${REPAIRED:+ repaired=$REPAIRED} status_in_container=$INC"
EOF_WATCH

# ---------------------------------------------------------------- run-now.sh (one-shot, e.g. before an upgrade)
cat > "$NB/run-now.sh" <<'EOF_RUNNOW'
#!/bin/bash
# Back up NOW, push to the peer, copy to the second target (if any), and print where things stand.
#   --push-only   skip the backup: just send what is waiting (e.g. after a push that failed or was refused)
#   --restore     (standby box) also load the newest complete set into the standby and check it
# A push already running (the nightly one takes hours) is waited for, with progress every 5 minutes, not
# fought with. push.sh on its own does the same and is always safe to re-run: it never deletes on the peer,
# re-sends whatever the peer is missing, and sends the waiting standby set until one push of it succeeds.
set -euo pipefail
STAGE=run-now
. "$(dirname "$0")/common.sh"
need_root
B="$(dirname "$0")"; RESTORE=0; PUSHONLY=0
for a in "$@"; do case "$a" in --restore) RESTORE=1;; --push-only) PUSHONLY=1;; *) echo "Usage: sudo bash $0 [--push-only] [--restore]"; exit 1;; esac; done
if [ "$SEND_ENABLED" = 1 ]; then
  if [ "$PUSHONLY" = 0 ]; then echo "== backup"; BACKUP_LOCK_WAIT_S="${BACKUP_LOCK_WAIT_S:-3600}" bash "$B/backup.sh"; fi
  echo "== push to $PEER_NAME (waits for a push already in progress)"; PUSH_RETRY_SLEEP="${PUSH_RETRY_SLEEP:-60}" bash "$B/push.sh"
fi
[ "${TARGET2_KIND:-none}" != none ] && [ "$PUSHONLY" = 0 ] && { echo "== second target"; bash "$B/offsite.sh"; }
[ "$RESTORE" = 1 ] && { echo "== restore test"; bash "$B/standby-refresh.sh" --now --wait-min=0; }
bash "$B/report.sh" >/dev/null 2>&1 || true
python3 - "$BASE/status.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
b, p = s.get("own_backup") or {}, s.get("push") or {}
print(f'== {s["box"]}: overall {s["overall"].upper()}')
print(f'backup : {b.get("result")} set {b.get("set")} {b.get("size_mb")} MB encrypted={b.get("encrypted")} at {b.get("at")}')
print(f'push   : {p.get("result")} set {p.get("set")} at {p.get("at")} ({p.get("duration_s")} s)')
o = s.get("offsite") or {}
if o.get("at"): print(f'target2: {o.get("result")} set {o.get("set")} {o.get("kind")} at {o.get("at")}')
r = s.get("standby_of_peer") or {}
if r.get("at"): print(f'restore: {r.get("result")} check {r.get("check")} set {r.get("set")} at {r.get("at")}')
for a in s.get("alerts", []): print(f'  {a["level"]:8} {a["code"]}: {a["message"]}')
PY
EOF_RUNNOW

# ---------------------------------------------------------------- set-conf.sh
cat > "$NB/set-conf.sh" <<'EOF_SETCONF'
#!/bin/bash
# Change one setting:      sudo bash set-conf.sh KEY VALUE
# Enter a secret setting:  sudo bash set-conf.sh NOTIFY_URL --prompt     (typed hidden; never in shell history)
set -euo pipefail
STAGE=set-conf
. "$(dirname "$0")/common.sh"
need_root
K="${1:-}"; V="${2:-}"
[[ "$K" =~ ^[A-Z][A-Z0-9_]*$ ]] || { echo "Usage: sudo bash $0 KEY VALUE | KEY --prompt"; exit 1; }
grep -q "^$K=" "$BASE/erp-backup.conf" || die "no setting $K in erp-backup.conf"
case "$K" in ME|PEER_NAME|BASE) die "$K is set by the installer; re-install instead";; esac
if [ "$V" = --prompt ]; then read -rsp "$K (hidden): " V; echo; SECRET=1; else SECRET=0; [ $# -eq 2 ] || die "give exactly one VALUE (quote it if it has spaces)"; fi
[[ "$V" != *$'\n'* && "$V" != *'|'* && "$V" != *'&'* && "$V" != *'\'* && "$V" != *'"'* ]] || die "value may not contain newline, |, &, \\ or \""
[[ "$V" == *' '* || -z "$V" ]] && V="\"$V\""
OLD=$(sed -n "s/^$K=//p" "$BASE/erp-backup.conf" | tail -n1)
setconf "$K" "$V"
if [ "$SECRET" = 1 ]; then echo "$K updated (value not shown)"; status "OK set-conf $K (hidden)"
else echo "$K: $OLD -> $V"; status "OK set-conf $K=$V"; fi
case "$K" in *_TIME|*_AT|*_CALENDAR|*_ENABLED|TARGET2_KIND|STANDBY_EVERY) echo "Schedule changed: run  sudo bash $(dirname "$0")/install.sh";; esac
EOF_SETCONF

# ---------------------------------------------------------------- stage-upgrade.sh (on demand, standby box)
cat > "$NB/stage-upgrade.sh" <<'EOF_STAGE'
#!/bin/bash
# ON DEMAND, on the box that holds the standby: rehearse an ERPNext image upgrade on a COPY of the peer's data.
#   1. dumps the read-only standby site (the peer's data as of the last nightly restore) with bench backup
#   2. starts a throwaway ERPNext from --image (own MariaDB, own volumes, compose project erp-stage-<me>,
#      bound to 127.0.0.1:STAGE_PORT only), with the copy's scheduler paused and email muted
#   3. restores the dump there and runs bench migrate (timed), then restarts all programs
#   4. checks: migrate exit code, every supervisord program RUNNING, HTTP ping, row counts / sanity / files /
#      secrets against the standby
#   5. removes the throwaway stack and its volumes (unless --keep)
# Usage: sudo bash stage-upgrade.sh [--image=IMAGE] [--keep] [--force]   (--force skips the memory check)
# The env names in the compose file below are this store's fafo-erpnext image (SITE_NAME, DB_HOST, ...).
set -euo pipefail
STAGE=stage
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/lib-site.sh"
need_root
trap 'die "unexpected error at line $LINENO"' ERR
IMG=""; KEEPUP=0; FORCE=0
for a in "$@"; do case "$a" in --image=*) IMG="${a#--image=}";; --keep) KEEPUP=1;; --force) FORCE=1;; *) die "unknown option $a";; esac; done
[ "$ALLOW_STANDBY" = 1 ] || die "stage-upgrade runs on the box that holds the standby (ALLOW_STANDBY=1)"
[ -z "$(primary_host)" ] || [ "$(hostname)" != "$(primary_host)" ] || die "never on the primary ($(primary_host))"
site_exists "$STANDBY_SITE" || die "no standby site $STANDBY_SITE yet (the nightly restore builds it)"
IMG="${IMG:-${STAGE_IMAGE:-}}"; [ -n "$IMG" ] || IMG=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")
[[ "$IMG" =~ ^[A-Za-z0-9._/:@-]+$ ]] || die "bad image name"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
mem_snapshot
[ "$FORCE" = 1 ] || [ "$MEM_AVAIL_MB" -ge "${STAGE_MIN_AVAIL_MB:-3500}" ] || die "low memory: MemAvailable ${MEM_AVAIL_MB} MB, need ${STAGE_MIN_AVAIL_MB:-3500} (stop heavy apps in the Umbrel UI, or --force)"
exec 9>"$BASE/.stage.lock"; flock -n 9 || die "another stage run is in progress"
PROJ="erp-stage-$ME"; SC="$PROJ-server"; W="$BASE/work/stage"; PROD="$CONTAINER"
# compose lets the caller's environment override --env-file: run it with an empty environment, so nothing
# exported in the calling shell can change what the throwaway stack is built from
dc() { env -i PATH="$PATH" HOME="${HOME:-/root}" ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} docker compose -p "$PROJ" -f "$W/compose.yml" --env-file "$W/.env" "$@"; }
rm -rf "$W"; mkdir -p "$W/set"; chmod 700 "$W"
cleanup() {
  CONTAINER="$PROD"
  if [ "$KEEPUP" != 1 ]; then dc down -v >/dev/null 2>&1 || true; rm -rf "$W"
  else echo "kept: compose project $PROJ (http://127.0.0.1:${STAGE_PORT:-8090}); remove with: sudo docker compose -p $PROJ -f $W/compose.yml --env-file $W/.env down -v"; fi
}
trap cleanup EXIT
T0=$SECONDS
echo "== 1. dump the standby ($STANDBY_SITE) on $PROD"; prog begin "staged upgrade" "dump the standby" "$IMG"
export TS="$STANDBY_SITE"
SRC_COUNTS=$(site_counts "$STANDBY_SITE"); SRC_SANITY=$(site_sanity "$STANDBY_SITE")
BK="$BENCH/sites/$STANDBY_SITE/private/backups"
docker exec -u frappe -w "$BENCH" "$PROD" bench --site "$STANDBY_SITE" backup --with-files >/dev/null || die "bench backup of $STANDBY_SITE failed"
NEWEST=$(docker exec "$PROD" sh -c "ls -1t '$BK'/*-database.sql.gz 2>/dev/null | head -n1"); [ -n "$NEWEST" ] || die "no dump of $STANDBY_SITE found"
PREFIX="${NEWEST%-database.sql.gz}"
for f in $(docker exec "$PROD" sh -c "ls -1 '$PREFIX'-*"); do docker cp "$PROD:$f" "$W/set/" >/dev/null 2>&1 || die "docker cp failed for $f"; done
docker exec -u frappe "$PROD" sh -c "rm -f '$PREFIX'-*" || true
echo "$SRC_COUNTS" > "$W/set/COUNTS.txt"; echo "$SRC_SANITY" > "$W/set/SANITY.txt"
set_files "$W/set" || die "standby dump incomplete"
echo "== 2. throwaway ERPNext from $IMG"; prog begin "staged upgrade" "boot a throwaway ERPNext" "$IMG" --expect 300
rnd() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24; }
STAGE_DB_PW=$(rnd)
( umask 077; printf 'ERPSTAGE_DB_PW=%s\nERPSTAGE_ADMIN_PW=%s\nERPSTAGE_IMAGE=%s\nERPSTAGE_DB_IMAGE=%s\nERPSTAGE_PORT=%s\nERPSTAGE_CONTAINER=%s\n' \
    "$STAGE_DB_PW" "$(rnd)" "$IMG" "${STAGE_DB_IMAGE:-mariadb:10.6}" "${STAGE_PORT:-8090}" "$SC" > "$W/.env" )
cat > "$W/compose.yml" <<'YML'
services:
  erpstage-db:
    image: ${ERPSTAGE_DB_IMAGE}
    command: [--character-set-server=utf8mb4, --collation-server=utf8mb4_unicode_ci, --skip-character-set-client-handshake, --skip-innodb-read-only-compressed]
    environment: {MYSQL_ROOT_PASSWORD: "${ERPSTAGE_DB_PW}"}
    volumes: [stagedb:/var/lib/mysql]
    healthcheck: {test: ["CMD-SHELL", "mysqladmin ping -h localhost -uroot -p\"$$MYSQL_ROOT_PASSWORD\""], interval: 10s, retries: 30}
  server:
    image: ${ERPSTAGE_IMAGE}
    container_name: ${ERPSTAGE_CONTAINER}
    depends_on: {erpstage-db: {condition: service_healthy}}
    environment: {SITE_NAME: frontend, DB_HOST: erpstage-db, DB_PORT: "3306", DB_ROOT_PASS: "${ERPSTAGE_DB_PW}", ADMIN_PASS: "${ERPSTAGE_ADMIN_PW}"}
    ports: ["127.0.0.1:${ERPSTAGE_PORT}:8080"]
    volumes: [stagesites:/home/frappe/frappe-bench/sites]
volumes: {stagedb: {}, stagesites: {}}
YML
dc up -d > "$W/compose.log" 2>&1 \
  || die "could not start the throwaway stack (image $IMG): $(grep -v '^\s*$' "$W/compose.log" | tail -n 2 | tr '\n' ' ' | cut -c1-240)"
UP=0; for _ in $(seq 1 "${STAGE_BOOT_POLLS:-120}"); do
  if docker exec "$SC" test -f "$BENCH/sites/frontend/site_config.json" 2>/dev/null \
     && docker exec "$SC" supervisorctl status backend 2>/dev/null | grep -q RUNNING; then UP=1; break; fi
  sleep 10
done
[ "$UP" = 1 ] || die "throwaway ERPNext did not come up (see: docker logs $SC)"
BOOT_S=$((SECONDS - T0))
echo "== 3. restore + migrate"; prog begin "staged upgrade" "restore + bench migrate" "$IMG"
CONTAINER="$SC"; DBPW="$STAGE_DB_PW"; TMPD=/tmp/erp-stage; export DBPW TMPD TS=frontend
copy_set_in "$W/set"
bx bench --site frontend set-config -p pause_scheduler 1 >/dev/null
bx bench --site frontend set-config -p mute_emails 1 >/dev/null
set_enc_key
T1=$SECONDS
bx sh -c 'bench --site "$TS" restore "$TMPD/$DBF" --with-public-files "$TMPD/$PUBF" --with-private-files "$TMPD/$PRIVF" --db-root-password "$DBPW"' </dev/null > "$W/restore.log" 2>&1 \
  || die "restore into the throwaway site failed: $(grep -v '^\s*$' "$W/restore.log" | tail -n 2 | tr '\n' ' ' | cut -c1-240)"
set_enc_key
bx bench --site frontend set-config -p pause_scheduler 1 >/dev/null; bx bench --site frontend set-config -p mute_emails 1 >/dev/null
RESTORE_S=$((SECONDS - T1)); T2=$SECONDS
MIG_RC=0; bx bench --site frontend migrate </dev/null > "$W/migrate.log" 2>&1 || MIG_RC=$?
MIGRATE_S=$((SECONDS - T2))
docker exec "$SC" supervisorctl restart all >/dev/null 2>&1 || true
echo "== 4. checks"
# programs come back one by one (nginx sits in STARTING for its startsecs): poll, don't judge a snapshot
NOTRUN="?"; WAITS=0
while [ "$WAITS" -lt "${STAGE_SETTLE_MAX_S:-240}" ]; do
  sleep 10; WAITS=$((WAITS + 10))
  NOTRUN=$(docker exec "$SC" supervisorctl status 2>/dev/null | awk '$2!="RUNNING"{print $1}' | tr '\n' ' '); NOTRUN="${NOTRUN% }"
  [ -z "$NOTRUN" ] && break
done
PING=$(curl -s -m 15 "http://127.0.0.1:${STAGE_PORT:-8090}/api/method/ping" || true); [[ "$PING" == *pong* ]] && PING=ok || PING=fail
run_checks frontend "$W/set"
VERS=$(docker exec -u frappe -w "$BENCH" "$SC" bench version 2>/dev/null | awk '{print $1"="$2}' | tr '\n' ' ')
RES=Pass
[ "$CHK_RESULT" = Pass ] || RES=Partial
{ [ "$MIG_RC" = 0 ] && [ -z "$NOTRUN" ] && [ "$PING" = ok ]; } || RES=Fail
TOTAL=$((SECONDS - T0))
REPORT="$BASE/restore-tests/$(date +%F_%H%M)-stage-$(echo "$IMG" | tr '/:@' '___').txt"
{ echo "STAGE $IMG on $(hostname) at $(date -Is): $RES"
  echo "versions: $VERS"; echo "boot ${BOOT_S}s restore ${RESTORE_S}s migrate ${MIGRATE_S}s (exit $MIG_RC) total ${TOTAL}s"
  echo "not running: ${NOTRUN:-none}; ping: $PING"
  echo "counts restored [$CHK_COUNTS] source [$CHK_SRC_COUNTS] ok=$CHK_COUNTS_OK; sanity ok=$CHK_SANITY_OK; files missing $CHK_MISSING; decrypt failures $CHK_DECRYPT_FAIL"
  echo "--- migrate (last 40 lines)"; tail -n 40 "$W/migrate.log"; } > "$REPORT"
CONTAINER="$PROD"
state_put stage result=OK at="$(date -Is)" image="$IMG" check="$RES" versions="$VERS" boot_s="$BOOT_S" restore_s="$RESTORE_S" migrate_s="$MIGRATE_S" \
  migrate_exit="$MIG_RC" not_running="$NOTRUN" ping="$PING" counts_ok="$CHK_COUNTS_OK" sanity_ok="$CHK_SANITY_OK" files_missing="$CHK_MISSING" \
  decrypt_fail="$CHK_DECRYPT_FAIL" total_s="$TOTAL" report="$REPORT"
prog end "$RES" "migrate ${MIGRATE_S}s exit $MIG_RC"
status "OK stage $IMG check=$RES migrate=${MIGRATE_S}s exit=$MIG_RC"
report_quiet
echo "STAGE $RES: migrate ${MIGRATE_S}s (exit $MIG_RC), programs not running: ${NOTRUN:-none}, ping $PING, data check $CHK_RESULT"
echo "Report: $REPORT"
trap - ERR
[ "$RES" != Fail ] || exit 1
EOF_STAGE

# ---------------------------------------------------------------- progress.py (live progress, both roles)
cat > "$NB/progress.py" <<'EOF_PROGPY'
#!/usr/bin/env python3
"""erp-backup live progress (kit 2026-10-19.3).

Every long job (backup, push, restore test, offsite copy, scrub, staged upgrade) writes what it is doing to
state/progress.json as it goes; when it ends the record moves to state/progress-last.json. The push also tells
the peer up front what it is about to send (receipts/inflight-<box>.json), so the receiving box can show how far
along each incoming set is from the bytes already on its disk. progress.sh shows all of it; report.sh embeds it in
status.json so ERPNext's get_backup_status can show it live (refreshed at most once a minute while a job runs).
Commands: begin, bytes, end, rsync (parses rsync --info=progress2 --stats on stdin), watchdir, incoming,
snapshot, show [--watch N] [--json]. Stdlib only."""
import datetime as dt, json, os, re, subprocess, sys, time

E = os.environ
STATE = E.get("ERPB_STATE", "."); ME = E.get("ERPB_ME", ""); PEER = E.get("ERPB_PEER", "")
RECV = E.get("ERPB_RECV_DIR", ""); REPORT = E.get("ERPB_REPORT", ""); HOST = os.uname().nodename
CUR = os.path.join(STATE, "progress.json"); LAST = os.path.join(STATE, "progress-last.json")
FRESH_S = 180


def now(): return dt.datetime.now().astimezone()
def iso(t=None): return (t or now()).isoformat(timespec="seconds")
def parse(ts):
    try: return dt.datetime.fromisoformat(ts)
    except Exception: return None
def load(p):
    try:
        with open(p) as f: return json.load(f)
    except Exception: return None
def save(p, d):
    tmp = p + ".tmp"
    with open(tmp, "w") as f: json.dump(d, f)
    os.replace(tmp, p)
def alive(pid):
    try: os.kill(int(pid), 0); return True
    except Exception: return False
def human(n):
    if n is None: return "?"
    n = float(n)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or u == "TB": return f"{n:.0f} {u}" if u == "B" else f"{n:.1f} {u}"
        n /= 1024
def hms(s):
    if s is None: return "?"
    s = int(max(0, s)); return f"{s // 3600}h{(s % 3600) // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"
def hhmm(ts):
    t = parse(ts or ""); return t.strftime("%H:%M") if t else "?"
def tree_bytes(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try: total += os.lstat(os.path.join(root, f)).st_size
            except OSError: pass
    return total


def maybe_report():
    """Refresh status.json (and its copy inside ERPNext) at most once a minute while a job runs."""
    if not REPORT: return
    stamp = os.path.join(STATE, ".progress-report")
    try:
        if time.time() - os.path.getmtime(stamp) < 60: return
    except OSError: pass
    open(stamp, "w").close()
    subprocess.Popen(["bash", REPORT], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def compute(d):
    """rate, % and ETA from what is known: bytes against a total, or elapsed time against the last run."""
    t = now(); st = parse(d.get("step_started_at", "")) or t
    el = (t - st).total_seconds(); d["elapsed_s"] = int(el)
    done, total = d.get("bytes_done"), d.get("bytes_total")
    if d.get("rate_bps") is None and done and el > 0: d["rate_bps"] = int(done / el)
    if total and done is not None and total > 0:
        d["pct"] = round(min(100.0, 100.0 * done / total), 1)
        r = d.get("rate_bps") or 0
        if d.get("eta_s") is None and r > 0: d["eta_s"] = int(max(0, total - done) / r)
    elif d.get("expect_s"):
        d["pct"] = round(min(99.0, 100.0 * el / d["expect_s"]), 1); d["eta_s"] = int(max(0, d["expect_s"] - el)); d["estimate"] = "from the last run's duration"
    return d


def cmd_begin(a):
    phase, step, setname = a[0], a[1], a[2]
    opts = dict(zip(a[3::2], a[4::2]))
    prev = load(CUR) or {}
    d = {"phase": phase, "step": step, "set": setname, "host": HOST, "box": ME, "pid": os.getppid(),
         "job_started_at": prev.get("job_started_at") if prev.get("phase") == phase and prev.get("pid") == os.getppid() else iso(),
         "step_started_at": iso(), "updated_at": iso(), "bytes_done": 0 if opts.get("--total") else None,
         "bytes_total": int(opts["--total"]) if opts.get("--total", "").isdigit() and int(opts["--total"]) > 0 else None,
         "total_from_job": opts.get("--total", "").isdigit() and int(opts["--total"]) > 0,
         "expect_s": int(opts["--expect"]) if opts.get("--expect", "").isdigit() and int(opts["--expect"]) > 0 else None}
    save(CUR, compute(d)); maybe_report()


def cmd_bytes(a):
    d = load(CUR)
    if not d: return
    d["bytes_done"] = int(a[0])
    if len(a) > 1 and a[1].isdigit() and int(a[1]) > 0: d["bytes_total"] = int(a[1])
    d.pop("rate_bps", None); d.pop("eta_s", None); d["updated_at"] = iso()
    save(CUR, compute(d)); maybe_report()


def cmd_end(a):
    d = load(CUR) or {}
    d.update({"result": a[0] if a else "OK", "note": " ".join(a[1:])[:300], "finished_at": iso()})
    js = parse(d.get("job_started_at", ""))
    if js: d["job_duration_s"] = int((now() - js).total_seconds())
    save(LAST, d)
    try: os.remove(CUR)
    except OSError: pass


PROG = re.compile(r"^\s*([\d,]+)\s+(\d+)%\s+([\d.]+)([kKMGT]?B)/s\s+(\d+):(\d{2}):(\d{2})")
UNITS = {"B": 1, "kB": 1e3, "KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3, "TB": 1024 ** 4}


def cmd_rsync(a):
    """stdin: rsync --info=progress2 --stats. Updates the current step; adds the call's byte counts to STATSFILE."""
    statsfile = a[0]; last = 0.0; sent = None; xfer = None; buf = ""
    stdin = sys.stdin.buffer
    while True:
        ch = stdin.read(1)
        if not ch: break
        c = ch.decode("latin-1")
        if c not in "\r\n": buf += c; continue
        line, buf = buf, ""
        m = PROG.match(line)
        if m:
            done = int(m.group(1).replace(",", "")); pct = int(m.group(2))
            rate = float(m.group(3)) * UNITS.get(m.group(4), 1); eta = int(m.group(5)) * 3600 + int(m.group(6)) * 60 + int(m.group(7))
            if time.time() - last >= 2:
                d = load(CUR)
                if d:
                    # rsync's own % is of everything it scanned (old sets included), so a total the job knows
                    # (the new set's size) wins; rsync's figure is only used when there is none
                    d.update({"bytes_done": done, "rate_bps": int(rate), "updated_at": iso(), "rsync_pct": pct})
                    if not d.get("total_from_job"):
                        d["eta_s"] = eta
                        if pct > 0 and done > 0: d["bytes_total"] = int(done * 100 / pct)
                    else:
                        d.pop("eta_s", None)
                    save(CUR, compute(d)); maybe_report()
                last = time.time()
            continue
        s = line.replace(",", "")
        m2 = re.match(r"Total bytes sent:\s*(\d+)", s)
        if m2: sent = int(m2.group(1))
        m3 = re.match(r"Total transferred file size:\s*(\d+)", s)
        if m3: xfer = int(m3.group(1))
    st = load(statsfile) or {"bytes_sent": 0, "transferred_file_bytes": 0, "calls": 0}
    st["bytes_sent"] += sent or 0; st["transferred_file_bytes"] += xfer or 0; st["calls"] += 1
    save(statsfile, st)


def cmd_watchdir(a):
    """Background sampler for a step with no byte counter of its own (encryption): bytes written so far in DIR."""
    path, total, every = a[0], int(a[1]), int(a[2]) if len(a) > 2 else 5
    owner = os.getppid()
    while alive(owner):
        d = load(CUR)
        if not d: break
        d["bytes_done"] = tree_bytes(path); d["bytes_total"] = total; d.pop("rate_bps", None); d.pop("eta_s", None); d["updated_at"] = iso()
        save(CUR, compute(d)); maybe_report(); time.sleep(every)


def incoming():
    """Receiver side: sets from the peer still without their completion marker, sized on disk."""
    if not RECV or not os.path.isdir(RECV): return {"from": PEER, "sets": [], "sender": None}
    infl = load(os.path.join(RECV, "receipts", f"inflight-{PEER}.json"))
    samples = load(os.path.join(STATE, "recv-sample.json")) or {}
    out = []; tnow = time.time()
    for kind, marker in (("daily", "SHA256SUMS"), ("standby", "MANIFEST.sha256")):
        base = os.path.join(RECV, kind)
        if not os.path.isdir(base): continue
        for name in sorted(os.listdir(base)):
            p = os.path.join(base, name)
            if name.startswith(".") or name.endswith(".partial") or not os.path.isdir(p) or os.path.exists(os.path.join(p, marker)): continue
            size = tree_bytes(p); age_min = int((tnow - os.path.getmtime(p)) / 60)
            exp = None
            if infl and infl.get("set") == name: exp = infl.get("archive_bytes" if kind == "daily" else "standby_bytes")
            if infl and kind == "standby" and infl.get("standby_set") == name: exp = infl.get("standby_bytes")
            key = f"{kind}/{name}"; rate = None
            prev = samples.get(key)
            if prev and tnow - prev[0] >= 5 and size >= prev[1]: rate = int((size - prev[1]) / (tnow - prev[0]))
            if not prev or tnow - prev[0] >= 30: samples[key] = [tnow, size]
            e = {"kind": kind, "set": name, "bytes_on_disk": size, "bytes_expected": exp, "rate_bps": rate, "age_min": age_min,
                 "stalled": age_min >= 360 and not rate}
            if exp: e["pct"] = round(min(100.0, 100.0 * size / exp), 1)
            if exp and rate: e["eta_s"] = int(max(0, exp - size) / rate)
            out.append(e)
    try: save(os.path.join(STATE, "recv-sample.json"), {k: v for k, v in samples.items() if tnow - v[0] < 86400})
    except OSError: pass
    return {"from": PEER, "sets": out, "sender": infl}


def snapshot():
    cur = load(CUR)
    if cur:
        up = parse(cur.get("updated_at", ""))
        cur["stale"] = (not alive(cur.get("pid", 0))) or (up is not None and (now() - up).total_seconds() > FRESH_S and not alive(cur.get("pid", 0)))
        if cur["stale"]: cur = None
        else: cur = compute(cur)
    return {"schema": "erp-backup-progress/1", "at": iso(), "box": ME, "current": cur, "last": load(LAST), "incoming": incoming()}


def line_for(d):
    bits = []
    if d.get("bytes_done") is not None:
        bits.append(f"{human(d['bytes_done'])}" + (f" of ~{human(d['bytes_total'])}" if d.get("bytes_total") else ""))
    if d.get("pct") is not None: bits.append(f"{d['pct']:.0f}%")
    if d.get("rate_bps"): bits.append(f"{human(d['rate_bps'])}/s")
    if d.get("eta_s") is not None: bits.append(f"ETA {hms(d['eta_s'])}" + (" (est.)" if d.get("estimate") else ""))
    return "  ".join(bits)


def show(as_json):
    s = snapshot()
    if as_json: print(json.dumps(s, indent=1)); return
    print(f"erp-backup progress on {HOST} ({ME}) at {now().strftime('%Y-%m-%d %H:%M:%S %Z')}")
    c = s["current"]
    if c:
        print(f"NOW   {c['phase']}: {c['step']}   set {c.get('set')}")
        print(f"      {line_for(c) or 'working'}   (step since {hhmm(c.get('step_started_at'))}, job since {hhmm(c.get('job_started_at'))}, {hms(c.get('elapsed_s'))} into this step)")
    else:
        print("NOW   idle")
    l = s["last"]
    if l: print(f"LAST  {l.get('phase')} {l.get('result')}  set {l.get('set')}  finished {hhmm(l.get('finished_at'))}" + (f" after {hms(l.get('job_duration_s'))}" if l.get("job_duration_s") else "") + (f"  ({l.get('note')})" if l.get("note") else ""))
    inc = s["incoming"]
    if RECV:
        snd = inc.get("sender") or {}
        if snd.get("state") == "sending": print(f"PEER  {PEER} is sending set {snd.get('set')} (started {hhmm(snd.get('started_at'))}; ~{human((snd.get('archive_bytes') or 0) + (snd.get('standby_bytes') or 0))} in all)")
        for e in inc["sets"]:
            print(f"IN    from {PEER}: {e['kind']} {e['set']}  {human(e['bytes_on_disk'])}" + (f" of {human(e['bytes_expected'])}  {e['pct']:.0f}%" if e.get("bytes_expected") else " so far")
                  + (f"  {human(e['rate_bps'])}/s" if e.get("rate_bps") else "") + (f"  ETA {hms(e['eta_s'])}" if e.get("eta_s") is not None else "")
                  + ("  STALLED (no growth, >6 h old)" if e.get("stalled") else ""))
        if not inc["sets"] and snd.get("state") != "sending": print(f"IN    nothing arriving from {PEER}")
    try:
        t = subprocess.run(["systemctl", "list-timers", "erp-*", "--no-pager", "--no-legend"], capture_output=True, text=True, timeout=5).stdout.strip().splitlines()
        nxt = [f"{x.split()[-2].replace('.timer', '')} {x.split()[1]} {x.split()[2][:5]}" for x in t if x.split() and x.split()[0] not in ("-", "n/a")][:6]
        if nxt: print("NEXT  " + ", ".join(nxt))
    except Exception: pass


def main():
    a = sys.argv[1:]
    if not a: print(__doc__); return
    c, rest = a[0], a[1:]
    if c == "begin": cmd_begin(rest)
    elif c == "bytes": cmd_bytes(rest)
    elif c == "end": cmd_end(rest)
    elif c == "rsync": cmd_rsync(rest)
    elif c == "watchdir": cmd_watchdir(rest)
    elif c == "snapshot": print(json.dumps(snapshot()))
    elif c == "incoming": print(json.dumps(incoming()))
    elif c == "show":
        as_json = "--json" in rest; every = None
        if "--watch" in rest:
            i = rest.index("--watch"); every = int(rest[i + 1]) if len(rest) > i + 1 and rest[i + 1].isdigit() else 10
        if every:
            try:
                while True:
                    print("\033[2J\033[H", end=""); show(as_json); print(f"\n(refreshing every {every}s; Ctrl-C to stop)"); sys.stdout.flush(); time.sleep(every)
            except KeyboardInterrupt: print()
        else: show(as_json)


if __name__ == "__main__":
    main()
EOF_PROGPY

# ---------------------------------------------------------------- progress.sh
cat > "$NB/progress.sh" <<'EOF_PROGSH'
#!/bin/bash
# Where is the backup right now?  sudo bash progress.sh [--watch [SECONDS]] [--json]
# Shows this box's running job (bench backup / encrypt / push / restore test / ...) with set, bytes, %, rate and
# ETA, the last finished job, and - on a receiving box - every set still arriving from the peer, sized on disk.
STAGE=progress
. "$(dirname "$0")/common.sh"
need_root
ERPB_STATE="$STATE" ERPB_ME="$ME" ERPB_PEER="$PEER_NAME" ERPB_RECV_DIR="$([ "$RECV_ENABLED" = 1 ] && echo "$RECV_DIR")" \
  python3 "$(dirname "$0")/progress.py" show "$@"
EOF_PROGSH

# ---------------------------------------------------------------- tick.sh (every 2 min: live status, resume pushes)
cat > "$NB/tick.sh" <<'EOF_TICK'
#!/bin/bash
# Every 2 minutes (erp-progress.timer). Cheap when idle: exits unless something is running or arriving.
#  * while a job runs here or a set is arriving from the peer: refresh status.json, so ERPNext shows live progress
#  * a push that FAILED (or a complete own set that was never pushed) is resumed after PUSH_RESUME_AFTER_MIN,
#    at most PUSH_RESUME_MAX_PER_DAY times a day, through erp-push.service - never alongside another push
set -euo pipefail
STAGE=tick
. "$(dirname "$0")/common.sh"
need_root
ACTIVE=0
[ -f "$STATE/progress.json" ] && ACTIVE=1
if [ "$RECV_ENABLED" = 1 ] && [ -n "$(ERPB_STATE="$STATE" ERPB_PEER="$PEER_NAME" ERPB_RECV_DIR="$RECV_DIR" python3 "$(dirname "$0")/progress.py" incoming 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("x" if d["sets"] or (d.get("sender") or {}).get("state")=="sending" else "")' 2>/dev/null)" ]; then ACTIVE=1; fi
[ "$ACTIVE" = 1 ] && report_quiet
[ "$SEND_ENABLED" = 1 ] || exit 0
NEWEST=$(newest_complete "$BASE/own/daily" SHA256SUMS); [ -n "$NEWEST" ] || exit 0
N=$(basename "$NEWEST"); PR=$(state_get push result); PS=$(state_get push set); PAT=$(state_get push at)
NEED=""
[ "$PR" = FAIL ] && NEED="the last push failed ($(state_get push msg | cut -c1-120))"
[ -z "$NEED" ] && [ "$N" != "$PS" ] && NEED="set $N was never pushed"
[ -n "$NEED" ] || exit 0
REF=$(stat -c %Y "$NEWEST/SHA256SUMS"); [ -n "$PAT" ] && REF=$(( $(date -d "$PAT" +%s) > REF ? $(date -d "$PAT" +%s) : REF ))
[ $(( ( $(date +%s) - REF ) / 60 )) -ge "${PUSH_RESUME_AFTER_MIN:-60}" ] || exit 0
[ -z "$(other_push_pids | tr -d ' \n')" ] || exit 0
exec 8>"$PUSH_LOCK"; flock -n 8 || exit 0; exec 8>&-
exec 9>"$BASE/.lock"; flock -n 9 || exit 0; exec 9>&-     # a backup is running: its own push follows
TODAY=$(date +%F); CNT=0; [ "$(state_get resume day)" = "$TODAY" ] && CNT=$(state_get resume count)
[ "${CNT:-0}" -lt "${PUSH_RESUME_MAX_PER_DAY:-6}" ] || exit 0
state_put resume day="$TODAY" count="$(( ${CNT:-0} + 1 ))" at="$(date -Is)" why="$NEED"
log "resuming the push to $PEER_NAME: $NEED"; status "OK tick resume push ($NEED)"
if [ -f "${ERP_KIT_SYSTEMD_DIR:-/etc/systemd/system}/erp-push.service" ] && command -v systemctl >/dev/null; then
  systemctl start --no-block erp-push.service
else
  setsid bash "$(dirname "$0")/push.sh" >/dev/null 2>&1 < /dev/null &
fi
EOF_TICK

# ---------------------------------------------------------------- report.sh (status JSON for ERPNext / MCP)
cat > "$NB/report.sh" <<'EOF_REPORT'
#!/bin/bash
# Build status.json from state files (schema erp-backup-status/1) and drop a copy where ERPNext can read it:
#   container: $BENCH/sites/erp_backup_status/<ME>.json
STAGE=report
. "$(dirname "$0")/common.sh"
command -v python3 >/dev/null || exit 0
ERPB_STATE="$STATE" ERPB_ME="$ME" ERPB_PEER="$PEER_NAME" ERPB_RECV_DIR="$([ "$RECV_ENABLED" = 1 ] && echo "$RECV_DIR")" \
  python3 "$(dirname "$0")/progress.py" snapshot > "$STATE/progress-snapshot.json.tmp" 2>/dev/null && mv "$STATE/progress-snapshot.json.tmp" "$STATE/progress-snapshot.json" || true
ERPB_LINKMIN="${LINK_MIN_RATE_KBPS:-1000}" ERPB_STATE="$STATE" ERPB_ME="$ME" ERPB_PEER="$PEER_NAME" ERPB_HOST="$(hostname)" ERPB_KIT="$(cat "$BASE/KIT_VERSION" 2>/dev/null)" \
ERPB_MAXAGE="$MAX_AGE_HOURS" ERPB_RECEIPT="$RECV_DIR/receipts/standby-of-$ME.json" ERPB_PROMOTED="$BASE/PROMOTED" ERPB_FENCED="$BASE/FENCED" \
ERPB_T2="${TARGET2_KIND:-none}" ERPB_KD="$KEEP_DAILY" ERPB_KW="$KEEP_WEEKLY" ERPB_KM="${KEEP_MONTHLY:-12}" \
ERPB_EVERY="$STANDBY_EVERY" ERPB_RRMAX="$REMOTE_RESTORE_MAX_HOURS" ERPB_EXPECT="$EXPECT_REMOTE_RESTORE" ERPB_ATMAX="$ARCHIVE_TEST_MAX_DAYS" ERPB_SEND="$SEND_ENABLED" ERPB_RECV="$RECV_ENABLED" ERPB_STANDBY="$STANDBY_ENABLED" ERPB_SITE="$SITE" ERPB_SS="$STANDBY_SITE" \
python3 - > "$BASE/status.json.tmp" <<'PY'
import os, json, glob, datetime as dt
E = os.environ
now = dt.datetime.now().astimezone()
def load(stage):
    p = os.path.join(E["ERPB_STATE"], stage + ".env"); d = {}
    if os.path.exists(p):
        for line in open(p):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1); d[k] = v
    return d
def age_h(ts):
    try: return round((now - dt.datetime.fromisoformat(ts)).total_seconds() / 3600, 1)
    except Exception: return None
maxage = float(E.get("ERPB_MAXAGE") or 30)
def old(d, limit):
    a = (d or {}).get("last_ok_age_hours", (d or {}).get("age_hours"))
    return a is None or a > limit
st = {s: load(s) for s in ("backup", "push", "check", "standby", "archive_test", "install", "standby_defer",
                          "offsite", "scrub", "watchdog", "stage", "link", "resume")}
try: progress = json.load(open(os.path.join(E["ERPB_STATE"], "progress-snapshot.json")))
except Exception: progress = None
for s, d in st.items():
    if d.get("at"): d["age_hours"] = age_h(d["at"])
    good = d.get("at") if d.get("result") == "OK" else d.get("last_ok_at")
    d["last_ok_age_hours"] = age_h(good) if good else None
receipt = None
if os.path.exists(E["ERPB_RECEIPT"]):
    try:
        receipt = json.load(open(E["ERPB_RECEIPT"])); receipt["age_hours"] = age_h(receipt.get("at", ""))
    except Exception: receipt = {"error": "unreadable receipt"}
promoted = None
if os.path.exists(E["ERPB_PROMOTED"]):
    promoted = dict(l.strip().split("=", 1) for l in open(E["ERPB_PROMOTED"]) if "=" in l)
def ago(h): return "never" if h is None else f"{h}h ago"
alerts = []
def A(level, code, msg): alerts.append({"level": level, "code": code, "message": msg})
b = st["backup"]
if b.get("result") == "FAIL": A("critical", "BACKUP_FAILED", b.get("msg", ""))
if E["ERPB_SEND"] == "1":
    if old(b, maxage): A("critical", "BACKUP_STALE", f"last own backup {ago(b.get('last_ok_age_hours'))}")
    if b.get("result") == "OK" and b.get("encrypted") != "yes": A("critical", "BACKUP_UNENCRYPTED", "last archive not encrypted")
    p = st["push"]
    if p.get("result") == "FAIL" or old(p, maxage): A("critical", "PUSH_STALE_OR_FAILED", p.get("msg", f"last push {ago(p.get('last_ok_age_hours'))}"))
    if E.get("ERPB_EXPECT") == "1":
        if receipt is None: A("warning", "NO_REMOTE_RESTORE", "no standby restore receipt from peer yet")
        elif old(receipt, float(E.get("ERPB_RRMAX") or maxage)): A("warning", "REMOTE_RESTORE_STALE", f"peer last restored our data {ago(receipt.get('age_hours'))}")
        elif receipt.get("result") != "Pass": A("warning", "REMOTE_RESTORE_NOT_PASS", f"peer standby check: {receipt.get('result')}")
    else:
        at = st["archive_test"]
        if at.get("result") != "OK" or old(at, float(E.get("ERPB_ATMAX") or 35) * 24): A("warning", "ARCHIVE_TEST_DUE", "no passing archive restore test of this box's backups in the last %s days (run archive-test.sh own)" % (E.get("ERPB_ATMAX") or 35))
if E["ERPB_RECV"] == "1":
    c = st["check"]
    if c.get("result") == "FAIL" or old(c, 26): A("critical", "PEER_COPIES_BAD", c.get("msg", "receive check missing/old"))
if E["ERPB_STANDBY"] == "1" and not promoted:
    s = st["standby"]
    if s.get("result") == "FAIL": A("critical", "STANDBY_FAILED", s.get("msg", ""))
    elif old(s, 198 if E.get("ERPB_EVERY") == "weekly" else maxage): A("warning", "STANDBY_STALE", f"standby refreshed {ago(s.get('last_ok_age_hours'))} ({E.get('ERPB_EVERY')})")
    elif s.get("check") not in ("Pass",): A("warning", "STANDBY_CHECK_NOT_PASS", f"standby check {s.get('check')}")
dfr = st["standby_defer"]
if E["ERPB_STANDBY"] == "1" and dfr.get("at"): A("warning", "STANDBY_DEFERRED", f"standby refresh skipped {dfr.get('at')}: {dfr.get('reason')} (retries nightly)")
# ---- 2026-10-19 additions: second target, scrub, timers, half-copied sets
if E.get("ERPB_T2", "none") != "none":
    o = st["offsite"]
    if o.get("result") == "FAIL": A("critical", "OFFSITE_FAILED", o.get("msg", ""))
    elif old(o, maxage): A("warning", "OFFSITE_STALE", f"second-target copy {o.get('age_hours')}h old ({E.get('ERPB_T2')})")
sc, ins = st["scrub"], st["install"]
if sc.get("result") == "FAIL": A("critical", "SCRUB_FAILED", sc.get("msg", ""))
elif old(sc, 9 * 24) and not ((ins.get("age_hours") or 0) < 8 * 24 and not sc.get("at")): A("warning", "SCRUB_STALE", f"stored sets last re-verified {sc.get('age_hours')}h ago")
w = st["watchdog"]
if w.get("timers_missing"): A("critical", "TIMERS_MISSING", f"systemd timers not installed/enabled: {w.get('timers_missing')} (run install.sh)")
if w.get("at") and w.get("status_in_container") == "no": A("warning", "STATUS_NOT_IN_CONTAINER", "ERPNext cannot see this box's status file")
if E["ERPB_STANDBY"] == "1" and (st["standby"].get("skipped_incomplete") or "").strip():
    A("warning", "STANDBY_SET_INCOMPLETE", f"incomplete standby set(s) from the peer skipped: {st['standby'].get('skipped_incomplete')}")
if E["ERPB_RECV"] == "1" and (st["check"].get("incomplete_newer") or "").strip():
    A("warning", "PEER_SET_INCOMPLETE", f"peer set(s) newer than the newest complete one never finished: {st['check'].get('incomplete_newer')}")
lk = st["link"]
if E["ERPB_SEND"] == "1" and lk.get("path") == "derp":
    A("warning", "LINK_RELAYED", f"pushes to the peer go through Tailscale's DERP relay ({lk.get('derp')}), not a direct path - expect about 1 Mbit/s; last push {st['push'].get('rate_kbps', '?')} KB/s")
elif E["ERPB_SEND"] == "1" and st["push"].get("rate_kbps", "").isdigit() and int(st["push"]["rate_kbps"]) < int(E.get("ERPB_LINKMIN") or 1000) and int(st["push"].get("bytes_sent") or 0) > 50 * 1048576:
    A("warning", "LINK_SLOW", f"last push ran at {st['push']['rate_kbps']} KB/s ({lk.get('path') or 'path unknown'}{', userspace networking' if lk.get('tun') == 'no' else ''})")
if (progress or {}).get("incoming", {}).get("sets"):
    for e in progress["incoming"]["sets"]:
        if e.get("stalled"): A("warning", "INCOMING_STALLED", f"{e['kind']} set {e['set']} from the peer has not grown for 6 h ({e['bytes_on_disk']} bytes on disk)")
if promoted: A("critical", "PROMOTED", f"this box is serving {promoted.get('ORIGIN')}'s data since {promoted.get('AT')}")
if os.path.exists(E["ERPB_FENCED"]): A("warning", "FENCED", "production site is in read-only mode")
out = {
  "schema": "erp-backup-status/1", "generated_at": now.isoformat(timespec="seconds"),
  "box": E["ERPB_ME"], "host": E["ERPB_HOST"], "peer": E["ERPB_PEER"], "kit_version": E["ERPB_KIT"],
  "site": E["ERPB_SITE"], "standby_site": E["ERPB_SS"],
  "roles": {"send": E["ERPB_SEND"] == "1", "receive": E["ERPB_RECV"] == "1", "standby": E["ERPB_STANDBY"] == "1",
            "remote_restore_expected": E.get("ERPB_EXPECT") == "1", "remote_restore_max_hours": float(E.get("ERPB_RRMAX") or maxage),
            "archive_test_max_days": float(E.get("ERPB_ATMAX") or 35), "standby_every": E.get("ERPB_EVERY") or "daily"},
  "vocabulary": {"result": "job ran: OK|FAIL", "check": "restore verified: Pass|Partial|Fail"},
  "retention": {"daily": int(E.get("ERPB_KD") or 14), "weekly": int(E.get("ERPB_KW") or 8), "monthly": int(E.get("ERPB_KM") or 12)},
  "offsite": st["offsite"] if E.get("ERPB_T2", "none") != "none" else None, "target2_kind": E.get("ERPB_T2", "none"),
  "scrub": st["scrub"], "watchdog": st["watchdog"], "last_stage_upgrade": st["stage"] or None,
  "progress": progress, "link": st["link"] or None, "push_resume": st["resume"] or None,
  "own_backup": b, "push": st["push"], "remote_restore_of_my_data": receipt,
  "peer_copies_check": st["check"], "standby_of_peer": st["standby"], "standby_deferred": st["standby_defer"] or None, "last_archive_test": st["archive_test"],
  "promoted": promoted, "fenced": os.path.exists(E["ERPB_FENCED"]),
  "alerts": alerts, "overall": "critical" if any(a["level"] == "critical" for a in alerts) else ("warning" if alerts else "ok"),
}
print(json.dumps(out, indent=1))
PY
mv "$BASE/status.json.tmp" "$BASE/status.json"
if [ "${STATUS_TO_CONTAINER:-1}" = 1 ]; then
  docker exec -u frappe "$CONTAINER" mkdir -p "$BENCH/sites/erp_backup_status" >/dev/null 2>&1 \
  && docker cp "$BASE/status.json" "$CONTAINER:$BENCH/sites/erp_backup_status/$ME.json" >/dev/null 2>&1 \
  && docker exec -u root "$CONTAINER" chown frappe:frappe "$BENCH/sites/erp_backup_status/$ME.json" >/dev/null 2>&1 || true
fi
# The PEER's status (it rides along with its receipts): with it, this box's ERPNext can raise REPORTER_DEAD for the
# peer when the peer goes silent. Off by default: a second file in the directory needs the backup_box flag set first.
PS="$RECV_DIR/receipts/status-$PEER_NAME.json"
if [ "${PEER_STATUS_TO_CONTAINER:-0}" = 1 ] && [ -f "$PS" ] && \
   python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("schema")=="erp-backup-status/1" and d.get("box")==sys.argv[2] else 1)' "$PS" "$PEER_NAME" 2>/dev/null; then
  docker cp "$PS" "$CONTAINER:$BENCH/sites/erp_backup_status/$PEER_NAME.json" >/dev/null 2>&1 \
  && docker exec -u root "$CONTAINER" chown frappe:frappe "$BENCH/sites/erp_backup_status/$PEER_NAME.json" >/dev/null 2>&1 || true
fi
EOF_REPORT

# ---------------------------------------------------------------- install.sh
cat > "$NB/install.sh" <<'EOF_INSTALL'
#!/bin/bash
# (Re)install systemd timers from erp-backup.conf. Run after setup changes and after every umbrelOS update.
set -euo pipefail
STAGE=install
. "$(dirname "$0")/common.sh"
need_root
SD="${ERP_KIT_SYSTEMD_DIR:-/etc/systemd/system}"; B="$BASE/bin"
unit() { # unit NAME DESCRIPTION TIME|CALENDAR EXECSTART...   (HH:MM, or a full systemd OnCalendar expression)
  local n="$1" d="$2" t="$3"; shift 3
  { echo "[Unit]"; echo "Description=$d"; echo "Wants=network-online.target"; echo "After=network-online.target docker.service"; echo
    echo "[Service]"; echo "Type=oneshot"; for e in "$@"; do echo "ExecStart=/bin/bash $B/$e"; done
    echo "Nice=10"; echo "IOSchedulingClass=idle"; echo "TimeoutStartSec=4h"; } > "$BASE/systemd/$n.service"
  { echo "[Unit]"; echo "Description=$d (timer)"; echo; echo "[Timer]"; if [[ "$t" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then echo "OnCalendar=*-*-* $t:00"; else echo "OnCalendar=$t"; fi; echo "RandomizedDelaySec=5m"; echo "Persistent=true"; echo
    echo "[Install]"; echo "WantedBy=timers.target"; } > "$BASE/systemd/$n.timer"
}
on()  { install -m 644 "$BASE/systemd/$1.service" "$SD/$1.service"; install -m 644 "$BASE/systemd/$1.timer" "$SD/$1.timer"; }
off() { systemctl disable --now "$1.timer" >/dev/null 2>&1 || true; rm -f "$SD/$1.service" "$SD/$1.timer"; }
unit erp-backup        "ERPNext ($ME) encrypted backup + push to $PEER_NAME" "$BACKUP_TIME" backup.sh push.sh
# weekly mode: wake daily at STANDBY_AT; the script refreshes on STANDBY_DAY, and retries the next nights after a deferral
unit erp-standby       "ERPNext warm standby refresh of $PEER_NAME data ($STANDBY_EVERY)" "${STANDBY_AT:-$STANDBY_TIME}" standby-refresh.sh
unit erp-recv-check    "Verify ERPNext backups received from $PEER_NAME"      "$CHECK_TIME"  recv-check.sh
unit erp-offsite       "Copy ERPNext ($ME) encrypted archives to the second target" "${TARGET2_TIME:-04:30}" offsite.sh
unit erp-scrub         "Re-verify every stored ERPNext backup set"           "${SCRUB_CALENDAR:-Sun *-*-* 08:30:00}" scrub.sh
unit erp-watchdog      "erp-backup self-check and notification"              "${WATCHDOG_TIME:-07:45}" watchdog.sh
unit erp-progress      "erp-backup live progress + resume of a failed push"   "*:0/2" tick.sh
unit erp-push          "ERPNext ($ME) push to $PEER_NAME (on demand; started by tick.sh to resume a failed push)" "*-*-* 00:00" push.sh
T2ON=0; [ "${TARGET2_KIND:-none}" != none ] && T2ON=1; ALWAYS=1
if [ "$SEND_ENABLED" = 1 ];    then on erp-backup;     else off erp-backup; fi
if [ "$STANDBY_ENABLED" = 1 ]; then on erp-standby;    else off erp-standby; fi
if [ "$RECV_ENABLED" = 1 ];    then on erp-recv-check; else off erp-recv-check; fi
if [ "$T2ON" = 1 ];            then on erp-offsite;    else off erp-offsite; fi
on erp-scrub; on erp-watchdog; on erp-progress
install -m 644 "$BASE/systemd/erp-push.service" "$SD/erp-push.service"; rm -f "$SD/erp-push.timer"   # service only, no timer
systemctl daemon-reload
for t in erp-backup:SEND_ENABLED erp-standby:STANDBY_ENABLED erp-recv-check:RECV_ENABLED erp-offsite:T2ON erp-scrub:ALWAYS erp-watchdog:ALWAYS erp-progress:ALWAYS; do
  n=${t%%:*}; v=${t##*:}; [ "${!v}" = 1 ] && systemctl enable --now "$n.timer" >/dev/null
done
state_put install result=OK at="$(date -Is)" send="$SEND_ENABLED" recv="$RECV_ENABLED" standby="$STANDBY_ENABLED" target2="${TARGET2_KIND:-none}" kit="$(cat "$BASE/KIT_VERSION" 2>/dev/null)"
status "OK install send=$SEND_ENABLED recv=$RECV_ENABLED standby=$STANDBY_ENABLED"
report_quiet
systemctl list-timers 'erp-*' --all --no-pager
EOF_INSTALL

# ---------------------------------------------------------------- status.sh
cat > "$NB/status.sh" <<'EOF_STATUS'
#!/bin/bash
# Read-only report. Paste the whole output back to Claude. Contains no secrets.
STAGE=status
. "$(dirname "$0")/common.sh"
need_root
bash "$(dirname "$0")/report.sh" >/dev/null 2>&1
echo "===== erp-backup status: $(hostname) role=$ME kit=$(cat "$BASE/KIT_VERSION" 2>/dev/null) at $(date -Is)"
[ -f "$BASE/PROMOTED" ] && echo "!!!!! PROMOTED: $(tr '\n' ' ' < "$BASE/PROMOTED")"
[ -f "$BASE/FENCED" ] && echo "!!!!! FENCED: production site is read-only"
echo "--- config"
grep -E '^(CONTAINER|SITE|KEEP_|WEEKLY_DOW|BACKUP_TIME|STANDBY_TIME|CHECK_TIME|WATCHDOG_TIME|PEER_NAME|PEER_HOST|PRIMARY_HOSTNAME|RECV_DIR|MAX_AGE_HOURS|SEND_ENABLED|RECV_ENABLED|SEND_STANDBY_SET|STANDBY_ENABLED|ALLOW_STANDBY|EXPECT_REMOTE_RESTORE|STANDBY_SITE|PROMOTE_ALLOWED|ALLOW_ARCHIVE_TEST|PURGE_BENCH_PLAINTEXT|DB_CONTAINER|DBPW_SOURCE|STANDBY_EVERY|STANDBY_DAY|STANDBY_AT|STANDBY_WAIT_MIN|STANDBY_MIN_AVAIL_MB|STANDBY_MAX_SWAP_PCT|STANDBY_STOP_APPS_ENABLED|STANDBY_STOP_APPS|REMOTE_RESTORE_MAX_HOURS|TS_MODE|TS_CONTAINER|PUSH_TRANSPORT|PEER_LOCAL_DIR|PEER_STATUS_TO_CONTAINER|TARGET2_[A-Z_]+|RCLONE_IMAGE|SCRUB_CALENDAR|STAGE_[A-Z_]+|NOTIFY_REPEAT_HOURS)=' "$BASE/erp-backup.conf"
echo "ARCHIVE_RECIPIENT: $([ -n "${ARCHIVE_RECIPIENT:-}" ] && echo "${ARCHIVE_RECIPIENT:0:16}...${ARCHIVE_RECIPIENT: -6}" || echo NOT SET)   NOTIFY_URL set: $([ -n "${NOTIFY_URL:-}" ] && echo yes || echo no)"
echo "age: $("$AGE" --version 2>/dev/null || echo MISSING)   db container: $(. "$BASE/bin/lib-site.sh"; find_db_container || true)"
echo "--- containers / sites"
docker ps --format '{{.Names}}  {{.Status}}' 2>/dev/null | grep -i erpnext || echo "(no erpnext containers seen)"
docker exec "$CONTAINER" sh -c "ls -1 '$BENCH/sites' | grep -v -e '\.json$' -e '^assets$'" 2>/dev/null | sed 's/^/  site dir: /'
echo "--- timers"
systemctl list-timers 'erp-*' --all --no-pager 2>/dev/null || true
PP=$(other_push_pids | tr '\n' ' '); [ -n "${PP// /}" ] && echo "PUSH IN PROGRESS to $PEER_NAME: $(push_progress $PP)" || echo "no push in progress"
echo "--- progress (progress.sh --watch for live)"; bash "$(dirname "$0")/progress.sh" 2>/dev/null | sed 's/^/  /'
[ -f "$STATE/link.env" ] && echo "--- path to $PEER_NAME: $(tr '\n' ' ' < "$STATE/link.env")"
for u in erp-backup erp-push erp-standby erp-recv-check erp-offsite erp-scrub erp-watchdog erp-progress; do echo "$u.service: $(systemctl show -p Result --value "$u.service" 2>/dev/null || echo n/a)"; done
echo "--- last 15 status lines"
tail -n 15 "$STATUS" 2>/dev/null || echo "(no status.log yet)"
echo "--- own encrypted archives"
ls -1 "$BASE/own/daily" 2>/dev/null | tail -n 3; echo "weekly: $(ls -1 "$BASE/own/weekly" 2>/dev/null | tr '\n' ' ')"; echo "monthly: $(ls -1 "$BASE/own/monthly" 2>/dev/null | tr '\n' ' ')"
for st in offsite scrub watchdog stage; do [ -f "$STATE/$st.env" ] && echo "$st: $(grep -E '^(result|at|check|set|sets|kind|msg|timers_missing|image)=' "$STATE/$st.env" | tr '\n' ' ')"; done
N=$(newest_dir "$BASE/own/daily"); [ -n "$N" ] && { ls -la "$N" | sed 's/^/  /'; echo "own total: $(du -sh "$BASE/own" | cut -f1)"; }
echo "plaintext waiting in work/: $(find "$BASE/work" -type f 2>/dev/null | wc -l) files"
echo "--- received from $PEER_NAME ($RECV_DIR)"
if [ -d "$RECV_DIR/daily" ]; then ls -1 "$RECV_DIR/daily" | tail -n 3; echo "weekly: $(ls -1 "$RECV_DIR/weekly" 2>/dev/null | tr '\n' ' ')"; echo "standby sets waiting: $(ls -1 "$RECV_DIR/standby" 2>/dev/null | tr '\n' ' ') (incomplete: $(incomplete_sets "$RECV_DIR/standby" MANIFEST.sha256 | tr '\n' ' '))"; echo "received total: $(du -sh "$RECV_DIR" | cut -f1)"; else echo "(nothing received)"; fi
echo "--- memory"
( . "$BASE/bin/lib-site.sh"; mem_snapshot; echo "$(mem_desc) -> standby refresh would $(mem_ok && echo run || echo be DEFERRED)" )
[ -f "$STATE/standby_defer.env" ] && echo "last deferral: $(tr '\n' ' ' < "$STATE/standby_defer.env")"
echo "--- tailnet path"
echo "$(link_desc); tailscale0: $(ip -4 addr show tailscale0 2>/dev/null | grep -o 'inet [0-9./]*' || echo absent)"
echo "peer $PEER_NAME sshd: $(peer_banner || true)"
echo "authorized from= : $(grep ' erp-backup-from-' "$UMBREL_HOME/.ssh/authorized_keys" 2>/dev/null | sed -E 's/^from="([^"]*)".* (erp-backup-from-[a-z]+)$/\2 from=\1/' | tr '\n' ' ')"
echo "recent sshd auth lines:"; journalctl -u ssh -u sshd --since "-2 days" --no-pager 2>/dev/null | grep -E 'Accepted publickey|not from a permitted host|rrsync' | tail -n 5 | sed 's/^/  /' || true
echo "--- keys"
[ -f "$SSH_KEY.pub" ] && echo "send key: $(ssh-keygen -lf "$SSH_KEY.pub")" || echo "send key: none"
[ -s "$KNOWN_HOSTS" ] && echo "pinned $PEER_NAME: $(ssh-keygen -lf "$KNOWN_HOSTS")" || echo "pinned peer: none"
echo "authorized erp-backup lines: $(grep -c ' erp-backup-from-' "$UMBREL_HOME/.ssh/authorized_keys" 2>/dev/null || echo 0)"
echo "--- disk"; df -h "$BASE" | tail -n 1
echo "--- tools"; for t in rsync rrsync python3 flock curl; do printf '%s=%s ' "$t" "$(command -v $t || echo MISSING)"; done; echo
echo "--- status.json (what ERPNext/MCP will read)"
cat "$BASE/status.json" 2>/dev/null || echo "(not generated)"
echo "===== end"
EOF_STATUS

chmod 700 "$NB"/*.sh "$NB"/*.py
chmod 600 "$NB/common.sh" "$NB/lib-site.sh"
# atomic: rename(2) each new file over the old one; a running script keeps its open (old) file
for f in "$NB"/*; do mv -f "$f" "$BASE/bin/$(basename "$f")"; done
rmdir "$NB" 2>/dev/null || true
echo "$KIT_VERSION" > "$BASE/KIT_VERSION.tmp" && mv -f "$BASE/KIT_VERSION.tmp" "$BASE/KIT_VERSION"
trap - EXIT
if [ -f "$BASE/state/install.env" ]; then
  bash "$BASE/bin/install.sh" >/dev/null 2>&1 && echo "Timers re-armed from erp-backup.conf." || echo "WARN: install.sh failed - run: sudo bash $BASE/bin/install.sh"
else
  for t in $TIMERS_WERE; do systemctl start "$t.timer" >/dev/null 2>&1 || true; done
fi

echo
echo "erp-backup kit $KIT_VERSION installed for role '$ME' in $BASE"
echo "Scripts: $(cd "$BASE/bin" && ls | tr '\n' ' ')"
[ -f "$BASE/state/install.env" ] && echo "Next step: sudo bash $BASE/bin/status.sh" || echo "Next step (first install): the setup steps, then sudo bash $BASE/bin/install.sh"
