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
| between segments | dim chevron in `plain`, solid arrow in `powerline` | `>` |
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
of them the table below says so and why. Two of the rules are not contrast ratios at all but
straight-line distances in sRGB, because a ratio cannot answer the question they ask — see the note
under the table.

| Rule | Bar | Light table | Dark table |
|---|---|---|---|
| A plain-style colour against the terminal's background | 4.5:1 on `#FFFFFF` **and** on an off-white `#F5F5F5` | worst 5.25 (`warn`) | not asserted — the plain codes are the basic sixteen, and what those look like is the terminal's to say |
| A powerline block's own text against its own background | 4.5:1 | worst 10.40 (`folder`) | worst 4.70 (`ok`); `model` is 4.13 and exempt by name, older than the rule |
| A block's background against the terminal's background — the trailing arrow paints it as a *foreground*, and every block edge is that boundary | 1.7:1 | worst 1.75 (`bad`) | worst 2.01 (`dim`) against Campbell |
| The arrow *between* two blocks — one block's background painted on the next one's | 1.10:1 in luminance and 40 apart in sRGB, over every ordered pair | 40.3 apart; the luminance half is **not** asserted, and `ok`/`warn` is 1.00 — a real gap, tracked separately | worst 1.104 and 40.0 |
| An inline marker (`+156`, `92% cached`, `1M`, `↑2`) against the background of the block it sits in | 3:1 | worst 3.48 | worst 3.01 |
| The same marker against that block's **own text**, which it sits beside | 85 apart in sRGB | worst 95.0 | worst 89.6 |
| An inline marker on the terminal's background in plain style | 4.5:1 | worst 7.03 | not asserted, same reason as the first rule |

**Why two of those bars are distances and not ratios.** An inline marker sits inside a block, so it has
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

The plain-style colours are 256-colour codes rather than the basic sixteen on purpose. The sixteen are
whatever your terminal's scheme says they are, which is the thing that goes wrong on a light theme in
the first place; a table that cannot say what a colour looks like cannot promise it is readable.

To check a value by hand: the indices 16–231 are a 6×6×6 cube on the levels 0, 95, 135, 175, 215, 255
(so index `24` is `16 + 0×36 + 1×6 + 2`, giving `#005F87`), and 232–255 are a grey ramp at `8 + 10n`.
Put the hex into any contrast checker against `#FFFFFF`.

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
