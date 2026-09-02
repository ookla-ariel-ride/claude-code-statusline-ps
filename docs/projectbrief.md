# Project Brief: claude-code-statusline-ps

## Purpose

A PowerShell status line for Claude Code on Windows. It replaces the default status line with one
or two lines showing the active model, context-window usage, session cost, lines changed, rate
limits, mode badges, current folder, and the git branch with its ahead, behind and file-change
counts, rendered with Nerd Font glyphs and ANSI colour.

## Problem

Claude Code's status line is configured as a shell command that receives a JSON payload on stdin.
Most community status lines are bash scripts that assume a Unix environment. Windows users running
PowerShell 7 need something that works natively, installs into the user-level settings without
clobbering other keys, and renders glyphs correctly regardless of file encoding.

## Goals

- Work out of the box on Windows 11 with PowerShell 7 and Windows Terminal.
- Zero dependencies beyond PowerShell 7 and a Nerd Font.
- Degrade gracefully: omit any segment whose data is missing from the payload, and never print nothing.
- One-command install and uninstall that preserves the rest of `~/.claude/settings.json`.
- Be easy to customise by editing constants at the top of one file.
- Fit the terminal width rather than wrap.
- Be configurable from one small JSON file without editing the script.

## Non-goals

- Cross-platform support for macOS or Linux (bash alternatives already exist).
- Continuous or animated rendering. The line refreshes on Claude Code events only.
- Plugin or module packaging. The deliverable is a script you copy.

## Scope

| File | Role |
|---|---|
| `statusline.ps1` | Reads JSON on stdin and `statusline.json` beside it; prints one or two coloured lines fitted to `COLUMNS`. |
| `install.ps1` | Copies the script to `~/.claude/`, writes the `statusLine` entry to user settings, optionally installs JetBrainsMono Nerd Font via winget and sets it as the Windows Terminal default font. Supports `-Uninstall`. |
| `statusline.json` | Defaults for layout, style and segment toggles. Installed beside the script. |
| `test.ps1` | Unit-tests the script's pure functions, renders every sample across layout × style × width, and checks the git fallback in temporary repositories: clean, dirty, unborn, detached, ahead, behind, a mixed tree, a git that fails and one that hangs. `-Columns`, `-Config`, `-Raw`. |
| `samples/*.json` | Eight payloads: clean main, dirty feature at high context, dirty main at mid context, minimal, no git, limits with badges and lines, expired limits with default effort, a repository identity below its project root. |
| `docs/render-screenshot.ps1` | Renders a payload and config through the script and captures the terminal as the README screenshot. |
| `docs/render-icons.ps1` | Extracts the Nerd Font glyphs used by the script as SVG outlines for `docs/icons/`. |

## Segments

| Segment | Source field | Rendering |
|---|---|---|
| Model | `model.display_name` | Bold cyan, robot glyph |
| Context | `context_window.used_percentage`, `total_input_tokens`, `total_output_tokens`, `context_window_size` | Percent, ten-block bar, used/total in k or M. Green below 60%, yellow below 85%, red above |
| Cost | `cost.total_cost_usd` | Dimmed, two decimals |
| Lines | `cost.total_lines_added`, `total_lines_removed` | `+N` green, `−N` red. Hidden when both are zero |
| Limits | `rate_limits.five_hour`, `seven_day` | Coloured by the worse of the two |
| Badges | `fast_mode`, `thinking.enabled`, `effort.level`, `vim.mode` | Dim glyphs |
| Folder | `workspace.repo.owner`, `workspace.repo.name`, `workspace.project_dir`, `workspace.current_dir` | Blue. `owner/name` when the payload carries a repository, followed by `›` and the leaf of `current_dir` when it differs from `project_dir`. The leaf alone without a repository or with `"folder": "leaf"` in the config. Short form is the repository name |
| Branch | `git status --porcelain=v1 --branch` in `workspace.current_dir`. The Claude Code payload has no `git` object, so this is the normal path; a payload that does carry `git.branch` and `git.status` (the test samples) is used as is | Home glyph on main/master, branch glyph otherwise. Yellow with pencil glyph when dirty, magenta when clean. Between the name and the pencil, dim counts in a fixed order: `↑N` `↓N` ahead of and behind the upstream (header bracket, git path only), `+N` staged, `~N` changed in the work tree, `?N` untracked entries, then a red triangle with the conflict count. Zero counts are left out. The short form used at a narrow width is icon, name and pencil |

## Key design decisions

- **Glyphs from code points.** Icons are built with `[char]::ConvertFromUtf32` rather than pasted into
  the file, so the script's encoding can never corrupt them. Stdout is forced to UTF-8.
- **Forward slashes in the configured command.** Claude Code may invoke the command through Git Bash,
  which strips backslashes, so the installer writes the path with forward slashes.
- **Silent error handling in the status line.** `$ErrorActionPreference` is `SilentlyContinue` and a
  JSON parse failure falls back to a plain model glyph. A broken status line must never break Claude Code.
- **Line endings.** `.gitattributes` forces CRLF on `.ps1` files and LF elsewhere.
- **Git fallback with a hard timeout.** The documented payload has no `git` object, so the branch
  segment runs `git status` itself through `System.Diagnostics.Process`, kills it after 1.5 s, and
  omits the segment on any failure.
- **Segment records and one renderer.** Each segment is a small record (name, text, short text,
  colour role, bold); one function renders a line in plain or powerline style, and width fitting
  shrinks then drops records in a fixed order.
- **Silent config.** Any missing or invalid value in `statusline.json` falls back to its default with
  no output.
- **One branch record, two readers.** The porcelain parser and the payload reader return the same
  eight keys (branch, dirty, ahead, behind, staged, modified, untracked, conflicts), so the segment
  builder reads one shape whichever source filled it, and a test pins the two key sets against each
  other.
- **One rule for payload numbers.** A single helper decides whether a `git.status` value is a count
  (a whole number that fits an Int32). The dirty flag and the counts both use it, so a value can
  never mark the tree dirty without showing a count, or the reverse.

## Constraints

- Each render costs roughly 250 ms of pwsh start-up. Acceptable for event-driven refresh, but the
  script should stay lightweight and avoid module imports.
- Payload `git.status` counts arrive as Int64 from `ConvertFrom-Json`, and the field may also be a
  string (`"clean"`, `"modified"`) or an object of booleans. The parser of `git status` output runs
  once per entry, so it has to stay an index loop over chars: a large unignored tree has thousands
  of entries, and a pipeline there cost about nine times as much.

## Success criteria

- `.\test.ps1` passes: the unit checks, all eight samples across four configs and four widths (120, 60, 20 and unset) with content checks at the unset width, and the git cases.
- `.\install.ps1` on a fresh machine produces a working status line in Claude Code after one session restart.
- `.\install.ps1 -Uninstall` returns `settings.json` to its prior state minus the `statusLine` key.
- `.\install.ps1` leaves an existing `~/.claude/statusline.json` untouched.

## Status

Two-line layout, powerline style, config file, width fitting and the git fallback are implemented.
The branch segment shows ahead and behind counts (#16) and staged, changed, untracked and conflict
counts (#17), all from the one `git status` call. Segment order, thresholds, glyphs and a light
palette are still constants in the script.

## Future work

Issues #2 to #28 hold the backlog, each with a plan and success criteria. The intended order:

1. Existing segments only: a 1M-context marker (#9), installer flags for the refresh interval and
   the built-in vim indicator (#26).
2. A segment registry with `order`, `rows`, `thresholds` and `icons` keys in `statusline.json` (#20).
   Every later segment builds on it.
3. Enablers: a pull-request badge with the OSC 8 link helper (#12), a per-session state file for
   deltas between renders (#4).
4. New segments: cache warmth and hit ratio, owner/repo, worktree, links, agent and session badges,
   spend limit, cost per turn, pace, session clock (#2, #3, #5 to #8, #10, #11, #13, #14).
5. Config: presets, a quiet block, an alarm colour, per-project config, git cache and timeout
   (#18, #19, #21 to #23).
6. Style and terminal: an ASCII style, a light palette, a right-aligned group with a clock, taskbar
   progress, a subagent status line (#15, #24, #25, #27, #28).

## License

MIT
