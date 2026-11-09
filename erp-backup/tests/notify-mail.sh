#!/bin/bash
# NOTIFY_URL=mailto: (kit 2026-11-08.1) and NOTIFY_IGNORE, without ERPNext. Run inside the harness image:
#
#   docker run --rm -v "$PWD/..":/kit:ro erp-backup-harness:test bash /kit/tests/notify-mail.sh
#
# A local SMTP sink stands in for the provider. The sink speaks plain SMTP, so a curl wrapper drops --ssl-reqd
# (and records every argument curl was given, to prove the password is never on a command line).
set -euo pipefail
KIT=/kit/erp-backup-kit.sh
R=/t/root; export ERP_KIT_SYSTEMD_DIR=/t/systemd
rm -rf "$R" /t/systemd /t/mail.log /t/hook.log /t/curl-args.log /t/wrap; mkdir -p "$R" /t/systemd /t/wrap
PASS=0; FAILS=()
ok()    { PASS=$((PASS + 1)); echo "  PASS $*"; }
bad()   { FAILS+=("$*"); echo "  FAIL $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
run()   { PATH="/t/wrap:$PATH" ERP_KIT_HOSTNAME=x bash "$R/erp-backup/bin/$@"; }
mails() { [ -f /t/mail.log ] && wc -l < /t/mail.log || echo 0; }
lastmail() { tail -n1 /t/mail.log | python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
export -f lastmail
nc_check() { ( PATH="/t/wrap:$PATH"; . "$R/erp-backup/bin/common.sh"; notify_check ); }

REAL_CURL=$(command -v curl)
cat > /t/wrap/curl <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> /t/curl-args.log
a=(); for x in "\$@"; do [ "\$x" = --ssl-reqd ] || a+=("\$x"); done
exec "$REAL_CURL" "\${a[@]}"
EOF
chmod +x /t/wrap/curl

python3 /kit/tests/smtp_sink.py 2525 /t/mail.log & SMTP=$!
python3 /kit/tests/notify_sink.py 18765 /t/hook.log & HOOK=$!
trap 'kill $SMTP $HOOK 2>/dev/null || true' EXIT
sleep 1

echo "== install"
ERP_KIT_HOSTNAME=x bash "$KIT" secondary --me=beta --peer=alpha --peer-host=alpha.test --primary-hostname=alpha --root="$R" --no-wait >/dev/null
CONF="$R/erp-backup/erp-backup.conf"
check "new settings appended with their defaults" bash -c "grep -qx 'NOTIFY_SMTP_URL=smtps://smtp.zoho.com:465' $CONF && grep -qx 'NOTIFY_SMTP_PASS=\"\"' $CONF && grep -qx 'NOTIFY_IGNORE=\"\"' $CONF"
# a status file with one standing warning, as both boxes have today
cat > "$R/erp-backup/status.json" <<'J'
{"overall": "warning", "alerts": [{"level": "warning", "code": "LINK_SLOW", "message": "last push ran at 103 KB/s"}]}
J
# report.sh would rebuild status.json from state; keep this fixture instead
printf '#!/bin/bash\nexit 0\n' > "$R/erp-backup/bin/report.sh"

echo "== email: settings first, the address last"
PW='pa$s w`rd;$(id)'
run set-conf.sh NOTIFY_SMTP_URL smtp://127.0.0.1:2525 >/dev/null
run set-conf.sh NOTIFY_SMTP_USER office@example.test >/dev/null
printf '%s\n' "$PW" | run set-conf.sh NOTIFY_SMTP_PASS --prompt > /t/out-pass.log
check "the password is not echoed" bash -c "! grep -qF 'w\`rd' /t/out-pass.log && grep -q 'value not shown' /t/out-pass.log"
check "no test is sent before NOTIFY_URL is a mailto" test "$(mails)" = 0
run set-conf.sh NOTIFY_URL mailto:alerts@example.test > /t/out-url.log
check "setting the address sends a test email" grep -q "Test notification sent" /t/out-url.log
check "then the open warning (two emails)" test "$(mails)" = 2
check "the test went to the address, from the SMTP login" bash -c "head -n1 /t/mail.log | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"rcpt\"]==[\"alerts@example.test\"] and d[\"from\"]==\"office@example.test\"'"
check "it logged in with the password exactly as typed" bash -c "head -n1 /t/mail.log | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"auth\"]==[\"office@example.test\", sys.argv[1]], d[\"auth\"]' '$PW'"
check "subject names the box and says test" bash -c "head -n1 /t/mail.log | grep -q 'Subject: \[erp-backup beta\] test: erp-backup notifications are on'"
check "the second email carries the warning" bash -c "lastmail 'd[\"data\"]' | grep -q 'warning - LINK_SLOW'"
check "the password never reached curl's command line" bash -c "! grep -qF 'w\`rd' /t/curl-args.log"
check "the sourced conf keeps the password literal" bash -c ". $CONF; [ \"\$NOTIFY_SMTP_PASS\" = '$PW' ]"
check "status.sh says email, password set, and does not print it" bash -c "PATH=/t/wrap:\$PATH ERP_KIT_HOSTNAME=x bash $R/erp-backup/bin/status.sh 2>/dev/null | grep -q 'email via smtp://127.0.0.1:2525 as office@example.test, password set' && ! PATH=/t/wrap:\$PATH ERP_KIT_HOSTNAME=x bash $R/erp-backup/bin/status.sh 2>/dev/null | grep -qF 'w\`rd'"

echo "== NOTIFY_IGNORE"
rm -f "$R/erp-backup/state/notify.env"; N=$(mails)
run set-conf.sh NOTIFY_IGNORE LINK_SLOW,LINK_RELAYED >/dev/null
run tick.sh >/dev/null 2>&1 || true
nc_check
check "an ignored warning alone sends nothing" test "$(mails)" = "$N"
cat > "$R/erp-backup/status.json" <<'J'
{"overall": "critical", "alerts": [{"level": "warning", "code": "LINK_SLOW", "message": "slow"}, {"level": "critical", "code": "BACKUP_FAILED", "message": "the 02:30 backup failed"}]}
J
nc_check
check "a failure still goes out" test "$(mails)" = "$((N + 1))"
check "as critical, without the ignored code" bash -c "lastmail 'd[\"data\"]' | grep -q 'critical - BACKUP_FAILED: the 02:30 backup failed' && ! lastmail 'd[\"data\"]' | grep -q LINK_SLOW"
echo '{"overall": "warning", "alerts": [{"level": "warning", "code": "LINK_SLOW", "message": "slow"}]}' > "$R/erp-backup/status.json"
nc_check
check "when only ignored codes remain, it says recovered" bash -c "lastmail 'd[\"data\"]' | grep -q 'recovered: backups ok again (was: BACKUP_FAILED)'"

echo "== refusals"
N=$(mails)
run set-conf.sh NOTIFY_URL mailto:not-an-address > /t/out-bad.log
check "a malformed address sends nothing and warns" bash -c "[ \$(wc -l < /t/mail.log) = $N ] && grep -q 'test email could not be sent' /t/out-bad.log"
run set-conf.sh NOTIFY_URL mailto:alerts@example.test >/dev/null
N=$(mails)
printf '\n' | run set-conf.sh NOTIFY_SMTP_PASS --prompt > /t/out-nopw.log
check "without a password nothing is sent, and it says so" bash -c "[ \$(wc -l < /t/mail.log) = $N ] && grep -q 'test email could not be sent' /t/out-nopw.log"
check "a single quote in a hidden value is refused" bash -c "printf \"a'b\\n\" | PATH=/t/wrap:\$PATH ERP_KIT_HOSTNAME=x bash $R/erp-backup/bin/set-conf.sh NOTIFY_SMTP_PASS --prompt >/dev/null 2>&1; [ \$? -ne 0 ]"

echo "== a webhook NOTIFY_URL still posts as before"
run set-conf.sh NOTIFY_URL http://127.0.0.1:18765/ > /t/out-hook.log
check "webhook test posted" grep -q 'test: erp-backup notifications are on for beta' /t/hook.log

echo "== upgrade over this conf keeps every value"
ERP_KIT_HOSTNAME=x bash "$KIT" secondary --root="$R" --no-wait > /t/out-up.log
check "no NOTIFY setting appended twice" bash -c "[ \$(grep -c '^NOTIFY_SMTP_URL=' $CONF) = 1 ] && [ \$(grep -c '^NOTIFY_IGNORE=' $CONF) = 1 ] && grep -qx 'NOTIFY_IGNORE=LINK_SLOW,LINK_RELAYED' $CONF"

echo
echo "notify-mail: $PASS passed, ${#FAILS[@]} failed"
[ ${#FAILS[@]} -eq 0 ] || { printf '  - %s\n' "${FAILS[@]}"; exit 1; }
