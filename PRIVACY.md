# Privacy policy

compass is local configuration — hooks, agents, commands, skills, and scripts installed on
your machine. **It collects nothing and phones home to nothing.**

## What compass does with your data

- **All processing is local.** The guardrail and red-team hooks scan prompts, tool calls,
  and fetched content **on your machine**, inside the agent process lifecycle. Nothing is
  transmitted to the compass author or any compass service — no compass service exists.
- **No telemetry, no analytics, no crash reporting.** There is no usage tracking of any kind.
- **Local records only.** Blocked/gated actions are appended to
  `${COMPASS_HOME:-~/.compass}/audit.jsonl` and spend metrics to `~/.compass/metrics.tsv` —
  plain local files you own, inspect, and delete at will. Audit entries record redacted
  reasons, never raw secrets or payloads.

## Network access

By default, compass's hooks make **no network calls**. The only egress is what you opt into,
and your data goes only to the party you configured — never to the compass author:

| You enable | Data goes to |
|---|---|
| Claude Code itself | Anthropic (your existing relationship; compass adds nothing) |
| `context7` MCP (optional) | Upstash (library-docs lookups you request) |
| `fetch` MCP (optional) | The URLs you ask the agent to fetch |
| `compass notify` (opt-in) | Your own Slack/Discord/Telegram webhook or local iMessage |
| `compass listen` (opt-in) | Your own Telegram bot (authorized to your chat id only) |
| Managed guardrail backend (opt-in, off by default) | Your own webhook/Bedrock/Azure endpoint |
| The SDLC loop (opt-in, per repo) | GitHub, via your own tokens and workflows |

The full per-endpoint table is maintained in [SECURITY.md](SECURITY.md).

## Your controls

- Every network-touching feature above is **off until you configure it**.
- `make uninstall` reverses everything the install created (symlinks, CLI, PATH line).
- Delete `~/.compass/` to remove all local records.

## Changes & contact

Material changes to this policy land in this file with a CHANGELOG entry. Questions or
concerns: open an issue at <https://github.com/dshakes/compass/issues> or use the private
vulnerability-reporting path in [SECURITY.md](SECURITY.md).
