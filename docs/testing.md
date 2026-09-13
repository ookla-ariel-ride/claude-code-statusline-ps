# Testing and contributing

## What `test.ps1` runs

`test.ps1` runs in groups, unit checks first. Those call the script's helper functions directly (width
measurement, config parsing, the segment table, rendering, width fitting, the context meter, the
limits, `git status` parsing, the payload counts, the branch and pr segments, the state file, the
git cache, and the count of filesystem operations a config read costs for each shape of payload —
counted rather than timed, so it is deterministic). The git group runs the branch fallback against
temporary repositories: clean, dirty, unborn, detached, one commit ahead, one behind, a mixed tree
with a staged, a modified and an
untracked file, a fake `git` that fails and one that hangs, then the cache end to end: a second
render with a failing `git` on `PATH`, a fetch from a bare remote, a push, a worktree. The state
group writes and reads session files in a temp folder. The install group runs `install.ps1` with
`USERPROFILE` and `-SettingsPath` pointed into a temp folder: a fresh settings file, an existing one
with unrelated keys, `-RefreshInterval`, a refused value, and `-Uninstall`. It checks afterwards
that the real `~/.claude` files were not touched. `-DetectTheme` is covered twice over: the settings
walk and the luminance arithmetic are lifted out of `install.ps1` and run against temp Windows
Terminal settings files — a user-defined scheme, a built-in one, a redefined built-in, a scheme on
`profiles.defaults`, the older flat `profiles` list, a profile that follows the OS theme, and eleven
ways the chain can break — and then the switch itself runs with both `USERPROFILE` and `LOCALAPPDATA`
redirected, so a light scheme writes `"palette": "light"`, Campbell writes `dark`, and a missing,
broken, unknown or OS-following scheme leaves `statusline.json` byte for byte as it was. The light
palette's own group recomputes every contrast ratio in both tables from the xterm colour cube, and
holds each of them to a 3:1 floor for every inline marker inside every block it can be drawn in. The subagent group pipes every payload in
`samples/subagent/` through `subagent-statusline.ps1` and reads the replies the way the panel does:
each line must be an object with a string `id` and a string `content`, every id must belong to a task
in the payload, every row must be one line carrying that style's own glyph, and it must fit the
payload's `columns` down to a single column — all of it once per `-Style` × `-Palette` pairing, the way
the main matrix runs styles and palettes. It also checks that malformed, empty, array-shaped and
task-less payloads print nothing and still exit 0, that an argument value the panel does not know falls
back to the default row instead of throwing, and that the helpers `subagent-statusline.ps1`
copies out of `statusline.ps1` are still the same text in both files. Its own install cases run
`install.ps1 -Subagents` and `-Uninstall` against a second temp home. The ownership rules are checked
against the forms that must not count as ours as well as the ones that must: a command that carries
the path as a wrapper argument or in a trailing comment, one with something chained after it, one
using `-Command`, one carrying a switch or a value the installer never writes, and a file where the
marker token appears only inside another line, in a string
literal, in a trailing comment or below the header window. Beyond that: an install over a file that is
not ours is refused and changes nothing, a profile whose path holds a space and an `&` produces a
command that really runs under cmd, a settings write that cannot complete leaves the old file intact
and no temporary file behind, a file changed between the read and the write is refused, a second
installer holding the lock makes this one write nothing, a `subagent-statusline.ps1.bak` and a file at
the rollback name that this project did not write both survive a reinstall and an uninstall, a foreign
file at `settings.json`'s own backup name or Windows Terminal's survives an install and an uninstall the
same way, the settings write it would have backed up still goes through, and the capture helper bounds a
single payload larger than its own cap. The render matrix pipes every payload in
`samples/` through the script for each of seven configs (both layouts and styles, model only, a
reversed `order`, swapped `rows`) at each width:

```powershell
.\test.ps1                                # full run, about twelve minutes on a quiet machine
.\test.ps1 -Columns 80                    # one width instead of 120, 60, 20 and unset
.\test.ps1 -Config .\statusline.json      # one config instead of the seven
.\test.ps1 -Raw                           # show ANSI escapes as <ESC>
```

Every render must exit 0 with nothing on stderr, print the number of lines its layout allows, and fit
the terminal width. At a set width a segment with a short form (limits, context, branch, folder,
badges) must be whole, shortened, or gone, never half shed. At the unset width the matrix also checks
content: each segment the sample and config enable must appear on its row, in the configured order,
with its glyph and value, disabled segments must not, and the separators must match the style. Those
content checks only run when `-Columns` includes `0`, which the default does. The `ascii` style gets a
pass of its own rather than an eighth config: every sample once at the unset width, against its own
marker table, plus the assertion the matrix cannot make — that every non-ASCII character on the line
came from the payload, and that no stand-in left an empty space behind it. One more render puts a
non-English name in every text field the line can draw from and pins the set exactly: the only
characters outside ASCII are the ones the payload supplied, which is what says the style replaced the
script's glyphs and nothing of the user's. A few renders after the
matrix run with no `-Config` at all: they point a payload at a temp project directory and check that
its `.claude\statusline.json` reaches the line, that a broken one does not, and that `-Config` ignores
it. The taskbar sequence is checked by rendering each payload twice, once with `"taskbar": true` and
once with it off, and comparing the two: the key off must write no sequence at all, the key on must
write exactly one, at the very front, with every byte behind it and every line's measured width
unchanged. A payload that will not parse, a render with no line in it and a render at 92% each get a
case of their own. The script exits non-zero if any check fails. Each render takes about 400 ms,
nearly all of it `pwsh` start-up.

The tests never touch your own repositories. They point `GIT_CEILING_DIRECTORIES` at the temp
folder and pass an empty global git config, so the results do not depend on the machine.

To try a payload of your own:

```powershell
Get-Content my-payload.json -Raw | pwsh -NoProfile -File .\statusline.ps1
Get-Content my-payload.json -Raw | pwsh -NoProfile -File .\statusline.ps1 -Config .\docs\statusline-two-line.json
Get-Content .\samples\subagent\01-two-agents.json -Raw | pwsh -NoProfile -File .\subagent-statusline.ps1
Get-Content .\samples\subagent\01-two-agents.json -Raw | pwsh -NoProfile -File .\subagent-statusline.ps1 -Style ascii -Palette light
```

## Customising the script

Segment order, the two rows, the colour cut-offs and the glyphs are `statusline.json` keys, described
in the [configuration reference](configuration.md#keys). What is left sits at the top of `statusline.ps1`:

- `Get-IconDefault` holds the built-in code point of every glyph, under the name the `icons` key takes. The [Nerd Font cheat sheet](https://www.nerdfonts.com/cheat-sheet) lists alternatives. `Get-IconAscii` holds the ASCII stand-in for each of the same names, and `Get-MarkSet` the characters that are not icons — the meter cells, the minus, the clock's separator, the pace arrows and a clipped name's tail.
- How long the branch segment waits for `git status` is `git.timeoutMs` in `statusline.json`, not a constant in the script.
- `$defaultEffort` is the level at which the effort badge is hidden.
- The 70% and 90% cut-offs of a 1M window are passed by the context block to `Get-ThresholdRole`; `thresholds` does not move them. The `alarm` percentages are separate from both: `Test-AlarmState` reads the payload directly, so it does not care about the window size or about which segments are switched on.
- `Get-WholePercent` is the one rule that turns a payload figure into the percentage on the line. The context meter, the limits figures, the cached share, the colour bands and the alarms all go through it, so a fractional percentage cannot print as 90% in one segment and count as 89% in another. It rounds half to even, which is what the casts it replaced already did. The cached share is computed from token counts rather than read as a percentage, and it still goes through the same rule: it prints beside the meter's own percentage, and two rounding rules on one segment is the disagreement this function exists to rule out.
- `Get-Palette` holds the colours for both palettes; `ascii` uses the same ones role for role. `subagent-statusline.ps1` carries its own copy of it and of `Get-MarkSet`, pinned to these by the drift gate, and takes the style and the palette as `-Style` and `-Palette` arguments because it has no config file to read.
- `Get-SegmentRegistry` is the segment table. Its array order is the default `order`, `Row` and `RowRank` give the default `rows`, `Default` says whether a segment is on before any config is read, and `ShrinkRank` and `DropRank` set the fitting order, which the config does not change. What the config does change is which segments leave that order for the right edge, under `right`.

## Adding a segment or a sample

The analyzer settings exclude the Write-Host rule, which a status line cannot avoid, and the
positional-parameters rule, because the script and its tests call their own small helpers
positionally. If you add a segment or a sample, add a payload to `samples/` and give it a row in the
`$sampleSegments` and `$sampleMarkers` tables in `test.ps1` (which segments it shows, and the glyph
and value to look for). A sample without those rows fails the run by name. A sample with a segment
that has a short form, such as a branch with counts or a folder with a repository, also needs an
entry in `$sampleShortForms`, the full and shortened text the matrix accepts at a set width, unless
its full text cannot fit at 120 columns, as sample 06's limits line does with every badge on.
A sample whose percentages reach the `alarm` level needs its name in `$alarmSamples` as well: the
markers are plain text and cannot see a colour, so that list is what tells the matrix whether the
model segment should be red or cyan, and it checks both.
Then regenerate the two screenshots at the top of the [README](../README.md) with
`pwsh docs/render-screenshot.ps1` and
`pwsh docs/render-screenshot.ps1 -Config docs/statusline-two-line.json -Out docs/statusline-two-line.png`.
Both PNGs are regenerated by hand rather than in CI. The script pins the render's clock with
`CLAUDE_STATUSLINE_NOW` (see [docs/diagnostics.md](diagnostics.md)), so the two countdowns and the wall
clock in the two-line shot are the same on every run and in every zone. Regenerating on the machine
that regenerated them last, with no other change, leaves `git status` clean; a binary diff on either
PNG then means the rendering really moved.

What is pinned is the text of the render, not the image. The pixels come from GDI+, the display's DPI
and ClearType settings, the installed version of JetBrainsMono NF and the Windows build, so the same
line drawn on another machine can still land on different bytes. Regenerate on one machine, or expect
the diff to be the rasteriser rather than the change.
