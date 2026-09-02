# Project Brief: claude-code-statusline-ps

## Purpose

A single-file PowerShell status line for Claude Code on Windows. It replaces the default status line
with one or two lines showing the active model, context-window usage, session cost, lines changed,
rate limits, mode badges, current folder, and git branch state, rendered with Nerd Font glyphs and
ANSI colour.

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
| `test.ps1` | Unit-tests the script's pure functions, renders every sample across layout × style × width, and checks the git fallback in temporary repositories, including a git that fails and one that hangs. `-Columns`, `-Config`, `-Raw`. |
| `samples/*.json` | Seven payloads: clean main, dirty feature at high context, dirty main at mid context, minimal, no git, limits with badges and lines, expired limits with default effort. |
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
| Folder | `workspace.current_dir` | Blue, leaf directory name |
| Branch | `git status --porcelain=v1 --branch` in `workspace.current_dir`. The Claude Code payload has no `git` object, so this is the normal path; a payload that does carry `git.branch` and `git.status` (the test samples) is used as is | Home glyph on main/master, branch glyph otherwise. Yellow with pencil glyph when dirty, magenta when clean. Dim `↑N` and `↓N` between the name and the pencil for commits ahead of and behind the upstream, parsed from the porcelain header, so only the git path shows them. After the arrows, dim `+N` `~N` `?N` for staged, modified and untracked files, counted from the porcelain lines or read from a payload `git.status` object, then a red `nf-fa-exclamation_triangle` with the number of conflicted files. Zero counts are left out. A line that is too wide sheds the counts before any segment is dropped |

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

## Constraints

- Each render costs roughly 250 ms of pwsh start-up. Acceptable for event-driven refresh, but the
  script should stay lightweight and avoid module imports.
- Git status counts arrive as Int64 from `ConvertFrom-Json`; the dirty check must handle numeric,
  boolean, and string forms of `git.status`.

## Success criteria

- `.\test.ps1` passes: the unit checks, all seven samples across four configs and four widths (120, 60, 20 and unset) with content checks at the unset width, and the git cases.
- `.\install.ps1` on a fresh machine produces a working status line in Claude Code after one session restart.
- `.\install.ps1 -Uninstall` returns `settings.json` to its prior state minus the `statusLine` key.
- `.\install.ps1` leaves an existing `~/.claude/statusline.json` untouched.

## Status

Two-line layout, powerline style, config file, width fitting and the git fallback are implemented.
Segment order, thresholds, glyphs and a light palette are still constants in the script.

## Possible future work

Later: configurable segment order, thresholds, glyphs; light palette; session duration; PR number as
an OSC 8 link; prompt-cache health; `owner/repo` and worktree identity; agent name; 1M-context colour
scaling; `refreshInterval` in the installer; git status cache; configurable git timeout; full
`wcwidth`.

## License

MIT
