# claude-code-statusline-ps

A PowerShell status line for [Claude Code](https://code.claude.com) on Windows. One script, one small JSON config, and a Nerd Font — or, with the `ascii` style, no special font at all. A second script draws the agent panel to match.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE.svg?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Windows](https://img.shields.io/badge/platform-Windows-0078D4.svg?logo=windows&logoColor=white)](#requirements)

![Status line rendered in Windows Terminal with JetBrainsMono Nerd Font](docs/statusline.png)

Left to right: model, context meter, cache warmth, cost, session clock, lines changed, rate limits,
session badges, the pull request, folder, and the branch with its change counts — the eleven segments
that ship on by default.

![Two-line powerline layout](docs/statusline-two-line.png)

The same data in the two-line powerline layout, with the twelfth segment, the wall clock, turned on.

## About

Claude Code can hand its status bar to any command that reads a JSON payload on stdin and prints a
line. The examples in its docs are bash scripts. This one is PowerShell 7. It shows the numbers you
would otherwise go looking for: how full the context window is, what the session has cost, how close
you are to a rate limit, and which modes are on. It installs into your user settings with one command.

## Features

- Context meter: the percentage, a ten-block bar, the session's used/total context tokens (`64k/200k`), and how much of the current turn's input the prompt cache served (`92% cached`).
- Prompt cache warmth as `cache 42m`, yellow in the last five minutes; `cache warm` with no expiry; red `cache cold` once it lapses, or `cache off` when caching is not working.
- Rate limits for the 5-hour and 7-day windows, a countdown to the next reset, a pace arrow, and the spend limit when Claude Code reports one.
- Session cost with the change since the last turn, lines added and removed, and a session clock with the share spent waiting on the model.
- Badges for fast mode, extended thinking, effort level and vim mode, then the custom agent and the session name.
- The pull request as `#12`, green when approved, red when changes are requested. Ctrl-click opens it.
- Folder and branch, with a home glyph on `main` or `master`, a pencil when the tree is dirty, ahead/behind and file counts, and the worktree name. Both are ctrl-clickable.
- One line or two, plain separators or powerline blocks, any segment off, a `right` group, and a wall clock — all from `statusline.json`. A repository can pin its own layout.
- `"style": "ascii"` draws the whole line in plain characters for a terminal whose font you cannot change; `"palette": "light"` recolours it for a pale background.
- A matching row for each subagent in the agent panel, and optionally the context percentage on the taskbar button.
- Fits the terminal width by shedding detail, then the right group, then whole segments, so lines stop wrapping.
- Payload decoded as UTF-8 whatever the console code page, so non-English names render as sent. Missing fields drop their segment; a payload that will not parse still prints the model glyph and the word `claude`.
- No modules. PowerShell 7 and a Nerd Font are the whole dependency list, and `ascii` drops the font.

## Requirements

- Windows 10 or 11
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) on your `PATH` as `pwsh`
- Claude Code
- A [Nerd Font](https://www.nerdfonts.com/) in your terminal, or `"style": "ascii"` where the font is not yours to set. The installer can set up JetBrainsMono Nerd Font for you.
- `git` on your `PATH` for the branch segment. Without it that segment is skipped and the rest renders.

## Installation

```powershell
git clone https://github.com/ookla-ariel-ride/claude-code-statusline-ps
cd claude-code-statusline-ps
.\install.ps1 -InstallFont -ConfigureWindowsTerminal
```

Restart Claude Code, or wait for its next status refresh.

The installer copies `statusline.ps1` and, unless one is already there, `statusline.json` into
`~/.claude`, and adds a `statusLine` entry to `~/.claude/settings.json` with every other key kept and
the previous version backed up beside it. The entry also sets `padding` to 0 and turns Claude Code's
own vim indicator off (`hideVimModeIndicator`), because the badges segment draws one. The switches:

| Switch | What it does |
|---|---|
| `-InstallFont` | Installs JetBrainsMono Nerd Font through winget. Expect one elevation prompt. |
| `-ConfigureWindowsTerminal` | Sets Windows Terminal's default font to `JetBrainsMono NF`, backing its settings up first; if that backup cannot be taken the font is left alone, with a warning. |
| `-DetectTheme` | Reads Windows Terminal's colour scheme and writes `palette` into `statusline.json`. When it cannot tell, it writes nothing and says why. |
| `-Style plain\|powerline\|ascii`, `-Palette dark\|light` | Writes that key into `~/.claude/statusline.json` (which must already exist) and carries it into the agent panel's command. Any run refreshes a panel entry this installer wrote. |
| `-RefreshInterval <seconds>` | Re-renders on a timer as well as on events, which keeps the wall clock and the taskbar bar current between events. Must be 1 or more. A reinstall without it drops the key, with a warning naming the value dropped. |
| `-Subagents` | Installs the agent panel script and its `subagentStatusLine` entry. See [The agent panel](docs/agent-panel.md). |
| `-Uninstall` | Removes the `statusLine` entry and `~/.claude/statusline.ps1` outright; removes the panel entry and script only when they are this project's. Keeps the font and `statusline.json`. |

Any Nerd Font works. In VS Code, ConEmu or another terminal, set the font yourself and skip
`-ConfigureWindowsTerminal`. `-SettingsPath <file>` exists for the test suite and only changes which
settings file is edited. What each switch writes, the settings entry, the backup names and the
ownership rules are in [docs/installer.md](docs/installer.md).

### The agent panel

```powershell
.\install.ps1 -Subagents
```

Claude Code shows a panel of the subagents a session is running. `subagent-statusline.ps1` draws one
row per subagent: the robot glyph, the agent's name, how full its context window is and its token
count, or the task's status word (`running`, `pending`, `completed`) while it reports no figures.

```
󰚩 Explore  24%  48k
󰚩 general-purpose  91%  182k
```

The panel reads no config file, so its style and palette ride on the command the installer writes,
taken from your own `statusline.json`. Change the key and run the installer again to carry it into the
panel. The contract, the precedence, and what the panel does not follow are in
[docs/agent-panel.md](docs/agent-panel.md).

## Configuration

The script reads `~/.claude/statusline.json`. The installed file holds the defaults:

```json
{
  "layout": "one",
  "style": "plain",
  "palette": "dark",
  "tint": "role",
  "folder": "repo",
  "state": true,
  "links": true,
  "taskbar": false,
  "thresholds": { "warn": 60, "bad": 85 },
  "alarm": { "context": 90, "limits": 90 },
  "icons": {},
  "git": { "timeoutMs": 1500, "cacheSeconds": 5, "cache": true },
  "segments": {
    "model": true, "context": true, "cache": true, "cost": true, "clock": true, "lines": true,
    "limits": true, "badges": true, "pr": true, "folder": true, "branch": true
  }
}
```

A config needs only the keys it changes. A repository can add its own `.claude/statusline.json`,
merged over yours key by key. Anything missing or invalid falls back to the value beneath it, silently.

| Key | Values | What it does |
|---|---|---|
| `preset` | `minimal`, `cost`, `full` | A named layout, style and segment set. Every other key in the file is applied over it. |
| `layout` | `one`, `two` | One line, or model/folder/branch/pr/badges (and the wall clock, when on) on the first and the figures on the second. |
| `style` | `plain`, `powerline`, `ascii` | Coloured text with a chevron, coloured blocks with arrows, or printable ASCII throughout. |
| `palette` | `dark`, `light` | The colour table, separate from `style`; all six pairings work. |
| `tint` | `role`, `segment` | `role` keeps the existing semantic colours. `segment` gives each resting segment a distinct colour; warnings and errors stay yellow or red. |
| `folder` | `repo`, `leaf` | `owner/name › dir` from the payload's repository, or the directory name alone. |
| `segments.<name>` | `true`, `false` | Turns a segment off. `time`, the wall clock, is the one that is off by default. |
| `order`, `rows` | lists of names | The segments of layout `one`, or the two rows of layout `two`. Left out, the script's order applies, new segments included. |
| `right` | `["time"]` | Segments pushed against the right edge of the first line. The first whole segments a narrow line loses. |
| `thresholds` | `{ "warn": 60, "bad": 85 }` | Where the context meter and the rate limits turn yellow and red: whole numbers 0–100, `warn` no higher than `bad`, or the pair is ignored together. The context meter on a 1M window keeps its own 70 and 90. |
| `alarm` | `{ "context": 90, "limits": 90 }` | Where the model segment itself turns red. `0` turns that alarm off. |
| `quiet` | `{ "cost": 0, "context": 0, "limits": 0 }` | The smallest value a segment is worth showing at; all off by default. `{"cost": 1.00}` hides a cost under a dollar. Never hides a warning or an alarm. |
| `icons` | `{ "home": "U+2302" }` | A code point per glyph name, as `U+2302`, `0x2302` or `2302`. Ignored under `ascii`. |
| `state`, `links`, `taskbar` | `true`, `false` | The per-session state file, the OSC 8 hyperlinks, and the taskbar bar (off by default). |
| `git.timeoutMs`, `git.cacheSeconds`, `git.cache` | `100`–`10000`, `0`–`300`, boolean | How long to wait for `git status`, how long to reuse its answer, and whether to. |

Presets: `minimal` is model, context, folder and branch; `cost` is model, context, cache, cost, clock,
lines and limits, with folder and branch off; `full` is everything on two powerline rows. The whole
file can be `{"preset": "minimal"}`.

When a line is too long it loses detail first (the cost delta, the limits countdown, the cache
segment's word, the context token counts, the branch counts, and so on), then the right group, then
whole segments in a fixed order: the wall clock, lines, the session clock, cache, badges, cost,
limits, pr, folder, branch, and the context meter last. The model segment always stays, and turns
red at the `alarm` level so a full window is visible at any width.

Every key in full, how the two config files are read (each under a 64 KiB and 250 ms budget), the
fitting order, the state file and the git cache: [docs/configuration.md](docs/configuration.md).

### Styles and palettes

`{"style": "ascii"}` draws every glyph the script chooses in printable ASCII and keeps every colour,
for the VS Code terminal, a session over SSH, or anywhere the font is not yours to change. Your own
text — a branch called `機能/x` — is drawn as it arrived.

```
Fable 5.1 > ctx 32% ###....... 64k/200k 92% cached > $1.07 > 1h12m | api 38%
  > +156 -23 > 5h 24% = (2h11m) 7d 88% > fast think xhigh NORMAL > dir my-project > ~ main
```

`{"palette": "light"}` swaps the colour table for one chosen against white, in any style. Every value
in both tables is held to a measured contrast floor by the test suite. `{"tint": "role"}` is the
default and keeps those semantic role colours, including their alternating shades where a repeated
role needs a visible joint. `{"tint": "segment"}` instead gives every resting segment its own
colour; a warning or error still takes its yellow or red semantic role. [The measured details](docs/styles-and-palettes.md#tint-ownership) cover both choices.
`.\install.ps1 -DetectTheme`
reads Windows Terminal's scheme and sets the key, or says why it could not. The stand-in table, the
contrast rules and what `-DetectTheme` reads: [docs/styles-and-palettes.md](docs/styles-and-palettes.md).

### Taskbar progress

With `"taskbar": true` the context percentage is drawn on the window's taskbar button in Windows
Terminal on every render: green, or red once the context window or either rate limit reaches its
`alarm` level (the number is always the context window's). A render that knows no percentage clears
the bar, and a refresh interval keeps it current while the session sits idle. Off by default because Claude
Code draws its own turn-progress bar there; set `"terminalProgressBarEnabled": false` in
`settings.json` to hand the bar over. Details, and how to clear a stuck bar: [docs/taskbar.md](docs/taskbar.md).

## What each segment shows

| Segment | Icon | Data | Rendering |
|---|---|---|---|
| model | <img src="docs/icons/robot.svg" height="18" alt="robot"> | `model.display_name` | Bold cyan, or the word `claude` when the name is unusable; `1M` on a 1M window, a warning once the payload reports `exceeds_200k_tokens`; red at the `alarm` level. Never shortened or dropped. |
| context | <img src="docs/icons/memory.svg" height="18" alt="memory"> | `context_window.*` | `32% ███░░░░░░░ 64k/200k 92% cached`: the percentage, a ten-block bar, the session's used/total context tokens (`8.0k` under ten thousand, `1.0M` at a million, the used count alone when the window size is missing), then the share of the current turn's input the prompt cache served — a different thing from the counts beside it. Green, yellow, red on the thresholds. |
| cache | <img src="docs/icons/fire.svg" height="18" alt="fire"> | `prompt_cache.*` | `cache 42m` (`2h05m`, `<1m`), yellow in the last five minutes; `cache warm` when alive with no usable expiry; red `cache cold` once lapsed or `cache off` when caching is observed not to work. Absent until Claude Code sends the block. |
| cost | <img src="docs/icons/cash.svg" height="18" alt="cash"> | `cost.total_cost_usd` | `$1.07 (+$0.12)`, the delta from the state file. |
| clock | <img src="docs/icons/timer-outline.svg" height="18" alt="stopwatch"> | `cost.total_duration_ms`, `total_api_duration_ms` | `1h12m · api 38%` (`12m`, `<1m`), dim, no bands. |
| time | <img src="docs/icons/clock-outline.svg" height="18" alt="clock"> | the machine clock | `14:05`. Off by default; needs a refresh interval. |
| lines | <img src="docs/icons/code.svg" height="18" alt="code"> | `cost.total_lines_*` | `+N` green, `−N` in the `removed` colour, always together. Hidden only when both are zero. |
| limits | <img src="docs/icons/tachometer.svg" height="18" alt="tachometer"> | `rate_limits.*` | `5h 24% → (1h12m) 7d 41% $ 62%`: the 5-hour figure with a pace arrow (`→` on track, `↑` overrunning, red past 120%) and the countdown to its reset (`(3d)` beyond two days), the 7-day figure, and the spend limit when sent. Coloured by the worst figure. |
| badges | <img src="docs/icons/bolt.svg" height="18" alt="bolt"> <img src="docs/icons/brain.svg" height="18" alt="brain"> <img src="docs/icons/speedometer.svg" height="18" alt="speedometer"> <img src="docs/icons/vim.svg" height="18" alt="vim"> <img src="docs/icons/user.svg" height="18" alt="user"> <img src="docs/icons/tag.svg" height="18" alt="tag"> | `fast_mode`, `thinking`, `effort`, `vim`, `agent`, `session_name` | Dim glyphs, modes first, then the agent and session names cut to 20 cells. Effort is hidden at `high`; the segment is hidden when nothing is on. |
| pr | <img src="docs/icons/pull-request.svg" height="18" alt="pull request"> | `pr.*` | `#12`, linked; green approved, red changes requested. |
| folder | <img src="docs/icons/folder-open.svg" height="18" alt="folder"> | `workspace.*` | Blue `owner/name › dir` when the payload names a repository, else the directory name; linked to the directory. |
| branch | <img src="docs/icons/home.svg" height="18" alt="home"> <img src="docs/icons/branch.svg" height="18" alt="branch"> <img src="docs/icons/fork.svg" height="18" alt="fork"> <img src="docs/icons/pencil.svg" height="18" alt="pencil"> | `git status` | Home glyph on `main` or `master`; magenta clean, yellow with a pencil when dirty, `detached` on a detached HEAD; then the fork glyph and worktree name (the glyph alone when the worktree has no name), `↑N` `↓N` `+N` `~N` `?N` counts, and the conflict triangle with its count. Linked to the branch page on `github.com`, the repository home elsewhere. |

The full rules for every segment, the branch counts and the worktree name are in
[docs/segments.md](docs/segments.md). Icon names follow the
[Nerd Font cheat sheet](https://www.nerdfonts.com/cheat-sheet) and field names the
[Claude Code status line reference](https://code.claude.com/docs/en/statusline).

## Test without Claude Code

```powershell
pwsh -NoProfile -File .\tools\Invoke-Suite.ps1 -Wait # full suite, detached and locked to one run
.\test.ps1 -Columns 80                              # one width instead of 120, 60, 20 and unset
.\test.ps1 -Config .\statusline.json                # one config instead of the seven
Get-Content my-payload.json -Raw | pwsh -NoProfile -File .\statusline.ps1
Get-Content .\samples\subagent\01-two-agents.json -Raw | pwsh -NoProfile -File .\subagent-statusline.ps1 -Style ascii
```

### Running the suite

Use `pwsh -NoProfile -File .\tools\Invoke-Suite.ps1 -Wait` for the full suite. It refuses a second
suite by default, starts `test.ps1` detached and stamps the log path it prints. If the calling shell is
lost, resume it with `pwsh -NoProfile -File .\tools\Invoke-Suite.ps1 -Attach <log-path>`.

The suite never touches your own repositories or your real `~/.claude`. What it covers, and how to
add a segment or a sample: [docs/testing.md](docs/testing.md).

## Troubleshooting

Icons show as boxes: the terminal font is not a Nerd Font. Set one, or put `"style": "ascii"` in
`statusline.json` and run `.\install.ps1` again if you use the agent panel, so the panel's command
picks the style up.

A non-English branch or folder name comes out as `µ⌐ƒΦâ╜/x`: you are running an old copy. Reinstall,
with `-Subagents` if you use the panel; nothing else needs setting.

The status line is blank: run `.\test.ps1`, then check that `pwsh` is on your `PATH` and that the
`command` path in `settings.json` exists.

No branch segment: `segments.branch` is off or `order`/`rows` leaves it out, `git` is not on your
`PATH`, the directory is not in a repository, or `git status` took longer than `git.timeoutMs`
(1.5 s). A segment a few seconds behind is the cache: `git.cacheSeconds` shortens it, `"cache": false`
turns it off. No `↑`/`↓` arrows means the branch has no upstream; `git branch -u origin/<branch>` sets
one. `?1` for a folder of new files is git counting the directory as one entry.

The line still wraps: width is measured with a small approximation, and wide glyphs or emoji in a
folder or branch name can be counted short on some terminals. At very narrow widths the model segment
prints even when it does not fit.

Colours look washed out on a pale terminal: the default dark table's dim `251` is 1.71:1 on white and
1.58:1 on Solarized Light, while alternate `254` is 1.27:1 on white (SGR `90` was Campbell `#767676`,
4.54:1 on white). A light terminal using the default palette should set `"palette": "light"`, or run
`.\install.ps1 -DetectTheme`.

`]8;;` or a URL printed as text: the terminal does not know OSC 8 hyperlinks. Set `"links": false`.
Ctrl-click on the branch opening the repository home rather than the branch is expected off `github.com`.

The taskbar bar flickers or sticks: both writers are on, or the last bar drawn is still there. See
[docs/taskbar.md](docs/taskbar.md).

Nothing to go on: set `CLAUDE_STATUSLINE_DEBUG=1` and every swallowed failure, cache miss and refused
config writes a line to `claude-statusline-diag.log` in your temp folder. See
[docs/diagnostics.md](docs/diagnostics.md).

## Contributing

Issues and pull requests are welcome. Before opening a PR:

```powershell
.\test.ps1
Install-Module PSScriptAnalyzer -Scope CurrentUser
Get-ChildItem *.ps1, docs\*.ps1, tools\*.ps1 | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings .\PSScriptAnalyzerSettings.psd1 }
```

Some checks are load-sensitive ([#94](https://github.com/ookla-ariel-ride/claude-code-statusline-ps/issues/94),
[#99](https://github.com/ookla-ariel-ride/claude-code-statusline-ps/issues/99),
[#102](https://github.com/ookla-ariel-ride/claude-code-statusline-ps/issues/102)): a child render
that misses its 250 ms config budget draws the defaults and fails a random matrix cell. Re-run a
failing check alone before reading it as a regression. Adding a segment or a sample, and regenerating the
screenshots, is described in [docs/testing.md](docs/testing.md). Commits are scanned for secrets with
[gitleaks](https://github.com/gitleaks/gitleaks); `winget install Gitleaks.Gitleaks` and
`git config core.hooksPath .githooks` enable the pre-commit hook.

## Roadmap

The feature backlog is done. [The open issues](https://github.com/ookla-ariel-ride/claude-code-statusline-ps/issues)
record the test families that can fail under parallel load (#94, #99, #102). The design record is
[docs/projectbrief.md](docs/projectbrief.md).

## License

MIT. See [`LICENSE`](LICENSE).
