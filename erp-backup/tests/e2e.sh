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
# hold_lock FILE SECONDS: hold FILE's flock in the background for SECONDS; returns once it is really held
hold_lock() { ( exec 8>>"$1"; flock 8; sleep "$2" ) & HOLD=$!; local i; for i in $(seq 1 40); do ( exec 9>>"$1"; flock -n 9 ) 2>/dev/null || return 0; sleep 0.25; done; }

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
docker exec -u frappe "$CONT_A" sh -c 'mkdir -p /home/frappe/frappe-bench/sites/frontend/private/files && head -c 25165824 /dev/urandom > /home/frappe/frappe-bench/sites/frontend/private/files/e2e-photo.bin'

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
export FAKE_SSH_MAP="boxb.example=$B/erp-backup-from-alpha,boxa.example=$A/erp-backup-from-beta" ERP_KIT_TEST_RSH=/usr/local/bin/fake-ssh
for R in "$A" "$B"; do
  echo "$RCPT" | run "$R" set-recipient.sh >/dev/null
  mkdir -p "$R/erp-backup/keys"; echo dummy > "$R/erp-backup/keys/send_ed25519"; echo "boxx ssh-ed25519 AAAA" > "$R/erp-backup/keys/known_hosts"
  run "$R" set-conf.sh PUSH_TRANSPORT ssh >/dev/null
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
check "push went over the ssh transport (fake-ssh -> the real rrsync jail)" [ "$(st "$A" push transport)" = ssh ]
check "push recorded bytes sent and rate" bash -c "[ \"\$(sed -n 's/^bytes_sent=//p' $A/erp-backup/state/push.env)\" -gt 20000000 ] && grep -q '^rate_kbps=' $A/erp-backup/state/push.env"
check "the peer was told what was coming (inflight notice, done)" bash -c "grep -q '\"state\":\"done\"' $B/erp-backup-from-alpha/receipts/inflight-alpha.json"

echo "== one push at a time (2026-10-19.2)"
hold_lock "$A/erp-backup/.push.lock" 25
PUSH_WAIT_POLL_S=5 PUSH_RETRY_SLEEP=999 timeout 300 bash -c "ERP_KIT_HOSTNAME=x bash $A/erp-backup/bin/push.sh" > /t/pushwait1.log 2>&1 || true
wait $HOLD || true
check "a second push waits for the one holding the lock" grep -q "another push holds" /t/pushwait1.log
check "... then goes ahead and succeeds" bash -c "grep -q 'the other push has finished' /t/pushwait1.log && [ \"$(st "$A" push result)\" = OK ] && [ \"$(st "$A" push waited_for_other_push_s)\" -gt 0 ]"
bash -c 'sleep 25; true' "$A/erp-backup/bin/push.sh" & OLD=$!; sleep 1     # an older kit's push: no lock, seen by its process
PUSH_WAIT_POLL_S=5 PUSH_RETRY_SLEEP=999 timeout 300 bash -c "ERP_KIT_HOSTNAME=x bash $A/erp-backup/bin/push.sh" > /t/pushwait2.log 2>&1 || true
wait $OLD || true
check "a lock-less push of an older kit is recognised and waited for, with progress" grep -q "is in progress (nightly or manual: running" /t/pushwait2.log
check "... then succeeds" [ "$(st "$A" push result)" = OK ]
mkdir -p /t/shim; rm -f /t/shim/n
cat > /t/shim/rsync <<'SHIM'
#!/bin/bash
n=$(( $(cat /t/shim/n 2>/dev/null || echo 0) + 1 )); echo $n > /t/shim/n
if [ "$n" -le 2 ]; then echo "/usr/bin/rrsync error: Another instance of rrsync is already accessing this directory." >&2; echo "rsync error: error in rsync protocol data stream (code 12)" >&2; exit 12; fi
exec /usr/bin/rsync "$@"
SHIM
chmod +x /t/shim/rsync
PATH=/t/shim:$PATH PUSH_WAIT_POLL_S=2 PUSH_RETRY_SLEEP=999 timeout 300 bash -c "ERP_KIT_HOSTNAME=x bash $A/erp-backup/bin/push.sh" > /t/pushwait3.log 2>&1 || true
check "the peer's rrsync lock is waited out, not counted as a failed attempt" bash -c "grep -q 'still receiving another push' /t/pushwait3.log && ! grep -q 'attempt 1 failed' /t/pushwait3.log && [ \"$(st "$A" push result)\" = OK ] && [ \"$(st "$A" push waited_for_peer_s)\" -gt 0 ]"
sleep 61
hold_lock "$A/erp-backup/.push.lock" 150
PUSH_WAIT_POLL_S=5 run "$A" backup.sh > /t/backupwait.log 2>&1 || true
wait $HOLD || true
check "a backup during a push leaves the outgoing standby set alone until the push ends" grep -q "the other push has finished; going ahead (backup.sh" /t/backupwait.log
check "... and completes" [ "$(st "$A" backup result)" = OK ]
BS=$(st "$A" backup set)
PUSH_RETRY_SLEEP=1 run "$A" run-now.sh --push-only > /t/pushonly.log 2>&1 || true
check "run-now --push-only sends without a new backup" bash -c "[ \"$(st "$A" backup set)\" = '$BS' ] && [ \"$(st "$A" push set)\" = '$BS' ] && ! grep -q '^== backup' /t/pushonly.log"
check "the waiting standby set went with it" test -f "$B/erp-backup-from-alpha/standby/$BS/MANIFEST.sha256"

echo "== live progress (2026-10-19.3)"
run "$A" set-conf.sh PUSH_BWLIMIT_KBPS 1500 >/dev/null
sleep 61; run "$A" backup.sh >/dev/null
( PUSH_RETRY_SLEEP=1 ERP_KIT_HOSTNAME=x bash "$A/erp-backup/bin/push.sh" > /t/push-slow.log 2>&1 ) & SLOW=$!
sleep 12
ERP_KIT_HOSTNAME=x bash "$A/erp-backup/bin/progress.sh" > /t/prog-a.txt 2>&1 || true
ERP_KIT_HOSTNAME=x bash "$B/erp-backup/bin/progress.sh" > /t/prog-b.txt 2>&1 || true
ERP_KIT_HOSTNAME=x bash "$A/erp-backup/bin/progress.sh" --json > /t/prog-a.json 2>&1 || true
echo "== re-install while that push runs (atomic writes keep it alive)"
ERP_KIT_HOSTNAME=boxa bash "$KIT" primary --root="$A" --no-wait > /t/inst-nowait.log 2>&1 && NW=ok || NW=refused
ERP_KIT_HOSTNAME=boxa bash "$KIT" primary --root="$A" --force > /t/inst-force.log 2>&1 || true
wait $SLOW && SLOWRC=0 || SLOWRC=$?
sed -n '1,4s/^/    /p' /t/prog-a.txt; grep -E '^(IN|PEER)' /t/prog-b.txt | sed 's/^/    /' || true
check "progress.sh on the sender shows the push step with % and rate" bash -c "grep -q '^NOW   push:' /t/prog-a.txt && grep -qE '[0-9]+%' /t/prog-a.txt && grep -q '/s' /t/prog-a.txt"
check "progress.sh on the receiver shows the set arriving" grep -qE '^(IN    from alpha: (daily|standby) .*%|PEER  alpha is sending)' /t/prog-b.txt
check "--json carries the live step" python3 -c "import json; d=json.load(open('/t/prog-a.json')); assert d['current']['phase']=='push' and d['current']['bytes_done']>0"
check "the installer refuses with --no-wait while a push runs" [ "$NW" = refused ]
check "an install during a running push does not break it" [ "$SLOWRC" = 0 ]
check "status.json carries the last activity for ERPNext" bash -c "run_r() { :; }; python3 -c \"import json; d=json.load(open('$A/erp-backup/status.json')); assert d['progress']['last']['phase']=='push'\""
run "$A" set-conf.sh PUSH_BWLIMIT_KBPS 0 >/dev/null

echo "== installer waits (no --force) until the job ends"
hold_lock "$A/erp-backup/.push.lock" 20
ERP_KIT_HOSTNAME=boxa timeout 120 bash "$KIT" primary --root="$A" > /t/inst-wait.log 2>&1 && IW=ok || IW=fail
wait $HOLD || true
check "the installer waited, then installed" bash -c "grep -q 'waiting for running erp-backup jobs' /t/inst-wait.log && [ $IW = ok ] && grep -qx \"\$(sed -n 's/^KIT_VERSION=\\\"\\(.*\\)\\\"\$/\\1/p' $KIT)\" $A/erp-backup/KIT_VERSION"

echo "== memory pre-check: MemAvailable, and swap only when active"
printf 'MemAvailable: 3670016 kB\nSwapTotal: 4718592 kB\nSwapFree: 419430 kB\n' > /t/meminfo; printf 'pswpin 1000\n' > /t/vmstat; printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > /t/psi-idle; printf 'some avg10=35.00 avg60=20.00 avg300=5.00 total=9\n' > /t/psi-busy
memtest() { ERP_MEMINFO=/t/meminfo ERP_VMSTAT=/t/vmstat ERP_PSI="$1" MEM_SAMPLE_S=1 bash -c ". $B/erp-backup/bin/common.sh; . $B/erp-backup/bin/lib-site.sh; mem_ok && echo RUN || echo DEFER; mem_desc"; }
M1=$(memtest /t/psi-idle | sed -n 1p); M2=$(memtest /t/psi-busy | sed -n 1p)
check "3.5 GiB available + 91% swap that is idle: restore runs" [ "$M1" = RUN ]
check "the same with memory pressure (PSI): restore defers" [ "$M2" = DEFER ]
echo "    $(memtest /t/psi-idle | sed -n 2p)"

echo "== link probe: direct vs DERP relay"
mkdir -p /t/fakets; cat > /t/fakets/tailscale <<'TS'
#!/bin/bash
case "$1" in
  status) echo '{"TUN":false,"Peer":{"k":{"HostName":"boxb","DNSName":"boxb.example.ts.net.","TailscaleIPs":["100.64.0.2"],"Online":true,"CurAddr":"","Relay":"sea"}}}' ;;
  ping) echo "pong from boxb (100.64.0.2) via DERP(sea) in 48ms" ;;
esac
TS
chmod +x /t/fakets/tailscale
LP=$(PATH=/t/fakets:$PATH bash -c ". $A/erp-backup/bin/common.sh; TS_MODE=direct; link_probe")
check "relayed path read from tailscale status/ping" bash -c "echo '$LP' | grep -qx path=derp && echo '$LP' | grep -qx derp=sea && echo '$LP' | grep -qx tun=no"
bash -c ". $A/erp-backup/bin/common.sh; state_put link at=\"\$(date -Is)\" path=derp derp=sea tun=no"; run "$A" report.sh
check "LINK_RELAYED alert raised" bash -c "grep -q LINK_RELAYED $A/erp-backup/status.json"
rm -f "$A/erp-backup/state/link.env"

echo "== a failed push is resumed by the 2-minute tick"
bash -c ". $A/erp-backup/bin/common.sh; state_put push result=FAIL at=\"\$(date -Is -d '-2 hours')\" msg=simulated set=none"
run "$A" set-conf.sh PUSH_RESUME_AFTER_MIN 0 >/dev/null
rm -f /t/systemd/erp-push.service; run "$A" tick.sh >/dev/null 2>&1 || true
for _ in $(seq 1 30); do [ "$(st "$A" push result)" = OK ] && break; sleep 2; done
check "tick resumed the push and it succeeded" bash -c "[ \"$(st "$A" resume count)\" = 1 ] && [ \"$(st "$A" push result)\" = OK ]"
run "$A" set-conf.sh PUSH_RESUME_AFTER_MIN 60 >/dev/null

echo "== secondary: first standby build"
run "$B" standby-init.sh --force > /t/standby-init.log 2>&1 || { tail -n 20 /t/standby-init.log; bad "standby-init"; }
check "standby site exists" docker exec "$CONT_B" test -f /home/frappe/frappe-bench/sites/standby-alpha/site_config.json
check "standby-init check Pass" [ "$(st "$B" standby check)" = Pass ]

echo "== the 2026-10-17 failure: a newer set cut off in transfer"
sleep 61   # backup stamps are per minute
run "$A" backup.sh >/dev/null; SET2=$(st "$A" backup set)
PUSH_RETRY_SLEEP=1 run "$A" push.sh > /t/push-delta.log 2>&1
SENT2=$(st "$A" push bytes_sent); SBB2=$(st "$A" push standby_bytes); NEWB2=$(st "$A" push new_set_bytes)
check "the standby set went as a delta against the peer's basis (rrsync accepted -yy --copy-dest --mkpath)" bash -c "[ \"$(st "$A" push delta_standby)\" = 1 ] && [ $SENT2 -lt $(( NEWB2 + SBB2 / 2 )) ]"
echo "  (night 2: $((SENT2 / 1048576)) MB sent for a $((NEWB2 / 1048576)) MB encrypted set + $((SBB2 / 1048576)) MB standby set)"
CUT=$(date -d '+1 day' +%F)_0232
cp -a "$B/erp-backup-from-alpha/standby/$SET2" "$B/erp-backup-from-alpha/standby/$CUT"; rm -f "$B/erp-backup-from-alpha/standby/$CUT/MANIFEST.sha256"
touch -d '-2 days' "$B/erp-backup-from-alpha/standby/$CUT"
run "$B" standby-refresh.sh --now --force --wait-min=0 > /t/refresh.log 2>&1 || { tail -n 20 /t/refresh.log; bad "standby-refresh"; }
check "refresh restored the newest COMPLETE set" [ "$(st "$B" standby set)" = "$SET2" ]
check "refresh check Pass (files emptied first: no stale extras)" [ "$(st "$B" standby check)" = Pass ]
check "sanity compared" [ "$(st "$B" standby sanity_ok)" = yes ]
check "the restored set is kept as the next delta basis" bash -c "test -f $B/erp-backup-from-alpha/standby/.basis/MANIFEST.sha256 && [ ! -e $B/erp-backup-from-alpha/standby/$SET2 ]"
check "the cut-off set was reported" bash -c "grep -q '$CUT' $B/erp-backup/state/standby.env"
run "$B" report.sh
check "STANDBY_SET_INCOMPLETE raised" bash -c "echo '$(codes "$B")' | grep -q STANDBY_SET_INCOMPLETE"
run "$B" recv-check.sh >/dev/null
check "recv-check dropped the >36h incomplete standby set" test ! -e "$B/erp-backup-from-alpha/standby/$CUT"
check "receipt went back to the primary" test -f "$A/erp-backup-from-beta/receipts/standby-of-alpha.json"
run "$A" report.sh
check "primary sees its restore as Pass" [ "$(js "$A" 'd["remote_restore_of_my_data"]["result"]')" = Pass ]
check "primary has no REMOTE_RESTORE alerts" bash -c "! echo '$(codes "$A")' | grep -q REMOTE_RESTORE"

echo "== the restore waits for a push the primary has announced but not finished"
ANNS=$(date -d '+3 days' +%F)_0232
printf '{"schema":"erp-backup-inflight/1","box":"alpha","state":"sending","set":"%s","archive_bytes":1,"standby_set":"%s","standby_bytes":1,"started_at":"%s","updated_at":"%s"}\n' "$ANNS" "$ANNS" "$(date -Is)" "$(date -Is)" > "$B/erp-backup-from-alpha/receipts/inflight-alpha.json"
STANDBY_WAIT_POLL_S=10 run "$B" standby-refresh.sh --now --force --wait-min=1 > /t/announce.log 2>&1 || true
check "waited for the announced set before falling back" bash -c "grep -q 'announced' /t/announce.log && grep -qE 'standby already at|refreshed to|standby stays at|no-new-set:' /t/announce.log"
rm -f "$B/erp-backup-from-alpha/receipts/inflight-alpha.json"

echo "== every way a restore run ends leaves a status line (2026-10-19.4)"
lastline() { tail -n1 "$1/erp-backup/status.log"; }
run "$B" standby-refresh.sh --now --wait-min=0 > /t/r1.log 2>&1 || true
check "nothing new: status line + standby_run outcome" bash -c "lastline() { tail -n1 \"\$1/erp-backup/status.log\"; }; lastline $B | grep -q 'standby no-new-set:' && grep -q '^outcome=no-new-set' $B/erp-backup/state/standby_run.env"
sleep 61; run "$A" backup.sh >/dev/null; S5=$(st "$A" backup set); PUSH_RETRY_SLEEP=1 run "$A" push.sh receipts >/dev/null
run "$B" standby-refresh.sh --now --wait-min=0 > /t/r2.log 2>&1 || true
check "the peer has a newer backup that has not arrived: waiting-for-peer, naming it" bash -c "grep -q '^outcome=waiting-for-peer' $B/erp-backup/state/standby_run.env && grep -q '$S5' $B/erp-backup/state/standby_run.env"
run "$B" report.sh
check "STANDBY_WAITING_FOR_PEER raised" grep -q STANDBY_WAITING_FOR_PEER "$B/erp-backup/status.json"
PUSH_RETRY_SLEEP=1 run "$A" push.sh >/dev/null
bash -c ". $B/erp-backup/bin/common.sh; state_put standby_run at=\"\$(date -Is -d '-15 min')\" outcome=waiting-for-peer reason=test"
rm -f /t/systemd/erp-standby-now.service; run "$B" tick.sh >/dev/null 2>&1 || true
for _ in $(seq 1 90); do [ "$(st "$B" standby set)" = "$S5" ] && [ "$(st "$B" standby_run outcome)" = restored ] && break; sleep 4; done
check "the 2-minute tick restored the late set by itself (catch-up)" bash -c "[ \"$(st "$B" standby set)\" = '$S5' ] && grep -q '^trigger=catch-up' $B/erp-backup/state/standby_run.env && grep -q 'catch-up restore of $S5' $B/erp-backup/status.log"
run "$B" standby-refresh.sh --now --wait-min=0 > /t/r3.log 2>&1 || true
check "a run with nothing new right after a restore: status line too (no-new-set: the restored set is now the delta basis)" bash -c "tail -n1 $B/erp-backup/status.log | grep -qE 'standby (already-current|no-new-set):'"
echo "STANDBY_TIME=04:30" >> "$B/erp-backup/erp-backup.conf"
ERP_KIT_HOSTNAME=boxb bash "$KIT" secondary --root="$B" --force > /dev/null 2>&1
check "re-install retires the shadowed STANDBY_TIME key" bash -c "grep -q '^# STANDBY_TIME=04:30' $B/erp-backup/erp-backup.conf && ! grep -q '^STANDBY_TIME=' $B/erp-backup/erp-backup.conf"
bash -c ". $B/erp-backup/bin/common.sh; sed -i 's/^every=.*/every=weekly/' $B/erp-backup/state/standby.env"; run "$B" report.sh
check "standby_of_peer.every follows the conf, not the last run" python3 -c "import json; d=json.load(open('$B/erp-backup/status.json')); assert d['standby_of_peer']['every']=='daily' and d['standby_of_peer']['every_at_last_refresh']=='weekly'"
bash -c ". $B/erp-backup/bin/common.sh; state_put archive_test result=OK at=\"\$(date -Is -d '-25 days')\" check=Pass"; run "$B" report.sh
check "ARCHIVE_TEST_DUE_SOON a week before the 30-day limit" grep -q ARCHIVE_TEST_DUE_SOON "$B/erp-backup/status.json"
rm -f "$B/erp-backup/state/archive_test.env"

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

echo "== notifications switched on later still announce what is already wrong"
run "$B" set-conf.sh NOTIFY_URL "" >/dev/null; rm -f "$B/erp-backup/state/notify.env"; : > /t/notify.log
run "$B" set-conf.sh MAX_AGE_HOURS 0 >/dev/null; run "$B" watchdog.sh >/dev/null
check "with NOTIFY_URL unset nothing is remembered as sent" bash -c "[ ! -f $B/erp-backup/state/notify.env ] && [ ! -s /t/notify.log ]"
run "$B" set-conf.sh NOTIFY_URL http://127.0.0.1:18765/ > /t/setnotify.log 2>&1
check "setting NOTIFY_URL sends a test, then the open problems" bash -c "grep -q 'test: erp-backup notifications are on' /t/notify.log && grep -qE '^\\[beta\\] (critical|warning) - ' /t/notify.log"
run "$B" set-conf.sh MAX_AGE_HOURS 30 >/dev/null; run "$B" recv-check.sh >/dev/null 2>&1 || true

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

check "no script anywhere hit an unexpected error" bash -c "! grep -h 'unexpected error at line' $A/erp-backup/status.log $B/erp-backup/status.log"
echo
echo "RESULT: $PASS passed, ${#FAILS[@]} failed"
for f in "${FAILS[@]}"; do echo "  - $f"; done
[ ${#FAILS[@]} = 0 ]
