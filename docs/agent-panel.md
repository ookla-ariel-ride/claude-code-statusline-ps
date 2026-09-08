# The agent panel

`subagent-statusline.ps1` draws one row per running subagent in the agent panel, in the same style and
palette as the bar. Install it with `.\install.ps1 -Subagents`.

## The contract

```powershell
.\install.ps1 -Subagents
```

Claude Code shows a panel of the subagents a session is running, and `subagentStatusLine` is a second
command that draws the row for each of them. `subagent-statusline.ps1` prints one short line per
subagent in the same visual language as the main bar: the robot glyph, the agent's name, and how full
its context window is.

```
󰚩 Explore  24%  48k
󰚩 general-purpose  91%  182k
```

The contract is not the one the main status line uses. Claude Code runs the command once for the
whole panel, hands it every live row in a single payload, and expects one JSON object per line back,
`{"id": ..., "content": ...}`, keyed by the task id. So the script loops over `tasks` and answers for
each one. A row that cannot be rendered falls back to the glyph alone; a payload that will not parse
prints nothing, because a bare glyph is not JSON and the panel would only log it and drop it.

The identity is the agent's registered name, or its label, description or type when there is no name.
The progress is the context percentage, coloured green, yellow and red on the same 60 and 85 bands the
context segment uses, 70 and 90 on a 1M window, then the token count. A task with no window size shows
its status word instead. When the payload's `columns` value leaves too little room, the name is
clipped with an ellipsis before any figure is dropped, and the glyph is never dropped, so a row never
wraps the panel. A `columns` of exactly `0` is the panel saying it has no room at all, and nothing is
printed for it; a `columns` that is missing or malformed says nothing about the width, so the row
renders in full and the terminal decides.

There is no config file and no git probe: a panel row is not a full-width bar, and a git probe per row
per tick is too much for something that ticks every five seconds.

## Style and palette

The panel has no config file to read — the command runs once per tick for the whole panel, and that
read is exactly what the status line's own config path had to be bounded and made cheap to survive. So
the two settings that decide how a row is *drawn* ride on the command instead, and the installer bakes
in the pair the status line itself will use:

```json
"subagentStatusLine": {
  "type": "command",
  "command": "pwsh -NoProfile -NoLogo -NonInteractive -File \"C:/Users/<you>/.claude/subagent-statusline.ps1\" -Style ascii -Palette light"
}
```

`-Style` takes the same three values as the `style` key and `-Palette` the same two as `palette`.
`ascii` draws the row's glyph and the tail on a clipped name in printable ASCII — `@ Explore  24%  48k`
rather than `󰚩 Explore  24%  48k` — and `light` swaps the colour numbers for the light table's, so a
pale terminal gets a readable panel under its readable bar. `plain` and `powerline` draw the same row:
the panel has no separators between segments, which is the whole of what `powerline` changes on the
main line, and it accepts the value anyway so the installer can pass `style` through unchanged.

Where the pair comes from, highest first: `-Style` and `-Palette` on the installer, then the palette
`-DetectTheme` worked out, then the `style` and `palette` already in `~/.claude/statusline.json`, then
`plain` and `dark`. So editing `statusline.json` and running `.\install.ps1` again is what carries a
change into the panel — any run of it, not only `-Subagents`: the installer refreshes a panel entry it
recognises as its own, and `-Subagents` is only what creates one. It is fixed until then, which is the
shape of the setting rather than a shortcut: a font belongs to the terminal and a background to its
colour scheme, and neither of those changes between sessions.

**Two things in that file the panel does not follow.** The installer reads the literal `style` and
`palette` keys of your own `~/.claude/statusline.json`. A [preset](configuration.md#presets) stands for a style without
naming one, so it does not reach the panel; and a repository's own `.claude/statusline.json`, which the
status line merges over yours per project (see [Configuration](configuration.md)), does not either. Today the first
changes nothing that is drawn, because all three presets name `plain` or `powerline` and the panel
draws those the same. The second cannot be followed at all: one command serves the whole session, so
there is no per-project answer for it to carry. Name `style` and `palette` in your own file if you want
the panel to follow them. The same read also ignores a `statusline.json` over 64 KiB — so does the
status line, so both fall back to the defaults together.

**The command line is the installer's, not a place to configure this.** Change `style` or `palette` in
`statusline.json` and run the installer again. Editing the command by hand has two failure modes the
panel cannot defend against: an argument left half-typed — `-Style` with nothing after it — fails
PowerShell's parameter binding *before* the script runs, so its error goes where the panel expects JSON
and **every row goes blank**, not just the one argument; and an entry edited into a shape the installer
does not recognise is one `-Uninstall` walks past and leaves behind.

A value the panel does not know — from a command line edited by hand — falls back to the default and
the row still renders. There is no `ValidateSet` on those parameters on purpose: a binding failure
would print a PowerShell error where the panel expects JSON, and take every row down with it rather
than the one argument that was mistyped.

The entry the installer writes with no switches, and with `statusline.json` at its shipped values:

```json
"subagentStatusLine": {
  "type": "command",
  "command": "pwsh -NoProfile -NoLogo -NonInteractive -File \"C:/Users/<you>/.claude/subagent-statusline.ps1\" -Style plain -Palette dark"
}
```

Both arguments are always written, defaults included: the command then says what the panel draws
rather than leaving it to whatever the panel's own defaults happen to be in a later version.

`padding` and `hideVimModeIndicator` are left out on purpose: the setting's schema is `type` and
`command` only. The path is double-quoted, and so is the one in the `statusLine` entry, because a
profile such as `C:/Users/Jane Doe` would otherwise end the `-File` argument at the space and the
command would never run. Double quotes are the one form both cmd and Git Bash honour, and every
character Windows forbids in a path is one that could break out of them. A `$` or a backtick is legal
in a Windows path and still expands inside Git Bash's double quotes, so the installer warns about
those two rather than writing a command that quietly does the wrong thing.

## Capturing a payload

`tools/capture-stdin.ps1` is there if you want to see a payload for yourself. Point
`subagentStatusLine` at it instead, run a session with a few subagents, and read the file it appends
to. It prints nothing on stdout, so the panel renders as if the key were not set.

It is bounded in three places, because a capture command left in place ticks every five seconds
forever. Stdin is read to a ceiling rather than to the end, so one enormous payload cannot be pulled
into memory whole. The record is then cut to fit `-MaxBytes` (1 MiB by default) on its own, with
` ...[truncated]` marking where. And the file is rotated over a single `.1` sibling when what is
already there plus this record would go over, so each of the two generations stays at or under the cap
rather than one of them ending up above it. The append runs under a lock on a `.lock` sibling so two
ticks cannot interleave a rotation with an append; a tick that cannot get the lock drops its payload.
If a write fails, the reason goes to stderr and to a `.error` sidecar once, and capture stops until
you delete that sidecar.
