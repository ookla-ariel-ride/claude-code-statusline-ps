# claude-code-statusline-ps

A single-file PowerShell status line for [Claude Code](https://code.claude.com) on Windows. Nerd Font
glyphs, ANSI colour, no dependencies beyond PowerShell 7.

```
󰚩 Fable 5.1  󰍛 8% █░░░░░░░░░ 17k/200k  󰅕 $0.43   my-project   main
```

| Segment | Shows |
|---|---|
| 󰚩 model | active model, bold cyan |
| 󰍛 context | percent used, ten-segment bar, **used/total tokens**; green < 60%, yellow < 85%, red above |
| 󰅕 cost | session cost, dimmed |
|  folder | current directory name |
|  /  branch |  home glyph on `main`/`master`,  branch glyph elsewhere; yellow with a  pencil when the tree has uncommitted changes |

Segments whose data is absent from the payload are simply omitted, so it degrades to just the model
name (or `claude`) on unusual input.

## Install

```powershell
git clone https://github.com/<you>/claude-code-statusline-ps
cd claude-code-statusline-ps
.\install.ps1 -InstallFont -ConfigureWindowsTerminal
```

`install.ps1` copies `statusline.ps1` to `~/.claude/`, adds this to your **user-level**
`~/.claude/settings.json` (all other keys preserved):

```json
"statusLine": {
  "type": "command",
  "command": "pwsh -NoProfile -NoLogo -NonInteractive -File C:/Users/<you>/.claude/statusline.ps1",
  "padding": 0
}
```

`-InstallFont` installs **JetBrainsMono Nerd Font** through winget (one elevation prompt);
`-ConfigureWindowsTerminal` sets Windows Terminal's default font to `JetBrainsMono NF` and keeps a backup
of its settings. Any Nerd Font works; if you run Claude Code in another terminal (VS Code, ConEmu), set its
font there. `.\install.ps1 -Uninstall` reverses the settings change.

## Test without Claude Code

```powershell
.\test.ps1          # renders every payload in samples/
.\test.ps1 -Raw     # shows ANSI escapes as <ESC>
```

Each run takes roughly 250 ms (pwsh start-up), which is fine for a status line that refreshes on
events rather than continuously.

## How it works

Claude Code pipes a JSON document to the command on stdin (fields documented at
https://code.claude.com/docs/en/statusline). The script reads `model.display_name`,
`context_window.{used_percentage,total_input_tokens,total_output_tokens,context_window_size}`,
`cost.total_cost_usd`, `workspace.current_dir` and `git.{branch,status}`, and prints one line.

Glyphs are emitted from Unicode code points (`[char]::ConvertFromUtf32`) rather than pasted into the
file, so the script's own encoding can never corrupt them, and stdout is forced to UTF-8.

## Customise

Everything is at the top of `statusline.ps1`: the glyph code points, the separator, and the colour
thresholds. Nerd Font code points: https://www.nerdfonts.com/cheat-sheet.

## License

MIT
