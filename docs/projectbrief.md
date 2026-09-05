# Project Brief: claude-code-statusline-ps

## Purpose

A PowerShell status line for Claude Code on Windows. It replaces the default status line with one
or two lines showing the active model, context-window usage, session cost, lines changed, rate
limits, session badges, the branch's pull request as a clickable link, current folder, and the git
branch with its worktree name and its ahead, behind and file-change counts, rendered with Nerd Font
glyphs and ANSI colour.

## Problem

Claude Code's status line is configured as a shell command that receives a JSON payload on stdin.
Most community status lines are bash scripts that assume a Unix environment. Windows users running
PowerShell 7 need something that works natively, installs into the user-level settings without
clobbering other keys, and renders glyphs correctly regardless of file encoding.

## Goals

- Work out of the box on Windows 11 with PowerShell 7 and Windows Terminal.
- Zero dependencies beyond PowerShell 7 and a Nerd Font.
- Degrade gracefully: omit any segment whose data is missing from the payload, and never print nothing
  the config did not ask for — a config with no model segment on it is allowed to render no line.
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
| `statusline.ps1` | Reads JSON on stdin, then `statusline.json` beside it and the project's own copy over that; prints one or two coloured lines fitted to `COLUMNS`. |
| `subagent-statusline.ps1` | The per-subagent line for the agent panel, wired up by `install.ps1 -Subagents`. A different contract from the main script: Claude Code runs it once for the whole panel with every live row in one payload (`columns` and a `tasks` array) and reads one JSON object per line back, `{"id","content"}`, keyed by the task id. One line per row: the robot glyph, the agent's name, its context percentage and token count, clipped to `columns`. A `columns` of 0 means no room and prints no row; a missing or malformed one means no information about the width and prints in full. No config file, no git probe, no powerline style, no state file. Its second line is a marker the installer looks for, as a whole line inside the first ten, before it overwrites or deletes an installed copy. Twelve small helpers are copied verbatim from `statusline.ps1`, because that script reads stdin and prints as it loads and so cannot be dot-sourced; `test.ps1` fails when the copies drift. |
| `tools/capture-stdin.ps1` | Appends stdin to a file and prints nothing on stdout. Point a settings key at it to find out what Claude Code sends at an integration point whose payload is not documented. Bounded in three places against a capture left running: stdin is read to a ceiling, the record is cut to `-MaxBytes` (1 MiB by default) with a truncation marker, and the file is rotated over one `.1` sibling when the existing length plus this record would exceed the cap, so each generation stays at or under it. The append is taken under a `.lock` sibling; a tick that cannot get it drops its payload. A write it cannot make is reported once to stderr and to a `.error` sidecar, after which it stops until the sidecar is deleted. |
| `install.ps1` | Copies the script to `~/.claude/`, writes the `statusLine` entry to user settings with `hideVimModeIndicator` on and, with `-RefreshInterval <seconds>`, a `refreshInterval`; with `-Subagents`, also copies `subagent-statusline.ps1` there and writes a `subagentStatusLine` entry of `type` and `command` only; optionally installs JetBrainsMono Nerd Font via winget and sets it as the Windows Terminal default font. Both commands carry a double-quoted forward-slash path, so a profile with a space or an `&` in it still runs. Settings are replaced atomically, the way `Write-AtomicJson` does it in `statusline.ps1`, under an exclusive lock on a `.lock` sibling held across the whole read-modify-write: serialize to a uniquely named sibling, compare the destination with what was read, parse the new text back, take the `.bak`, compare once more, then move. The lock serialises writers that take it and has no effect on one that does not; the second comparison narrows the loss window to the rename itself rather than removing it, and what a rename replaces is in the `.bak`. Ownership of the subagent artifacts is decided by strict match, not substring: the entry has to be the exact command form the installer writes with the target as the `-File` argument itself, and the file has to carry the marker as a whole line inside its first ten. `-Subagents` refuses to install over a file that fails that check, stages its copy under a temporary name so a settings failure changes nothing, and keeps the version it replaces as `~/.claude/.claude-code-statusline-ps.subagent-rollback.ps1` — a project-owned name rather than a `.bak` beside the script, and still marker-checked before it is overwritten or deleted. Supports `-Uninstall`, which removes the `statusLine` entry and script outright and the subagent entry and script only when they pass the ownership check, and `-SettingsPath` (the seam the tests use). |
| `statusline.json` | Defaults for layout, style, the folder mode, the state file toggle, the `links` toggle for the OSC 8 hyperlinks, segment toggles, the colour thresholds, the alarm percentages (`alarm.context`, `alarm.limits`), glyph overrides, and the git probe's timeout and cache (`git.timeoutMs`, `git.cacheSeconds`, `git.cache`). A `preset` key names one of three built-in shapes — `minimal`, `cost`, `full` — for the layout, the style and every segment toggle at once; it is expanded before the rest of the file it appears in, so any key beside it wins. The layout-one `order` and layout-two `rows` keys are left out so the registry stays the source and a new segment appears on its own, and the `quiet` thresholds are left out for the same reason: they default to zero, which hides nothing. Installed beside the script. |
| `<workspace.project_dir>\.claude\statusline.json` | The project's own copy of the same keys, merged over the user file key by key so a repository can pin its layout without changing any other session. Read only when the payload names a project directory that holds it, and not at all when `-Config` names a file. Read as untrusted input: opened first and judged by the handle, at most 64 KiB, within one 250 ms budget that starts before the first filesystem call. |
| `%TEMP%\claude-statusline-state\` | One JSON file per session (`<session_id>.json`, version 1): last cost, token totals, context and 5-hour percentages, and a ring of up to twenty cost readings. Read before the line is built, for the cost segment's per-turn delta, written after it is printed, swept of day-old files at most every six hours. The three counters (cost and the two token totals) are kept from the previous record when the payload does not carry them; the two percentages are read fresh and left absent, because a gauge carried forward describes a moment that has passed. `~/.claude/statusline-state` when `TEMP` is empty. |
| `%TEMP%\claude-statusline\` | The git probe cache: one JSON file per repository, named by the first 16 hex characters of the SHA-256 of the lower-cased work tree path, holding the root, a stamp string (the UTC ticks of the git directory, of `index`, `HEAD`, `ORIG_HEAD`, `FETCH_HEAD`, `MERGE_HEAD`, `packed-refs`, `logs/HEAD`, `config` and `info/exclude`, and of every directory under `refs`, capped at 256; a worktree's main repository after a bar), the write time and the last `git status` record, or null when the probe failed. Read before the branch segment is built and reused for `git.cacheSeconds` while the stamp string matches; swept of day-old files with the state sweep. `TMPDIR`, then the runtime's temp path, when `TEMP` is empty. |
| `test.ps1` | Unit-tests the script's pure functions, renders every sample across layout × style × width, checks the git fallback in temporary repositories: clean, dirty, unborn, detached, ahead, behind, a mixed tree, a git that fails and one that hangs, the probe cache with a counting stand-in and end to end with a failing git on `PATH`, exercises the session state file end to end, runs `install.ps1` against a settings file in a temp folder, and pipes every subagent payload through `subagent-statusline.ps1`, reading the replies the way the panel does and checking the copied helpers for drift. `-Columns`, `-Config`, `-Raw`. |
| `samples/*.json` | Every payload in `samples/` goes through the render matrix. One per case: clean main, dirty feature at high context, dirty main at mid context, minimal, no git, limits with badges, lines and a session clock at 1h12m with a 38% api share, expired limits with default effort, a repository identity below its project root, a 1M window with `exceeds_200k_tokens` true, a feature branch with an approved pull request, a session in a git worktree, a context window past the alarm percentage, a named session run by a custom agent with every mode off. |
| `samples/subagent/*.json` | Subagent panel payloads, in their own subdirectory so the render matrix, which globs `samples/` without `-Recurse`, never sees them. One per case: two running agents, a task with nothing but an id, an empty task list, hostile fields (an escape in a name, a blank and an array id, `20.0` and `2e1` token counts, a zero window, a label too long for the panel), and a 1M window with no `columns` key. |
| `docs/render-screenshot.ps1` | Renders a payload and config through the script and captures the terminal as the README screenshot. |
| `docs/render-icons.ps1` | Extracts the Nerd Font glyphs used by the script as SVG outlines for `docs/icons/`. |

## Segments

| Segment | Source field | Rendering |
|---|---|---|
| Model | `model.display_name`, `context_window.context_window_size`, `exceeds_200k_tokens`, and, for the alarm, `context_window.used_percentage` and `rate_limits.five_hour`, `seven_day` | Bold cyan, robot glyph. On a 1M window `1M` follows the name in a lighter cyan, then the warning triangle when Claude Code reports `exceeds_200k_tokens` as true. Red instead of cyan, text unchanged, once the context window or a rate limit reaches the `alarm` percentage (90 by default, `0` off). `Test-AlarmState` decides that from the payload and the config alone, and the role is picked before the text is built so the `1M` marker restores the right foreground |
| Context | `context_window.used_percentage`, `total_input_tokens`, `total_output_tokens`, `context_window_size`, `current_usage.{input_tokens, cache_creation_input_tokens, cache_read_input_tokens}` | Percent, ten-block bar, used/total in k or M, then the cached share as a dim `92% cached`. Green below 60%, yellow below 85%, red above. A 1M window uses 70% and 90%, so red still means about 100k tokens of room. The share is the cache read over the whole of `current_usage`, rounded by `Get-WholePercent` like every other percentage; a missing block, a missing field, a zero total or any negative count leaves it off. A negative count is refused rather than repaired, because a negative `input_tokens` beside a positive read divides out above 100 and would print as a confident `100% cached`; "we cannot tell" is the honest answer and the one a missing block already gets. With every count non-negative the share is in range by arithmetic, so there is no clamp - but only because the division happens before the scale: `100 * read` would overflow to infinity for a read above about 1.8e306 and print `2147483647% cached`, which is what an earlier version did while this table claimed it could not. It lives in `Text` and not in `Short`, so the fitting sheds it with the token counts |
| Cache | `prompt_cache.warm`, `expires_at`, `caching_observed`, `requests` | Fire glyph and how long the prompt cache has left: `cache 42m` green, `cache 4m` yellow inside the last five minutes, `cache <1m` under a minute. `cache cold` red when `warm` is the boolean false or the expiry has already passed — the timestamp is the specific claim and beats a `warm` that contradicts it. `cache off` red when `caching_observed` is the boolean false with at least three requests behind it, tested before the countdown because a cache the client says is not working still carries an expiry and that countdown would be the most reassuring thing on the line at the moment it is least true; it fires with `warm` absent as well as true, since gating it on a field that may not be there would restore the very countdown it suppresses. `cache warm`, no figure, when the cache is alive but the expiry is missing or refused. `Get-CacheSecondsLeft` is the refusal: `expires_at` is epoch seconds, divided by 1000 when it is past 1e12, and a value that is not a finite number, is zero or less, or is more than a day out is refused rather than clamped — the longest documented prompt cache lifetime is an hour, and clamping the 2100 epoch samples carry (which the rate-limit countdown beside it renders as `(26781d)`) would print a calm green `cache 24h00m` over a payload nobody can vouch for. Nothing usable in the block, and no block at all, are both no segment: that is what Claude Code before 2.1.251 sends and what the first turns of a session send. This is NOT `Get-CacheShare`: that reads `context_window.current_usage` for the hit ratio the meter prints as `92% cached`, and a turn can honestly be 92% cached off a cache with four minutes to live. **No `quiet` key, deliberately**: three of the four states are the warning, and quiet never hides a warning, so there is nothing here for a threshold to be a threshold on. Short drops the word and keeps the glyph and the value |
| Cost | `cost.total_cost_usd`, `cost_usd` from the session state file | Dimmed, two decimals, then the change since the previous render in parentheses: `$1.07 (+$0.12)`. The suffix is built only when the total rose by at least a cent, so no state, a first render, an unchanged total and one that went backwards all print the total alone. Precisely, the comparison is against the last total the file holds, so a render that ended before the write leaves the next delta spanning both turns — still a real difference between two totals, and that render printed no total to contradict. Both figures go through the same `'{0:N2}'`, so the delta follows the culture the total is written in. The short form is the total without the suffix, and it is the first detail the fitting sheds |
| Clock | `cost.total_duration_ms`, `cost.total_api_duration_ms` | Dimmed, never bold and never banded: `1h12m · api 38%`. `Format-Elapsed` gives the three forms — `<1m` under a minute, `12m` under an hour, `1h12m` above one with the minutes zero-padded — and the arithmetic goes through a `[TimeSpan]`, so the hours cannot overflow the format and a count of milliseconds too large to be a span is refused with everything else. The api share is `Get-WholePercent` over api ÷ total, the same rounding as every other percentage on the line; it does not take the `[math]::Floor` exception `subagent-statusline.ps1` has, because nothing bands on this figure and that exception exists to stop a colour running ahead of its number. Both fields are optional: no total is no segment, no api figure is the elapsed time alone with no dot. A figure that could not be true is refused rather than clamped — a total that is missing, zero, negative or past `[TimeSpan]::MaxValue` leaves the segment out, and an api time longer than the session has existed leaves the elapsed time alone rather than printing `api 100%`, the same rule that keeps a negative token count from rendering `100% cached`. The short form is the elapsed time without the share, and the two ranks say the rest: last in the shrink order, so the share is the last detail worth keeping, and second in the drop order behind lines, so the segment is the first number worth losing |
| Lines | `cost.total_lines_added`, `total_lines_removed` | `+N` green, `−N` red. Hidden when both are zero |
| Limits | `rate_limits.five_hour`, `seven_day`, `spend_limit` | Coloured by the worst of the figures. A pace arrow follows the 5-hour figure, before its countdown: `→` while the current rate lands inside the window, `↑` when it overruns, red through the `removed` inline role once the projection reaches 120%. The elapsed fraction comes from `resets_at` and the fixed five-hour window, so there is no arrow without a reset time, after one, inside the first tenth of a window, or before anything has been used. The arrow never reaches the short form. The spend figure is `$ 62%`, a literal dollar sign, shown only when the payload carries `spend_limit`, which Claude Code sends behind a Claude apps gateway with a spend limit (2.1.251 or later); its reset time is not shown |
| Badges | `fast_mode`, `thinking.enabled`, `effort.level`, `vim.mode`, `agent.name`, `session_name` | Dim glyphs, in that order: the four modes, which come and go as the session runs, then the two identities, which do not. `agent.name` is the custom agent driving the main thread and `session_name` the name the user gave the session; both pass the payload-text guard the branch name passes, which refuses a control character and strips the Unicode Format characters, and both are then cut to 20 cells by `Get-ClippedText`, the clipping rule the agent panel already uses, which measures with `Get-VisibleWidth` so a name in wide characters is cut where it draws. The short form is the mode badges alone, so a narrow line sheds the two identities before the segment goes. Hidden when none of the six is present; a session that is named or agent-driven shows the segment with every mode off. `session_id` is deliberately not rendered |
| PR | `pr.number`, `pr.url`, `pr.review_state` (`pr.kind` is read but not shown) | Pull-request glyph and `#N`, the whole text wrapped in an OSC 8 hyperlink to `pr.url`. Green on `approved`, red on `changes requested` (underscores and case ignored), dim for anything else. Omitted without a `pr` object or a whole, positive `number`; a `url` that is not `http(s)` leaves the text unlinked, and so does `"links": false`, the one key in front of all three links. No short form |
| Folder | `workspace.repo.owner`, `workspace.repo.name`, `workspace.project_dir`, `workspace.current_dir` | Blue. `owner/name` when the payload carries a repository, followed by `›` and the leaf of `current_dir` when it differs from `project_dir`. The leaf alone without a repository or with `"folder": "leaf"` in the config. Short form is the repository name. Both forms are wrapped whole in an OSC 8 hyperlink to `current_dir` as a `file:` URL, built by `Get-FolderUrl`: `[System.Uri]::TryCreate` with `AbsoluteUri` does the escaping, and a path that is not an absolute URI, one that parses as something other than a file, and a UNC path each give no URL and leave the text as it was |
| Branch | `git status --porcelain=v1 --branch` in `workspace.current_dir`. The Claude Code payload has no `git` object, so this is the normal path; a payload that does carry `git.branch` and `git.status` (the test samples) is used as is. The worktree badge is payload-only: `worktree.name`, `worktree.path`, `workspace.git_worktree` | Home glyph on main/master, branch glyph otherwise. Yellow with pencil glyph when dirty, magenta when clean. A session in a git worktree gets the fork glyph and the worktree name straight after the branch name: `worktree.name` when it is usable text, otherwise the leaf of `worktree.path` when `workspace.git_worktree` is exactly `true`, otherwise the glyph on its own; no worktree at all means no badge, and neither field changes the colour. Both fields pass the payload-text guard the branch name and the repo owner pass, which refuses a control character and strips the Unicode Format characters, so a name that is nothing but overrides is not a name and falls through the chain. Between the badge and the pencil, dim counts in a fixed order: `↑N` `↓N` ahead of and behind the upstream (header bracket, git path only), `+N` staged, `~N` changed in the work tree, `?N` untracked entries, then a red triangle with the conflict count. Zero counts are left out. The short form used at a narrow width is icon, name and pencil, so the badge sheds with the counts. Both strings are then wrapped whole in an OSC 8 hyperlink from `Get-BranchUrl`, so the badge, the counts and their inline colour codes keep the places they were built in: `github.com` gets `https://github.com/<owner>/<name>/tree/<branch>`, every other host the repository home, and `workspace.repo.host`, `owner` and `name` each pass the payload-text guard, with the host held to a hostname shape and the other three percent-escaped before they are pasted in. A detached HEAD, a payload with no `repo`, and `"links": false` each leave both strings unlinked |

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
- **Width is counted per grapheme, and over-counting is the safe direction.** `Get-VisibleWidth` walks
  text elements rather than characters and is a small wcwidth approximation, not a full one. Most
  graphemes are classified by their first code point against a list of wide ranges, but two are not
  described by their first code point at all: a flag is a pair of regional indicators and a keycap is
  an ordinary digit, `#` or `*` carrying U+20E3, and both draw two columns. They are classified
  explicitly, because the failure is one-sided — a string measured wider than it draws is only
  shortened early, while one measured narrower passes a width cap it does not fit and then overruns
  the line. `test.ps1` holds a table of grapheme to expected cells, written from what a terminal
  reserves, and checks both the script's rule and its own separate copy against it.
- **Silent config.** Any missing or invalid value in `statusline.json` falls back with no output, and
  each key falls back on its own: a valid `order` beside a broken `thresholds` keeps the order. The
  files are merged in precedence order, defaults then user then project, so what a key falls back to
  is the value beneath it: a project file with a bad `layout` keeps the user's, not the default.
- **The project file is untrusted input.** It comes with the repository, so `Read-BoundedFileText` opens
  it first and judges the handle: not seekable means a device or a pipe rather than a file, and the
  64 KiB cap is measured against the length the handle reports and again against the bytes read, so a
  name that changes under the check cannot widen either. A reparse point is refused too, by asking the
  name a second time, because the APIs that name a handle's own target are .NET 6 and the floor here is
  .NET Core 3.1. One stopwatch, started before the first filesystem call, covers every step: the open,
  the length (a call of its own — over SMB it is a round trip to the server), that probe, each read and
  the close. Each runs on the thread pool through a delegate closed over the path or the stream (a
  script block cannot: converted to a delegate it needs a runspace, and a pool thread has none) and is
  waited on for what is left of 250 ms. The close is queued and never waited on, and with the budget
  gone the stream is abandoned unclosed, whichever step spent it. The bound is on this read alone: a
  thread can stay blocked until the process exits, and the user's own file, read the ordinary way for
  its encoding detection, has no deadline at all. `Read-CodePoint` admits a
  code point only when it draws as one glyph
  standing alone: no control, format, separator, mark, surrogate, noncharacter or unassigned value, and
  one or two cells wide by the script's own width rule, so a repository cannot reorder, hide or
  mis-measure the line through the `icons` table. The user's own file keeps its ordinary read.
- **One segment table, and the config moves what it can.** `Get-SegmentRegistry` is the single list of
  segments: its array order is the default `order`, its row keys the default `rows`, its ranks the
  shrink and drop order, and the build loop dispatches through it. The `order` and `rows` keys pick
  and place segments from that table by name; a segment on no line is not built, so leaving `branch`
  out also skips the git probe. `thresholds` reaches both callers of `Get-ThresholdRole` through the
  config, but not the fixed 70 and 90 of a 1M window, which belong to the window size. `alarm` is a
  step away from both: `Test-AlarmState` reads the payload and the config directly rather than any
  segment record, so the model segment can carry the warning whether or not the context and limits
  segments are enabled, and it compares the same figure whatever the window size. What all three
  compare is one number: `Get-WholePercent` turns a payload figure into the percentage that is printed,
  banded and alarmed on, rounding half to even, so a meter reading 90% cannot sit beside a model that
  thinks the window is at 89. The subagent panel is the deliberate exception - it derives a percentage
  from token counts and floors it, so a partly used window never reads as a full one. Deriving a
  figure from token counts is not itself what earns that exception: the context segment's cached
  share is derived the same way and still rounds, because nothing bands or alarms on it and it
  prints beside the meter's own rounded percentage, where two rules on one segment is exactly the
  disagreement `Get-WholePercent` exists to rule out. `quiet` is the
  same idea one step earlier: a threshold per segment below which the builder returns `$null` and the
  segment is never built, so a four-cent cost or a 3% meter costs nothing on the line. It extends the
  rule the lines and badges segments already follow, that a segment with nothing to say disappears, from
  zero to a number the user picks. One guard, `Test-QuietValue`, reads the threshold defensively, so a
  config with no `Quiet` table hides nothing; the comparison is strict, which is what makes the default
  of `0` mean off. What it compares differs by segment: `cost` reads the raw dollar figure, while
  `context` and `limits` read the same whole percentage `Get-WholePercent` gives the text and the
  bands, so a cutoff and the number printed beside it can never disagree. **Quiet never hides a
  segment that is carrying a warning, an error or an alarm**, which is the rule that makes the setting
  safe to turn on: a hide-the-boring-numbers key that also hid the alarm would be worse than no key at
  all. So each builder settles its warning state before it asks the guard — context and limits keep a
  segment whose role is `warn` or `bad`, and limits also keeps one whose pace arrow projects an
  overrun, since a low current percentage early in a five-hour window is precisely the reading that
  projects red. `Get-PaceArrow` names that state `Over` rather than leaving it to be read off the
  glyph. The third state is the alarm of #23, and the most serious of them: `Test-AlarmLevel` is asked
  the same question the model segment asks, on the raw payload figure for context and on the larger
  window figure for limits, because `alarm` may be set below `thresholds.warn` and the role would then
  still read `ok` while the model turned red — a red bar with no number under it explaining it. Cost
  has no warning state to preserve, its role being always `dim`, and no alarm is read against a dollar
  figure, so there the threshold stands alone. What `quiet.limits` compares is the larger of the
  5-hour and 7-day figures, deliberately not the `$worst`
  that also carries the spend limit and drives the colour: the key is a threshold on how much of an
  allowance is gone, and a spend limit is not one of those. With neither window present there is
  nothing to compare and the segment is kept. `icons` maps a
  name to a code point, and the `$icon*` constants are assigned from `Get-IconSet` after the config
  is read and before the first line is printed, so both fallback lines and every builder see one set
  of glyphs. The fitting order stays in the table: it is a property of what each segment can shed,
  not of taste.
- **Two fallback lines, one rule.** Both print the model glyph and the word `claude`, which makes
  each of them the model segment with no name to put in it — a payload carrying no
  `model.display_name` is the case the second was written for. So neither goes out unless the config
  would have allowed a model segment: toggled on, and named by `order` or by one of the rows. The
  rule is decided once, above both lines, so they cannot answer the same config differently. A
  payload that is not JSON is no exception to it: it loses only the *project* overlay, because it
  names no project directory, while the user file — or the file `-Config` named — was read and
  merged over the defaults well before either line prints, and the glyph overrides from that same
  merge are already being used on it. A config file that cannot be parsed at all leaves the built-in
  defaults, which have model on and listed, so the case of saying something when nothing else can be
  said is carried by the defaults rather than by printing over a user who asked for no model
  segment. A config that turns model off, or whose order leaves it out, gets no line at all — the
  same answer the fitting loop already gives when every line shrinks away to nothing.
- **A display choice is not a persistence choice.** The zero-segment path does not exit. A payload
  that parsed carries its session id and its cost, token and rate figures whatever the config chose
  to put on screen, and the state file is where the next render reads them back from, so an empty
  render still writes and merges state and still runs the sweep. Falling through costs nothing on
  screen: `Get-FittedLine` returns `$null` for an empty line, so the print loop prints nothing. The
  one path that does exit early is the malformed payload, which has no session id and no figures to
  keep.
- **One branch record, two readers.** The porcelain parser and the payload reader return the same
  eight keys (branch, dirty, ahead, behind, staged, modified, untracked, conflicts), so the segment
  builder reads one shape whichever source filled it, and a test pins the two key sets against each
  other.
- **One rule for payload numbers.** A single helper decides whether a `git.status` value is a count
  (a whole number that fits an Int32). The dirty flag and the counts both use it, so a value can
  never mark the tree dirty without showing a count, or the reverse. The PR number goes through the
  same helper.
- **Links live in the segment text.** `Format-Link` wraps text in an OSC 8 hyperlink and the PR,
  folder and branch builders put the result in their record's `Text` and `Short`, so the renderer
  needs no link support: the colour codes of either style wrap the link, and OSC 8 carries no SGR
  state, so a powerline background runs through it. The width rule strips OSC 8 (either terminator)
  before the colour codes, so a URL never counts as text and never changes what fits — the folder and
  branch segments shrink and drop at exactly the widths they always did. Each builder wraps its
  finished string whole, the glyph, the worktree badge and the dim counts included, so nothing inside
  is reordered and the inline colour codes keep their places.
  The helper owns its own type gate: anything that is not a string, is over 2083 characters, holds
  whitespace or a control character, or does not parse as an absolute URI in one of three schemes is
  not linked, so a payload cannot end the sequence early. The schemes are `http` and `https` for the
  pull request and the branch page, and `file` for the folder, which is how a terminal is told to open
  a directory; `file` carries one rule the others do not need, an empty authority, because
  `file://server/share` is a UNC path and a click on one would reach out over SMB to a machine the
  payload named.
- **One key in front of every link.** `links`, default true, is read by all three builders through
  `Test-LinkWanted`, and only the boolean `false` turns them off. It is one key rather than three
  because the reason to turn links off is never about a segment: it is a terminal that prints the
  escape as text instead of rendering or swallowing it, and that terminal is broken for all three at
  once. Both URLs are built from payload text — a directory the session is in, a remote whoever made
  the checkout wrote — so both builders guard their fields and hand the result to `Format-Link` rather
  than around it, and either builder returning `$null` renders the segment byte for byte as it was
  before links existed.
- **Per-session state on disk, one read and one write.** A render cannot see the previous payload, so a
  small JSON file per `session_id` carries the last cost and token totals forward. The cost segment's
  per-turn delta is the difference from the total in that file, so the read sits before the build and
  the merge and the write stay after the last `Write-Host`: the record read for the delta is the one
  merged over, so a render is still one read and one write, and only the read is in front of the line.
  A payload that carries no cost or token totals keeps the ones the record holds rather than replacing
  them with nothing - they count up over a session, and the delta is measured from them - while the two
  percentages are read fresh, because a gauge carried across a compaction or a window reset describes a
  moment that has passed. A counter is also required to be possible and not merely finite: dollars and
  tokens only count up, so `Get-CountedNumber` refuses a negative one field by field, on the way in and
  on the way out, and the delta refuses both ends of its subtraction the same way. A hand-edited record
  holding `-100` would otherwise render a confident `(+$101.07)` beside a real total. The refusal is not
  a clamp to zero on purpose: a clamp would answer with a delta measured from nothing, which is the most
  reassuring reading available and the least true. The percentages keep the plain rule, because a rate
  limit really can report over 100 and the pace arrow already refuses anything at or below zero. Every failure (no temp folder, a read-only directory, a corrupt file) is
  silent and leaves the line unchanged. The record is written to a `.tmp` file and moved over
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

- `.\test.ps1` passes: the unit checks, every payload in `samples/` across seven configs and four widths (120, 60, 20 and unset) with content checks at the unset width, the git cases with the probe cache, the state file cases, the diagnostics log cases, the install cases, and the subagent cases.
- `.\install.ps1` on a fresh machine produces a working status line in Claude Code after one session restart.
- `.\install.ps1 -Uninstall` returns `settings.json` to its prior state minus the `statusLine` key, and minus `subagentStatusLine` when that key is this project's. A settings write is never observed truncated, and never silently overwrites a change made since the file was read.
- `.\install.ps1` leaves an existing `~/.claude/statusline.json` untouched.

## Status

Two-line layout, powerline style, config file, width fitting and the git fallback are implemented.
The branch segment shows ahead and behind counts (#16) and staged, changed, untracked and conflict
counts (#17), all from the one `git status` call, and that call is cached per repository with its
timeout and lifetime in the config (#18), and it shows the worktree name beside the branch when the
payload names one (#11). The model segment marks a 1M window (#9), the limits
segment shows the spend limit (#7) and paces the 5-hour figure against its window (#6), and the
folder segment shows `owner/name` (#10). A cache segment shows whether the prompt cache is still
warm and how long it has left (#2), which is a different figure from the hit ratio the context
segment prints (#3) and comes from a different block of the payload. The
pull-request segment (#12) links `#N` to the PR with OSC 8, and the folder and branch segments carry
the same kind of link under the one `links` key (#13): the folder to `current_dir` as a `file:` URL,
the branch to its page on the repository host. Segment order, the two rows, the colour
thresholds and the glyphs are `statusline.json` keys over the segment registry (#20), and `preset`
names three whole shapes of those keys (#21). The installer writes `hideVimModeIndicator` and, on
request, `refreshInterval` (#26), and `-Subagents` installs a
second script for the agent panel (#15). A state file per session (#4) carries the last cost forward,
and the cost segment reads it for its per-turn delta (#5). Every silent catch can be traced through an
optional log behind `CLAUDE_STATUSLINE_DEBUG` (#43). Both fallback lines are printed only where the
config allows a model segment, and a render that shows nothing still writes its state (#42). A light
palette is still a constant in the script.

## Future work

Issues #2 to #43 hold the backlog, each with a plan and success criteria. The enablers are done:
the segment registry and config keys (#20), the per-project config merge (#19), the state file (#4),
the link helper (#12) and the git cache (#18). A registry refactor that let the two scripts share
segment builders would remove the copied helpers in `subagent-statusline.ps1`; it is not worth it for
twelve short functions and a drift test. The intended order for the rest:

1. New segments: all done. Cache warmth (#2), the hit ratio (#3) and the session clock (#8) are in.
   The first two are deliberately separate: one reads `prompt_cache` for whether the cache is alive,
   the other `context_window.current_usage` for how much of a turn it served. Cost per turn (#5) is
   done and is the first reader of the state file, the agent and session badges (#14) are done, and
   the folder and branch links (#13) are done, reusing `Format-Link` around the finished text of each.
2. Config: presets, a quiet block, an alarm colour (#21 to #23). Each is one key over
   `Merge-StatusConfigFile`.
3. Style and terminal: an ASCII style, a light palette, a right-aligned group with a clock, taskbar
   progress (#24, #25, #27, #28).

## License

MIT
