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

No timeout is added. `git status --porcelain` on a warm repo is tens of milliseconds and the status
line refreshes on events, not on a timer. If this proves slow on large repos, a later round can add
`-uno` or a cache.

## 4. Width fitting

### Available width

`$env:COLUMNS`, which Claude Code sets before running the script. When it is absent, empty, or not
a positive integer, no fitting happens at all. The target width is `COLUMNS - 1`; the one-column
margin avoids the pending-wrap glitch some terminals show when a line ends exactly at the edge.

### Measuring

Visible width is measured on the fully rendered line: strip every `ESC[...m` sequence, then count
text elements with `[System.Globalization.StringInfo]`. That counts each Nerd Font glyph above
U+FFFF as one cell, which `.Length` would count as two. Glyphs are assumed single-width.

### Algorithm

For each line independently:

1. Render. If it fits, done.
2. Stage 1, shrink. In this order, replace the segment's `Text` with its `Short` when present and
   the segment is on this line, re-rendering after each: `limits`, `context`. Stop as soon as it
   fits.
3. Stage 2, drop. Remove whole segments in this order, re-rendering after each: `lines`, `badges`,
   `cost`, `limits`, `folder`, `branch`, `context`. Stop as soon as it fits.
4. `model` is never dropped. If only `model` remains and still does not fit, print it anyway.
   Line 2 in two-line layout has no `model`, so every segment on it can drop; if all do, the line
   is not printed.

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
| `-Columns <int[]>` | Widths to test. Default `120, 60`. `0` means unset, no fitting. |
| `-Config <path>` | Run only this config instead of the generated matrix. |
| `-Raw` | Show ANSI escapes as `<ESC>`, as today. |

Without `-Config`, the script writes four config files into a temp folder, one per layout × style
combination, and runs every sample in `samples/` against each at every width. That is 7 × 4 × 2 =
56 renders, roughly 15 seconds. Output is grouped by combination and width, one rendered line (or
two) per sample, so the matrix doubles as a visual check.

A render fails, and the script exits non-zero after finishing the matrix, when:

- output is empty or whitespace;
- layout `one` produced more than one line, or layout `two` produced more than two;
- any printed line is empty;
- any printed line's visible width exceeds `COLUMNS - 1` when `COLUMNS` is set.

`$env:COLUMNS` is set in the child's environment for each width, and removed for width `0`.

### Samples

No new sample files. Samples 04, 05, and 07 already lack a `git` object, which exercises the
fallback path. Their `current_dir` values are absent or point at directories that do not exist on
a normal machine, so they take the "omit segment" branch. The live `git status` path is exercised
by a manual check in the plan (pipe a payload whose `current_dir` is this repo) and by running the
installed script inside Claude Code.

### Static analysis

`Invoke-ScriptAnalyzer` with the repo's `PSScriptAnalyzerSettings.psd1` passes on every changed
`.ps1`.

### Docs

- `README.md`: a "Configuration" section after "Installation" that shows the JSON, the three
  keys, and notes that missing or invalid values fall back silently. The "What each segment
  shows" table gains the arrow glyph row. A second screenshot, `docs/statusline-two-line.png`,
  shows two-line powerline. "Test without Claude Code" documents the new parameters.
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
a git status timeout or cache.
