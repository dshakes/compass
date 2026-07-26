# compass demo — render with:  vhs demo/demo.tape   (or: make demo)
# Punchy + colorful + error-free. Short helpers (demo/_demo.sh) keep the screen clean.

Output demo/preview.gif

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

Type "# compass — one config · every agent · every repo"
Enter
Sleep 1400ms

Type "# guardrails: block the catastrophic, allow the rest"
Enter
Sleep 900ms
Type "guard 'rm -rf /'"
Enter
Sleep 1100ms
Type "guard 'rm -rf ./build'"
Enter
Sleep 1800ms

Type "statusline"
Enter
Sleep 2200ms

Type "# raise a PR → it reviews & fixes itself → you merge"
Enter
Sleep 900ms
Type "loop"
Enter
Sleep 3400ms

Type "crew"
Enter
Sleep 2400ms

Type "# install once → make install   (or:  /plugin install compass@compass)"
Enter
Sleep 2800ms
