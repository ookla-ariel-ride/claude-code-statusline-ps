# Taskbar progress

Windows Terminal draws a progress bar on the window's taskbar button when a program writes the OSC 9;4
escape sequence. With `"taskbar": true` the status line writes the context percentage there on every
refresh, so how full the window is stays readable with Claude Code minimised — green below the `alarm`
level, red at or above it.

It is off by default because Claude Code writes the same sequence itself. There is one bar per window,
so with both writers on they overwrite each other: Claude Code fills it while a turn runs, the status
line puts the context percentage back on its next refresh, and Claude Code's clear at the end of a turn
wipes the context bar until the refresh after that. Pick one. To pick this one, in `settings.json`:

```json
{
  "terminalProgressBarEnabled": false,
  "statusLine": {
    "type": "command",
    "command": "pwsh -NoProfile -NoLogo -NonInteractive -File \"C:/Users/<you>/.claude/statusline.ps1\"",
    "padding": 0,
    "hideVimModeIndicator": true,
    "refreshInterval": 10
  }
}
```

and `"taskbar": true` in `statusline.json`. `.\install.ps1 -RefreshInterval 10` writes the
`statusLine` entry above; `terminalProgressBarEnabled` is Claude Code's own key and the installer does
not touch it. The refresh interval — seconds — is what keeps the bar current while the session sits
idle; without it the bar only moves when something else redraws the line. Anyone who prefers Claude
Code's turn-progress bar leaves `taskbar` at `false` and changes nothing.

A bar the status line has drawn stays on the taskbar until something draws over it — that is how the
sequence works, and it is why a render with no percentage to show writes a clear rather than nothing.
And for the same reason, turning the key back off does not put the taskbar back: the last bar drawn is
still there. Closing the window clears it, and so does one line in the same terminal:

```powershell
Write-Host "`e]9;4;0;0`a" -NoNewline
```

Turn it on in your own `~/.claude/statusline.json` rather than in a project's
`.claude/statusline.json`. The taskbar belongs to the window, not to the repository, so a project
deciding what your taskbar does is a stranger arrangement than a project pinning its own layout. There
is a concrete difference too. When Claude Code hands the script something that is not JSON, the payload
names no project directory, so the project file is not read on that render — a rule older than this key
that every project-only value has always been subject to. Enabled only in a project file, that render
writes no clear and the last bar drawn stays lit until the next payload that parses, which is the next
event or the next `refreshInterval` tick. It lasts longer than that only if every payload after it also
fails to parse, and by then the line itself has been reduced to the model glyph and the word `claude`,
which is the visible half of the same fault. Enabled in the user file, that render clears the bar like
any other, because the user file is read whatever the payload turns out to be.

A terminal that does not know OSC 9;4 — Windows Terminal is the one that does; most others ignore it —
shows nothing at all rather than stray characters, because an unknown OSC string is swallowed up to its
terminator. The sequence is never counted as visible width, so the line is fitted and clipped exactly
as it is with the key off.
