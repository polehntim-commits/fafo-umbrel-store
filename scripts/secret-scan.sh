#!/usr/bin/env bash
# Secret scan — run by the pre-push hook, or by hand.
#
#   scripts/secret-scan.sh                  scan the working tree (files on disk)
#   scripts/secret-scan.sh --range A..B     scan the commits in a git range
#   scripts/secret-scan.sh --history        scan every commit on every ref
#
# Two checks:
#  1. gitleaks — its default secret rules, plus this repo's .gitleaks.toml when
#     there is one (project rules, allow-listed test placeholders). Findings are
#     printed REDACTED.
#  2. A PRIVATE deny-list of literal strings that must never be committed but
#     can't be written into a public repo's config without leaking them (the
#     farm's public IPs, family names, account numbers...). One string per
#     line, '#' comments allowed. It lives OUTSIDE every repo:
#        ${SECRET_SCAN_DENYLIST:-~/.config/secret-scan/denylist.txt}
#     Hits print the file, line/commit and the entry NUMBER — never the value.
#     For --range/--history only lines a commit ADDS are checked.
#
# Exit: 0 clean, 1 findings, 2 gitleaks missing or bad usage.
# See docs/SECRET_SCANNING.md.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
denylist="${SECRET_SCAN_DENYLIST:-$HOME/.config/secret-scan/denylist.txt}"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "secret-scan: gitleaks is not installed — run: brew install gitleaks" >&2
  exit 2
fi

cfg=()
[ -f "$root/.gitleaks.toml" ] && cfg=(--config "$root/.gitleaks.toml")
common=(--redact --verbose --no-banner ${cfg[@]+"${cfg[@]}"})  # bash 3.2-safe empty array

# gitleaks >= 8.19 has `git` / `dir`; older releases only `detect`.
if gitleaks git --help >/dev/null 2>&1; then new=1; else new=0; fi

gitleaks_git() {  # $1 = git log options, e.g. "A..B" or "--all"
  if [ "$new" = 1 ]; then gitleaks git "${common[@]}" --log-opts="$1" "$root"
  else gitleaks detect "${common[@]}" --source "$root" --log-opts="$1"; fi
}

gitleaks_tree() {
  if [ "$new" = 1 ]; then gitleaks dir "${common[@]}" "$root"
  else gitleaks detect "${common[@]}" --source "$root" --no-git; fi
}

# ── private deny-list ────────────────────────────────────────────────
pats=""
if [ -f "$denylist" ]; then
  pats="$(mktemp)"
  trap 'rm -f "$pats"' EXIT
  # "N<TAB>string" per line; each entry is also checked in its regex-escaped
  # form (1.2.3.4 -> 1\.2\.3\.4), which is how IPs and hostnames turn up in tests.
  grep -vE '^[[:space:]]*(#|$)' "$denylist" | awk '{
    n++; printf "%d\t%s\n", n, $0
    e = $0; gsub(/\./, "\\.", e); if (e != $0) printf "%d\t%s\n", n, e
  }' > "$pats" || true
  [ -s "$pats" ] || pats=""
fi

deny_tree() {  # tracked + untracked (not ignored) files on disk
  [ -n "$pats" ] || return 0
  local n hits=0 p
  while IFS=$'\t' read -r n p; do
    while IFS= read -r loc; do
      [ -n "$loc" ] || continue
      echo "deny-list entry #$n found at $loc"; hits=1
    done < <(git -C "$root" grep --untracked -n -I -F -e "$p" -- . 2>/dev/null | cut -d: -f1,2)
  done < "$pats"
  return "$hits"
}

deny_git() {  # $@ = git log revision args; checks ADDED lines only
  [ -n "$pats" ] || return 0
  # shellcheck disable=SC2068
  git -C "$root" log -p --no-color --no-ext-diff --format='@@commit %h' $@ 2>/dev/null |
    awk -v patfile="$pats" '
      BEGIN { FS = "\t"
              while ((getline l < patfile) > 0) { t = index(l, "\t"); n++; num[n] = substr(l, 1, t - 1); pat[n] = substr(l, t + 1) }
              FS = " " }
      /^@@commit / { commit = $2; next }
      /^\+\+\+ /   { file = substr($0, 7); next }
      /^\+/        { line = substr($0, 2)
                     for (i = 1; i <= n; i++) if (index(line, pat[i]))
                       { printf "deny-list entry #%s added in commit %s, file %s\n", num[i], commit, file; hits = 1 } }
      END { exit hits }'
}

status=0
case "${1:-}" in
  --range)
    [ -n "${2:-}" ] || { echo "usage: $0 --range A..B" >&2; exit 2; }
    gitleaks_git "$2" || status=1
    deny_git $2 || status=1 ;;
  --history)
    gitleaks_git "--all" || status=1
    deny_git --all || status=1 ;;
  "")
    gitleaks_tree || status=1
    deny_tree || status=1 ;;
  *)
    echo "usage: $0 [--range A..B | --history]" >&2; exit 2 ;;
esac

if [ -z "$pats" ]; then
  echo "secret-scan: note — no private deny-list at $denylist (see docs/SECRET_SCANNING.md)" >&2
fi
exit "$status"
