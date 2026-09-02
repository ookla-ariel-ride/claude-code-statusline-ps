# claude-code-statusline-ps

A PowerShell status line for [Claude Code](https://code.claude.com) on Windows. One script, one small JSON config, a Nerd Font.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE.svg?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Windows](https://img.shields.io/badge/platform-Windows-0078D4.svg?logo=windows&logoColor=white)](#requirements)

![Status line rendered in Windows Terminal with JetBrainsMono Nerd Font](docs/statusline.png)

Left to right: model, context meter, cost, lines changed, rate limits, mode badges, folder, and the
branch with its change counts. Each segment starts with a Nerd Font icon, which GitHub cannot show
in text, so the rest of this file names the icons instead.

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
- Counts beside the branch name: `↑N` `↓N` commits ahead of or behind the upstream, `+N` staged, `~N` changed, `?N` untracked, and a red triangle with a count when files are in conflict. See [Branch counts](#branch-counts).
- One line or two, plain separators or powerline blocks, and any segment switched off, all from `statusline.json`.
- Fits the terminal width. A line that is too long first loses detail from the limits, context and branch segments, then loses whole segments from the right, so lines stop wrapping in normal use.
- If a field is missing from the payload, the script drops that segment. If the payload will not parse, it still prints the model glyph.
- Icons come from Unicode code points rather than pasted characters, so the file's own encoding cannot corrupt them.
- No modules to install. PowerShell 7 and a Nerd Font are the whole dependency list.

## Requirements

- Windows 10 or 11
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) on your `PATH` as `pwsh`
- Claude Code
- A [Nerd Font](https://www.nerdfonts.com/) in your terminal. The installer can set up JetBrainsMono Nerd Font for you.
- `git` on your `PATH` if you want the branch segment. Without it the segment is skipped and everything else still renders.

## Installation

```powershell
git clone https://github.com/ookla-ariel-ride/claude-code-statusline-ps
cd claude-code-statusline-ps
.\install.ps1 -InstallFont -ConfigureWindowsTerminal
```

Restart Claude Code, or wait for its next status refresh.

### What the installer does

- Copies `statusline.ps1` to `~/.claude/statusline.ps1`.
- Copies `statusline.json` to `~/.claude/statusline.json` unless one is already there. If the repo copy is missing it warns and carries on. The script has the same defaults built in.
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

Claude Code tells the script the terminal width. When a line is too long the script shortens it in
two stages:

1. Detail comes off three segments, in this order: the countdown and 7-day figure from limits, the
   token counts from context, and every count from the branch.
2. Whole segments go, from the right: lines, badges, cost, limits, folder, branch, context.

The model segment always stays.

## What each segment shows

| Segment | Icon | Data | Rendering |
|---|---|---|---|
| model | <img src="docs/icons/robot.svg" height="18" alt="robot"> `nf-md-robot` | `model.display_name`, `context_window.context_window_size`, `exceeds_200k_tokens` | Bold cyan. A dim `1M` follows the name on a 1M window, then a warning triangle once the session has passed 200k tokens |
| context | <img src="docs/icons/memory.svg" height="18" alt="memory"> `nf-md-memory` | `context_window.*` | Percent, ten-block bar, used/total tokens. Green below 60%, yellow below 85%, red above. On a 1M window the cut-offs are 70% and 90%, so red still means about 100k tokens left |
| cost | <img src="docs/icons/cash.svg" height="18" alt="cash"> `nf-md-cash` | `cost.total_cost_usd` | Dimmed, two decimals |
| lines | <img src="docs/icons/code.svg" height="18" alt="code"> `nf-fa-code` | `cost.total_lines_added`, `total_lines_removed` | `+N` green, `−N` red. Hidden when both are zero |
| limits | <img src="docs/icons/tachometer.svg" height="18" alt="tachometer"> `nf-fa-tachometer` | `rate_limits.five_hour`, `seven_day` | `5h 24% (1h12m) 7d 41%`. Coloured by the worse of the two using the context thresholds. The countdown is omitted once the reset time has passed |
| badges | <img src="docs/icons/bolt.svg" height="18" alt="bolt"> fast, <img src="docs/icons/brain.svg" height="18" alt="brain"> thinking, <img src="docs/icons/speedometer.svg" height="18" alt="speedometer"> effort, <img src="docs/icons/vim.svg" height="18" alt="vim"> vim | `fast_mode`, `thinking.enabled`, `effort.level`, `vim.mode` | Dimmed glyphs. Effort is hidden at `high`. The whole segment is hidden when nothing is on |
| folder | <img src="docs/icons/folder-open.svg" height="18" alt="folder"> `nf-fa-folder_open` | `workspace.current_dir` | Blue, leaf directory name |
| branch | <img src="docs/icons/home.svg" height="18" alt="home"> on `main`/`master`, <img src="docs/icons/branch.svg" height="18" alt="branch"> elsewhere, <img src="docs/icons/pencil.svg" height="18" alt="pencil"> when dirty | `git status --porcelain=v1 --branch` run in `workspace.current_dir` | Magenta when clean, yellow with the pencil when the tree has changes. The counts described below sit between the name and the pencil. Shows `detached` on a detached HEAD |
| separator | <img src="docs/icons/chevron.svg" height="18" alt="chevron"> in `plain`, <img src="docs/icons/arrow.svg" height="18" alt="arrow"> in `powerline` | none | Dim chevron between segments, or a solid arrow coloured to blend the neighbouring blocks |

A dim <img src="docs/icons/chevron.svg" height="14" alt="chevron"> separates the segments in plain
style; powerline style joins the coloured blocks with a solid
<img src="docs/icons/arrow.svg" height="14" alt="arrow">. The icon images are SVG outlines
extracted from JetBrainsMono Nerd Font by `docs/render-icons.ps1`, because
GitHub cannot render the font itself. Icon names are from the
[Nerd Font cheat sheet](https://www.nerdfonts.com/cheat-sheet). Field names follow the
[Claude Code status line reference](https://code.claude.com/docs/en/statusline).

### Branch counts

Claude Code's payload carries no git data, so the script runs one `git status` in the working
directory and reads everything below from its output. A count of zero is left out, so a clean,
synced branch shows only the icon and the name.

| Marker | Meaning | Notes |
|---|---|---|
| `↑N` | Commits ahead of the upstream | Hidden when the branch has no upstream or the upstream is gone |
| `↓N` | Commits behind the upstream | Same |
| `+N` | Staged files | |
| `~N` | Files changed in the work tree | Modified, deleted, type-changed, or added with `git add -N`. A file that is staged and then edited again counts in both `+N` and `~N` |
| `?N` | Untracked entries | Git reports a new directory as one entry, however many files it holds |
| `nf-fa-exclamation_triangle` `N` | Files in conflict | Red, so it stands out |

The counts render dim, in that order, after the branch name and before the pencil. If the line is
too wide for the terminal they are the third thing shed, after the limits and context detail and
before any whole segment goes, leaving the icon, the name and the pencil.

The `git status` call is the one the script already made for the pencil, so the counts cost no
extra process. If a payload does include a `git` object with `branch` and `status`, as the test
samples do, the script reads the branch and the four file counts from it instead and shows no
arrows. A `git` object with an empty branch name shows nothing.

## Test without Claude Code

`test.ps1` runs three groups. Unit checks call the script's helper functions directly (width
measurement, config parsing, rendering, width fitting, the context meter, `git status` parsing, the
payload counts, the branch segment). The git group runs the branch fallback against temporary
repositories: clean, dirty, unborn, detached, one commit ahead, one behind, a mixed tree with a
staged, a modified and an untracked file, a fake `git` that fails and one that hangs. The render
matrix pipes every payload in `samples/` through the script for each layout and style at each
width:

```powershell
.\test.ps1                                # full run, about a minute
.\test.ps1 -Columns 80                    # one width instead of 120, 60, 20 and unset
.\test.ps1 -Config .\statusline.json      # one config instead of the four combinations
.\test.ps1 -Raw                           # show ANSI escapes as <ESC>
```

Every render must exit 0 with nothing on stderr, print the number of lines its layout allows, and fit
the terminal width. At a set width the branch segment must be whole, shortened, or gone, never half
shed. At the unset width the matrix also checks content: each segment the sample and config enable
must appear on its row with its glyph and value, disabled segments must not, and the separators must
match the style. Those content checks only run when `-Columns` includes `0`, which the default does.
The script exits non-zero if any check fails. Each render takes about 250 ms, nearly all of it
`pwsh` start-up.

The tests never touch your own repositories. They point `GIT_CEILING_DIRECTORIES` at the temp
folder and pass an empty global git config, so the results do not depend on the machine.

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
- The 60% and 85% colour cut-offs are the defaults of `Get-ThresholdRole`. The context block passes 70 and 90 for a 1M window; the rate-limit block uses the defaults.
- `Get-Palette` holds the colours for both styles.

Segment order is fixed for each layout, and `statusline.json` only hides segments rather than moving them.
To change the order, edit the lists near the bottom of `statusline.ps1`: `$segmentNames` for layout `one`, and
`$lineSets` for the two rows of layout `two`.

## Troubleshooting

Icons show as boxes or question marks: the terminal font is not a Nerd Font. Set it to
`JetBrainsMono NF` or any other Nerd Font.

The status line is blank: run `.\test.ps1` to confirm the script works, then check that `pwsh` is on
your `PATH` and that the `command` path in `settings.json` exists.

No branch segment: the script runs `git status` in the session's working directory. Check that
`git` is on your `PATH` and that the directory is inside a repository. If `git status` takes longer
than 1.5 seconds the segment is skipped for that refresh.

No arrows after the branch name: the branch has no upstream, or the upstream branch was deleted.
`git branch -u origin/<branch>` sets one.

`?1` for a folder full of new files: git reports an untracked directory as a single entry. The
count is of entries, not files.

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
positionally. If you add a segment or a sample, add a payload to `samples/` and give it a row in the
`$sampleSegments` and `$sampleMarkers` tables in `test.ps1` (which segments it shows, and the glyph
and value to look for). A sample without those rows fails the run by name. A sample whose branch
segment carries counts also needs a row in `$sampleBranchForms`, the full and shortened text the
matrix accepts at a set width. Then regenerate the screenshots at the top of this file with
`pwsh docs/render-screenshot.ps1` and
`pwsh docs/render-screenshot.ps1 -Config docs/statusline-two-line.json -Out docs/statusline-two-line.png`.

Commits are scanned for secrets with [gitleaks](https://github.com/gitleaks/gitleaks), both in CI
and through a pre-commit hook. To enable the hook in your clone:

```powershell
winget install Gitleaks.Gitleaks
git config core.hooksPath .githooks
```

## Roadmap

Done so far:

- [x] Query git directly for branch and dirty state
- [x] Optional two-line layout and powerline style
- [x] Ahead and behind counts on the branch
- [x] Staged, changed, untracked and conflict counts on the branch
- [x] `1M` marker and past-200k warning on the model segment, wider colour bands for a 1M window

[Issues #2 to #28](https://github.com/ookla-ariel-ride/claude-code-statusline-ps/issues) hold what comes next,
each with its own plan. In rough order: small additions to existing segments (installer flags),
then a segment registry so order, thresholds and glyphs move into
`statusline.json`, then new segments (pull-request link, cache warmth, session clock), presets and
per-project config, and finally an ASCII style that needs no Nerd Font and a light palette.

## License

MIT. See [`LICENSE`](LICENSE).
