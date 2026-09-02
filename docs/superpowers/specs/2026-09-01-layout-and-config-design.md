# Layout, width fitting, powerline style, and config file

Date: 2026-09-01. Status: approved design, awaiting spec review.

## Goal

Give `statusline.ps1` an optional two-line layout, width awareness, and a powerline separator
style, all switched from a `statusline.json` config file. Fix the branch segment so it renders in
real Claude Code sessions, not only in `test.ps1`. With no config file present the output must look
identical to today's one-line plain rendering (same characters, same colours), except that the
branch segment now appears in real sessions.

Out of scope this round: segment order, colour thresholds, glyph choices, a light palette, new
segments. See "Later" at the end.

## 1. Config file

### Location

The script reads `statusline.json` from its own directory (`$PSScriptRoot`). Installed, that is
`~/.claude/statusline.json`. In the repo it is the repo root. `statusline.ps1` gains one optional
parameter, `-Config <path>`, which overrides the location. Claude Code never passes it; `test.ps1`
and `docs/render-screenshot.ps1` do.

### Schema

```json
{
  "layout": "one",
  "style": "plain",
  "segments": {
    "model": true,
    "context": true,
    "cost": true,
    "lines": true,
    "limits": true,
    "badges": true,
    "folder": true,
    "branch": true
  }
}
```

| Key | Values | Default |
|---|---|---|
| `layout` | `one`, `two` | `one` |
| `style` | `plain`, `powerline` | `plain` |
| `segments.<name>` | `true`, `false` | `true` |

### Validation

Everything falls back to its default silently. Specifically:

- File missing, unreadable, or not valid JSON: all defaults.
- `layout` or `style` missing, not a string, or not one of the listed values: default.
  Comparison is case-insensitive.
- `segments` missing or not an object: all on. A segment name that is missing or whose value is
  not a JSON boolean: on. Unknown segment names: ignored.
- Unknown top-level keys: ignored.

Nothing is ever written to stderr or stdout about config problems. A broken config must never
break the status line.

### Shipping and install

The repo commits `statusline.json` holding the defaults above. `install.ps1` copies it to
`~/.claude/statusline.json` only if that file does not already exist, and prints which of the two
happened. `install.ps1 -Uninstall` leaves the config in place and prints one line saying it was
kept and where it is.

## 2. Segment model

### Segment record

Each segment is built by its own function that returns `$null` (segment omitted) or a hashtable:

| Field | Type | Meaning |
|---|---|---|
| `Name` | string | One of `model, context, cost, lines, limits, badges, folder, branch`. |
| `Text` | string | Full text, with glyphs. May contain inline foreground colour changes (see "Inline colour"). Never contains `ESC[0m` or background codes. |
| `Short` | string or `$null` | Reduced text used by width fitting stage 1. `$null` means no shorter form. |
| `Role` | string | Palette role, see the colour table. Decides the segment's colours in both styles. |
| `Bold` | bool | Bold text. Only `model` sets it. |

Builders receive the parsed payload and the config. They do not know about layout or style, with
one exception: inline colour lookups take the style so the same builder works in both.

### Order and lines

One-line order is unchanged: `model, context, cost, lines, limits, badges, folder, branch`.

Two-line split:

| Line | Segments in order |
|---|---|
| 1 | `model, folder, branch, badges` |
| 2 | `context, limits, cost, lines` |

A line with no segments is not printed. So a two-line config on a payload with only a model
prints one line. Segment toggles apply before layout; a toggled-off segment never builds.

The final fallback stays: if no segment at all is built (all toggled off or payload empty), print
the model glyph and `claude` in plain cyan, as today.

### Colour table

Plain style keeps the exact SGR codes used today. Powerline style uses 256-colour indices so the
backgrounds look the same on every terminal theme.

| Role | Used by | Plain SGR | Powerline fg | Powerline bg |
|---|---|---|---|---|
| `model` | model | `1;36` | 231 | 31 |
| `ok` | context, limits below 60% | `32` | 231 | 28 |
| `warn` | context, limits 60–84%, dirty branch | `33` | 16 | 178 |
| `bad` | context, limits 85% and above | `31` | 231 | 160 |
| `dim` | cost, lines, badges | `90` | 250 | 238 |
| `folder` | folder | `34` | 231 | 25 |
| `branch` | clean branch | `35` | 231 | 90 |

Inline colours (used inside `Text` by the lines segment only):

| Inline role | Plain SGR | Powerline fg |
|---|---|---|
| `added` | `32` | 46 |
| `removed` | `31` | 203 |

### Inline colour

The lines segment renders `+156` green and `−23` red inside a dim segment. In powerline style the
background must not break, so inline spans change the foreground only and then restore the
segment's own foreground rather than emitting a reset. A helper `Inline($role, $text, $segmentRole,
$style)` does exactly that. In plain style it emits `ESC[<inline SGR>m text ESC[<segment SGR>m`,
which produces the same bytes the script emits today for that segment.

### Renderer

One function takes an ordered list of segment records, the style, and a target width, and returns
one string. It is called once per line.

Plain: each segment becomes `ESC[<SGR>m<Text>ESC[0m`; segments join with the existing separator,
a space, a dim thin chevron `U+E0B1`, and a space.

Powerline: each segment becomes `ESC[48;5;<bg>;38;5;<fg>m <Text> ` (one space padding each side,
`1;` prefixed when bold). Between segment A and segment B the separator is
`ESC[38;5;<A.bg>;48;5;<B.bg>m` followed by the solid arrow `U+E0B0`. After the last segment:
`ESC[0m ESC[38;5;<last.bg>m` arrow `ESC[0m`, so the arrow points into the terminal's own
background.

Two-line output is printed as two `Write-Host` calls, one per line.

## 3. Git fix

The real payload carries no `git` object. The branch builder therefore:

1. Uses `$d.git.branch` and `$d.git.status` when the payload has a `git` object. This keeps the
   seven samples and the screenshot renderer working unchanged.
2. Otherwise, if `workspace.current_dir` is set and the directory exists, runs one command with
   `GIT_OPTIONAL_LOCKS=0` in the environment:

   ```
   git -C <current_dir> status --porcelain=v1 --branch
   ```

   Stderr is discarded. If `git` is not on PATH, the command fails, or the output has no line
   starting with `## `, the segment is omitted.
3. Parses the first line. `## main...origin/main [ahead 1]` gives `main` (text after `## ` up to
   the first `...`, or to end of line). `## HEAD (no branch)` and `## No commits yet on main` are
   detached or unborn; show the text `detached` for the first and `main` for the second.
4. Dirty means any line after the first. Untracked files count as dirty, matching porcelain.

Rendering is unchanged: home glyph on `main` or `master`, branch glyph otherwise, pencil glyph and
`warn` role when dirty, `branch` role when clean.

### Timeout

The status line must never hang on git. The command is started with
`System.Diagnostics.Process` (redirected stdout, `UseShellExecute` false, `CreateNoWindow` true)
and given `$gitTimeoutMs = 1500` to finish. If `WaitForExit` returns false the process is killed
with `Kill($true)` (the whole tree) and the segment is omitted. Any exception from starting or
reading the process also omits the segment. Stdout is drained while waiting, using
`BeginOutputReadLine` with a handler that appends to a list, so a large porcelain listing cannot
fill the pipe and deadlock a process that would otherwise finish in time.

The number is a constant at the top of the script, not a config key this round.

## 4. Width fitting

### Available width

`$env:COLUMNS`, which Claude Code sets before running the script. When it is absent, empty, or not
a positive integer, no fitting happens at all. The target width is `COLUMNS - 1`; the one-column
margin avoids the pending-wrap glitch some terminals show when a line ends exactly at the edge.

### Measuring

Visible width is measured on the fully rendered line: strip every `ESC[...m` sequence, then walk
the text elements from `[System.Globalization.StringInfo]` and sum a cell width per element:

| Element | Cells |
|---|---|
| First code point is a combining mark (Unicode category `Mn`, `Mc`, or `Me`) or a zero-width char (U+200B–U+200D, U+FE0F) | 0 |
| First code point is in an East Asian Wide or Fullwidth block: U+1100–115F, U+2E80–A4CF, U+AC00–D7A3, U+F900–FAFF, U+FE30–FE4F, U+FF00–FF60, U+FFE0–FFE6, U+20000–3FFFD | 2 |
| First code point is emoji presentation: U+1F300–1F64F, U+1F680–1F6FF, U+1F900–1FAFF, U+2600–27BF | 2 |
| Anything else, including Nerd Font private-use glyphs and the box characters | 1 |

This is a small `wcwidth` approximation, not the full algorithm. It covers the text a user controls
(folder and branch names, model display name) well enough to stop wrapping in the common cases.
Terminals disagree on some emoji and on Nerd Font glyph widths; that residual risk is accepted and
documented in the README's troubleshooting section.

### Algorithm

For each line independently:

1. Render. If it fits, done.
2. Stage 1, shrink. In this order, replace the segment's `Text` with its `Short` when present and
   the segment is on this line, re-rendering after each: `limits`, `context`. Stop as soon as it
   fits.
3. Stage 2, drop. Remove whole segments in this order, re-rendering after each: `lines`, `badges`,
   `cost`, `limits`, `folder`, `branch`, `context`. Stop as soon as it fits.
4. `model` is never dropped. If only `model` remains and still does not fit, print it anyway.
   This is the one case where output may exceed the target width, and the test oracle exempts it
   (see "test.ps1"). Line 2 in two-line layout has no `model`, so every segment on it can drop;
   if all do, the line is not printed.

The minimum supported width is therefore the rendered width of the model segment plus the
margin. Below that, the status line prints the model segment alone and lets the terminal wrap.

Short forms:

| Segment | Full | Short |
|---|---|---|
| `context` | `󰍛 32% ███░░░░░░░ 64k/200k` | `󰍛 32% ███░░░░░░░` (token counts dropped) |
| `limits` | ` 5h 23% (1h12m) 7d 41%` | ` 5h 23%` (countdown and 7-day figure dropped) |

All other segments have `Short` = `$null`.

## 5. Powerline style

Covered by the renderer in section 2. Additional points:

- The solid arrow `U+E0B0` is added to `docs/render-icons.ps1` under the name `arrow` so the README
  can show it.
- Threshold colours become backgrounds: the context bar and limits segment turn green, yellow, or
  red as a block. The bar characters inherit the segment foreground.
- The `badges` segment in powerline style keeps its glyph-only text on a dim background. Its
  separator arrows make it readable even when the text is two glyphs wide.
- Plain style output for a default config looks identical to the current script's output for
  the same payload: same characters, same colours. The exact escape sequences may differ (the
  lines segment restores its foreground instead of resetting), which no test depends on. The one
  visible change is the branch segment rendering from `git status` when the payload lacks a
  `git` object.

## 6. Testing and docs

### test.ps1

Parameters:

| Parameter | Meaning |
|---|---|
| `-Columns <int[]>` | Widths to test. Default `120, 60, 20`. `0` means unset, no fitting. Width 20 forces the model-only fallback on every sample. |
| `-Config <path>` | Run only this config instead of the generated matrix. |
| `-Raw` | Show ANSI escapes as `<ESC>`, as today. |

Without `-Config`, the script writes four config files into a temp folder, one per layout × style
combination, and runs every sample in `samples/` against each at every width. That is 7 × 4 × 3 =
84 renders, roughly 20 seconds. Output is grouped by combination and width, one rendered line (or
two) per sample, so the matrix doubles as a visual check.

A render fails, and the script exits non-zero after finishing the matrix, when:

- output is empty or whitespace;
- layout `one` produced more than one line, or layout `two` produced more than two;
- any printed line is empty;
- any printed line's visible width exceeds `COLUMNS - 1` when `COLUMNS` is set, unless the
  line consists of the model segment alone (the documented fallback). The test detects that case
  by rendering the same sample with every segment except `model` toggled off and comparing.

Visible width in the test is measured by a copy of the same cell-width function, kept in
`test.ps1` rather than dot-sourced from `statusline.ps1`, so a bug in the script's measurement
does not silently agree with itself. Both copies are exercised by a fixed table of strings with
known widths (ASCII, a Nerd Font glyph, CJK, an emoji, a combining mark) at the start of the run.

`$env:COLUMNS` is set in the child's environment for each width, and removed for width `0`.

### Git fallback tests

`test.ps1` also runs a git group that does not depend on the developer's own repository. It
creates temporary repositories under the scratch folder with `git init -b main` (so the result does
not depend on the machine's `init.defaultBranch`) and pipes a payload with no `git` object and
`current_dir` set to each:

| Case | Setup | Expected branch segment |
|---|---|---|
| clean | one commit on `main` | `main`, home glyph, no pencil |
| dirty tracked | commit, then modify the file | `main` with pencil, warn colour |
| dirty untracked | commit, then add an untracked file | `main` with pencil |
| feature | checkout `-b feature/x` | `feature/x`, branch glyph |
| unborn | `git init` only | `main` (from `## No commits yet on main`) |
| detached | checkout the commit hash | `detached` |
| not a repo | empty directory | segment omitted |
| git fails | fake `git` on PATH that exits 128 with stderr | segment omitted, nothing on stderr |
| git hangs | fake `git` on PATH that sleeps 10 s | segment omitted, render completes in under 3 s |

The fake `git` is a `git.cmd` written to a temp folder that is prepended to `PATH` for that child
only. Each case asserts on the ANSI-stripped output text. Cases that need a real git are skipped
with a warning when `git` is not on PATH.

### Samples

No new sample files. Samples 04, 05, and 07 already lack a `git` object, which exercises the
fallback path. Their `current_dir` values are absent or point at directories that do not exist on
a normal machine, so they take the "omit segment" branch. The live `git status` path is covered by
the git fallback tests below, which build their own repositories.

### Static analysis

`Invoke-ScriptAnalyzer` with the repo's `PSScriptAnalyzerSettings.psd1` passes on every changed
`.ps1`.

### Docs

- `README.md`: a "Configuration" section after "Installation" that shows the JSON, the three
  keys, and notes that missing or invalid values fall back silently. The "What each segment
  shows" table gains the arrow glyph row. A second screenshot, `docs/statusline-two-line.png`,
  shows two-line powerline. "Test without Claude Code" documents the new parameters.
  "Troubleshooting" gains an entry for lines that still wrap (wide glyphs or emoji in folder or
  branch names, and the model-only fallback at very narrow widths).
- `docs/render-screenshot.ps1` gains `-Config <path>` and `-Out <path>` so it can render both
  screenshots; the two-line render draws two rows.
- `docs/render-icons.ps1` gains the `arrow` glyph.
- `docs/projectbrief.md` is brought current: eight segments, seven samples, the config file, the
  new `test.ps1` behaviour, and the git fallback listed under key design decisions.

## Error handling summary

- `$ErrorActionPreference = 'SilentlyContinue'` stays at the top of `statusline.ps1`.
- Config read, git call, and width parsing are each wrapped so any failure yields the default
  behaviour for that feature, never an exception.
- The existing "print `claude` if nothing built" guard remains the last line of defence.

## Later

Not in this round, recorded so they are not lost: configurable segment order, thresholds, glyphs,
a light palette, session duration, PR number as an OSC 8 link, prompt-cache health, `owner/repo`
and worktree identity, agent name, 1M-context colour scaling, `refreshInterval` in the installer,
a git status cache, a configurable git timeout, a full `wcwidth` implementation.
