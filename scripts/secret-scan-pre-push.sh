#!/usr/bin/env bash
# Called by the pre-push hook. git passes, on stdin, one line per ref:
#   <local ref> <local sha> <remote ref> <remote sha>
# Scans only the commits this push would send. Blocks the push on a finding,
# or when gitleaks is missing. Emergency bypass: git push --no-verify
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
zero=0000000000000000000000000000000000000000
status=0

while read -r local_ref local_sha remote_ref remote_sha; do
  [ "$local_sha" = "$zero" ] && continue            # deleting a remote branch
  if [ "$remote_sha" = "$zero" ]; then               # new branch: commits no remote has
    range="$local_sha --not --remotes"
  else
    range="$remote_sha..$local_sha"
  fi
  [ -z "$(git rev-list $range 2>/dev/null | head -1)" ] && continue
  echo "secret-scan: checking $(git rev-list $range | wc -l | tr -d ' ') commit(s) for $remote_ref"
  "$here/secret-scan.sh" --range "$range" || status=$?
done

if [ "$status" -ne 0 ]; then
  echo "" >&2
  echo "secret-scan: PUSH BLOCKED (exit $status). Fix the finding above — remove the" >&2
  echo "secret from the commit (amend/rebase), rotate it if it was ever pushed — or," >&2
  echo "for a known false positive, allow-list it in .gitleaks.toml." >&2
  exit 1
fi
