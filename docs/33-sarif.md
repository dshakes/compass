# SARIF output

`compass scan --config --sarif` and `compass audit-plugin --sarif DIR` emit
[SARIF 2.1.0](https://json.schemastore.org/sarif-2.1.0.json) on stdout, so findings can flow into
GitHub code scanning (or any SARIF viewer) instead of living only in terminal text.

- One `run`, `tool.driver` = `compass` (version from the plugin manifest).
- `rules[]` is the distinct finding classes (`mcp-unpinned`, `hook-remote-exec`, ...).
- Severity maps HIGH -> `error`, MED -> `warning`, LOW/INFO -> `note`.
- `locations[]` carries the file URI (and `startLine` where the scanner knows it).
- Baseline-accepted `audit-plugin` findings are omitted. Exit codes are unchanged: the SARIF is
  the report, the exit code is still the gate.
- Secret values are never emitted, only the key name (same as `--json`).

```yaml
- run: compass audit-plugin --sarif plugins/core > compass.sarif || true  # exit code gates elsewhere
- uses: github/codeql-action/upload-sarif@6f2ac81f5cd81fe351a197ba0b00d91d03cd2aee # v4.39.0
  with:
    sarif_file: compass.sarif
    category: compass-audit-plugin
```

Needs `security-events: write` on the job. Compose, don't compete: Claude Code's native security
review covers the code you wrote; compass's scanners cover the harness around it (settings, hooks,
MCP servers, third-party plugins), and both land in the same code-scanning tab.
