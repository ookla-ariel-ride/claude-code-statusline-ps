# Project Brief: claude-code-statusline-ps

## Purpose

A PowerShell status line for Claude Code on Windows. It replaces the default status line with one
or two lines showing the active model, context-window usage and its cached share, prompt cache
warmth, session cost and its per-turn delta, a session clock, lines changed, rate limits with a pace
arrow, session badges, the branch's pull request as a clickable link, current folder, the git branch
with its worktree name and its ahead, behind and file-change counts, and optionally the wall clock,
rendered with Nerd Font glyphs and ANSI colour — or in plain ASCII, on a dark or a light palette. A
second script draws a matching row for each subagent in the agent panel.

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
| `statusline.ps1` | Reads JSON on stdin, then `statusline.json` beside it and the project's own copy over that; prints one or two coloured lines fitted to `COLUMNS`. `Read-StdinText` is the read: a `StreamReader` over the standard input handle with UTF-8 named explicitly, because `[Console]::In` decodes at the console's *input* code page and turned every payload field that was not English into mojibake (#80). A reader rather than an assignment to `[Console]::InputEncoding` because of the byte order mark, not the code page: .NET builds `Console.In` with `detectEncodingFromByteOrderMarks` off, so a mark would survive into the string and `ConvertFrom-Json` would refuse the payload. `UTF8Encoding($false)` has an empty preamble, which makes that flag the only thing stripping the mark. Stdin that is not redirected keeps the old `[Console]::In` path, because a console hands its bytes over at its own input code page. |
| `subagent-statusline.ps1` | The per-subagent line for the agent panel, wired up by `install.ps1 -Subagents`. A different contract from the main script: Claude Code runs it once for the whole panel with every live row in one payload (`columns` and a `tasks` array) and reads one JSON object per line back, `{"id","content"}`, keyed by the task id. One line per row: the robot glyph, the agent's name, its context percentage and token count, clipped to `columns`. A `columns` of 0 means no room and prints no row; a missing or malformed one means no information about the width and prints in full. No config file, no git probe, no state file. It takes `-Style` and `-Palette` instead (#78), the same two enums `statusline.json` holds, folded to lower case and falling back to the default for anything else rather than through a `ValidateSet` that would take the whole panel down on a hand-edited command line; `install.ps1` bakes the pair the status line will use into the `subagentStatusLine` command. `ascii` changes the two characters the script picks - the robot glyph becomes `Get-IconAscii`'s `@` and the clip tail a full stop - and `powerline` draws what `plain` draws, because the panel has no separators to shape. Its second line is a marker the installer looks for, as a whole line inside the first ten, before it overwrites or deletes an installed copy. Fifteen small helpers are copied verbatim from `statusline.ps1`, `Get-MarkSet` among them for its `Ellipsis`, `Read-StdinText` among them so the panel decodes its payload the same way the status line does, because that script reads stdin and prints as it loads and so cannot be dot-sourced; `test.ps1` fails when the copies drift. |
| `tools/capture-stdin.ps1` | Appends stdin to a file and prints nothing on stdout. Point a settings key at it to find out what Claude Code sends at an integration point whose payload is not documented. Stdin is decoded as UTF-8 explicitly, the same read path the two status line scripts use and for the same reason: a capture taken through `[Console]::In` wrote a file of mojibake for exactly the session someone reaches for this stub to look at. Bounded in three places against a capture left running: stdin is read to a ceiling, the record is cut to `-MaxBytes` (1 MiB by default) with a truncation marker, and the file is rotated over one `.1` sibling when the existing length plus this record would exceed the cap, so each generation stays at or under it. The append is taken under a `.lock` sibling; a tick that cannot get it drops its payload. A write it cannot make is reported once to stderr and to a `.error` sidecar, after which it stops until the sidecar is deleted. |
| `install.ps1` | Copies the script to `~/.claude/`, writes the `statusLine` entry to user settings with `hideVimModeIndicator` on and, with `-RefreshInterval <seconds>`, a `refreshInterval`; with `-Subagents`, also copies `subagent-statusline.ps1` there and writes a `subagentStatusLine` entry of `type` and `command` only, the command carrying `-Style` and `-Palette`; the pair is decided once from one table (`Get-SubagentArgumentSpec`, whose rows the composer, the ownership check, the config write and every printed line all iterate), written into `statusline.json` in one batched read-modify-write BEFORE the settings entry, and the command is then composed from what that file holds, so a config write that is skipped or throws leaves the command following the file rather than promising what the file does not say; an entry `Test-OwnSubagentEntry` recognises is refreshed by any run that changes the pair, with or without `-Subagents`, which only creates one; the installer reads `statusline.json` under the same 64 KiB cap `Read-BoundedFileText` applies, so a config too big for the render path is too big for the panel and both fall back to the defaults together; optionally installs JetBrainsMono Nerd Font via winget and sets it as the Windows Terminal default font. Both commands carry a double-quoted forward-slash path, so a profile with a space or an `&` in it still runs. Settings are replaced atomically, the way `Write-AtomicJson` does it in `statusline.ps1`, under an exclusive lock on a `.lock` sibling held across the whole read-modify-write: serialize to a uniquely named sibling, compare the destination with what was read, parse the new text back, back up, compare once more, then move. The lock serialises writers that take it and has no effect on one that does not; the second comparison narrows the loss window to the rename itself rather than removing it, and what a rename replaces is in that backup, when there was one to take. The backup is not `settings.json.bak`: `Get-JsonBackupPath` names a project-owned sibling instead (`settings.json.claude-code-statusline-ps-rollback`), and `Backup-OwnedFile`/`Test-OwnBackupFile` verify it before overwrite the same way the subagent rollback file is marker-checked — but JSON has no comment syntax for a marker line, so the proof is a `.sha256` sidecar recording the hash of the backup this installer last wrote; a mismatch or a missing sidecar means the file is not this installer's to certify and it is left alone with a warning naming the reason, instead of replaced or falsely reported as saved. An orphan sidecar (present with no backup beside it) is not the same case: nothing else ever writes that name, so a leftover one does not block the next write. `Backup-OwnedFile` itself writes to a temporary sibling, hashes it, then renames it into place before writing the sidecar, all inside one try/catch, so a failure partway - including a sidecar write that fails right after the backup itself was replaced - reconciles the sidecar to the backup's actual content rather than certifying a write that did not happen; the content backed up is `$settingsBaseline[$Path]`, the text this process already read, taken immediately before the final move rather than from a fresh read between the two unchanged-checks, which could otherwise capture and certify a lock-ignoring writer's content moments before the second check refuses the write over it. The settings write itself still completes even when its own backup could not be taken. `-ConfigureWindowsTerminal` backs up Windows Terminal's `settings.json` the same way, in place of the old `settings.json.bak-before-nerdfont`, but there the font change is refused outright rather than merely warned about when that backup fails - a font with no way back is not offered silently - and the edit itself goes through the same temporary-sibling-and-rename shape rather than a plain `Set-Content`. `-Uninstall`'s own settings write leaves its own backup and sidecar too, and the run names both and says they are kept. An older install's `settings.json.bak` or `settings.json.bak-before-nerdfont` is read, written and deleted by no code path here; it is simply left where it is. The subagent rollback copy below keeps a stricter, deliberately different policy from the JSON backup - a failed copy there aborts the whole install rather than warning and continuing - because it sits directly in front of the one file the same run is about to overwrite, where a JSON settings write has other keys at stake that a failed few-KB backup should not hold hostage; both comments say so rather than one comment claiming they make the same trade. Ownership of the subagent artifacts is decided by strict match, not substring: the entry has to be the exact command form the installer writes with the target as the `-File` argument itself and, after it, only the panel arguments `Get-SubagentArgumentSpec` names, each at most once with a value that table allows, and the file has to carry the marker as a whole line inside its first ten. That one table is read by the composer and by the check, so the command written and the command recognised cannot drift; `test.ps1` compares it with `Get-StatusConfigKey`, so neither can drift from what the status line and the panel accept. `-Subagents` refuses to install over a file that fails that check, stages its copy under a temporary name so a settings failure changes nothing, and keeps the version it replaces as `~/.claude/.claude-code-statusline-ps.subagent-rollback.ps1` — a project-owned name rather than a `.bak` beside the script, and still marker-checked before it is overwritten or deleted. Supports `-Uninstall`, which removes the `statusLine` entry and script outright and the subagent entry and script only when they pass the ownership check, and `-SettingsPath` (the seam the tests use). |
| `statusline.json` | Defaults for layout, style, the `palette` colour table, the folder mode, the state file toggle, the `links` toggle for the OSC 8 hyperlinks, the taskbar progress toggle, segment toggles, the colour thresholds, the alarm percentages (`alarm.context`, `alarm.limits`), glyph overrides, and the git probe's timeout and cache (`git.timeoutMs`, `git.cacheSeconds`, `git.cache`). A `preset` key names one of three built-in shapes — `minimal`, `cost`, `full` — for the layout, the style and every segment toggle at once; it is expanded before the rest of the file it appears in, so any key beside it wins. The layout-one `order` and layout-two `rows` keys are left out so the registry stays the source and a new segment appears on its own, and the `quiet` thresholds are left out for the same reason: they default to zero, which hides nothing. Installed beside the script. |
| `<workspace.project_dir>\.claude\statusline.json` | The project's own copy of the same keys, merged over the user file key by key so a repository can pin its layout without changing any other session. Read only when the payload names a project directory that holds it, and not at all when `-Config` names a file. Read as untrusted input: opened first and judged by the handle, at most 64 KiB, within one 250 ms budget that starts before the first filesystem call. |
| `%TEMP%\claude-statusline-state\` | One JSON file per session (`<session_id>.json`, version 1): last cost, token totals, context and 5-hour percentages, and a ring of up to twenty cost readings. Read before the line is built, for the cost segment's per-turn delta, written after it is printed, swept of day-old files at most every six hours. The three counters (cost and the two token totals) are kept from the previous record when the payload does not carry them; the two percentages are read fresh and left absent, because a gauge carried forward describes a moment that has passed. `~/.claude/statusline-state` when `TEMP` is empty. |
| `%TEMP%\claude-statusline\` | The git probe cache: one JSON file per repository, named by the first 16 hex characters of the SHA-256 of the lower-cased work tree path, holding the root, a stamp string (the UTC ticks of the git directory, of `index`, `HEAD`, `ORIG_HEAD`, `FETCH_HEAD`, `MERGE_HEAD`, `packed-refs`, `logs/HEAD`, `config` and `info/exclude`, and of every directory under `refs`, capped at 256; a worktree's main repository after a bar), the write time and the last `git status` record, or null when the probe failed. Read before the branch segment is built and reused for `git.cacheSeconds` while the stamp string matches; swept of day-old files with the state sweep. `TMPDIR`, then the runtime's temp path, when `TEMP` is empty. |
| `test.ps1` | Unit-tests the script's pure functions, renders every sample across layout × style × width and once more in the `ascii` style, where the line is checked against its own marker table and for holding no character outside ASCII that the payload did not supply, checks the git fallback in temporary repositories: clean, dirty, unborn, detached, ahead, behind, a mixed tree, a git that fails and one that hangs, the probe cache with a counting stand-in and end to end with a failing git on `PATH`, exercises the session state file end to end, runs `install.ps1` against a settings file in a temp folder, and pipes every subagent payload through `subagent-statusline.ps1` once per `-Style` × `-Palette` pairing, reading the replies the way the panel does, pinning the two characters the style decides and the SGR codes the palette decides, checking that an unusable argument value falls back rather than throwing, and checking the copied helpers for drift. `-Columns`, `-Config`, `-Raw`. |
| `samples/*.json` | Every payload in `samples/` goes through the render matrix. One per case: clean main, dirty feature at high context, dirty main at mid context, minimal, no git, limits with badges, lines and a session clock at 1h12m with a 38% api share, expired limits with default effort, a repository identity below its project root, a 1M window with `exceeds_200k_tokens` true, a feature branch with an approved pull request, a session in a git worktree, a context window past the alarm percentage, a named session run by a custom agent with every mode off, a warm prompt cache with a far-future expiry, and a branch name and directory that are not English (two CJK ideographs and a Latin letter with an accent), which is what holds the UTF-8 read path through the whole matrix rather than through one dedicated check. |
| `samples/subagent/*.json` | Subagent panel payloads, in their own subdirectory so the render matrix, which globs `samples/` without `-Recurse`, never sees them. One per case: two running agents, a task with nothing but an id, an empty task list, hostile fields (an escape in a name, a blank and an array id, `20.0` and `2e1` token counts, a zero window, a label too long for the panel), and a 1M window with no `columns` key. |
| `docs/render-screenshot.ps1` | Renders a payload and config through the script and captures the terminal as the README screenshot. |
| `docs/render-icons.ps1` | Extracts the Nerd Font glyphs used by the script as SVG outlines for `docs/icons/`. |

## Segments

| Segment | Source field | Rendering |
|---|---|---|
| Model | `model.display_name`, `context_window.context_window_size`, `exceeds_200k_tokens`, and, for the alarm, `context_window.used_percentage` and `rate_limits.five_hour`, `seven_day` | Bold cyan, robot glyph. `display_name` goes through the same payload-text guard as the branch and repository names, but unlike every other guarded field it never omits the segment for a bad one: a number, a boolean, a blank string, or no `model.display_name` at all (no `model` object, or one with no `display_name` key) prints the literal word `claude` instead, because this is the one segment `Get-FittedLine` never drops and the alarm rides on it — a payload field is not allowed to be the reason a real alarm goes unseen. On a 1M window `1M` follows the name in a brighter cyan, then the warning triangle when Claude Code reports `exceeds_200k_tokens` as true. Red instead of cyan, text unchanged, once the context window or a rate limit reaches the `alarm` percentage (90 by default, `0` off). `Test-AlarmState` decides that from the payload and the config alone, and the role is picked before the text is built so the `1M` marker restores the right foreground |
| Context | `context_window.used_percentage`, `total_input_tokens`, `total_output_tokens`, `context_window_size`, `current_usage.{input_tokens, cache_creation_input_tokens, cache_read_input_tokens}` | Percent, ten-block bar, used/total in k or M, then the cached share as a quieter `92% cached`. Green below 60%, yellow below 85%, red above. A 1M window uses 70% and 90%, so red still means about 100k tokens of room. The share is the cache read over the whole of `current_usage`, rounded by `Get-WholePercent` like every other percentage; a missing block, a missing field, a zero total or any negative count leaves it off. A negative count is refused rather than repaired, because a negative `input_tokens` beside a positive read divides out above 100 and would print as a confident `100% cached`; "we cannot tell" is the honest answer and the one a missing block already gets. With every count non-negative the share is in range by arithmetic, so there is no clamp - but only because the division happens before the scale: `100 * read` would overflow to infinity for a read above about 1.8e306 and print `2147483647% cached`, which is what an earlier version did while this table claimed it could not. It lives in `Text` and not in `Short`, so the fitting sheds it with the token counts |
| Cache | `prompt_cache.warm`, `expires_at`, `caching_observed`, `requests` | Fire glyph and how long the prompt cache has left: `cache 42m` green, `cache 4m` yellow inside the last five minutes, `cache <1m` under a minute. `cache cold` red when `warm` is the boolean false or the expiry has already passed — the timestamp is the specific claim and beats a `warm` that contradicts it. `cache off` red when `caching_observed` is the boolean false with at least three requests behind it, tested before the countdown because a cache the client says is not working still carries an expiry and that countdown would be the most reassuring thing on the line at the moment it is least true; it fires with `warm` absent as well as true, since gating it on a field that may not be there would restore the very countdown it suppresses. `cache warm`, no figure, when the cache is alive but the expiry is missing or refused. `Get-CacheSecondsLeft` is the refusal: `expires_at` is epoch seconds, divided by 1000 when it is past 1e12, and a value that is not a finite number, is zero or less, or is more than a day out is refused rather than clamped — the longest documented prompt cache lifetime is an hour, and clamping the 2100 epoch the samples carry would print a calm green `cache 24h00m` over a payload nobody can vouch for. The rate-limit countdown beside it (`TimeLeft`) used to render that same 2100 epoch as `(26781d)`; it is now capped at a year out and renders nothing for a reset that far away either, on the same reasoning — a number nobody can vouch for is worse than no number. Nothing usable in the block, and no block at all, are both no segment: that is what Claude Code before 2.1.251 sends and what the first turns of a session send. This is NOT `Get-CacheShare`: that reads `context_window.current_usage` for the hit ratio the meter prints as `92% cached`, and a turn can honestly be 92% cached off a cache with four minutes to live. **No `quiet` key, deliberately**: three of the four states are the warning, and quiet never hides a warning, so there is nothing here for a threshold to be a threshold on. Short drops the word and keeps the glyph and the value |
| Cost | `cost.total_cost_usd`, `cost_usd` from the session state file | Dimmed, two decimals, then the change since the previous render in parentheses: `$1.07 (+$0.12)`. The suffix is built only when the total rose by at least a cent, so no state, a first render, an unchanged total and one that went backwards all print the total alone. Precisely, the comparison is against the last total the file holds, so a render that ended before the write leaves the next delta spanning both turns — still a real difference between two totals, and that render printed no total to contradict. Both figures go through the same `'{0:N2}'`, so the delta follows the culture the total is written in. The short form is the total without the suffix, and it is the first detail the fitting sheds |
| Clock | `cost.total_duration_ms`, `cost.total_api_duration_ms` | Dimmed, never bold and never banded: `1h12m · api 38%`. `Format-Elapsed` gives the three forms — `<1m` under a minute, `12m` under an hour, `1h12m` above one with the minutes zero-padded — and the arithmetic goes through a `[TimeSpan]`, so the hours cannot overflow the format and a count of milliseconds too large to be a span is refused with everything else. The api share is `Get-WholePercent` over api ÷ total, the same rounding as every other percentage on the line; it does not take the `[math]::Floor` exception `subagent-statusline.ps1` has, because nothing bands on this figure and that exception exists to stop a colour running ahead of its number. Both fields are optional: no total is no segment, no api figure is the elapsed time alone with no dot. A figure that could not be true is refused rather than clamped — a total that is missing, zero, negative or past `[TimeSpan]::MaxValue` leaves the segment out, and an api time longer than the session has existed leaves the elapsed time alone rather than printing `api 100%`, the same rule that keeps a negative token count from rendering `100% cached`. The short form is the elapsed time without the share, and the two ranks say the rest: last in the shrink order, so the share is the last detail worth keeping, and third in the drop order behind the wall clock and lines, so the segment is the first figure about the session worth losing |
| Time | none — `Get-StatusClock`, the render's one reading of the wall clock | The wall clock, `14:05`: the local time of day, 24 hour, dim and never banded. It reads no payload field because Claude Code sends no timestamp, which makes it the one segment whose value moves without a new payload and the reason the README says to set `statusLine.refreshInterval` beside it — without one the script runs on Claude Code's events and an idle session shows the time of the last one. The colon is escaped in the format string (`'HH\:mm'`): a bare `:` is the culture's time separator, and under fi-FI that is a dot. **This is not the Clock segment.** That one is how long the session has run and what share of it went on the API; this one is what time it is, and a session that has run 1h12m says nothing about whether it is now 09:14 or 23:47. Two segments, two numbers, two glyphs — a stopwatch and a wall clock. It is the only registry record whose `Default` is false, because turning a clock on for every existing install would be a behaviour change carried by a default. No short form, since there is nothing in five characters to shed; `DropRank` 1 instead, ahead of lines, because it is the one figure on the line that says nothing about the session |
| Lines | `cost.total_lines_added`, `total_lines_removed` | `+N` green, `−N` in the `removed` colour — a true red inside the light `warn` block, a warm apricot inside a dark one. Hidden when both are zero |
| Limits | `rate_limits.five_hour`, `seven_day`, `spend_limit` | Coloured by the worst of the figures. Each figure's `used_percentage` goes through `Get-FiniteNumber`, so a string, a boolean or an array is not a percentage: that one figure drops off the line rather than corrupting it (a boolean used to coerce to `1%`/`0%`) or, before this guard existed, throwing and taking the whole segment with it; a payload with nothing usable drops the whole segment, same as before. `resets_at` goes through `TimeLeft`, which is guarded the same way and additionally caps the rendered countdown at a year — a reset further out than that, or one that is not a usable date at all (a numerically absurd value that used to throw straight out of `DateTimeOffset::FromUnixTimeSeconds`), renders nothing rather than a five-digit day count or a crash. A pace arrow follows the 5-hour figure, before its countdown: `→` while the current rate lands inside the window, `↑` when it overruns, coloured through the `removed` inline role once the projection reaches 120%. The elapsed fraction comes from `resets_at` and the fixed five-hour window, so there is no arrow without a reset time, after one, inside the first tenth of a window, or before anything has been used. The arrow never reaches the short form. The spend figure is `$ 62%`, a literal dollar sign, shown only when the payload carries `spend_limit`, which Claude Code sends behind a Claude apps gateway with a spend limit (2.1.251 or later); its reset time is not shown |
| Badges | `fast_mode`, `thinking.enabled`, `effort.level`, `vim.mode`, `agent.name`, `session_name` | Dim glyphs, in that order: the four modes, which come and go as the session runs, then the two identities, which do not. Four of the six fields are payload text and pass the same guard the branch name passes, which refuses a control character and strips the Unicode Format characters: `agent.name` and `session_name` (also cut to 20 cells by `Get-ClippedText`, the clipping rule the agent panel already uses, which measures with `Get-VisibleWidth` so a name in wide characters is cut where it draws), and `effort.level` and `vim.mode` (added later, not cut - a mode word is never that long). `effort.level` is hidden at `high`, compared `OrdinalIgnoreCase` so a culture cannot bend the comparison and case does not turn it into a second word. `fast_mode` and `thinking.enabled` are not text at all - they are read with a strict boolean type check, the same one `exceeds_200k_tokens` uses, so PowerShell's own `-eq $true` would have read the string `"true"` or the number `1` as the mode too, and neither is what Claude Code actually sends. The short form is the mode badges alone, so a narrow line sheds the two identities before the segment goes. Hidden when none of the six is present; a session that is named or agent-driven shows the segment with every mode off. `session_id` is deliberately not rendered |
| PR | `pr.number`, `pr.url`, `pr.review_state` (`pr.kind` is read but not shown) | Pull-request glyph and `#N`, the whole text wrapped in an OSC 8 hyperlink to `pr.url`. Green on `approved`, red on `changes requested` (underscores and case ignored), dim for anything else. Omitted without a `pr` object or a whole, positive `number`; a `url` that is not `http(s)` leaves the text unlinked, and so does `"links": false`, the one key in front of all three links. No short form |
| Folder | `workspace.repo.owner`, `workspace.repo.name`, `workspace.project_dir`, `workspace.current_dir` | Blue. `owner/name` when the payload carries a repository, followed by `›` and the leaf of `current_dir` when it differs from `project_dir`. The leaf alone without a repository or with `"folder": "leaf"` in the config. Short form is the repository name. Both forms are wrapped whole in an OSC 8 hyperlink to `current_dir` as a `file:` URL, built by `Get-FolderUrl`: `[System.Uri]::TryCreate` with `AbsoluteUri` does the escaping, and a path that is not an absolute URI, one that parses as something other than a file, and a UNC path each give no URL and leave the text as it was |
| Branch | `git status --porcelain=v1 --branch` in `workspace.current_dir`. The Claude Code payload has no `git` object, so this is the normal path; a payload that does carry `git.branch` and `git.status` (the test samples) is used as is. The worktree badge is payload-only: `worktree.name`, `worktree.path`, `workspace.git_worktree` | Home glyph on main/master, branch glyph otherwise. Yellow with pencil glyph when dirty, magenta when clean. A session in a git worktree gets the fork glyph and the worktree name straight after the branch name: `worktree.name` when it is usable text, otherwise the leaf of `worktree.path` when `workspace.git_worktree` is exactly `true`, otherwise the glyph on its own; no worktree at all means no badge, and neither field changes the colour. Both fields pass the payload-text guard the branch name and the repo owner pass, which refuses a control character and strips the Unicode Format characters, so a name that is nothing but overrides is not a name and falls through the chain. Between the badge and the pencil, counts in the quiet `track` colour in a fixed order: `↑N` `↓N` ahead of and behind the upstream (header bracket, git path only), `+N` staged, `~N` changed in the work tree, `?N` untracked entries, then the conflict triangle in the `removed` colour with its count. Zero counts are left out. The short form used at a narrow width is icon, name and pencil, so the badge sheds with the counts. Both strings are then wrapped whole in an OSC 8 hyperlink from `Get-BranchUrl`, so the badge, the counts and their inline colour codes keep the places they were built in: `github.com` gets `https://github.com/<owner>/<name>/tree/<branch>`, every other host the repository home, and `workspace.repo.host`, `owner` and `name` each pass the payload-text guard, with the host held to a hostname shape and the other three percent-escaped before they are pasted in. A detached HEAD, a payload with no `repo`, and `"links": false` each leave both strings unlinked |

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
  colour role, bold); one function renders a line in plain, powerline or ascii style, and width fitting
  shrinks then drops records in a fixed order.
- **Style and palette are two axes, not one list.** `style` is the SHAPE a line is drawn in — a
  chevron between coloured words, solid blocks with arrows, or the same shape in printable ASCII — and
  `palette` is the COLOUR NUMBERS those shapes use, which depend only on whether the terminal's
  background is dark or light. `Get-Palette` takes the palette name and returns the whole table,
  `Format-Line`, `Format-Inline` and `Get-FittedLine` each carry it, and all six pairings are drawn;
  `ascii` with `light` is the ASCII characters in the light numbers, and neither feature needs a case
  for the other, because an SGR code is digits and semicolons. Both parameters default to `dark`, so
  every caller and every config written before the key existed renders the same bytes. The light
  table's values are picked against contrast ratios rather than by eye — a plain foreground at 4.5:1
  on white and on off-white, a block's own pair at 4.5:1, a block's background at 1.7:1 against the
  terminal's ground so the trailing arrow and the block edges survive, and an inline marker at 3:1
  inside any block — and `test.ps1` recomputes every one of them from the xterm cube. A bar can only
  be applied to a colour the table can name a hex for, which is why the dark table's plain codes were
  outside all of it: the basic sixteen are the terminal scheme's to define. The two dark plain markers
  are 256-colour indices now and measured against Campbell and Solarized Dark; the dark plain *role*
  colours are still the sixteen, because changing those is a redesign of the default line rather than
  a repair.
- **A role can be two shades, and which one a segment takes is a property of the line.** Seven
  distinct role colours are still one colour where the layout puts two segments of the same role side
  by side, which the shipped second row does twice over — context, cache and limits are all `ok`, and
  cost, clock and lines are all `dim`. Neither half can see it: the contrast rules measure pairs of
  roles and do not know the order, and the layout does not know the colours. So `ok`, `warn`, `bad`
  and `dim` carry a second background and a second plain code, `Format-Line` gives it to a block whose
  neighbour on the line has the same role, and a run of three alternates rather than drifting. The
  decision is made from the records `Format-Line` is handed, because a line can be missing the cache
  block, the lines block or the pull request, so which segments end up adjacent is not a property of
  the registry. The shade moves the background and never the block's text: a segment's markers were
  chosen when its text was built and already hand that text's own colour back, so a second foreground
  would have to be threaded into finished text. Where no colour clears every floor — dark `dim`'s
  block, light `ok`'s plain code — the pair keeps one shade and the powerline joint is drawn as a
  divider in the block's own ink instead of an arrow of one colour on itself. Both absences are
  searched over the whole 256-colour cube in `test.ps1` rather than asserted in a comment.
- **The right group is a layout, and a layout is the first thing a narrow line gives up.** `right`
  names segments that leave the packed line and sit flush against the right edge of the FIRST line;
  everything else stays where it was. `Get-FittedLine` splits the records in two, renders each group
  with the one `Format-Line`, and joins them with `target - leftWidth - rightWidth` spaces, so the
  result is exactly the target width. **The padding is counted in cells and never in characters.** A
  line carries an SGR code in front of every segment and can carry six OSC 8 hyperlink wrappers — the
  folder and branch segments each emit one in `Text` and another in `Short`, and the pr segment emits
  one — and none of that draws a cell; a subtraction from `.Length` would be short by over a hundred
  characters on a linked line and the "aligned" line would not reach the edge. `Get-VisibleWidth` is
  the measurement the fitting stages already use, so the padding and the fitting cannot disagree.
  Fitting gains one stage between the two that were there: shrink both groups, then empty the right
  group last-name-first, then drop from the left group in the drop order. **The right group goes whole
  and goes early, before any packed segment**, because a segment pushed to the edge is decoration and
  the alternative is a line that keeps a clock and loses a rate limit; a dropped right member is gone
  rather than moved back inline, since re-inlining it would make the line wider, which is the opposite
  of what the stage is for. That ordering is also what answers the case where the two groups cannot
  both fit however much is shed: the right group is empty before the last stage starts, so the whole
  thing degrades into exactly the one-group fitting that was there before, model overflow included.
  With `COLUMNS` unset there is no target, so there is no right group either and every segment renders
  inline — the early return that was already at the top of the function.
- **An empty `right` is kept, unlike an empty `order` or `rows`.** Those two fall back because a line
  naming no segment is not a layout and there is nothing a file could have meant by it. An empty right
  group is the built-in default and a real thing to ask for, and keeping it is the only way a project
  file can take back a group the user file asked for.
- **One style key, not a style and an icon set.** `ascii` (#27) is the whole no-Nerd-Font answer rather
  than an axis crossed with the other two: the separator glyph and the icon table have the same single
  cause, the font, so one word settles both and the incoherent pairing — powerline's block separators
  on a terminal that cannot draw them — cannot be asked for. What it promises is that every character
  **the script chooses** is printable ASCII, U+0020 to U+007E, not merely "no private use area": that
  range is both the one every font has and the one every terminal draws a single cell wide, and the
  width half matters because `Get-VisibleWidth` counts a meter block, an arrow or a middle dot as one
  column while some terminals draw them as two. So `Get-IconAscii` answers for the glyphs and
  `Get-MarkSet` for the characters that are not glyphs, and the `icons` overrides — code points, every
  one — are ignored in this style, so the promise holds whatever a user or a repository's own config
  asks for. Colours are the plain palette, role for role, in whichever table `palette` names — the
  style picks characters and never colours, so `ascii` with `light` needs no case of its own in
  either. Each of the twenty-four stand-ins follows one
  rule in three clauses: nothing at all where what follows already names the segment (the model name,
  `$1.07`, `1h12m`, `14:05`, `+156 -23`, `5h 24%`, an effort level, a vim mode); otherwise the mark
  ASCII already uses for the thing (`~` home, `*` a dirty tree, `^` and `v` ahead and behind, `!` a
  conflict, `/` a step down a path, `@` a person, `#` a tag); otherwise the shortest lower-case
  abbreviation (`ctx`, `dir`, `pr`, `wt`, `fast`, `think`), cut to one letter where the segment's own
  text carries the word (`b` branch, `c` cache).
- **The ascii style does not touch payload text, and the promise is scoped to say so.** A branch, a
  folder, a repo owner, a model, agent or session name reaches the line as the payload supplied it in
  every style, so an ascii line can hold characters outside ASCII and be exactly right. The style is
  about the glyphs the script picked, which live in the private use area and need a font the terminal
  may not have; a name in Japanese needs a Japanese font, which most terminals do have, and it is the
  user's own data. Transliterating it would be lossy and silent, and it would make this style worse
  than no style for the people most likely to be on a terminal they cannot configure — boxes say "this
  font is missing", `????` says nothing and cannot be read back. `test.ps1` pins the scoped rule rather
  than the broad one: every non-ASCII character on the line has to have come from the payload, and one
  render with a non-English name in every text field pins that set exactly.
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
- **Both config files are read under one budget, and trust is a separate axis from it.** `Read-BoundedFileText`
  reads the user's own `statusline.json` and the project's, each under 64 KiB and 250 ms — per file, so
  two unreachable files cost two budgets, which is what the README states and what a test pins. The
  budget is about a filesystem that does not answer, which is no respecter of whose file it is: a home
  directory on a dead share hangs a render the way a project directory on one does, which is what #48
  closed. A miss draws the built-in defaults for that render; nothing caches the last config that
  worked, so the visible cost is one flickered line rather than a stalled one. Trust decides one thing
  on top of the budget, the reparse-point probe, and `-Trusted` skips that for the user's file so a
  config symlinked out of a dotfiles repository still loads, as it did when `Get-Content` read it.
  Reading bytes rather than `Get-Content` means the encoding has to be decided here, and it is decided
  by the same class `Get-Content` decides it with — a `StreamReader` over a `MemoryStream` on the buffer
  already read, with `detectEncodingFromByteOrderMarks`, which makes no call and copies nothing. A rule
  restated by hand would be a rule that can drift; using the reference implementation cannot. This is
  why the user's file could not simply be pointed at the reader in #19, and why the encoding work came
  first in #48. Either file falling back is the fall-back it always had: the values beneath it stand.
- **Two things about the user's file that `Get-Content` did for free, and now have to be done here.**
  `File.OpenRead` shares with readers only, so a config another program holds open for WRITING is
  refused with a sharing violation where `Get-Content`, which shares with writers, read it fine;
  `Open-SharedConfigFile` re-opens on this thread with `FileShare.ReadWrite` when — and only when — that
  is the failure, on the user's own file. It is not a pooled delegate because there is no cheap way to
  make one: `Delegate.CreateDelegate` binds one argument and the four-argument `File.Open` cannot be
  closed to the parameterless delegate a dispatch needs, and building one at run time with an expression
  tree was measured at 61 ms per process. What makes the unbounded re-open acceptable is which failure
  reaches it: a sharing violation is a completed round trip inside the budget, the same "test of the
  filesystem about to be called" the diagnostics rollover makes before its rename. And a relative path
  resolves against the SESSION's location under `Get-Content` but against the PROCESS's working
  directory under every call here, and `Set-Location` moves only the first — so `Resolve-ConfigPath`
  maps `-Config` once, at the edge, with `GetUnresolvedProviderPathFromPSPath`, which resolves without
  probing. It is unconditional rather than gated on `IsPathRooted`, because `C:statusline.json` is
  drive-relative and that test calls it rooted; a name that will not resolve is refused rather than
  handed to the open, which on Windows would have read an alternate data stream in the working
  directory.
- **The project file is untrusted input.** It comes with the repository, so `Read-BoundedFileText` opens
  it first and judges the handle: not seekable means a device or a pipe rather than a file, and the
  64 KiB cap is measured against the length the handle reports and again against the bytes read, so a
  name that changes under the check cannot widen either. A reparse point is refused too, by asking the
  name a second time, because the APIs that name a handle's own target are .NET 6 and the floor here is
  .NET Core 3.1. One stopwatch, started before the first filesystem call, covers every step: the open,
  the length (a call of its own — over SMB it is a round trip to the server), that probe, each read and
  the close. Each runs on the thread pool through a delegate closed over the path or the stream (a
  script block cannot: converted to a delegate it needs a runspace, and a pool thread has none) and is
  waited on for what is left of 250 ms. Each wait is `Task.WaitAny` rather than `Task.Wait`, because
  `Wait` rethrows a task that failed and a project with no config of its own takes that path on every
  render - the ordinary case was raising and catching an exception, which cost more than the pooled
  call it was waiting on. `WaitAny` returns instead, and the task is then asked whether it succeeded,
  so the deadline and the failure are told apart rather than both arriving as one caught exception,
  which is also what lets each refusal name itself in the diagnostics log. The close is queued and
  never waited on, and with the budget gone the stream is abandoned unclosed, whichever step spent it.
  **Abandonment is literal**, and anything adopting this pattern adopts that: nothing here can cancel a
  blocking filesystem call, so a pool thread can stay stuck in the kernel until the process exits, a
  completed abandoned open and close tasks are retained in a small pending list and swept by the next
  bounded read or cache write without waiting. A task that never answers remains bounded and is reclaimed
  at process exit.
  `Read-CodePoint` admits a code point only when it draws as one glyph
  standing alone: no control, format, separator, mark, surrogate, noncharacter or unassigned value, and
  one or two cells wide by the script's own width rule, so a repository cannot reorder, hide or
  mis-measure the line through the `icons` table.
- **Every other filesystem call a render can make is audited, in a comment beside `Read-BoundedFileText`.**
  #48 asked for a decision per call rather than a list, and the block records one. The diagnostics log
  bounds itself on its own 250 ms clock and is off unless `CLAUDE_STATUSLINE_DEBUG` is set.
  `git status` is a child process under `git.timeoutMs`, and that timeout covers the child and nothing
  the script does before starting it — which is where the audit corrected itself under review. The git
  cache entry and the session state file are read through `Read-BoundedFileText -Trusted`, because the
  reason for leaving them alone did not survive being checked against them: each was one `File.Exists`
  and one `ReadAllText` on the render's own thread, which is the config read's shape exactly, so each
  cost one bounded read rather than any new machinery. Left deliberately unbounded, and said by where
  they really are: `Get-GitBranch`'s `Test-Path` on the payload's directory; the cache's repository
  work, all of it before git runs and none of it under `TEMP` (`Get-GitRepoRoot` walking up from the
  payload's directory, `Get-GitStamp` stat-ing the git directory, enumerating `refs` and reading
  `.git/commondir`, a file the repository writes); and the writes. The session-state write is after the
  line prints, but the git-cache write is in `Get-BranchSegment` while segments are being built and is
  therefore before the print. It makes one immediate move and never waits for a pending reader close: a
  refusal drops that render's cache entry, so the next render re-probes git. That costs one failed move,
  not a render stall, and access failures are not retried. Those directories are also not chosen the same
  way, which is worth writing down:
  `Write-StatusDiag` and `Get-GitCacheDir` go `TEMP` → `TMPDIR` → `GetTempPath()`, while
  `Get-SessionStateDir` goes `TEMP` → `$HOME/.claude/statusline-state`, so on Unix, where `TEMP` is
  normally unset, the log and the cache land in `/tmp` and the state file lands under the home
  directory — the one of the three that can be a network mount. Recorded, not moved: moving it would
  strand every state file already written, and the read of it is bounded now. So a project directory on
  a filesystem that hangs can still hold a render up in the walk, before the git timeout applies to
  anything. What keeps THAT from a budget is cost — the walk and the stamps are many calls of several
  shapes — not a claim that they cannot hang.
  `subagent-statusline.ps1` opens no file at all.
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
- **Two fallback lines, one rule.** Both print the model glyph and the word `claude`. The first, for
  a payload that will not parse at all, is a genuine stand-in: the model builder never ran. The
  second, for every enabled and listed segment coming back empty, used to be the model segment's own
  stand-in too, for a payload naming no `model.display_name` — that case has since moved inside
  `Get-ModelSegment` itself, which now never returns `$null` and prints `claude` there directly, so
  the second line is reached only when the model segment could not be built at all: turned off, or
  left out of `order` or every row. Both still print the identical word for the identical reason —
  there being nothing else to say about the model — so neither goes out unless the config would have
  allowed a model segment: toggled on, and named by `order` or by one of the rows. The
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
  state, so a powerline background runs through it. The width rule strips any OSC string (either
  terminator) before the colour codes, so a URL never counts as text and never changes what fits — the folder and
  branch segments shrink and drop at exactly the widths they always did. Each builder wraps its
  finished string whole, the glyph, the worktree badge and the dim counts included, so nothing inside
  is reordered and the inline colour codes keep their places.
  One OSC rule and not one per command: a hyperlink wrapper and the taskbar sequence below are both
  "ESC ] anything terminator", which is exactly what a terminal that does not know the command
  swallows, so measuring them the same way is measuring what is drawn.
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
- **The taskbar bar is terminal state, so staying silent is not the neutral choice.** With
  `"taskbar": true` the script writes OSC 9;4 with the context percentage, which Windows Terminal
  draws on the window's taskbar button. What it writes outlives the process: whatever the last render
  set stays there until something sets it again. So a render that has no percentage — no
  `context_window` yet, a `used_percentage` still null before the first API response, a payload that
  would not parse — writes the clear form rather than nothing, and a render that ends with **no line
  at all** still writes its sequence. A bar frozen at a figure from a payload no longer on screen is
  worse than an honest bar over an empty line. A real 0% is state 1 and not state 0: a known zero and
  an unknown figure must not look the same. Which of state 1 and state 2 goes out is `Test-AlarmState`
  and nothing narrower, so the bar turns red at exactly the moment the model segment does. Turning the
  key off writes nothing at all, not even a clear — a default-off feature must not fight Claude Code's
  own progress bar on every render of every user who never asked for it — and the cost of that choice
  is that the last bar drawn stays until the window closes, which the README says out loud.
- **The one corner the taskbar does not repair, and why it is a documented limit rather than a fix.**
  A payload that will not parse names no project directory, so the project file is not read on that
  path. That rule predates this key and every project-only value has always been subject to it; for
  every other key it is invisible, because a colour or a toggle that did not reach a line is replaced
  on the next render. This key writes state that outlives the render, so `"taskbar": true` set **only**
  in a project file leaves the last good render's bar lit with no clear behind it. Closing it would
  need the script to know it had lit that terminal's bar before, and a malformed payload leaves nothing
  to key that on: no `project_dir`, no `session_id`, and no terminal identifier of any kind. The
  alternatives were both worse than the gap — reading a project config from somewhere the payload did
  not name widens an untrusted read on the path with the least information, and clearing
  unconditionally would have the default-off configuration write terminal state it was never asked to
  write and wipe Claude Code's own bar. So: enabled in the user file there is no gap, enabled in a
  project file the bar is stale until the next payload that parses, and both halves are pinned by
  tests. The fix, if it is ever wanted, belongs in how the malformed path finds the project config,
  not in this feature.
- **One write site, and it is not a line.** The sequence goes out through a single
  `Write-Host -NoNewline` above every path that prints and above the one that prints nothing. The
  bytes are identical to gluing it onto the front of the first line, so a layout-one render is still
  one line; a render with no line writes the sequence and no newline, so nothing moves on screen. The
  alternative, prefixing the first line printed, would have needed the same string threaded through
  three print sites — one of which does not exist on the empty render. It also has to stay outside the
  line rather than merely at the front of it: the folder, branch and pr segments carry OSC 8 hyperlink
  wrappers, folder and branch one each in `Text` and `Short`, so a line can hold six, and a progress
  sequence written between a wrapper and its closer would sit inside a hyperlink's text run. Writing it
  before any line exists is what rules that out.
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
- **The silence is switchable.** Every failure in the git probe, the probe cache, the project config
  read and the state file is swallowed on purpose, which leaves a bug report with nothing in it.
  `Write-StatusDiag` appends one line - UTC time, process id, reason - per swallowed catch, per cache
  branch, per refused config and per state read and
  write to `claude-statusline-diag.log` in the temp folder, and only while `CLAUDE_STATUSLINE_DEBUG`
  is set to something other than `0`, `false`, `no` or `off`. A refused config names which refusal it
  was - it could not be opened, the handle is not an ordinary file, a link or a reparse point, over the
  byte cap, the deadline spent and at which step, empty, or it would not parse - because "why is my
  project config being ignored?" is close to the exact question this log exists to answer, and a
  reason of "something failed" does not answer it.
  Unset, no call site does anything at all: `Test-StatusDiagFlag` reads the variable once into
  `$script:diagOn` and every call site tests that before it builds a reason or calls the helper. The
  gate inside `Write-StatusDiag` is cheap but reached too late to be free - PowerShell builds the
  argument first, so the reason was interpolated on every render whatever the flag said, and the call
  itself cost more than the interpolation did. `Write-StatusDiag` keeps its own gate as well, so the
  environment variable stays the one thing that decides and a call site that forgets the guard is a
  missed optimisation rather than a log that writes when it should not. `test.ps1` checks the guard is
  at every call site by walking the script's syntax tree, not just the ones a test happens to reach.
- **Writing the log is bounded, and it is not done under anyone else's clock.** The temp folder is a
  filesystem like any other and can be redirected onto a share that stalls, so a record's own
  filesystem calls - the size the rollover decision needs, the append open, and the close that actually
  writes - go to the thread pool and are waited on for what is left of one 250 ms clock, the same shape
  the project config read uses. A record that cannot be written inside it is dropped, which is the
  trade #43 already made when it took a zero wait on the rollover lock over a guaranteed rotation.
  That includes the rollover: it reads the size again with the lock held, because
  another render may have rolled the file already, and that second read goes to the pool under the same
  clock as the first. Reading it straight from a `FileInfo` there, as it once did, put an unbounded
  filesystem call back on the render's thread and made every other bound in the function moot.
  **The one call still on the calling thread is the rename**, and only that: `File.Move` takes two
  arguments and has no zero-argument form to close a delegate over, and compiling a worker to carry
  them would cost every render more than the case it guards. It is attempted only with `RolloverMs`
  (half the budget) still unspent, which is not a bound on it but a test of the filesystem about to be
  renamed on - reaching that point means both size reads answered, and answered briskly. Below the
  reserve the record is dropped, unrolled and unwritten. What that leaves, plainly: while a filesystem
  is slow enough to eat the reserve the log stops being written rather than growing, and it sits near
  its cap until a render with room to spare rolls it; it heals on its own once the filesystem does. That
  is the same answer a rollover that is entered and cannot take the lock now gets (#93), so the reserve
  is one more road to it rather than a hole beside it. Every cap drop, including this reserve drop, is
  counted by reason and carried until a record has handed its line to a writer whose close has not
  already failed; a still-running close does not make the next record repeat the accounting.
  `Read-BoundedFileText` writes no record at all: it records the
  reason and `Merge-StatusConfigFile` writes it once the read has returned and its clock has stopped,
  because a size probe, a rename, an open and a close inside that clock would be exactly the unbounded
  filesystem work the clock exists to keep out, and would delay the queued close behind them.
- **Nothing a repository writes can act on the log.** A reason can carry text this project did not
  write: `ConvertFrom-Json` quotes the property names it choked on, and in a project config those come
  from the repository. A log is read in a terminal, where an escape runs instead of being read - `ESC [
  2 J` clears the display and takes the evidence with it. So `Write-StatusDiag` writes every control,
  format and surrogate code point as `<U+XXXX>`, centrally and before the length cut, so no call site
  can be the one that forgets and notation cannot push a record past the bound. Notation rather than
  removal, which is the opposite of what `Format-PayloadText` does to payload text on its way to the
  line, and deliberately so: the line has to be safe to look at, the log has to be honest about what it
  found. Whitespace is folded first, so a tab or a newline is still a space rather than notation.
- The log is written the way the catch behaves: it never reaches the pipeline, a failure to write it
  is swallowed in turn, and the
  rendered line is identical with the variable set and unset. The log rolls over into a `.log.1`
  sibling once an append would take it past 4 MB, from inside that same `try`, so a variable left set
  in a profile cannot fill the temp volume and a rollover that fails costs the line and nothing more.
  One record is cut at 1000 characters, so no single reason can outgrow the cap by itself. The move is
  taken under an exclusive lock on a sibling `.lock` file with a zero wait, and the size is read again
  while it is held, so two renders cannot rotate over each other's archive; one that cannot take the
  lock at once skips the rollover and, with the log already full, drops its record rather than
  appending past the cap, carrying the count and the reason into the next record it does land (#93).
  The full list of cap-drop reasons is in [the diagnostics reference](diagnostics.md). Nothing waits. Appending through a held lock, as it did before #93, made the cap a target and not a
  ceiling: a holder can be a stalled render or one in another session or another user's account, and
  every render on the machine appended past the cap for as long as it lived. What is left of the
  approximation is the unlocked append: `FileInfo.AppendText` uses `FileShare.Read`, so overlapping
  appends can lose a line to each other when one open fails. A successful append can still leave the
  file a little over the cap because both renders measured room before either wrote. That is the right
  trade for a log that must never delay a render and is off by default. The note the drop leaves is bounded by the process
  that took it, which the review of #93 read as the fix's weak point and which is recorded here rather
  than engineered around: a render draws one line and exits, so the count usually dies with it, and a
  channel that outlived it would be a fourth file beside a two-file-and-a-lock log, written by a
  filesystem call on the path that is dropping records rather than waiting for one. The cross-process
  signal is the log itself - near its cap and no longer growing while a live process owns `.lock` - and
  `docs/diagnostics.md` tells the reader to read it that way; a `.log.1` can remain from an earlier
  rollover. Also unlike the mutex this replaced
  (#49): the lock is scoped by the path rather than a
  machine- or session-wide name, a killed render's handle is released by the kernel on process exit
  with no stale lock left behind, and a lock file some other user cannot open at all - not merely held,
  but permanently unopenable - is read as a structural failure that drops the record rather than as
  contention that would let the log grow past its cap forever.

## Constraints

- Each render costs roughly 250 ms of pwsh start-up. Acceptable for event-driven refresh, but the
  script should stay lightweight and avoid module imports.
- Payload `git.status` counts arrive as Int64 from `ConvertFrom-Json`, and the field may also be a
  string (`"clean"`, `"modified"`) or an object of booleans. The parser of `git status` output runs
  once per entry, so it has to stay an index loop over chars: a large unignored tree has thousands
  of entries, and a pipeline there cost about nine times as much.

## Success criteria

- `.\test.ps1` passes: the unit checks, every payload in `samples/` across seven configs and four widths (120, 60, 20 and unset) with content checks at the unset width, the git cases with the probe cache, the state file cases, the diagnostics log cases, the render cost cases, the install cases, and the subagent cases across every style and palette.
- Render cost is checked by counting filesystem operations, not by timing a render. A wall-clock
  ceiling is the obvious way and the wrong one here: the timing assertions in `test.ps1` bound hangs
  rather than cost, and a ceiling on a render fails under parallel load for reasons that have nothing
  to do with the code. A compiled double stands in for the two calls the bounded read dispatches and
  counts every open, attribute probe, length, read and close, so what a payload shape costs is pinned
  as a number that cannot flake. The close is bounded rather than pinned, because it is queued on the
  pool and never waited on.
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
config allows a model segment, and a render that shows nothing still writes its state (#42). A
`palette` key picks the dark colour table or a light one tuned for a pale background (#28), and
`install.ps1 -DetectTheme` reads Windows Terminal's default colour scheme to set it — or writes
nothing and says why, since terminals do not report their own background and a wrong guess costs more
than no guess. Both tables are now held to the same floors for an inline marker inside a powerline
block (#82): the dark table had never been measured and `cached` on the model block was 1.05:1. The fix
is structural rather than a retuned number, because a marker has to clear the block's background AND
stay apart from the block's own text, and on a dark block no single colour does both — anything bright
enough to be legible on the block is within 1.38:1 of the white the block writes in. So each marker
carries two colours, one for a block whose text is light and one for a block whose text is dark, and
the block's own ink picks between them. That put the true red back inside the light `warn` block, which
keeps its yellow. The block backgrounds are measured too, in ordered pairs: the powerline arrow is one
block's background painted on the next one's, so two blocks of equal luminance leave nothing at the
joint. A `right` key pushes any named segments against the right
edge of the first line, and a wall-clock segment gives that edge something to hold (#25); the clock is
the only registry record that is off by default. The agent panel takes `style` and `palette` as
arguments the installer bakes into its command (#78), since it reads no config file.

The rest of the backlog closed in one run on 2026-09-06. The payload is decoded as UTF-8 whatever the
console's input code page (#80). Every payload field the line draws goes through the shared text and
number guards, `Get-PayloadText` and `Get-PayloadPercent`, and the model segment never drops out (#61,
#45, #44). The dark palette's inline markers are measured against the same floors as the light table's
(#82). The two icons that shipped under the wrong code point are corrected (#55), and every bare
negative literal in the suite is parenthesised, with an AST check to keep it so (#62). The user's
`statusline.json`, the git cache entry and the state file are read through the bounded reader with
encoding detection (#48). The diagnostics rollover guard is a lock file beside the log rather than a
named mutex, which was session-scoped on Unix (#49), and a render that cannot take that lock drops its
record instead of appending past the cap, so a stalled holder can no longer grow the log without bound
(#93). The timing tests inject their clocks instead of
racing them (#63). The installer's backups live at project-owned names and are provenance-checked
(#52). The screenshots are regenerated from the shipped samples (#77). Three more test families decide
rather than wait: a child render's config budget can be raised through
`CLAUDE_STATUSLINE_CONFIG_TIMEOUT_MS`, and the diagnostics record budget is pinned for the checks about
where its bytes go (#99, #94). An open that completed after a bounded read had returned could leave its
FileStream open in a long-lived host. Later bounded operations now sweep completed opens and close them;
a git-cache write waits at most 50 ms for this process's pending close before its one replacement attempt,
because that write occurs before the line prints. The four clock-relative figures on a line — the cache
countdown, the rate-limit countdown, the pace arrow and the wall clock — come out of one reading, taken
once and replaceable through `CLAUDE_STATUSLINE_NOW`, so a screenshot regenerates to the same text (#98).
The reads that compare against file times, the git cache's TTL and the state sweep, stay on the real clock
on purpose.



### What has shipped, in order

- [x] Query git directly for branch and dirty state
- [x] Optional two-line layout and powerline style
- [x] Ahead and behind counts on the branch
- [x] Staged, changed, untracked and conflict counts on the branch
- [x] `1M` marker and past-200k warning on the model segment, wider colour bands for a 1M window
- [x] Spend limit beside the rate limits
- [x] `owner/name` in the folder segment
- [x] Installer switch for the refresh interval
- [x] Per-session state file, so a later render can see what changed
- [x] Pull-request segment with a clickable link
- [x] Segment order, rows, colour cut-offs and glyphs as `statusline.json` keys
- [x] Cached `git status` with a configurable timeout
- [x] Optional diagnostics log behind `CLAUDE_STATUSLINE_DEBUG`
- [x] One clock reading behind every clock-relative figure on the line, pinnable with `CLAUDE_STATUSLINE_NOW`
- [x] Pace arrow on the 5-hour rate limit
- [x] Per-project `statusline.json` merged over the user file
- [x] A subagent status line for the agent panel, installed with `-Subagents`
- [x] `-Style` and `-Palette` on the subagent panel, baked into the command by the installer
- [x] Named presets: `minimal`, `cost` and `full` under one `preset` key
- [x] Worktree name beside the branch
- [x] Cost per turn beside the session total, from the state file
- [x] Prompt cache warmth and the time left on it
- [x] Session clock with the share of it spent waiting on the API
- [x] Ctrl-clickable folder and branch, under a `links` key
- [x] Context percentage on the taskbar button, behind a `taskbar` key
- [x] An `ascii` style that needs no Nerd Font
- [x] A right-aligned group under a `right` key, and a wall-clock segment to put in it
- [x] A light palette under a `palette` key, and `-DetectTheme` to set it from Windows Terminal's scheme
- [x] The payload decoded as UTF-8 whatever the console code page, so non-English names render as sent
- [x] Both config files, the git cache and the state file read under one bounded, encoding-aware reader
- [x] Installer backups at project-owned names with their provenance checked before they are touched
- [x] Screenshots regenerated from the shipped samples, showing every segment
- [x] The dark plain markers on a measurable 256-colour index, and both tables' plain markers asserted
- [x] Second shades where their tables clear the floors, and dividers where they do not, so repeated roles stay distinct

## Future work

The feature backlog is done. #89 closed the six isoluminant light pairs: all seven light backgrounds
now clear the arrow's 1.10:1 and 40 sRGB floors, worst 1.101:1 (`bad`/`dim`) and 56.6 sRGB, while the
light table deliberately has no second backgrounds. What remains open are limits recorded under review,
none of them a feature: the dark palette's plain-style `dim` role is still SGR 90, the terminal's own bright black,
which measures 2.79:1 on Solarized Dark and colours the chevron and five segments (#111) — #88 moved
the two markers off it and left this deliberately, because a quiet grey near the markers' 246 would
reopen #82's distinctness rule; two more test families fail under parallel load rather
than on a defect (#94), the git-cache stamp tests do the same (#102), and a parallel suite run can trip
the 250 ms user-config clock and fail random matrix cells (#99). A registry refactor that let the two scripts share segment
builders would remove the copied helpers in `subagent-statusline.ps1`; it is not worth it for fifteen
short functions and a drift test. How the backlog was ordered, for the record:

1. New segments: all done. Cache warmth (#2), the hit ratio (#3) and the session clock (#8) are in.
   The first two are deliberately separate: one reads `prompt_cache` for whether the cache is alive,
   the other `context_window.current_usage` for how much of a turn it served. Cost per turn (#5) is
   done and is the first reader of the state file, the agent and session badges (#14) are done, and
   the folder and branch links (#13) are done, reusing `Format-Link` around the finished text of each.
2. Config: presets, a quiet block, an alarm colour (#21 to #23). Each is one key over
   `Merge-StatusConfigFile`.
3. Style and terminal: all done. The right-aligned group and its wall clock (#25) are
   done, and are the first thing on the line whose position is decided by the width rather than by
   the order. The ASCII style (#27) is done: a third `style` value, its own icon and mark tables, and
   the `icons` overrides refused under it so the line it promises is the line it draws. The light
   palette (#28) is done as a second axis rather than a fourth style, with `-DetectTheme` reading
   Windows Terminal's scheme at install time and declining to answer when the settings file cannot
   say. Taskbar progress (#24) is done and is the first writer of terminal state that outlives the
   render.
4. The agent panel (#78) is done. The decision it needed was where a panel learns a setting from —
   a config read on every tick, an environment variable, or an argument the installer bakes into the
   `subagentStatusLine` command — and the argument won: a style is about the terminal's font and a
   palette about its background, so neither moves with the session, and the panel keeps its promise of
   reading nothing on a tick. `Test-OwnSubagentEntry` was the reason it could not be bolted on, and it
   was widened rather than loosened: after `-File` and the path it now accepts only the arguments this
   installer writes, name and value checked against the same table the composer reads, so a wrapper, a
   chained command, an unknown switch and an unknown value all still say not ours, and an entry written
   before the arguments existed is still recognised.

## License

MIT
