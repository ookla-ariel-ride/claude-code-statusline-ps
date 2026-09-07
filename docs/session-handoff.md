# Session handoff

Written 2026-09-06 (eighth session). Every issue that was open at the start of the day is closed.
Read this first when resuming work on this repo.

## Repo state

- Branch `main`, in sync with `origin/main`. Head `b192019` plus this docs refresh. Only `main` exists
  locally and on the remote; every feature branch is merged and deleted.
- **Suite: `pwsh -NoProfile -File ./test.ps1` → passed 11641, failed 0** at `242b234`, run alone;
  PR #100 added ~80 assertions on top and passed 11719 on its own merged tree. About twelve minutes on
  a quiet machine. Under parallel load expect random failures in the render matrix (#99), the diag
  record budget and the render-cost delegate (#94), and the git-cache stamp tests (#102) — re-run
  alone before believing one.
- Lint clean on every `.ps1` (root, `docs/`, `tools/`) with `PSScriptAnalyzerSettings.psd1`.
- Samples run 01..15 (15 is the non-English branch). Subagent samples 01..05. Twelve segments.
  Fifteen helpers are copied verbatim into `subagent-statusline.ps1` under the drift gate.
- The installed status line on this machine is current: both scripts hash-match `main`, `settings.json`
  carries `refreshInterval: 10` and a `subagentStatusLine` entry with `-Style powerline -Palette dark`.
- `C:\Users\jimsi\wt\` holds ten worktree directories git no longer tracks (a lingering `pwsh` had them
  locked). Delete by hand. `.claude/` still holds older ones under OneDrive; cosmetic.

## What shipped today (10 PRs, 13 issues)

| PR | Issues | Change |
|---|---|---|
| #85 | #55, #62 | `cost`/`think` code points corrected and SVGs re-rendered; bare negative literals parenthesised, with an AST self-check and a `render-icons` ↔ `Get-IconDefault` parity test |
| #87 | #80 | stdin read as explicit UTF-8 in both scripts (`Read-StdinText`, drift-gated), transport tests through a child pwsh, sample 15, `$OutputEncoding` pinned in the suite |
| #86 | #82 | inline markers carry Light/Dark colours picked by the block's ink; `warn` stays yellow; three floors pinned (marker vs background 3:1 and marker vs block text 85 sRGB on both palettes; background pairs 40 sRGB on both, and 1.10:1 in luminance on the dark table only — the light table fails it, which is #89) |
| #90 | #61, #45, #44 | `Get-PayloadText` / `Get-PayloadPercent` at every site in both scripts; model segment always renders (`claude` fallback) so the alarm survives; `TimeLeft` in whole seconds against `$Now` with a 365-day cap; effort compare `OrdinalIgnoreCase` |
| #92 | #63 | git-probe timing and diag-rollover tests deterministic via an injectable `$WaitForExit` and a pinned record budget |
| #95 | #48 | user config, git-cache entry and state file read through `Read-BoundedFileText -Trusted` with `StreamReader` BOM detection; `-Config` resolved once at the boundary; `FileShare.ReadWrite` re-open on a sharing violation; audit table of every render-path filesystem call beside the reader |
| #91 | #49 | the rollover mutex was POSIX-session-scoped on Unix and `Global\` throws for a second user on both platforms; replaced by an exclusive lock file beside the log, pool-bounded, with abandoned handles swept and the list capped |
| #96 | #78 | subagent `-Style`/`-Palette`, composed by `install.ps1` from one spec table; config written before the settings entry; an owned panel entry refreshed on any run |
| #97 | #77 | screenshots regenerated from sample 06 with all twelve segments; OSC pattern derived from one `$oscArm`; icon viewBox frame pinned as a constant |
| #100 | #52 | project-owned backup names with a `.sha256` sidecar; atomic backup writes from the baseline text after the second unchanged-check; Windows Terminal font change refused when its backup fails |

Follow-ups filed from review findings, all open: #88, #89, #93, #94, #98, #99, #102. None is a feature.

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
- **Every config read is bounded**: `Read-BoundedFileText` gives the project file 64 KiB and 250 ms
  as untrusted input (handle-first validation, reparse points refused) and the user file, the git
  cache entry and the state file the same budget under `-Trusted`. Encoding comes from a
  `StreamReader` over the bytes read. A comment beside the reader audits every other filesystem call
  a render makes. `-Config` is resolved once, at the boundary, by `Resolve-ConfigPath`.
- **Every payload field goes through a shared guard**: `Get-PayloadText` for text (reject controls,
  strip format characters), `Get-FiniteNumber`/`Get-PayloadPercent` for numbers. The model segment
  never returns `$null`; the alarm rides on it.
- **Two rendering scripts, fifteen shared helpers, one drift gate** comparing them by AST extent.
  `subagent-statusline.ps1` cannot dot-source `statusline.ps1`, which executes its whole body on
  load — that is why the fifteen are copies, and why an LF rewrite of either file fails the gate.
- **Three styles** (`plain`, `powerline`, `ascii`) and **two palettes** (`dark`, `light`) are
  separate axes. Each inline marker carries a Light and a Dark colour and the block's `Ink` picks one.
- **`Get-WholePercent`** is the one percentage rule (round half to even) behind displayed text,
  threshold bands and alarms. `subagent-statusline.ps1` floors instead, deliberately, because its
  figure feeds a colour band.
- **Quiet never hides a segment carrying a warning, an error or an alarm.** That rule is stated in
  six places and is why `quiet` is safe to enable.
- **The diagnostics rollover guard is a lock file beside the log** (`<log>.lock`, `FileShare.None`,
  pool-dispatched under the record budget), not a mutex: a bare mutex name is per POSIX session on
  Unix and `Global\` throws for a second user.
- **The installer decides the panel's style and palette from one table** (`Get-SubagentArgumentSpec`),
  writes `statusline.json` before the settings entry, and its backups live at project-owned names
  with a `.sha256` sidecar as the provenance marker.

## Rulings made on the user's behalf (any is one small change to reverse)

- `warn` block kept yellow; markers pick their colour by block ink (reversed a first acceptance of a
  `warn` colour change once the review showed it isoluminant with `ok`).
- `removed` is apricot inside white-text blocks — a true red cannot clear 3:1 there — and red only on the
  yellow block. A 214-amber alternative needing a model-block exemption was declined.
- Effort compare `OrdinalIgnoreCase`, not case-sensitive `Ordinal`.
- The model segment always exists when enabled, even with no `model` key.
- Lock file instead of any mutex; parked-lock sweep capped at 8; permission failure on the lock drops the
  record rather than growing the log.
- No `File.Exists` pre-check on the trusted config path (55 µs saving, unbounded call ahead of the clock).
- One-line screenshot stays `plain` (the shipped default); no clock seam in a docs PR (#98).
- Truncated hand-edited panel arguments are documented, not parsed.
- The subagent rollback keeps its stricter abort-on-failure policy, documented rather than unified.

## Process notes that paid off

- **One implementer per issue, own worktree under `C:\Users\jimsi\wt\` (outside OneDrive), four at a
  time.** Prompts carry a shared brief (repo state, traps, the mandatory method) plus a per-issue
  dispatch; reports go to files, not the coordinator's context.
- **Codex adversarial review by the implementer, then `/code-review` per PR, then a scoped re-review of
  the fix round.** Every review found something real; three PRs needed a design rework (#82, #49 twice).
- **Mutation evidence is required** and caught more than the suite did: five assertions that could not
  fail, a test that pinned a literal rather than a property, a `-ErrorAction SilentlyContinue` that did
  not suppress.
- **Merge main via the branch's implementer** with per-file rules and an expected assertion count; a
  clean textual merge was verified by arithmetic every time.
- **Resume, never relaunch.** Rate limits killed four agents mid-task; each resumed by `SendMessage`
  with its last note and picked up where it stopped.

## Traps, all of which bit at least once

`-ceq` is culture-sensitive (and `StartsWith`/`EndsWith`/`IndexOf(string)` are too, while
`Contains(string)` is not) · `Import-ScriptFunction` lifts functions but not script constants, and is
transitive · a bare negative literal binds as a string (an AST check in `test.ps1` now catches it) ·
`$Raw`/`$Columns`/`$Config` are reserved in `test.ps1` · `[System.IO.*]` ignores `Set-Location` · a
quoted Bash heredoc collapses `\\` to `\` (twice in a row, the second looking like a successful
repair) · `git checkout` to undo a mutation reverts the whole uncommitted implementation, and
`git checkout <sha> -- file` is just as destructive · Git Bash `grep`/`awk` silently translate CRLF ·
GitHub closes only the first issue in `Closes #64 and #65` · an agent that ends its turn "waiting for
the monitor" never resumes — brief them to poll the log in a bounded loop · the Edit tool and `sed -i`
rewrite a `.ps1` as LF, which fails the `subagent drift:` assertions invisibly (`git diff` hides it) —
check CRLF after every edit · a `/code-review` fork can end while its finders run; the finders' raw
JSON then lands in the coordinator's session — triage it, do not relaunch · an issue body can be wrong
about its own facts (#49's "verify" turned into a design change; #55 and #11 named the wrong code
points) · never run `install.ps1` outside the test group's redirected `USERPROFILE` and
`-SettingsPath`; a reviewer once overwrote the live `~/.claude`.
