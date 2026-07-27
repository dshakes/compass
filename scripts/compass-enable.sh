#!/usr/bin/env bash
# compass-enable.sh — one command to put a repo (or several) fully on compass.
#
# Composes the existing layers instead of reinventing them:
#   L1  scripts/new-repo.sh          starter CLAUDE.md + AGENTS.md/GEMINI.md symlinks
#   L2  sdlc/setup.sh                labels + sdlc workflows + CODEOWNERS + commit/push
#       + secrets (env-only here — never prompts, never reads credential stores)
#       + a solo-friendly ruleset (required review+qa checks; NO human-approval
#         requirement, so the autonomous fix loop can land green PRs) + auto-merge
#   L3  compass schedule             optional --schedule → pr-shepherd twice daily
#
#   compass enable [flags] <owner/repo | dir> ...
#     --schedule        also schedule pr-shepherd --twice-daily for each repo
#     --coverage N      set repo var SDLC_COVERAGE_MIN=N (opt-in QA coverage gate)
#     --team-protect    use sdlc/setup.sh --protect instead of the solo ruleset
#                       (adds required human approval + code owners — team mode)
#     --clone-root DIR  where owner/repo targets get cloned (default ~/workspace)
#     --dry-run         print the plan per repo, change nothing
#
# Secrets are set ONLY from exported env (ANTHROPIC_API_KEY, OPENAI_API_KEY,
# GEMINI_API_KEY, CLAUDE_CODE_OAUTH_TOKEN); anything absent is listed at the end
# with the exact `gh secret set` command — agent jobs no-op green until then.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_HOME="$(dirname "$HERE")"
C_RST=$'\033[0m'; C_GREEN=$'\033[38;5;42m'; C_AMBER=$'\033[38;5;214m'; C_CYAN=$'\033[38;5;39m'
log()  { printf '\n%s▶ %s%s\n' "$C_CYAN" "$*" "$C_RST"; }
ok()   { printf '  %s✓ %s%s\n' "$C_GREEN" "$*" "$C_RST"; }
warn() { printf '  %s! %s%s\n' "$C_AMBER" "$*" "$C_RST"; }
note() { printf '  %s\n' "$*"; }   # plain detail line — used by the --dry-run plan
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

command -v gh >/dev/null || die "gh CLI required"
command -v git >/dev/null || die "git required"

SCHEDULE=0 COVERAGE="" TEAM_PROTECT=0 DRYRUN=0 CLONE_ROOT="$HOME/workspace"
targets=()
while [ $# -gt 0 ]; do case "$1" in
  --schedule) SCHEDULE=1; shift ;;
  --coverage) COVERAGE="${2:-}"; [ -n "$COVERAGE" ] || die "--coverage needs a number"; shift 2 ;;
  --team-protect) TEAM_PROTECT=1; shift ;;
  --clone-root) CLONE_ROOT="${2:-}"; [ -n "$CLONE_ROOT" ] || die "--clone-root needs a dir"; shift 2 ;;
  --dry-run) DRYRUN=1; shift ;;
  -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) die "unknown flag: $1" ;;
  *) targets+=("$1"); shift ;;
esac; done
[ "${#targets[@]}" -gt 0 ] || die "usage: compass enable [flags] <owner/repo | dir> ..."

# Resolve a target to a local dir (cloning owner/repo if needed). Echoes the dir.
resolve_dir() {
  local t="$1"
  if [ -d "$t" ]; then (cd "$t" && pwd); return 0; fi
  case "$t" in
    */*)
      # Two statements on purpose: bash 3.2 expands a `local` line's args before
      # assigning any of them, so $name in dest would be unbound under set -u.
      local name dest
      name="${t##*/}"; dest="$CLONE_ROOT/$name"
      mkdir -p "$CLONE_ROOT"
      if [ -d "$dest/.git" ]; then printf '%s' "$dest"; return 0; fi
      [ "$DRYRUN" = 1 ] && { printf '%s' "$dest"; return 0; }
      gh repo clone "$t" "$dest" -- --quiet >/dev/null 2>&1 || return 1
      printf '%s' "$dest" ;;
    *) return 1 ;;
  esac
}

# Solo-friendly ruleset: required checks gate merges server-side, but no human-approval
# requirement — the human gate is "you own the merge button", not a forced review click.
apply_solo_ruleset() { # args: <owner/repo>
  local nwo="$1"
  gh api -X POST "repos/$nwo/rulesets" -H "X-GitHub-Api-Version: 2026-03-10" --input - >/dev/null 2>&1 << 'JSON' && return 0
{
  "name": "compass-protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "review" }, { "context": "qa" } ]
    } }
  ]
}
JSON
  return 1
}

missing_secrets=""
enable_one() {
  local target="$1" dir nwo
  dir="$(resolve_dir "$target")" || { warn "cannot resolve $target (not a dir; clone failed?)"; return 1; }
  nwo="$(cd "$dir" 2>/dev/null && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || nwo=""
  log "enable: ${nwo:-$dir}"
  if [ "$DRYRUN" = 1 ]; then
    # A plan that only lists step NAMES tells you nothing about THIS repo. The whole point
    # of --dry-run here is to answer: will it reach the repo, is it already enabled, is it
    # about to clone, and — the failure mode that actually bites — which secrets are
    # missing from my env right now. Secrets are reported by NAME and set/missing only;
    # values are never read, printed, or logged.
    local plan_nwo="" reach="" default_branch="" enabled="" s n_set=0 n_missing=0
    plan_nwo="$nwo"
    # Not cloned yet → resolve the name from the target itself so we can still query it.
    [ -n "$plan_nwo" ] || case "$target" in */*) [ -d "$target" ] || plan_nwo="$target" ;; esac

    if [ -n "$plan_nwo" ]; then
      # Use the REST fields, not GraphQL's defaultBranchRef: on a repo with no commits
      # the latter returns an EMPTY name, which reads as "unreachable" and sends you off
      # checking auth scopes for a repo that is fine and merely empty. Ask for
      # default_branch and size instead, and report empty as its own state — it matters,
      # because committing workflows into a repo with no commits is a different job.
      local meta="" size=""
      if meta="$(gh api "repos/$plan_nwo" --jq '[.default_branch, .size] | @tsv' 2>/dev/null)" && [ -n "$meta" ]; then
        default_branch="${meta%%	*}"; size="${meta##*	}"
        if [ "${size:-0}" -eq 0 ] 2>/dev/null; then
          reach="reachable, but EMPTY (no commits yet; default branch will be ${default_branch:-main})"
          enabled="nothing to update — L2 would make the first commit"
        else
          reach="reachable (default branch: ${default_branch:-?})"
          if gh api "repos/$plan_nwo/contents/.github/workflows/sdlc-review.yml" >/dev/null 2>&1; then
            enabled="already enabled — L2 would update workflows in place"
          else
            enabled="not yet enabled — L2 would commit + push sdlc workflows and labels"
          fi
        fi
      else
        reach="NOT reachable by gh — check the name, or your gh auth scopes"
      fi
      note "repo:     $plan_nwo — $reach"
      [ -n "$enabled" ] && note "state:    $enabled"
    else
      note "repo:     no GitHub remote gh can see for '$target'"
    fi

    if [ -d "$dir/.git" ]; then note "checkout: $dir (exists)"
    else                        note "checkout: $dir (would clone here)"; fi

    # The load-bearing part: which of the five will actually be set.
    for s in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY CLAUDE_CODE_OAUTH_TOKEN SDLC_BOT_TOKEN; do
      if [ -n "${!s:-}" ]; then n_set=$((n_set + 1)); else n_missing=$((n_missing + 1)); fi
    done
    note "secrets:  $n_set of 5 exported and would be set; $n_missing missing"
    for s in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY CLAUDE_CODE_OAUTH_TOKEN SDLC_BOT_TOKEN; do
      if [ -n "${!s:-}" ]; then note "            set      $s"
      else                       note "            MISSING  $s"; fi
    done
    [ "$n_missing" -gt 0 ] && note "          missing ones are skipped silently on a real run — agent jobs no-op green until set"

    note "would do: L1 per-repo config · L2 workflows+labels$([ "$TEAM_PROTECT" = 1 ] && echo ' · branch protection' || echo ' · solo ruleset') · auto-merge$([ -n "$COVERAGE" ] && echo " · coverage≥$COVERAGE")$([ "$SCHEDULE" = 1 ] && echo ' · pr-shepherd twice daily')"
    ok "[dry-run] nothing was changed"
    return 0
  fi
  [ -n "$nwo" ] || { warn "$dir has no GitHub remote gh can see — skipping"; return 1; }

  # L1 — committed per-repo config (idempotent; leaves existing files alone).
  "$HERE/new-repo.sh" "$dir" >/dev/null && ok "L1: CLAUDE.md + AGENTS.md/GEMINI.md"

  # L2 — workflows + labels (+ optional team protection). Secrets: env-only, no prompts.
  ( cd "$dir" && "$REPO_HOME/sdlc/setup.sh" --workflows --commit $([ "$TEAM_PROTECT" = 1 ] && echo --protect) >/dev/null 2>&1 ) \
    && ok "L2: sdlc workflows + labels committed & pushed" \
    || warn "L2: setup.sh reported errors — run it by hand: (cd $dir && $REPO_HOME/sdlc/setup.sh --workflows --commit)"
  local s set_any=0
  for s in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY CLAUDE_CODE_OAUTH_TOKEN SDLC_BOT_TOKEN; do
    if [ -n "${!s:-}" ]; then
      # stdin, never --body: a command-line arg is visible to every process (ps/procfs).
      printf '%s' "${!s}" | gh secret set "$s" --repo "$nwo" >/dev/null 2>&1 && set_any=1
    else
      missing_secrets="${missing_secrets}
  gh secret set $s --repo $nwo"
    fi
  done
  [ "$set_any" = 1 ] && ok "secrets set from env (only the exported ones)"
  if [ "$TEAM_PROTECT" != 1 ]; then
    if apply_solo_ruleset "$nwo"; then ok "solo ruleset: required review+qa, no forced approval"
    else warn "ruleset not applied (may already exist) — check: gh api repos/$nwo/rulesets"; fi
  fi
  gh api -X PATCH "repos/$nwo" -F allow_auto_merge=true >/dev/null 2>&1 && ok "auto-merge available (gh pr merge --auto --squash)"
  [ -n "$COVERAGE" ] && gh variable set SDLC_COVERAGE_MIN --repo "$nwo" --body "$COVERAGE" >/dev/null 2>&1 && ok "coverage gate ≥${COVERAGE}%"

  # L3 — the unattended loop, per repo.
  if [ "$SCHEDULE" = 1 ]; then
    "$HERE/compass-schedule.sh" add pr-shepherd --twice-daily --dir "$dir" \
      && ok "pr-shepherd scheduled twice daily for $dir" \
      || warn "schedule add failed — run: compass schedule add pr-shepherd --twice-daily --dir $dir"
  fi
  return 0
}

okc=0; failc=0
for t in "${targets[@]}"; do
  if enable_one "$t"; then okc=$((okc+1)); else failc=$((failc+1)); fi
done

printf '\n%s%d enabled, %d failed%s\n' "$C_GREEN" "$okc" "$failc" "$C_RST"
if [ -n "$missing_secrets" ]; then
  warn "secrets NOT set (not exported in this shell) — agent jobs no-op green until you run:"
  printf '%s\n' "$missing_secrets"
fi
[ "$failc" -eq 0 ]
