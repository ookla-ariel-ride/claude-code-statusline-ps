# Session handoff

Written 2026-09-06 (seventh session). The whole feature backlog was implemented in five parallel
waves. Read this first when resuming work on this repo.

## Repo state

- Branch `main`, in sync with `origin/main`. Head `3609a26`. Only `main` exists locally and on the
  remote; every feature branch is merged and deleted.
- **Suite: `pwsh -NoProfile -File ./test.ps1` → passed 10115, failed 0.** Baseline at the start of
  the session was 4532. Roughly 12 minutes alone; far longer with parallel agents.
- Lint clean on all seven scripts with `PSScriptAnalyzerSettings.psd1`.
- Samples run 01..14. Twelve segments: model, context, cache, cost, clock, time, lines, limits,
  badges, pr, folder, branch. Twenty-four icons.
- **35 PRs merged this session.** 13 issues open, 11 of them filed by this session.
- `.claude/` holds leftover worktree directories that OneDrive locks; git no longer tracks any of
  them. Cosmetic.

## What shipped

All nineteen open feature issues, plus two filed mid-session from an audit.

| Wave | Issues |
|---|---|
| 1 | #43 diagnostics log, #6 pace arrow, #19 per-project config, #15 subagent script |
| 2 | #21 presets, #11 worktree name, #22 quiet block, #23 alarm colour |
| 3 | #3 cache ratio, #42 zero-segment fallback, #5 cost delta, #14 agent badges |
| 4 | #8 clock, #2 cache warmth, #13 OSC 8 links, #24 taskbar progress |
| 5 | #25 right-aligned group + wall clock, #27 ascii style, #28 light palette |
| audit | #64 diagnostics coverage, #65 render-cost claims |

Plus fix branches: `review-fixes` (five code-review findings and a harness bug), the cache-share
overflow, and the alarm/quiet guard.

## Architecture as it now stands

- **`Get-SegmentRegistry`** is the single table: `Name/Build/Default/ShrinkRank/DropRank/Row/RowRank`.
  Adding a segment is one row, an icon constant, an icon-assignment case, a config default, the
  presets and the test tables. **Ranks must be dense 1..N** — `Get-SegmentOrder` keys a hashtable by
  rank, so a duplicate does not misorder, it **silently deletes** a segment. A test asserts density
  per key; it was written after a merge collision silently dropped `context`.
- **`Read-StatusConfig` is four functions**: `Get-DefaultStatusConfig`, `Get-StatusConfigKey`,
  `Merge-StatusConfigFile`, `Read-StatusConfig`. A one-value key is one row in the key table; an
  object key is a guarded block in the merge function. Precedence is defaults → user file → project
  file, each invalid value falling back to the value beneath.
- **The project config is untrusted input** — it arrives from whatever repository you cd into.
  `Read-BoundedFileText` gives it 64 KiB and 250 ms, one clock covering lookup, open, length and
  every read, all dispatched to the thread pool via delegates closed over BCL members. Validation is
  handle-first (`CanSeek`, `Length` from the handle). Cleanup is queued, never waited on.
- **Two rendering scripts, twelve shared helpers, one drift gate** comparing them by AST extent.
  `subagent-statusline.ps1` cannot dot-source `statusline.ps1`, which executes its whole body on
  load — that is why the twelve are copies.
- **Three styles** (`plain`, `powerline`, `ascii`) and **two palettes** (`dark`, `light`) are
  separate axes. `ascii` is about fonts, `palette` about background colour; all six pair coherently.
- **`Get-WholePercent`** is the one percentage rule (round half to even) behind displayed text,
  threshold bands and alarms. `subagent-statusline.ps1` floors instead, deliberately, because its
  figure feeds a colour band.
- **Quiet never hides a segment carrying a warning, an error or an alarm.** That rule is stated in
  six places and is why `quiet` is safe to enable.

## Open issues worth doing first

- **#82 — the `92% cached` suffix is unreadable.** 1.05:1 contrast on the `ok` powerline block, in
  the shipped default configuration. The measurement code exists in `test.ps1` now.
- **#80 — the payload is read at the console input code page.** `機能` arrives as six mojibake
  characters. Every non-ASCII field, every style, today. Nothing caught it because every sample is
  English and the non-English tests run in process.
- **#61 — four fields bypass the payload text guards.** `model.display_name` is the worst: a newline
  there splits the status line in two, breaking the `layout: one` contract.
- **#55 — two icons render the wrong glyph.** `cost` draws a clock rather than a banknote, which now
  sits beside the clock segment's stopwatch.
- **#63 — two flaky test families.** Git fixtures (the probe exceeds `git.timeoutMs` under load and
  the segment renders without counts, so it fails on *content*) and `diag rollover lock` (a child
  pwsh races the parent). Both want injection points, not wider tolerances.
- **#77** screenshots show 7 of 12 segments; **#78** the subagent panel cannot be told about ascii
  or a palette — and #15's ownership check blocks the cheap fix.

## Process notes that paid off

- **One implementer per issue, in its own worktree, four at a time.** Prompts carry the repo's
  accumulated traps, the correction that issue bodies are stale, pre-assigned sample numbers, and
  what the other agents in the wave own.
- **Codex adversarial review per branch, then a `/code-review` per wave.** They overlap almost not
  at all. Findings are reliably right; recommended fixes are often disproportionate — accept the
  finding, then judge the cost.
- **Mutation evidence is required.** Every branch mutates its implementation and names the
  assertions that fail. This caught more real problems than the suite did.
- **Merge via the branch's own implementer**, with per-file rules and an expected assertion count.
  Explaining a difference beats banking it — several real drops and cross-terms were found that way.
- **Deliberately performing the wrong merge first**, once, proved a density assertion catches a
  silent segment deletion that every existing assertion would have passed.

## Traps, all of which bit at least once

`-ceq` is culture-sensitive (and `StartsWith`/`EndsWith`/`IndexOf(string)` are too, while
`Contains(string)` is not) · `Import-ScriptFunction` lifts functions but not script constants · a
bare negative literal binds as a string · `$Raw`/`$Columns`/`$Config` are reserved in `test.ps1` ·
`[System.IO.*]` ignores `Set-Location` · a quoted Bash heredoc collapses `\\` to `\` (twice in a
row, the second looking like a successful repair) · `git checkout` to undo a mutation reverts the
whole uncommitted implementation · Git Bash `grep`/`awk` silently translate CRLF · GitHub closes
only the first issue in `Closes #64 and #65`.
