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
credentials|credentials.*|.npmrc|.pypirc|.netrc|_netrc|.htpasswd|secrets.yaml|secrets.yml|secrets.json|.dockercfg|application.properties|application-*.properties)
      printf "Refusing to write secret-bearing file '%s'. If this is intentional, edit it yourself or use 'ask' permission." "$base"; return 0 ;;
  esac
  case "$file" in
    */.ssh/*|*/.gnupg/*|*/.aws/credentials|*/.kube/config|*/.docker/config.json|*/.config/gcloud/*|*/.config/gh/hosts.yml)
      printf "Refusing to write to a credential store (%s)." "$file"; return 0 ;;
  esac
  return 0
}

# ── agent self-protection ──────────────────────────────────────────────────────
# The guardrails only bind while they're installed. A Write/Edit (or a shell mutation)
# of the agent's OWN LIVE config can swap the guardrail hooks for an auto-approve stub
# and silently disable everything — a failure we've seen drift onto a real machine. So
# the live install is frozen: repo working copies stay editable (dev rides the human
# merge gate + re-install), only the files under ~/.claude, ~/.codex, ~/.gemini are.
#
# Matching is HOME-anchored on purpose: a repo copy at …/compass/claude/settings.json
# or a project's own ./.claude/settings.json is NOT under $HOME/.claude, so it never
# matches; a bare repo-relative path (no home prefix) never matches either.

# _policy_live_config_rest "<path>" — echo the home-relative form (e.g. ~/.claude/…)
# when <path> is a LIVE agent-config file, else echo nothing. Accepts the path written
# as $HOME/…, ~/…, $HOME/…, ${HOME}/…, or fully resolved.
_policy_live_config_rest() {
  local t="$1" rest=
  t="${t//\"/}"; t="${t//\'/}"   # drop every quote char (mirror _policy_norm_target)
  case "$t" in
    "$HOME"/*)   rest="${t#"$HOME"/}" ;;
    '~'/*)       rest="${t#'~'/}" ;;
    '$HOME'/*)   rest="${t#'$HOME'/}" ;;
    '${HOME}'/*) rest="${t#'${HOME}'/}" ;;
    *) return 0 ;;
  esac
  case "$rest" in
    .claude/settings.json|.claude/settings.local.json|.claude/CLAUDE.md|.claude/hooks/*|\
.codex/AGENTS.md|.codex/config.toml|\
.gemini/GEMINI.md|.gemini/settings.json|.gemini/settings.local.json)
      printf '%s' "$rest" ;;
  esac
}

# agent_config_reason "<path>" — deny reason if a Write/Edit targets live agent config
# (empty = allow). The primary vector: this is how a drifted settings.json got its
# guardrail hooks replaced by an echo stub.
agent_config_reason() {
  local hit; hit="$(_policy_live_config_rest "$1")"
  [ -n "$hit" ] || return 0
  printf "Refusing to modify live agent config '%s' — config changes belong in your compass repo + re-run install; direct live-config edits are how guardrails get silently disabled." "$1"
}

# agent_config_cmd_reason "<normalized cmd>" — deny reason if a shell command MUTATES
# live agent config: redirect onto it, or rm/sed -i/tee/truncate/install/dd/ln/cp/mv
# naming it. Reads (cat/grep/diff/less …) carry no write signal, so they stay allowed.
# Defense-in-depth behind agent_config_reason (the Edit/Write path is the primary gate).
agent_config_cmd_reason() {
  local cmd="$1" mut=0
  # Quote handling, span-aware: a single-token quoted arg ("$HOME/.claude/…") is a real
  # path argument — unwrap it so it matches. A quoted string WITH spaces is data (a commit
  # message, an echo body) — drop the whole span, else prose like
  # `git commit -m "… install … ~/.claude/settings.json …"` false-positives as a mutation.
  cmd="$(printf '%s' "$cmd" \
    | sed -E 's/"([^"[:space:]]*)"/\1/g'"; s/'([^'[:space:]]*)'/\1/g" \
    | sed -E 's/"[^"]*"/ /g'"; s/'[^']*'/ /g")"
  local cfg='(~|\$HOME|\$\{HOME\}|'"$HOME"')/\.(claude/(settings\.json|settings\.local\.json|CLAUDE\.md|hooks(/[^ ;&|]*)?)|codex/(AGENTS\.md|config\.toml)|gemini/(GEMINI\.md|settings\.(local\.)?json))'
  # redirect onto it:  > ~/.claude/settings.json   /   >>$HOME/.gemini/settings.json
  printf '%s' "$cmd" | grep -Eq -- ">>?[[:space:]]*$cfg" && mut=1
  # a destructive/in-place verb naming it (path appears as an argument of the verb)
  printf '%s' "$cmd" | grep -Eq -- "(^|[ ;&|])(rm|sed +-[a-zA-Z.]*i[a-zA-Z.]*|tee|truncate|install|ln)( +[^;&|]*)? +$cfg" && mut=1
  # cp / mv with the live-config path as the final (destination) token
  printf '%s' "$cmd" | grep -Eq -- "(^|[ ;&|])(cp|mv) +[^;&|]* +${cfg}[[:space:]]*([;&|]|\$)" && mut=1
  [ "$mut" = 1 ] || return 0
  printf 'Refusing to mutate live agent config via shell — config changes belong in your compass repo + re-run install; direct live-config edits are how guardrails get silently disabled.'
}

# ── dangerous shell commands ───────────────────────────────────────────────────
# danger_reason "<command>"  -> reason if the command is a footgun (empty = allow).
# Reads optional POLICY_CURRENT_BRANCH for the "force-push the branch I'm on" case.
danger_reason() {
  local cmd="$1" norm tok
  norm="$(printf '%s' "$cmd" | tr -s '[:space:]' ' ')"

  # 0 · Self-protection: block a shell command that mutates the agent's OWN live config
  #     (settings.json / hooks/** / CLAUDE.md, plus the codex/gemini equivalents) — the
  #     shell twin of the Edit/Write gate in agent_config_reason.
  local self; self="$(agent_config_cmd_reason "$norm")"
  [ -n "$self" ] && { printf '%s' "$self"; return 0; }

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
    # Force flags must belong to the push invocation itself — after "push", on the same
    # line, before the next separator (| ; &). Matching a bare -f/--force anywhere in the
    # command false-positives when a CLEAN push merely shares a command with an unrelated
    # token like `[ -f file ]`, `grep -f`, or `tail -f`. (grep is line-oriented.)
    printf '%s' "$norm" | grep -Eq -- 'push[^|;&]* --force(-with-lease)?([^a-z]|$)' && forced=1
    printf '%s' "$norm" | grep -Eq -- 'push[^|;&]* -[a-zA-Z]*f([^a-z]|$)' && forced=1   # -f / -vf etc.
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
POLICY_INJECTION_DETECTORS='instruction-override|(ignore|disregard|forget|override)( +[a-z]+){0,3} +(previous|prior|earlier|above|preceding|all (previous|prior|the)|the (system|above)).{0,20}(instruction|prompt|message|context|rule|direction|system prompt|information|assignments?|tasks?|orders?)|(now new tasks follow|new (tasks?|instructions?) follow|(your|the) new (task|instructions?) (is|are|follow))
persona-jailbreak|(you are now|from now on|act as|pretend (you|to be|that)|roleplay as).{0,50}(developer mode|do anything now|\bdan\b|unrestricted|uncensored|jailbroken|no (restrictions|rules|filter|guardrails|limits))
role-hijack|(you are now (in )?(developer|god|admin|jailbreak|maintenance|root) mode|act as (a |an )?(linux|unix) (terminal|shell|root shell|interpreter|command prompt)|pretend you (are|have) no (rules?|restrictions?|guidelines?|limits?|guardrails?))
disable-safety|(disable|bypass|turn off|ignore|circumvent|switch off|remove).{0,30}(safety|guardrail|content (policy|filter)|moderation|restriction|the sandbox|approval step|permission check|security (check|hook))
permission-escalation|((run|use|using|with|enable|pass|set|invoke|add) .{0,20}--dangerously-skip-permissions|skip( the)? permission (check|prompt)|grant (yourself|me|all|full)|give (yourself|me) (admin|root|full)|add .{0,40}(allow ?list|allowlist))
data-exfiltration|(send|post|upload|exfiltrate|transmit|e-?mail|forward|leak).{0,60}(\.env\b|secret|credential|password|api[ _-]?key|access[ _-]?token|private key|env(ironment)? variable|ssh key|\.aws|conversation history|chat history|system prompt|id_rsa|id_ed25519|authorized_keys|\.pem\b|\.p12\b|\.git-credentials|\.netrc|kubeconfig|/etc/(passwd|shadow))
exfil-channel|(dig|nslookup|host) +[^ ]*\$\(|(curl|wget) .{0,60}(--data(-binary|-raw)?|--upload-file|--form|-d |-T |-F ).{0,25}@?[^ ]*(id_rsa|id_ed25519|\.ssh/|\.env\b|\.aws/|/etc/(passwd|shadow)|\.git-credentials|kubeconfig)
covert-instruction|do not (tell|inform|warn|mention .{0,15}to|reveal .{0,15}to|notify|alert) (the )?(user|human|operator|developer|owner)
fake-role-tag|</?(system|assistant)>|\[/?INST\]|<\|(im_start|im_end|system)\|>|(^|\n)#{2,3} *system *:
markdown-exfil|!\[[^]]*\]\( *https?://[^)]*(\$\{|secret|token|api[_-]?key)
hidden-html-comment|<!--[^>]*(ignore (previous|above|all|the)|you are now|system prompt|assistant *:|do the following|run this|execute the)[^>]*-->
system-prompt-leak|((repeat|reveal|print|show me|disclose|output|dump|leak|give me) .{0,20}your (system |initial )?(prompt|instructions|rules|configuration|directive)|what (is|are) your (system |initial )?(prompt|instructions|rules|directive|configuration))
prompt-leak|(show|print|reveal|repeat)( me)?( all)?( of)? your (system )?(prompt|instructions?|initial message)|output (everything|all of it) above
tool-poisoning|<(important|secret|system|instructions?)>.{0,80}(ignore|do not (tell|mention|reveal|disclose)|read|send|fetch|exfiltrat|before (using|calling))|before (using|calling|invoking|running) (this|the) (tool|function|mcp|command).{0,60}(read|cat|send|fetch|exfiltrat|pass|include|append).{0,40}(~?/|\.ssh|id_rsa|\.env|secret|credential|token|password|api[ _-]?key)
authority-spoof|(the (user|developer|owner|operator|human|admin)|anthropic|your (creator|developer|maker)) (has|have|already) ?(been )?(authoriz|approv|pre-?approv|sanction|permit|allow|consent|clear)[a-z]* (you to|this action|bypass|skip|disabl|full access|admin(istrator)? access|root|the permission|without (asking|confirm))|(i am|this is|acting as) (the|an|your) (admin(istrator)?|developer|creator|owner|system administrator|anthropic (staff|employee)).{0,25}(so |therefore |now )?(you (must|should|can|are|will)|override|disable|bypass|grant|ignore)'

# Lines carrying one of these markers are NOT flagged — so the corpus, this file,
# and docs/17 (which quote the patterns to explain them) don't self-trip a repo scan.
# Neutralisers: our own pragma, the corpus/docs that quote patterns, NEGATED mentions
# ("never exfiltrate", "do not reveal" — an instruction NOT to do it, not an attack), and
# the benign compound "safety-critical". Keeps precision high on security prose.
POLICY_INJECTION_ALLOW='allowlist[ _-]?injection|redteam[ _-]?corpus|injection[ _-]?(example|sample|payload|pattern|test|detector)|POLICY_INJECTION|safety[- ]critical|(never|not|dont|do not|don.t|avoid|without|cannot|can.t|won.t|refuse to|must not|should not) +(exfiltrat|leak|disab|bypass|reveal|print|remov|send|email|forward|grant|comply)'

# normalize_untrusted "<text>"  -> a de-obfuscated rendering for detection: strips
# invisible chars, decodes base64 blobs, and folds leetspeak + homoglyph lookalikes,
# so an encoded/disguised payload is scanned in its readable form too. Best-effort and
# fail-safe (always echoes something; never errors). Output is the cleaned text plus
# any decoded/folded variants appended — it is for MATCHING only, never shown to a user.
normalize_untrusted() {
  local text="$1" out extra tok dec folded
  [ -n "$text" ] || return 0
  # 1 · drop zero-width / bidi control chars so split/hidden words rejoin.
  out="$(printf '%s' "$text" | LC_ALL=C sed 's/'$'\342\200''[\213-\217\252-\256]//g; s/'$'\342\201''[\246-\251]//g; s/'$'\357\273\277''//g' 2>/dev/null)"
  [ -n "$out" ] || out="$text"
  # 1b · Unicode Tags block (U+E0000–E007F) "ASCII smuggling": invisible tag chars map
  # 1:1 onto ASCII. Decode the printable ones back to readable text (recovers the hidden
  # payload for matching) and strip the rest; fall back to stripping when perl is absent.
  if command -v perl >/dev/null 2>&1; then
    out="$(printf '%s' "$out" | perl -CSAD -pe 's/([\x{E0020}-\x{E007E}])/chr(ord($1)-0xE0000)/ge; s/[\x{E0000}-\x{E007F}]//g' 2>/dev/null || printf '%s' "$out")"
  else
    out="$(printf '%s' "$out" | LC_ALL=C sed 's/'$'\363\240''[\200-\201][\200-\277]//g' 2>/dev/null || printf '%s' "$out")"
  fi
  [ -n "$out" ] || out="$text"
  # 2 · decode base64-looking tokens (>=16 chars), append printable plaintext.
  extra=""
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    dec="$(printf '%s' "$tok" | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; } | LC_ALL=C tr -dc '\11\12\15\40-\176' 2>/dev/null)"
    [ ${#dec} -ge 6 ] && extra="$extra
$dec"
  done <<EOF
$(printf '%s' "$out" | grep -oE '[A-Za-z0-9+/]{16,}={0,2}' 2>/dev/null | head -20)
EOF
  # 2b · decode hex (\xHH), percent (%HH) and HTML numeric entities (&#NN; / &#xHH;) so
  # instructions escaped through any of those channels are scanned in readable form too.
  if command -v perl >/dev/null 2>&1; then
    dec="$(printf '%s' "$out" | perl -pe 's/(?:\\x|%)([0-9A-Fa-f]{2})/chr(hex($1))/ge; s/&#(\d{1,7});/chr($1)/ge; s/&#x([0-9A-Fa-f]{1,6});/chr(hex($1))/ge' 2>/dev/null | LC_ALL=C tr -dc '\11\12\15\40-\176' 2>/dev/null)"
    [ ${#dec} -ge 6 ] && [ "$dec" != "$out" ] && extra="$extra
$dec"
  fi
  # 3 · leetspeak fold + homoglyph fold (Cyrillic/Greek lookalikes -> Latin via perl).
  # Two leet variants: `folded` maps '$'->'s' (catches "di$able safety"); `folded2`
  # keeps '$' (so shell "$(" survives for the exfil-channel detector). Emitting both
  # loses nothing and closes the leet/homoglyph evasion of '$('-keyed patterns.
  local folded2=""
  folded="$(printf '%s' "$out" | LC_ALL=C tr '013457@$' 'oieastas' 2>/dev/null)"
  folded2="$(printf '%s' "$out" | LC_ALL=C tr '013457@' 'oieasta' 2>/dev/null)"
  if command -v perl >/dev/null 2>&1; then
    local homoglyph='tr/\x{0430}\x{0435}\x{043e}\x{0440}\x{0441}\x{0445}\x{0443}\x{0456}\x{03bf}\x{03b1}\x{03b5}/aeopcxyioae/'
    folded="$(printf '%s' "$folded" | perl -CSAD -pe "$homoglyph" 2>/dev/null || printf '%s' "$folded")"
    folded2="$(printf '%s' "$folded2" | perl -CSAD -pe "$homoglyph" 2>/dev/null || printf '%s' "$folded2")"
  fi
  printf '%s%s\n%s\n%s' "$out" "$extra" "$folded" "$folded2"
}

# injection_findings "<text>"  -> one "rule: snippet…" line per likely injection
# pattern (empty output = clean). Scans the raw text AND its de-obfuscated rendering
# (so base64/zero-width/homoglyph/leet evasions are caught); drops allowlisted lines.
injection_findings() {
  local text="$1" name re hit scan
  [ -n "$text" ] || return 0

  # Invisible instructions: zero-width (U+200B–200F), bidi overrides (U+202A–202E,
  # U+2066–2069) and a stray BOM (U+FEFF) — matched as raw UTF-8 bytes under C locale.
  local zwpat; zwpat="$(printf '\342\200[\213-\217\252-\256]|\342\201[\246-\251]|\357\273\277')"
  if printf '%s' "$text" | LC_ALL=C grep -Eq "$zwpat" 2>/dev/null; then
    printf 'hidden-unicode: zero-width/bidirectional control character\n'
  fi
  # Unicode Tags block (U+E0000–E007F): the invisible "ASCII smuggling" channel — no
  # legitimate use in agent-facing text, so flag its mere presence (payload is decoded
  # for matching by normalize_untrusted above).
  if printf '%s' "$text" | LC_ALL=C grep -Eq "$(printf '\363\240[\200-\201][\200-\277]')" 2>/dev/null; then
    printf 'ascii-smuggling: invisible Unicode Tags-block characters (U+E0000-E007F)\n'
  fi

  # scan raw + de-obfuscated rendering in one pass (a match in either fires the rule).
  scan="$text
$(normalize_untrusted "$text")"
  printf '%s\n' "$POLICY_INJECTION_DETECTORS" | while IFS='|' read -r name re; do
    [ -n "$name" ] || continue
    hit="$(printf '%s\n' "$scan" \
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
