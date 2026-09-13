# Session handoff

Written 2026-09-13 (ninth and tenth sessions, one long run from the evening of the 12th). The open
backlog is closed: the nine issues that were open on the 12th are all merged and closed, and nothing is
open on GitHub. Read this first when resuming work on this repo.

## Repo state

- Branch `main`, in sync with `origin/main`, head `5985eaa`. `main` is the only branch that matters on the
  remote; the wave branches below were merged and deleted locally (their remote refs remain).
- **Suite result: `passed 17287, failed 0`** at `819d06b` (the tree `main`
  merged last), run alone. The suite has grown from 11,724 to 17,287 assertions in this run and takes
  **ten to thirteen minutes alone** on this machine (15,000-assertion trees took nine minutes forty; the
  loaded runs of the night took eighteen to twenty-four). Under any second suite the git-cache stamp cases,
  the `time` minute-boundary case and random render-matrix cells still fail; run alone before believing one.
  New full runs use `pwsh -NoProfile -File .\tools\Invoke-Suite.ps1 -Wait`.
- Lint clean on every `.ps1` with `PSScriptAnalyzerSettings.psd1`. Samples 01..15; subagent samples 01..05.
  `statusline.json` gained one key, `tint` (`role` by default, `segment` opt-in).
- **The installed status line on this machine matches `main`** (both scripts hash-match, reinstalled at
  `5985eaa` with `-Subagents -RefreshInterval 10`). The `rows` interleave in `~/.claude/statusline.json`
  was a stopgap for #106 and can come out; the previous file is beside it as `statusline.json.before-rows`.
- Ten worktrees are still registered, all for merged branches: four under `C:\Users\jimsi\wt\` (the old PR
  branches) and five Sidequest agent worktrees under `~/.claude/sidequest/worktrees/`. `C:\Users\jimsi\wt\`
  also holds eleven untracked directories from day one. `git worktree remove` and `prune` hit
  "Permission denied" on `.git/worktrees/*` metadata under OneDrive; `Remove-Item -Recurse -Force` from
  PowerShell clears them. None of this blocks anything.
- `.git/info/exclude` now lists `.claude/` so the Sidequest board sees a clean checkout; the directory holds
  the project plugin settings plus stale day-one worktree copies, none tracked.

## What shipped (eight PRs, nine issues)

| PR | Issues | What landed |
|---|---|---|
| #113 | #98 | one clock reading per render behind `CLAUDE_STATUSLINE_NOW`; strict `Get-StatusClock`; screenshots regenerate to the same bytes on one machine |
| #115 | #106 | second shades for `ok`/`warn`/`bad`/`dim` chosen in `Format-Line` when a neighbour shares the role; a divider where the cube has no second shade; the failing assertions were a test-side unroll bug, the render was right |
| #112 | #93 | `Invoke-StatusDiagRollover` returns its outcome and the caller drops on anything but `$true`; per-reason drop map; late-lock sweep on every record; nine reasons documented once |
| #114 | #99, #94, #102 | `CLAUDE_STATUSLINE_CONFIG_TIMEOUT_MS` can only raise the config deadline; git-cache tests pin entry ages and the read deadline; diag and render-cost budgets pinned; a disposal-only pending sweep for the bounded reader; one unwaited atomic move (a refused move costs one render's cache entry, never a stall) |
| #116 | #89 | the seven light backgrounds moved (51, 76, 221, 218, 252, 110, 213) so every pair clears 1.10:1 and 40 sRGB; the light against-white bar fell to 1.25:1 with an 80 sRGB distance half; **the four light second backgrounds were removed**: under the floor no cube colour exists, proved by exhaustive search |
| #117 | (#94 fix) | `Write-StatusDiag`'s abandoned append open joins the diag pending-handle sweep; admission control (refuse a ninth open) instead of eviction; the GitHub PR record stuck open after a 502 and was closed by hand, the merge `7bbee1c` is on `main` |
| #118 | #107 | `tint: segment` gives each of the twelve segments a resting colour in both palettes, warnings and the alarm still override; the divider is drawn for any resolved joint under the floor under either tint; segment tables in `Get-SegmentPalette`, main script only |
| #119 | #111 | dark plain `dim` moved from SGR 90 to `38;5;251` (alternate 254), measured on both plain grounds and 86.6 sRGB from the `246` markers; the light-terminal cost of the dark default is now documented with `palette: light` as the remedy |

Every PR went through a Codex adversarial review, `/code-review` at high, one to three fix rounds, and a
full suite run alone on the exact merged tree. The review rounds were where the real defects were found
(a same-pass close a wait could not see, a cap that evicted an unfinished open, a light `branch` code
identical to the `bad` code, an emitted delegate costing 31 ms per process); budget for them.

## How the work runs now: the Sidequest board

The user installed Sidequest on the 12th; the board (`claude-code-statusline-ps-985719e8`) is the ledger
and every implementer is a routed executor. Rules that came out of this run, all also in the user-level
`CLAUDE.md` and this project's memory:

- **Every wave ships as a PR.** Cut `wave/<name>` from `main`, set the board's `integrationBranch` to it,
  dispatch, and executors' worktrees are cut from that branch (`worktreeBase` is `local-main`). When the
  candidate is verified, push the wave branch, open the PR with the `Closes #N` lines and the evidence,
  merge on GitHub, then point `integrationBranch` back to `main`. It is on `main` now.
- **A dispatch's integration target is pinned when it is prepared**, so the board can be repointed for the
  next ticket as soon as the previous executor's worktree exists. Declare every path a merge of `main`
  would touch, or the executor is refused scope mid-merge.
- **Two Sidequest limitations shaped every round** (version 5.1.15, 5.1.16 arrived mid-run and needs
  `/reload-plugins`): the pinned verify-capture wrapper has a fixed ten-minute ceiling that the board's
  30-minute setting does not reach, and this suite outlasts it, so `submit` was never possible; and the
  board's `commit` tool cannot complete a merge commit (`git commit --only` during a merge). The working
  pattern: the executor commits, runs the wrapper once, lets its child finish, posts the full report and
  releases with kind `handback`; the orchestrator completes any merge commit with plain git, verifies the
  exact tree alone, publishes, and closes the ticket with `groomClose` citing the merge. Both are upstream
  defects for Eigenwise/eigenwise-toolshed, not yet filed.
- **The Sidequest hook refuses raw `Agent` spawns**, including `/code-review`'s own finders, which is why
  every review ran inline in the review fork. It also means an implementer can never be a plain agent.
- **Verification on this machine is fragile.** The harness kills background tasks (and their children)
  when free memory drops under about a gigabyte, which it does whenever a suite runs beside Chrome, WSL
  and Docker. Run the full suite only through `pwsh -NoProfile -File .\tools\Invoke-Suite.ps1 -Wait`:
  it detaches the child, prevents an accidental second suite and prints its stamped log path. If the
  shell disappears, resume with `-Attach <log-path>`; do not hand-roll `Start-Process` or a `Monitor`.
- **Transient API drops** (stream idle timeouts, connection resets, one unparsable tool call) hit seven
  executors and two review forks. Every one was resumed by `SendMessage` with its last note and lost
  nothing; never relaunch.

## Rulings made on the user's behalf

- #89: removing the four light second backgrounds rather than keeping four joints at 1.008 to 1.022, which
  is the defect the issue closes. Recorded on SQ-5 and in PR #116.
- #107: the segment tables' honest arrow floor is 1.05:1 on both palettes; mixed joints under the floor
  take the divider; the equality contract is byte-exact after stripping SGR in plain and ascii and after
  normalising the joint glyph in powerline. The bad-payload stand-in on dark now takes the model role's
  bold cyan (`1;36`) instead of plain cyan.
- #94/#114: after an emitted delegate measured 31 to 38 ms per fresh process, the reader stays on the
  closed `OpenRead` delegate (12 to 17 ms, the baseline) and the cache write makes one unwaited move.
- #111: the dark default's dim grey is hard to read on a light terminal that never set `palette`; the
  design stands, the cost is documented.
- Day-one and day-two rulings still stand (warn kept yellow, effort compare `OrdinalIgnoreCase`, lock file
  not mutex, no `File.Exists` pre-check on the trusted path, `removed` apricot on white-text blocks).

## Traps that bit this run

Everything in the previous handoff still applies. New this run:

- **The one-line `Import-ScriptFunction` list in `test.ps1` (~line 355) conflicts on every merge of
  `main`.** Resolve as the union of both sides minus any name the other side renamed or removed
  (`Clear-StatusDiagPendingLock` became `Clear-StatusDiagPendingHandle`; `Open-SharedConfigFile` went
  away), then verify the count, that every name matches `^function <name>\b` in the merged
  `statusline.ps1`, and that the line still ends with `))`. An emptied list lints clean and only fails
  ten minutes later; it happened once.
- A `return , $out` at the end of a function is unwrapped once by PowerShell, so a pipeline consumer sees
  the whole array as one object; `Get-JointSet` and `Measure-DiagMatch` both had it. Wrap the call in
  `@()`, not the pipeline.
- `Get-CachedGitBranch` no longer takes an injected clock; tests pin entry ages in fixtures.
- Executors that "wait for the monitor" or stop their own suite child lose the run; the ticket text now
  spells out the polling and the never-stop rule, and still gets ignored about one time in four.
- GitHub returned 502 on one merge and left PR #117 open with its merge commit on `main`; `gh pr close`
  with a note was the way out.

## Loose ends, none blocking

- Worktree cleanup (above). The four `C:\Users\jimsi\wt\` checkouts and the five agent worktrees are all
  merged; remove them when convenient.
- File the two Sidequest limitations upstream, with the reproduction: a suite that outlasts ten minutes
  cannot be submitted, and a staged merge cannot be committed through the board.
- `/reload-plugins` for Sidequest 5.1.16; the running board server still served 5.1.15 at the end.
- The user's live `statusline.json` predates `tint`; nothing to do unless they want `segment`.
- The verification and review evidence for every ticket is on the board (comments on SQ-1 to SQ-11) and in
  the orchestrator scratchpad for session `e0a7aff1` (`sq*-verify*.log`, `pr*-codex-review.md`,
  `pr*-body.md`), which the OS will eventually clear.
