#Requires -Version 7.0
<#
.SYNOPSIS
  Tests statusline.ps1.
.DESCRIPTION
  Runs unit checks on the script's pure functions, then renders every sample in ./samples against
  every layout x style combination at each width in -Columns, then exercises the git fallback in
  temporary repositories. Exits non-zero if any check fails.
.PARAMETER Columns
  Terminal widths to test. 0 means COLUMNS unset (no fitting). Default 120, 60, 20, 0.
.PARAMETER Config
  Render only this config file instead of the generated layout x style set.
.PARAMETER Raw
  Show ANSI escapes as <ESC>.
#>
[CmdletBinding()]
param(
    [int[]] $Columns = @(120, 60, 20, 0),
    [string] $Config,
    [switch] $Raw
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSStyle.OutputRendering = 'Ansi'
$script = Join-Path $PSScriptRoot 'statusline.ps1'
$esc = [char]27
$script:passed = 0
$script:failed = 0

function Confirm-Equal($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ceq "$Expected") { $script:passed++; return }
    $script:failed++
    Write-Host "FAIL $Label" -ForegroundColor Red
    Write-Host "  expected: $("$Expected" -replace $esc, '<ESC>')"
    Write-Host "  actual:   $("$Actual" -replace $esc, '<ESC>')"
}

function Confirm-True([bool] $Condition, [string] $Label) {
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

# Starts statusline.ps1 in a child pwsh and returns before it finishes, so the caller can look at the
# machine while the render is still running. The payload goes in on stdin and both output streams are
# drained on .NET threads, so the child never blocks on a full pipe. COLUMNS is cleared for the child the
# way Invoke-StatusLine clears it for a width of 0.
function Invoke-StatusLineAsync([string] $Payload, [string] $PathPrefix) {
    $pwshPath = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $psi = [System.Diagnostics.ProcessStartInfo]::new($pwshPath)
    foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', $script)) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    [void] $psi.Environment.Remove('COLUMNS')
    if ($PathPrefix) { $psi.Environment['PATH'] = $PathPrefix + [System.IO.Path]::PathSeparator + $env:PATH }
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.Write($Payload)
    $p.StandardInput.Close()
    return @{ Process = $p; Out = $out; Err = $err }
}

# ---- Unit group: functions extracted from statusline.ps1 ----
. (Import-ScriptFunction $script @('Get-VisibleWidth', 'Read-StatusConfig', 'Get-Palette', 'Format-Inline', 'Format-Line', 'Get-FittedLine', 'Read-PorcelainStatus', 'Get-GitBranch', 'G', 'K', 'Get-ThresholdRole', 'Get-ContextSegment', 'Test-PayloadDirty', 'Get-PayloadCount', 'Get-BranchSegment'))

# Get-BranchSegment closes over these script-level names in statusline.ps1, so the test has to supply them.
$gitTimeoutMs = 1500
$iconHome = [char]::ConvertFromUtf32(0xF015)
$iconBranch = [char]::ConvertFromUtf32(0xE0A0)
$iconDirty = [char]::ConvertFromUtf32(0xF040)
$iconAhead = [char]::ConvertFromUtf32(0x2191)
$iconBehind = [char]::ConvertFromUtf32(0x2193)
$iconConflict = [char]::ConvertFromUtf32(0xF071)

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
    @{ Text = "${iconAhead}1 ${iconBehind}2"; Width = 5 }                              # ahead/behind arrows are narrow
)
foreach ($row in $widthTable) {
    $shown = $row.Text -replace $esc, '<ESC>'
    Confirm-Equal -Actual (Get-VisibleWidth $row.Text) -Expected $row.Width -Label "script width of '$shown'"
    Confirm-Equal -Actual (Measure-VisibleWidth $row.Text) -Expected $row.Width -Label "test width of '$shown'"
}

Write-Host '== unit: config' -ForegroundColor Cyan
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "statusline-test-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
# Every git probe in this file - the unit checks, the git group and the render matrix (whose child pwsh
# processes inherit this) - must stop at the temp root's parent so an ancestor repository cannot be found.
$oldGitCeiling = $env:GIT_CEILING_DIRECTORIES
$env:GIT_CEILING_DIRECTORIES = (Split-Path $tmp -Parent).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
try {
function Write-TempConfig([string] $Name, [string] $Json) {
    $p = Join-Path $tmp $Name
    [System.IO.File]::WriteAllText($p, $Json, [System.Text.UTF8Encoding]::new($false))
    return $p
}
$allSegments = @('model', 'context', 'cost', 'lines', 'limits', 'badges', 'folder', 'branch')

$c = Read-StatusConfig (Join-Path $tmp 'does-not-exist.json')
Confirm-Equal $c.Layout 'one' 'config missing: layout'
Confirm-Equal $c.Style 'plain' 'config missing: style'
Confirm-True (@($allSegments | Where-Object { -not $c.Segments[$_] }).Count -eq 0) 'config missing: all segments on'

$c = Read-StatusConfig (Write-TempConfig 'valid.json' '{ "layout": "Two", "style": "POWERLINE", "segments": { "cost": false, "lines": true } }')
Confirm-Equal $c.Layout 'two' 'config valid: layout case-insensitive'
Confirm-Equal $c.Style 'powerline' 'config valid: style case-insensitive'
Confirm-Equal $c.Segments.cost $false 'config valid: cost off'
Confirm-Equal $c.Segments.lines $true 'config valid: lines on'
Confirm-Equal $c.Segments.model $true 'config valid: unmentioned segment on'

$c = Read-StatusConfig (Write-TempConfig 'broken.json' '{ "layout": ')
Confirm-Equal $c.Layout 'one' 'config broken json: default layout'

$c = Read-StatusConfig (Write-TempConfig 'wrong-types.json' '{ "layout": "three", "style": 5, "segments": { "cost": "no", "bogus": false }, "extra": 1 }')
Confirm-Equal $c.Layout 'one' 'config bad layout value: default'
Confirm-Equal $c.Style 'plain' 'config non-string style: default'
Confirm-Equal $c.Segments.cost $true 'config non-bool segment: on'
Confirm-True (-not $c.Segments.ContainsKey('bogus')) 'config unknown segment: ignored'

$c = Read-StatusConfig (Write-TempConfig 'segments-array.json' '{ "segments": [true] }')
Confirm-Equal $c.Segments.model $true 'config segments not an object: all on'

$c = Read-StatusConfig (Write-TempConfig 'empty.json' '')
Confirm-Equal $c.Layout 'one' 'config empty file: default'

$c = Read-StatusConfig (Write-TempConfig 'array.json' '[1, 2]')
Confirm-Equal $c.Style 'plain' 'config top-level array: default'

# The config that ships with the repo has to be valid JSON and to mean what the README says it means.
$shippedConfig = Join-Path $PSScriptRoot 'statusline.json'
$shippedJson = try { Get-Content -LiteralPath $shippedConfig -Raw | ConvertFrom-Json } catch { $null }
Confirm-True ($shippedJson -is [System.Management.Automation.PSCustomObject]) 'shipped config: parses as a JSON object'
$c = Read-StatusConfig $shippedConfig
Confirm-Equal $c.Layout 'one' 'shipped config: layout one'
Confirm-Equal $c.Style 'plain' 'shipped config: style plain'
$shippedSegments = @($c.Segments.Keys)
Confirm-Equal $shippedSegments.Count 8 'shipped config: eight segments'
Confirm-True (@($shippedSegments | Where-Object { -not $c.Segments[$_] }).Count -eq 0) 'shipped config: every segment on'
$shippedFileSegments = @($shippedJson.segments.PSObject.Properties)
Confirm-Equal $shippedFileSegments.Count 8 'shipped config: the file itself lists eight segments'
# -ne coerces its right side to the left side's type, so 'true' -ne $true is False; test the type too.
Confirm-True (@($shippedFileSegments | Where-Object { $_.Value -isnot [bool] -or $_.Value -ne $true }).Count -eq 0) 'shipped config: the file itself sets them all to the boolean true'

Write-Host '== unit: renderer' -ForegroundColor Cyan
$arrow = [char]::ConvertFromUtf32(0xE0B0)
$chevron = [char]::ConvertFromUtf32(0xE0B1)
$segModel = @{ Name = 'model'; Text = 'M'; Short = $null; Role = 'model'; Bold = $true }
$segFolder = @{ Name = 'folder'; Text = 'F'; Short = $null; Role = 'folder'; Bold = $false }
$segDim = @{ Name = 'cost'; Text = 'X'; Short = $null; Role = 'dim'; Bold = $false }

Confirm-Equal (Format-Line @($segModel, $segFolder) 'plain') "$esc[1;36mM$esc[0m $esc[90m$chevron$esc[0m $esc[34mF$esc[0m" 'plain: two segments'
Confirm-Equal (Format-Line @($segDim) 'plain') "$esc[90mX$esc[0m" 'plain: one segment'
Confirm-Equal (Format-Line @() 'plain') '' 'plain: no segments'
Confirm-Equal (Format-Line @($segModel, $segFolder) 'powerline') "$esc[0;1;48;5;31;38;5;231m M $esc[38;5;31;48;5;25m$arrow$esc[0;48;5;25;38;5;231m F $esc[0m$esc[38;5;25m$arrow$esc[0m" 'powerline: two segments'
Confirm-Equal (Format-Line @($segDim) 'powerline') "$esc[0;48;5;238;38;5;250m X $esc[0m$esc[38;5;238m$arrow$esc[0m" 'powerline: one segment'
Confirm-Equal (Format-Inline 'added' '+1' 'dim' 'plain') "$esc[32m+1$esc[90m" 'inline plain restores segment colour'
Confirm-Equal (Format-Inline 'removed' '-2' 'dim' 'powerline') "$esc[38;5;203m-2$esc[38;5;250m" 'inline powerline restores segment fg'

$pal = Get-Palette
Confirm-Equal $pal.Roles.warn.Sgr '33' 'palette warn sgr'
Confirm-Equal $pal.Roles.warn.Fg 16 'palette warn fg'
Confirm-Equal $pal.Roles.branch.Bg 90 'palette branch bg'
Confirm-Equal $pal.Inline.added.Fg 46 'palette inline added fg'

Write-Host '== unit: fitting' -ForegroundColor Cyan
function Get-FitSegmentSet {
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
$fit = Get-FitSegmentSet
$line = Get-FittedLine $fit 'plain' $null
Confirm-Equal (Get-VisibleWidth $line) 44 'fit: no width means no fitting'
Confirm-Equal (Get-VisibleWidth (Get-FittedLine $fit 'plain' 44)) 44 'fit: exact fit unchanged'
$line = Get-FittedLine $fit 'plain' 43
Confirm-Equal (Get-VisibleWidth $line) 41 'fit: stage 1 shrinks limits first'
Confirm-True ($line.Contains('III') -and -not $line.Contains('IIIIII') -and $line.Contains('CCCCCC')) 'fit: only limits shortened at 43'
Confirm-Equal $fit[4].Text 'IIIIII' 'fit: input not mutated'
$line = Get-FittedLine $fit 'plain' 40
Confirm-Equal (Get-VisibleWidth $line) 38 'fit: stage 1 shrinks context second'
$line = Get-FittedLine $fit 'plain' 37
Confirm-Equal (Get-VisibleWidth $line) 33 'fit: stage 2 drops lines first'
Confirm-True (-not $line.Contains('LL') -and $line.Contains('GG')) 'fit: lines dropped, badges kept at 37'
$line = Get-FittedLine $fit 'plain' 10
Confirm-Equal (ConvertTo-PlainText $line) "M $chevron CCC" 'fit: drops down to model and short context'
$line = Get-FittedLine $fit 'plain' 6
Confirm-Equal (ConvertTo-PlainText $line) 'M' 'fit: context dropped last'
$line = Get-FittedLine $fit 'plain' 0
Confirm-Equal $line "$esc[1;36mM$esc[0m" 'fit: model alone may overflow'
Confirm-Equal (Get-FittedLine @($fit[2]) 'plain' 1) $null 'fit: line without model drops to nothing'
Confirm-Equal (Get-FittedLine @() 'plain' 40) $null 'fit: no segments gives null'
$line = Get-FittedLine $fit 'powerline' 30
Confirm-True ((Get-VisibleWidth $line) -le 30) 'fit: powerline respects width'

# A branch with a Short form (its ahead/behind counts stripped) sheds it in stage 1, after context and
# before any whole segment goes. Full width is 46 here; limits short gives 43, context 40, branch 38.
$fitBranch = Get-FitSegmentSet
$fitBranch[7] = @{ Name = 'branch'; Text = 'BBBB'; Short = 'BB'; Role = 'branch'; Bold = $false }
$line = Get-FittedLine $fitBranch 'plain' 40
Confirm-True ($line.Contains('BBBB') -and $line.Contains('CCC') -and -not $line.Contains('CCCCCC')) 'fit: context shortened before branch at 40'
$line = Get-FittedLine $fitBranch 'plain' 39
Confirm-Equal (Get-VisibleWidth $line) 38 'fit: stage 1 shrinks branch third'
Confirm-True ($line.Contains('BB') -and -not $line.Contains('BBBB') -and $line.Contains('LL')) 'fit: branch shortened, nothing dropped at 39'

Write-Host '== unit: context' -ForegroundColor Cyan
$iconCtx = [char]::ConvertFromUtf32(0xF035B)
$blockFull = [char]::ConvertFromUtf32(0x2588)
$blockLight = [char]::ConvertFromUtf32(0x2591)
function Get-ContextPayload([double] $Pct) {
    return [pscustomobject]@{ context_window = [pscustomobject]@{ used_percentage = $Pct; total_input_tokens = 1000; total_output_tokens = 0; context_window_size = 200000 } }
}

$seg = Get-ContextSegment (Get-ContextPayload 32)
$bar32 = ($blockFull * 3) + ($blockLight * 7)
Confirm-True $seg.Text.StartsWith("$iconCtx 32% ") 'context 32: text prefix'
Confirm-True $seg.Text.Contains($bar32) 'context 32: bar is 3 full + 7 light'
Confirm-Equal $seg.Role 'ok' 'context 32: role'
Confirm-Equal $seg.Short "$iconCtx 32% $bar32" 'context 32: short'

$seg = Get-ContextSegment (Get-ContextPayload 110)
$bar100 = $blockFull * 10
Confirm-True $seg.Text.StartsWith("$iconCtx 100% ") 'context 110: clamped text prefix'
Confirm-True $seg.Text.Contains($bar100) 'context 110: bar is 10 full blocks'
Confirm-Equal $seg.Role 'bad' 'context 110: role'

$seg = Get-ContextSegment (Get-ContextPayload -5)
$bar0 = $blockLight * 10
Confirm-True $seg.Text.StartsWith("$iconCtx 0% ") 'context -5: clamped text prefix'
Confirm-True $seg.Text.Contains($bar0) 'context -5: bar is 10 light blocks'
Confirm-Equal $seg.Role 'ok' 'context -5: role'

Confirm-Equal (Get-ContextSegment (Get-ContextPayload 64)).Role 'warn' 'context 64: role'
Confirm-Equal (Get-ContextSegment (Get-ContextPayload 85)).Role 'bad' 'context 85: role'

Confirm-Equal (Get-ContextSegment ([pscustomobject]@{})) $null 'context: missing context_window'

Write-Host '== unit: porcelain' -ForegroundColor Cyan
$r = Read-PorcelainStatus "## main...origin/main [ahead 1]`n"
Confirm-Equal $r.Branch 'main' 'porcelain: tracking branch'
Confirm-Equal $r.Dirty $false 'porcelain: clean'
Confirm-Equal $r.Ahead 1 'porcelain: ahead only gives the count'
Confirm-Equal $r.Behind 0 'porcelain: ahead only gives behind 0'
$r = Read-PorcelainStatus "## main...origin/main [behind 2]`n"
Confirm-Equal $r.Ahead 0 'porcelain: behind only gives ahead 0'
Confirm-Equal $r.Behind 2 'porcelain: behind only gives the count'
$r = Read-PorcelainStatus "## main...origin/main [ahead 1, behind 2]`n"
Confirm-Equal $r.Ahead 1 'porcelain: both gives ahead'
Confirm-Equal $r.Behind 2 'porcelain: both gives behind'
Confirm-Equal $r.Branch 'main' 'porcelain: both keeps the branch name'
$r = Read-PorcelainStatus "## main...origin/main [gone]`n"
Confirm-Equal $r.Ahead 0 'porcelain: gone gives ahead 0'
Confirm-Equal $r.Behind 0 'porcelain: gone gives behind 0'
$r = Read-PorcelainStatus "## main`n"
Confirm-Equal $r.Ahead 0 'porcelain: no bracket gives ahead 0'
Confirm-Equal $r.Behind 0 'porcelain: no bracket gives behind 0'
$r = Read-PorcelainStatus "## main`n M file.txt`n"
Confirm-Equal $r.Dirty $true 'porcelain: modified is dirty'
Confirm-Equal $r.Modified 1 'porcelain: modified counts as modified'
Confirm-Equal $r.Staged 0 'porcelain: modified is not staged'
$r = Read-PorcelainStatus "## main`r`n?? new.txt`r`n"
Confirm-Equal $r.Dirty $true 'porcelain: untracked is dirty (CRLF)'
Confirm-Equal $r.Untracked 1 'porcelain: untracked counts as untracked (CRLF)'
Confirm-Equal $r.Staged 0 'porcelain: untracked is not staged'
$r = Read-PorcelainStatus "## main`n M a`nA  b`n?? c`n"
Confirm-Equal $r.Staged 1 'porcelain: mixed block staged'
Confirm-Equal $r.Modified 1 'porcelain: mixed block modified'
Confirm-Equal $r.Untracked 1 'porcelain: mixed block untracked'
Confirm-Equal $r.Conflicts 0 'porcelain: mixed block no conflicts'
Confirm-Equal $r.Dirty $true 'porcelain: mixed block dirty'
$r = Read-PorcelainStatus "## main`nUU a`n"
Confirm-Equal $r.Conflicts 1 'porcelain: conflict counts as conflict'
Confirm-Equal $r.Staged 0 'porcelain: conflict is not staged'
Confirm-Equal $r.Modified 0 'porcelain: conflict is not modified'
Confirm-Equal $r.Dirty $true 'porcelain: conflict is dirty'
$r = Read-PorcelainStatus "## main`nMM a`n"
Confirm-Equal $r.Staged 1 'porcelain: staged and modified counts as staged'
Confirm-Equal $r.Modified 1 'porcelain: staged and modified counts as modified'
$r = Read-PorcelainStatus "## main`n D gone.txt`n"
Confirm-Equal $r.Modified 1 'porcelain: work tree deletion counts as modified'
Confirm-Equal $r.Staged 0 'porcelain: work tree deletion is not staged'
Confirm-Equal $r.Dirty $true 'porcelain: work tree deletion is dirty'
$r = Read-PorcelainStatus "## main`n T mode.txt`n"
Confirm-Equal $r.Modified 1 'porcelain: type change counts as modified'
Confirm-Equal $r.Dirty $true 'porcelain: type change is dirty'
$r = Read-PorcelainStatus "## main`nD  staged-gone.txt`n"
Confirm-Equal $r.Staged 1 'porcelain: staged deletion counts as staged'
Confirm-Equal $r.Modified 0 'porcelain: staged deletion is not modified'
$r = Read-PorcelainStatus "## main`n"
Confirm-Equal $r.Staged 0 'porcelain: clean gives staged 0'
Confirm-Equal $r.Modified 0 'porcelain: clean gives modified 0'
Confirm-Equal $r.Untracked 0 'porcelain: clean gives untracked 0'
Confirm-Equal $r.Conflicts 0 'porcelain: clean gives conflicts 0'
Confirm-Equal $r.Dirty $false 'porcelain: clean is not dirty'
$r = Read-PorcelainStatus "## main`n`n   `n"
Confirm-Equal $r.Dirty $false 'porcelain: blank and whitespace-only lines count as nothing'
$r = Read-PorcelainStatus "## feature/x...origin/feature/x`n"
Confirm-Equal $r.Branch 'feature/x' 'porcelain: feature branch'
$r = Read-PorcelainStatus "## No commits yet on main`n"
Confirm-Equal $r.Branch 'main' 'porcelain: unborn'
Confirm-Equal $r.Dirty $false 'porcelain: unborn clean'
$r = Read-PorcelainStatus "## No commits yet on master...origin/master [gone]`n"
Confirm-Equal $r.Branch 'master' 'porcelain: unborn with upstream'
Confirm-Equal $r.Dirty $false 'porcelain: unborn with upstream clean'
Confirm-Equal $r.Ahead 0 'porcelain: unborn with upstream ahead 0'
Confirm-Equal $r.Behind 0 'porcelain: unborn with upstream behind 0'
$r = Read-PorcelainStatus "## HEAD (no branch)`n"
Confirm-Equal $r.Branch 'detached' 'porcelain: detached'
Confirm-Equal (Read-PorcelainStatus "fatal: not a git repository`n") $null 'porcelain: no header'
Confirm-Equal (Read-PorcelainStatus '') $null 'porcelain: empty'

Write-Host '== unit: payload counts' -ForegroundColor Cyan
# ConvertFrom-Json hands the sample counts over as Int64, so the object cases go through it.
$c = Get-PayloadCount ('{"staged":2,"modified":1,"untracked":3,"conflicts":1}' | ConvertFrom-Json)
Confirm-Equal $c.Staged 2 'payload counts: staged'
Confirm-Equal $c.Modified 1 'payload counts: modified'
Confirm-Equal $c.Untracked 3 'payload counts: untracked'
Confirm-Equal $c.Conflicts 1 'payload counts: conflicts'
$c = Get-PayloadCount ('{"modified":2,"untracked":1}' | ConvertFrom-Json)
Confirm-Equal $c.Staged 0 'payload counts: missing staged is 0'
Confirm-Equal $c.Modified 2 'payload counts: two of four modified'
Confirm-Equal $c.Untracked 1 'payload counts: two of four untracked'
Confirm-Equal $c.Conflicts 0 'payload counts: missing conflicts is 0'
foreach ($status in @('clean', 'modified', $null)) {
    $c = Get-PayloadCount $status
    $shown = if ($null -eq $status) { 'null' } else { "'$status'" }
    Confirm-True (($c.Staged + $c.Modified + $c.Untracked + $c.Conflicts) -eq 0 -and $c.Staged -is [int]) "payload counts: $shown status gives four zeros"
}

Write-Host '== unit: branch segment' -ForegroundColor Cyan
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'main'; status = 'clean' } })
Confirm-True ($null -ne $seg -and $seg.Text.Contains('main')) "branch payload clean: text has the branch name, got '$($seg.Text)'"
Confirm-Equal $seg.Text "$iconHome main" 'branch payload clean: home icon, no pencil'
Confirm-Equal $seg.Role 'branch' 'branch payload clean: role'

$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = @{ modified = 2 } } })
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ~2 $iconDirty" 'branch payload dirty counts: branch icon, modified count, pencil'
Confirm-Equal $seg.Role 'warn' 'branch payload dirty counts: role'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch payload dirty counts: short drops the count and keeps the pencil'

$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = @{ modified = 2; untracked = 1 } } }) @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ~2 ?1 $iconDirty" 'branch payload modified and untracked: tilde then question mark'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[90m~2$esc[33m $esc[90m?1$esc[33m $iconDirty" 'branch payload modified and untracked: counts dim, warn colour restored'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch payload modified and untracked: short has no counts'
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = 'modified' } }) @{ Style = 'plain' }
Confirm-Equal $seg.Text "$iconBranch feature/x $iconDirty" 'branch payload string status: pencil only, no counts'
Confirm-Equal $seg.Role 'warn' 'branch payload string status: role'
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = @{ conflicts = 1 } } }) @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ${iconConflict}1 $iconDirty" 'branch payload conflict: conflict glyph and count before the pencil'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[31m${iconConflict}1$esc[33m $iconDirty" 'branch payload conflict: removed colour, warn colour restored'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch payload conflict: short has no conflict glyph'
Confirm-Equal $seg.Role 'warn' 'branch payload conflict: role'

Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{ git = @{} }))) 'branch payload git object with no branch: segment omitted'
Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{ git = @{ branch = '' } }))) 'branch payload empty branch: segment omitted'

# Ahead and behind counts only ever come from the git probe, so stand in for Get-GitBranch here and put
# the real one back afterwards. The "not a repo" checks below then double as proof the restore worked.
function Get-GitBranch([string] $Dir, [int] $TimeoutMs) { return $script:mockGitBranch }
$probePayload = [pscustomobject]@{ workspace = @{ current_dir = 'x' } }
$script:mockGitBranch = @{ Branch = 'feature/x'; Dirty = $false; Ahead = 1; Behind = 2 }
$seg = Get-BranchSegment $probePayload
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ${iconAhead}1 ${iconBehind}2" 'branch counts: ahead then behind after the name'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[90m${iconAhead}1$esc[35m $esc[90m${iconBehind}2$esc[35m" 'branch counts: arrows dim, branch colour restored (plain, no cfg)'
Confirm-Equal $seg.Short "$iconBranch feature/x" 'branch counts: short has no arrows'
Confirm-Equal $seg.Role 'branch' 'branch counts: role'
$seg = Get-BranchSegment $probePayload @{ Style = 'powerline' }
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[38;5;245m${iconAhead}1$esc[38;5;231m $esc[38;5;245m${iconBehind}2$esc[38;5;231m" 'branch counts: powerline arrows restore the block fg'
$script:mockGitBranch = @{ Branch = 'topic'; Dirty = $false; Ahead = 2; Behind = 0 }
$seg = Get-BranchSegment $probePayload @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch topic ${iconAhead}2" 'branch ahead only: no behind arrow'
$script:mockGitBranch = @{ Branch = 'main'; Dirty = $false; Ahead = 0; Behind = 3 }
$seg = Get-BranchSegment $probePayload @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconHome main ${iconBehind}3" 'branch behind only: no ahead arrow'
$script:mockGitBranch = @{ Branch = 'main'; Dirty = $false; Ahead = 0; Behind = 0 }
$seg = Get-BranchSegment $probePayload @{ Style = 'plain' }
Confirm-Equal $seg.Text "$iconHome main" 'branch zero counts: exactly the old text, no escapes'
Confirm-Equal $seg.Short "$iconHome main" 'branch zero counts: short is the same text'
$script:mockGitBranch = @{ Branch = 'feature/x'; Dirty = $true; Ahead = 1; Behind = 1 }
$seg = Get-BranchSegment $probePayload @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ${iconAhead}1 ${iconBehind}1 $iconDirty" 'branch dirty with counts: pencil last'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[90m${iconAhead}1$esc[33m $esc[90m${iconBehind}1$esc[33m $iconDirty" 'branch dirty with counts: arrows restore the warn colour'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch dirty with counts: short keeps the pencil, drops the arrows'
Confirm-Equal $seg.Role 'warn' 'branch dirty with counts: role'
$script:mockGitBranch = @{ Branch = 'feature/x'; Dirty = $true; Ahead = 1; Behind = 2; Staged = 2; Modified = 1; Untracked = 3; Conflicts = 1 }
$seg = Get-BranchSegment $probePayload @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ${iconAhead}1 ${iconBehind}2 +2 ~1 ?3 ${iconConflict}1 $iconDirty" 'branch everything: arrows, staged, modified, untracked, conflict, pencil'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[90m${iconAhead}1$esc[33m $esc[90m${iconBehind}2$esc[33m $esc[90m+2$esc[33m $esc[90m~1$esc[33m $esc[90m?3$esc[33m $esc[31m${iconConflict}1$esc[33m $iconDirty" 'branch everything: counts dim, conflict red, warn colour restored after each'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch everything: short is icon, name, pencil'
$script:mockGitBranch = @{ Branch = 'main'; Dirty = $true; Ahead = 0; Behind = 0; Staged = 1; Modified = 2; Untracked = 0; Conflicts = 0 }
$seg = Get-BranchSegment $probePayload @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconHome main +1 ~2 $iconDirty" 'branch file counts only: no arrows, zero counts omitted'
. (Import-ScriptFunction $script @('Get-GitBranch'))

# No git key at all falls through to Get-GitBranch. GIT_CEILING_DIRECTORIES (set above) stops the probe
# from walking out of the temp tree, so this cannot find a repository on the machine running the test.
$branchProbeDir = Join-Path $tmp 'branch-unit-not-a-repo'
New-Item -ItemType Directory -Force $branchProbeDir | Out-Null
Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{ workspace = @{ current_dir = $branchProbeDir } }))) 'branch no git key: falls through to git and finds no repo'
Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{}))) 'branch no git key and no dir: segment omitted'

Write-Host '== git' -ForegroundColor Cyan
$gitConfigEmpty = Join-Path $tmp 'gitconfig-empty'
[System.IO.File]::WriteAllText($gitConfigEmpty, '', [System.Text.UTF8Encoding]::new($false))
$oldGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
$oldGitConfigNoSystem = $env:GIT_CONFIG_NOSYSTEM
$env:GIT_CONFIG_GLOBAL = $gitConfigEmpty
$env:GIT_CONFIG_NOSYSTEM = '1'
try {
$gitCfg = @('-c', 'user.name=test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false')
function Initialize-TestRepo([string] $Name) {
    $p = Join-Path $tmp $Name
    New-Item -ItemType Directory -Force $p | Out-Null
    git init -q -b main $p
    return $p
}
function Add-Commit([string] $Path, [string] $Content = 'hello') {
    Set-Content (Join-Path $Path 'file.txt') $Content
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
    # A local branch tracking another local branch gives git status a real [ahead N] / [behind N]
    # bracket with no remote involved: topic tracks main and carries one commit main does not.
    $ahead = Initialize-TestRepo 'repo-ahead'; Add-Commit $ahead
    git -C $ahead checkout -q -b topic; git -C $ahead branch -q --set-upstream-to=main; Add-Commit $ahead 'topic'
    # The mirror image: main tracks a topic that is one commit further on.
    $behind = Initialize-TestRepo 'repo-behind'; Add-Commit $behind
    git -C $behind checkout -q -b topic; Add-Commit $behind 'topic'; git -C $behind checkout -q main; git -C $behind branch -q --set-upstream-to=topic
    # One file in each of the three counted states: a new file added to the index, the committed file
    # edited but not added, and a new file git has never seen.
    $mixed = Initialize-TestRepo 'repo-mixed'; Add-Commit $mixed
    Set-Content (Join-Path $mixed 'staged.txt') 'x'; git -C $mixed add staged.txt
    Set-Content (Join-Path $mixed 'file.txt') 'changed'
    Set-Content (Join-Path $mixed 'new.txt') 'y'

    # In-process checks of Get-GitBranch itself
    $g = Get-GitBranch $clean $gitTimeoutMs
    Confirm-Equal $g.Branch 'main' 'Get-GitBranch: clean branch'
    Confirm-Equal $g.Dirty $false 'Get-GitBranch: clean not dirty'
    Confirm-Equal $g.Ahead 0 'Get-GitBranch: no upstream means ahead 0'
    Confirm-Equal $g.Behind 0 'Get-GitBranch: no upstream means behind 0'
    $g = Get-GitBranch $ahead $gitTimeoutMs
    Confirm-Equal $g.Branch 'topic' 'Get-GitBranch: ahead fixture branch'
    Confirm-Equal $g.Ahead 1 'Get-GitBranch: one commit ahead of the tracked branch'
    Confirm-Equal $g.Behind 0 'Get-GitBranch: ahead fixture is not behind'
    $g = Get-GitBranch $behind $gitTimeoutMs
    Confirm-Equal $g.Branch 'main' 'Get-GitBranch: behind fixture branch'
    Confirm-Equal $g.Ahead 0 'Get-GitBranch: behind fixture is not ahead'
    Confirm-Equal $g.Behind 1 'Get-GitBranch: one commit behind the tracked branch'
    $g = Get-GitBranch $mixed $gitTimeoutMs
    Confirm-Equal $g.Staged 1 'Get-GitBranch: mixed fixture has one staged file'
    Confirm-Equal $g.Modified 1 'Get-GitBranch: mixed fixture has one modified file'
    Confirm-Equal $g.Untracked 1 'Get-GitBranch: mixed fixture has one untracked file'
    Confirm-Equal $g.Conflicts 0 'Get-GitBranch: mixed fixture has no conflicts'
    Confirm-Equal $g.Dirty $true 'Get-GitBranch: mixed fixture is dirty'
    $g = Get-GitBranch $dirtyUntracked $gitTimeoutMs
    Confirm-Equal $g.Dirty $true 'Get-GitBranch: untracked dirty'
    Confirm-Equal (Get-GitBranch (Join-Path $tmp 'nowhere') $gitTimeoutMs) $null 'Get-GitBranch: missing dir'

    # Positive controls for the "not a repo" case below, which on its own would also pass if the probe
    # never ran. The first shows the walk upwards really happens and that the ceiling above $tmp does not
    # block it: a plain directory inside a fixture repo still reports that repo's branch. The second
    # shows GIT_CEILING_DIRECTORIES is what stops the walk - with the ceiling moved onto the trap repo the
    # same directory finds nothing, and with the normal ceiling back it finds the trap's branch.
    $nested = Join-Path $clean 'sub'
    New-Item -ItemType Directory -Force $nested | Out-Null
    Confirm-Equal (Get-GitBranch $nested $gitTimeoutMs).Branch 'main' 'Get-GitBranch: a directory inside a repo reports that repo'

    $trapRepo = Initialize-TestRepo 'trap'; Add-Commit $trapRepo
    $trapChild = Join-Path $trapRepo 'child'
    New-Item -ItemType Directory -Force $trapChild | Out-Null
    $ceiling = $env:GIT_CEILING_DIRECTORIES
    $blocked = 'the probe did not run'
    try {
        $env:GIT_CEILING_DIRECTORIES = $trapRepo
        $blocked = Get-GitBranch $trapChild $gitTimeoutMs
    } finally { $env:GIT_CEILING_DIRECTORIES = $ceiling }
    Confirm-Equal $blocked $null 'Get-GitBranch: a ceiling on the parent repo hides it'
    Confirm-Equal (Get-GitBranch $trapChild $gitTimeoutMs).Branch 'main' 'Get-GitBranch: the same directory finds the repo once the ceiling moves back'

    $gitCases.Add(@{ Name = 'clean';           Dir = $clean;          Has = "$iconHome main";              Not = $iconDirty })
    $gitCases.Add(@{ Name = 'dirty tracked';   Dir = $dirtyTracked;   Has = "$iconHome main ~1 $iconDirty";  Raw = "$esc[33m" })
    $gitCases.Add(@{ Name = 'dirty untracked'; Dir = $dirtyUntracked; Has = "$iconHome main ?1 $iconDirty" })
    $gitCases.Add(@{ Name = 'mixed';           Dir = $mixed;          Has = "$iconHome main +1 ~1 ?1 $iconDirty"; Not = $iconConflict; Raw = "$esc[90m+1$esc[33m $esc[90m~1$esc[33m $esc[90m?1$esc[33m" })
    $gitCases.Add(@{ Name = 'feature';         Dir = $feature;        Has = "$iconBranch feature/x" })
    $gitCases.Add(@{ Name = 'unborn';          Dir = $unborn;         Has = "$iconHome main";              Not = $iconDirty })
    $gitCases.Add(@{ Name = 'detached';        Dir = $detached;       Has = "$iconBranch detached" })
    $gitCases.Add(@{ Name = 'ahead';           Dir = $ahead;          Has = "$iconBranch topic ${iconAhead}1"; Not = $iconBehind; Raw = "$esc[90m${iconAhead}1$esc[35m" })
    $gitCases.Add(@{ Name = 'behind';          Dir = $behind;         Has = "$iconHome main ${iconBehind}1";   Not = $iconAhead })
}
$notRepo = Join-Path $tmp 'not-a-repo'; New-Item -ItemType Directory -Force $notRepo | Out-Null
$gitCases.Add(@{ Name = 'not a repo'; Dir = $notRepo; NoBranch = $true })
# Each fake writes a marker file next to itself so the test can prove it really ran. The marker path is
# %~dp0-relative so the batch file stays pure ASCII however the temp path is spelled. The hang fake's ping
# child must be gone afterwards, which proves Kill($true) took the tree down; its -w value tags the
# process so concurrent runs of this test do not see each other's pings. The tag is arithmetic, not
# concatenation: "1000$PID" would overflow ping's 32-bit -w once the PID reached seven digits.
$pingTag = 1000 + $PID
$fakeFail = Write-FakeGit 'fake-fail' "echo ran > `"%~dp0fake.ran`"`r`necho fatal: not a git repository 1>&2`r`nexit 128"
$fakeHang = Write-FakeGit 'fake-hang' "echo ran > `"%~dp0fake.ran`"`r`nping -n 11 -w $pingTag 127.0.0.1 > nul`r`nexit 0"
$gitCases.Add(@{ Name = 'git fails'; Dir = $notRepo; NoBranch = $true; NoStderr = $true; Marker = (Join-Path $fakeFail 'fake.ran')
                 PathPrefix = $fakeFail })
$gitCases.Add(@{ Name = 'git hangs'; Dir = $notRepo; NoBranch = $true; NoStderr = $true; MinMs = 1500; MaxMs = 4000; Marker = (Join-Path $fakeHang 'fake.ran'); NoPing = $true
                 PathPrefix = $fakeHang })

function Get-FakePingCount([string] $Tag) {
    return @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "-n 11 -w $Tag " }).Count
}

foreach ($case in $gitCases) {
    $r = Invoke-StatusLine (Get-GitPayload $case.Dir) $null 0 $case.PathPrefix
    $rawOut = $r.Lines -join "`n"
    $text = ConvertTo-PlainText $rawOut
    $label = "git $($case.Name)"
    Confirm-True ($text.Contains('M')) "${label}: model still printed"
    if ($case.Has) { Confirm-True ($text.Contains($case.Has)) "${label}: expected '$($case.Has)' in '$text'" }
    if ($case.Not) { Confirm-True (-not $text.Contains($case.Not)) "${label}: unexpected '$($case.Not)' in '$text'" }
    if ($case.Raw) { Confirm-True ($rawOut.Contains($case.Raw)) "${label}: expected colour $($case.Raw -replace $esc, '<ESC>')" }
    if ($case.NoBranch) { Confirm-True (-not $text.Contains($iconHome) -and -not $text.Contains($iconBranch)) "${label}: branch segment omitted, got '$text'" }
    if ($case.NoStderr) { Confirm-True ($r.Err.Count -eq 0) "${label}: nothing on stderr, got '$($r.Err -join ' | ')'" }
    if ($case.Marker) { Confirm-True (Test-Path $case.Marker) "${label}: fake git was actually launched" }
    if ($case.MinMs) { Confirm-True ($r.Ms -ge $case.MinMs) "${label}: waited the full timeout ($($r.Ms) ms, expected at least $($case.MinMs))" }
    if ($case.MaxMs) { Confirm-True ($r.Ms -lt $case.MaxMs) "${label}: finished in $($r.Ms) ms (limit $($case.MaxMs))" }
    if ($case.NoPing) { Start-Sleep -Milliseconds 300; Confirm-True ((Get-FakePingCount $pingTag) -eq 0) "${label}: ping child killed with the tree" }
    Write-Host ("{0,-40} {1,5:N0} ms  {2}" -f $case.Name, $r.Ms, $text)
}

# Positive control for the hang case's "no ping is left behind": that assertion would also pass if the
# fake had never started a ping. Run the same fake once more without waiting for the render, and watch
# the ping from outside - it has to be running while the render is still blocked, and gone once the
# render has exited.
$hang = Invoke-StatusLineAsync (Get-GitPayload $notRepo) $fakeHang
$midPings = 0
$midMs = 0
$hangSw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Start-Sleep -Milliseconds 500
    $midPings = Get-FakePingCount $pingTag
    # pwsh's own start-up is not instant, so allow a little longer for the child to reach the ping.
    while ($midPings -lt 1 -and $hangSw.ElapsedMilliseconds -lt 5000 -and -not $hang.Process.HasExited) {
        Start-Sleep -Milliseconds 100
        $midPings = Get-FakePingCount $pingTag
    }
    $midMs = $hangSw.ElapsedMilliseconds
    Confirm-True ($midPings -ge 1) "git hangs control: ping child running $midMs ms into the render (count $midPings)"
    Confirm-True ($hang.Process.WaitForExit(30000)) 'git hangs control: the render exited'
    [void] [System.Threading.Tasks.Task]::WaitAll(@($hang.Out, $hang.Err), 5000)
} finally {
    if (-not $hang.Process.HasExited) { try { $hang.Process.Kill($true) } catch { $null = $_ } }
    $hang.Process.Dispose()
}
$hangSw.Stop()
Start-Sleep -Milliseconds 300
Confirm-True ((Get-FakePingCount $pingTag) -eq 0) 'git hangs control: ping child gone once the render exited'
Write-Host ("{0,-40} {1,5:N0} ms  {2} ping(s) at {3} ms, 0 after" -f 'git hangs control', $hangSw.ElapsedMilliseconds, $midPings, $midMs)
} finally {
    if ($null -ne $oldGitConfigGlobal) { $env:GIT_CONFIG_GLOBAL = $oldGitConfigGlobal } else { Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue }
    if ($null -ne $oldGitConfigNoSystem) { $env:GIT_CONFIG_NOSYSTEM = $oldGitConfigNoSystem } else { Remove-Item Env:GIT_CONFIG_NOSYSTEM -ErrorAction SilentlyContinue }
}

# ---- Render matrix: samples x configs x widths ----
$sampleFiles = Get-ChildItem (Join-Path $PSScriptRoot 'samples') -Filter *.json | Sort-Object Name
$sample06 = $sampleFiles | Where-Object { $_.Name -eq '06-limits-badges-lines.json' }

# A sample without a `git` object makes the script probe workspace.current_dir with `git status`, and the
# samples spell that path out (C:\repo, C:\Users\jim\Downloads). GIT_CEILING_DIRECTORIES only stops the
# walk upwards, so on a machine where one of those paths is a repository the matrix would render a branch
# the presence table says is absent. Point those payloads at an empty directory of the same name under
# $tmp\probe instead: the folder segment prints the same leaf, and the probe is provably not a repository.
# The probe dirs get their own parent so a sample leaf can never collide with one of the git fixtures the
# group above creates directly under $tmp (a sample whose folder was called `repo-clean` would otherwise
# be pointed at a real repository). The rewrite is in memory, for every config including a user-supplied
# -Config; the sample files never change.
function Convert-ToHermeticPayload([string] $Path) {
    $text = Get-Content -LiteralPath $Path -Raw
    $json = $text | ConvertFrom-Json
    if ($null -ne $json.git) { return $text }
    $dir = $json.workspace.current_dir
    if (-not $dir) { return $text }
    $probe = Join-Path (Join-Path $tmp 'probe') (Split-Path $dir -Leaf)
    New-Item -ItemType Directory -Force $probe | Out-Null
    $json.workspace.current_dir = $probe
    return ($json | ConvertTo-Json -Depth 20 -Compress)
}
$samplePayloads = @{}
foreach ($sample in $sampleFiles) { $samplePayloads[$sample.Name] = Convert-ToHermeticPayload $sample.FullName }
$iconModel = [char]::ConvertFromUtf32(0xF06A9)
$iconCost = [char]::ConvertFromUtf32(0xF0155)
$iconFolder = [char]::ConvertFromUtf32(0xF07C)
$iconLines = [char]::ConvertFromUtf32(0xF121)
$iconLimits = [char]::ConvertFromUtf32(0xF0E4)
$iconFast = [char]::ConvertFromUtf32(0xF0E7)
$iconThink = [char]::ConvertFromUtf32(0xF09D0)
$iconEffort = [char]::ConvertFromUtf32(0xF04C5)
$iconVim = [char]::ConvertFromUtf32(0xE62B)
$minus = [char]::ConvertFromUtf32(0x2212)
# Glyphs a sample must NOT show when every segment is enabled. This is the variant coverage the markers
# below cannot give, because a marker can only say that something rendered: a clean tree carries no
# pencil, a feature branch no home icon, a payload without rate limits no tachometer, and 07's badges
# are all off or at the default level. Rows that only said "this glyph is present" are gone - the
# per-segment markers assert that, by value, for every visible segment.
$absentGlyphs = @{
    '01-main-clean.json'                    = @(
        @{ Icon = $iconDirty; Name = 'pencil' }
        @{ Icon = $iconLines; Name = 'lines' }
        @{ Icon = $iconLimits; Name = 'limits' }
        @{ Icon = $iconBranch; Name = 'branch' }
    )
    '02-feature-dirty-high.json'            = @(
        @{ Icon = $iconHome; Name = 'home' }
        @{ Icon = $iconLines; Name = 'lines' }
        @{ Icon = $iconLimits; Name = 'limits' }
    )
    '03-main-dirty-mid.json'                = @(
        @{ Icon = $iconLines; Name = 'lines' }
        @{ Icon = $iconLimits; Name = 'limits' }
    )
    '04-minimal.json'                       = @(
        @{ Icon = $iconCtx; Name = 'context' }
        @{ Icon = $iconFolder; Name = 'folder' }
    )
    '05-no-git.json'                        = @(
        @{ Icon = $iconHome; Name = 'home' }
        @{ Icon = $iconBranch; Name = 'branch' }
        @{ Icon = $iconCost; Name = 'cost' }
    )
    '06-limits-badges-lines.json'           = @(
        @{ Icon = $iconDirty; Name = 'pencil' }
    )
    '07-limits-expired-default-effort.json' = @(
        @{ Icon = $iconFast; Name = 'fast' }
        @{ Icon = $iconThink; Name = 'think' }
        @{ Icon = $iconEffort; Name = 'effort' }
        @{ Icon = $iconVim; Name = 'vim' }
        @{ Icon = $iconHome; Name = 'home' }
        @{ Icon = $iconBranch; Name = 'branch' }
    )
}
# What each sample renders when every segment is enabled and nothing is fitted away: 04 carries nothing
# but a model, 05 and 07 have no git object and their probe directory is not a repository, and 07's
# badges are all off or at the default level. Intersected with a config's enabled set this gives the
# segments the line should actually show, which is what the gates below are built on.
$sampleSegments = @{
    '01-main-clean.json'                    = @('model', 'context', 'cost', 'folder', 'branch')
    '02-feature-dirty-high.json'            = @('model', 'context', 'cost', 'folder', 'branch')
    '03-main-dirty-mid.json'                = @('model', 'context', 'cost', 'folder', 'branch')
    '04-minimal.json'                       = @('model')
    '05-no-git.json'                        = @('model', 'context', 'folder')
    '06-limits-badges-lines.json'           = @('model', 'context', 'cost', 'lines', 'limits', 'badges', 'folder', 'branch')
    '07-limits-expired-default-effort.json' = @('model', 'context', 'cost', 'lines', 'limits', 'folder')
}
# One marker per segment per sample: the segment's glyph plus the value this payload gives it, spelled
# the way it reaches the line once the escapes are stripped. Every visible segment has to put its marker
# on its own row, so a segment that stops rendering fails by name rather than slipping past the absence
# table, which only names a few glyphs per sample. Money is formatted the way the script formats it so
# the check survives a culture that writes 12,50. Markers stop short of anything that moves: 06's limits
# segment carries a countdown to a 2100 reset, so its marker ends at the percentage. Badges and branch
# have no single glyph of their own, so their markers are the whole segment text.
$sampleMarkers = @{
    '01-main-clean.json'                    = @{
        model  = "$iconModel Fable 5.1"; context = "$iconCtx 8%"; cost = "$iconCost `$$('{0:N2}' -f 0.4312)"
        folder = "$iconFolder my-project"; branch = "$iconHome main"
    }
    '02-feature-dirty-high.json'            = @{
        model  = "$iconModel Fable 5.1"; context = "$iconCtx 90%"; cost = "$iconCost `$$('{0:N2}' -f 12.5)"
        folder = "$iconFolder repo"; branch = "$iconBranch feature/x ~2 ?1 $iconDirty"
    }
    '03-main-dirty-mid.json'                = @{
        model  = "$iconModel Opus 5"; context = "$iconCtx 65%"; cost = "$iconCost `$$('{0:N2}' -f 3.07)"
        folder = "$iconFolder project"; branch = "$iconHome main $iconDirty"
    }
    '04-minimal.json'                       = @{
        model = "$iconModel Fable 5.1"
    }
    '05-no-git.json'                        = @{
        model = "$iconModel Sonnet 5"; context = "$iconCtx 25%"; folder = "$iconFolder Downloads"
    }
    '06-limits-badges-lines.json'           = @{
        model  = "$iconModel Fable 5.1"; context = "$iconCtx 32%"; cost = "$iconCost `$$('{0:N2}' -f 1.07)"
        lines  = "$iconLines +156 ${minus}23"; limits = "$iconLimits 5h 24%"
        badges = "$iconFast $iconThink $iconEffort xhigh $iconVim NORMAL"
        folder = "$iconFolder my-project"; branch = "$iconHome main"
    }
    '07-limits-expired-default-effort.json' = @{
        model = "$iconModel Opus 5"; context = "$iconCtx 5%"; cost = "$iconCost `$$('{0:N2}' -f 0.02)"
        lines = "$iconLines +0 ${minus}4"; limits = "$iconLimits 5h 61% 7d 12%"
        folder = "$iconFolder repo"
    }
}
# Every glyph a segment can put on the line: a segment the config turns off must show none of them, and
# the two-line checks use them to say which row a segment landed on.
$segmentGlyphs = @{
    model   = @($iconModel)
    context = @($iconCtx)
    cost    = @($iconCost)
    lines   = @($iconLines)
    limits  = @($iconLimits)
    badges  = @($iconFast, $iconThink, $iconEffort, $iconVim)
    folder  = @($iconFolder)
    branch  = @($iconHome, $iconBranch, $iconDirty, $iconAhead, $iconBehind, $iconConflict)
}
# The segment behind each row of the absence table, so a row can be skipped when its segment is off
# (the per-segment absence assertions cover that case instead, for every glyph the segment owns).
$glyphSegment = @{
    context = 'context'; cost = 'cost'; folder = 'folder'; lines = 'lines'; limits = 'limits'
    home = 'branch'; pencil = 'branch'; branch = 'branch'
    fast = 'badges'; think = 'badges'; effort = 'badges'; vim = 'badges'
}
# statusline.ps1's own line sets, mirrored here so the test knows which segments share a line.
$layoutRows = @{
    one = @(, @('model', 'context', 'cost', 'lines', 'limits', 'badges', 'folder', 'branch'))
    two = @(@('model', 'folder', 'branch', 'badges'), @('context', 'limits', 'cost', 'lines'))
}
$modelOnlyPath = @{}
foreach ($style in @('plain', 'powerline')) {
    $modelOnlyPath[$style] = Write-TempConfig "model-only-$style.json" ('{ "layout": "one", "style": "' + $style + '", "segments": { "context": false, "cost": false, "lines": false, "limits": false, "badges": false, "folder": false, "branch": false } }')
}
# Each config carries the set of segments it leaves enabled. Every assertion below is gated on that set
# rather than on "all segments on", so a user-supplied -Config keeps each check its own segment set still
# justifies: the glyphs of its enabled segments, the absence of the glyphs of the ones it turns off, the
# separator style wherever a line still holds two segments, and the two-line layout's row contents.
$configSet = [System.Collections.Generic.List[hashtable]]::new()
if ($Config) {
    $resolved = (Resolve-Path $Config).Path
    $parsed = Read-StatusConfig $resolved
    $off = @($allSegments | Where-Object { -not $parsed.Segments[$_] })
    if ($off.Count -gt 0) { Write-Host "note: $(Split-Path $resolved -Leaf) turns off $($off -join ', '); those segments are checked for absence instead" -ForegroundColor Yellow }
    $configSet.Add(@{ Name = (Split-Path $resolved -Leaf); Path = $resolved; Layout = $parsed.Layout; Style = $parsed.Style; Enabled = $parsed.Segments })
} else {
    foreach ($layout in @('one', 'two')) {
        foreach ($style in @('plain', 'powerline')) {
            $path = Write-TempConfig "$layout-$style.json" ('{ "layout": "' + $layout + '", "style": "' + $style + '" }')
            $configSet.Add(@{ Name = "$layout-$style"; Path = $path; Layout = $layout; Style = $style; Enabled = (Read-StatusConfig $path).Segments })
        }
    }
}

foreach ($cfg in $configSet) {
    foreach ($c in $Columns) {
        Write-Host ''
        Write-Host ("== render {0}  COLUMNS={1}" -f $cfg.Name, $(if ($c -gt 0) { $c } else { 'unset' })) -ForegroundColor Cyan
        $maxLines = if ($cfg.Layout -eq 'two') { 2 } else { 1 }
        foreach ($sample in $sampleFiles) {
            $payload = $samplePayloads[$sample.Name]
            $r = Invoke-StatusLine $payload $cfg.Path $c
            $label = "$($cfg.Name) COLUMNS=$c $($sample.Name)"
            Confirm-True ($r.ExitCode -eq 0) "${label}: exit code $($r.ExitCode)"
            Confirm-True ($r.Err.Count -eq 0) "${label}: stderr empty"
            $lines = $r.Lines
            if ([string]::IsNullOrWhiteSpace(($lines -join ''))) { Confirm-True $false "${label}: empty output"; continue }
            Confirm-True ($lines.Count -le $maxLines) "${label}: $($lines.Count) lines, layout allows $maxLines"
            foreach ($line in $lines) {
                Confirm-True (-not [string]::IsNullOrWhiteSpace($line)) "${label}: empty line"
                if ($c -le 0) { continue }
                $w = Measure-VisibleWidth $line
                if ($w -le $c - 1) { $script:passed++; continue }
                $only = Invoke-StatusLine $payload $modelOnlyPath[$cfg.Style] $c
                Confirm-True ($only.ExitCode -eq 0) "${label}: model-only oracle exit code $($only.ExitCode)"
                Confirm-True ($only.Err.Count -eq 0) "${label}: model-only oracle stderr empty"
                $isModelOnly = (ConvertTo-PlainText $line) -ceq (ConvertTo-PlainText ($only.Lines -join ''))
                Confirm-True $isModelOnly "${label}: width $w exceeds $($c - 1) and the line is not the model-only fallback"
            }
            if ($c -le 0) {
                # A sample with no row in the two tables would be checked against nothing at all, so say
                # so instead of quietly degrading to "whatever the render happened to print".
                $listed = $sampleSegments.ContainsKey($sample.Name) -and $sampleMarkers.ContainsKey($sample.Name)
                Confirm-True $listed "${label}: sample has a row in the segment and marker tables"
                if (-not $listed) { continue }
                $text = ConvertTo-PlainText ($lines -join "`n")
                $known = @($sampleSegments[$sample.Name])
                $marks = $sampleMarkers[$sample.Name]
                $visible = @($allSegments | Where-Object { $cfg.Enabled[$_] -and $_ -in $known })
                $rowVisible = [System.Collections.Generic.List[object]]::new()
                foreach ($row in $layoutRows[$cfg.Layout]) { $rowVisible.Add(@($row | Where-Object { $_ -in $visible })) }
                if ($visible.Count -eq 0) {
                    # The config turns off everything this sample could show. statusline.ps1 builds no
                    # segments at all then and prints its fallback, the model glyph and the word claude.
                    Confirm-Equal $text "$iconModel claude" "${label}: nothing left on gives the claude fallback"
                } else {
                    foreach ($name in $allSegments) {
                        if ($cfg.Enabled[$name]) { continue }
                        $seen = @($segmentGlyphs[$name] | Where-Object { $text.Contains($_) })
                        Confirm-True ($seen.Count -eq 0) "${label}: $name is off, none of its glyphs appear"
                    }
                    # The rows this render should print, in order. Layout one is a single row; layout two
                    # drops a row that has nothing visible left on it, because Get-FittedLine returns
                    # $null for an empty set and the print loop skips it.
                    if ($cfg.Layout -eq 'two') { $rows = @($rowVisible | Where-Object { $_.Count -gt 0 }) } else { $rows = @(, $visible) }
                    Confirm-Equal $lines.Count $rows.Count "${label}: renders $($rows.Count) line(s)"
                    if ($lines.Count -eq $rows.Count) {
                        for ($ri = 0; $ri -lt $rows.Count; $ri++) {
                            $rowText = ConvertTo-PlainText $lines[$ri]
                            $mine = @($rows[$ri])
                            # Every visible segment has to prove it rendered, by its own marker, on its
                            # own row. This is the check that a dropped segment cannot slip past: the
                            # absence table names only a few glyphs per sample.
                            foreach ($name in $mine) {
                                $marker = $marks[$name]
                                if (-not $marker) { Confirm-True $false "${label}: no marker for $name in the marker table"; continue }
                                Confirm-True ($rowText.Contains($marker)) "${label}: line $($ri + 1) shows $name as '$marker'"
                            }
                            $other = @($visible | Where-Object { $_ -notin $mine })
                            if ($other.Count -gt 0) {
                                $strayed = @($other | Where-Object { @($segmentGlyphs[$_] | Where-Object { $rowText.Contains($_) }).Count -gt 0 })
                                Confirm-True ($strayed.Count -eq 0) "${label}: line $($ri + 1) carries none of $($other -join '+') (strayed '$($strayed -join ',')')"
                            }
                        }
                    }
                    if ($absentGlyphs.ContainsKey($sample.Name)) {
                        foreach ($check in $absentGlyphs[$sample.Name]) {
                            if (-not $cfg.Enabled[$glyphSegment[$check.Name]]) { continue }
                            Confirm-True (-not $text.Contains($check.Icon)) "${label}: $($check.Name) glyph absent"
                        }
                    }
                    # A separator only exists between two segments on the same line, so this asks the row
                    # sets rather than the sample: one segment left on a row means nothing to separate.
                    if (@($rowVisible | Where-Object { $_.Count -ge 2 }).Count -gt 0) {
                        if ($cfg.Style -eq 'plain') {
                            Confirm-True ($text.Contains($chevron) -and -not $text.Contains($arrow)) "${label}: plain uses chevron not arrow"
                        } else {
                            Confirm-True ($text.Contains($arrow) -and -not $text.Contains($chevron)) "${label}: powerline uses arrow not chevron"
                        }
                    }
                    if ($cfg.Style -eq 'powerline') {
                        $rawJoined = $lines -join "`n"
                        if ($cfg.Enabled['model']) {
                            Confirm-True ($rawJoined.Contains("$esc[0;1;48;5;31;38;5;231m")) "${label}: powerline bold model block"
                        } else {
                            # No model means no bold block, but every other segment is still a block.
                            Confirm-True ($rawJoined.Contains("$esc[0;48;5;")) "${label}: powerline block without a model segment"
                        }
                    }
                }
            }
            # @() or a one-line render collapses to a bare string here and $shown[0] echoes its first
            # character instead of the line.
            $shown = @(if ($Raw) { $lines -replace $esc, '<ESC>' } else { $lines })
            Write-Host ("{0,-40} {1,5:N0} ms  " -f $sample.Name, $r.Ms) -NoNewline
            Write-Host $shown[0]
            for ($i = 1; $i -lt $shown.Count; $i++) { Write-Host ((' ' * 50) + $shown[$i]) }
        }
        # The toggle config is generated from the layout and style under test, never from the segment set
        # of a user-supplied -Config, so this runs for every config.
        if ($c -le 0) {
            $togglePath = Write-TempConfig "toggle-$($cfg.Name).json" ('{ "layout": "' + $cfg.Layout + '", "style": "' + $cfg.Style + '", "segments": { "cost": false, "badges": false } }')
            $payload06 = $samplePayloads[$sample06.Name]
            $toggle = Invoke-StatusLine $payload06 $togglePath $c
            $toggleLabel = "$($cfg.Name) COLUMNS=$c toggle"
            Confirm-True ($toggle.ExitCode -eq 0) "${toggleLabel}: exit code $($toggle.ExitCode)"
            Confirm-True ($toggle.Err.Count -eq 0) "${toggleLabel}: stderr empty"
            $toggleText = ConvertTo-PlainText ($toggle.Lines -join "`n")
            Confirm-True (-not $toggleText.Contains($iconCost)) "${toggleLabel}: no cost glyph"
            Confirm-True (-not $toggleText.Contains($iconFast)) "${toggleLabel}: no fast glyph"
            Confirm-True ($toggleText.Contains($iconLines)) "${toggleLabel}: lines glyph still present"
        }
    }
}
} finally {
    if ($null -ne $oldGitCeiling) { $env:GIT_CEILING_DIRECTORIES = $oldGitCeiling } else { Remove-Item Env:GIT_CEILING_DIRECTORIES -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "passed $script:passed, failed $script:failed" -ForegroundColor $(if ($script:failed -gt 0) { 'Red' } else { 'Green' })
if ($script:failed -gt 0) { exit 1 }
