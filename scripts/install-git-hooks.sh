#!/usr/bin/env bash
# Install the pre-push secret scan for this repo (all worktrees share it).
# Safe to re-run. Refuses to overwrite a different pre-push hook.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
hooks="$(git config core.hooksPath || true)"
if [ -n "$hooks" ]; then
  case "$hooks" in /*) ;; *) hooks="$root/$hooks" ;; esac
else
  hooks="$(cd "$root" && cd "$(git rev-parse --git-common-dir)" && pwd)/hooks"
fi
mkdir -p "$hooks"
hook="$hooks/pre-push"
marker="# secret-scan pre-push hook"

if [ -e "$hook" ] && ! grep -q "$marker" "$hook"; then
  echo "install-git-hooks: $hook already exists and is not ours — add this line to it instead:" >&2
  echo '  "$(git rev-parse --show-toplevel)/scripts/secret-scan-pre-push.sh" "$@" || exit 1' >&2
  exit 1
fi

cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
# secret-scan pre-push hook — installed by scripts/install-git-hooks.sh
s="$(git rev-parse --show-toplevel)/scripts/secret-scan-pre-push.sh"
if [ ! -x "$s" ]; then
  echo "secret-scan: WARNING — $s is not in this checkout (older branch?); push NOT scanned" >&2
  exit 0
fi
exec "$s" "$@"
HOOK
chmod +x "$hook"
echo "install-git-hooks: pre-push secret scan installed at $hook"
command -v gitleaks >/dev/null 2>&1 || echo "install-git-hooks: now run: brew install gitleaks"
