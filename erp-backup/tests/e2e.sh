#!/bin/bash
# End-to-end test of erp-backup-kit.sh against two real ERPNext containers (a primary and a secondary),
# run inside the harness image with the docker socket mounted:
#
#   docker run --rm --network host -v /var/run/docker.sock:/var/run/docker.sock \
#     -v "$PWD/..":/kit:ro -v <scratch>:/t erp-backup-harness:test bash /kit/tests/e2e.sh
#
# Env: CONT_A / CONT_B (ERPNext server containers), STAGE_IMAGE (image for the staged-upgrade test, empty = skip).
# Uses a throwaway age key generated here, local-directory "pushes" instead of SSH, and a local notify sink.
set -euo pipefail
CONT_A="${CONT_A:-kitA_server}"; CONT_B="${CONT_B:-kitB_server}"
KIT=/kit/erp-backup-kit.sh
A=/t/rootA; B=/t/rootB; export ERP_KIT_SYSTEMD_DIR=/t/systemd
rm -rf "$A" "$B" /t/target2 /t/systemd /t/notify.log; mkdir -p "$A" "$B" /t/target2 /t/home /t/systemd
PASS=0; FAILS=()
ok()   { PASS=$((PASS + 1)); echo "  PASS $*"; }
bad()  { FAILS+=("$*"); echo "  FAIL $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
st()   { sed -n "s/^$3=//p" "$1/erp-backup/state/$2.env" 2>/dev/null | tail -n1; }   # st ROOT STAGE KEY
js()   { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); exec("try: print("+sys.argv[2]+")\nexcept Exception: print(\"?\")")' "$1/erp-backup/status.json" "$2"; }
codes() { js "$1" '" ".join(sorted(a["code"] for a in d["alerts"]))'; }
run()  { local r="$1"; shift; ERP_KIT_HOSTNAME=x bash "$r/erp-backup/bin/$@"; }

python3 /kit/tests/notify_sink.py 18765 /t/notify.log & SINK=$!
trap 'kill $SINK 2>/dev/null || true' EXIT
rm -f /t/test-age-key.txt; age-keygen -o /t/test-age-key.txt 2>/dev/null; RCPT=$(age-keygen -y /t/test-age-key.txt)

echo "== fixture: give the primary's site an encryption key and one encrypted secret, like a real site"
docker exec -i -u frappe -w /home/frappe/frappe-bench/sites "$CONT_A" ../env/bin/python - <<'PY'
import frappe
frappe.init(site="frontend", sites_path="."); frappe.connect()
from frappe.utils.password import get_encryption_key, set_encrypted_password
get_encryption_key(); set_encrypted_password("User", "Administrator", "e2e-test-secret", "api_secret"); frappe.db.commit()
frappe.destroy()
PY

echo "== reset: drop a standby site left by an earlier run"
if docker exec "$CONT_B" test -d /home/frappe/frappe-bench/sites/standby-alpha; then
  DBC=$(docker ps --filter "label=com.docker.compose.project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$CONT_B")" --format '{{.Names}}' | grep -i db | head -n1)
  RP=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$DBC" | sed -n 's/^MYSQL_ROOT_PASSWORD=//p')
  docker exec -u frappe -w /home/frappe/frappe-bench -e RP="$RP" "$CONT_B" sh -c 'bench drop-site standby-alpha --db-root-password "$RP" --no-backup --force' >/dev/null 2>&1 || true
  docker exec -u root "$CONT_B" rm -rf /home/frappe/frappe-bench/sites/standby-alpha /home/frappe/frappe-bench/archived_sites
  RP=""
fi
docker exec -u root "$CONT_A" rm -rf /home/frappe/frappe-bench/sites/erp_backup_status
docker exec -u root "$CONT_B" rm -rf /home/frappe/frappe-bench/sites/erp_backup_status

echo "== install"
ERP_KIT_HOSTNAME=boxa ERP_KIT_UMBREL_HOME=/t/home bash "$KIT" primary --me=alpha --peer=beta --peer-host=boxb.example --root="$A" --container="$CONT_A" >/dev/null
ERP_KIT_HOSTNAME=boxb ERP_KIT_UMBREL_HOME=/t/home bash "$KIT" secondary --me=beta --peer=alpha --peer-host=boxa.example --primary-hostname=boxa --root="$B" --container="$CONT_B" >/dev/null
check "no host or IP baked into the generated scripts" bash -c "! grep -rqE '100\.[0-9]+\.[0-9]+\.[0-9]+|orchardmeadow|umbrel\.local' $A/erp-backup/bin $B/erp-backup/bin"
check "refuses primary role on a non-primary host" bash -c "! ERP_KIT_HOSTNAME=other bash $KIT primary --root=$A >/dev/null 2>&1"
check "refuses secondary role on the primary host" bash -c "! ERP_KIT_HOSTNAME=boxa bash $KIT secondary --root=$B >/dev/null 2>&1"
check "re-install keeps names and hosts" bash -c "ERP_KIT_HOSTNAME=boxa bash $KIT primary --root=$A >/dev/null && grep -q '^PEER_HOST=boxb.example' $A/erp-backup/erp-backup.conf"
mkdir -p "$B/erp-backup-from-alpha" "$A/erp-backup-from-beta"
for R in "$A" "$B"; do
  echo "$RCPT" | run "$R" set-recipient.sh >/dev/null
  run "$R" set-conf.sh PUSH_TRANSPORT local >/dev/null
  run "$R" set-conf.sh SEND_ENABLED 1 >/dev/null
  run "$R" set-conf.sh RECV_ENABLED 1 >/dev/null
  run "$R" set-conf.sh NOTIFY_URL http://127.0.0.1:18765/ >/dev/null
done
run "$A" set-conf.sh PEER_LOCAL_DIR "$B/erp-backup-from-alpha" >/dev/null
run "$B" set-conf.sh PEER_LOCAL_DIR "$A/erp-backup-from-beta" >/dev/null
run "$A" set-conf.sh TARGET2_KIND dir >/dev/null; run "$A" set-conf.sh TARGET2_PATH /t/target2 >/dev/null; run "$A" set-conf.sh TARGET2_REQUIRE_MOUNT 0 >/dev/null
check "set-conf refuses an unknown key" bash -c "! ERP_KIT_HOSTNAME=x bash $A/erp-backup/bin/set-conf.sh NO_SUCH_KEY 1 >/dev/null 2>&1"
check "set-conf refuses a value with a pipe" bash -c "! ERP_KIT_HOSTNAME=x bash $A/erp-backup/bin/set-conf.sh STAGE_PORT '1|2' >/dev/null 2>&1"

echo "== primary: backup + two-phase push"
run "$A" backup.sh >/dev/null
SET1=$(st "$A" backup set)
check "backup OK" [ "$(st "$A" backup result)" = OK ]
check "SANITY.txt in the encrypted set" test -s "$A/erp-backup/own/daily/$SET1/SANITY.txt"
check "monthly link made" test -d "$A/erp-backup/own/monthly/$(date +%Y-%m)"
check "archive is age-encrypted" bash -c "head -c 21 $A/erp-backup/own/daily/$SET1/*-database.sql.gz.age | grep -q age-encryption.org"
PUSH_RETRY_SLEEP=1 run "$A" push.sh >/dev/null
check "push OK with duration recorded" bash -c "[ \"$(st "$A" push result)\" = OK ] && [ -n \"$(st "$A" push duration_s)\" ]"
check "peer got the complete encrypted set" test -f "$B/erp-backup-from-alpha/daily/$SET1/SHA256SUMS"
check "peer got the complete standby set" test -f "$B/erp-backup-from-alpha/standby/$SET1/MANIFEST.sha256"
check "peer got the primary's status" test -f "$B/erp-backup-from-alpha/receipts/status-alpha.json"

echo "== secondary: first standby build"
run "$B" standby-init.sh --force > /t/standby-init.log 2>&1 || { tail -n 20 /t/standby-init.log; bad "standby-init"; }
check "standby site exists" docker exec "$CONT_B" test -f /home/frappe/frappe-bench/sites/standby-alpha/site_config.json
check "standby-init check Pass" [ "$(st "$B" standby check)" = Pass ]

echo "== the 2026-10-17 failure: a newer set cut off in transfer"
sleep 61   # backup stamps are per minute
run "$A" backup.sh >/dev/null; SET2=$(st "$A" backup set)
PUSH_RETRY_SLEEP=1 run "$A" push.sh >/dev/null
CUT=$(date -d '+1 day' +%F)_0232
cp -a "$B/erp-backup-from-alpha/standby/$SET2" "$B/erp-backup-from-alpha/standby/$CUT"; rm -f "$B/erp-backup-from-alpha/standby/$CUT/MANIFEST.sha256"
touch -d '-2 days' "$B/erp-backup-from-alpha/standby/$CUT"
STANDBY_WAIT_MIN=0 run "$B" standby-refresh.sh --now --force > /t/refresh.log 2>&1 || { tail -n 20 /t/refresh.log; bad "standby-refresh"; }
check "refresh restored the newest COMPLETE set" [ "$(st "$B" standby set)" = "$SET2" ]
check "refresh check Pass (files emptied first: no stale extras)" [ "$(st "$B" standby check)" = Pass ]
check "sanity compared" [ "$(st "$B" standby sanity_ok)" = yes ]
check "the cut-off set was reported" bash -c "grep -q '$CUT' $B/erp-backup/state/standby.env"
run "$B" report.sh
check "STANDBY_SET_INCOMPLETE raised" bash -c "echo '$(codes "$B")' | grep -q STANDBY_SET_INCOMPLETE"
run "$B" recv-check.sh >/dev/null
check "recv-check dropped the >36h incomplete standby set" test ! -e "$B/erp-backup-from-alpha/standby/$CUT"
check "receipt went back to the primary" test -f "$A/erp-backup-from-beta/receipts/standby-of-alpha.json"
run "$A" report.sh
check "primary sees its restore as Pass" [ "$(js "$A" 'd["remote_restore_of_my_data"]["result"]')" = Pass ]
check "primary has no REMOTE_RESTORE alerts" bash -c "! echo '$(codes "$A")' | grep -q REMOTE_RESTORE"

echo "== a set still arriving is waited for, not failed on"
ARR=$(date -d '+2 days' +%F)_0232
cp -a "$B/erp-backup-from-alpha/daily/$SET2" "$B/erp-backup-from-alpha/daily/$ARR" 2>/dev/null || true
rm -f "$B/erp-backup-from-alpha/daily/$ARR/SHA256SUMS"
run "$B" recv-check.sh >/dev/null
check "recv-check OK while a newer daily is in transit" [ "$(st "$B" check result)" = OK ]
check "a fresh in-transit set is not flagged" [ -z "$(st "$B" check incomplete_newer)" ]
touch -d '-7 hours' "$B/erp-backup-from-alpha/daily/$ARR"; run "$B" recv-check.sh >/dev/null
check "a set without its marker for >6h is flagged" [ "$(st "$B" check incomplete_newer)" = "$ARR" ]
rm -rf "$B/erp-backup-from-alpha/daily/$ARR"

echo "== second target"
run "$A" offsite.sh >/dev/null
check "offsite OK" [ "$(st "$A" offsite result)" = OK ]
check "offsite copy verifies" bash -c "cd /t/target2/alpha/daily/$SET2 && sha256sum -c --quiet SHA256SUMS"
check "no plaintext on the second target" bash -c "! find /t/target2 -name '*.sql.gz' | grep -q ."
run "$A" set-conf.sh TARGET2_REQUIRE_MOUNT 1 >/dev/null
check "refuses an unmounted target" bash -c "! ERP_KIT_HOSTNAME=x bash $A/erp-backup/bin/offsite.sh >/dev/null 2>&1"
run "$A" set-conf.sh TARGET2_REQUIRE_MOUNT 0 >/dev/null; run "$A" offsite.sh >/dev/null

echo "== scrub"
run "$B" scrub.sh >/dev/null
check "scrub OK" [ "$(st "$B" scrub result)" = OK ]
F=$(ls "$B"/erp-backup-from-alpha/daily/"$SET1"/*-database.sql.gz.age); cp "$F" /t/keep.age; printf 'X' | dd of="$F" bs=1 seek=100 conv=notrunc 2>/dev/null
check "scrub catches a flipped byte" bash -c "! ERP_KIT_HOSTNAME=x bash $B/erp-backup/bin/scrub.sh >/dev/null 2>&1"
run "$B" report.sh
check "SCRUB_FAILED is critical" [ "$(js "$B" 'd["overall"]')" = critical ]
cp /t/keep.age "$F"; run "$B" scrub.sh >/dev/null

echo "== watchdog, timers, notifications"
run "$A" install.sh >/dev/null
check "timers installed" bash -c "ls /t/systemd/erp-backup.timer /t/systemd/erp-scrub.timer /t/systemd/erp-watchdog.timer /t/systemd/erp-offsite.timer >/dev/null"
check "scrub timer is weekly" grep -q 'OnCalendar=Sun \*-\*-\* 08:30:00' /t/systemd/erp-scrub.timer
rm -f /t/systemd/erp-backup.timer
run "$A" watchdog.sh >/dev/null
check "watchdog re-installed a missing timer" bash -c "[ -f /t/systemd/erp-backup.timer ] && [ \"$(st "$A" watchdog timers_repaired)\" = erp-backup ]"
check "status file is in the primary's ERPNext" [ "$(st "$A" watchdog status_in_container)" = yes ]
: > /t/notify.log; rm -f "$A/erp-backup/state/notify.env"   # earlier runs already announced this problem
run "$A" watchdog.sh >/dev/null; run "$A" watchdog.sh >/dev/null
check "one notification for a problem, not one per run" [ "$(grep -c . /t/notify.log)" = 1 ]
check "the notification names the problem" grep -q 'PEER_COPIES_BAD' /t/notify.log
run "$B" backup.sh >/dev/null; PUSH_RETRY_SLEEP=1 run "$B" push.sh >/dev/null; run "$A" recv-check.sh >/dev/null
run "$A" watchdog.sh >/dev/null
check "primary is ok once the peer's copies arrive" [ "$(js "$A" 'd["overall"]')" = ok ]
check "one 'recovered' message" [ "$(grep -c recovered /t/notify.log)" = 1 ]
run "$A" watchdog.sh >/dev/null
check "no repeat while ok" [ "$(grep -c . /t/notify.log)" = 2 ]

echo "== peer status visible to the secondary's ERPNext"
run "$B" set-conf.sh PEER_STATUS_TO_CONTAINER 1 >/dev/null; run "$B" report.sh
check "alpha.json copied into the secondary's ERPNext" docker exec "$CONT_B" test -f /home/frappe/frappe-bench/sites/erp_backup_status/alpha.json

echo "== run-now"
sleep 61
PUSH_RETRY_SLEEP=1 run "$A" run-now.sh > /t/run-now.log 2>&1 || { tail /t/run-now.log; bad "run-now"; }
check "run-now made a new set and pushed it" [ "$(st "$A" push set)" = "$(st "$A" backup set)" ]
check "run-now printed a summary" grep -q '^== alpha: overall' /t/run-now.log

if [ -n "${STAGE_IMAGE:-}" ]; then
  echo "== staged upgrade on a copy ($STAGE_IMAGE)"
  run "$B" set-conf.sh STAGE_PORT "${STAGE_PORT:-8083}" >/dev/null
  run "$B" stage-upgrade.sh --image="$STAGE_IMAGE" --force > /t/stage.log 2>&1 || { tail -n 30 /t/stage.log; bad "stage-upgrade"; }
  check "staged upgrade Pass" [ "$(st "$B" stage check)" = Pass ]
  check "migrate exit 0" [ "$(st "$B" stage migrate_exit)" = 0 ]
  check "throwaway stack removed" bash -c "! docker ps -a --format '{{.Names}}' | grep -q erp-stage-beta"
  check "no plaintext left in work/" bash -c "[ -z \"\$(find $B/erp-backup/work -type f 2>/dev/null)\" ]"
  echo "  $(grep '^STAGE' /t/stage.log | tail -n1)"
fi

echo
echo "RESULT: $PASS passed, ${#FAILS[@]} failed"
for f in "${FAILS[@]}"; do echo "  - $f"; done
[ ${#FAILS[@]} = 0 ]
