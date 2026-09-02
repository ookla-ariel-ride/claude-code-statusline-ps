# Layout, Width Fitting, Powerline Style, and Config File Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `statusline.ps1` a `statusline.json` config (layout, style, segment toggles), a two-line layout, width fitting from `COLUMNS`, a powerline separator style, and a real `git status` fallback for the branch segment, with `test.ps1` covering all of it.

**Architecture:** `statusline.ps1` stays a single file. It gains a set of pure functions (config reader, palette, renderer, width measurer, fitter, porcelain parser) above a main section that builds one hashtable record per segment, splits them into lines by layout, and fits each line to the terminal width. `test.ps1` extracts those pure functions from the script by parsing its AST and dot-sourcing the function definitions, so they get unit tests without running the script; a render matrix and a git integration group run the script as a child `pwsh`.

**Tech Stack:** PowerShell 7 only (no modules), .NET `System.Diagnostics.Process` for git, `System.Globalization.StringInfo` for width, PSScriptAnalyzer for linting, `System.Drawing` for the screenshot renderer.

**Spec:** `docs/superpowers/specs/2026-09-01-layout-and-config-design.md`

## Global Constraints

- `#Requires -Version 7.0` on every script. No modules imported anywhere.
- `statusline.ps1` keeps `$ErrorActionPreference = 'SilentlyContinue'` and never writes to stderr. A broken config, a missing git, or a hung git must never break the status line.
- With no config file the plain one-line output must show the same characters and colours as today (escape bytes may differ).
- Glyphs come from code points via `[char]::ConvertFromUtf32`, never pasted characters. This applies to test strings too (CJK, emoji).
- `.ps1` files are CRLF (`.gitattributes`), everything else LF.
- Every changed `.ps1` passes `Invoke-ScriptAnalyzer -Settings .\PSScriptAnalyzerSettings.psd1` with no output. Avoid the verbs `New`, `Set`, `Remove`, `Start`, `Stop`, `Reset`, `Update` on function names (they trigger the ShouldProcess rule). Single-word helper names like `G`, `C`, `K` are fine.
- File paths given to the Edit/Write tools use backslashes.
- Git timeout constant: `$gitTimeoutMs = 1500`. Width target: `COLUMNS - 1`.
- Commit messages follow the repo's style (imperative sentence, no conventional-commit prefix) and end with the two trailer lines below. Commit from the Bash tool with a heredoc into `git commit -F -`, because PowerShell here-strings and `git commit -m` mix badly here:

```bash
git commit -F - <<'EOF'
<subject line>

<body>

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FpwyeW4r1Bay98JfkxVT9F
EOF
```

- The gitleaks pre-commit hook runs on every commit; it is expected to pass.

## Deviations from the spec (decided while planning, keep unless the user objects)

1. **Powerline segment SGR starts with `0;`.** The spec writes `ESC[48;5;<bg>;38;5;<fg>m`. Without a reset the model segment's bold leaks into every later segment. Each powerline segment therefore starts `ESC[0;48;5;<bg>;38;5;<fg>m` (`ESC[0;1;48;...` when bold). The between-segment arrow sequence is unchanged.
2. **Stdout drain uses `ReadToEndAsync`, not `BeginOutputReadLine`.** A PowerShell script block attached to `OutputDataReceived` runs on a thread-pool thread with no runspace and fails. `$p.StandardOutput.ReadToEndAsync()` drains the pipe on a .NET thread with no PowerShell involvement, which satisfies the spec's reason for draining (no deadlock on large output). Stderr is drained the same way and discarded.
3. **git is resolved with `Get-Command git -CommandType Application` before `Process.Start`.** `CreateProcess` only appends `.exe` when searching `PATH`, so a bare `git` would never find the test's fake `git.cmd`. Passing the resolved full path makes the fake work and changes nothing for a real `git.exe`.
4. **Fallback line also covers "nothing printed".** If `model` is toggled off and every other segment drops for width, no line would print. The script prints the existing `claude` fallback in that case too.
5. **`docs/statusline-two-line.json` is committed.** It is the config `render-screenshot.ps1` uses for the second screenshot and doubles as a copyable example.

## File map

| File | Change |
|---|---|
| `statusline.ps1` | Add `-Config` param, constants, pure functions (`Read-StatusConfig`, `Get-VisibleWidth`, `Get-Palette`, `Format-Inline`, `Format-Line`, `Get-FittedLine`, `Read-PorcelainStatus`, `Get-GitBranch`), segment builders, layout and fitting main section. |
| `statusline.json` | New. The defaults. |
| `test.ps1` | Rewrite: assert helpers, AST function import, unit groups, render matrix (`-Columns`, `-Config`, `-Raw`), git group. |
| `install.ps1` | Copy config if absent; keep it on uninstall. |
| `docs/render-screenshot.ps1` | `-Config`, `-Out`, 256-colour and background parsing, multi-row output. |
| `docs/render-icons.ps1` | Add `arrow` glyph. |
| `docs/statusline-two-line.json` | New. Two-line powerline config for the screenshot. |
| `docs/statusline-two-line.png` | New. Generated. |
| `docs/icons/arrow.svg` | New. Generated. |
| `README.md`, `docs/projectbrief.md` | Docs. |

---

### Task 1: Test harness scaffolding and width measurement

**Files:**
- Modify: `statusline.ps1` (insert functions after line 30, `$defaultEffort = 'high'`)
- Modify: `test.ps1` (rewrite header, add helpers and unit group; keep the existing sample loop at the end)

**Interfaces:**
- Produces: `Get-VisibleWidth([string] $Text) -> [int]` in `statusline.ps1`. Strips `ESC[...m` and sums cell widths per spec section 4.
- Produces in `test.ps1`: `Assert-Equal($Actual, $Expected, $Label)`, `Assert-True([bool] $Condition, $Label)`, `ConvertTo-PlainText([string] $Text)`, `Import-ScriptFunction([string] $Path, [string[]] $Name) -> scriptblock`, `Measure-VisibleWidth([string] $Text)` (the test's own copy), `$esc`, `$script:passed`, `$script:failed`.

- [ ] **Step 1: Rewrite the top of `test.ps1` with helpers and the width unit group**

Replace the whole of `test.ps1` with this. The old sample loop is kept at the bottom, unchanged in behaviour, until Task 7 replaces it.

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS
  Tests statusline.ps1. Unit checks on its pure functions, then renders every sample in ./samples.
  Add -Raw to show ANSI escapes as <ESC> for inspection.
#>
[CmdletBinding()]
param([switch] $Raw)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSStyle.OutputRendering = 'Ansi'
$script = Join-Path $PSScriptRoot 'statusline.ps1'
$esc = [char]27
$script:passed = 0
$script:failed = 0

function Assert-Equal($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ceq "$Expected") { $script:passed++; return }
    $script:failed++
    Write-Host "FAIL $Label" -ForegroundColor Red
    Write-Host "  expected: $("$Expected" -replace $esc, '<ESC>')"
    Write-Host "  actual:   $("$Actual" -replace $esc, '<ESC>')"
}

function Assert-True([bool] $Condition, [string] $Label) {
    if ($Condition) { $script:passed++; return }
    $script:failed++
    Write-Host "FAIL $Label" -ForegroundColor Red
}

function ConvertTo-PlainText([string] $Text) { $Text -replace "$esc\[[0-9;]*m", '' }

# Pulls named function definitions out of a script by parsing it, so pure functions can be tested
# without running the script (which reads stdin and prints).
function Import-ScriptFunction([string] $Path, [string[]] $Name) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    if ($errors.Count -gt 0) { throw "parse error in ${Path}: $($errors[0].Message)" }
    $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $Name }, $true)
    $missing = @($Name | Where-Object { $_ -notin @($defs.Name) })
    if ($missing.Count -gt 0) { throw "functions not found in ${Path}: $($missing -join ', ')" }
    return [scriptblock]::Create((@($defs.Extent.Text) -join "`n"))
}

# The test's own copy of the cell-width rule from the spec, kept separate from the script's so a bug
# in one does not agree with itself in the other.
function Measure-VisibleWidth([string] $Text) {
    if (-not $Text) { return 0 }
    $plain = [regex]::Replace($Text, "$esc\[[0-9;]*m", '')
    $width = 0
    $en = [System.Globalization.StringInfo]::GetTextElementEnumerator($plain)
    while ($en.MoveNext()) {
        $el = [string] $en.Current
        $cp = try { [char]::ConvertToUtf32($el, 0) } catch { 0x3F }
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($cp)
        $zero = $cat -eq [System.Globalization.UnicodeCategory]::NonSpacingMark -or
                $cat -eq [System.Globalization.UnicodeCategory]::SpacingCombiningMark -or
                $cat -eq [System.Globalization.UnicodeCategory]::EnclosingMark -or
                ($cp -ge 0x200B -and $cp -le 0x200D) -or $cp -eq 0xFE0F
        if ($zero) { continue }
        $wide = ($cp -ge 0x1100 -and $cp -le 0x115F) -or ($cp -ge 0x2E80 -and $cp -le 0xA4CF) -or
                ($cp -ge 0xAC00 -and $cp -le 0xD7A3) -or ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or
                ($cp -ge 0xFE30 -and $cp -le 0xFE4F) -or ($cp -ge 0xFF00 -and $cp -le 0xFF60) -or
                ($cp -ge 0xFFE0 -and $cp -le 0xFFE6) -or ($cp -ge 0x20000 -and $cp -le 0x3FFFD) -or
                ($cp -ge 0x1F300 -and $cp -le 0x1F64F) -or ($cp -ge 0x1F680 -and $cp -le 0x1F6FF) -or
                ($cp -ge 0x1F900 -and $cp -le 0x1FAFF) -or ($cp -ge 0x2600 -and $cp -le 0x27BF)
        $width += if ($wide) { 2 } else { 1 }
    }
    return $width
}

# ---- Unit group: functions extracted from statusline.ps1 ----
. (Import-ScriptFunction $script @('Get-VisibleWidth'))

Write-Host '== unit: width' -ForegroundColor Cyan
$widthTable = @(
    @{ Text = 'abc'; Width = 3 }
    @{ Text = ''; Width = 0 }
    @{ Text = [char]::ConvertFromUtf32(0xF06A9) + ' Fable 5.1'; Width = 11 }          # Nerd Font glyph, PUA plane 15
    @{ Text = [char]::ConvertFromUtf32(0xE0B0) + [char]::ConvertFromUtf32(0xE0B1); Width = 2 }  # powerline arrows
    @{ Text = ([char]::ConvertFromUtf32(0x2588) * 3) + ([char]::ConvertFromUtf32(0x2591) * 7); Width = 10 }  # bar
    @{ Text = [char]::ConvertFromUtf32(0x65E5) + [char]::ConvertFromUtf32(0x672C); Width = 4 }  # CJK
    @{ Text = [char]::ConvertFromUtf32(0x1F680); Width = 2 }                           # emoji
    @{ Text = 'e' + [string][char]0x0301; Width = 1 }                                   # e + combining acute
    @{ Text = [string][char]0x0301; Width = 0 }                                         # lone combining mark
    @{ Text = "$esc[1;36mab$esc[0m $esc[90mc$esc[0m"; Width = 4 }                     # escapes stripped
)
foreach ($row in $widthTable) {
    $shown = $row.Text -replace $esc, '<ESC>'
    Assert-Equal (Get-VisibleWidth $row.Text) $row.Width "script width of '$shown'"
    Assert-Equal (Measure-VisibleWidth $row.Text) $row.Width "test width of '$shown'"
}

# ---- Sample renders (replaced by the matrix in a later task) ----
Write-Host '== samples' -ForegroundColor Cyan
foreach ($sample in Get-ChildItem (Join-Path $PSScriptRoot 'samples') -Filter *.json | Sort-Object Name) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = Get-Content $sample.FullName -Raw | pwsh -NoProfile -NoLogo -NonInteractive -File $script
    $sw.Stop()
    if ([string]::IsNullOrWhiteSpace($out)) { $script:failed++; Write-Host "FAIL $($sample.Name): empty output" -ForegroundColor Red; continue }
    $script:passed++
    $shown = if ($Raw) { $out -replace [char]27, '<ESC>' } else { $out }
    Write-Host ("{0,-40} {1,5:N0} ms  " -f $sample.Name, $sw.ElapsedMilliseconds) -NoNewline
    Write-Host $shown
}

Write-Host ''
Write-Host "passed $script:passed, failed $script:failed" -ForegroundColor $(if ($script:failed -gt 0) { 'Red' } else { 'Green' })
if ($script:failed -gt 0) { exit 1 }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: terminates with `functions not found in ...statusline.ps1: Get-VisibleWidth`, exit code 1.

- [ ] **Step 3: Add `Get-VisibleWidth` to `statusline.ps1`**

Insert after line 30 (`$defaultEffort = 'high'   # effort badge is hidden at this level`):

```powershell
$gitTimeoutMs = 1500      # how long the branch segment waits for `git status` before giving up

# Visible cell width of a rendered line: escapes stripped, combining marks 0, CJK and emoji 2, else 1.
# A small wcwidth approximation; Nerd Font glyphs count as 1.
function Get-VisibleWidth([string] $Text) {
    if (-not $Text) { return 0 }
    $plain = [regex]::Replace($Text, "`e\[[0-9;]*m", '')
    $width = 0
    $en = [System.Globalization.StringInfo]::GetTextElementEnumerator($plain)
    while ($en.MoveNext()) {
        $el = [string] $en.Current
        $cp = try { [char]::ConvertToUtf32($el, 0) } catch { 0x3F }
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($cp)
        if ($cat -eq [System.Globalization.UnicodeCategory]::NonSpacingMark -or
            $cat -eq [System.Globalization.UnicodeCategory]::SpacingCombiningMark -or
            $cat -eq [System.Globalization.UnicodeCategory]::EnclosingMark -or
            ($cp -ge 0x200B -and $cp -le 0x200D) -or $cp -eq 0xFE0F) { continue }
        if (($cp -ge 0x1100 -and $cp -le 0x115F) -or ($cp -ge 0x2E80 -and $cp -le 0xA4CF) -or
            ($cp -ge 0xAC00 -and $cp -le 0xD7A3) -or ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or
            ($cp -ge 0xFE30 -and $cp -le 0xFE4F) -or ($cp -ge 0xFF00 -and $cp -le 0xFF60) -or
            ($cp -ge 0xFFE0 -and $cp -le 0xFFE6) -or ($cp -ge 0x20000 -and $cp -le 0x3FFFD) -or
            ($cp -ge 0x1F300 -and $cp -le 0x1F64F) -or ($cp -ge 0x1F680 -and $cp -le 0x1F6FF) -or
            ($cp -ge 0x1F900 -and $cp -le 0x1FAFF) -or ($cp -ge 0x2600 -and $cp -le 0x27BF)) { $width += 2; continue }
        $width += 1
    }
    return $width
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: `== unit: width` with no FAIL lines, seven sample lines rendered, `passed 27, failed 0`, exit 0.

- [ ] **Step 5: Lint**

Run: `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path .\statusline.ps1, .\test.ps1 -Settings .\PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add statusline.ps1 test.ps1
git commit -F - <<'EOF'
Add visible-width measurement and a unit test harness in test.ps1

test.ps1 now parses statusline.ps1 and dot-sources named functions so pure helpers
get unit tests without running the script. Both the script's Get-VisibleWidth and
the test's own Measure-VisibleWidth copy are checked against a fixed table.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FpwyeW4r1Bay98JfkxVT9F
EOF
```

---

### Task 2: Config file and `Read-StatusConfig`

**Files:**
- Create: `statusline.json`
- Modify: `statusline.ps1` (add `param` block at top; add `Read-StatusConfig` after `Get-VisibleWidth`)
- Modify: `test.ps1` (extend the import list; add `== unit: config` group before the samples section)

**Interfaces:**
- Produces: `Read-StatusConfig([string] $Path) -> @{ Layout = 'one'|'two'; Style = 'plain'|'powerline'; Segments = @{ model = $bool; context; cost; lines; limits; badges; folder; branch } }`. Never throws.
- Produces: script parameter `-Config <path>`.

- [ ] **Step 1: Add the config unit tests to `test.ps1`**

Change the import line to:

```powershell
. (Import-ScriptFunction $script @('Get-VisibleWidth', 'Read-StatusConfig'))
```

Insert before the `# ---- Sample renders` comment:

```powershell
Write-Host '== unit: config' -ForegroundColor Cyan
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "statusline-test-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
function Write-TempConfig([string] $Name, [string] $Json) {
    $p = Join-Path $tmp $Name
    [System.IO.File]::WriteAllText($p, $Json, [System.Text.UTF8Encoding]::new($false))
    return $p
}
$allSegments = @('model', 'context', 'cost', 'lines', 'limits', 'badges', 'folder', 'branch')

$c = Read-StatusConfig (Join-Path $tmp 'does-not-exist.json')
Assert-Equal $c.Layout 'one' 'config missing: layout'
Assert-Equal $c.Style 'plain' 'config missing: style'
Assert-True (@($allSegments | Where-Object { -not $c.Segments[$_] }).Count -eq 0) 'config missing: all segments on'

$c = Read-StatusConfig (Write-TempConfig 'valid.json' '{ "layout": "Two", "style": "POWERLINE", "segments": { "cost": false, "lines": true } }')
Assert-Equal $c.Layout 'two' 'config valid: layout case-insensitive'
Assert-Equal $c.Style 'powerline' 'config valid: style case-insensitive'
Assert-Equal $c.Segments.cost $false 'config valid: cost off'
Assert-Equal $c.Segments.lines $true 'config valid: lines on'
Assert-Equal $c.Segments.model $true 'config valid: unmentioned segment on'

$c = Read-StatusConfig (Write-TempConfig 'broken.json' '{ "layout": ')
Assert-Equal $c.Layout 'one' 'config broken json: default layout'

$c = Read-StatusConfig (Write-TempConfig 'wrong-types.json' '{ "layout": "three", "style": 5, "segments": { "cost": "no", "bogus": false }, "extra": 1 }')
Assert-Equal $c.Layout 'one' 'config bad layout value: default'
Assert-Equal $c.Style 'plain' 'config non-string style: default'
Assert-Equal $c.Segments.cost $true 'config non-bool segment: on'
Assert-True (-not $c.Segments.ContainsKey('bogus')) 'config unknown segment: ignored'

$c = Read-StatusConfig (Write-TempConfig 'segments-array.json' '{ "segments": [true] }')
Assert-Equal $c.Segments.model $true 'config segments not an object: all on'

$c = Read-StatusConfig (Write-TempConfig 'empty.json' '')
Assert-Equal $c.Layout 'one' 'config empty file: default'

$c = Read-StatusConfig (Write-TempConfig 'array.json' '[1, 2]')
Assert-Equal $c.Style 'plain' 'config top-level array: default'
```

Insert `Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue` immediately before the final `Write-Host ''` summary line.

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: `functions not found in ...statusline.ps1: Read-StatusConfig`, exit 1.

- [ ] **Step 3: Add the parameter and `Read-StatusConfig` to `statusline.ps1`**

Replace lines 1–10 (from `#Requires` through `$PSStyle.OutputRendering = 'Ansi'`) with:

```powershell
#Requires -Version 7.0
# Claude Code status line (PowerShell 7) with Nerd Font glyphs and ANSI colour.
# Requires a Nerd Font in the terminal (install.ps1 can set up JetBrainsMono Nerd Font).
# Reads the JSON Claude Code pipes on stdin and prints one or two lines, e.g.
#   󰚩 Fable 5.1  󰍛 37% ████░░░░░░   $0.43   my-project   main
# Layout, separator style and segment toggles come from statusline.json next to this script.
# Glyphs are emitted from code points so the file's own encoding never matters.
[CmdletBinding()]
param(
    # Path to the config file. Defaults to statusline.json beside this script. Claude Code never passes it.
    [string] $Config
)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# PowerShell strips ANSI colour when stdout is redirected unless told otherwise; the host always redirects it.
$PSStyle.OutputRendering = 'Ansi'
```

Insert after the closing brace of `Get-VisibleWidth`:

```powershell
# Reads statusline.json. Anything missing or invalid silently falls back to its default.
function Read-StatusConfig([string] $Path) {
    $cfg = @{ Layout = 'one'; Style = 'plain'; Segments = @{} }
    foreach ($n in @('model', 'context', 'cost', 'lines', 'limits', 'badges', 'folder', 'branch')) { $cfg.Segments[$n] = $true }
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $cfg }
        $j = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($j -isnot [System.Management.Automation.PSCustomObject]) { return $cfg }
        if ($j.layout -is [string] -and $j.layout.ToLowerInvariant() -in @('one', 'two')) { $cfg.Layout = $j.layout.ToLowerInvariant() }
        if ($j.style -is [string] -and $j.style.ToLowerInvariant() -in @('plain', 'powerline')) { $cfg.Style = $j.style.ToLowerInvariant() }
        $segs = $j.segments
        if ($segs -is [System.Management.Automation.PSCustomObject]) {
            foreach ($n in @($cfg.Segments.Keys)) {
                $v = $segs.$n
                if ($v -is [bool]) { $cfg.Segments[$n] = $v }
            }
        }
    } catch { }
    return $cfg
}
```

- [ ] **Step 4: Create `statusline.json` at the repo root**

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

- [ ] **Step 5: Run the test to verify it passes**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: `== unit: config` with no FAIL lines, `failed 0`, exit 0.

- [ ] **Step 6: Lint**

Run: `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path .\statusline.ps1, .\test.ps1 -Settings .\PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add statusline.ps1 statusline.json test.ps1
git commit -F - <<'EOF'
Add statusline.json and a silent config reader

statusline.ps1 takes -Config <path> and otherwise reads statusline.json from its own
directory. Missing files, bad JSON, wrong types and unknown values all fall back to
defaults without any output. The config is parsed but not yet applied.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FpwyeW4r1Bay98JfkxVT9F
EOF
```

---

### Task 3: Palette, inline colour, and the line renderer

**Files:**
- Modify: `statusline.ps1` (add `Get-Palette`, `Format-Inline`, `Format-Line` after `Read-StatusConfig`)
- Modify: `test.ps1` (extend import list; add `== unit: renderer` group)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Get-Palette() -> @{ Roles = @{ <role> = @{ Sgr; Fg; Bg } }; Inline = @{ added = @{ Sgr; Fg }; removed = @{ Sgr; Fg } } }`.
- Produces: `Format-Inline([string] $Role, [string] $Text, [string] $SegmentRole, [string] $Style) -> string`.
- Produces: `Format-Line($Segments, [string] $Style) -> string`. `$Segments` is a list or array of segment hashtables `@{ Name; Text; Short; Role; Bold }`. Returns `''` for no segments.

- [ ] **Step 1: Add renderer unit tests to `test.ps1`**

Change the import line to:

```powershell
. (Import-ScriptFunction $script @('Get-VisibleWidth', 'Read-StatusConfig', 'Get-Palette', 'Format-Inline', 'Format-Line'))
```

Insert before the `# ---- Sample renders` comment:

```powershell
Write-Host '== unit: renderer' -ForegroundColor Cyan
$arrow = [char]::ConvertFromUtf32(0xE0B0)
$chevron = [char]::ConvertFromUtf32(0xE0B1)
$segModel = @{ Name = 'model'; Text = 'M'; Short = $null; Role = 'model'; Bold = $true }
$segFolder = @{ Name = 'folder'; Text = 'F'; Short = $null; Role = 'folder'; Bold = $false }
$segDim = @{ Name = 'cost'; Text = 'X'; Short = $null; Role = 'dim'; Bold = $false }

Assert-Equal (Format-Line @($segModel, $segFolder) 'plain') "$esc[1;36mM$esc[0m $esc[90m$chevron$esc[0m $esc[34mF$esc[0m" 'plain: two segments'
Assert-Equal (Format-Line @($segDim) 'plain') "$esc[90mX$esc[0m" 'plain: one segment'
Assert-Equal (Format-Line @() 'plain') '' 'plain: no segments'
Assert-Equal (Format-Line @($segModel, $segFolder) 'powerline') "$esc[0;1;48;5;31;38;5;231m M $esc[38;5;31;48;5;25m$arrow$esc[0;48;5;25;38;5;231m F $esc[0m$esc[38;5;25m$arrow$esc[0m" 'powerline: two segments'
Assert-Equal (Format-Line @($segDim) 'powerline') "$esc[0;48;5;238;38;5;250m X $esc[0m$esc[38;5;238m$arrow$esc[0m" 'powerline: one segment'
Assert-Equal (Format-Inline 'added' '+1' 'dim' 'plain') "$esc[32m+1$esc[90m" 'inline plain restores segment colour'
Assert-Equal (Format-Inline 'removed' '-2' 'dim' 'powerline') "$esc[38;5;203m-2$esc[38;5;250m" 'inline powerline restores segment fg'

$pal = Get-Palette
Assert-Equal $pal.Roles.warn.Sgr '33' 'palette warn sgr'
Assert-Equal $pal.Roles.warn.Fg 16 'palette warn fg'
Assert-Equal $pal.Roles.branch.Bg 90 'palette branch bg'
Assert-Equal $pal.Inline.added.Fg 46 'palette inline added fg'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: `functions not found in ...: Get-Palette, Format-Inline, Format-Line`, exit 1.

- [ ] **Step 3: Add the three functions to `statusline.ps1`**

Insert after the closing brace of `Read-StatusConfig`:

```powershell
# Colour table. Plain style uses the SGR codes the script has always used; powerline uses 256-colour
# foreground/background pairs so blocks look the same on every terminal theme.
function Get-Palette {
    return @{
        Roles = @{
            model  = @{ Sgr = '1;36'; Fg = 231; Bg = 31 }
            ok     = @{ Sgr = '32';   Fg = 231; Bg = 28 }
            warn   = @{ Sgr = '33';   Fg = 16;  Bg = 178 }
            bad    = @{ Sgr = '31';   Fg = 231; Bg = 160 }
            dim    = @{ Sgr = '90';   Fg = 250; Bg = 238 }
            folder = @{ Sgr = '34';   Fg = 231; Bg = 25 }
            branch = @{ Sgr = '35';   Fg = 231; Bg = 90 }
        }
        Inline = @{
            added   = @{ Sgr = '32'; Fg = 46 }
            removed = @{ Sgr = '31'; Fg = 203 }
        }
    }
}

# A foreground-only colour change inside a segment that restores the segment's own foreground afterwards,
# so a powerline background is never interrupted by a reset.
function Format-Inline([string] $Role, [string] $Text, [string] $SegmentRole, [string] $Style) {
    $pal = Get-Palette
    if ($Style -eq 'powerline') { return "`e[38;5;$($pal.Inline[$Role].Fg)m$Text`e[38;5;$($pal.Roles[$SegmentRole].Fg)m" }
    return "`e[$($pal.Inline[$Role].Sgr)m$Text`e[$($pal.Roles[$SegmentRole].Sgr)m"
}

# Renders an ordered list of segment records as one line in the given style.
function Format-Line($Segments, [string] $Style) {
    $segs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($s in $Segments) { if ($s) { $segs.Add($s) } }
    if ($segs.Count -eq 0) { return '' }
    $pal = Get-Palette
    if ($Style -eq 'powerline') {
        $arrow = [char]::ConvertFromUtf32(0xE0B0)
        $sb = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt $segs.Count; $i++) {
            $s = $segs[$i]
            $c = $pal.Roles[$s.Role]
            $bold = if ($s.Bold) { '1;' } else { '' }
            [void] $sb.Append("`e[0;${bold}48;5;$($c.Bg);38;5;$($c.Fg)m $($s.Text) ")
            if ($i -lt $segs.Count - 1) {
                $n = $pal.Roles[$segs[$i + 1].Role]
                [void] $sb.Append("`e[38;5;$($c.Bg);48;5;$($n.Bg)m$arrow")
            } else {
                [void] $sb.Append("`e[0m`e[38;5;$($c.Bg)m$arrow`e[0m")
            }
        }
        return $sb.ToString()
    }
    $sep = " `e[90m$([char]::ConvertFromUtf32(0xE0B1))`e[0m "
    $parts = foreach ($s in $segs) { $c = $pal.Roles[$s.Role]; "`e[$($c.Sgr)m$($s.Text)`e[0m" }
    return ($parts -join $sep)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: `== unit: renderer` with no FAIL lines, `failed 0`.

- [ ] **Step 5: Lint**

Run: `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path .\statusline.ps1, .\test.ps1 -Settings .\PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add statusline.ps1 test.ps1
git commit -F - <<'EOF'
Add the colour palette, inline colour helper and line renderer

Format-Line renders segment records in plain style (unchanged SGR codes, dim chevron
separator) or powerline style (256-colour blocks joined by solid arrows). Each
powerline block starts with a reset so the model's bold does not leak.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FpwyeW4r1Bay98JfkxVT9F
EOF
```

---

### Task 4: Width fitting

**Files:**
- Modify: `statusline.ps1` (add `Get-FittedLine` after `Format-Line`)
- Modify: `test.ps1` (extend import list; add `== unit: fitting` group)

**Interfaces:**
- Consumes: `Format-Line`, `Get-VisibleWidth`.
- Produces: `Get-FittedLine($Segments, [string] $Style, $Width) -> string or $null`. `$Width` is the target cell count or `$null` for no fitting. Never mutates the input records. Returns `$null` when there is nothing left to print.

- [ ] **Step 1: Add fitting unit tests to `test.ps1`**

Change the import line to:

```powershell
. (Import-ScriptFunction $script @('Get-VisibleWidth', 'Read-StatusConfig', 'Get-Palette', 'Format-Inline', 'Format-Line', 'Get-FittedLine'))
```

Insert before the `# ---- Sample renders` comment. Plain separators are 3 cells each, so the full line below is 23 + 7 × 3 = 44 cells.

```powershell
Write-Host '== unit: fitting' -ForegroundColor Cyan
function Get-FitSegments {
    return @(
        @{ Name = 'model';   Text = 'M';      Short = $null; Role = 'model';  Bold = $true }
        @{ Name = 'context'; Text = 'CCCCCC'; Short = 'CCC'; Role = 'ok';     Bold = $false }
        @{ Name = 'cost';    Text = 'AA';     Short = $null; Role = 'dim';    Bold = $false }
        @{ Name = 'lines';   Text = 'LL';     Short = $null; Role = 'dim';    Bold = $false }
        @{ Name = 'limits';  Text = 'IIIIII'; Short = 'III'; Role = 'warn';   Bold = $false }
        @{ Name = 'badges';  Text = 'GG';     Short = $null; Role = 'dim';    Bold = $false }
        @{ Name = 'folder';  Text = 'FF';     Short = $null; Role = 'folder'; Bold = $false }
        @{ Name = 'branch';  Text = 'BB';     Short = $null; Role = 'branch'; Bold = $false }
    )
}
$fit = Get-FitSegments
$line = Get-FittedLine $fit 'plain' $null
Assert-Equal (Get-VisibleWidth $line) 44 'fit: no width means no fitting'
Assert-Equal (Get-VisibleWidth (Get-FittedLine $fit 'plain' 44)) 44 'fit: exact fit unchanged'
$line = Get-FittedLine $fit 'plain' 43
Assert-Equal (Get-VisibleWidth $line) 41 'fit: stage 1 shrinks limits first'
Assert-True ($line.Contains('III') -and -not $line.Contains('IIIIII') -and $line.Contains('CCCCCC')) 'fit: only limits shortened at 43'
Assert-Equal $fit[4].Text 'IIIIII' 'fit: input not mutated'
$line = Get-FittedLine $fit 'plain' 40
Assert-Equal (Get-VisibleWidth $line) 38 'fit: stage 1 shrinks context second'
$line = Get-FittedLine $fit 'plain' 37
Assert-Equal (Get-VisibleWidth $line) 33 'fit: stage 2 drops lines first'
Assert-True (-not $line.Contains('LL') -and $line.Contains('GG')) 'fit: lines dropped, badges kept at 37'
$line = Get-FittedLine $fit 'plain' 10
Assert-Equal (ConvertTo-PlainText $line) "M $chevron CCC" 'fit: drops down to model and short context'
$line = Get-FittedLine $fit 'plain' 6
Assert-Equal (ConvertTo-PlainText $line) 'M' 'fit: context dropped last'
$line = Get-FittedLine $fit 'plain' 0
Assert-Equal $line "$esc[1;36mM$esc[0m" 'fit: model alone may overflow'
Assert-Equal (Get-FittedLine @($fit[2]) 'plain' 1) $null 'fit: line without model drops to nothing'
Assert-Equal (Get-FittedLine @() 'plain' 40) $null 'fit: no segments gives null'
$line = Get-FittedLine $fit 'powerline' 30
Assert-True ((Get-VisibleWidth $line) -le 30) 'fit: powerline respects width'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: `functions not found in ...: Get-FittedLine`, exit 1.

- [ ] **Step 3: Add `Get-FittedLine` to `statusline.ps1`**

Insert after the closing brace of `Format-Line`:

```powershell
# Renders a line and, when a width is given, shrinks then drops segments until it fits.
# Stage 1 swaps limits then context for their Short form. Stage 2 drops whole segments in a fixed order.
# The model segment is never dropped and may overflow on its own. Returns $null when nothing is left.
function Get-FittedLine($Segments, [string] $Style, $Width) {
    $segs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($s in $Segments) { if ($s) { $segs.Add($s.Clone()) } }
    if ($segs.Count -eq 0) { return $null }
    $line = Format-Line $segs $Style
    if ($null -eq $Width) { return $line }
    $target = [int] $Width
    if ((Get-VisibleWidth $line) -le $target) { return $line }
    foreach ($name in @('limits', 'context')) {
        for ($i = 0; $i -lt $segs.Count; $i++) {
            if ($segs[$i].Name -eq $name -and $segs[$i].Short) {
                $segs[$i].Text = $segs[$i].Short
                $line = Format-Line $segs $Style
                if ((Get-VisibleWidth $line) -le $target) { return $line }
            }
        }
    }
    foreach ($name in @('lines', 'badges', 'cost', 'limits', 'folder', 'branch', 'context')) {
        $at = -1
        for ($i = 0; $i -lt $segs.Count; $i++) { if ($segs[$i].Name -eq $name) { $at = $i } }
        if ($at -lt 0) { continue }
        $segs.RemoveAt($at)
        if ($segs.Count -eq 0) { return $null }
        $line = Format-Line $segs $Style
        if ((Get-VisibleWidth $line) -le $target) { return $line }
    }
    return $line
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: `== unit: fitting` with no FAIL lines, `failed 0`.

- [ ] **Step 5: Lint**

Run: `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path .\statusline.ps1, .\test.ps1 -Settings .\PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add statusline.ps1 test.ps1
git commit -F - <<'EOF'
Add width fitting: shrink limits and context, then drop segments in order

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FpwyeW4r1Bay98JfkxVT9F
EOF
```

---

### Task 5: Segment builders, layout, and config wiring in the main section

**Files:**
- Modify: `statusline.ps1` (replace everything from `$raw = [Console]::In.ReadToEnd()` to the end of the file)

**Interfaces:**
- Consumes: `Read-StatusConfig`, `Format-Inline`, `Get-FittedLine`, `$gitTimeoutMs`, icons, `$defaultEffort`.
- Produces: builders `Get-ModelSegment`, `Get-ContextSegment`, `Get-CostSegment`, `Get-LinesSegment`, `Get-LimitsSegment`, `Get-BadgesSegment`, `Get-FolderSegment`, `Get-BranchSegment`, each `($d, $cfg) -> hashtable or $null`; `Test-PayloadDirty($status) -> bool`; `Get-ThresholdRole([int] $pct) -> 'ok'|'warn'|'bad'`. Task 6 replaces the body of `Get-BranchSegment`'s fallback.

- [ ] **Step 1: Capture today's output as the regression baseline**

Run in Bash from the repo root (scratchpad path is in the environment notes; substitute it):

```bash
S="C:/Users/jimsi/AppData/Local/Temp/claude/C--Users-jimsi-OneDrive-Documents-GitHub-claude-code-statusline-ps/7dc3c221-9bef-41fe-8d3b-bc49b252b6a1/scratchpad"
mkdir -p "$S" && git show HEAD:statusline.ps1 > "$S/old.ps1"
```

Then write `$S/compare.ps1`:

```powershell
param([string] $Old, [string] $New)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$esc = [char]27
$bad = 0
foreach ($f in Get-ChildItem 'C:\Users\jimsi\OneDrive\Documents\GitHub\claude-code-statusline-ps\samples' -Filter *.json | Sort-Object Name) {
    $payload = Get-Content $f.FullName -Raw
    $a = ($payload | pwsh -NoProfile -NonInteractive -File $Old) -join "`n"
    $b = ($payload | pwsh -NoProfile -NonInteractive -File $New -Config 'C:\nonexistent.json') -join "`n"
    $a = $a -replace "$esc\[[0-9;]*m", ''
    $b = $b -replace "$esc\[[0-9;]*m", ''
    if ($a -ceq $b) { "same  $($f.Name)" } else { $bad++; "DIFF  $($f.Name)`n  old: $a`n  new: $b" }
}
if ($bad) { exit 1 }
```

Run: `pwsh -NoProfile -File "$S/compare.ps1" -Old "$S/old.ps1" -New ./statusline.ps1`
Expected now: `same` for all seven (the main section is still the old one; `-Config` is accepted and unused).

- [ ] **Step 2: Replace the main section of `statusline.ps1`**

Delete from the line `$raw = [Console]::In.ReadToEnd()` to the end of the file and put this in its place:

```powershell
$raw = [Console]::In.ReadToEnd()
try { $d = $raw | ConvertFrom-Json } catch { Write-Host (C '36' "$iconModel claude"); exit 0 }

$configPath = if ($Config) { $Config } else { Join-Path $PSScriptRoot 'statusline.json' }
$cfg = Read-StatusConfig $configPath

# ---- Segment builders. Each returns $null (segment omitted) or @{ Name; Text; Short; Role; Bold }. ----

function Get-ThresholdRole([int] $pct) { if ($pct -ge 85) { 'bad' } elseif ($pct -ge 60) { 'warn' } else { 'ok' } }

# Thousands of tokens: 1.5k, 64k, 1.0M
function K([double] $n) { if ($n -ge 1000000) { '{0:N1}M' -f ($n / 1000000) } elseif ($n -ge 10000) { '{0:N0}k' -f ($n / 1000) } else { '{0:N1}k' -f ($n / 1000) } }

function Get-ModelSegment($d, $cfg) {
    $model = $d.model.display_name
    if (-not $model) { return $null }
    return @{ Name = 'model'; Text = "$iconModel $model"; Short = $null; Role = 'model'; Bold = $true }
}

function Get-ContextSegment($d, $cfg) {
    $pct = $d.context_window.used_percentage
    if ($null -eq $pct) { return $null }
    $pct = [int] $pct
    $filled = [math]::Round($pct / 10)
    $bar = ((G 0x2588) * $filled) + ((G 0x2591) * (10 - $filled))
    $used = [double] ($d.context_window.total_input_tokens ?? 0) + [double] ($d.context_window.total_output_tokens ?? 0)
    $size = $d.context_window.context_window_size
    $counts = if ($used -gt 0 -and $size) { " $(K $used)/$(K $size)" } elseif ($used -gt 0) { " $(K $used)" } else { '' }
    $short = "$iconCtx $pct% $bar"
    return @{ Name = 'context'; Text = "$short$counts"; Short = $(if ($counts) { $short } else { $null }); Role = (Get-ThresholdRole $pct); Bold = $false }
}

function Get-CostSegment($d, $cfg) {
    $cost = $d.cost.total_cost_usd
    if ($null -eq $cost) { return $null }
    return @{ Name = 'cost'; Text = ("$iconCost `$" + ('{0:N2}' -f [double] $cost)); Short = $null; Role = 'dim'; Bold = $false }
}

# Lines added/removed this session; shown when either is non-zero. Inline colours keep the dim background intact.
function Get-LinesSegment($d, $cfg) {
    $added = [int] ($d.cost.total_lines_added ?? 0)
    $removed = [int] ($d.cost.total_lines_removed ?? 0)
    if ($added -le 0 -and $removed -le 0) { return $null }
    $text = "$iconLines " + (Format-Inline 'added' "+$added" 'dim' $cfg.Style) + ' ' + (Format-Inline 'removed' ((G 0x2212) + "$removed") 'dim' $cfg.Style)
    return @{ Name = 'lines'; Text = $text; Short = $null; Role = 'dim'; Bold = $false }
}

# " (1h12m)" or " (3d)" until the given epoch; empty when absent or already past.
function TimeLeft([object] $epoch) {
    if ($null -eq $epoch) { return '' }
    $left = [DateTimeOffset]::FromUnixTimeSeconds([long] $epoch) - [DateTimeOffset]::UtcNow
    if ($left.TotalMinutes -lt 1) { return '' }
    if ($left.TotalHours -ge 48) { return ' ({0}d)' -f [int] [math]::Floor($left.TotalDays) }
    return ' ({0}h{1:00}m)' -f [int] [math]::Floor($left.TotalHours), $left.Minutes
}

# Rate limits: 5-hour and 7-day usage, plus time until the 5-hour window resets.
function Get-LimitsSegment($d, $cfg) {
    $rl = $d.rate_limits
    if (-not $rl) { return $null }
    $h5 = $rl.five_hour.used_percentage
    $d7 = $rl.seven_day.used_percentage
    if ($null -eq $h5 -and $null -eq $d7) { return $null }
    $bits = [System.Collections.Generic.List[string]]::new()
    $worst = 0
    $short = $null
    if ($null -ne $h5) {
        $h5 = [int] [math]::Round([double] $h5); $worst = [math]::Max($worst, $h5)
        $bits.Add("5h $h5%$(TimeLeft $rl.five_hour.resets_at)")
        $short = "$iconLimit 5h $h5%"
    }
    if ($null -ne $d7) { $d7 = [int] [math]::Round([double] $d7); $worst = [math]::Max($worst, $d7); $bits.Add("7d $d7%") }
    $text = "$iconLimit $($bits -join ' ')"
    if ($short -eq $text) { $short = $null }
    return @{ Name = 'limits'; Text = $text; Short = $short; Role = (Get-ThresholdRole $worst); Bold = $false }
}

# Session mode badges: fast mode, thinking, non-default effort, vim mode. Omitted when nothing is on.
function Get-BadgesSegment($d, $cfg) {
    $badges = [System.Collections.Generic.List[string]]::new()
    if ($d.fast_mode -eq $true) { $badges.Add($iconFast) }
    if ($d.thinking.enabled -eq $true) { $badges.Add($iconThink) }
    $effort = $d.effort.level
    if ($effort -and $effort -ne $defaultEffort) { $badges.Add("$iconEffort $effort") }
    $vim = $d.vim.mode
    if ($vim) { $badges.Add("$iconVim $vim") }
    if ($badges.Count -eq 0) { return $null }
    return @{ Name = 'badges'; Text = ($badges -join ' '); Short = $null; Role = 'dim'; Bold = $false }
}

function Get-FolderSegment($d, $cfg) {
    $dir = $d.workspace.current_dir
    if (-not $dir) { return $null }
    return @{ Name = 'folder'; Text = "$iconFolder $(Split-Path $dir -Leaf)"; Short = $null; Role = 'folder'; Bold = $false }
}

# Dirty flag from a payload git.status value: "clean"/other string, or an object of counts/booleans.
function Test-PayloadDirty($status) {
    if ($status -is [string]) { return [bool] ($status -and $status -ne 'clean') }
    if (-not $status) { return $false }
    # Counts arrive as Int64 from ConvertFrom-Json; treat any positive numeric or "true" as dirty.
    foreach ($p in $status.PSObject.Properties) {
        $v = $p.Value
        if (($v -is [ValueType] -and -not ($v -is [bool]) -and [double] $v -gt 0) -or ($v -is [bool] -and $v)) { return $true }
    }
    return $false
}

# Branch from the payload's git object when present; otherwise from `git status` (Task 6).
function Get-BranchSegment($d, $cfg) {
    $info = $null
    if ($d.git.branch) { $info = @{ Branch = "$($d.git.branch)"; Dirty = (Test-PayloadDirty $d.git.status) } }
    if (-not $info) { return $null }
    $isMain = $info.Branch -in @('main', 'master')
    $icon = if ($isMain) { $iconHome } else { $iconBranch }
    $text = "$icon $($info.Branch)"
    if ($info.Dirty) { $text += " $iconDirty" }
    return @{ Name = 'branch'; Text = $text; Short = $null; Role = $(if ($info.Dirty) { 'warn' } else { 'branch' }); Bold = $false }
}

# ---- Build, lay out, fit, print ----

$segmentNames = @('model', 'context', 'cost', 'lines', 'limits', 'badges', 'folder', 'branch')
$segments = [System.Collections.Generic.List[hashtable]]::new()
foreach ($name in $segmentNames) {
    if (-not $cfg.Segments[$name]) { continue }
    $seg = switch ($name) {
        'model'   { Get-ModelSegment $d $cfg }
        'context' { Get-ContextSegment $d $cfg }
        'cost'    { Get-CostSegment $d $cfg }
        'lines'   { Get-LinesSegment $d $cfg }
        'limits'  { Get-LimitsSegment $d $cfg }
        'badges'  { Get-BadgesSegment $d $cfg }
        'folder'  { Get-FolderSegment $d $cfg }
        'branch'  { Get-BranchSegment $d $cfg }
    }
    if ($seg) { $segments.Add($seg) }
}
if ($segments.Count -eq 0) { Write-Host (C '36' "$iconModel claude"); exit 0 }

# Claude Code sets COLUMNS before running the script. Leave one column free to avoid the pending-wrap glitch.
$width = $null
$cols = 0
if ([int]::TryParse([string] $env:COLUMNS, [ref] $cols) -and $cols -gt 0) { $width = $cols - 1 }

$lineSets = if ($cfg.Layout -eq 'two') {
    @(@('model', 'folder', 'branch', 'badges'), @('context', 'limits', 'cost', 'lines'))
} else { , $segmentNames }

$printed = 0
foreach ($names in $lineSets) {
    $onLine = foreach ($n in $names) { foreach ($s in $segments) { if ($s.Name -eq $n) { $s } } }
    $text = Get-FittedLine @($onLine) $cfg.Style $width
    if ($text) { Write-Host $text; $printed++ }
}
if ($printed -eq 0) { Write-Host (C '36' "$iconModel claude") }
```

Also delete the old `$sep = ...` line near the top (line 29 in the original; the renderer builds its own separator). Keep `function C` because the fallback uses it.

- [ ] **Step 3: Run the regression comparison**

Run: `pwsh -NoProfile -File "$S/compare.ps1" -Old "$S/old.ps1" -New ./statusline.ps1`
Expected: `same` for all seven samples, exit 0. Any `DIFF` is a bug in a builder; fix before moving on.

- [ ] **Step 4: Run the unit tests and samples**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: `failed 0`. The sample renders read the repo's `statusline.json` (defaults) and look as before.

- [ ] **Step 5: Smoke-test two-line powerline and toggles by hand**

Write `$S/two.json`: `{ "layout": "two", "style": "powerline", "segments": { "cost": false } }`.

Run: `Get-Content .\samples\06-limits-badges-lines.json -Raw | pwsh -NoProfile -File .\statusline.ps1 -Config "$S/two.json"`
Expected: two lines. Line 1 has model, folder, branch, badges as coloured blocks joined by arrows. Line 2 has context, limits, lines, and no cost.

Run with `$env:COLUMNS = 40` set in the calling shell and `layout: one` (the repo config): the same sample prints one line no wider than 39 cells, with lines, badges, cost dropped as needed. Unset `COLUMNS` afterwards.

- [ ] **Step 6: Lint**

Run: `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path .\statusline.ps1 -Settings .\PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add statusline.ps1
git commit -F - <<'EOF'
Build segments as records and apply layout, style, toggles and width fitting

Each segment is built by its own function returning Name/Text/Short/Role/Bold. The
config's segment toggles apply before building, layout "two" splits the segments over
two lines, and each line is fitted to COLUMNS - 1. Default plain output is unchanged
character for character against the previous script on all seven samples.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FpwyeW4r1Bay98JfkxVT9F
EOF
```

---

### Task 6: Git fallback with timeout

**Files:**
- Modify: `statusline.ps1` (add `Read-PorcelainStatus` and `Get-GitBranch` after `Get-FittedLine`; update `Get-BranchSegment`)
- Modify: `test.ps1` (extend import list; add `== unit: porcelain` and `== git` groups; add `Invoke-StatusLine` helper)

**Interfaces:**
- Consumes: `Get-BranchSegment` from Task 5, `$gitTimeoutMs`.
- Produces: `Read-PorcelainStatus([string] $Text) -> $null or @{ Branch = string; Dirty = bool }`.
- Produces: `Get-GitBranch([string] $Dir, [int] $TimeoutMs) -> $null or @{ Branch; Dirty }`.
- Produces in `test.ps1`: `Invoke-StatusLine([string] $Payload, [string] $ConfigPath, [int] $Columns, [string] $PathPrefix) -> @{ Lines = string[]; Err = string[]; ExitCode; Ms }`. Task 7 reuses it.

- [ ] **Step 1: Add the porcelain parser unit tests**

Change the import line to:

```powershell
. (Import-ScriptFunction $script @('Get-VisibleWidth', 'Read-StatusConfig', 'Get-Palette', 'Format-Inline', 'Format-Line', 'Get-FittedLine', 'Read-PorcelainStatus', 'Get-GitBranch'))
```

Insert before the `# ---- Sample renders` comment:

```powershell
Write-Host '== unit: porcelain' -ForegroundColor Cyan
$r = Read-PorcelainStatus "## main...origin/main [ahead 1]`n"
Assert-Equal $r.Branch 'main' 'porcelain: tracking branch'
Assert-Equal $r.Dirty $false 'porcelain: clean'
$r = Read-PorcelainStatus "## main`n M file.txt`n"
Assert-Equal $r.Dirty $true 'porcelain: modified is dirty'
$r = Read-PorcelainStatus "## main`r`n?? new.txt`r`n"
Assert-Equal $r.Dirty $true 'porcelain: untracked is dirty (CRLF)'
$r = Read-PorcelainStatus "## feature/x...origin/feature/x`n"
Assert-Equal $r.Branch 'feature/x' 'porcelain: feature branch'
$r = Read-PorcelainStatus "## No commits yet on main`n"
Assert-Equal $r.Branch 'main' 'porcelain: unborn'
Assert-Equal $r.Dirty $false 'porcelain: unborn clean'
$r = Read-PorcelainStatus "## HEAD (no branch)`n"
Assert-Equal $r.Branch 'detached' 'porcelain: detached'
Assert-Equal (Read-PorcelainStatus "fatal: not a git repository`n") $null 'porcelain: no header'
Assert-Equal (Read-PorcelainStatus '') $null 'porcelain: empty'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: `functions not found in ...: Read-PorcelainStatus, Get-GitBranch`, exit 1.

- [ ] **Step 3: Add the two functions to `statusline.ps1`**

Insert after the closing brace of `Get-FittedLine`:

```powershell
# Parses `git status --porcelain=v1 --branch` output. $null when the header line is missing.
function Read-PorcelainStatus([string] $Text) {
    if (-not $Text) { return $null }
    $lines = $Text -split "`r?`n"
    if (-not $lines[0].StartsWith('## ')) { return $null }
    $head = $lines[0].Substring(3)
    $branch = if ($head -eq 'HEAD (no branch)') { 'detached' }
    elseif ($head -match '^(No commits yet|Initial commit) on (.+)$') { $Matches[2] }
    else { ($head -split '\.\.\.', 2)[0] }
    $dirty = @($lines | Select-Object -Skip 1 | Where-Object { $_.Trim() }).Count -gt 0
    return @{ Branch = $branch; Dirty = $dirty }
}

# Runs git status in $Dir with a hard timeout. Any failure, or no git on PATH, returns $null.
# Stdout and stderr are drained on .NET threads so a long listing cannot fill the pipe and stall git.
function Get-GitBranch([string] $Dir, [int] $TimeoutMs) {
    if (-not $Dir) { return $null }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    $git = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $git) { return $null }
    $p = $null
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($git)
        foreach ($a in @('-C', $Dir, 'status', '--porcelain=v1', '--branch')) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.Environment['GIT_OPTIONAL_LOCKS'] = '0'
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $null = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill($true) } catch { }
            return $null
        }
        if (-not $outTask.Wait(500)) { return $null }
        if ($p.ExitCode -ne 0) { return $null }
        return Read-PorcelainStatus $outTask.Result
    } catch { return $null }
    finally { if ($p) { $p.Dispose() } }
}
```

Then in `Get-BranchSegment` replace the single line

```powershell
    if ($d.git.branch) { $info = @{ Branch = "$($d.git.branch)"; Dirty = (Test-PayloadDirty $d.git.status) } }
```

with

```powershell
    if ($d.git.branch) { $info = @{ Branch = "$($d.git.branch)"; Dirty = (Test-PayloadDirty $d.git.status) } }
    else { $info = Get-GitBranch $d.workspace.current_dir $gitTimeoutMs }
```

and change its comment to `# Branch from the payload's git object when present; otherwise from git status in current_dir.`

- [ ] **Step 4: Run the test to verify the porcelain group passes**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: `== unit: porcelain` with no FAIL lines, `failed 0`. Rerun the Task 5 regression compare; all seven still `same` (samples 05 and 07 point at directories that do not exist here).

- [ ] **Step 5: Add `Invoke-StatusLine` and the git group to `test.ps1`**

Insert `Invoke-StatusLine` right after `Measure-VisibleWidth`:

```powershell
# Runs statusline.ps1 in a child pwsh. $Columns 0 means COLUMNS unset. $PathPrefix is prepended to PATH for the child.
function Invoke-StatusLine([string] $Payload, [string] $ConfigPath, [int] $Columns = 0, [string] $PathPrefix) {
    $oldCols = $env:COLUMNS
    $oldPath = $env:PATH
    try {
        if ($Columns -gt 0) { $env:COLUMNS = "$Columns" } else { Remove-Item Env:COLUMNS -ErrorAction SilentlyContinue }
        if ($PathPrefix) { $env:PATH = $PathPrefix + [System.IO.Path]::PathSeparator + $env:PATH }
        $pwshArgs = @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', $script)
        if ($ConfigPath) { $pwshArgs += @('-Config', $ConfigPath) }
        $err = [System.Collections.Generic.List[string]]::new()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $out = $Payload | pwsh @pwshArgs 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $err.Add("$_") } else { "$_" }
        }
        $sw.Stop()
        return @{ Lines = @($out); Err = @($err); ExitCode = $LASTEXITCODE; Ms = $sw.ElapsedMilliseconds }
    } finally {
        if ($null -ne $oldCols) { $env:COLUMNS = $oldCols } else { Remove-Item Env:COLUMNS -ErrorAction SilentlyContinue }
        $env:PATH = $oldPath
    }
}
```

Insert before the `# ---- Sample renders` comment (after the porcelain group):

```powershell
Write-Host '== git' -ForegroundColor Cyan
$iconHome = [char]::ConvertFromUtf32(0xF015)
$iconBranch = [char]::ConvertFromUtf32(0xE0A0)
$iconDirty = [char]::ConvertFromUtf32(0xF040)
$gitCfg = @('-c', 'user.name=test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false')
function Initialize-TestRepo([string] $Name) {
    $p = Join-Path $tmp $Name
    New-Item -ItemType Directory -Force $p | Out-Null
    git init -q -b main $p
    return $p
}
function Add-Commit([string] $Path) {
    Set-Content (Join-Path $Path 'file.txt') 'hello'
    git -C $Path add .
    git -C $Path @gitCfg commit -q -m init
}
function Get-GitPayload([string] $Dir) {
    return ([ordered]@{ model = @{ display_name = 'M' }; workspace = @{ current_dir = $Dir } } | ConvertTo-Json -Compress)
}
function Write-FakeGit([string] $Name, [string] $Body) {
    $dir = Join-Path $tmp $Name
    New-Item -ItemType Directory -Force $dir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir 'git.cmd'), "@echo off`r`n$Body`r`n", [System.Text.Encoding]::ASCII)
    return $dir
}

$haveGit = [bool] (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
if (-not $haveGit) { Write-Warning 'git is not on PATH; skipping the real-repository git cases' }

$gitCases = [System.Collections.Generic.List[hashtable]]::new()
if ($haveGit) {
    $clean = Initialize-TestRepo 'repo-clean'; Add-Commit $clean
    $dirtyTracked = Initialize-TestRepo 'repo-dirty-tracked'; Add-Commit $dirtyTracked; Set-Content (Join-Path $dirtyTracked 'file.txt') 'changed'
    $dirtyUntracked = Initialize-TestRepo 'repo-dirty-untracked'; Add-Commit $dirtyUntracked; Set-Content (Join-Path $dirtyUntracked 'new.txt') 'x'
    $feature = Initialize-TestRepo 'repo-feature'; Add-Commit $feature; git -C $feature checkout -q -b feature/x
    $unborn = Initialize-TestRepo 'repo-unborn'
    $detached = Initialize-TestRepo 'repo-detached'; Add-Commit $detached; git -C $detached checkout -q --detach

    # In-process checks of Get-GitBranch itself
    $g = Get-GitBranch $clean 1500
    Assert-Equal $g.Branch 'main' 'Get-GitBranch: clean branch'
    Assert-Equal $g.Dirty $false 'Get-GitBranch: clean not dirty'
    $g = Get-GitBranch $dirtyUntracked 1500
    Assert-Equal $g.Dirty $true 'Get-GitBranch: untracked dirty'
    Assert-Equal (Get-GitBranch (Join-Path $tmp 'nowhere') 1500) $null 'Get-GitBranch: missing dir'

    $gitCases.Add(@{ Name = 'clean';           Dir = $clean;          Has = "$iconHome main";              Not = $iconDirty })
    $gitCases.Add(@{ Name = 'dirty tracked';   Dir = $dirtyTracked;   Has = "$iconHome main $iconDirty";  Raw = "$esc[33m" })
    $gitCases.Add(@{ Name = 'dirty untracked'; Dir = $dirtyUntracked; Has = "$iconHome main $iconDirty" })
    $gitCases.Add(@{ Name = 'feature';         Dir = $feature;        Has = "$iconBranch feature/x" })
    $gitCases.Add(@{ Name = 'unborn';          Dir = $unborn;         Has = "$iconHome main";              Not = $iconDirty })
    $gitCases.Add(@{ Name = 'detached';        Dir = $detached;       Has = "$iconBranch detached" })
}
$notRepo = Join-Path $tmp 'not-a-repo'; New-Item -ItemType Directory -Force $notRepo | Out-Null
$gitCases.Add(@{ Name = 'not a repo'; Dir = $notRepo; NoBranch = $true })
$gitCases.Add(@{ Name = 'git fails';  Dir = $notRepo; NoBranch = $true; NoStderr = $true; PathPrefix = (Write-FakeGit 'fake-fail' "echo fatal: not a git repository 1>&2`r`nexit 128") })
$gitCases.Add(@{ Name = 'git hangs';  Dir = $notRepo; NoBranch = $true; MaxMs = 3000; PathPrefix = (Write-FakeGit 'fake-hang' "ping -n 11 127.0.0.1 > nul`r`nexit 0") })

foreach ($case in $gitCases) {
    $r = Invoke-StatusLine (Get-GitPayload $case.Dir) $null 0 $case.PathPrefix
    $rawOut = $r.Lines -join "`n"
    $text = ConvertTo-PlainText $rawOut
    $label = "git $($case.Name)"
    Assert-True ($text.Contains('M')) "${label}: model still printed"
    if ($case.Has) { Assert-True ($text.Contains($case.Has)) "${label}: expected '$($case.Has)' in '$text'" }
    if ($case.Not) { Assert-True (-not $text.Contains($case.Not)) "${label}: unexpected '$($case.Not)' in '$text'" }
    if ($case.Raw) { Assert-True ($rawOut.Contains($case.Raw)) "${label}: expected colour $($case.Raw -replace $esc, '<ESC>')" }
    if ($case.NoBranch) { Assert-True (-not $text.Contains($iconHome) -and -not $text.Contains($iconBranch)) "${label}: branch segment omitted, got '$text'" }
    if ($case.NoStderr) { Assert-True ($r.Err.Count -eq 0) "${label}: nothing on stderr, got '$($r.Err -join ' | ')'" }
    if ($case.MaxMs) { Assert-True ($r.Ms -lt $case.MaxMs) "${label}: finished in $($r.Ms) ms (limit $($case.MaxMs))" }
    Write-Host ("{0,-40} {1,5:N0} ms  {2}" -f $case.Name, $r.Ms, $text)
}
```

- [ ] **Step 6: Run the test to verify the git group passes**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: `== git` prints nine case lines; clean shows the home glyph and `main`, dirty cases add the pencil, feature shows the branch glyph, unborn shows `main`, detached shows `detached`, the last three show only `M`. The hang case takes about 2 seconds. `failed 0`.

If the hang case exceeds 3000 ms, check that `Kill($true)` ran (the `ping` child must die with `cmd.exe`) and that `pwsh` start-up on this machine is under a second.

- [ ] **Step 7: Lint**

Run: `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path .\statusline.ps1, .\test.ps1 -Settings .\PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add statusline.ps1 test.ps1
git commit -F - <<'EOF'
Read the branch from git status when the payload has no git object

The real Claude Code payload carries no git object, so the branch segment never
rendered in real sessions. Get-GitBranch runs git status --porcelain=v1 --branch in
current_dir through System.Diagnostics.Process with a 1500 ms timeout, kills the
process tree on expiry, and drains stdout asynchronously. test.ps1 builds temporary
repositories for clean, dirty, feature, unborn and detached cases and uses a fake
git.cmd on PATH for the failure and hang cases.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FpwyeW4r1Bay98JfkxVT9F
EOF
```

---

### Task 7: Render matrix in `test.ps1`

**Files:**
- Modify: `test.ps1` (parameters, help; replace the `# ---- Sample renders` section with the matrix)

**Interfaces:**
- Consumes: `Invoke-StatusLine`, `Measure-VisibleWidth`, `ConvertTo-PlainText`, `Read-StatusConfig` (imported), `Write-TempConfig`, `$tmp`.
- Produces: parameters `-Columns <int[]>` (default `120, 60, 20`), `-Config <path>`, `-Raw`.

- [ ] **Step 1: Update the header and parameters**

Replace the comment block and `param` at the top of `test.ps1` with:

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS
  Tests statusline.ps1.
.DESCRIPTION
  Runs unit checks on the script's pure functions, then renders every sample in ./samples against
  every layout x style combination at each width in -Columns, then exercises the git fallback in
  temporary repositories. Exits non-zero if any check fails.
.PARAMETER Columns
  Terminal widths to test. 0 means COLUMNS unset (no fitting). Default 120, 60, 20.
.PARAMETER Config
  Render only this config file instead of the generated layout x style set.
.PARAMETER Raw
  Show ANSI escapes as <ESC>.
#>
[CmdletBinding()]
param(
    [int[]] $Columns = @(120, 60, 20),
    [string] $Config,
    [switch] $Raw
)
```

- [ ] **Step 2: Replace the sample section with the matrix**

Replace everything from the `# ---- Sample renders` comment down to (not including) the `Remove-Item -Recurse -Force $tmp` line with:

```powershell
# ---- Render matrix: samples x configs x widths ----
$sampleFiles = Get-ChildItem (Join-Path $PSScriptRoot 'samples') -Filter *.json | Sort-Object Name
$modelOnlyPath = @{}
foreach ($style in @('plain', 'powerline')) {
    $modelOnlyPath[$style] = Write-TempConfig "model-only-$style.json" ('{ "layout": "one", "style": "' + $style + '", "segments": { "context": false, "cost": false, "lines": false, "limits": false, "badges": false, "folder": false, "branch": false } }')
}
$configSet = [System.Collections.Generic.List[hashtable]]::new()
if ($Config) {
    $resolved = (Resolve-Path $Config).Path
    $parsed = Read-StatusConfig $resolved
    $configSet.Add(@{ Name = (Split-Path $resolved -Leaf); Path = $resolved; Layout = $parsed.Layout; Style = $parsed.Style })
} else {
    foreach ($layout in @('one', 'two')) {
        foreach ($style in @('plain', 'powerline')) {
            $path = Write-TempConfig "$layout-$style.json" ('{ "layout": "' + $layout + '", "style": "' + $style + '" }')
            $configSet.Add(@{ Name = "$layout-$style"; Path = $path; Layout = $layout; Style = $style })
        }
    }
}

foreach ($cfg in $configSet) {
    foreach ($c in $Columns) {
        Write-Host ''
        Write-Host ("== render {0}  COLUMNS={1}" -f $cfg.Name, $(if ($c -gt 0) { $c } else { 'unset' })) -ForegroundColor Cyan
        $maxLines = if ($cfg.Layout -eq 'two') { 2 } else { 1 }
        foreach ($sample in $sampleFiles) {
            $payload = Get-Content $sample.FullName -Raw
            $r = Invoke-StatusLine $payload $cfg.Path $c
            $label = "$($cfg.Name) COLUMNS=$c $($sample.Name)"
            $lines = $r.Lines
            if ([string]::IsNullOrWhiteSpace(($lines -join ''))) { Assert-True $false "${label}: empty output"; continue }
            Assert-True ($lines.Count -le $maxLines) "${label}: $($lines.Count) lines, layout allows $maxLines"
            foreach ($line in $lines) {
                Assert-True (-not [string]::IsNullOrWhiteSpace($line)) "${label}: empty line"
                if ($c -le 0) { continue }
                $w = Measure-VisibleWidth $line
                if ($w -le $c - 1) { $script:passed++; continue }
                $only = Invoke-StatusLine $payload $modelOnlyPath[$cfg.Style] $c
                $isModelOnly = (ConvertTo-PlainText $line) -ceq (ConvertTo-PlainText ($only.Lines -join ''))
                Assert-True $isModelOnly "${label}: width $w exceeds $($c - 1) and the line is not the model-only fallback"
            }
            $shown = if ($Raw) { $lines -replace $esc, '<ESC>' } else { $lines }
            Write-Host ("{0,-40} {1,5:N0} ms  " -f $sample.Name, $r.Ms) -NoNewline
            Write-Host $shown[0]
            for ($i = 1; $i -lt $shown.Count; $i++) { Write-Host ((' ' * 50) + $shown[$i]) }
        }
    }
}
```

- [ ] **Step 3: Run the full test**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: twelve `== render` blocks (4 configs × 3 widths), seven samples each. At `COLUMNS=60` the one-line renders of samples 02 and 06 lose their trailing segments; at `COLUMNS=20` every sample shows only the model. Two-line configs print two rows for samples that have segments on both lines. `failed 0`. Total runtime roughly 30 seconds.

Run: `pwsh -NoProfile -File .\test.ps1 -Config .\statusline.json -Columns 0`
Expected: one `== render statusline.json  COLUMNS=unset` block, `failed 0`.

Run: `pwsh -NoProfile -File .\test.ps1 -Columns 30 -Raw`
Expected: escapes shown as `<ESC>`; `failed 0`.

- [ ] **Step 4: Lint**

Run: `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path .\test.ps1 -Settings .\PSScriptAnalyzerSettings.psd1"`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add test.ps1
git commit -F - <<'EOF'
Render every sample across layouts, styles and widths in test.ps1

-Columns (default 120, 60, 20) sets COLUMNS for each child render; 0 leaves it unset.
-Config runs a single config instead of the four generated combinations. A render fails
on empty output, too many lines, an empty line, or a line wider than COLUMNS - 1 unless
it matches the model-only render of the same sample.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FpwyeW4r1Bay98JfkxVT9F
EOF
```

---

### Task 8: Installer copies and keeps the config

**Files:**
- Modify: `install.ps1:16-17` (help), `install.ps1:31-32` (paths), `install.ps1:45-50` (uninstall), `install.ps1:52-54` (install)

- [ ] **Step 1: Edit `install.ps1`**

Help: change the `.DESCRIPTION` first sentence to `Copies statusline.ps1 to ~/.claude/statusline.ps1, copies statusline.json there if none exists, and adds a "statusLine" entry to the USER-level`. Change `.PARAMETER Uninstall` text to `Remove the statusLine entry from settings.json and delete ~/.claude/statusline.ps1. ~/.claude/statusline.json is kept.`

After `$target = Join-Path $claudeDir 'statusline.ps1'` add:

```powershell
$configTarget = Join-Path $claudeDir 'statusline.json'
```

Replace the uninstall block with:

```powershell
if ($Uninstall) {
    $s = Read-Settings
    if ($s.PSObject.Properties['statusLine']) { $s.PSObject.Properties.Remove('statusLine'); Write-Settings $s; Write-Host "Removed statusLine from $settingsPath" }
    if (Test-Path $target) { Remove-Item $target -Force; Write-Host "Deleted $target" }
    if (Test-Path $configTarget) { Write-Host "Kept $configTarget (delete it yourself if you no longer want it)" }
    return
}
```

Replace the two install lines (`Copy-Item ...` and `Write-Host "Installed $target"`) with:

```powershell
Copy-Item (Join-Path $PSScriptRoot 'statusline.ps1') $target -Force
Write-Host "Installed $target"
if (Test-Path $configTarget) {
    Write-Host "Kept existing $configTarget"
} else {
    Copy-Item (Join-Path $PSScriptRoot 'statusline.json') $configTarget
    Write-Host "Installed $configTarget (edit it to change layout, style or segments)"
}
```

- [ ] **Step 2: Verify against a throwaway profile**

The installer derives everything from `USERPROFILE`, so point it at the scratchpad. In PowerShell:

```powershell
$S = 'C:\Users\jimsi\AppData\Local\Temp\claude\C--Users-jimsi-OneDrive-Documents-GitHub-claude-code-statusline-ps\7dc3c221-9bef-41fe-8d3b-bc49b252b6a1\scratchpad'
$env:USERPROFILE = "$S\fakehome"; New-Item -ItemType Directory -Force $env:USERPROFILE | Out-Null
.\install.ps1
```

Expected: `Installed ...\fakehome\.claude\statusline.ps1`, `Installed ...\fakehome\.claude\statusline.json (edit it ...)`, `Configured statusLine in ...`.

Then edit the fake `statusline.json` to `{ "layout": "two" }` and run `.\install.ps1` again. Expected: `Kept existing ...\statusline.json`; the file still says `two`.

Then `.\install.ps1 -Uninstall`. Expected: `Removed statusLine`, `Deleted ...statusline.ps1`, `Kept ...statusline.json (...)`; the json file still exists.

Restore: `$env:USERPROFILE = 'C:\Users\jimsi'` (or open a fresh shell). Do not run the installer against the real profile in this task.

- [ ] **Step 3: Lint and commit**

Run: `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path .\install.ps1 -Settings .\PSScriptAnalyzerSettings.psd1"`
Expected: no output.

```bash
git add install.ps1
git commit -F - <<'EOF'
Install statusline.json beside the script unless one already exists; keep it on uninstall

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FpwyeW4r1Bay98JfkxVT9F
EOF
```

---

### Task 9: Screenshot and icon renderers

**Files:**
- Modify: `docs/render-icons.ps1:13-28` (add `arrow`)
- Create: `docs/statusline-two-line.json`
- Modify: `docs/render-screenshot.ps1` (rewrite the parser and drawing loop)
- Generate: `docs/icons/arrow.svg`, `docs/statusline.png`, `docs/statusline-two-line.png`

- [ ] **Step 1: Add the arrow glyph and regenerate icons**

In `docs/render-icons.ps1` add after `chevron     = 0xE0B1`:

```powershell
    arrow       = 0xE0B0
```

Run: `pwsh docs/render-icons.ps1`
Expected: a line for each icon including `arrow`, and `docs/icons/arrow.svg` exists. Only `arrow.svg` should show as new in `git status`; if other SVGs changed, the font differs from the one that produced them, so revert those.

- [ ] **Step 2: Create `docs/statusline-two-line.json`**

```json
{
  "layout": "two",
  "style": "powerline"
}
```

- [ ] **Step 3: Rewrite `docs/render-screenshot.ps1`**

Replace the file with:

```powershell
#Requires -Version 7.0
# Renders statusline.ps1 output for a demo payload to a PNG using the installed Nerd Font.
# Run from anywhere:
#   pwsh docs/render-screenshot.ps1                                                         # docs/statusline.png
#   pwsh docs/render-screenshot.ps1 -Config docs/statusline-two-line.json -Out docs/statusline-two-line.png
param(
    [string] $Repo = (Split-Path $PSScriptRoot -Parent),
    [string] $Out = (Join-Path $PSScriptRoot 'statusline.png'),
    [string] $Config
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$PSStyle.OutputRendering = 'Ansi'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8   # decode the child's UTF-8 output correctly

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$payload = [ordered]@{
    model          = @{ display_name = 'Fable 5.1' }
    context_window = @{ total_input_tokens = 60000; total_output_tokens = 4000; context_window_size = 200000; used_percentage = 32 }
    cost           = @{ total_cost_usd = 1.07; total_lines_added = 156; total_lines_removed = 23 }
    rate_limits    = @{ five_hour = @{ used_percentage = 23.5; resets_at = $now + 4320 }; seven_day = @{ used_percentage = 41.2; resets_at = $now + 400000 } }
    fast_mode      = $true
    thinking       = @{ enabled = $true }
    effort         = @{ level = 'high' }
    workspace      = @{ current_dir = 'C:\Users\jim\src\my-project' }
    git            = @{ branch = 'main'; status = 'clean' }
} | ConvertTo-Json -Depth 5

$scriptArgs = @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', (Join-Path $Repo 'statusline.ps1'))
if ($Config) { $scriptArgs += @('-Config', (Resolve-Path $Config).Path) }
Remove-Item Env:COLUMNS -ErrorAction SilentlyContinue
$rows = @($payload | pwsh @scriptArgs)

# One Half Dark palette for the 16 system colours; the 256-colour cube and greys are computed.
$palette = @{ 30 = '#282C34'; 31 = '#E06C75'; 32 = '#98C379'; 33 = '#E5C07B'; 34 = '#61AFEF'; 35 = '#C678DD'; 36 = '#56B6C2'; 37 = '#DCDFE4'; 90 = '#5C6370'
              91 = '#E06C75'; 92 = '#98C379'; 93 = '#E5C07B'; 94 = '#61AFEF'; 95 = '#C678DD'; 96 = '#56B6C2'; 97 = '#FFFFFF' }
$fg = [System.Drawing.ColorTranslator]::FromHtml('#DCDFE4')
$bg = [System.Drawing.ColorTranslator]::FromHtml('#282C34')
function ConvertFrom-Xterm256([int] $n) {
    if ($n -lt 8) { return [System.Drawing.ColorTranslator]::FromHtml($palette[30 + $n]) }
    if ($n -lt 16) { return [System.Drawing.ColorTranslator]::FromHtml($palette[90 + $n - 8]) }
    if ($n -ge 232) { $v = 8 + 10 * ($n - 232); return [System.Drawing.Color]::FromArgb($v, $v, $v) }
    $n -= 16
    $levels = @(0, 95, 135, 175, 215, 255)
    return [System.Drawing.Color]::FromArgb($levels[[math]::Floor($n / 36)], $levels[[math]::Floor(($n % 36) / 6)], $levels[$n % 6])
}

# Parse each row's SGR sequences into runs of (text, fg, bg, bold)
$esc = [char]27
$pattern = "$esc\[([0-9;]*)m"
$rowRuns = foreach ($line in $rows) {
    $runs = [System.Collections.Generic.List[object]]::new()
    $colour = $fg; $back = $null; $bold = $false
    $pos = 0
    foreach ($m in [regex]::Matches($line, $pattern)) {
        if ($m.Index -gt $pos) { $runs.Add(@{ text = $line.Substring($pos, $m.Index - $pos); colour = $colour; back = $back; bold = $bold }) }
        $codes = @($m.Groups[1].Value -split ';' | ForEach-Object { if ($_ -eq '') { 0 } else { [int] $_ } })
        for ($i = 0; $i -lt $codes.Count; $i++) {
            $code = $codes[$i]
            if ($code -eq 0) { $colour = $fg; $back = $null; $bold = $false }
            elseif ($code -eq 1) { $bold = $true }
            elseif ($code -eq 39) { $colour = $fg }
            elseif ($code -eq 49) { $back = $null }
            elseif ($code -eq 38 -and $codes[$i + 1] -eq 5) { $colour = ConvertFrom-Xterm256 $codes[$i + 2]; $i += 2 }
            elseif ($code -eq 48 -and $codes[$i + 1] -eq 5) { $back = ConvertFrom-Xterm256 $codes[$i + 2]; $i += 2 }
            elseif ($palette.ContainsKey($code)) { $colour = [System.Drawing.ColorTranslator]::FromHtml($palette[$code]) }
        }
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $line.Length) { $runs.Add(@{ text = $line.Substring($pos); colour = $colour; back = $back; bold = $bold }) }
    , $runs
}

$scale = 2
$fontSize = 13 * $scale
$pad = 14 * $scale
$regular = [System.Drawing.Font]::new('JetBrainsMono NF', $fontSize, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$boldFont = [System.Drawing.Font]::new('JetBrainsMono NF', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$fmt = [System.Drawing.StringFormat]::GenericTypographic
$fmt.FormatFlags = $fmt.FormatFlags -bor [System.Drawing.StringFormatFlags]::MeasureTrailingSpaces

# Measure
$probe = [System.Drawing.Bitmap]::new(10, 10)
$g = [System.Drawing.Graphics]::FromImage($probe)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$width = 0
foreach ($runs in $rowRuns) {
    $w = 0
    foreach ($r in $runs) { $f = if ($r.bold) { $boldFont } else { $regular }; $w += $g.MeasureString($r.text, $f, 10000, $fmt).Width }
    $width = [math]::Max($width, $w)
}
$lineHeight = $regular.GetHeight($g)
$g.Dispose(); $probe.Dispose()

$bmp = [System.Drawing.Bitmap]::new([int] ($width + 2 * $pad), [int] ($lineHeight * $rowRuns.Count + 2 * $pad))
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear($bg)
$y = [float] $pad
foreach ($runs in $rowRuns) {
    $x = [float] $pad
    foreach ($r in $runs) {
        $f = if ($r.bold) { $boldFont } else { $regular }
        $w = $g.MeasureString($r.text, $f, 10000, $fmt).Width
        if ($r.back) {
            $bb = [System.Drawing.SolidBrush]::new($r.back)
            $g.FillRectangle($bb, $x, $y, $w, $lineHeight)
            $bb.Dispose()
        }
        $brush = [System.Drawing.SolidBrush]::new($r.colour)
        $g.DrawString($r.text, $f, $brush, $x, $y, $fmt)
        $brush.Dispose()
        $x += $w
    }
    $y += $lineHeight
}
$g.Dispose()
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
"wrote $Out ($($bmp.Width) x $($bmp.Height))"
$bmp.Dispose()
foreach ($line in $rows) { $line -replace $esc, '<ESC>' }
```

- [ ] **Step 4: Render both screenshots and inspect them**

Run: `pwsh docs/render-screenshot.ps1`
Expected: `wrote ...docs/statusline.png (W x H)` and one `<ESC>`-escaped line. Open the PNG with the Read tool: one row, the same look as before (bold cyan model, green context bar, dim cost and lines, green limits, dim badges, blue folder, magenta branch, dim chevrons).

Run: `pwsh docs/render-screenshot.ps1 -Config docs/statusline-two-line.json -Out docs/statusline-two-line.png`
Expected: two rows. Row 1: model on blue, folder on darker blue, branch on purple, badges on grey, joined by arrows whose colours match their neighbours, ending with an arrow into the dark background. Row 2: context on green, limits on green, cost and lines on grey. The `+156` is bright green and `−23` salmon on the grey block with no gap in the background.

If the arrow glyph leaves a one-pixel seam, that is a GDI measurement artefact and is acceptable.

- [ ] **Step 5: Lint and commit**

Run: `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path .\docs\render-screenshot.ps1, .\docs\render-icons.ps1 -Settings .\PSScriptAnalyzerSettings.psd1"`
Expected: no output.

```bash
git add docs/render-icons.ps1 docs/render-screenshot.ps1 docs/statusline-two-line.json docs/icons/arrow.svg docs/statusline.png docs/statusline-two-line.png
git commit -F - <<'EOF'
Render powerline backgrounds and multi-row output in the screenshot script; add the arrow icon

render-screenshot.ps1 takes -Config and -Out, parses 38;5;n and 48;5;n colours, fills
run backgrounds, and draws one row per output line. docs/statusline-two-line.json is
the config behind the new two-line screenshot.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FpwyeW4r1Bay98JfkxVT9F
EOF
```

---

### Task 10: README and project brief

**Files:**
- Modify: `README.md`
- Modify: `docs/projectbrief.md`

Before writing prose, invoke `crafting-effective-readmes` for structure and then `humanizer` on the new paragraphs (user preference). The content below is the substance; the wording may be tightened by those passes but every fact must survive.

- [ ] **Step 1: README edits**

1. After the first screenshot and its caption paragraph (line 11–13), add:

```markdown
![Two-line powerline layout](docs/statusline-two-line.png)

The same data in the two-line powerline layout. Both come from one script; a small JSON file
picks the layout and style.
```

2. In **Features**, add two bullets after the folder-and-branch bullet:

```markdown
- One line or two, plain separators or powerline blocks, and any segment switched off, all from `statusline.json`.
- Fits the terminal width. Long lines shorten the limits and context segments first, then drop segments from the right, so the status line never wraps.
```

and change the folder-and-branch bullet to:

```markdown
- Folder and git branch, with a home glyph on `main` and a pencil when the tree is dirty. Branch state comes from `git status` in the current directory.
```

3. In **What the installer does**, add a bullet after the first: ``- Copies `statusline.json` to `~/.claude/statusline.json` unless one is already there.`` In **Uninstall**, change the sentence to: ``This removes the `statusLine` entry and deletes `~/.claude/statusline.ps1`. Fonts and `~/.claude/statusline.json` stay.``

4. Add a **Configuration** section after **Installation** (before **What each segment shows**):

````markdown
## Configuration

The script reads `statusline.json` from its own folder, so after installing that is
`~/.claude/statusline.json`. The installed file holds the defaults:

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

| Key | Values | What it does |
|---|---|---|
| `layout` | `one`, `two` | `two` puts model, folder, branch and badges on the first line and context, limits, cost and lines on the second. |
| `style` | `plain`, `powerline` | `plain` is coloured text with a dim chevron between segments. `powerline` is coloured blocks joined by solid arrows. |
| `segments.<name>` | `true`, `false` | `false` hides that segment. |

Anything missing or invalid falls back to its default without a message, so a typo cannot blank
the status line. Delete the file to get the defaults back. `docs/statusline-two-line.json` is the
config behind the second screenshot.

Claude Code tells the script the terminal width. When a line is too long the script first drops
the token counts from the context segment and the countdown and 7-day figure from the limits
segment, then removes whole segments from the right: lines, badges, cost, limits, folder, branch,
context. The model segment always stays.
````

5. In the segment table, change the branch row's Data cell to `` `git.branch`, `git.status`, else `git status` in `workspace.current_dir` `` and its Rendering cell to `Magenta when clean. Yellow with the pencil when the tree has uncommitted or untracked changes. Shows `detached` on a detached HEAD`. Change the separator paragraph to:

```markdown
A dim <img src="docs/icons/chevron.svg" height="14" alt="chevron"> separates the segments in plain
style; powerline style joins the coloured blocks with a solid
<img src="docs/icons/arrow.svg" height="14" alt="arrow">. The icon images are SVG outlines ...
```

6. Replace the **Test without Claude Code** section with:

````markdown
## Test without Claude Code

`test.ps1` checks the script's helper functions, then renders every payload in `samples/` against
each layout and style at several terminal widths, then runs the branch segment against temporary
git repositories:

```powershell
.\test.ps1                                # full run, about half a minute
.\test.ps1 -Columns 80                    # one width instead of 120, 60 and 20
.\test.ps1 -Config .\statusline.json      # one config instead of the four combinations
.\test.ps1 -Raw                           # show ANSI escapes as <ESC>
```

It exits non-zero if a render is empty, prints more lines than the layout allows, or is wider than
the terminal. Each render takes about 250 ms, nearly all of it `pwsh` start-up, plus a `git status`
call when the payload has no `git` object.

To try a payload of your own:

```powershell
Get-Content my-payload.json -Raw | pwsh -NoProfile -File .\statusline.ps1
Get-Content my-payload.json -Raw | pwsh -NoProfile -File .\statusline.ps1 -Config .\docs\statusline-two-line.json
```
````

7. In **Customise**, replace the `$sep` bullet with ``- `$gitTimeoutMs` is how long the branch segment waits for `git status`.`` and add ``- `Get-Palette` holds the colours for both styles.``. Replace the last sentence with: ``Segments appear in the order of the `$segmentNames` list. Use `statusline.json` to hide one; edit the list to reorder.``

8. In **Troubleshooting**, replace the "No branch segment" paragraph with:

```markdown
No branch segment: the script runs `git status` in the session's working directory. Check that
`git` is on your `PATH` and that the directory is inside a repository. If `git status` takes longer
than 1.5 seconds the segment is skipped for that refresh.

The line still wraps: the script measures width with a small approximation. Wide glyphs or emoji
in a folder or branch name can be counted short on some terminals. At very narrow widths the model
segment prints even when it does not fit.
```

9. In **Contributing**, add `pwsh docs/render-screenshot.ps1 -Config docs/statusline-two-line.json -Out docs/statusline-two-line.png` after the existing screenshot command in the paragraph.

10. In **Roadmap**, tick the first two items (`- [x] Query git directly ...`, `- [x] Optional two-line layout`).

- [ ] **Step 2: Rewrite `docs/projectbrief.md`**

Update these sections; leave the rest as is:

- **Purpose**: "with one or two lines showing the active model, context-window usage, session cost, lines changed, rate limits, mode badges, current folder, and git branch state".
- **Goals**: add "- Fit the terminal width rather than wrap." and "- Be configurable from one small JSON file without editing the script."
- **Scope** table: `statusline.ps1` "Reads JSON on stdin and `statusline.json` beside it; prints one or two coloured lines fitted to `COLUMNS`."; add `statusline.json` "Defaults for layout, style and segment toggles. Installed beside the script."; `test.ps1` "Unit-tests the script's pure functions, renders every sample across layout × style × width, and checks the git fallback in temporary repositories. `-Columns`, `-Config`, `-Raw`."; `samples/*.json` "Seven payloads: clean main, dirty feature at high context, dirty main at mid context, minimal, no git, limits with badges and lines, expired limits with default effort."; add `docs/render-screenshot.ps1` and `docs/render-icons.ps1` rows.
- **Segments** table: add rows for Lines (`cost.total_lines_added`, `total_lines_removed`; `+N` green, `−N` red, hidden when both zero), Limits (`rate_limits.five_hour`, `seven_day`; coloured by the worse), Badges (`fast_mode`, `thinking.enabled`, `effort.level`, `vim.mode`; dim glyphs). Branch row: "`git.branch`/`git.status` when present, else `git status --porcelain=v1 --branch` in `workspace.current_dir`".
- **Key design decisions**: add "**Git fallback with a hard timeout.** The documented payload has no `git` object, so the branch segment runs `git status` itself through `System.Diagnostics.Process`, kills it after 1.5 s, and omits the segment on any failure." and "**Segment records and one renderer.** Each segment is a small record (name, text, short text, colour role, bold); one function renders a line in plain or powerline style, and width fitting shrinks then drops records in a fixed order." and "**Silent config.** Any missing or invalid value in `statusline.json` falls back to its default with no output."
- **Success criteria**: "`.\test.ps1` passes: all seven samples across four configs and three widths, plus the git cases." and add "`.\install.ps1` leaves an existing `~/.claude/statusline.json` untouched."
- **Status**: "Two-line layout, powerline style, config file, width fitting and the git fallback are implemented. Segment order, thresholds, glyphs and a light palette are still constants in the script."
- **Possible future work**: replace with the spec's "Later" list: configurable segment order, thresholds, glyphs; light palette; session duration; PR number as an OSC 8 link; prompt-cache health; `owner/repo` and worktree identity; agent name; 1M-context colour scaling; `refreshInterval` in the installer; git status cache; configurable git timeout; full `wcwidth`.

- [ ] **Step 3: Check the README renders and the links resolve**

Run: `pwsh -NoProfile -c "Get-Content .\README.md | Select-String 'docs/' | ForEach-Object { $_ -replace '.*\((docs/[^)]+)\).*|.*src=\"(docs/[^\"]+)\".*', '$1$2' } | Where-Object { $_ -and -not (Test-Path $_) }"`
Expected: no output (every referenced docs path exists).

- [ ] **Step 4: Commit**

```bash
git add README.md docs/projectbrief.md
git commit -F - <<'EOF'
Document the config file, layouts, width fitting, git fallback and new test options

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FpwyeW4r1Bay98JfkxVT9F
EOF
```

---

### Task 11: Final verification

**Files:** none changed unless something fails.

- [ ] **Step 1: Full test run**

Run: `pwsh -NoProfile -File .\test.ps1`
Expected: `failed 0`, exit code 0. Paste the summary line into the completion report.

- [ ] **Step 2: Lint every script**

Run: `pwsh -NoProfile -c "Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings .\PSScriptAnalyzerSettings.psd1 }"`
Expected: no output.

- [ ] **Step 3: Confirm default output is unchanged**

Run the Task 5 comparison once more: `pwsh -NoProfile -File "$S/compare.ps1" -Old "$S/old.ps1" -New ./statusline.ps1`
Expected: `same` for all seven.

- [ ] **Step 4: Live check in a real repo**

In PowerShell from the repo root, with `COLUMNS` set to the current window width:

```powershell
$env:COLUMNS = $Host.UI.RawUI.WindowSize.Width
'{ "model": { "display_name": "Fable 5.1" }, "workspace": { "current_dir": "' + ($PWD.Path -replace '\\', '\\\\') + '" } }' | pwsh -NoProfile -File .\statusline.ps1
Remove-Item Env:COLUMNS
```

Expected: one line with the model, the folder `claude-code-statusline-ps`, and the branch `main` with a pencil if the tree is dirty. This is the case that never worked before.

- [ ] **Step 5: Working tree clean**

Run: `git status --short`
Expected: only `?? docs/session-handoff.md` (the handoff file is deliberately untracked). Nothing else pending.
