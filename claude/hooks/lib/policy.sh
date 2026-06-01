#!/usr/bin/env bash
# policy.sh — the compass guardrail policy, as readable, testable, sourceable code.
#
# This is the single source of truth for "which actions are footguns." It is pure:
# two functions that take strings and echo a human-readable reason when an action
# should be blocked (empty = allow). No side effects, no exits, no git calls — so
# protect-paths.sh can wire it to the live hook AND scripts/test-protect-paths.sh
# can score it against a labeled corpus (the "eval" that gates the policy in CI).
#
# NOTE: this is BEST-EFFORT footgun-prevention, NOT a security boundary. It catches
# common accidents — split/long flags, quoted homes, plus-refspec force-pushes,
# `curl|sh` variants — not a determined attacker or a cleverly-obfuscated payload.
# Keep least-privilege credentials and review diffs. (See SECURITY.md.)
#
# Design: prefer a token scan + a few anchored regexes over one monster regex —
# it's the difference between "we think this is covered" and a corpus that proves it.
# Bash 3.2 compatible (macOS): no associative arrays, POSIX-ish grep -E.

# Branches we refuse to force-push / hard-reset (exact names; release/* matched as a prefix).
POLICY_PROTECTED_BRANCHES="main master release production prod develop staging"

# System directories whose recursive deletion is almost never intended.
# A *deeper* path (e.g. /usr/local/share/foo) is allowed — only the dir itself or its glob.
POLICY_SYSTEM_DIRS="/usr /etc /var /bin /sbin /lib /lib64 /lib32 /boot /dev /proc /sys /opt /root /home /System /Library"

# Inline-secret detectors: "name|ERE", one per line. HIGH PRECISION by design —
# secret_content_findings() runs on the write hot path (protect-paths blocks a
# Write/Edit that introduces a match), so it only matches structured, unambiguous
# credential formats, never generic high-entropy strings. Broader/entropy scanning
# lives in `compass scan` (off the hot path; can shell out to gitleaks).
POLICY_SECRET_DETECTORS='anthropic-api-key|sk-ant-[A-Za-z0-9_-]{20,}
openai-api-key|sk-(proj-)?[A-Za-z0-9_-]{32,}
aws-access-key-id|(AKIA|ASIA)[0-9A-Z]{16}
aws-secret-access-key|aws_secret_access_key[^A-Za-z0-9]{1,4}[A-Za-z0-9/+]{40}
gcp-api-key|AIza[0-9A-Za-z_-]{35}
github-token|gh[posru]_[A-Za-z0-9]{36,}
github-pat|github_pat_[0-9A-Za-z_]{60,}
gitlab-pat|glpat-[0-9A-Za-z_-]{20,}
slack-token|xox[baprs]-[0-9A-Za-z-]{10,}
stripe-secret-key|[sr]k_live_[0-9A-Za-z]{16,}
npm-token|npm_[0-9A-Za-z]{36}
private-key-block|-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'

# Markers that neutralise a match on the SAME line — placeholders, AWS's documented
# EXAMPLE key, doc fences, and an explicit `allowlist secret` pragma — so READMEs,
# fixtures, and templates don't trip the guardrail.
POLICY_SECRET_ALLOW='allowlist[ _-]?secret|EXAMPLE|example\.com|placeholder|REDACTED|dummy|sample|\bfake|your[_-]|YOUR_|<[A-Za-z0-9_]|xxxxxxxx|\.\.\.'

# ── helpers ──────────────────────────────────────────────────────────────────

# Strip quotes and a trailing slash / glob from a token, so "/usr/", '/usr/*',
# "$HOME"/ and ~ all normalize to a comparable form. Removes ALL quote characters
# (not just balanced surrounding ones) so `"$HOME"/` normalizes too.
_policy_norm_target() {
  local t="$1"
  t="${t//\"/}"; t="${t//\'/}"   # drop every quote char
  t="${t%/}"        # trailing slash:  /usr/  -> /usr
  t="${t%/\*}"      # glob:            /usr/* -> /usr   ;  /*  -> '' (root)
  t="${t%/}"        # bare /  -> ''  (root)  after the glob strip leaves nothing
  printf '%s' "$t"
}

# Scan a normalized command's tokens for the first catastrophic path (root/home/
# system dir). Runs in its own subshell (command substitution) with `set -f` so an
# unquoted glob token like /var/* is NOT pathname-expanded against the real filesystem.
_policy_first_catastrophic_target() {
  set -f
  local tok
  for tok in $1; do
    case "$tok" in -*|find|rm) continue ;; esac
    if _policy_is_catastrophic_target "$tok"; then printf '%s' "$tok"; return 0; fi
  done
}

# Is a (raw) token a catastrophic recursive-delete target? root, home, or a system dir.
_policy_is_catastrophic_target() {
  local n; n="$(_policy_norm_target "$1")"
  case "$n" in
    ''|'~'|'$HOME'|'${HOME}'|'$home'|'~root') return 0 ;;  # '' == root (/ or /*)
  esac
  local d
  for d in $POLICY_SYSTEM_DIRS; do [ "$n" = "$d" ] && return 0; done
  return 1
}

# Does the normalized command contain an rm recursive flag in ANY form?
#   -rf  -fr  -r  -R  --recursive  -f -r  --force --recursive  etc.
_policy_has_recursive_flag() {
  printf '%s' "$1" | grep -Eq -- '(^| )(-[A-Za-z]*[rR][A-Za-z]*|--recursive)( |$)'
}

# Is `branch` protected? (exact match in the set, or a release/* prefix.)
_policy_branch_protected() {
  local b="$1" p
  case "$b" in release/*|releases/*) return 0 ;; esac
  for p in $POLICY_PROTECTED_BRANCHES; do [ "$b" = "$p" ] && return 0; done
  return 1
}

# ── secret-bearing file writes ─────────────────────────────────────────────────
# secret_file_reason "<path>"  -> reason if the path is a secret/credential store.
secret_file_reason() {
  local file="$1" base; base="$(basename "$file")"
  case "$base" in
    .env|.env.*|.envrc|*.pem|*.key|id_rsa|id_dsa|id_ecdsa|id_ed25519|*.p12|*.pfx|*.keystore|*.jks|\
credentials|credentials.*|.npmrc|.pypirc|.netrc|_netrc|.htpasswd|secrets.yaml|secrets.yml|secrets.json|.dockercfg)
      printf "Refusing to write secret-bearing file '%s'. If this is intentional, edit it yourself or use 'ask' permission." "$base"; return 0 ;;
  esac
  case "$file" in
    */.ssh/*|*/.gnupg/*|*/.aws/credentials|*/.kube/config|*/.docker/config.json|*/.config/gcloud/*|*/.config/gh/hosts.yml)
      printf "Refusing to write to a credential store (%s)." "$file"; return 0 ;;
  esac
  return 0
}

# ── dangerous shell commands ───────────────────────────────────────────────────
# danger_reason "<command>"  -> reason if the command is a footgun (empty = allow).
# Reads optional POLICY_CURRENT_BRANCH for the "force-push the branch I'm on" case.
danger_reason() {
  local cmd="$1" norm tok
  norm="$(printf '%s' "$cmd" | tr -s '[:space:]' ' ')"

  # 1 · Recursive delete of root / home / a system dir (any flag ordering or form).
  if printf '%s' "$norm" | grep -Eq -- '(^| )rm( |$)' && _policy_has_recursive_flag "$norm"; then
    local bad; bad="$(_policy_first_catastrophic_target "$norm")"
    if [ -n "$bad" ]; then
      printf 'Blocked recursive delete of root/home/system path (%s). Narrow the target to a subdirectory if intentional.' "$bad"; return 0
    fi
  fi

  # 1b · find <root> … -delete  /  -exec rm — the rm-free recursive delete.
  if printf '%s' "$norm" | grep -Eq -- '(^| )find ' \
     && printf '%s' "$norm" | grep -Eq -- '(-delete( |$)|-exec +rm)'; then
    local bad2; bad2="$(_policy_first_catastrophic_target "$norm")"
    if [ -n "$bad2" ]; then
      printf 'Blocked `find … -delete` rooted at a catastrophic path (%s).' "$bad2"; return 0
    fi
  fi

  # 2 · Fork bomb / raw disk writes / chmod-777 on system paths.
  case "$norm" in
    *':(){'*|*':() {'*) printf 'Blocked what looks like a fork bomb.'; return 0 ;;
  esac
  if printf '%s' "$norm" | grep -Eq -- '(^| )dd .*of=/dev/' \
     || printf '%s' "$norm" | grep -Eiq -- '(^| )mkfs(\.[a-z0-9]+)?( |$)'; then
    printf 'Blocked a raw disk write (dd/mkfs).'; return 0
  fi
  case "$norm" in
    *'> /dev/sd'*|*'>/dev/sd'*|*'> /dev/nvme'*|*'>/dev/nvme'*|*'> /dev/disk'*) printf 'Blocked a write to a raw block device.'; return 0 ;;
  esac
  if printf '%s' "$norm" | grep -Eq -- 'chmod +(-R +)?[0-7]*777[0-7]* +/( |$)' \
     || printf '%s' "$norm" | grep -Eq -- 'chmod +-R +[0-7]*777[0-7]* +(/usr|/etc|/var|/bin|/lib)'; then
    printf 'Blocked chmod 777 on a system path.'; return 0
  fi

  # 3 · Piping the internet straight into a shell — pipe, process-sub, and eval forms.
  if printf '%s' "$norm" | grep -Eiq -- '(curl|wget|fetch)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?[a-z]*sh([[:space:]]|$)' \
     || printf '%s' "$norm" | grep -Eiq -- '\b[a-z]*sh[[:space:]]+(-[a-z]+[[:space:]]+)*<\([[:space:]]*(curl|wget|fetch)' \
     || printf '%s' "$norm" | grep -Eiq -- '\b(eval|sh -c|bash -c|zsh -c)\b[^|]*\$\([[:space:]]*(curl|wget|fetch)'; then
    printf "Blocked 'curl|sh' style remote-execute. Download, read, then run if you trust it."; return 0
  fi

  # 4 · Force-push / plus-refspec push to a protected branch (handles `git -c … push`).
  if printf '%s' "$norm" | grep -Eq -- '(^| )git( |$)' && printf '%s' "$norm" | grep -Eq -- '(^| )push( |$)'; then
    local forced=0
    printf '%s' "$norm" | grep -Eq -- '(--force-with-lease|--force|(^| )-f( |$)| -[a-zA-Z]*f([^a-z]|$))' && forced=1
    printf '%s' "$norm" | grep -Eq -- 'push[^|;&]* \+[A-Za-z0-9_./-]+' && forced=1   # +refspec (force)
    if [ "$forced" = 1 ]; then
      local hit=0
      # the branch we're on, if the caller told us
      if [ -n "${POLICY_CURRENT_BRANCH:-}" ] && _policy_branch_protected "$POLICY_CURRENT_BRANCH"; then hit=1; fi
      # a protected branch named in the command (bare, +prefixed, or as a refspec dst)
      printf '%s' "$norm" | grep -Eq -- '(^| |\+|:)(main|master|production|prod|release|develop|staging)( |$|:)' && hit=1
      printf '%s' "$norm" | grep -Eq -- ':(\+)?(main|master|production|prod|release|develop|staging)( |$)' && hit=1
      if [ "$hit" = 1 ]; then
        printf 'Blocked force-push to a protected branch. Push to a feature branch and open a PR.'; return 0
      fi
    fi
  fi

  # 5 · Hard reset that discards committed work on the protected branch we're on.
  if printf '%s' "$norm" | grep -Eq -- 'git( +-[^ ]+| +-c +[^ ]+)* +reset +(--[a-z]+ +)*--hard'; then
    if [ -n "${POLICY_CURRENT_BRANCH:-}" ] && _policy_branch_protected "$POLICY_CURRENT_BRANCH"; then
      printf "Blocked 'git reset --hard' on protected branch '%s'." "$POLICY_CURRENT_BRANCH"; return 0
    fi
  fi

  return 0
}

# ── inline secret content ──────────────────────────────────────────────────────
# secret_content_findings "<text>"  -> one "rule: redacted…" line per detected
# secret (empty output = clean). Scans the WHOLE blob once per detector (cost is
# O(detectors), not O(lines)), so it stays cheap on the write hot path. A match is
# dropped if its line also carries an allowlist marker, so placeholders and the
# documented AWS EXAMPLE key never trip it. Tokens are redacted to their first 4
# chars — a finding tells you the *kind* of secret, never reprints the secret.
secret_content_findings() {
  local text="$1" name re hit
  [ -n "$text" ] || return 0
  printf '%s\n' "$POLICY_SECRET_DETECTORS" | while IFS='|' read -r name re; do
    [ -n "$name" ] || continue
    # matching lines → drop allowlisted lines → extract the offending token
    hit="$(printf '%s\n' "$text" \
      | grep -E -- "$re" 2>/dev/null \
      | grep -Eiv -- "$POLICY_SECRET_ALLOW" 2>/dev/null \
      | grep -Eo -- "$re" 2>/dev/null | head -1)"
    [ -n "$hit" ] && printf '%s: %s…\n' "$name" "$(printf '%s' "$hit" | cut -c1-4)"
  done
}
