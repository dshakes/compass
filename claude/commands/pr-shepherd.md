---
description: Take every open PR end-to-end — diagnose, fix mechanical failures, stop at the merge gate
argument-hint: "[optional: PR numbers to scope to, or --merge to grant merge authority for this run]"
allowed-tools: Read, Grep, Glob, Bash, Edit, Write, Task
---
Run the **pr-shepherd** skill on the open PRs: $ARGUMENTS

Follow the skill's procedure exactly: enumerate (fail closed on
`isCrossRepository`), diagnose each red check from its log, classify
(real defect / mechanical / environmental), fix mechanical failures on the
PR branch with the gate run locally first, three-strikes cap, and stop at
the merge gate. Merge only if `--merge` was passed or I granted merge
authority earlier in this session; otherwise report ready-to-merge.
