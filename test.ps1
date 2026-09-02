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

# ---- Unit group: functions extracted from statusline.ps1 ----
. (Import-ScriptFunction $script @('Get-VisibleWidth', 'Read-StatusConfig', 'Get-Palette', 'Format-Inline', 'Format-Line', 'Get-FittedLine', 'Read-PorcelainStatus', 'Get-GitBranch', 'G', 'K', 'Get-ThresholdRole', 'Get-ContextSegment', 'Test-PayloadDirty', 'Get-BranchSegment'))

# Get-BranchSegment closes over these script-level names in statusline.ps1, so the test has to supply them.
$gitTimeoutMs = 1500
$iconHome = [char]::ConvertFromUtf32(0xF015)
$iconBranch = [char]::ConvertFromUtf32(0xE0A0)
$iconDirty = [char]::ConvertFromUtf32(0xF040)

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
$r = Read-PorcelainStatus "## main`n M file.txt`n"
Confirm-Equal $r.Dirty $true 'porcelain: modified is dirty'
$r = Read-PorcelainStatus "## main`r`n?? new.txt`r`n"
Confirm-Equal $r.Dirty $true 'porcelain: untracked is dirty (CRLF)'
$r = Read-PorcelainStatus "## feature/x...origin/feature/x`n"
Confirm-Equal $r.Branch 'feature/x' 'porcelain: feature branch'
$r = Read-PorcelainStatus "## No commits yet on main`n"
Confirm-Equal $r.Branch 'main' 'porcelain: unborn'
Confirm-Equal $r.Dirty $false 'porcelain: unborn clean'
$r = Read-PorcelainStatus "## No commits yet on master...origin/master [gone]`n"
Confirm-Equal $r.Branch 'master' 'porcelain: unborn with upstream'
Confirm-Equal $r.Dirty $false 'porcelain: unborn with upstream clean'
$r = Read-PorcelainStatus "## HEAD (no branch)`n"
Confirm-Equal $r.Branch 'detached' 'porcelain: detached'
Confirm-Equal (Read-PorcelainStatus "fatal: not a git repository`n") $null 'porcelain: no header'
Confirm-Equal (Read-PorcelainStatus '') $null 'porcelain: empty'

Write-Host '== unit: branch segment' -ForegroundColor Cyan
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'main'; status = 'clean' } })
Confirm-True ($null -ne $seg -and $seg.Text.Contains('main')) "branch payload clean: text has the branch name, got '$($seg.Text)'"
Confirm-Equal $seg.Text "$iconHome main" 'branch payload clean: home icon, no pencil'
Confirm-Equal $seg.Role 'branch' 'branch payload clean: role'

$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = @{ modified = 2 } } })
Confirm-Equal $seg.Text "$iconBranch feature/x $iconDirty" 'branch payload dirty counts: branch icon and pencil'
Confirm-Equal $seg.Role 'warn' 'branch payload dirty counts: role'

Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{ git = @{} }))) 'branch payload git object with no branch: segment omitted'
Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{ git = @{ branch = '' } }))) 'branch payload empty branch: segment omitted'

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
    $g = Get-GitBranch $clean $gitTimeoutMs
    Confirm-Equal $g.Branch 'main' 'Get-GitBranch: clean branch'
    Confirm-Equal $g.Dirty $false 'Get-GitBranch: clean not dirty'
    $g = Get-GitBranch $dirtyUntracked $gitTimeoutMs
    Confirm-Equal $g.Dirty $true 'Get-GitBranch: untracked dirty'
    Confirm-Equal (Get-GitBranch (Join-Path $tmp 'nowhere') $gitTimeoutMs) $null 'Get-GitBranch: missing dir'

    $gitCases.Add(@{ Name = 'clean';           Dir = $clean;          Has = "$iconHome main";              Not = $iconDirty })
    $gitCases.Add(@{ Name = 'dirty tracked';   Dir = $dirtyTracked;   Has = "$iconHome main $iconDirty";  Raw = "$esc[33m" })
    $gitCases.Add(@{ Name = 'dirty untracked'; Dir = $dirtyUntracked; Has = "$iconHome main $iconDirty" })
    $gitCases.Add(@{ Name = 'feature';         Dir = $feature;        Has = "$iconBranch feature/x" })
    $gitCases.Add(@{ Name = 'unborn';          Dir = $unborn;         Has = "$iconHome main";              Not = $iconDirty })
    $gitCases.Add(@{ Name = 'detached';        Dir = $detached;       Has = "$iconBranch detached" })
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
# $tmp instead: the folder segment prints the same leaf, and the probe is provably not a repository. The
# rewrite is in memory, for every config including a user-supplied -Config; the sample files never change.
function Convert-ToHermeticPayload([string] $Path) {
    $text = Get-Content -LiteralPath $Path -Raw
    $json = $text | ConvertFrom-Json
    if ($null -ne $json.git) { return $text }
    $dir = $json.workspace.current_dir
    if (-not $dir) { return $text }
    $probe = Join-Path $tmp (Split-Path $dir -Leaf)
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
$twoLineSamples = @('01-main-clean.json', '06-limits-badges-lines.json')
$presenceTable = @{
    '01-main-clean.json' = @(
        @{ Icon = $iconCtx; Name = 'context'; Expect = $true }
        @{ Icon = $iconCost; Name = 'cost'; Expect = $true }
        @{ Icon = $iconFolder; Name = 'folder'; Expect = $true }
        @{ Icon = $iconHome; Name = 'home'; Expect = $true }
        @{ Icon = $iconDirty; Name = 'pencil'; Expect = $false }
        @{ Icon = $iconLines; Name = 'lines'; Expect = $false }
        @{ Icon = $iconLimits; Name = 'limits'; Expect = $false }
        @{ Icon = $iconBranch; Name = 'branch'; Expect = $false }
    )
    '02-feature-dirty-high.json' = @(
        @{ Icon = $iconBranch; Name = 'branch'; Expect = $true }
        @{ Icon = $iconDirty; Name = 'pencil'; Expect = $true }
        @{ Icon = $iconCost; Name = 'cost'; Expect = $true }
        @{ Icon = $iconHome; Name = 'home'; Expect = $false }
    )
    '03-main-dirty-mid.json' = @(
        @{ Icon = $iconHome; Name = 'home'; Expect = $true }
        @{ Icon = $iconDirty; Name = 'pencil'; Expect = $true }
    )
    '04-minimal.json' = @(
        @{ Icon = $iconCtx; Name = 'context'; Expect = $false }
        @{ Icon = $iconFolder; Name = 'folder'; Expect = $false }
    )
    '05-no-git.json' = @(
        @{ Icon = $iconCtx; Name = 'context'; Expect = $true }
        @{ Icon = $iconFolder; Name = 'folder'; Expect = $true }
        @{ Icon = $iconHome; Name = 'home'; Expect = $false }
        @{ Icon = $iconBranch; Name = 'branch'; Expect = $false }
        @{ Icon = $iconCost; Name = 'cost'; Expect = $false }
    )
    '06-limits-badges-lines.json' = @(
        @{ Icon = $iconCtx; Name = 'context'; Expect = $true }
        @{ Icon = $iconCost; Name = 'cost'; Expect = $true }
        @{ Icon = $iconLines; Name = 'lines'; Expect = $true }
        @{ Icon = $iconLimits; Name = 'limits'; Expect = $true }
        @{ Icon = $iconFast; Name = 'fast'; Expect = $true }
        @{ Icon = $iconThink; Name = 'think'; Expect = $true }
        @{ Icon = $iconEffort; Name = 'effort'; Expect = $true }
        @{ Icon = $iconVim; Name = 'vim'; Expect = $true }
        @{ Icon = $iconFolder; Name = 'folder'; Expect = $true }
        @{ Icon = $iconHome; Name = 'home'; Expect = $true }
        @{ Icon = $iconDirty; Name = 'pencil'; Expect = $false }
    )
    '07-limits-expired-default-effort.json' = @(
        @{ Icon = $iconCtx; Name = 'context'; Expect = $true }
        @{ Icon = $iconCost; Name = 'cost'; Expect = $true }
        @{ Icon = $iconLines; Name = 'lines'; Expect = $true }
        @{ Icon = $iconLimits; Name = 'limits'; Expect = $true }
        @{ Icon = $iconFolder; Name = 'folder'; Expect = $true }
        @{ Icon = $iconFast; Name = 'fast'; Expect = $false }
        @{ Icon = $iconThink; Name = 'think'; Expect = $false }
        @{ Icon = $iconEffort; Name = 'effort'; Expect = $false }
        @{ Icon = $iconVim; Name = 'vim'; Expect = $false }
        @{ Icon = $iconHome; Name = 'home'; Expect = $false }
        @{ Icon = $iconBranch; Name = 'branch'; Expect = $false }
    )
}
$modelOnlyPath = @{}
foreach ($style in @('plain', 'powerline')) {
    $modelOnlyPath[$style] = Write-TempConfig "model-only-$style.json" ('{ "layout": "one", "style": "' + $style + '", "segments": { "context": false, "cost": false, "lines": false, "limits": false, "badges": false, "folder": false, "branch": false } }')
}
# AllOn says whether every segment is enabled. The glyph, two-line and toggle assertions below describe a
# full status line, so they only apply then; a user-supplied -Config with segments off still gets the
# structural checks (exit code, empty stderr, width, line count against the layout).
$configSet = [System.Collections.Generic.List[hashtable]]::new()
if ($Config) {
    $resolved = (Resolve-Path $Config).Path
    $parsed = Read-StatusConfig $resolved
    $allOn = (@($parsed.Segments.Keys | Where-Object { -not $parsed.Segments[$_] }).Count -eq 0)
    if (-not $allOn) { Write-Host "note: $(Split-Path $resolved -Leaf) turns segments off; running structural checks only" -ForegroundColor Yellow }
    $configSet.Add(@{ Name = (Split-Path $resolved -Leaf); Path = $resolved; Layout = $parsed.Layout; Style = $parsed.Style; AllOn = $allOn })
} else {
    foreach ($layout in @('one', 'two')) {
        foreach ($style in @('plain', 'powerline')) {
            $path = Write-TempConfig "$layout-$style.json" ('{ "layout": "' + $layout + '", "style": "' + $style + '" }')
            $configSet.Add(@{ Name = "$layout-$style"; Path = $path; Layout = $layout; Style = $style; AllOn = $true })
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
            if ($c -le 0 -and $cfg.AllOn) {
                $text = ConvertTo-PlainText ($lines -join "`n")
                Confirm-True ($text.Contains($iconModel)) "${label}: has model glyph"
                if ($presenceTable.ContainsKey($sample.Name)) {
                    foreach ($check in $presenceTable[$sample.Name]) {
                        $has = $text.Contains($check.Icon)
                        Confirm-True ($has -eq $check.Expect) "${label}: $($check.Name) glyph $(if ($check.Expect) { 'present' } else { 'absent' })"
                    }
                }
                if ($sample.Name -ne '04-minimal.json') {
                    if ($cfg.Style -eq 'plain') {
                        Confirm-True ($text.Contains($chevron) -and -not $text.Contains($arrow)) "${label}: plain uses chevron not arrow"
                    } else {
                        Confirm-True ($text.Contains($arrow) -and -not $text.Contains($chevron)) "${label}: powerline uses arrow not chevron"
                    }
                }
                if ($cfg.Style -eq 'powerline') {
                    $rawJoined = $lines -join "`n"
                    Confirm-True ($rawJoined.Contains("$esc[0;1;48;5;31;38;5;231m")) "${label}: powerline bold model block"
                }
                if ($cfg.Layout -eq 'two') {
                    if ($sample.Name -in $twoLineSamples) {
                        Confirm-Equal $lines.Count 2 "${label}: two-line layout produces 2 lines"
                        if ($lines.Count -eq 2) {
                            $line1 = ConvertTo-PlainText $lines[0]
                            $line2 = ConvertTo-PlainText $lines[1]
                            Confirm-True ($line1.Contains($iconModel) -and $line1.Contains($iconFolder) -and -not $line1.Contains($iconCtx)) "${label}: line 1 has model+folder, no context"
                            Confirm-True ($line2.Contains($iconCtx) -and -not $line2.Contains($iconFolder)) "${label}: line 2 has context, no folder"
                        }
                    } elseif ($sample.Name -eq '04-minimal.json') {
                        Confirm-Equal $lines.Count 1 "${label}: two-line layout with only model collapses to 1 line"
                    }
                }
            }
            $shown = if ($Raw) { $lines -replace $esc, '<ESC>' } else { $lines }
            Write-Host ("{0,-40} {1,5:N0} ms  " -f $sample.Name, $r.Ms) -NoNewline
            Write-Host $shown[0]
            for ($i = 1; $i -lt $shown.Count; $i++) { Write-Host ((' ' * 50) + $shown[$i]) }
        }
        if ($c -le 0 -and $cfg.AllOn) {
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
