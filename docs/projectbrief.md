# Project Brief: claude-code-statusline-ps

## Purpose

A PowerShell status line for Claude Code on Windows. It replaces the default status line with one
or two lines showing the active model, context-window usage, session cost, lines changed, rate
limits, mode badges, the branch's pull request as a clickable link, current folder, and the git
branch with its ahead, behind and file-change counts, rendered with Nerd Font glyphs and ANSI colour.

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
| `statusline.json` | Defaults for layout, style, the folder mode, the state file toggle, segment toggles, the colour thresholds, glyph overrides, and the git probe's timeout and cache (`git.timeoutMs`, `git.cacheSeconds`, `git.cache`). The layout-one `order` and layout-two `rows` keys are left out so the registry stays the source and a new segment appears on its own. Installed beside the script. |
| `%TEMP%\claude-statusline-state\` | One JSON file per session (`<session_id>.json`, version 1): last cost, token totals, context and 5-hour percentages, and a ring of up to twenty cost readings. Written after the line is printed, swept of day-old files at most every six hours. `~/.claude/statusline-state` when `TEMP` is empty. |
| `%TEMP%\claude-statusline\` | The git probe cache: one JSON file per repository, named by the first 16 hex characters of the SHA-256 of the lower-cased work tree path, holding the root, a stamp string (the UTC ticks of the git directory, of `index`, `HEAD`, `ORIG_HEAD`, `FETCH_HEAD`, `MERGE_HEAD`, `packed-refs`, `logs/HEAD`, `config` and `info/exclude`, and of every directory under `refs`, capped at 256; a worktree's main repository after a bar), the write time and the last `git status` record, or null when the probe failed. Read before the branch segment is built and reused for `git.cacheSeconds` while the stamp string matches; swept of day-old files with the state sweep. `TMPDIR`, then the runtime's temp path, when `TEMP` is empty. |
| `test.ps1` | Unit-tests the script's pure functions, renders every sample across layout × style × width, checks the git fallback in temporary repositories: clean, dirty, unborn, detached, ahead, behind, a mixed tree, a git that fails and one that hangs, the probe cache with a counting stand-in and end to end with a failing git on `PATH`, exercises the session state file end to end, and runs `install.ps1` against a settings file in a temp folder. `-Columns`, `-Config`, `-Raw`. |
| `samples/*.json` | Every payload in `samples/` goes through the render matrix. One per case: clean main, dirty feature at high context, dirty main at mid context, minimal, no git, limits with badges and lines, expired limits with default effort, a repository identity below its project root, a 1M window with `exceeds_200k_tokens` true, a feature branch with an approved pull request. |
| `docs/render-screenshot.ps1` | Renders a payload and config through the script and captures the terminal as the README screenshot. |
| `docs/render-icons.ps1` | Extracts the Nerd Font glyphs used by the script as SVG outlines for `docs/icons/`. |

## Segments

| Segment | Source field | Rendering |
|---|---|---|
| Model | `model.display_name`, `context_window.context_window_size`, `exceeds_200k_tokens` | Bold cyan, robot glyph. On a 1M window `1M` follows the name in a lighter cyan, then the warning triangle when Claude Code reports `exceeds_200k_tokens` as true |
| Context | `context_window.used_percentage`, `total_input_tokens`, `total_output_tokens`, `context_window_size` | Percent, ten-block bar, used/total in k or M. Green below 60%, yellow below 85%, red above. A 1M window uses 70% and 90%, so red still means about 100k tokens of room |
| Cost | `cost.total_cost_usd` | Dimmed, two decimals |
| Lines | `cost.total_lines_added`, `total_lines_removed` | `+N` green, `−N` red. Hidden when both are zero |
| Limits | `rate_limits.five_hour`, `seven_day`, `spend_limit` | Coloured by the worst of the figures. A pace arrow follows the 5-hour figure, before its countdown: `→` while the current rate lands inside the window, `↑` when it overruns, red through the `removed` inline role once the projection reaches 120%. The elapsed fraction comes from `resets_at` and the fixed five-hour window, so there is no arrow without a reset time, after one, inside the first tenth of a window, or before anything has been used. The arrow never reaches the short form. The spend figure is `$ 62%`, a literal dollar sign, shown only when the payload carries `spend_limit`, which Claude Code sends behind a Claude apps gateway with a spend limit (2.1.251 or later); its reset time is not shown |
| Badges | `fast_mode`, `thinking.enabled`, `effort.level`, `vim.mode` | Dim glyphs |
| PR | `pr.number`, `pr.url`, `pr.review_state` (`pr.kind` is read but not shown) | Pull-request glyph and `#N`, the whole text wrapped in an OSC 8 hyperlink to `pr.url`. Green on `approved`, red on `changes requested` (underscores and case ignored), dim for anything else. Omitted without a `pr` object or a whole, positive `number`; a `url` that is not `http(s)` leaves the text unlinked. No short form |
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
  stamps match (the directory itself, nine named files, every directory under `refs` up to 256 of
  them, because git renames `x.lock` into place and that moves the parent's stamp) and the entry is younger than
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
  no output, and each key falls back on its own: a valid `order` beside a broken `thresholds` keeps
  the order.
- **One segment table, and the config moves what it can.** `Get-SegmentRegistry` is the single list of
  segments: its array order is the default `order`, its row keys the default `rows`, its ranks the
  shrink and drop order, and the build loop dispatches through it. The `order` and `rows` keys pick
  and place segments from that table by name; a segment on no line is not built, so leaving `branch`
  out also skips the git probe. `thresholds` reaches both callers of `Get-ThresholdRole` through the
  config, but not the fixed 70 and 90 of a 1M window, which belong to the window size. `icons` maps a
  name to a code point, and the `$icon*` constants are assigned from `Get-IconSet` after the config
  is read and before the payload is parsed, so the fallback line and every builder see one set of
  glyphs. The fitting order stays in the table: it is a property of what each segment can shed, not
  of taste.
- **One branch record, two readers.** The porcelain parser and the payload reader return the same
  eight keys (branch, dirty, ahead, behind, staged, modified, untracked, conflicts), so the segment
  builder reads one shape whichever source filled it, and a test pins the two key sets against each
  other.
- **One rule for payload numbers.** A single helper decides whether a `git.status` value is a count
  (a whole number that fits an Int32). The dirty flag and the counts both use it, so a value can
  never mark the tree dirty without showing a count, or the reverse. The PR number goes through the
  same helper.
- **Links live in the segment text.** `Format-Link` wraps text in an OSC 8 hyperlink and the PR
  builder puts the result in its record's `Text`, so the renderer needs no link support: the colour
  codes of either style wrap the link, and OSC 8 carries no SGR state, so a powerline background runs
  through it. The width rule strips OSC 8 (either terminator) before the colour codes, so a URL never
  counts as text and never changes what fits. The helper owns its own type gate: anything that is not
  a string, is over 2083 characters, holds whitespace or a control character, or does not parse as an
  absolute `http(s)` URI is not linked, so a payload cannot end the sequence early.
- **Per-session state on disk, never on the line's critical path.** A render cannot see the previous
  payload, so a small JSON file per `session_id` carries the last cost and token totals forward. The
  read, the merge and the write all sit after the last `Write-Host`, so none of their cost is in front
  of the visible line; measured end to end, a render with a `session_id` reaches its first line within
  a millisecond or two of one without. Every failure (no temp folder, a read-only directory, a corrupt
  file) is silent and leaves the line unchanged. The record is written to a `.tmp` file and moved over
  the real one, so an interrupted write costs nothing. The file holds numbers and one id, nothing from
  the prompt or the file system. Cleanup is a stamped sweep, so the common render is one read and one
  write.
- **The silence is switchable.** Every failure in the git probe, the probe cache and the state file is
  swallowed on purpose, which leaves a bug report with nothing in it. `Write-StatusDiag` appends one
  line - UTC time, process id, reason - per swallowed catch, per cache branch and per state read and
  write to `claude-statusline-diag.log` in the temp folder, and only while `CLAUDE_STATUSLINE_DEBUG`
  is set to something other than `0`, `false`, `no` or `off`. Unset, the helper reads one
  environment variable and returns, so the render pays nothing for it. The log is written the way the
  catch behaves: it never reaches the pipeline, a failure to write it is swallowed in turn, and the
  rendered line is identical with the variable set and unset. The log rolls over into a `.log.1`
  sibling once an append would take it past 4 MB, from inside that same `try`, so a variable left set
  in a profile cannot fill the temp volume and a rollover that fails costs the line and nothing more.
  One record is cut at 1000 characters, so no single reason can outgrow the cap by itself. The move is
  taken under a named mutex with a zero wait, and the size is read again while it is held, so two
  renders cannot rotate over each other's archive; one that cannot take the mutex at once skips the
  rollover and appends. Nothing waits, and the append itself is unlocked, which makes the cap
  approximate rather than exact: overlapping renders can leave the file a little over it or lose a
  line. That is the right trade for a log that must never delay a render and is off by default.

## Constraints

- Each render costs roughly 250 ms of pwsh start-up. Acceptable for event-driven refresh, but the
  script should stay lightweight and avoid module imports.
- Payload `git.status` counts arrive as Int64 from `ConvertFrom-Json`, and the field may also be a
  string (`"clean"`, `"modified"`) or an object of booleans. The parser of `git status` output runs
  once per entry, so it has to stay an index loop over chars: a large unignored tree has thousands
  of entries, and a pipeline there cost about nine times as much.

## Success criteria

- `.\test.ps1` passes: the unit checks, every payload in `samples/` across seven configs and four widths (120, 60, 20 and unset) with content checks at the unset width, the git cases with the probe cache, the state file cases, the diagnostics log cases, and the install cases.
- `.\install.ps1` on a fresh machine produces a working status line in Claude Code after one session restart.
- `.\install.ps1 -Uninstall` returns `settings.json` to its prior state minus the `statusLine` key.
- `.\install.ps1` leaves an existing `~/.claude/statusline.json` untouched.

## Status

Two-line layout, powerline style, config file, width fitting and the git fallback are implemented.
The branch segment shows ahead and behind counts (#16) and staged, changed, untracked and conflict
counts (#17), all from the one `git status` call, and that call is cached per repository with its
timeout and lifetime in the config (#18). The model segment marks a 1M window (#9), the limits
segment shows the spend limit (#7) and paces the 5-hour figure against its window (#6), and the
folder segment shows `owner/name` (#10). The
pull-request segment (#12) links `#N` to the PR with OSC 8. Segment order, the two rows, the colour
thresholds and the glyphs are `statusline.json` keys over the segment registry (#20). The installer
writes `hideVimModeIndicator` and, on request, `refreshInterval` (#26). A state file per session
(#4) is written but nothing on the line reads it yet. Every silent catch can be traced through an
optional log behind `CLAUDE_STATUSLINE_DEBUG` (#43). A light palette is still a constant in the
script.

## Future work

Issues #2 to #43 hold the backlog, each with a plan and success criteria. The enablers are done:
the segment registry and config keys (#20), the state file (#4), the link helper (#12) and the git
cache (#18). The intended order for the rest:

1. New segments: cache warmth and hit ratio, worktree name, links on the folder and branch, agent
   and session badges, cost per turn, pace, session clock (#2, #3, #5, #6, #8, #11, #13, #14). #5
   and #6 read the state file; #13 reuses `Format-Link`.
2. Config: presets, a quiet block, an alarm colour, per-project config (#19, #21 to #23).
3. Style and terminal: an ASCII style, a light palette, a right-aligned group with a clock, taskbar
   progress, a subagent status line (#15, #24, #25, #27, #28).
4. Small fixes from review: the zero-segment fallback line should respect the model toggle and the
   configured order (#42).

## License

MIT
