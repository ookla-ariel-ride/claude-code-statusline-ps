# claude-code-statusline-ps

A single-file PowerShell status line for [Claude Code](https://code.claude.com) on Windows.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE.svg?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Windows](https://img.shields.io/badge/platform-Windows-0078D4.svg?logo=windows&logoColor=white)](#requirements)

![Status line rendered in Windows Terminal with JetBrainsMono Nerd Font](docs/statusline.png)

Left to right: model, context meter, cost, lines changed, rate limits, mode badges, folder, branch.
Each segment starts with a Nerd Font icon, which GitHub cannot show in text, so the rest of this
file names the icons instead.

![Two-line powerline layout](docs/statusline-two-line.png)

The same data in the two-line powerline layout. Both come from one script; a small JSON file
picks the layout and style.

## About

Claude Code can hand its status bar to any command that reads a JSON payload on stdin and prints a
line. The examples in its docs are bash scripts. This one is PowerShell 7. It needs a Nerd Font and
nothing else, and it installs into your user settings with one command. It shows the numbers you
would otherwise have to go looking for: how full the context window is, what the session has cost,
how close you are to a rate limit, and which modes are on.

## Features

- Context meter with a ten-block bar, percent, and used/total tokens. Green, then yellow, then red.
- Rate limits for the 5-hour and 7-day windows, with a countdown to the next 5-hour reset.
- Session cost and lines added or removed.
- Badges for fast mode, extended thinking, effort level, and vim mode. They disappear when nothing is on.
- Folder and git branch, with a home glyph on `main` and a pencil when the tree is dirty. Branch state comes from `git status` in the current directory.
- One line or two, plain separators or powerline blocks, and any segment switched off, all from `statusline.json`.
- Fits the terminal width. Long lines shorten the limits and context segments first, then drop segments from the right, so lines stop wrapping in normal use.
- If a field is missing from the payload, the script drops that segment. If the payload will not parse, it still prints the model glyph.
- Icons come from Unicode code points rather than pasted characters, so the file's own encoding cannot corrupt them.
- No modules to install. PowerShell 7 and a Nerd Font are the whole dependency list.

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
- Copies `statusline.json` to `~/.claude/statusline.json` unless one is already there.
- Adds a `statusLine` entry to your user-level `~/.claude/settings.json`. It keeps every other key and writes a `.bak` copy first.
- With `-InstallFont`, installs JetBrainsMono Nerd Font through winget. Expect one elevation prompt.
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

This removes the `statusLine` entry and deletes `~/.claude/statusline.ps1`. Fonts and `~/.claude/statusline.json` stay.

## Configuration

The script reads `statusline.json` from its own folder, so after installing that is
`~/.claude/statusline.json`. The installed file holds the defaults:

```json
{
  "layout": "one",
  "style": "plain",
  "segments": {
    "model": true,
    "context": true,
    "cost": true,
    "lines": true,
    "limits": true,
    "badges": true,
    "folder": true,
    "branch": true
  }
}
```

| Key | Values | What it does |
|---|---|---|
| `layout` | `one`, `two` | `two` puts model, folder, branch and badges on the first line and context, limits, cost and lines on the second. |
| `style` | `plain`, `powerline` | `plain` is coloured text with a dim chevron between segments. `powerline` is coloured blocks joined by solid arrows. |
| `segments.<name>` | `true`, `false` | `false` hides that segment. |

Anything missing or invalid falls back to its default without a message, so a typo cannot blank
the status line. Delete the file to get the defaults back. `docs/statusline-two-line.json` is the
config behind the second screenshot.

Claude Code tells the script the terminal width. When a line is too long the script first drops
the token counts from the context segment and the countdown and 7-day figure from the limits
segment, then removes whole segments from the right: lines, badges, cost, limits, folder, branch,
context. The model segment always stays.

## What each segment shows

| Segment | Icon | Data | Rendering |
|---|---|---|---|
| model | <img src="docs/icons/robot.svg" height="18" alt="robot"> `nf-md-robot` | `model.display_name` | Bold cyan |
| context | <img src="docs/icons/memory.svg" height="18" alt="memory"> `nf-md-memory` | `context_window.*` | Percent, ten-block bar, used/total tokens. Green below 60%, yellow below 85%, red above |
| cost | <img src="docs/icons/cash.svg" height="18" alt="cash"> `nf-md-cash` | `cost.total_cost_usd` | Dimmed, two decimals |
| lines | <img src="docs/icons/code.svg" height="18" alt="code"> `nf-fa-code` | `cost.total_lines_added`, `total_lines_removed` | `+N` green, `−N` red. Hidden when both are zero |
| limits | <img src="docs/icons/tachometer.svg" height="18" alt="tachometer"> `nf-fa-tachometer` | `rate_limits.five_hour`, `seven_day` | `5h 24% (1h12m) 7d 41%`. Coloured by the worse of the two using the context thresholds. The countdown is omitted once the reset time has passed |
| badges | <img src="docs/icons/bolt.svg" height="18" alt="bolt"> fast, <img src="docs/icons/brain.svg" height="18" alt="brain"> thinking, <img src="docs/icons/speedometer.svg" height="18" alt="speedometer"> effort, <img src="docs/icons/vim.svg" height="18" alt="vim"> vim | `fast_mode`, `thinking.enabled`, `effort.level`, `vim.mode` | Dimmed glyphs. Effort is hidden at `high`. The whole segment is hidden when nothing is on |
| folder | <img src="docs/icons/folder-open.svg" height="18" alt="folder"> `nf-fa-folder_open` | `workspace.current_dir` | Blue, leaf directory name |
| branch | <img src="docs/icons/home.svg" height="18" alt="home"> on `main`/`master`, <img src="docs/icons/branch.svg" height="18" alt="branch"> elsewhere, <img src="docs/icons/pencil.svg" height="18" alt="pencil"> when dirty | `git.branch`, `git.status`, else `git status` in `workspace.current_dir` | Magenta when clean. Yellow with the pencil when the tree has uncommitted or untracked changes. Shows `detached` on a detached HEAD |
| separator | <img src="docs/icons/chevron.svg" height="18" alt="chevron"> in `plain`, <img src="docs/icons/arrow.svg" height="18" alt="arrow"> in `powerline` | none | Dim chevron between segments, or a solid arrow coloured to blend the neighbouring blocks |

A dim <img src="docs/icons/chevron.svg" height="14" alt="chevron"> separates the segments in plain
style; powerline style joins the coloured blocks with a solid
<img src="docs/icons/arrow.svg" height="14" alt="arrow">. The icon images are SVG outlines
extracted from JetBrainsMono Nerd Font by `docs/render-icons.ps1`, because
GitHub cannot render the font itself. Icon names are from the
[Nerd Font cheat sheet](https://www.nerdfonts.com/cheat-sheet). Field names follow the
[Claude Code status line reference](https://code.claude.com/docs/en/statusline).

## Test without Claude Code

`test.ps1` checks the script's helper functions, then renders every payload in `samples/` against
each layout and style at several terminal widths, then runs the branch segment against temporary
git repositories:

```powershell
.\test.ps1                                # full run, about half a minute
.\test.ps1 -Columns 80                    # one width instead of 120, 60, 20 and unset
.\test.ps1 -Config .\statusline.json      # one config instead of the four combinations
.\test.ps1 -Raw                           # show ANSI escapes as <ESC>
```

It exits non-zero if a render is empty, prints more lines than the layout allows, or is wider than
the terminal. Each render takes about 250 ms, nearly all of it `pwsh` start-up, plus a `git status`
call when the payload has no `git` object.

To try a payload of your own:

```powershell
Get-Content my-payload.json -Raw | pwsh -NoProfile -File .\statusline.ps1
Get-Content my-payload.json -Raw | pwsh -NoProfile -File .\statusline.ps1 -Config .\docs\statusline-two-line.json
```

## Customise

The things you are likely to change sit at the top of `statusline.ps1`:

- Each icon is a code point, for example `$iconCtx = G 0xF035B`. The [Nerd Font cheat sheet](https://www.nerdfonts.com/cheat-sheet) lists alternatives.
- `$gitTimeoutMs` is how long the branch segment waits for `git status`.
- `$defaultEffort` is the level at which the effort badge is hidden.
- The 60% and 85% colour cut-offs live in the context and rate-limit blocks.
- `Get-Palette` holds the colours for both styles.

Segments appear in the order of the `$segmentNames` list. Use `statusline.json` to hide one; edit the list to reorder.

## Troubleshooting

Icons show as boxes or question marks: the terminal font is not a Nerd Font. Set it to
`JetBrainsMono NF` or any other Nerd Font.

The status line is blank: run `.\test.ps1` to confirm the script works, then check that `pwsh` is on
your `PATH` and that the `command` path in `settings.json` exists.

No branch segment: the script runs `git status` in the session's working directory. Check that
`git` is on your `PATH` and that the directory is inside a repository. If `git status` takes longer
than 1.5 seconds the segment is skipped for that refresh.

The line still wraps: the script measures width with a small approximation. Wide glyphs or emoji
in a folder or branch name can be counted short on some terminals. At very narrow widths the model
segment prints even when it does not fit.

Colours look wrong: the script assumes a dark terminal theme.

## Contributing

Issues and pull requests are welcome. Before opening a PR:

```powershell
.\test.ps1
Install-Module PSScriptAnalyzer -Scope CurrentUser
Get-ChildItem *.ps1 | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings .\PSScriptAnalyzerSettings.psd1 }
```

The analyzer settings exclude the Write-Host rule, which a status line cannot avoid, and the
positional-parameters rule, because the script and its tests call their own small helpers
positionally. If you add a segment, add a sample payload to `samples/` so `test.ps1` exercises it,
and regenerate the screenshot at the top of this file with `pwsh docs/render-screenshot.ps1` and
`pwsh docs/render-screenshot.ps1 -Config docs/statusline-two-line.json -Out docs/statusline-two-line.png`.

Commits are scanned for secrets with [gitleaks](https://github.com/gitleaks/gitleaks), both in CI
and through a pre-commit hook. To enable the hook in your clone:

```powershell
winget install Gitleaks.Gitleaks
git config core.hooksPath .githooks
```

## Roadmap

- [x] Query git directly for branch and dirty state
- [x] Optional two-line layout
- [ ] Light-theme palette
- [ ] Prompt-cache and pull-request segments

## License

MIT. See [`LICENSE`](LICENSE).
