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

# ── prompt-injection in untrusted context ──────────────────────────────────────
# Patterns of the LLM-targeting attacks a red team throws at an agent: a poisoned
# CLAUDE.md/AGENTS.md/README the agent auto-loads as "trusted," or content that
# arrives via WebFetch / MCP tools / command output. Format "name|ERE", one per
# line (the FIRST '|' splits name from the ERE — the ERE may itself contain '|',
# exactly like POLICY_SECRET_DETECTORS' (AKIA|ASIA) case).
#
# This is BEST-EFFORT detection for defense-in-depth, NOT a security boundary and
# NOT a replacement for the cardinal rule (now in CLAUDE.md): treat all fetched/
# read content as DATA, never as instructions. Pattern matching catches the known
# shapes; a novel or obfuscated payload can still slip — keep the human in the loop.
POLICY_INJECTION_DETECTORS='instruction-override|(ignore|disregard|forget|override)( +[a-z]+){0,3} +(previous|prior|earlier|above|preceding|all (previous|prior|the)|the (system|above)).{0,20}(instruction|prompt|message|context|rule|direction|system prompt)
persona-jailbreak|(you are now|from now on|act as|pretend (you|to be|that)|roleplay as).{0,50}(developer mode|do anything now|\bdan\b|unrestricted|uncensored|jailbroken|no (restrictions|rules|filter|guardrails|limits))
disable-safety|(disable|bypass|turn off|ignore|circumvent|switch off|remove).{0,30}(safety|guardrail|content (policy|filter)|moderation|restriction|the sandbox|approval step|permission check|security (check|hook))
permission-escalation|((run|use|using|with|enable|pass|set|invoke|add) .{0,20}--dangerously-skip-permissions|skip( the)? permission (check|prompt)|grant (yourself|me|all|full)|give (yourself|me) (admin|root|full)|add .{0,40}(allow ?list|allowlist))
data-exfiltration|(send|post|upload|exfiltrate|transmit|e-?mail|forward|leak).{0,60}(\.env\b|secret|credential|password|api[ _-]?key|access[ _-]?token|private key|env(ironment)? variable|ssh key|\.aws|conversation history|chat history|system prompt)
covert-instruction|do not (tell|inform|warn|mention .{0,15}to|reveal .{0,15}to|notify|alert) (the )?(user|human|operator|developer|owner)
fake-role-tag|</?(system|assistant)>|\[/?INST\]|<\|(im_start|im_end|system)\|>|(^|\n)#{2,3} *system *:
markdown-exfil|!\[[^]]*\]\( *https?://[^)]*(\$\{|secret|token|api[_-]?key)
hidden-html-comment|<!--[^>]*(ignore (previous|above|all|the)|you are now|system prompt|assistant *:|do the following|run this|execute the)[^>]*-->'

# Lines carrying one of these markers are NOT flagged — so the corpus, this file,
# and docs/17 (which quote the patterns to explain them) don't self-trip a repo scan.
POLICY_INJECTION_ALLOW='allowlist[ _-]?injection|redteam[ _-]?corpus|injection[ _-]?(example|sample|payload|pattern|test|detector)|POLICY_INJECTION'

# injection_findings "<text>"  -> one "rule: snippet…" line per likely injection
# pattern (empty output = clean). Scans line-by-line; drops allowlisted lines.
injection_findings() {
  local text="$1" name re hit
  [ -n "$text" ] || return 0

  # Invisible instructions: zero-width (U+200B–200F), bidi overrides (U+202A–202E,
  # U+2066–2069) and a stray BOM (U+FEFF) — matched as raw UTF-8 bytes under C locale.
  local zwpat; zwpat="$(printf '\342\200[\213-\217\252-\256]|\342\201[\246-\251]|\357\273\277')"
  if printf '%s' "$text" | LC_ALL=C grep -Eq "$zwpat" 2>/dev/null; then
    printf 'hidden-unicode: zero-width/bidirectional control character\n'
  fi

  printf '%s\n' "$POLICY_INJECTION_DETECTORS" | while IFS='|' read -r name re; do
    [ -n "$name" ] || continue
    hit="$(printf '%s\n' "$text" \
      | grep -Ei -- "$re" 2>/dev/null \
      | grep -Eiv -- "$POLICY_INJECTION_ALLOW" 2>/dev/null | head -1)"
    [ -n "$hit" ] && printf '%s: %s\n' "$name" "$(printf '%s' "$hit" | sed 's/^[[:space:]]*//' | cut -c1-72)"
  done
}

# ── local config that tries to weaken safety ───────────────────────────────────
# settings_override_reason "<settings-json-or-text>"  -> reason if a PROJECT-level
# config (a cloned repo's .claude/settings.json, or instructions in its CLAUDE.md)
# tries to grant itself a blanket safety exception. Project config may TIGHTEN
# safety freely; this only flags attempts to LOOSEN it — the privilege-escalation
# vector where `git clone X && cd X` silently disarms the guardrails.
settings_override_reason() {
  local t="$1"
  [ -n "$t" ] || return 0
  # collapse whitespace so "defaultMode" : "bypassPermissions" matches regardless of formatting
  local n; n="$(printf '%s' "$t" | tr -s '[:space:]' ' ')"
  case "$n" in
    *dangerouslySkipPermissions*|*--dangerously-skip-permissions*)
      printf 'Project config sets dangerouslySkipPermissions — refusing to disarm the permission prompt.'; return 0 ;;
  esac
  if printf '%s' "$n" | grep -Eq '"defaultMode" *: *"bypassPermissions"'; then
    printf 'Project config sets defaultMode=bypassPermissions — refusing a blanket permission bypass.'; return 0
  fi
  if printf '%s' "$n" | grep -Eq '"(disableAllHooks|disableHooks)" *: *true'; then
    printf 'Project config disables hooks — refusing to turn off the guardrails.'; return 0
  fi
  # blanket allow entries: bare tool (no scope) or a wildcard = "allow everything"
  if printf '%s' "$n" | grep -Eq '"allow" *: *\[[^]]*"(\*|Bash|Bash\(\*\)|Write\(\*\)|Edit\(\*\)|Read\(/\*\*?\))"'; then
    printf 'Project config grants a blanket tool allowlist (e.g. unscoped Bash/Write or "*").'; return 0
  fi
  if printf '%s' "$n" | grep -Eq '"enableAllProjectMcpServers" *: *true'; then
    printf 'Project config auto-trusts all project MCP servers (enableAllProjectMcpServers).'; return 0
  fi
  return 0
}

# ── malware-authoring awareness (dual-use, NOT a censor) ────────────────────────
# malware_intent_findings "<text>"  -> one "rule: snippet" line per high-signal
# malware-authoring pattern. This is an AWARENESS + audit signal, not a hard block:
# compass supports authorized security work (pentest, CTF, defensive research, dual-
# use tooling), so the wired hook WARNS and logs rather than refusing. High precision
# by design — only unambiguous offensive constructs, never generic networking/crypto.
POLICY_MALWARE_DETECTORS='reverse-shell|(/dev/tcp/[0-9]|nc(at)? .{0,30}-e +/?(bin/)?(ba)?sh|socket.{0,40}(connect|dup2).{0,40}(/bin/(ba)?sh|exec)|pty\.spawn\(.{0,10}/bin/(ba)?sh|sh -i .{0,10}>& */dev/tcp)
ransomware|(encrypt|aes[_-]?(256|cbc|gcm)).{0,80}(ransom|bitcoin|btc wallet|\.locked\b|all your files (have been|are) encrypted|pay (the )?(ransom|to decrypt))
credential-stealer|(steal|dump|harvest|exfiltrate|scrape).{0,40}(saved password|browser (password|cookie)|Login Data|cookies\.sqlite|keychain|/etc/shadow|LSASS|mimikatz)
keylogger|(keylog|GetAsyncKeyState|SetWindowsHookEx.{0,20}WH_KEYBOARD|pynput\.keyboard.{0,30}(Listener|on_press)|/dev/input/event.{0,20}(read|capture))
self-propagation|(self[- ]?propagat|spread (itself )?to (other|all|every) (host|machine|device|system)|worm that (spreads|propagates)|infect (other|all|nearby))
crypto-miner|(xmrig|coinhive|cryptonight|stratum\+tcp://|--coin monero --pool)
c2-framework|(command[- ]and[- ]control beacon|c2 (beacon|implant|channel)|cobalt ?strike beacon|meterpreter (reverse|session)|empire (agent|stager))'
malware_intent_findings() {
  local text="$1" name re hit
  [ -n "$text" ] || return 0
  printf '%s\n' "$POLICY_MALWARE_DETECTORS" | while IFS='|' read -r name re; do
    [ -n "$name" ] || continue
    hit="$(printf '%s\n' "$text" \
      | grep -Ei -- "$re" 2>/dev/null \
      | grep -Eiv -- "$POLICY_INJECTION_ALLOW" 2>/dev/null | head -1)"
    [ -n "$hit" ] && printf '%s: %s\n' "$name" "$(printf '%s' "$hit" | sed 's/^[[:space:]]*//' | cut -c1-72)"
  done
}

# ── insecure code patterns (SAST-lite, defense-in-depth) ───────────────────────
# insecure_code_findings "<text>"  -> one "rule: snippet" line per high-signal
# vulnerability an agent might introduce. HIGH PRECISION: only unambiguous insecure
# constructs (shell=True+interpolation, untrusted deserialization, TLS verification
# turned off, weak crypto), never generic networking/crypto. This is a complement to
# the PR-time SDLC security reviewer — a fast, local, offline first line.
POLICY_INSECURE_DETECTORS='shell-injection|(subprocess\.(call|run|Popen)\([^)]*shell *= *True|os\.system\([^)]*[%+]|child_process\.exec\([^)]*[`$]|Runtime\.getRuntime\(\)\.exec\([^)]*\+)
unsafe-deserialization|(pickle\.loads|cPickle\.loads|yaml\.load\(|marshal\.loads|readObject\(|unserialize\()
disabled-tls|(verify *= *False|rejectUnauthorized *: *false|InsecureSkipVerify *: *true|NODE_TLS_REJECT_UNAUTHORIZED.{0,5}= *.{0,2}0|ssl\._create_unverified_context|curl( |[^|]* )-k\b)
weak-crypto|((hashlib\.)?md5\([^)]*pass|sha1\([^)]*pass|createHash\( *.(md5|sha1)|\bDES\b|MD5CryptoServiceProvider|Cipher(Mode)?\.ECB)'
insecure_code_findings() {
  local text="$1" name re hit
  [ -n "$text" ] || return 0
  printf '%s\n' "$POLICY_INSECURE_DETECTORS" | while IFS='|' read -r name re; do
    [ -n "$name" ] || continue
    hit="$(printf '%s\n' "$text" \
      | grep -Ei -- "$re" 2>/dev/null \
      | grep -Eiv -- "$POLICY_INJECTION_ALLOW" 2>/dev/null | head -1)"
    [ -n "$hit" ] && printf '%s: %s\n' "$name" "$(printf '%s' "$hit" | sed 's/^[[:space:]]*//' | cut -c1-72)"
  done
}
