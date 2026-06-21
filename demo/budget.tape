# compass budget-ceiling demo — render with:  vhs demo/budget.tape  (or: make demo-budget)
# The governance moment for X/HN: a coding agent that STOPS at your dollar cap.
# Drives the real budget-gate.sh hook (via demo/_demo.sh), so the HALT is honest.

Output assets/budget.gif

Set Shell "zsh"
Set FontSize 24
Set Width 1280
Set Height 720
Set Padding 40
Set Margin 0
Set Theme "Catppuccin Mocha"
Set TypingSpeed 32ms
Set LineHeight 1.45

Hide
Type "source demo/_demo.sh; setopt interactive_comments 2>/dev/null; PROMPT='%F{141}❯%f '; clear"
Enter
Sleep 300ms
Show

Type "# compass — a live budget ceiling: the agent stops at YOUR number"
Enter
Sleep 1500ms

Type "export COMPASS_MAX_USD=5      # this session hard-stops at $5"
Enter
Sleep 1400ms

Type "# the agent works… each action checked against the cap, live"
Enter
Sleep 900ms
Type "budget 180 5"
Enter
Sleep 1100ms
Type "budget 410 5"
Enter
Sleep 1100ms
Type "budget 500 5"
Enter
Sleep 2200ms

Type "# usage trackers REPORT spend. compass ENFORCES it — no $40 surprise."
Enter
Sleep 1600ms

Type "# raise it (export COMPASS_MAX_USD=10) or /clear to continue. you stay in control."
Enter
Sleep 2800ms
