#!/usr/bin/env python3
"""compass-sarif.py — turn compass scanner --json output (stdin) into SARIF 2.1.0 (stdout).

Accepts {"findings":[{severity,file,rule,detail|evidence,line?,accepted?}]}. Baseline-accepted
findings are dropped. Severity HIGH->error, MED->warning, LOW/INFO->note.
"""

import json
import os
import re
import sys

LEVEL = {"HIGH": "error", "MED": "warning", "LOW": "note", "INFO": "note"}


def version():
    p = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..",
        "plugins",
        "core",
        ".claude-plugin",
        "plugin.json",
    )
    try:
        return json.load(open(p))["version"]
    except Exception:
        return "0.0.0"


def main():
    findings = [
        f for f in json.load(sys.stdin).get("findings", []) if not f.get("accepted")
    ]
    rules, results = {}, []
    for f in findings:
        rule, lvl = f["rule"], LEVEL.get(f["severity"], "note")
        r = rules.setdefault(
            rule,
            {
                "id": rule,
                "shortDescription": {"text": rule},
                "defaultConfiguration": {"level": lvl},
            },
        )
        if lvl == "error":
            r["defaultConfiguration"]["level"] = "error"
        msg = f.get("detail") or f.get("evidence") or rule
        res = {"ruleId": rule, "level": lvl, "message": {"text": msg}}
        uri = re.split(r":mcp:", f.get("file", ""))[0]
        if uri:
            loc = {"artifactLocation": {"uri": uri}}
            if str(f.get("line", "")).isdigit():
                loc["region"] = {"startLine": int(f["line"])}
            res["locations"] = [{"physicalLocation": loc}]
        results.append(res)
    json.dump(
        {
            "version": "2.1.0",
            "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
            "runs": [
                {
                    "tool": {
                        "driver": {
                            "name": "compass",
                            "version": version(),
                            "informationUri": "https://github.com/dshakes/compass",
                            "rules": list(rules.values()),
                        }
                    },
                    "results": results,
                }
            ],
        },
        sys.stdout,
        indent=2,
    )
    print()


main()
