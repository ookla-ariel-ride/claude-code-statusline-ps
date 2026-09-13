# Styles and palettes

`style` is the shape of the line and `palette` the colours it is drawn in. The three styles and the
two palettes are separate axes, so all six pairings work.

## ASCII style

Every icon on the line is a Nerd Font code point, so on a terminal without one the line is a row of
boxes. `{"style": "ascii"}` draws every glyph the script chooses in printable ASCII instead and keeps
every colour, for the VS Code terminal, a session over SSH, or anywhere the font is not yours to
change.

```
Fable 5.1 > ctx 32% ###....... 64k/200k 92% cached > $1.07 > 1h12m | api 38%
  > +156 -23 > 5h 24% = (2h11m) 7d 88% > fast think xhigh NORMAL > dir my-project > ~ main
```

The rule for each stand-in, in order: nothing at all where what follows already names the segment; a
mark ASCII already uses for the thing where there is one; otherwise the shortest lower-case
abbreviation, cut to a single letter where the segment's own text carries the word.

| Element | Nerd Font | ASCII |
|---|---|---|
| model, cost, clock, time, lines, limits, effort, vim | robot, cash, stopwatch, wall clock, code, tachometer, speedometer, vim | nothing — the name, the `$1.07`, the `1h12m`, the `14:05`, the `+156 -23`, the `5h 24%`, the level and the mode say it |
| context | memory | `ctx` |
| context bar, filled and empty | `█` `░` | `#` `.` |
| cache | fire | `c` |
| folder | folder | `dir` |
| owner/name to leaf | `›` | `/` |
| branch | branch | `b` |
| main or master | home | `~` |
| dirty tree | pencil | `*` |
| worktree | fork | `wt` |
| ahead, behind | `↑` `↓` | `^` `v` |
| conflicts, past 200k | warning triangle | `!` |
| pull request | pull request | `pr` |
| fast mode, thinking | bolt, brain | `fast`, `think` |
| agent, session name | user, tag | `@`, `#` |
| removed lines | `−` | `-` |
| clock's api share | `·` | `\|` |
| pace on track, overrunning | `→` `↑` | `=` `^` |
| clipped name | `…` | `.` |
| between segments | dim chevron in `plain`, solid arrow in `powerline` — or the thin chevron where two `powerline` blocks come out the same colour, see [the second shade](#the-second-shade) | `>` |
| subagent panel row | robot | `@` |

Two things follow from ASCII being the promise rather than "no Nerd Font". Everything the script
chooses is drawn from U+0020 to U+007E, which is both the range every font has and the range every
terminal draws one cell wide — the second half matters, because the width fitting counts a meter block
or an arrow as one column and some terminals draw them as two. And an `icons` override is a code point,
so it is ignored in this style; set the style back to `plain` if you want your own glyph. Colours,
thresholds, layout, segment order and fitting are exactly as they are in `plain`.

**Your own text is left alone.** The branch, the folder, the repo owner, the model name and the agent
and session names come from the payload and are drawn as they arrived, in this style as in the other
two — so a branch called `機能/x` renders `b 機能/x`, not `b ????`. This style replaces the glyphs
*the script picked*, which live in the private use area and need a font your terminal may not have. A
Japanese branch name needs a Japanese font, which most terminals do have, and it is your data either
way: a name shown as boxes at least tells you a font is missing, where one silently transliterated
tells you nothing and cannot be read back.

**The agent panel too, at install time.** The panel reads no config file, so `.\install.ps1 -Subagents`
puts `-Style ascii` on the command it writes when that is what the status line is set to. A panel row
has only two characters of its own — the robot glyph and the tail on a clipped name — and they become
`@` and `.`. The `@` is this table's own mark for a person driving a thread, which is what a panel row
is; the `model` row above is empty for a reason that does not hold there, because on the main line the
model's name follows the glyph and on a panel row the glyph is the one thing that always survives. See
[Style and palette in the panel](agent-panel.md#style-and-palette).

## Tint ownership

`tint` chooses who owns a segment's resting colour; it is independent of both `style` and
`palette`. The default, `{"tint": "role"}`, keeps the seven role colours the line has always
used. That is why resting context, cache and limits can share one colour, and why the renderer
alternates a role where two of those segments become neighbours.

`{ "tint": "segment" }` assigns a separate measured colour to each of the twelve resting segments.
It does not alternate a repeated resting role because the segment names already make the resting
colours distinct. Semantic state wins: a `warn` or `bad` context, cache, limits, or model alarm remains
the role's yellow or red, so a useful alert never becomes merely a segment hue.

Each segment table is measured on both palettes: every resting foreground is measured against both
plain-style grounds, every foreground against its own powerline background, every inline marker
against every block it can inhabit, and every resting segment pair at **1.05:1 luminance and 40 sRGB**.
The renderer then measures the resolved pair actually painted at every powerline joint — resting
segment beside resting segment, or beside `warn`, `bad`, or an alarm — on both palettes. It draws an
arrow only when that pair clears the stricter **1.10:1 luminance and 40 sRGB** floor; otherwise it
draws the measured, readable divider. Segment plain codes are also kept at least 40 sRGB from the
semantic warn, bad, and alarm codes, so a healthy resting segment cannot impersonate an alert.

## Light palette

The colours the line has always used are chosen for a dark terminal. On a pale background a bright
cyan model name is barely there and the dim grey chevron is close to invisible. `{"palette": "light"}`
swaps the whole table for one chosen against white.

```json
{ "palette": "light" }
```

`palette` and `style` are separate keys because they answer separate questions. `style` is the
**shape** of the line — coloured words with a chevron, solid blocks with arrows, or the same shape in
characters any font has. `palette` is the **colour numbers** those shapes are drawn with, and the only
thing it depends on is whether the terminal's background is dark or light. All six pairings are real
configurations:

| | `dark` | `light` |
|---|---|---|
| `plain` | what the line has always been | the same chevron, in colours that read on white |
| `powerline` | near-white text on saturated blocks | near-black text on pale blocks |
| `ascii` | the ASCII characters, dark colours | the ASCII characters, light colours |

`ascii` with `light` needs no special case in either direction: a colour code is digits and
semicolons, so a palette can never put a non-ASCII character on the line, and the ASCII style never
touches a colour.

**How the colours were chosen, and how to check them.** The light table is not the dark one with
darker numbers. Every value in it is an xterm 256-colour index picked to clear a contrast ratio, and
the ratios are checked by arithmetic in `test.ps1` rather than by eye — an index is turned into its hex, and the hex
into a [WCAG 2.1](https://www.w3.org/TR/WCAG21/#dfn-relative-luminance) contrast ratio, by code that
shares nothing with the script. **Both tables are measured**, and where a bar is asserted for only one
of them, or differs between them, the table below says so and why. Three of the rules include straight-line distances in sRGB, because a ratio cannot answer the question they ask — see the note
under the table.

Every rule below runs over **every shade a line can paint**, which since the second shade (below) means
the seven role backgrounds *and* the alternates — ten colours in the dark table. An alternate is
measured exactly as a base is, and several of the dark table's worst figures are now an alternate's.
The light table has seven: holding its arrow rule to 1.10:1 spends every step its other bars leave, so
its backgrounds cannot carry a second shade at all and its repeated roles take the divider instead.

| Rule | Bar | Light table | Dark table |
|---|---|---|---|
| A plain-style colour against the terminal's background | 4.5:1 on `#FFFFFF` **and** on an off-white `#F5F5F5` | worst 5.25 (`warn`); the three **alternate** codes are held to it too, worst 6.17 (`warn` alt on `#F5F5F5`) | the six hue bases are the basic sixteen and are not asserted; `dim` is `251` and its `254` alternate is also held to it: worst 6.48 (`bad` alt on `#002B36`), while `dim` is 8.79 and 11.81 on Solarized Dark |
| A powerline block's own text against its own background | 4.5:1 | worst 9.14 (`folder`) | worst 4.70 (`ok`); `model` is 4.13 and exempt by name, older than the rule |
| A block's background against the terminal's background — the trailing arrow paints it as a *foreground*, and every block edge is that boundary | 1.25:1 light, 1.7:1 dark, and 80 apart in sRGB on both — the one ratio bar that differs, and the note under the table says what bought it | worst 1.25 (`model`), 81.4 sRGB (`dim`) | worst 2.01 (`dim`) against Campbell, 84.7 sRGB (`ok` alt) |
| The arrow *between* two blocks — one block's background painted on the next one's | 1.10:1 in luminance and 40 apart in sRGB, over every pair that can meet | worst 1.101 (`bad`/`dim`) and 56.6 | worst 1.104 and 40.0 |
| An inline marker (`+156`, `92% cached`, `1M`, `↑2`) against the background of the block it sits in | 3:1 | worst 3.06 (`muted` in `folder`) | worst 3.01 |
| The same marker against that block's **own text**, which it sits beside | 85 apart in sRGB | worst 95.0 | worst 89.6 |
| An inline marker on the terminal's background in plain style | 4.5:1, on the two grounds each palette has: `#FFFFFF` and `#F5F5F5` for light, Campbell `#0C0C0C` and Solarized Dark `#002B36` for dark | worst 6.45 (`muted`) | worst 4.95 — `track` and `cached` are both 246; the other three markers are hues on the basic sixteen and are not asserted |
| An alternate shade against the base it alternates with | within 20° of hue, on top of every rule above | 18° at worst (`warn`'s plain code, an amber to a darker olive-amber) | 8° at worst (`warn`'s block) |

**Why the light bar against the terminal's background is 1.25 where the dark one is 1.7.** It is the
one figure in the table that differs between the two palettes, and the smaller number was bought
rather than dropped ([#89](https://github.com/ookla-ariel-ride/claude-code-statusline-ps/issues/89)).
The arrow *between* two blocks needs 1.10:1, so seven backgrounds have to spread over a luminance
span of 1.10⁶ = 1.7716:1. The light table's other rules leave less room than that. The brightest of the
inline markers — `muted` `#005F87`, at 0.0993 — has to clear 3:1 inside every block, which floors every
light background at 0.398 relative luminance; 1.7:1 against white put a ceiling on them at 0.568. That
is a band of 1.3786:1,
and at most four of seven values can sit 1.10 apart inside it — arithmetic, not tuning, so no
assignment exists in the 256-colour cube or in 24-bit colour either, since the band is set by the
rules and not by how many colours there are to pick from. One of the three bars had to give, and this
is the one whose cost lands on a saturated hue rather than on a marker both tables share: the light
block that sets 1.25 is `model` `#00FFFF`, whose edge against white is carried by chroma where its
luminance is nearly white's, and the palest *neutral* in the table is still `dim` `#D0D0D0` at 1.54. The
same rule also keeps every background at least 80 sRGB from its terminal ground: the current minimum is
light `dim` at 81.4, so pale neutral blocks cannot turn the arrow into an almost-white edge.
The dark table is untouched and keeps 1.7. The same arithmetic is what leaves the light table with no
second block shade at all — see [the second shade](#the-second-shade).

**Why three of those bars are distances and not ratios.** An inline marker sits inside a block, so it has
two neighbours: the block's background behind it, and the block's own text beside it. On a dark block
those two pull against each other. Clearing 3:1 against the `model` block means the marker's relative
luminance has to be above 0.71 — and the block's text is white, luminance 1.0. So every colour that is
readable there is within 1.38:1 of the text, and no luminance bar can tell "readable and distinct" from
"readable and indistinguishable from the figure it qualifies". What separates them is hue, which a
distance measures and a ratio does not. That is why the dark table's quiet markers are pale cyans
rather than greys, and why `−N` is a warm apricot rather than red: with red at full, green has to reach
215 before the luminance is high enough to be legible on that block, and `#FFD787` is the reddest
colour that exists up there. A true red survives inside the light `warn` block, where the block is
light and its text is black, so the marker can go dark instead — which is the same reason each marker
carries two colours and the block's own text colour picks between them.

**The light table's plain-style colours are 256-colour codes rather than the basic sixteen on purpose,
all twelve of them.** The sixteen are whatever your terminal's scheme says they are, which is the thing
that goes wrong on a light theme in the first place; a table that cannot say what a colour looks like
cannot promise it is readable. The dark table still leaves its six hue roles to the terminal — and makes
the measured neutral exception explicit.

**Why the dark table's markers stayed at 246 and `dim` moved.** `track` and `cached` — the `92% cached`
suffix and the `↑2 ↓1 +3 ~1 ?2` branch counts — were moved from `90`, bright black, to `246` (`#949494`)
by #88: the lowest grey ramp index that clears 4.5 on Campbell and Solarized Dark alike. #111 found the
same 2.79:1 Solarized-Dark failure in the `dim` role: the chevron and cost, clock, time, lines, and
badges text. `dim` is now `251` (`#C6C6C6`), 8.79:1 on Solarized Dark; its alternating code is `254`
(`#E4E4E4`), 11.81:1. They are 52.0 sRGB apart. The `dim` role never shares a segment with `track` or
`cached`: `cached` is context-only, `track` branch-only, and dim segments carry added/removed markers
or plain text. No distance rule applies between dim and either marker. The other six dark role codes —
`1;36`, `32`, `33`, `31`, `34`, `35` — remain terminal-scheme hues: a scheme's tuned hue is preferable
to turning that visual choice into a fixed cube colour.

**What that costs on the one configuration it is not for.** `dark` is the default, so somebody on a
*light* terminal who never set `palette` gets this table anyway. There `dim` `251` (`#C6C6C6`) is
**1.71:1** on white and **1.58:1** on Solarized Light's `#FDF6E3`; alternate `254` (`#E4E4E4`) is
**1.27:1** on white. By comparison, SGR `90` was Campbell bright black `#767676`, **4.54:1** on white.
A dark table on a light ground is out of contrast either way. A light terminal using the default palette
should set `"palette": "light"`, or run `.\install.ps1 -DetectTheme` and let it read the terminal
background. Every bar in this page is measured against the ground its own table is for.

To check a value by hand: the indices 16–231 are a 6×6×6 cube on the levels 0, 95, 135, 175, 215, 255
(so index `24` is `16 + 0×36 + 1×6 + 2`, giving `#005F87`), and 232–255 are a grey ramp at `8 + 10n`.
Put the hex into any contrast checker against `#FFFFFF`.

## The second shade

Seven distinct role colours are still one colour where the **layout** puts two segments of the same
role side by side, and the shipped two-line layout does exactly that. Its second row is context, cache,
limits, cost, clock, lines: while nothing is warning the first three are all `ok` and the last three
are all `dim`. A powerline arrow is the left block's background painted on the right block's, so
between two blocks of one background there is nothing to see — three green segments read as one band
and then three grey ones as another. In `plain` the same segments share one foreground code with only
the chevron between them.

Neither half of the problem can see the other. The contrast rules above measure every pair of *roles*
and cannot know that two adjacent *segments* carry the same one; the layout does not know the colours.
So the four roles a value moves between use a **second shade** wherever the table can supply one: dark
`ok`, `warn` and `bad` carry a second background for `powerline`; dark `dim` and light
`warn`, `bad` and `dim` carry a second code for `plain` and `ascii`. The light table has no
second background, and light `ok` is the measured plain-code exception below. A run of three with an
available shade reads base, alternate, base.

| Role | `dark` block | `dark` plain | `light` block | `light` plain |
|---|---|---|---|---|
| `ok` | 28 → **22** | `32` → **`38;5;114`** | 76 → none | `38;5;22` → none |
| `warn` | 178 → **214** | `33` → **`38;5;221`** | 221 → none | `38;5;94` → **`38;5;58`** |
| `bad` | 160 → **124** | `31` → **`38;5;210`** | 218 → none | `38;5;124` → **`38;5;88`** |
| `dim` | 238 → none | `38;5;251` → **`38;5;254`** | 252 → none | `38;5;240` → **`38;5;237`** |

**Which segments this reaches.** `ok`, `warn` and `bad` are the roles of context, cache, limits and the
pull request — whichever of them the thresholds put a segment in — and `dim` is cost, clock, time,
lines and badges. `model`, `folder` and `branch` have no second shade because each is the role of
exactly one segment, so no line can put two of them side by side.

**The shade moves the background, never the block's text.** A segment's text is built before there is
a line, so the inline markers inside it were already chosen by the role's ink and already close their
runs by handing that role's own foreground back; a second foreground would have to be threaded back
into finished text. What holds instead is that every marker clears its floors against the second
background too, which is where several of the dark table's worst figures above come from. In `plain`
the segment's own code *is* the thing that changes, so the hand-backs inside its text move with it —
otherwise the words after the first marker would revert to the base code and the segment would be two
colours.

**Where a joint has no second shade, it gets a divider.** Two neighbouring blocks that still come out
the same colour are drawn with the thin powerline separator in the block's own ink instead of an arrow
of one colour on itself. The rule is on the rendered backgrounds rather than on the roles, so it covers
a role with no alternate, a role no layout was expected to repeat, and any future pair that comes out
the same for a reason nobody has thought of. In `plain` there is nothing to fall back to: the chevron
was already between the two segments and it stays.

**Six absent cells, each measured rather than chosen.** Every alternate above had to clear every rule in
the table. Dark `dim` lacks one background, light `ok` lacks one plain code, and all four light
background cells are absent:

- **`dark` `dim` has no second background.** Its block is a grey wedged between its own light text at
  250 above and the terminal's ground below, which leaves a band of roughly 0.041 to 0.073 in relative
  luminance — and no *neutral* colour in the cube sits inside it while staying 40 sRGB from `#444444`.
  The only colour that clears every floor there is `#5F0087`, a purple, which is not a shade of grey.
  So the dark grey run — cost, clock, lines — is the case the divider carries.
- **`light` `ok` has no second plain code.** The mirror image: every green in the cube 40 sRGB away
  from `#005F00` is too light to hold 4.5:1 on a white ground. That pair keeps the chevron.

All three cube searches run in `test.ps1` rather than asserted as comments, so loosening a floor makes
the colour that has become available show up as a failure.

**The `light` block column is empty — all four cells, and this one was bought rather than found.**
[#89](https://github.com/ookla-ariel-ride/claude-code-statusline-ps/issues/89) made the arrow rule hold
every pair of light backgrounds a line can paint to 1.10:1, an alternate against every base included,
and the seven bases then spend the whole band the marker floor and the 1.25 ground bar leave them:
1.7716:1 out of 1.8750:1. Their widest interior gap is 1.1118 where an eighth value needs 1.21 to sit
between two of them; there is 1.0204 of headroom under `folder`, the darkest of them; and a shade a step
above `model` would be 1.1399:1 against white where the ground bar asks 1.25. A run of alternates costs
exactly one more 1.10 step however long it is, because two alternates never touch, so the light ground
bar at which the first one could fit is 1.20269 — and at 1.20 the cube still offers nothing for any of
the seven roles. `test.ps1` walks the cube for this too, in one loop rather than seven, because what
rules a colour out does not depend on the role: an alternate meets *every* base, not only its own.

Every repeated light role takes the divider instead, and here that is the better joint rather than a
consolation. A chevron in the block's own ink is 9.14:1 or better on a light block, where the four
shades that fitted the old backgrounds measure 1.008 to 1.022 against the new ones — the invisible
arrow the rule exists to close.

**The plain alternates are 256-colour indices in both tables.** Six dark bases remain basic-sixteen
hues, but dim is indexed because its terminal-defined bright black could not promise contrast. A colour
chosen now has no reason to be a theme's own green, and one concrete reason not to be: Solarized Dark
maps the bright half of the sixteen onto greys, so `32` beside `92` there would be a green beside a grey
rather than a green beside a lighter green. The `dim` role never shares a segment with the `track` or
`cached` markers, so [#111](https://github.com/ookla-ariel-ride/claude-code-statusline-ps/issues/111)
does not apply a distance rule between them.

**Every layout is walked.** `test.ps1` builds every sample through the real segment builders, lays them
out with both layouts *and* all three presets, renders each row in both palettes and all three styles,
and then reads the joints back out of the rendered line and holds each to the floor above. A segment
can be absent — no cache block, no lines, no pull request — so which segments end up next to each other
is decided from the records actually on the line rather than from the registry, and the walk covers the
lines a payload really produces. The render matrix does the same to the output of the script itself, at
every width, which brings in the neighbours that only appear once fitting has dropped a segment.

**The agent panel is unaffected.** It draws one row per agent with nothing joined to anything, so there
is no joint to part; it carries the same colour table because a drift gate compares the two copies as
text.

**Letting the installer decide.** `.\install.ps1 -DetectTheme` reads Windows Terminal's
`settings.json`, follows `defaultProfile` to a profile, that profile's `colorScheme` to a scheme, and
the scheme to its `background`, then computes the background's relative luminance and writes `light`
above 0.5 and `dark` below. Every scheme Windows Terminal ships is under 0.05 or over 0.85, so the cut
sits in an empty band.

**That is a read of a configuration file, not a look at your screen.** Terminals
do not reliably report their own background — `COLORFGBG` is not universal and an OSC 11 query needs a
reply that may never come — so there is nothing here to probe. If you run Claude Code in conhost, in
VS Code, over SSH, or in a Windows Terminal profile that is not the default one, `-DetectTheme` has
read a file about a different terminal. That is why it prints the scheme name it found beside the
palette it chose, and why the answer is one key you can edit.

When any link in the chain is missing it **writes nothing and prints why**:

- no Windows Terminal settings file, or one that will not parse;
- no `defaultProfile`, or no profile carrying that guid and no `colorScheme` on `profiles.defaults`;
- a scheme that is neither defined in the file nor one of the nine Windows Terminal ships;
- a `colorScheme` set to an object with `light` and `dark` members, which means the profile follows
  the OS theme. Both scheme names are printed. Nothing in the settings file says which is in force, so
  there is no answer to give, and a coin toss between the readable palette and the unreadable one is
  worse than leaving the key alone.

Leaving it alone is safe because the palette already defaults to `dark`: a detection that fails
changes nothing, and the failure is one line of output rather than a line you cannot read.

**The agent panel follows, but only at install time.** `subagent-statusline.ps1` still reads no config
file — it takes a payload on stdin and answers — so the palette reaches it as a `-Palette` argument the
installer bakes into the `subagentStatusLine` command, from this same key. That is
[#78](https://github.com/ookla-ariel-ride/claude-code-statusline-ps/issues/78), which did the same for
`style`. Change the key by hand and the bar follows on the next render while the panel keeps what it
was installed with; run `.\install.ps1 -Subagents` again to bring the panel along. See
[Style and palette in the panel](agent-panel.md#style-and-palette).
