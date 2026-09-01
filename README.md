# claude-code-statusline-ps

A single-file PowerShell status line for [Claude Code](https://code.claude.com) on Windows.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE.svg?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Windows](https://img.shields.io/badge/platform-Windows-0078D4.svg?logo=windows&logoColor=white)](#requirements)

```
󰚩 Fable 5.1  󰍛 32% ███░░░░░░░ 64k/200k  󰅕 $1.07   +156 −23   5h 24% (1h12m) 7d 41%   󰧐   my-project   main
```

## About

Claude Code lets you replace its status bar with any command that reads a JSON payload on stdin and
prints a line. Almost every published status line is a bash script. This one is PowerShell 7, needs
nothing but a Nerd Font, and installs into your user settings with one command. It shows the things
you cannot otherwise see at a glance: how full the context window is, what the session has cost, how
close you are to a rate limit, and which modes are switched on.

## Features

- **Context meter** with a ten-block bar, percent, and used/total tokens. Green, yellow, then red.
- **Rate limits** for the 5-hour and 7-day windows, with a countdown to the next 5-hour reset.
- **Session cost** and **lines added/removed**.
- **Mode badges** for fast mode, extended thinking, effort level, and vim mode. Hidden when nothing is on.
- **Folder and git branch**, with a home glyph on `main` and a pencil when the tree is dirty.
- **Graceful degradation.** Any segment whose data is missing is dropped. Malformed input still prints the model glyph.
- **Encoding-proof glyphs.** Icons come from Unicode code points, not pasted characters, so the file's own encoding can never corrupt them.
- **No dependencies.** PowerShell 7 and a Nerd Font. Nothing to `Install-Module`.

## Requirements

- Windows 10 or 11
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) on your `PATH` as `pwsh`
- Claude Code
- A [Nerd Font](https://www.nerdfonts.com/) in your terminal. The installer can set up JetBrainsMono Nerd Font for you.

## Installation

```powershell
git clone https://github.com/ookla-ariel-ride/claude-code-statusline-ps
cd claude-code-statusline-ps
.\install.ps1 -InstallFont -ConfigureWindowsTerminal
```

Restart Claude Code, or wait for its next status refresh.

### What the installer does

- Copies `statusline.ps1` to `~/.claude/statusline.ps1`.
- Adds a `statusLine` entry to your **user-level** `~/.claude/settings.json`. Every other key is preserved and a `.bak` copy is written first.
- With `-InstallFont`, installs **JetBrainsMono Nerd Font** through winget. Expect one elevation prompt.
- With `-ConfigureWindowsTerminal`, sets Windows Terminal's default font to `JetBrainsMono NF` and backs up its settings.

The settings entry it writes:

```json
"statusLine": {
  "type": "command",
  "command": "pwsh -NoProfile -NoLogo -NonInteractive -File C:/Users/<you>/.claude/statusline.ps1",
  "padding": 0
}
```

The path uses forward slashes on purpose. Claude Code may run the command through Git Bash, which
strips backslashes.

### Other terminals

Any Nerd Font works. If you run Claude Code inside VS Code, ConEmu, or another terminal, set that
terminal's font to a Nerd Font yourself and skip `-ConfigureWindowsTerminal`.

### Uninstall

```powershell
.\install.ps1 -Uninstall
```

Removes the `statusLine` entry and deletes `~/.claude/statusline.ps1`. Fonts are left in place.

## What each segment shows

| Segment | Data | Rendering |
|---|---|---|
| 󰚩 model | `model.display_name` | Bold cyan |
| 󰍛 context | `context_window.*` | Percent, ten-block bar, used/total tokens. Green below 60%, yellow below 85%, red above |
| 󰅕 cost | `cost.total_cost_usd` | Dimmed, two decimals |
|  lines | `cost.total_lines_added`, `total_lines_removed` | `+N` green, `−N` red. Hidden when both are zero |
|  limits | `rate_limits.five_hour`, `seven_day` | `5h 24% (1h12m) 7d 41%`. Coloured by the worse of the two using the context thresholds. Countdown omitted once the reset time has passed |
|  󰧐 󰓅  badges | `fast_mode`, `thinking.enabled`, `effort.level`, `vim.mode` | Dimmed glyphs. Effort is hidden at `high`. The whole segment is hidden when nothing is on |
|  folder | `workspace.current_dir` | Blue, leaf directory name |
|  /  branch | `git.branch`, `git.status` |  on `main`/`master`,  elsewhere. Yellow with a  when the tree has uncommitted changes, magenta when clean |

Segments are separated by a dim powerline divider. Field names follow the
[Claude Code status line reference](https://code.claude.com/docs/en/statusline).

## Test without Claude Code

`test.ps1` feeds every payload in `samples/` to the script and prints the result with timing:

```powershell
.\test.ps1          # render every sample
.\test.ps1 -Raw     # show ANSI escapes as <ESC>
```

It exits non-zero if any sample produces empty output. Each render takes roughly 250 ms, almost all
of it `pwsh` start-up, which is fine for a status line that refreshes on events rather than
continuously.

To try a payload of your own:

```powershell
Get-Content my-payload.json -Raw | pwsh -NoProfile -File .\statusline.ps1
```

## Customise

Everything you are likely to change sits at the top of `statusline.ps1`:

- **Glyphs.** Each icon is a code point, for example `$iconCtx = G 0xF035B`. Look up alternatives on the [Nerd Font cheat sheet](https://www.nerdfonts.com/cheat-sheet).
- **Separator.** `$sep` holds the divider between segments.
- **Effort badge.** `$defaultEffort` is the level at which the effort badge is hidden.
- **Colour thresholds.** The 60% and 85% cut-offs live in the context and rate-limit blocks.

Segment order is the order of `$parts.Add(...)` calls. Remove a block to drop a segment.

## Troubleshooting

**Icons show as boxes or question marks.** The terminal font is not a Nerd Font. Set it to
`JetBrainsMono NF` or any other Nerd Font.

**The status line is blank.** Run `.\test.ps1` to confirm the script works, then check that `pwsh` is on
your `PATH` and that the `command` path in `settings.json` exists.

**No branch segment.** The branch segment reads a `git` object from the payload. The documented
payload does not include one, so this segment renders only when your Claude Code build supplies it.
Having the script query git directly is on the roadmap.

**Colours look wrong.** The script assumes a dark terminal theme.

## Contributing

Issues and pull requests are welcome. Before opening a PR:

```powershell
.\test.ps1
Install-Module PSScriptAnalyzer -Scope CurrentUser
Get-ChildItem *.ps1 | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings .\PSScriptAnalyzerSettings.psd1 }
```

The analyzer settings exclude only the Write-Host rule, which a status line cannot avoid. Add a
sample payload to `samples/` for any new segment so `test.ps1` exercises it.

## Roadmap

- [ ] Query git directly for branch and dirty state
- [ ] Optional two-line layout
- [ ] Light-theme palette
- [ ] Prompt-cache and pull-request segments

## License

MIT. See [`LICENSE`](LICENSE).
