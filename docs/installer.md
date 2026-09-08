# The installer

`install.ps1` copies the scripts into `~/.claude`, writes the settings entries, and can set up the font
and the palette. This page is the full account of what each switch writes and what `-Uninstall` keeps;
the [README](../README.md#installation) has the short version.

## What each switch writes

- Copies `statusline.ps1` to `~/.claude/statusline.ps1`.
- Copies `statusline.json` to `~/.claude/statusline.json` unless one is already there. If the repo copy is missing it warns and carries on. The script has the same defaults built in.
- Adds a `statusLine` entry to your user-level `~/.claude/settings.json`. It keeps every other key and keeps a copy of the previous version first, at a project-owned backup name rather than the generic `settings.json.bak` (see [Uninstall](#uninstall)).
- Sets `hideVimModeIndicator` inside that entry. The badges segment already shows the vim mode, so Claude Code's own indicator would be the same word twice on one bar.
- With `-RefreshInterval <seconds>`, sets `refreshInterval` inside that entry so Claude Code re-renders the line on a timer as well as on events. Without the switch the key is not written. A value below 1 is refused and nothing is written.
- With `-Subagents`, also copies `subagent-statusline.ps1` to `~/.claude/` and adds a `subagentStatusLine` entry. See [Subagent status line](agent-panel.md).
- With `-Style plain|powerline|ascii` or `-Palette dark|light`, writes that key into `~/.claude/statusline.json`, keeping every other key, and carries the same value into the `subagentStatusLine` command. Leave them out and both come from the file as it already stands.
- With `-InstallFont`, installs JetBrainsMono Nerd Font through winget. Expect one elevation prompt.
- With `-ConfigureWindowsTerminal`, sets Windows Terminal's default font to `JetBrainsMono NF` and keeps a copy of its settings first, the same project-owned backup treatment as `settings.json` gets.
- With `-DetectTheme`, reads Windows Terminal's default colour scheme and writes `"palette": "dark"` or `"palette": "light"` into `~/.claude/statusline.json`, keeping every other key. It prints the scheme it found, that scheme's background and the palette it chose. When it cannot tell — no Windows Terminal, no default profile, a scheme it has no background for, or a profile set to follow the OS light/dark theme — **it writes nothing and says why**, because the palette already defaults to `dark` and a wrong guess of `light` would leave the line unreadable. `-Palette` outranks it, and it still prints what it found. Without any of the three, `statusline.json` is not touched. See [Light palette](styles-and-palettes.md#light-palette).

The settings entry it writes after `.\install.ps1 -RefreshInterval 10`:

```json
"statusLine": {
  "type": "command",
  "command": "pwsh -NoProfile -NoLogo -NonInteractive -File \"C:/Users/<you>/.claude/statusline.ps1\"",
  "padding": 0,
  "hideVimModeIndicator": true,
  "refreshInterval": 10
}
```

The path uses forward slashes on purpose. Claude Code may run the command through Git Bash, which
strips backslashes. It is double-quoted for the same kind of reason: a profile with a space in it,
such as `C:/Users/Jane Doe`, would otherwise end the `-File` argument at the space. See
[Subagent status line](agent-panel.md) for the one case the quoting cannot cover.

`refreshInterval` is what keeps a clock, or a taskbar bar driven by the context percentage, moving
between events. Nothing that is drawn on the line itself needs it, so the installer only writes it when
asked; the one feature that does want it is [Taskbar progress](taskbar.md). A reinstall without
the switch writes an entry without the key. Pass the switch again to keep it.

`-SettingsPath <file>` changes only which settings file is edited. The `statusline.ps1` and
`statusline.json` copies, and the delete on `-Uninstall`, still use `~/.claude`. It exists for the
test suite, which points it into a temp folder.

## Other terminals

Any Nerd Font works. If you run Claude Code inside VS Code, ConEmu, or another terminal, set that
terminal's font to a Nerd Font yourself and skip `-ConfigureWindowsTerminal`.

## Uninstall

```powershell
.\install.ps1 -Uninstall
```

This removes the whole `statusLine` entry, `hideVimModeIndicator` and `refreshInterval` with it, and
deletes `~/.claude/statusline.ps1`. Fonts and `~/.claude/statusline.json` stay.

It removes `subagentStatusLine` and `~/.claude/subagent-statusline.ps1` too, without needing
`-Subagents` again, but only when they are this project's. The subagent line is opt-in, so those two
names may well be something you set up yourself.

## What counts as ours

The key counts as ours only when the whole `command` is the form the installer writes: `pwsh`, then
only the switches it passes, then `-File`, then one more argument that *is* the path to
`~/.claude/subagent-statusline.ps1`, and after it only the panel's own `-Style` and `-Palette` — each
at most once, in either order, with a value the panel has — and then the end of the command. A command
that merely mentions that path somewhere — as an argument to a wrapper, in a comment, behind a `&` — is
not ours and is kept, because it never runs our script. So is one that runs our script with anything
else attached: `-Style neon`, a second `-Style`, a `-Style` with nothing after it, or any switch this
installer does not write. An entry written before the arguments existed, with nothing after the path,
is still recognised.

The file counts as ours only when the marker line `# claude-code-statusline-ps:subagent-statusline`
appears as a whole line of its own within the first ten lines. The token turning up inside some other
line, in a string literal or in a trailing comment does not count.

`-Subagents` applies the same rule on the way in: it refuses to install over a
`~/.claude/subagent-statusline.ps1` that is not ours, rather than overwriting it. When it does replace
one of ours it keeps the previous version as `~/.claude/.claude-code-statusline-ps.subagent-rollback.ps1`
— a name carrying this project's id, not a `.bak` beside the script, because a `.bak` is a name your
own tooling might already be using and this file is written and deleted without being asked. Even at
that name the marker is checked before it is overwritten or removed, so a file there that is not ours
survives both a reinstall and an uninstall.

## The settings write and its backups

Both entries leave in one write, so the backup below still holds them as they were. Every settings
write runs under an exclusive lock on `settings.json.lock`, goes to a uniquely named file beside the
real one, and is then moved over it.

That backup is not `settings.json.bak` either, for the same reason the subagent rollback copy is not
`subagent-statusline.ps1.bak`: that name is one your own tooling might already be using for the same
file, and every settings write overwrites it without being asked. It is kept instead at
`settings.json.claude-code-statusline-ps-rollback`, and JSON has no comment syntax to carry a marker
line the way a `.ps1` file does, so the marker lives beside it — a small `.sha256` sidecar recording the
hash of the backup this installer last wrote. Before that backup is ever overwritten, the sidecar is
checked against the backup file's actual content; a mismatch or a missing sidecar means the file at that
name is not this installer's, and it is left alone with a warning naming why, rather than replaced. (A
sidecar with no backup beside it is not the same thing: nothing else ever writes that exact name, so a
leftover one — from a backup deleted by hand, say — does not block the next write.) The backup itself is
written to a temporary sibling and hashed before it ever takes the real name, and a write that fails
partway leaves the previous backup exactly as it was rather than a half-replaced one. `-Uninstall`'s own
settings write leaves a backup the same way, and names it in the output alongside the kept
`statusline.json`.

The settings write itself goes ahead either way — losing the ability to roll back is a smaller harm than
overwriting a file that was never this installer's. `-ConfigureWindowsTerminal` backs up Windows
Terminal's `settings.json` the same way, at `settings.json.claude-code-statusline-ps-rollback` beside it,
in place of the old `settings.json.bak-before-nerdfont` — but there the font change itself is refused,
not merely warned about, when that backup cannot be taken: a font with no way back is not something this
installer offers silently.

What that gets you, stated no more strongly than it holds. An interrupted or failed write leaves the
previous settings intact rather than a truncated file. The lock serialises this installer against
anything else that takes the same lock, and does nothing about a writer that does not take it, because
a cooperative lock cannot exclude a process that ignores it. The file is compared with what the
installer read twice — when the lock is taken, and again immediately before the rename — so a change
that lands before that second check is refused. A change that lands in the gap between that check and
the rename, which only a writer ignoring the lock can manage, is replaced; the content it replaced is in
that backup, when there was one to take and the backup name was this installer's to write. Closing that
gap would need a compare-and-swap the filesystem does not offer, or a lock every writer honours.

An installer from before this backup name changed may have left a `settings.json.bak` or a
`settings.json.bak-before-nerdfont` behind. Neither is read, written or deleted by this version — they
are not part of any restore path, only ever a copy for you to look at by hand — so they are simply left
where they are; delete them yourself once you no longer need them.
