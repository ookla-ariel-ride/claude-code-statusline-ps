# Configuration reference

Everything `statusline.json` can say, and how the script reads it. The [README](../README.md#configuration)
keeps the short table; this page has the full description of every key.

## Defaults

The script reads `statusline.json` from its own folder, so after installing that is
`~/.claude/statusline.json`. The installed file holds the defaults:

```json
{
  "layout": "one",
  "style": "plain",
  "palette": "dark",
  "folder": "repo",
  "state": true,
  "links": true,
  "taskbar": false,
  "thresholds": { "warn": 60, "bad": 85 },
  "alarm": { "context": 90, "limits": 90 },
  "icons": {},
  "git": {
    "timeoutMs": 1500,
    "cacheSeconds": 5,
    "cache": true
  },
  "segments": {
    "model": true,
    "context": true,
    "cache": true,
    "cost": true,
    "clock": true,
    "lines": true,
    "limits": true,
    "badges": true,
    "pr": true,
    "folder": true,
    "branch": true
  }
}
```

The file leaves `order` and `rows` out on purpose: without them the segments come in the script's own
order, and a segment added by a later release appears on its own. The installer keeps an existing
`statusline.json`, so a file that spells the order out would pin it. `quiet` and `right` are left out
for the same reason: every threshold in `quiet` defaults to zero, which hides nothing, and `right`
defaults to empty, which moves nothing. `segments` lists eleven names and not twelve because the
twelfth, `time`, is the one segment that is off by default — writing it in with a `false` beside it
would say the file had an opinion about it, and it does not.

A repository can pin its own look. When the payload names a project directory, the script reads
`<project>\.claude\statusline.json` as well and merges it over the user file. The merge is per key, so
a project file of `{"layout": "two"}` keeps every user segment toggle, and one of
`{"segments": {"cost": false}}` turns off cost and leaves the other nine alone. Precedence runs
built-in defaults, user file, project file, and a value the project file gets wrong falls back to the
value beneath it rather than to the built-in default. A project with no `.claude\statusline.json`
changes nothing, and so does an unreadable one. `-Config <path>` is the exception: it replaces the user
file and skips the project file, so a render with it is the same whatever directory the payload names.

The agent panel follows none of this. It takes its style and palette as arguments the installer bakes
in from your **own** file, so a project file changes the bar in that repository and leaves the panel
where it was. See [Style and palette in the panel](agent-panel.md#style-and-palette).

## Keys

| Key | Values | What it does |
|---|---|---|
| `preset` | `minimal`, `cost`, `full` | A name for a layout, a style and the whole set of segment toggles, listed below. Every other key in the same file is applied over it, so a preset is a starting point rather than a lock. A name none of the three has, or a value that is not a string, changes nothing. |
| `layout` | `one`, `two` | `two` puts model, folder, branch, pr, badges and time on the first line and context, cache, limits, cost, clock and lines on the second, unless `rows` says otherwise. |
| `style` | `plain`, `powerline`, `ascii` | `plain` is coloured text with a dim chevron between segments. `powerline` is coloured blocks joined by solid arrows. `ascii` is `plain` with every character drawn from printable ASCII and a `>` between segments, for a terminal whose font you cannot change. See [ASCII style](styles-and-palettes.md#ascii-style). |
| `palette` | `dark`, `light` | Which colour table the line is drawn with. `dark` is what the line has always been and stays the default, so nothing changes until you ask. `light` swaps every colour for one that reads on a pale background. **This is a separate key from `style`, not a fourth style**: `style` is the shape of the line and `palette` is the colours it is drawn in, so all six pairings work — `ascii` with `light` is the ASCII characters in the light colours. `.\install.ps1 -DetectTheme` can set it for you. See [Light palette](styles-and-palettes.md#light-palette). |
| `folder` | `repo`, `leaf` | `repo` shows `owner/name` from `workspace.repo` when the payload has one, with the current directory's name after a `›` when it differs from the project root. `leaf` always shows the directory name alone. |
| `segments.<name>` | `true`, `false` | `false` hides that segment. The names are the ones in the file above, plus `time`, the wall clock, which is the one segment off by default and so is not written there; `segments.pr` is the pull-request link. |
| `state` | `true`, `false` | `false` stops the script writing a state file for the session. |
| `links` | `true`, `false` | `false` turns off the OSC 8 hyperlinks on the folder, branch and pull-request segments. One key covers all three, because the reason to turn them off is never a segment: it is a terminal that prints the escape as text instead of rendering or swallowing it. The links add no width, so the line fits the same either way. |
| `taskbar` | `true`, `false` | `true` draws the context percentage on the window's taskbar button, so how full the window is stays readable while Claude Code is minimised. Green below the `alarm` level and red at or above it, using the same alarm the model segment uses, so a rate limit at its level colours the bar too while the number stays the context window's. A render with no percentage to show — a session before its first API response, or a payload the script could not read — clears the bar rather than leaving the last one lit. Set it in your own `statusline.json` rather than a project's: a payload that will not parse names no project directory, so a project-only value is not read on the one render that most needs to clear the bar. Off by default, and see [Taskbar progress](taskbar.md) before turning it on: Claude Code writes to the same taskbar button. |
| `order` | `["model", "branch", "context"]` | The segments of layout `one`, left to right. A segment left out is not shown, an unknown name is skipped, a repeat keeps its first place. Left out altogether, as the installed file leaves it, the segments come in the script's order, new ones included. An empty list, a list naming no segment, or anything that is not a list does the same. |
| `rows` | `[["model", "branch"], ["context", "cost"]]` | The two lines of layout `two`, with the same rules per row. A segment named on the first row is not repeated on the second, and a row may be empty. Left out, the script's own two rows apply, new segments included. Anything but exactly two lists, or two lists naming no segment, does the same. |
| `right` | `["time"]` | The segments pushed flush against the right edge of the **first** line, in the order given, with spaces filling the gap. Everything else stays packed against the left. Empty by default, and empty means the line you already have — no padding is added to a line with nothing to push against. The names are read like `order`'s: unknown skipped, repeats keep their first place, and a name whose segment is switched off simply leaves the group empty. Unlike `order` and `rows` an empty list is *kept* rather than falling back, so a project file can take back a group the user file asked for. Row two of layout `two` is never aligned, and with `COLUMNS` unset there is no width to align to, so the named segments render inline in their ordinary places. **A right group holds the first whole segments a narrow line loses**, after every short form has been taken: see [width fitting](#width-fitting). |
| `thresholds` | `{ "warn": 20, "bad": 40 }` | Where the context meter and the rate limits turn yellow and red: whole numbers from 0 to 100 (`20` or `20.0`, not `20.5`), `warn` no higher than `bad`. Either value wrong keeps both as they were: the user file's pair under a bad project file, or the built-in 60 and 85. A 1M window keeps its own 70 and 90. |
| `alarm` | `{ "context": 90, "limits": 90 }` | Where the model segment itself turns red: `context` is read against `context_window.used_percentage` and `limits` against the higher of the 5-hour and 7-day figures. Whole numbers, each read on its own, so a file naming one leaves the other at 90. `0` turns that alarm off, a negative counts as `0`, and a number above 100 is kept as written and fires only if the payload reports a figure that high — which a context window never does, since the meter clamps to 100, and a rate limit can, since a limit really at 105% is left unclamped to say so. The spend limit is a billing ceiling rather than a rate and raises no alarm; neither does a percentage that is missing or null, which is what a session sends before its first API response. What is compared is the whole number the segments print, rounded half to even, so the meter and the model can never disagree about whether 90% has been reached: at 89.6 the meter reads 90% and the alarm fires. The alarm reads the percentage whatever the window size, so on a 1M window it fires at the same figure as the window's own fixed 90 band. |
| `quiet` | `{ "cost": 1.00, "context": 30, "limits": 50 }` | The smallest value a segment is worth showing at: dollars for `cost`, percent for `context`, and percent for `limits` against the larger of the 5-hour and 7-day figures (the spend limit is not one of them, and a payload carrying only a spend limit is never hidden here). Below it the segment is not built at all, so it takes no room and has nothing to shed at a narrow width. **Quiet never hides a segment that is carrying a warning, an error or an alarm**: a context meter or a limits segment already yellow or red stays whatever the threshold says, so does a 5-hour figure whose pace arrow projects an overrun — which is the case that matters most, because a low percentage early in a window is exactly the one that projects red — and so does a figure at or above its `alarm` level, since `alarm` may be set below `thresholds.warn` and a red model segment with no number under it explains nothing. `cost` has no warning state of its own and no alarm is read against a dollar figure, so there its threshold is the whole story. Fractions are allowed, a negative counts as zero, and the test is on the raw figure rather than the printed one, so `"cost": 1.00` hides a cost of 0.996 even though it would have printed `$1.00`. The default is `0` everywhere, which hides nothing; a value that is not a number leaves that one name at `0` and the other two alone. There is deliberately no `quiet.cache`: three of that segment's four states are the warning, and the fourth is a countdown whose whole value is being on the line before it turns yellow, so there is no boring number there for a threshold to hide. |
| `icons` | `{ "model": "F0E7", "home": "U+2302" }` | Swaps a glyph for the code point given as hex, with `U+` or `0x` and leading zeros allowed in front. Names: `model`, `context`, `cache`, `cost`, `clock`, `time`, `folder`, `chevron`, `branch`, `worktree`, `home`, `dirty`, `ahead`, `behind`, `conflict`, `pr`, `lines`, `limits`, `fast`, `think`, `effort`, `vim`, `agent`, `session`. A name the list does not have, or a value that is not a single printable glyph, keeps the built-in one. To count as a glyph a code point has to be inside Unicode, not a surrogate half and not a noncharacter, one or two cells wide, and none of: a control (`A` is a newline, `1B` a bare escape), a format character (`202E` is a right-to-left override, `200D` a zero-width joiner), a line or paragraph separator, a space, or a combining mark. Private use is where the Nerd Font glyphs live, so it is allowed. Ignored entirely under `"style": "ascii"`, which promises that every glyph the script chooses is printable ASCII and a code point is the one thing that cannot keep it. |
| `git.timeoutMs` | `100` to `10000` | How long the branch segment waits for `git status`, in milliseconds, before it gives up and leaves the segment out. A value outside the range is clamped to it. |
| `git.cacheSeconds` | `0` to `300` | How long a `git status` result is reused for, in seconds, before git is asked again. `0` asks git on every render. Clamped like `timeoutMs`. |
| `git.cache` | `true`, `false` | `false` asks git on every render, whatever `cacheSeconds` says. |

## Examples

A config only needs the keys it changes. This one puts the branch beside the model, colours the
meter early and uses a house glyph on `main`:

```json
{
  "layout": "two",
  "rows": [["model", "branch"], ["context", "limits", "cost"]],
  "thresholds": { "warn": 40, "bad": 70 },
  "icons": { "home": "U+2302" }
}
```

A segment that is toggled off, or that the active layout's list does not name (`order` for layout
`one`, `rows` for layout `two`), is not built at all: leave `branch` out and the script never runs
`git status`.

With `badges` off the vim mode is shown nowhere, because the installer sets `hideVimModeIndicator`
and that hides Claude Code's own indicator. If that matters, remove `hideVimModeIndicator` from the
`statusLine` entry in `settings.json` by hand.

Anything missing or invalid falls back to its default without a message, so a typo cannot blank
the status line. Delete the file to get the defaults back. `docs/statusline-two-line.json` is the
config behind the two-line screenshot in the README.

## How the config files are read

**Both config files are read under the same budget: 64 KiB and 250 ms.** One clock covers every step of
one file — the open, the size, each read and the close at the end — and it starts before the first
filesystem call. The clock is per file, and the two are read one after the other, so a machine where
both are unreachable spends up to 500 ms and not 250. If the budget goes by the attempt is abandoned and
the config beneath it stands, silently, the way a bad value does. Silently on the line, that is — every
one of those refusals names itself in the [diagnostics log](diagnostics.md), so a config that is being
ignored can say why. The budget is not a judgement about who wrote the file: it is about a filesystem that does not
answer, and a home directory on a dead network share hangs a render exactly the way a project directory
on one does.

**What a miss looks like on screen: that render draws the built-in defaults.** There is no cache of the
last config that worked, so if your own `statusline.json` takes longer than 250 ms to read — an
anti-virus scan of a file just saved, a cloud-sync client hydrating it, a disk spinning up — that one
render is a plain, one-row line, and the next one is back to normal. A visible flicker is the price of
never waiting; a render that hangs would have cost the line altogether.

**`CLAUDE_STATUSLINE_CONFIG_TIMEOUT_MS` raises that 250 ms, and nothing else changes it.** Set it to a
whole number of milliseconds and both config files — yours and the project's — are read under that
budget instead. It exists for the test suite, which renders in child processes that read a config it
wrote a moment earlier and cannot afford one of those reads to miss under load; you would only reach for
it on a machine where a config really does take longer than a quarter of a second to open and a flicker
of defaults is worse than a slow render. It can only ever *raise* the budget: a value below 250, zero, a
negative number, or anything that is not a whole number is ignored and the shipped 250 ms stands, and a
value over 60000 is capped at 60000. Unset — which is every render this was written for — it is not read
at all. It does not reach the other two files the same reader opens, the git cache entry and the session
state file; those keep the 250 ms whatever it says.

What separates the two files is trust, and it comes to one extra check. The project file arrives with
the repository rather than from you, so it is opened first and then judged by the handle: a handle that
cannot seek is a device or a pipe rather than a file, and the size that has to fit under 64 KiB is the
one the handle reports, not one read off the path beforehand. A link or another reparse point is refused
as well. Your own file skips only that last check, so a `statusline.json` symlinked out of a dotfiles
repository still loads — you chose that link, and a repository did not.

Your file is read as bytes rather than through `Get-Content`, and the bytes are decoded by the same
class `Get-Content` decodes with, so the answer is the same one: UTF-8 with or without a mark, UTF-16 in
either byte order, UTF-32 in either byte order, and no mark means UTF-8. A config saved as UTF-16 by an
editor keeps working. This is why the file was left unbounded when the project file was bounded, and it
is what closing that gap needed first. A file another program is holding open *for writing* — an editor
between its truncate and its flush, a sync client — is refused until that writer releases it, rather
than reading an in-flight snapshot.

A relative `-Config` path means what PowerShell means by it, not what the process working directory
means: those two part company after a `Set-Location`, so the path is resolved against your session
before anything opens it. A path PowerShell cannot resolve at all falls back to the built-in defaults
and says so in the log.

A project directory with no `.claude\statusline.json` — the usual case if you keep no per-project
config — costs one attempted open on the thread pool and nothing else: no attribute probe, no read and
no close. It is not free, and cannot be: the deadline is the reason the open is dispatched rather than
made here, and a cheaper check made first would either block on the render's own thread or cost a
dispatch of its own and reopen the gap between asking about a name and opening it. Your own file costs
an open, a size and two reads on every render, which is what reading it has always cost. `test.ps1`
counts those operations rather than timing them, so the shape is pinned and the count cannot drift.

What that buys is a bound on these two reads, not on the machine. Abandoning is literal: a thread can
stay stuck behind a hung open until the process exits, and a file left open that way is not closed on
the way out, because closing it would wait on the same thing. The status line renders and exits without
either. What the bound still does not cover, said plainly rather than rounded off: a filesystem sick
enough to hang calls these reads never make can hold a render up somewhere else. Every other filesystem
call a render can make is audited in a comment beside `Read-BoundedFileText` in `statusline.ps1`, with a
decision recorded for each. The diagnostics log has a clock of its own. The probe cache entry and the
session state file are read under the config budget, because each was one existence test and one read —
the same shape, so the same fix. `git status` is a child process under its own timeout — which covers
the child, and not the `Test-Path` and the walk for a `.git` directory that come before it. Those and
the ref stamps are deliberately unbounded: they are many calls of several shapes rather than the one
open and one read a config takes, so a budget there would cost more than the case it guards. That is a
decision about cost and not a claim that they cannot hang — a project directory on a dead share can hold
a render up in the walk before the git timeout applies to anything.

## Width fitting

Claude Code sets `COLUMNS` before running the script, and the line is fitted to one column less than
that so the terminal never sits on a pending wrap. Too long a line loses things in three stages, and
never in a different order:

1. **Detail.** Segments with a short form swap to it, in this order: cost, limits, cache, context,
   branch, folder, badges, clock. What each one sheds: cost loses the per-turn delta; limits keeps
   only the figure that drives its colour (the worst one when it is yellow or red, otherwise the
   first one present) and drops the countdown and the pace arrow; cache loses the word and keeps the
   glyph and the value; context loses the token counts and the cached share; branch loses every
   count and the worktree name; folder keeps the repository name alone; badges keeps the mode badges
   and sheds the agent and session names; the clock loses its `api` share.
   This reaches into the right group too — a short form is detail shed, and which side of the line the
   segment sits on says nothing about whether that detail is worth losing.
2. **The right group**, last name in the list first, until it is empty or the two groups fit with at
   least one space between them. A segment pushed to the edge is decoration, so the whole group goes
   before one packed segment does — and it goes rather than moving back inline, since re-inlining it
   would make the line wider. This is the trade to know about before setting `right`: on a narrow
   terminal, or a busy line, the clock is the first thing you stop seeing.
3. **Whole segments** from what is left, in this order: time, lines, clock, cache, badges, cost,
   limits, pr, folder, branch, context.

The model segment is never shortened and never dropped, which is why the `alarm` colour rides on it: at
any width there is still a red line saying the window is full. If it will not fit on its own it
overflows, because a status line with nothing on it says less than one that is too long.

With `COLUMNS` unset none of this runs — nothing is measured, nothing is shed, and there is no right
group either, so every segment renders inline in its ordinary place.

## Presets

Turning five segments off by hand is the first edit most people make, so the three usual shapes have
names. The whole file can be `{"preset": "minimal"}`.

A preset sets a style without naming one, and the installer reads the `style` key rather than the
preset, so a preset does not reach the agent panel. It makes no visible difference today — all three
name `plain` or `powerline`, which the panel draws identically — but name `style` yourself if you want
to be sure. See [Style and palette in the panel](agent-panel.md#style-and-palette).

| Preset | Layout | Style | Segments on |
|---|---|---|---|
| `minimal` | `one` | `plain` | model, context, folder, branch |
| `cost` | `one` | `plain` | model, context, cache, cost, clock, lines, limits |
| `full` | `two` | `powerline` | all twelve, the wall clock included |

`minimal` answers which model, how full and where am I, and nothing else. `cost` is the spend line,
for watching a budget or a rate limit. `full` is everything, split across two rows.

A preset is expanded before the rest of the file it appears in, whatever order the keys are written
in, so anything beside it wins: `{"preset": "minimal", "style": "powerline"}` is the minimal segment
set in powerline blocks, and `{"preset": "cost", "segments": {"branch": true}}` is the spend line with
the branch put back. It sets nothing but the layout, the style and the toggles — `order`, `rows`,
`thresholds`, `icons`, `state` and the `git` block are untouched. A preset in a project file sits
where any other project key sits, so it is written over the user file whole; a preset in the user file
is a base for the project file to change.

## The state file

Every render is a new process that sees only the current payload. So that a later render can tell
what changed, the script keeps one small JSON file per session in `claude-statusline-state` under
your temp folder (`%TEMP%` on Windows, `~/.claude/statusline-state` when there is no temp folder).
The file is named after the session id and holds numbers only: the last cost, input and output token
totals, context and 5-hour usage percentages, and up to twenty timestamped cost readings. No prompt
text, path or file name is written. Files not touched for a day are deleted on a later render. A
payload that does not carry the cost or the token totals leaves the stored ones alone, so a figure is
never replaced by nothing; the two percentages are read fresh each render and are simply absent when
the payload is silent, because a carried-forward percentage would say something false about now.
The cost segment uses it, for the change since the previous render: the file is read once, before the
line is built, and written after it is printed. Set `state` to `false` and the script neither reads nor
writes it, and the cost segment shows the session total alone. Upgrading over an existing
`statusline.json` leaves that file alone, so a config without a `state` key gets the default, which is
on. `.\install.ps1 -Uninstall` prints where the files are
so you can delete the folder. The same goes for the `pr` segment: an existing `statusline.json`
without a `pr` key shows it; add `"pr": false` under `segments` to turn it off.

## The git cache

The branch segment keeps the last `git status` answer for each repository in `claude-statusline`
under the same temp folder (`TMPDIR` or the runtime's temp path when there is no `TEMP`), one small
JSON file per repository named by a hash of its path, and reuses it for `git.cacheSeconds` while the
repository's git directory is unchanged: the timestamps of `.git` itself, of `index`, `HEAD`,
`ORIG_HEAD`, `FETCH_HEAD`, `MERGE_HEAD`, `packed-refs`, `logs/HEAD`, `config` and `info/exclude`,
and of every directory under `refs` (up to 256 of them; a repository with more is not cached). A
commit, checkout, add, reset, merge, fetch or push moves one of those, so it shows straight away, and
so does a change to the repository's own config or exclude file; an edit or a new file in the work
tree does not, and neither does a change to your global git config or `core.excludesFile`, so those
can lag by up to five seconds. A worktree or a submodule, where `.git` is a file, is cached under its own
path, with its main repository's refs counted too. A `git status` that failed or timed out is
remembered for the same lifetime, so a slow repository pays the wait once per lifetime, not once per
render — and *is* remembered, which took a fix: a bounded read that times out can finish its open
after the caller has moved on. The reader keeps that task in a small pending list, and the next bounded
read or cache write queues disposal of a completed handle without waiting. The cache write is on the
render path, before the line prints, and makes one immediate replacement attempt. If a still-open handle
refuses that move, the cache caller swallows it and the next render re-probes git: one lost cache entry
and a microsecond-scale failed move, not a render stall. It does not poll an access-denied number or
retry. This is a best effort, not a claim that every cache write is free. A `statusline.json` from before this cache has no `git` block and gets the defaults: the
cache on, five seconds, a 1.5 second timeout. Add `"git": { "cache": false }` to turn it off. The
folder is safe to delete at any time; the next render writes it again, and entries not written for a
day are swept.

## When nothing can be shown

When no segment can be built at all — a payload with nothing in it, or an `order` naming only
segments the payload cannot fill — the script prints the model glyph and the word `claude` in place
of the model segment. The same line stands in when Claude Code sends something that is not JSON at
all. Both follow the same two keys the model segment itself does: with `"segments": {"model":
false}`, or with an `order` or `rows` that leave `model` out, there is no model segment to stand in
for and the script prints nothing. A `statusline.json` that cannot be parsed leaves the built-in
defaults, which do show the line, so a broken config still says something. An empty line is not an
empty session: the state file is written from the payload either way, so a config that shows nothing
still records what the session spent.
