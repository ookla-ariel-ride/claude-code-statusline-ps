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
- Continuous or animated rendering. The line refreshes on Claude Code events, plus a timer if the installer's `-RefreshInterval` was used.
- Plugin or module packaging. The deliverable is a script you copy.

## Scope

| File | Role |
|---|---|
| `statusline.ps1` | Reads JSON on stdin and `statusline.json` beside it; prints one or two coloured lines fitted to `COLUMNS`. |
| `install.ps1` | Copies the script to `~/.claude/`, writes the `statusLine` entry to user settings with `hideVimModeIndicator` on and, with `-RefreshInterval <seconds>`, a `refreshInterval`; optionally installs JetBrainsMono Nerd Font via winget and sets it as the Windows Terminal default font. Supports `-Uninstall` and `-SettingsPath` (the seam the tests use). |
| `statusline.json` | Defaults for layout, style, the folder mode, the state file toggle, segment toggles, and the git probe's timeout and cache (`git.timeoutMs`, `git.cacheSeconds`, `git.cache`). Installed beside the script. |
| `%TEMP%\claude-statusline-state\` | One JSON file per session (`<session_id>.json`, version 1): last cost, token totals, context and 5-hour percentages, and a ring of up to twenty cost readings. Written after the line is printed, swept of day-old files at most every six hours. `~/.claude/statusline-state` when `TEMP` is empty. |
| `%TEMP%\claude-statusline\` | The git probe cache: one JSON file per repository, named by the first 16 hex characters of the SHA-256 of the lower-cased work tree path, holding the root, a stamp string (the UTC ticks of the git directory, of `index`, `HEAD`, `ORIG_HEAD`, `FETCH_HEAD`, `MERGE_HEAD`, `packed-refs` and `logs/HEAD`, and of every directory under `refs`; a worktree's main repository after a bar), the write time and the last `git status` record, or null when the probe failed. Read before the branch segment is built and reused for `git.cacheSeconds` while the stamp string matches; swept of day-old files with the state sweep. `TMPDIR`, then the runtime's temp path, when `TEMP` is empty. |
| `test.ps1` | Unit-tests the script's pure functions, renders every sample across layout × style × width, checks the git fallback in temporary repositories: clean, dirty, unborn, detached, ahead, behind, a mixed tree, a git that fails and one that hangs, the probe cache with a counting stand-in and end to end with a failing git on `PATH`, exercises the session state file end to end, and runs `install.ps1` against a settings file in a temp folder. `-Columns`, `-Config`, `-Raw`. |
| `samples/*.json` | Every payload in `samples/` goes through the render matrix. One per case: clean main, dirty feature at high context, dirty main at mid context, minimal, no git, limits with badges and lines, expired limits with default effort, a repository identity below its project root, a 1M window with `exceeds_200k_tokens` true. |
| `docs/render-screenshot.ps1` | Renders a payload and config through the script and captures the terminal as the README screenshot. |
| `docs/render-icons.ps1` | Extracts the Nerd Font glyphs used by the script as SVG outlines for `docs/icons/`. |

## Segments

| Segment | Source field | Rendering |
|---|---|---|
| Model | `model.display_name`, `context_window.context_window_size`, `exceeds_200k_tokens` | Bold cyan, robot glyph. On a 1M window `1M` follows the name in a lighter cyan, then the warning triangle when Claude Code reports `exceeds_200k_tokens` as true |
| Context | `context_window.used_percentage`, `total_input_tokens`, `total_output_tokens`, `context_window_size` | Percent, ten-block bar, used/total in k or M. Green below 60%, yellow below 85%, red above. A 1M window uses 70% and 90%, so red still means about 100k tokens of room |
| Cost | `cost.total_cost_usd` | Dimmed, two decimals |
| Lines | `cost.total_lines_added`, `total_lines_removed` | `+N` green, `−N` red. Hidden when both are zero |
| Limits | `rate_limits.five_hour`, `seven_day`, `spend_limit` | Coloured by the worst of the figures. The spend figure is `$ 62%`, a literal dollar sign, shown only when the payload carries `spend_limit`, which Claude Code sends behind a Claude apps gateway with a spend limit (2.1.251 or later); its reset time is not shown |
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
  segment runs `git status` itself through `System.Diagnostics.Process`, kills it after
  `git.timeoutMs` (1.5 s by default, 100 ms to 10 s), and omits the segment on any failure.
- **The probe is cached, keyed on the git directory, not on the work tree.** A render that starts
  git pays for a process and a status walk every time; most renders happen seconds apart in an
  unchanged repository. The last answer is kept per repository and reused while the git directory's
  stamps match (the directory itself, seven named files, every directory under `refs`, because git
  renames `x.lock` into place and that moves the parent's stamp) and the entry is younger than
  `git.cacheSeconds`. Commits, checkouts, adds, resets, merges, fetches and pushes move one of them
  and show at once; an edit or a new file in the work tree moves none and shows when the entry ages
  out, a lag of five seconds by default. The read sits in front of the branch segment because it
  replaces the probe, and it is one file read and a dozen stats. A null answer is cached too, so a
  slow repository pays the timeout once per lifetime; a cached record is checked with the payload
  guards before it is rendered, and every failure ends in a plain probe.
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
- **Per-session state on disk, never on the line's critical path.** A render cannot see the previous
  payload, so a small JSON file per `session_id` carries the last cost and token totals forward. The
  read, the merge and the write all sit after the last `Write-Host`, so none of their cost is in front
  of the visible line; measured end to end, a render with a `session_id` reaches its first line within
  a millisecond or two of one without. Every failure (no temp folder, a read-only directory, a corrupt
  file) is silent and leaves the line unchanged. The record is written to a `.tmp` file and moved over
  the real one, so an interrupted write costs nothing. The file holds numbers and one id, nothing from
  the prompt or the file system. Cleanup is a stamped sweep, so the common render is one read and one
  write.

## Constraints

- Each render costs roughly 250 ms of pwsh start-up. Acceptable for event-driven refresh, but the
  script should stay lightweight and avoid module imports.
- Payload `git.status` counts arrive as Int64 from `ConvertFrom-Json`, and the field may also be a
  string (`"clean"`, `"modified"`) or an object of booleans. The parser of `git status` output runs
  once per entry, so it has to stay an index loop over chars: a large unignored tree has thousands
  of entries, and a pipeline there cost about nine times as much.

## Success criteria

- `.\test.ps1` passes: the unit checks, every payload in `samples/` across five configs and four widths (120, 60, 20 and unset) with content checks at the unset width, the git cases, and the install cases.
- `.\install.ps1` on a fresh machine produces a working status line in Claude Code after one session restart.
- `.\install.ps1 -Uninstall` returns `settings.json` to its prior state minus the `statusLine` key.
- `.\install.ps1` leaves an existing `~/.claude/statusline.json` untouched.

## Status

Two-line layout, powerline style, config file, width fitting and the git fallback are implemented.
The branch segment shows ahead and behind counts (#16) and staged, changed, untracked and conflict
counts (#17), all from the one `git status` call, and that call is cached per repository with its
timeout and lifetime in the config (#18). Segment order, thresholds, glyphs and a light palette are
still constants in the script.

## Future work

Issues #2 to #28 hold the backlog, each with a plan and success criteria. The intended order:

1. Existing segments only: installer flags for the refresh interval and the built-in vim
   indicator (#26). The 1M-context marker (#9) is done.
2. A segment registry with `order`, `rows`, `thresholds` and `icons` keys in `statusline.json` (#20).
   Every later segment builds on it.
3. Enablers: a pull-request badge with the OSC 8 link helper (#12), a per-session state file for
   deltas between renders (#4).
4. New segments: cache warmth and hit ratio, owner/repo, worktree, links, agent and session badges,
   spend limit, cost per turn, pace, session clock (#2, #3, #5 to #8, #10, #11, #13, #14).
5. Config: presets, a quiet block, an alarm colour, per-project config (#19, #21 to #23). The git
   cache and timeout (#18) are done.
6. Style and terminal: an ASCII style, a light palette, a right-aligned group with a clock, taskbar
   progress, a subagent status line (#15, #24, #25, #27, #28).

## License

MIT
