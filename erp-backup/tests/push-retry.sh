#!/bin/bash
# Push retry / failure-reporting test (kit 2026-10-24.1). Needs no ERPNext: it fakes one encrypted set and one
# plaintext standby set, and pushes them through the REAL rrsync jail (fake-ssh.sh). Run in the harness image:
#
#   docker run --rm -v "$PWD/..":/kit:ro erp-backup-harness:test bash /kit/tests/push-retry.sh
set -uo pipefail
KIT=/kit/erp-backup-kit.sh; A=/t/rootA; J=/t/jail; export ERP_KIT_SYSTEMD_DIR=/t/systemd
rm -rf "$A" "$J" /t/systemd /t/home; mkdir -p "$A" "$J" /t/systemd /t/home
PASS=0; FAILS=()
check() { local d="$1"; shift; if "$@"; then PASS=$((PASS + 1)); echo "  PASS $d"; else FAILS+=("$d"); echo "  FAIL $d"; fi; }
st() { sed -n "s/^$1=//p" "$A/erp-backup/state/push.env" 2>/dev/null | tail -n1; }
run() { ERP_KIT_HOSTNAME=boxa bash "$A/erp-backup/bin/$@"; }

ERP_KIT_HOSTNAME=boxa ERP_KIT_UMBREL_HOME=/t/home bash "$KIT" primary --me=alpha --peer=beta --peer-host=boxb.example --root="$A" --container=none >/dev/null 2>&1
mkdir -p "$A/erp-backup/keys"; echo dummy > "$A/erp-backup/keys/send_ed25519"; echo "boxb ssh-ed25519 AAAA" > "$A/erp-backup/keys/known_hosts"
run set-conf.sh SEND_ENABLED 1 >/dev/null; run set-conf.sh STATUS_TO_CONTAINER 0 >/dev/null
run install.sh >/dev/null 2>&1
check "unit timeout for backup+push is 12h" grep -q '^TimeoutStartSec=12h' "$A/erp-backup/systemd/erp-backup.service"
check "unit timeout for on-demand push is 12h" grep -q '^TimeoutStartSec=12h' "$A/erp-backup/systemd/erp-push.service"
check "other units keep 4h" grep -q '^TimeoutStartSec=4h' "$A/erp-backup/systemd/erp-standby.service"

newset() { # newset STAMP : one complete encrypted set + one plaintext standby set
  local d="$A/erp-backup/own/daily/$1" w="$A/erp-backup/work/standby/$1"
  mkdir -p "$d" "$w"; head -c 3000000 /dev/urandom > "$d/x-database.sql.gz.age"; echo r > "$d/RECIPIENT.txt"
  ( cd "$d" && sha256sum -- * > SHA256SUMS )
  find "$A/erp-backup/work/standby" -mindepth 1 -maxdepth 1 -type d ! -name "$1" -exec rm -rf {} +
  head -c 2000000 /dev/urandom > "$w/x-database.sql.gz"; ( cd "$w" && sha256sum -- * > MANIFEST.sha256 )
}
# FLAKY=N: the first N ssh connections fail the way a dropped tailnet path does; then the real jail
cat > /t/flaky-ssh <<'EOF'
#!/bin/bash
n=$(cat /t/flaky.count 2>/dev/null || echo 0); echo $((n + 1)) > /t/flaky.count
if [ "$n" -lt "${FLAKY:-0}" ]; then echo "Timeout, server boxb.example not responding." >&2; exit 255; fi
exec /usr/local/bin/fake-ssh "$@"
EOF
chmod +x /t/flaky-ssh
export FAKE_SSH_MAP="boxb.example=$J" ERP_KIT_TEST_RSH=/t/flaky-ssh PUSH_RETRY_SLEEP=1

echo "== healthy push"
newset 2026-10-24_0232; rm -f /t/flaky.count
FLAKY=0 run push.sh > /t/p1.log 2>&1
check "healthy push OK" [ "$(st result)" = OK ]
check "healthy push: attempts=1 (not the call count)" [ "$(st attempts)" = 1 ]
check "healthy push: retries=0" [ "$(st retries)" = 0 ]
check "healthy push: rsync_calls recorded separately (6)" [ "$(st rsync_calls)" = 6 ]
check "status line says attempts=1 retries=0" bash -c "grep 'OK push 2026-10-24_0232' $A/erp-backup/status.log | grep -q 'attempts=1 retries=0 calls=6'"
check "set complete on the peer" test -f "$J/daily/2026-10-24_0232/SHA256SUMS"

echo "== one dropped connection, then OK"
newset 2026-10-25_0232; rm -f /t/flaky.count
FLAKY=1 run push.sh > /t/p2.log 2>&1
check "push OK after one retry" [ "$(st result)" = OK ]
check "attempts=2 retries=1" bash -c "[ \"$(st attempts)\" = 2 ] && [ \"$(st retries)\" = 1 ]"
check "the failed try's reason is in status.log" bash -c "grep -q 'WARN push 2026-10-25_0232 try 1/3 failed (notice to beta (0/4)): rc=255 ssh failed .* Timeout, server boxb.example not responding' $A/erp-backup/status.log"
check "the reason is in the journal output too" grep -q 'try 1/3 of notice to beta (0/4) failed: rc=255' /t/p2.log
check "first retry waits 60 s at most (here PUSH_RETRY_SLEEP=1)" grep -q 'trying again in 1s' /t/p2.log
check "last_retry_reason kept on the OK record" bash -c "st() { sed -n \"s/^\$1=//p\" $A/erp-backup/state/push.env; }; st last_retry_reason | grep -q 'rc=255'"

echo "== the peer unreachable all night"
newset 2026-10-26_0232; rm -f /t/flaky.count
FLAKY=99 run push.sh > /t/p3.log 2>&1; RC=$?
check "push exits non-zero" [ "$RC" != 0 ]
check "state result=FAIL" [ "$(st result)" = FAIL ]
check "FAIL message carries the reason" bash -c "st() { sed -n \"s/^\$1=//p\" $A/erp-backup/state/push.env; }; st msg | grep -q 'try 3/3: rc=255 ssh failed'"
check "three tries, each logged" [ "$(grep -c 'WARN push 2026-10-26_0232 try [123]/3 failed' "$A/erp-backup/status.log")" = 3 ]
run report.sh >/dev/null 2>&1
check "PUSH_STALE_OR_FAILED raised" python3 -c "import json,sys; d=json.load(open('$A/erp-backup/status.json')); a=[x for x in d['alerts'] if x['code']=='PUSH_STALE_OR_FAILED']; sys.exit(0 if a and a[0]['level']=='critical' and 'rc=255' in a[0]['message'] else 1)"

echo "== push stopped mid-way (systemd timeout / stop)"
rm -f /t/flaky.count
cat > /t/slow-ssh <<'EOF'
#!/bin/bash
sleep 30; exec /usr/local/bin/fake-ssh "$@"
EOF
chmod +x /t/slow-ssh
ERP_KIT_TEST_RSH=/t/slow-ssh run push.sh > /t/p4.log 2>&1 & PID=$!
# systemd stops the whole unit: push.sh and everything it started get SIGTERM
sleep 3; pkill -TERM -f "$A/erp-backup/bin/push.sh"; pkill -TERM -x rsync; pkill -TERM -f /t/slow-ssh; wait "$PID"; RC=$?
check "stopped push exits non-zero" [ "$RC" != 0 ]
check "stopped push is recorded as FAIL" bash -c "st() { sed -n \"s/^\$1=//p\" $A/erp-backup/state/push.env; }; [ \"\$(st result)\" = FAIL ] && st msg | grep -q 'stopped by a signal'"
check "one FAIL line, not two" [ "$(grep -c 'FAIL push push.sh was stopped' "$A/erp-backup/status.log")" = 1 ]

echo "== healthy again"
rm -f /t/flaky.count
FLAKY=0 run push.sh > /t/p5.log 2>&1
check "recovers to OK, attempts=1" bash -c "[ \"$(st result)\" = OK ] && [ \"$(st attempts)\" = 1 ]"
check "no unexpected-exit FAIL anywhere" bash -c "! grep -q 'ended unexpectedly' $A/erp-backup/status.log"

echo "== run-now --push-only, foreground"
newset 2026-10-27_0232; rm -f /t/flaky.count
FLAKY=0 run run-now.sh --push-only > /t/r1.log 2>&1; RC=$?
check "run-now exits 0" [ "$RC" = 0 ]
check "run-now says the push ended OK" grep -q '^== push: OK 2026-10-27_0232' /t/r1.log
check "run-now prints the summary" grep -q '^push   : OK set 2026-10-27_0232' /t/r1.log
check "the push itself logged OK" grep -q 'OK push 2026-10-27_0232' "$A/erp-backup/status.log"

echo "== run-now --push-only, foreground, peer down"
newset 2026-10-28_0232; rm -f /t/flaky.count
FLAKY=99 run run-now.sh --push-only > /t/r2.log 2>&1; RC=$?
check "run-now exits non-zero" [ "$RC" != 0 ]
check "run-now prints FAIL with the reason" grep -qE '^== push: FAIL \(exit 1\) - .*rc=255 ssh failed' /t/r2.log
check "and still prints the summary" grep -q '^push   : FAIL' /t/r2.log

echo "== run-now --push-only --detach"
: > /t/systemd/.calls
run run-now.sh --push-only --detach > /t/r3.log 2>&1; RC=$?
check "detach starts erp-push.service" grep -q 'systemctl start --no-block erp-push.service' /t/systemd/.calls
check "detach says so, and where to watch" bash -c "grep -q 'started in the background (erp-push.service)' /t/r3.log && grep -q 'progress.sh --watch' /t/r3.log"
check "detach is logged" grep -q 'OK run-now push detached to erp-push.service' "$A/erp-backup/status.log"

echo "== the real ssh path (no test stand-in): kits .3-.5 exited here silently, in init_ssh"
newset 2026-10-29_0232
( unset ERP_KIT_TEST_RSH; ERP_KIT_HOSTNAME=boxa bash "$A/erp-backup/bin/push.sh" ) > /t/p6.log 2>&1; RC=$?
check "push.sh gets past ssh setup and tries the peer" grep -q 'try 1/3 of notice to beta (0/4) failed: rc=255' /t/p6.log
check "and ends FAIL with a reason (no such host here)" bash -c "[ $RC != 0 ] && [ \"$(st result)\" = FAIL ] && sed -n 's/^msg=//p' $A/erp-backup/state/push.env | grep -q 'rc=255'"
check "link-test.sh gets past ssh setup too" bash -c "( unset ERP_KIT_TEST_RSH; ERP_KIT_HOSTNAME=boxa bash $A/erp-backup/bin/link-test.sh ) 2>&1 | grep -q 'cannot reach beta\|tailnet path'"
check "init_ssh returns 0 on a real box" bash -c "unset ERP_KIT_TEST_RSH; cd $A/erp-backup/bin && . ./common.sh && init_ssh && [ -n \"\$RSYNC_RSH\" ]"

echo; echo "push-retry: $PASS passed, ${#FAILS[@]} failed"
[ "${#FAILS[@]}" = 0 ] || { printf '  - %s\n' "${FAILS[@]}"; tail -n 30 "$A/erp-backup/status.log"; exit 1; }
