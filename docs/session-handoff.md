# Session handoff

Written 2026-09-07 (eighth session, second day). The feature backlog closed on day one; day two was
documentation and the start of a sequential run over the follow-up issues. Read this first when
resuming work on this repo.

## Repo state

- Branch `main`, in sync with `origin/main`, head `ff3e933` plus this handoff. `main` is the only
  branch on the remote. One feature branch is open locally: `fix-88-plain-markers` in
  `C:\Users\jimsi\wt\fix-88-plain-markers`, owned by a running implementer (see below).
- **Suite: `pwsh -NoProfile -File ./test.ps1` → passed 11724, failed 0** at `9a53ccf` (no script has
  changed since). About nine to twelve minutes alone. Under parallel load expect random failures in
  the render matrix (#99), the diag record budget and render-cost delegate (#94), and the git-cache
  stamp tests (#102) — re-run alone before believing one.
- Lint clean on every `.ps1` (root, `docs/`, `tools/`) with `PSScriptAnalyzerSettings.psd1`.
- Samples 01..15; subagent samples 01..05. Twelve segments. Fifteen helpers are copied verbatim into
  `subagent-statusline.ps1` under the drift gate.
- **The installed status line on this machine matches `main`** (both scripts hash-match). The user's
  `~/.claude/statusline.json` was edited today to interleave roles across the two rows
  (`rows: [[model, branch, folder, pr, badges, time], [context, cost, cache, clock, limits, lines]]`)
  as a stopgap for #106; the previous file is beside it as `statusline.json.before-rows`.
- `C:\Users\jimsi\wt\` holds ten stale worktree directories from day one that git no longer tracks
  (a lingering `pwsh` had them locked) plus the live one for #88. Delete the stale ones by hand.

## What shipped on day two (all documentation)

| PR | Change |
|---|---|
| #101 | README, brief and handoff refreshed after the backlog run |
| #103 | Its review findings folded in |
| #104 | **The README split**: 1,176 lines became 274, and eight reference pages under `docs/` carry the moved text — `installer.md`, `agent-panel.md`, `configuration.md`, `styles-and-palettes.md`, `taskbar.md`, `segments.md`, `diagnostics.md`, `testing.md`. Two commits: verbatim moves by script, then the cut |
| #105 | Segment rows completed against renders |
| #108 | Every README claim audited against the code: four wrong (drop order, `quiet` defaults, lines rule, upstream arrows), five materially incomplete, ten minor; all fixed |

The README is now a short guide: install, configure, fix. Every section ends in a link to its
reference page. **Edit the page that owns a claim; keep the README short.** A script-checked rule for
the split: every internal link and anchor across README and `docs/*.md` resolved at merge time —
re-run that check after any docs change (the PowerShell one-liner is in this session's ledger; it
parses headings into GitHub slugs and follows every `](path#anchor)`).

## The sequential run (in progress)

The user asked for the remaining issues to be worked one at a time by a subagent. Order, with the
reasoning:

1. **#88** — plain-style `track`/`cached` markers off SGR 90 onto measured 256-colour indices,
   asserted on both palettes. **Running** in `fix-88-plain-markers` (agent resumed by SendMessage if
   the session survives; otherwise relaunch fresh from the brief).
2. **#106** — adjacent same-role segments merge into one block (the user's live complaint on the
   two-line powerline layout: context/cache/limits all `ok`, cost/clock/lines all `dim`, model and
   folder two blues at 1.14:1). **Decision: option 2** — an alternate shade per role that
   `Format-Line` uses when the previous block has the same role, on both palettes and in `plain`,
   plus an assertion walking both default layouts and the three presets so every adjacent pair clears
   the joint floor. Option 1 (a visible divider) is the fallback for any pair the shades cannot
   separate. After it lands, **reinstall** (`.\install.ps1 -Subagents -RefreshInterval 10`) and tell
   the user the `rows` stopgap can come out.
3. **#107** — a config key (suggested `"tint": "segment"`, default `role`) giving every segment its
   own resting colour, warnings and the model alarm still overriding, same floors, off by default.
4. **#93** — the diagnostics log can outgrow its cap while another render holds the lock.
5. **#99**, **#94**, **#102** — the load-sensitive test families; injection points, not tolerances.
6. **#98** — a clock seam so screenshots and clock-relative segments regenerate to the same bytes.
7. **#89** — six light-palette block pairs are isoluminant; needs a retuned light background.

Each issue goes through the same gate as day one: the shared brief
(`scratchpad/implementer-brief.md` in this session's temp dir — recreate it from the day-one handoff's
process notes if the scratchpad is gone), TDD, mutation evidence, the implementer's own Codex
adversarial review, then `/code-review`, a fix round, a scoped re-review, and merge.

## Rulings made on the user's behalf

- #106 option 2 was the user's choice; #107 was the user's addition.
- The `rows` stopgap in the user's live config was applied without asking, as a reversible interim
  for a complaint the user raised twice; it is documented above and in the file beside it.
- Day-one rulings still stand (warn kept yellow; `removed` apricot on white-text blocks; effort compare
  `OrdinalIgnoreCase`; the model segment always renders; lock file not mutex; no `File.Exists`
  pre-check on the trusted config path; truncated panel arguments documented not parsed).

## Traps, all of which bit at least once

`-ceq` is culture-sensitive (and `StartsWith`/`EndsWith`/`IndexOf(string)` are too, while
`Contains(string)` is not) · `Import-ScriptFunction` lifts functions but not script constants, and is
transitive · a bare negative literal binds as a string (an AST check in `test.ps1` catches it) ·
`$Raw`/`$Columns`/`$Config` are reserved in `test.ps1` · `[System.IO.*]` ignores `Set-Location` · a
quoted Bash heredoc collapses `\\` to `\`, and the Bash tool mangles `\e`/`\x1b` in `sed`/`perl`
one-liners — strip escapes in PowerShell instead · `git checkout` (bare or path-limited) to undo a
mutation reverts the whole uncommitted implementation · Git Bash `grep`/`awk` translate CRLF · the
Edit tool and `sed -i` rewrite a `.ps1` as LF, which fails the `subagent drift:` assertions invisibly
(`git diff` hides it) — check CRLF after every edit; `[System.IO.File]::WriteAllLines` writes CRLF, so
normalise `.md` files to LF · PowerShell `-like` treats a backtick as an escape, so a pattern holding
Markdown code spans needs `StartsWith` · `/tmp` in the Bash tool is not `C:\tmp` for pwsh · GitHub
closes only the first issue in `Closes #64 and #65` · an agent that ends its turn "waiting for the
monitor" never resumes — brief them to poll the log · a `/code-review` fork can end while its finders
run, and the finders' raw JSON then lands in the coordinator's session — triage it, do not relaunch ·
a network drop kills every running agent; resume each by SendMessage with its last note · an issue body
can be wrong about its own facts · never run `install.ps1` outside the test group's redirected
`USERPROFILE` and `-SettingsPath`.
