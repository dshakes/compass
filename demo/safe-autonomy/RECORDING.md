# Recording the safe-autonomy GIF

Shot-by-shot checklist for capturing `run.sh` as the flagship demo GIF. Target:
**under 60 seconds**, readable at GitHub's rendered width.

## Terminal setup

| Setting        | Value                                                        |
|----------------|-------------------------------------------------------------|
| Size           | **90×32** columns×rows (the output is ~74 cols wide)         |
| Font           | monospace with box-drawing + `●`/`↳`/`↻` glyphs — e.g. JetBrains Mono, Menlo, Fira Code |
| Font size      | 22–26px so it's legible when scaled down                     |
| Theme          | dark background, high contrast (the script uses red/green/yellow) |
| Prompt         | clear it or use a minimal `$ ` — no long path, no git branch in the prompt |

Run **without** `--mock` so the built-in pauses pace the four beats. Do a dry run
first; total runtime with pauses is ~13s of sleeps plus your read time.

## Recommended: vhs (matches the repo's other demos)

The repo already records demos with [vhs](https://github.com/charmbracelet/vhs)
(`demo/*.tape` → GIF). Save this as `demo/safe-autonomy/safe-autonomy.tape` and run
`vhs demo/safe-autonomy/safe-autonomy.tape`:

```tape
Output demo/safe-autonomy/safe-autonomy.gif
Set FontSize 24
Set Width 1100
Set Height 760
Set Theme "Dracula"
Set Padding 20
Set PlaybackSpeed 1.0
Hide
Type "cd demo/safe-autonomy" Enter
Show
Type "./run.sh" Sleep 500ms Enter
Sleep 16s          # let all four beats play; tune after a first render
```

vhs is deterministic and diff-able — prefer it over a hand-captured screen record.

## Manual fallback

`asciinema rec safe-autonomy.cast` then `agg safe-autonomy.cast safe-autonomy.gif`,
or any screen recorder cropped to the terminal. Record `./run.sh` (full pacing).

## The four beats — what each shot must show

Each beat is a labelled section header on screen. Confirm all four land:

1. **`1 · GOAL-GATED LOOP`** — the task, the stop condition (tests green AND a fresh
   judge), the guards line ($0.40 cap · protected paths · human merge), then
   `↻ loop start (you close the laptop here)` and turns 1–2 running. *This frame
   sets up "you walked away."*
2. **`2 · THE GUARDRAIL HOLDS`** — three red **`● BLOCKED`** lines with their `↳`
   reasons: force-push to `main`, `~/.aws/credentials`, `.env`. *The money shot —
   pause here longest when reading.*
3. **`3 · THE BUDGET GATE CAPS SPEND`** — two green `● running` turns, then the red
   **`● HALTED`** at `$0.41 / $0.40 cap` with its reason.
4. **`4 · CONVERGE → HUMAN MERGE GATE`** — turns go green, `judge ● CLEAN`, then
   **`✓ you merge — nothing auto-merges`** and the closing line
   *"walked away at beat 1. the guards did the sitting-there."*

## After recording

- Trim dead air at the head/tail; keep it under 60s.
- Sanity-check the GIF is legible on a phone (GitHub mobile) — if not, bump font size.
- Optimize: `gifsicle -O3 --colors 128 safe-autonomy.gif -o safe-autonomy.gif`.
- Commit the GIF alongside the tape:
  `git add demo/safe-autonomy/safe-autonomy.gif demo/safe-autonomy/safe-autonomy.tape`.
