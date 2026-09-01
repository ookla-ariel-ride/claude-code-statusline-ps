# Project Brief: claude-code-statusline-ps

## Purpose

A single-file PowerShell status line for Claude Code on Windows. It replaces the default status line
with one line showing the active model, context-window usage, session cost, current folder, and git
branch state, rendered with Nerd Font glyphs and ANSI colour.

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

## Non-goals

- Cross-platform support for macOS or Linux (bash alternatives already exist).
- Continuous or animated rendering. The line refreshes on Claude Code events only.
- Plugin or module packaging. The deliverable is a script you copy.

## Scope

| File | Role |
|---|---|
| `statusline.ps1` | The status line. Reads JSON on stdin, prints one coloured line. |
| `install.ps1` | Copies the script to `~/.claude/`, writes the `statusLine` entry to user settings, optionally installs JetBrainsMono Nerd Font via winget and sets it as the Windows Terminal default font. Supports `-Uninstall`. |
| `test.ps1` | Renders every payload in `samples/` and reports timing. `-Raw` shows ANSI escapes. Exits non-zero on empty output. |
| `samples/*.json` | Five representative payloads: clean main, dirty feature branch at high context, dirty main at mid context, minimal payload, no git. |

## Segments

| Segment | Source field | Rendering |
|---|---|---|
| Model | `model.display_name` | Bold cyan, robot glyph |
| Context | `context_window.used_percentage`, `total_input_tokens`, `total_output_tokens`, `context_window_size` | Percent, ten-block bar, used/total in k or M. Green below 60%, yellow below 85%, red above |
| Cost | `cost.total_cost_usd` | Dimmed, two decimals |
| Folder | `workspace.current_dir` | Blue, leaf directory name |
| Branch | `git.branch`, `git.status` | Home glyph on main/master, branch glyph otherwise. Yellow with pencil glyph when dirty, magenta when clean |

## Key design decisions

- **Glyphs from code points.** Icons are built with `[char]::ConvertFromUtf32` rather than pasted into
  the file, so the script's encoding can never corrupt them. Stdout is forced to UTF-8.
- **Forward slashes in the configured command.** Claude Code may invoke the command through Git Bash,
  which strips backslashes, so the installer writes the path with forward slashes.
- **Silent error handling in the status line.** `$ErrorActionPreference` is `SilentlyContinue` and a
  JSON parse failure falls back to a plain model glyph. A broken status line must never break Claude Code.
- **Line endings.** `.gitattributes` forces CRLF on `.ps1` files and LF elsewhere.

## Constraints

- Each render costs roughly 250 ms of pwsh start-up. Acceptable for event-driven refresh, but the
  script should stay lightweight and avoid module imports.
- Git status counts arrive as Int64 from `ConvertFrom-Json`; the dirty check must handle numeric,
  boolean, and string forms of `git.status`.

## Success criteria

- `.\test.ps1` renders all five samples with non-empty output.
- `.\install.ps1` on a fresh machine produces a working status line in Claude Code after one session restart.
- `.\install.ps1 -Uninstall` returns `settings.json` to its prior state minus the `statusLine` key.

## Status

Initial release committed. Core script, installer, test harness, and sample payloads are in place.

## Possible future work

- Additional optional segments (elapsed session time, lines added/removed) gated on payload fields.
- A colour-theme switch for light terminals.
- Publishing to the PowerShell Gallery if demand warrants.

## License

MIT
