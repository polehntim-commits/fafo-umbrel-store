# Secret scanning (pre-push)

Every push is checked for secrets **before** it leaves this Mac. Two checks run:

1. **gitleaks**: API keys, tokens, private keys, passwords and similar, using
   gitleaks' built-in rules plus this repo's `.gitleaks.toml` if it has one.
2. **A private deny-list**: literal strings that must never be committed but
   can't be written into a repo without leaking them. Examples: the farm's public
   IPs, family names, account numbers. It lives **outside every repo**, at
   `~/.config/secret-scan/denylist.txt`.

The pre-push hook scans only the commits the push would send. Findings are
printed **redacted**: gitleaks shows `REDACTED`, and the deny-list reports a file,
a line or commit, and an entry *number*, never the value.

## One-time setup (per Mac)

```zsh
brew install gitleaks
mkdir -p ~/.config/secret-scan && touch ~/.config/secret-scan/denylist.txt
chmod 600 ~/.config/secret-scan/denylist.txt
open -e ~/.config/secret-scan/denylist.txt      # one string per line, '#' comments OK
```

Each entry is also checked in its regex-escaped form, so `1.2.3.4` also catches
`1\.2\.3\.4` in a test. What belongs in the deny-list:

- the farm's public IPs and the real tailnet name (`tailXXXXXX`) and node IPs
- family and employee names that must not appear in public code
- bank and card last-4s and account numbers, tax-lot numbers
- the first 8+ characters of any key that has leaked before

## One-time setup (per repo clone)

```zsh
scripts/install-git-hooks.sh      # installs .git/hooks/pre-push (shared by all worktrees)
```

## Using it

```zsh
scripts/secret-scan.sh                    # scan the files on disk now
scripts/secret-scan.sh --range origin/main..HEAD
scripts/secret-scan.sh --history          # every commit on every ref (audits)
```

A blocked push says what was found and where:

1. Remove the value from the commits: `git commit --amend`, or `git rebase -i`
   for older unpushed commits.
2. **If it was ever pushed or published, rotate it.** Deleting it from git does
   not un-leak it.
3. For a genuine false positive, allow-list that exact value in `.gitleaks.toml`
   (`[[rules.allowlists]]`), never a whole folder.

Emergency bypass: `git push --no-verify`. Don't use it for a real finding.

## Rules of thumb

- Test fixtures use **synthetic** data: `example.test` emails, `Pat Example`,
  card `4242`, tax lot `9N 99E 99 9900`, tailnet `umbrel.tail1234.ts.net`,
  `100.64.0.x`, `203.0.113.x`. Never paste a real statement or receipt into a
  fixture, even with names swapped: the dollar figures are the leak.
- No tokens in `ARG`/`ENV` in a Dockerfile. Use BuildKit secrets
  (`--secret id=…`).
- `.dockerignore` patterns match at the context root only. `*.db` misses
  `app/instance/x.db`, so use `**/*.db`.
