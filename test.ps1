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

# Strips the OSC 8 hyperlink wrappers (either terminator) and then the SGR colour codes, so a marker
# check searches the text a terminal would show and a URL can never satisfy or spoil one.
function ConvertTo-PlainText([string] $Text) { $Text -replace "$esc\]8;[^\a$esc]*(?:\a|$esc\\)", '' -replace "$esc\[[0-9;]*m", '' }

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
    $plain = [regex]::Replace($Text, "$esc\]8;[^\a$esc]*(?:\a|$esc\\)", '')
    $plain = [regex]::Replace($plain, "$esc\[[0-9;]*m", '')
    $width = 0
    $en = [System.Globalization.StringInfo]::GetTextElementEnumerator($plain)
    while ($en.MoveNext()) {
        $el = [string] $en.Current
        $cp = try { [char]::ConvertToUtf32($el, 0) } catch { 0x3F }
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($cp)
        $zero =$cat -eq [System.Globalization.UnicodeCategory]::NonSpacingMark -or
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

# Runs a script file in a child pwsh with $Payload on stdin, and collects stdout as Lines and stderr as Err.
function Invoke-ChildPwsh([string] $File, [string[]] $Arguments, [string] $Payload) {
    $pwshArgs = @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', $File) + @($Arguments)
    $err = [System.Collections.Generic.List[string]]::new()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = $Payload | pwsh @pwshArgs 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $err.Add("$_") } else { "$_" }
    }
    $sw.Stop()
    return @{ Lines = @($out); Err = @($err); ExitCode = $LASTEXITCODE; Ms = $sw.ElapsedMilliseconds }
}

# Runs statusline.ps1 in a child pwsh. $Columns 0 means COLUMNS unset. $PathPrefix is prepended to PATH for the child.
function Invoke-StatusLine([string] $Payload, [string] $ConfigPath, [int] $Columns = 0, [string] $PathPrefix) {
    $oldCols = $env:COLUMNS
    $oldPath = $env:PATH
    try {
        if ($Columns -gt 0) { $env:COLUMNS = "$Columns" } else { Remove-Item Env:COLUMNS -ErrorAction SilentlyContinue }
        if ($PathPrefix) { $env:PATH = $PathPrefix + [System.IO.Path]::PathSeparator + $env:PATH }
        $scriptArgs = if ($ConfigPath) { @('-Config', $ConfigPath) } else { @() }
        return Invoke-ChildPwsh $script $scriptArgs $Payload
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
. (Import-ScriptFunction $script @('Get-VisibleWidth', 'Read-StatusConfig', 'Get-Palette', 'Format-Inline', 'Format-Line', 'Get-FittedLine', 'Read-PorcelainStatus', 'Get-GitBranch', 'G', 'K', 'Get-ThresholdRole', 'Test-WideWindow', 'Get-ModelSegment', 'Get-ContextSegment', 'Get-PayloadNumber', 'Test-PayloadText', 'Test-PayloadDirty', 'Get-PayloadCount', 'Read-PayloadStatus', 'Get-BranchSegment', 'Get-FolderSegment', 'Get-SegmentRegistry', 'Get-SegmentOrder', 'TimeLeft', 'Get-LimitsSegment', 'Format-Link', 'Get-PrSegment', 'Get-FiniteNumber','Get-SessionStateDir', 'Get-SessionStatePath', 'Get-StateNumber', 'Read-SessionState', 'Merge-SessionState', 'Write-SessionState', 'Invoke-SessionStateSweep'))

# Get-BranchSegment, Get-FolderSegment, Get-LimitsSegment, Get-ModelSegment and Get-PrSegment close over
# these script-level names in statusline.ps1, so the test has to supply them.
$gitTimeoutMs = 1500
$iconLimit = [char]::ConvertFromUtf32(0xF0E4)
$iconModel = [char]::ConvertFromUtf32(0xF06A9)
$iconFolder = [char]::ConvertFromUtf32(0xF07C)
$iconChevron = [char]::ConvertFromUtf32(0x203A)
$iconHome = [char]::ConvertFromUtf32(0xF015)
$iconBranch = [char]::ConvertFromUtf32(0xE0A0)
$iconDirty = [char]::ConvertFromUtf32(0xF040)
$iconAhead = [char]::ConvertFromUtf32(0x2191)
$iconBehind = [char]::ConvertFromUtf32(0x2193)
$iconConflict = [char]::ConvertFromUtf32(0xF071)
$iconPr = [char]::ConvertFromUtf32(0xF407)

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
    @{ Text = "$esc]8;;https://example.com/pull/12$esc\abc$esc]8;;$esc\"; Width = 3 } # OSC 8 link: the URL is not visible
    @{ Text = "$esc]8;;https://example.com$esc\$esc[32mab$esc[0m$esc]8;;$esc\"; Width = 2 }  # link around coloured text
    @{ Text = "$esc]8;;$esc\"; Width = 0 }                                              # a bare link terminator
    @{ Text = "$esc]8;;https://example.com`aabcd$esc]8;;`a"; Width = 4 }               # BEL-terminated link
)
foreach ($row in $widthTable) {
    $shown = $row.Text -replace $esc, '<ESC>'
    Confirm-Equal -Actual (Get-VisibleWidth $row.Text) -Expected $row.Width -Label "script width of '$shown'"
    Confirm-Equal -Actual (Measure-VisibleWidth $row.Text) -Expected $row.Width -Label "test width of '$shown'"
}

Write-Host '== unit: registry' -ForegroundColor Cyan
# The registry is the one table behind the config defaults, the shrink and drop order, the build
# dispatch and the row split. This pins its contents to what the script did when each list was written
# out by hand, so a change there is a deliberate one. Array order is layout one.
$registryTable = @(
    @{ Name = 'model';   Build = 'Get-ModelSegment';   Default = $true; ShrinkRank = $null; DropRank = $null; Row = 1; RowRank = 1 }
    @{ Name = 'context'; Build = 'Get-ContextSegment'; Default = $true; ShrinkRank = 2;     DropRank = 8;     Row = 2; RowRank = 1 }
    @{ Name = 'cost';    Build = 'Get-CostSegment';    Default = $true; ShrinkRank = $null; DropRank = 3;     Row = 2; RowRank = 3 }
    @{ Name = 'lines';   Build = 'Get-LinesSegment';   Default = $true; ShrinkRank = $null; DropRank = 1;     Row = 2; RowRank = 4 }
    @{ Name = 'limits';  Build = 'Get-LimitsSegment';  Default = $true; ShrinkRank = 1;     DropRank = 4;     Row = 2; RowRank = 2 }
    @{ Name = 'badges';  Build = 'Get-BadgesSegment';  Default = $true; ShrinkRank = $null; DropRank = 2;     Row = 1; RowRank = 5 }
    @{ Name = 'pr';      Build = 'Get-PrSegment';      Default = $true; ShrinkRank = $null; DropRank = 5;     Row = 1; RowRank = 4 }
    @{ Name = 'folder';  Build = 'Get-FolderSegment';  Default = $true; ShrinkRank = 4;     DropRank = 6;     Row = 1; RowRank = 2 }
    @{ Name = 'branch';  Build = 'Get-BranchSegment';  Default = $true; ShrinkRank = 3;     DropRank = 7;     Row = 1; RowRank = 3 }
)
$registry = @(Get-SegmentRegistry)
Confirm-Equal $registry.Count $registryTable.Count 'registry: nine records'
for ($i = 0; $i -lt [math]::Min($registry.Count, $registryTable.Count); $i++) {
    $want = $registryTable[$i]
    $got = $registry[$i]
    Confirm-Equal $got.Name $want.Name "registry: record $i is $($want.Name)"
    foreach ($key in @('Build', 'Default', 'ShrinkRank', 'DropRank', 'Row', 'RowRank')) {
        Confirm-True ($got.ContainsKey($key)) "registry: $($want.Name) has $key"
        Confirm-Equal $got[$key] $want[$key] "registry: $($want.Name) $key"
    }
}
Confirm-Equal ((Get-SegmentOrder 'ShrinkRank') -join ',') 'limits,context,branch,folder' 'registry: shrink order'
Confirm-Equal ((Get-SegmentOrder 'DropRank') -join ',') 'lines,badges,cost,limits,pr,folder,branch,context' 'registry: drop order'
Confirm-Equal ((Get-SegmentOrder 'RowRank' 1) -join ',') 'model,folder,branch,pr,badges' 'registry: layout two row 1'
Confirm-Equal ((Get-SegmentOrder 'RowRank' 2) -join ',') 'context,limits,cost,lines' 'registry: layout two row 2'

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
# Every segment name in layout-one order, from the registry, so this list cannot drift from the script's.
$allSegments = @((Get-SegmentRegistry).Name)

$c = Read-StatusConfig (Join-Path $tmp 'does-not-exist.json')
Confirm-Equal $c.Layout 'one' 'config missing: layout'
Confirm-Equal $c.Style 'plain' 'config missing: style'
Confirm-Equal $c.Folder 'repo' 'config missing: folder repo'
Confirm-True (@($allSegments | Where-Object { -not $c.Segments[$_] }).Count -eq 0) 'config missing: all segments on'

$c = Read-StatusConfig (Write-TempConfig 'folder-leaf.json' '{ "folder": "LEAF" }')
Confirm-Equal $c.Folder 'leaf' 'config folder: leaf, case-insensitive'
Confirm-Equal $c.Segments.folder $true 'config folder: the mode does not touch the segment toggle'
$c = Read-StatusConfig (Write-TempConfig 'folder-nonsense.json' '{ "folder": "nonsense" }')
Confirm-Equal $c.Folder 'repo' 'config folder: unknown value falls back to repo'
$c = Read-StatusConfig (Write-TempConfig 'folder-number.json' '{ "folder": 7 }')
Confirm-Equal $c.Folder 'repo' 'config folder: non-string falls back to repo'

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

# The state key: a boolean is taken as is, anything else (missing, string, number) leaves it on.
Confirm-Equal (Read-StatusConfig (Join-Path $tmp 'does-not-exist.json')).State $true 'config missing: state on'
Confirm-Equal (Read-StatusConfig (Write-TempConfig 'state-true.json' '{ "state": true }')).State $true 'config state true'
Confirm-Equal (Read-StatusConfig (Write-TempConfig 'state-false.json' '{ "state": false }')).State $false 'config state false'
Confirm-Equal (Read-StatusConfig (Write-TempConfig 'state-absent.json' '{ "layout": "two" }')).State $true 'config state absent: on'
Confirm-Equal (Read-StatusConfig (Write-TempConfig 'state-string.json' '{ "state": "false" }')).State $true 'config state string: on'
Confirm-Equal (Read-StatusConfig (Write-TempConfig 'state-number.json' '{ "state": 0 }')).State $true 'config state number: on'

# The config that ships with the repo has to be valid JSON and to mean what the README says it means.
$shippedConfig = Join-Path $PSScriptRoot 'statusline.json'
$shippedJson = try { Get-Content -LiteralPath $shippedConfig -Raw | ConvertFrom-Json } catch { $null }
Confirm-True ($shippedJson -is [System.Management.Automation.PSCustomObject]) 'shipped config: parses as a JSON object'
$c = Read-StatusConfig $shippedConfig
Confirm-Equal $c.Layout 'one' 'shipped config: layout one'
Confirm-Equal $c.Style 'plain' 'shipped config: style plain'
Confirm-Equal $c.Folder 'repo' 'shipped config: folder repo'
Confirm-Equal $shippedJson.folder 'repo' 'shipped config: the file itself says folder repo'
$shippedSegments = @($c.Segments.Keys)
Confirm-Equal $shippedSegments.Count 9 'shipped config: nine segments'
Confirm-True (@($shippedSegments | Where-Object { -not $c.Segments[$_] }).Count -eq 0) 'shipped config: every segment on'
$shippedFileSegments = @($shippedJson.segments.PSObject.Properties)
Confirm-Equal $shippedFileSegments.Count 9 'shipped config: the file itself lists nine segments'
# -ne coerces its right side to the left side's type, so 'true' -ne $true is False; test the type too.
Confirm-True (@($shippedFileSegments | Where-Object { $_.Value -isnot [bool] -or $_.Value -ne $true }).Count -eq 0) 'shipped config: the file itself sets them all to the boolean true'
Confirm-Equal $c.State $true 'shipped config: state on'
Confirm-True ($shippedJson.state -is [bool] -and $shippedJson.state) 'shipped config: the file itself sets state to the boolean true'

Write-Host '== unit: state' -ForegroundColor Cyan
# The state helpers derive their directory from TEMP, so point it at a folder under $tmp for these cases
# and put it back afterwards. Nothing here touches the machine's real state directory.
$oldTemp = $env:TEMP
$stateTemp = Join-Path $tmp 'temp-unit'
New-Item -ItemType Directory -Force $stateTemp | Out-Null
$env:TEMP = $stateTemp
try {
$stateDir = Join-Path $stateTemp 'claude-statusline-state'
$stateStamp = Join-Path $stateDir '.sweep'
function Get-StatePayload([double] $Cost) {
    return [pscustomobject]@{
        session_id = 'abc'
        cost = [pscustomobject]@{ total_cost_usd = $Cost }
        context_window = [pscustomobject]@{ used_percentage = 32; total_input_tokens = 60000; total_output_tokens = 4000 }
        rate_limits = [pscustomobject]@{ five_hour = [pscustomobject]@{ used_percentage = 23.5 } }
    }
}
function Get-StateFile([string] $Name) { return (Get-Content -LiteralPath (Join-Path $stateDir "$Name.json") -Raw | ConvertFrom-Json) }
function Get-StateFileCount { return @(Get-ChildItem -LiteralPath $stateDir -Filter *.json -File -ErrorAction SilentlyContinue).Count }
function Write-StateFileAge([string] $Path, [double] $Hours) { (Get-Item -LiteralPath $Path).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-$Hours) }

Confirm-Equal (Read-SessionState 'nothing-yet') $null 'state read: missing file gives null'
Confirm-True (-not (Test-Path -LiteralPath $stateDir)) 'state read: creates no directory'
Confirm-Equal (Get-SessionStateDir $false) $null 'state dir: missing and not asked to create gives null'

# One guard behind both number helpers: anything that is not a number at all is rejected by both, and
# each then applies its own rule - a count that fits an Int32, or a figure floored to a long when whole.
foreach ($case in @(
        @{ Name = 'missing';      V = $null }
        @{ Name = 'string';       V = '2' }
        @{ Name = 'empty string'; V = '' }
        @{ Name = 'boolean';      V = $true }
        @{ Name = 'array';        V = @(1, 2) }
        @{ Name = 'object';       V = ([pscustomobject]@{ a = 1 }) }
        @{ Name = 'NaN';          V = [double]::NaN }
        @{ Name = 'infinity';     V = [double]::PositiveInfinity })) {
    Confirm-Equal (Get-FiniteNumber $case.V) $null "state number: $($case.Name) is not a finite number"
    Confirm-Equal (Get-PayloadNumber $case.V) $null "state number: $($case.Name) is not a payload count"
    Confirm-Equal (Get-StateNumber $case.V) $null "state number: $($case.Name) is not a state figure"
    Confirm-Equal (Get-StateNumber $case.V -Whole) $null "state number: $($case.Name) is not a whole state figure"
}
Confirm-Equal (Get-FiniteNumber 0) 0 'state number: zero is a finite number'
Confirm-Equal (Get-PayloadNumber 1.5) $null 'state number: a fraction is not a count'
Confirm-Equal (Get-StateNumber 1.5) 1.5 'state number: a fraction is a figure'
Confirm-Equal (Get-StateNumber 1.5 -Whole) 1 'state number: -Whole floors a fraction'
Confirm-Equal (Get-PayloadNumber 2147483648) $null 'state number: a count must fit an Int32'
Confirm-Equal (Get-StateNumber 2147483648 -Whole) 2147483648 'state number: a whole figure may exceed an Int32'
Confirm-Equal (Get-StateNumber 1e300 -Whole) $null 'state number: a whole figure must fit a long'

$state = Merge-SessionState $null (Get-StatePayload 1.07) 1767225600
Confirm-Equal $state.v 1 'state merge: version 1'
Confirm-Equal $state.updated_at 1767225600 'state merge: updated_at is the clock given'
Confirm-Equal $state.cost_usd 1.07 'state merge: cost'
Confirm-Equal $state.input_tokens 60000 'state merge: input tokens'
Confirm-Equal $state.output_tokens 4000 'state merge: output tokens'
Confirm-Equal $state.used_percentage 32 'state merge: context percentage'
Confirm-Equal $state.five_hour_percentage 23.5 'state merge: five-hour percentage'
Confirm-Equal @($state.history).Count 1 'state merge: first render starts the history'
Confirm-Equal $state.history[0].cost_usd 1.07 'state merge: history entry holds the cost'
Confirm-Equal $state.history[0].t 1767225600 'state merge: history entry holds the time'
Confirm-Equal (@($state.Keys) -join ',') 'v,updated_at,cost_usd,input_tokens,output_tokens,used_percentage,five_hour_percentage,history' 'state merge: schema keys in schema order'

Write-SessionState 'abc' $state
Confirm-True (Test-Path -LiteralPath $stateDir -PathType Container) 'state write: missing directory is created'
Confirm-True (Test-Path -LiteralPath (Join-Path $stateDir 'abc.json') -PathType Leaf) 'state write: file named after the session'
Confirm-True (Test-Path -LiteralPath $stateStamp -PathType Leaf) 'state write: first write leaves the sweep stamp'
$file = Get-StateFile 'abc'
Confirm-Equal (@($file.PSObject.Properties.Name) -join ',') 'v,updated_at,cost_usd,input_tokens,output_tokens,used_percentage,five_hour_percentage,history' 'state file: schema keys in schema order'
Confirm-Equal $file.v 1 'state file: v'
Confirm-Equal $file.cost_usd 1.07 'state file: cost_usd'
Confirm-Equal $file.input_tokens 60000 'state file: input_tokens'
Confirm-True ((Get-Content -LiteralPath (Join-Path $stateDir 'abc.json') -Raw).Contains('"input_tokens":60000,')) 'state file: token counts are written as integers'
Confirm-Equal $file.history.Count 1 'state file: one history entry'
$back = Read-SessionState 'abc'
Confirm-True ($back -is [hashtable]) 'state round trip: a hashtable'
Confirm-Equal $back.v 1 'state round trip: v'
Confirm-Equal $back.updated_at 1767225600 'state round trip: updated_at'
Confirm-Equal $back.cost_usd 1.07 'state round trip: cost'
Confirm-Equal $back.input_tokens 60000 'state round trip: input tokens'
Confirm-Equal $back.output_tokens 4000 'state round trip: output tokens'
Confirm-Equal $back.used_percentage 32 'state round trip: context percentage'
Confirm-Equal $back.five_hour_percentage 23.5 'state round trip: five-hour percentage'
Confirm-Equal @($back.history).Count 1 'state round trip: history count'
Confirm-Equal $back.history[0].t 1767225600 'state round trip: history time'
Confirm-Equal $back.history[0].cost_usd 1.07 'state round trip: history cost'

# The history ring gains an entry only when the cost moved.
$same = Merge-SessionState $back (Get-StatePayload 1.07) 1767225660
Confirm-Equal @($same.history).Count 1 'state merge: unchanged cost adds no entry'
Confirm-Equal $same.updated_at 1767225660 'state merge: unchanged cost still moves updated_at'
$next = Merge-SessionState $back (Get-StatePayload 1.2) 1767225720
Confirm-Equal @($next.history).Count 2 'state merge: changed cost adds an entry'
Confirm-Equal $next.history[0].cost_usd 1.07 'state merge: old entry kept first'
Confirm-Equal $next.history[1].cost_usd 1.2 'state merge: new entry last'
Confirm-Equal $next.history[1].t 1767225720 'state merge: new entry carries the clock'
$noCost = Merge-SessionState $back ([pscustomobject]@{ session_id = 'abc' }) 1767225780
Confirm-Equal $noCost.cost_usd $null 'state merge: payload without cost gives null cost'
Confirm-Equal $noCost.input_tokens $null 'state merge: payload without context gives null tokens'
Confirm-Equal @($noCost.history).Count 1 'state merge: payload without cost adds no entry'
$badCost = Merge-SessionState $null ([pscustomobject]@{ cost = [pscustomobject]@{ total_cost_usd = 'lots' } }) 1
Confirm-Equal $badCost.cost_usd $null 'state merge: string cost is not a number'
Confirm-Equal @($badCost.history).Count 0 'state merge: string cost starts no history'

# A payload can arrive with no cost object at all (the minimal sample is that shape), which stores a
# null cost. The comparison is against the last history entry, not that null, so the render after the
# gap does not re-append a cost that never moved.
$run = Merge-SessionState $null (Get-StatePayload 1.07) 1
Confirm-Equal @($run.history).Count 1 'state merge: gap run starts with one entry'
$run = Merge-SessionState $run ([pscustomobject]@{ session_id = 'abc' }) 2
Confirm-Equal $run.cost_usd $null 'state merge: gap run stores a null cost'
Confirm-Equal @($run.history).Count 1 'state merge: gap run keeps the entry it had'
$run = Merge-SessionState $run (Get-StatePayload 1.07) 3
Confirm-Equal @($run.history).Count 1 'state merge: the same cost after a gap adds no entry'
$run = Merge-SessionState $run (Get-StatePayload 1.2) 4
Confirm-Equal @($run.history).Count 2 'state merge: a moved cost after a gap adds an entry'
# The same three renders through the file, the way they actually run.
Write-SessionState 'gap' (Merge-SessionState (Read-SessionState 'gap') (Get-StatePayload 1.07) 1)
Write-SessionState 'gap' (Merge-SessionState (Read-SessionState 'gap') ([pscustomobject]@{}) 2)
Write-SessionState 'gap' (Merge-SessionState (Read-SessionState 'gap') (Get-StatePayload 1.07) 3)
$gap = Read-SessionState 'gap'
Confirm-Equal @($gap.history).Count 1 'state merge: 1.07, no cost, 1.07 through the file leaves one entry'
Confirm-Equal $gap.history[0].cost_usd 1.07 'state merge: and that entry is the first cost'

# Twenty-five renders with a rising cost through the file: the ring keeps the newest twenty.
$ring = $null
for ($i = 1; $i -le 25; $i++) {
    $ring = Merge-SessionState $ring (Get-StatePayload ([math]::Round($i / 10, 2))) (1767225600 + $i)
    Write-SessionState 'ring' $ring
    $ring = Read-SessionState 'ring'
}
Confirm-Equal @($ring.history).Count 20 'state ring: stops at 20'
Confirm-Equal $ring.history[0].cost_usd 0.6 'state ring: oldest dropped first'
Confirm-Equal $ring.history[19].cost_usd 2.5 'state ring: newest last'
Confirm-True ((Get-Item -LiteralPath (Join-Path $stateDir 'ring.json')).Length -lt 1200) 'state ring: a full ring stays around 1 KB'

# Files that cannot be trusted read as no state.
foreach ($case in @(
        @{ Name = 'truncated'; Text = '{ "v": 1, "cost' }
        @{ Name = 'empty'; Text = '' }
        @{ Name = 'v2'; Text = '{ "v": 2, "cost_usd": 1, "history": [] }' }
        @{ Name = 'nov'; Text = '{ "cost_usd": 1, "history": [] }' }
        @{ Name = 'vstring'; Text = '{ "v": "1", "cost_usd": 1, "history": [] }' }
        @{ Name = 'array'; Text = '[1, 2]' }
        @{ Name = 'number'; Text = '5' })) {
    [System.IO.File]::WriteAllText((Join-Path $stateDir "$($case.Name).json"), $case.Text)
    Confirm-Equal (Read-SessionState $case.Name) $null "state read: $($case.Name) file gives null"
}
[System.IO.File]::WriteAllText((Join-Path $stateDir 'odd.json'), '{ "v": 1, "cost_usd": "x", "history": [ { "t": 5 }, "junk", null, { "t": 6, "cost_usd": 0.5 } ] }')
$odd = Read-SessionState 'odd'
Confirm-True ($odd -is [hashtable]) 'state read: odd but versioned file still reads'
Confirm-Equal $odd.cost_usd $null 'state read: string cost reads as null'
Confirm-Equal @($odd.history).Count 1 'state read: history entries without both numbers are dropped'
Confirm-Equal $odd.history[0].cost_usd 0.5 'state read: the whole entry is kept'

# The file name is the id itself when it is clean and at most 64 characters, as a UUID is. An id that had
# characters stripped, or was longer than that, gets a hash of the whole id as a suffix, so two ids that
# strip or cut to the same text (a/b and ab; two long ids with one first 64 characters) never share a file.
function Get-StateFileName([string] $Id) { return (Split-Path (Get-SessionStatePath $Id $false) -Leaf) }
# The test's own way to the same 16 characters: a byte-by-byte hex format, not the script's
# BitConverter expression, and only APIs PowerShell 7.0's .NET Core 3.1 has.
function Get-IdHash([string] $Id) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Id)) } finally { $sha.Dispose() }
    return (-join @(0..7 | ForEach-Object { $bytes[$_].ToString('x2') }))
}
# And one hash written out in full, so the expectations below cannot all be wrong together.
Confirm-Equal (Get-IdHash 'a/b') 'c14cddc033f64b9d' 'state name: the hash of a/b, written out'
$uuid = '0f8fad5b-d9cb-469f-a165-70867728950e'
Confirm-Equal (Get-StateFileName $uuid) "$uuid.json" 'state name: a UUID keeps its readable name'
Confirm-Equal (Get-StateFileName ('x' * 64)) (('x' * 64) + '.json') 'state name: 64 clean characters kept as they are'
Confirm-Equal (Get-StateFileName 'ab') 'ab.json' 'state name: ab is readable'
Confirm-Equal (Get-StateFileName 'a/b') "ab-$(Get-IdHash 'a/b').json" 'state name: a/b is the stripped prefix, a hyphen and 16 hex characters of the SHA-256'
Confirm-True ((Get-StateFileName 'a/b') -cne (Get-StateFileName 'ab')) 'state name: a/b and ab get different files'
$long1 = ('y' * 64) + 'AAAAAA'
$long2 = ('y' * 64) + 'BBBBBB'
Confirm-True ((Get-StateFileName $long1) -cne (Get-StateFileName $long2)) 'state name: two 70-character ids sharing the first 64 get different files'
Confirm-True ((Get-StateFileName $long1) -cmatch ('^' + ('y' * 47) + '-[0-9a-f]{16}\.json$')) 'state name: a long id is a 47-character prefix, a hyphen and 16 hex characters'
Confirm-Equal (Get-StateFileName ('x' * 100)).Length 69 'state name: a hashed name is 64 characters plus .json'
Confirm-True ((Get-StateFileName '///') -cmatch '^[0-9a-f]{16}\.json$') 'state name: an id of only punctuation is the hash alone'
Confirm-Equal (Get-StateFileName '../abc') "..abc-$(Get-IdHash '../abc').json" 'state name: slashes stripped, dots kept, hash added'
# Case is not a difference to the file system, so an id that is not already lower-case is hashed too.
Confirm-Equal (Get-StateFileName 'a1b2c3') 'a1b2c3.json' 'state name: a lower-case id is readable'
Confirm-Equal (Get-StateFileName 'A1B2C3') "a1b2c3-$(Get-IdHash 'A1B2C3').json" 'state name: an id with upper case gets the hash of the id as written'
Confirm-True ((Get-StateFileName 'A1B2C3') -cne (Get-StateFileName 'a1b2c3')) 'state name: two ids differing only in case get different files'
Confirm-Equal (Get-StateFileName $uuid.ToUpperInvariant()) "$uuid-$(Get-IdHash $uuid.ToUpperInvariant()).json" 'state name: an upper-case UUID keeps a readable prefix and gains a hash'
Write-SessionState 'a b/c:d\e' $state
Confirm-True (Test-Path -LiteralPath (Join-Path $stateDir "abcde-$(Get-IdHash 'a b/c:d\e').json")) 'state write: stripped id lands under its hashed name'
Write-SessionState '../up' $state
Confirm-True (Test-Path -LiteralPath (Join-Path $stateDir "..up-$(Get-IdHash '../up').json")) 'state write: a dotdot id stays inside the directory'
Write-SessionState '///' $state
Confirm-True (Test-Path -LiteralPath (Join-Path $stateDir "$(Get-IdHash '///').json")) 'state write: a punctuation-only id still gets a file'
$countBefore = Get-StateFileCount
Write-SessionState '' $state
Write-SessionState 'abc' $null
Confirm-Equal (Get-StateFileCount) $countBefore 'state write: empty id and null state write nothing'
Confirm-Equal (Read-SessionState '') $null 'state read: empty id gives null'
Confirm-Equal (Get-SessionStatePath '' $false) $null 'state path: empty id gives null'

# The record is written to a .tmp file and moved over the real one, so an interrupted write costs
# nothing. A .tmp left behind by one must not stop the next write.
[System.IO.File]::WriteAllText((Join-Path $stateDir 'abc.json.tmp'), 'half a record')
Write-SessionState 'abc' $state
Confirm-Equal (Read-SessionState 'abc').cost_usd 1.07 'state write: a stale .tmp file does not stop a later write'
Confirm-True (-not (Test-Path -LiteralPath (Join-Path $stateDir 'abc.json.tmp'))) 'state write: no .tmp file is left behind'

# The sweep: state files not written for a day go, at most once per six hours, marked by the stamp.
$oldFile = Join-Path $stateDir 'old.json'
$freshFile = Join-Path $stateDir 'fresh.json'
[System.IO.File]::WriteAllText($oldFile, '{ "v": 1 }')
[System.IO.File]::WriteAllText($freshFile, '{ "v": 1 }')
Write-StateFileAge $oldFile 25
Write-StateFileAge (Join-Path $stateDir 'abc.json') 25
Remove-Item -LiteralPath $stateStamp -Force
Write-SessionState 'abc' $state
Confirm-True (-not (Test-Path -LiteralPath $oldFile)) 'state sweep: day-old file deleted'
Confirm-True (Test-Path -LiteralPath $freshFile) 'state sweep: fresh file kept'
Confirm-True (Test-Path -LiteralPath (Join-Path $stateDir 'abc.json')) 'state sweep: the file just written is kept even if it was old'
Confirm-True (Test-Path -LiteralPath $stateStamp) 'state sweep: stamp written'
[System.IO.File]::WriteAllText($oldFile, '{ "v": 1 }')
Write-StateFileAge $oldFile 25
Write-SessionState 'abc' $state
Confirm-True (Test-Path -LiteralPath $oldFile) 'state sweep: a fresh stamp skips the sweep'
Write-StateFileAge $stateStamp 7
Write-SessionState 'abc' $state
Confirm-True (-not (Test-Path -LiteralPath $oldFile)) 'state sweep: a stamp older than six hours sweeps again'
Confirm-True (((Get-Item -LiteralPath $stateStamp).LastWriteTimeUtc - [DateTime]::UtcNow).TotalMinutes -gt -1) 'state sweep: stamp touched'
Invoke-SessionStateSweep (Join-Path $stateTemp 'no-such-dir')
Confirm-True $true 'state sweep: a missing directory is silent'

# The 200-file cap. A pass that hits it leaves the stamp alone, so the next render carries on with the
# backlog rather than draining 200 files every six hours.
function Initialize-SweepDir([string] $Name) {
    $d = Join-Path $stateTemp $Name
    New-Item -ItemType Directory -Force $d | Out-Null
    return $d
}
function Get-SweepFileCount([string] $Dir) { return @(Get-ChildItem -LiteralPath $Dir -Filter *.json -File -ErrorAction SilentlyContinue).Count }
$backlog = Initialize-SweepDir 'backlog'
for ($i = 0; $i -lt 250; $i++) {
    $p = Join-Path $backlog "old-$i.json"
    [System.IO.File]::WriteAllText($p, '{ "v": 1 }')
    Write-StateFileAge $p 30
}
Invoke-SessionStateSweep $backlog
Confirm-Equal (Get-SweepFileCount $backlog) 50 'state sweep: a capped pass deletes 200 and stops'
Confirm-True (-not (Test-Path -LiteralPath (Join-Path $backlog '.sweep'))) 'state sweep: a capped pass writes no stamp'
Invoke-SessionStateSweep $backlog
Confirm-Equal (Get-SweepFileCount $backlog) 0 'state sweep: the next pass clears the rest of the backlog'
Confirm-True (Test-Path -LiteralPath (Join-Path $backlog '.sweep')) 'state sweep: the pass that finished writes the stamp'

# A stamp or a file dated in the future is stale, not fresh: a clock change must not park housekeeping
# until the wall clock catches up.
$future = Initialize-SweepDir 'future'
$futureStamp = Join-Path $future '.sweep'
$futureOld = Join-Path $future 'old.json'
[System.IO.File]::WriteAllText($futureOld, '{ "v": 1 }')
Write-StateFileAge $futureOld 30
[System.IO.File]::WriteAllText($futureStamp, '')
Write-StateFileAge $futureStamp (-24 * 365)
Invoke-SessionStateSweep $future
Confirm-True (-not (Test-Path -LiteralPath $futureOld)) 'state sweep: a stamp dated a year ahead still sweeps'
$futureFile = Join-Path $future 'ahead.json'
[System.IO.File]::WriteAllText($futureFile, '{ "v": 1 }')
Write-StateFileAge $futureFile (-24 * 365)
Remove-Item -LiteralPath $futureStamp -Force
Invoke-SessionStateSweep $future
Confirm-True (-not (Test-Path -LiteralPath $futureFile)) 'state sweep: a file dated a year ahead is swept too'

# Read plus write on a warm cache. The first call pays for JIT and module load, so take the best of five.
$best = [double]::MaxValue
for ($i = 0; $i -lt 5; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prev = Read-SessionState 'abc'
    Write-SessionState 'abc' (Merge-SessionState $prev (Get-StatePayload 1.07) 1767225600)
    $sw.Stop()
    if ($sw.Elapsed.TotalMilliseconds -lt $best) { $best = $sw.Elapsed.TotalMilliseconds }
}
Confirm-True ($best -lt 20) "state timing: read plus write $([math]::Round($best, 2)) ms (limit 20)"
Write-Host ("{0,-40} {1,5:N2} ms  best of five read+write" -f 'state timing', $best)
} finally {
    if ($null -ne $oldTemp) { $env:TEMP = $oldTemp } else { Remove-Item Env:TEMP -ErrorAction SilentlyContinue }
}

Write-Host '== unit: folder' -ForegroundColor Cyan
# The four render paths from the issue, then both config modes. Nothing here touches the file system:
# the builder only splits strings, so the directories need not exist.
function Get-FolderPayload([string] $Dir, [string] $Root, $Owner, $Name) {
    $ws = [ordered]@{}
    if ($Dir) { $ws.current_dir = $Dir }
    if ($Root) { $ws.project_dir = $Root }
    if ($Owner -or $Name) { $ws.repo = [pscustomobject]@{ owner = $Owner; name = $Name } }
    return [pscustomobject]@{ workspace = [pscustomobject]$ws }
}
$cfgRepo = @{ Folder = 'repo'; Style = 'plain' }
$cfgLeaf = @{ Folder = 'leaf'; Style = 'plain' }
$seg = Get-FolderSegment (Get-FolderPayload 'C:\src\demo' 'C:\src\demo' 'octo' 'demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder octo/demo" 'folder at root: owner/name'
Confirm-Equal $seg.Short "$iconFolder demo" 'folder at root: short is the name alone'
Confirm-Equal $seg.Role 'folder' 'folder at root: role'
Confirm-Equal $seg.Name 'folder' 'folder at root: name'
Confirm-Equal $seg.Bold $false 'folder at root: not bold'
$seg = Get-FolderSegment (Get-FolderPayload 'C:\src\demo\tools' 'C:\src\demo' 'octo' 'demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder octo/demo $iconChevron tools" 'folder below root: owner/name, chevron, leaf'
Confirm-Equal $seg.Short "$iconFolder demo" 'folder below root: short is the name alone'
$seg = Get-FolderSegment (Get-FolderPayload 'C:\src\demo\' 'C:\src\demo' 'octo' 'demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder octo/demo" 'folder at root with a trailing separator: still the root'
$seg = Get-FolderSegment (Get-FolderPayload 'c:\SRC\Demo' 'C:\src\demo' 'octo' 'demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder octo/demo" 'folder at root in another case: still the root'
# The payload can spell either path with forward slashes, backslashes or a mix; the same directory is
# the root whichever way it is written.
$seg = Get-FolderSegment (Get-FolderPayload 'C:/src/demo' 'C:\src\demo' 'octo' 'demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder octo/demo" 'folder at root with forward slashes in current_dir: still the root'
$seg = Get-FolderSegment (Get-FolderPayload 'C:\src\demo' 'C:/src/demo' 'octo' 'demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder octo/demo" 'folder at root with forward slashes in project_dir: still the root'
$seg = Get-FolderSegment (Get-FolderPayload 'C:/src\demo/' 'C:\src/demo' 'octo' 'demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder octo/demo" 'folder at root with mixed slashes on both sides: still the root'
$seg = Get-FolderSegment (Get-FolderPayload 'C:/src/demo/tools' 'C:/src/demo' 'octo' 'demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder octo/demo $iconChevron tools" 'folder below root with forward slashes: chevron and leaf'
$seg = Get-FolderSegment (Get-FolderPayload 'C:\src\demo\tools' 'C:/src/demo/' 'octo' 'demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder octo/demo $iconChevron tools" 'folder below a forward-slash root with a trailing slash: chevron and leaf'
$seg = Get-FolderSegment (Get-FolderPayload 'C:\src\demo2' 'C:/src/demo' 'octo' 'demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder octo/demo $iconChevron demo2" 'folder beside the root: a longer name is not the root'
# A repo field that is not a string with visible text is no repo at all: the segment falls back to the
# leaf alone, whichever of the two fields is bad.
$badRepoFields = @(
    @{ Label = 'a number'; Value = 7 }
    @{ Label = 'an array'; Value = @('octo') }
    @{ Label = 'an object'; Value = [pscustomobject]@{ login = 'octo' } }
    @{ Label = 'null'; Value = $null }
    @{ Label = 'an empty string'; Value = '' }
    @{ Label = 'a whitespace-only string'; Value = '   ' }
)
foreach ($bad in $badRepoFields) {
    foreach ($field in @('owner', 'name')) {
        $payload = if ($field -eq 'owner') { Get-FolderPayload 'C:\src\demo\tools' 'C:\src\demo' $bad.Value 'demo' } else { Get-FolderPayload 'C:\src\demo\tools' 'C:\src\demo' 'octo' $bad.Value }
        $seg = Get-FolderSegment $payload $cfgRepo
        Confirm-Equal $seg.Text "$iconFolder tools" "folder with $($bad.Label) as repo.${field}: the leaf"
        Confirm-Equal $seg.Short $null "folder with $($bad.Label) as repo.${field}: no short form"
    }
}
$seg = Get-FolderSegment (Get-FolderPayload 'C:\src\demo\tools' '' 'octo' 'demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder octo/demo" 'folder with no project_dir: owner/name, no leaf'
$seg = Get-FolderSegment (Get-FolderPayload 'C:\src\demo\tools' 'C:\src\demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder tools" 'folder with no repo: the leaf as before'
Confirm-Equal $seg.Short $null 'folder with no repo: no short form'
Confirm-Equal (Get-FolderSegment (Get-FolderPayload '' 'C:\src\demo' 'octo' 'demo') $cfgRepo) $null 'folder with no current_dir: null'
Confirm-Equal (Get-FolderSegment ([pscustomobject]@{ model = @{ display_name = 'M' } }) $cfgRepo) $null 'folder with no workspace: null'
$seg = Get-FolderSegment (Get-FolderPayload 'C:\src\demo\tools' 'C:\src\demo' 'octo' 'demo') $cfgLeaf
Confirm-Equal $seg.Text "$iconFolder tools" 'folder leaf mode: the leaf even with a repo'
Confirm-Equal $seg.Short $null 'folder leaf mode: no short form'
$seg = Get-FolderSegment (Get-FolderPayload 'C:\src\demo' 'C:\src\demo' 'octo' 'demo') $cfgLeaf
Confirm-Equal $seg.Text "$iconFolder demo" 'folder leaf mode at root: the leaf'

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

# A folder with a Short form (the repo name alone) sheds it fourth in stage 1, after branch and still
# before any whole segment goes. Full width is 48 here; limits short gives 45, context 42, branch 40, folder 38.
$fitFolder = Get-FitSegmentSet
$fitFolder[6] = @{ Name = 'folder'; Text = 'FFFF'; Short = 'FF'; Role = 'folder'; Bold = $false }
$fitFolder[7] = @{ Name = 'branch'; Text = 'BBBB'; Short = 'BB'; Role = 'branch'; Bold = $false }
$line = Get-FittedLine $fitFolder 'plain' 40
Confirm-True ($line.Contains('FFFF') -and $line.Contains('BB') -and -not $line.Contains('BBBB')) 'fit: branch shortened before folder at 40'
$line = Get-FittedLine $fitFolder 'plain' 39
Confirm-Equal (Get-VisibleWidth $line) 38 'fit: stage 1 shrinks folder fourth'
Confirm-True ($line.Contains('FF') -and -not $line.Contains('FFFF') -and $line.Contains('LL')) 'fit: folder shortened, nothing dropped at 39'

# The shrink and drop orders are parameters that default to the registry, so a caller can hand in its own.
# Shrinking context alone takes 44 to 41; dropping badges after the default shrink of limits and context
# takes 38 to 33 (two cells of text and a three-cell separator).
$line = Get-FittedLine $fit 'plain' 43 -ShrinkOrder @('context')
Confirm-True ($line.Contains('CCC') -and -not $line.Contains('CCCCCC') -and $line.Contains('IIIIII')) 'fit: custom shrink order shortens context before limits'
Confirm-Equal (Get-VisibleWidth $line) 41 'fit: custom shrink order width'
$line = Get-FittedLine $fit 'plain' 37 -DropOrder @('badges')
Confirm-True ($line.Contains('LL') -and -not $line.Contains('GG')) 'fit: custom drop order drops badges, keeps lines'
Confirm-Equal (Get-VisibleWidth $line) 33 'fit: custom drop order width'
# The model segment stays whatever the drop order names: at width 10 nothing else is left to drop, so
# the line is the shrunk one, still holding the model.
$line = Get-FittedLine $fit 'plain' 10 -DropOrder @('model')
Confirm-True ($line.Contains('M') -and $line.Contains('CCC')) 'fit: drop order naming model leaves it in place'
Confirm-Equal (Get-VisibleWidth $line) 38 'fit: drop order naming model drops nothing'

Write-Host '== unit: pr' -ForegroundColor Cyan
# The link helper: OSC 8 open, the text, OSC 8 close, with ESC \ as the terminator. Anything that is not
# an http or https URL leaves the text alone, so a bad payload can never put a stray escape on the line.
$prUrl = 'https://github.com/octo/demo/pull/12'
$linkOpen = "$esc]8;;$prUrl$esc\"
$linkClose = "$esc]8;;$esc\"
Confirm-Equal (Format-Link $prUrl 'abc') "${linkOpen}abc${linkClose}" 'link: exact bytes'
Confirm-Equal (Format-Link '' 'abc') 'abc' 'link: empty url leaves the text alone'
Confirm-Equal (Format-Link $null 'abc') 'abc' 'link: null url leaves the text alone'
Confirm-Equal (Format-Link 'ftp://example.com/x' 'abc') 'abc' 'link: ftp url leaves the text alone'
Confirm-Equal (Format-Link 'javascript:alert(1)' 'abc') 'abc' 'link: javascript url leaves the text alone'
Confirm-Equal (Format-Link "https://example.com/$esc\x" 'abc') 'abc' 'link: a control character in the url leaves the text alone'
Confirm-Equal (Format-Link "https://example.com/`ax" 'abc') 'abc' 'link: a BEL in the url leaves the text alone'
# The C1 controls are the 8-bit forms of CSI, ST and OSC; a terminal that honours them would end the
# link early, so they are refused like the C0 range.
Confirm-Equal (Format-Link "https://example.com/$([char]0x9B)x" 'abc') 'abc' 'link: a C1 CSI (U+009B) in the url leaves the text alone'
Confirm-Equal (Format-Link "https://example.com/$([char]0x9C)x" 'abc') 'abc' 'link: a C1 ST (U+009C) in the url leaves the text alone'
Confirm-Equal (Format-Link "https://example.com/$([char]0x9D)x" 'abc') 'abc' 'link: a C1 OSC (U+009D) in the url leaves the text alone'
Confirm-Equal (Format-Link "https://example.com/$([char]0x80)x" 'abc') 'abc' 'link: a C1 control (U+0080) in the url leaves the text alone'
Confirm-Equal (Format-Link "https://example.com/$([char]0x7F)x" 'abc') 'abc' 'link: DEL in the url leaves the text alone'
Confirm-Equal (Format-Link "https://example.com/$([char]0xE9)x" 'abc') "$esc]8;;https://example.com/$([char]0xE9)x$esc\abc${linkClose}" 'link: a non-control non-ASCII character in the url is still linked'
Confirm-Equal (Format-Link 'HTTPS://EXAMPLE.COM/x' 'abc') "$esc]8;;HTTPS://EXAMPLE.COM/x$esc\abc${linkClose}" 'link: scheme is matched case-insensitively'
Confirm-Equal (Format-Link 'http://example.com/x' 'abc') "$esc]8;;http://example.com/x$esc\abc${linkClose}" 'link: plain http is linked too'
Confirm-Equal (Get-VisibleWidth (Format-Link $prUrl 'abc')) 3 'link: the url has no width'

# The segment: glyph, space, #number, the whole text wrapped in the link, coloured by the review state.
function Get-PrPayload([string] $Pr) {
    return ('{"pr":' + $Pr + '}') | ConvertFrom-Json
}
$seg = Get-PrSegment (Get-PrPayload ('{"number":12,"url":"' + $prUrl + '","review_state":"approved","kind":"pull_request"}'))
Confirm-Equal $seg.Name 'pr' 'pr approved: name'
Confirm-Equal $seg.Text "${linkOpen}$iconPr #12${linkClose}" 'pr approved: linked glyph and number'
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconPr #12" 'pr approved: plain text is the glyph and the number'
Confirm-Equal $seg.Role 'ok' 'pr approved: role ok'
Confirm-Equal $seg.Short $null 'pr approved: no short form'
Confirm-Equal $seg.Bold $false 'pr approved: not bold'
Confirm-Equal (Get-VisibleWidth $seg.Text) (Get-VisibleWidth "$iconPr #12") 'pr approved: the link adds no width'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"number":12,"url":"' + $prUrl + '","review_state":"changes requested"}'))).Role 'bad' 'pr changes requested: role bad'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"number":12,"url":"' + $prUrl + '","review_state":"CHANGES_REQUESTED"}'))).Role 'bad' 'pr CHANGES_REQUESTED: underscore and case folded, role bad'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"number":12,"url":"' + $prUrl + '","review_state":"Approved"}'))).Role 'ok' 'pr Approved: case folded, role ok'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"number":12,"url":"' + $prUrl + '","review_state":"review_required"}'))).Role 'dim' 'pr unknown state: role dim'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"number":12,"url":"' + $prUrl + '","review_state":null}'))).Role 'dim' 'pr null state: role dim'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"number":12,"url":"' + $prUrl + '"}'))).Role 'dim' 'pr missing state: role dim'
$seg = Get-PrSegment (Get-PrPayload '{"number":12,"review_state":"approved"}')
Confirm-Equal $seg.Text "$iconPr #12" 'pr missing url: text unlinked'
Confirm-Equal $seg.Role 'ok' 'pr missing url: still coloured by the state'
Confirm-Equal (Get-PrSegment (Get-PrPayload '{"number":12,"url":"ftp://example.com/12"}')).Text "$iconPr #12" 'pr ftp url: text unlinked'
Confirm-Equal (Get-PrSegment (Get-PrPayload '{"number":12,"url":7}')).Text "$iconPr #12" 'pr numeric url: text unlinked'
Confirm-Equal (Get-PrSegment (Get-PrPayload '{"number":345,"url":"HTTPS://github.com/octo/demo/pull/345"}')).Text "$esc]8;;HTTPS://github.com/octo/demo/pull/345$esc\$iconPr #345${linkClose}" 'pr upper-case scheme: linked'
Confirm-Equal (Get-PrSegment ([pscustomobject]@{ model = @{ display_name = 'M' } })) $null 'pr missing object: null'
Confirm-Equal (Get-PrSegment (Get-PrPayload 'null')) $null 'pr null object: null'
Confirm-Equal (Get-PrSegment (Get-PrPayload '"open"')) $null 'pr object is a string: null'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"url":"' + $prUrl + '","review_state":"approved"}'))) $null 'pr missing number: null even with a url'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"number":"12","url":"' + $prUrl + '"}'))) $null 'pr string number: null'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"number":12.5,"url":"' + $prUrl + '"}'))) $null 'pr float number: null'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"number":0,"url":"' + $prUrl + '"}'))) $null 'pr zero number: null'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"number":-3,"url":"' + $prUrl + '"}'))) $null 'pr negative number: null'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"number":2147483648,"url":"' + $prUrl + '"}'))) $null 'pr number above Int32: null'
Confirm-Equal (Get-PrSegment (Get-PrPayload ('{"number":12.0,"url":"' + $prUrl + '"}'))).Text "${linkOpen}$iconPr #12${linkClose}" 'pr whole float number: rendered as 12'

# The renderer wraps the link in the segment's colour codes in both styles, so the link sits inside the
# colour and the terminal keeps the background through it.
$segPr = Get-PrSegment (Get-PrPayload ('{"number":12,"url":"' + $prUrl + '","review_state":"approved"}'))
Confirm-Equal (Format-Line @($segPr) 'plain') "$esc[32m${linkOpen}$iconPr #12${linkClose}$esc[0m" 'pr plain: colour outside the link'
Confirm-Equal (Format-Line @($segPr) 'powerline') "$esc[0;48;5;28;38;5;231m ${linkOpen}$iconPr #12${linkClose} $esc[0m$esc[38;5;28m$arrow$esc[0m" 'pr powerline: block colour outside the link'

# The URL never counts towards the width, so a long one fits where a short one does and is shed in the
# same place. The fit set is 44 wide; the pr segment adds five cells and a separator, 52, and 49 needs
# only the limits short form, so at both widths the pr segment must survive whatever the URL length.
$longUrl = 'https://github.com/octo/demo/pull/12?' + ('x' * 263)
Confirm-Equal $longUrl.Length 300 'pr long url: 300 characters'
$fitShort = @(Get-FitSegmentSet) + @(Get-PrSegment (Get-PrPayload ('{"number":12,"url":"' + $prUrl + '","review_state":"approved"}')))
$fitLong = @(Get-FitSegmentSet) + @(Get-PrSegment (Get-PrPayload ('{"number":12,"url":"' + $longUrl + '","review_state":"approved"}')))
Confirm-Equal (Get-VisibleWidth (Format-Line $fitLong 'plain')) 52 'pr long url: full line is 52 wide'
foreach ($w in @(60, 49)) {
    $shortLine = Get-FittedLine $fitShort 'plain' $w
    $longLine = Get-FittedLine $fitLong 'plain' $w
    Confirm-Equal (ConvertTo-PlainText $longLine) (ConvertTo-PlainText $shortLine) "pr long url at ${w}: same visible text as the short url"
    Confirm-Equal (Get-VisibleWidth $longLine) (Get-VisibleWidth $shortLine) "pr long url at ${w}: same width as the short url"
    Confirm-True ((Get-VisibleWidth $longLine) -le $w) "pr long url at ${w}: fits"
    Confirm-True ($longLine.Contains("$iconPr #12") -and $longLine.Contains($longUrl)) "pr long url at ${w}: pr segment kept with its link"
}
$line = Get-FittedLine $fitLong 'plain' 49
Confirm-True ($line.Contains('III') -and -not $line.Contains('IIIIII') -and $line.Contains('CCCCCC')) 'pr long url at 49: limits shortened, nothing dropped'
# In the drop order pr goes after limits and before folder. Both short forms take 52 to 46; dropping
# lines (41), badges (36), cost (31) and limits (25) leaves pr on a 25-cell line, and 24 drops pr next,
# keeping folder and branch. The pr record sits last in this set, so it renders after BB here.
$line = Get-FittedLine $fitLong 'plain' 25
Confirm-Equal (ConvertTo-PlainText $line) "M $chevron CCC $chevron FF $chevron BB $chevron $iconPr #12" 'pr drop order: at 25 pr is still on the line'
$line = Get-FittedLine $fitLong 'plain' 24
Confirm-Equal (ConvertTo-PlainText $line) "M $chevron CCC $chevron FF $chevron BB" 'pr drop order: at 24 pr goes before folder and branch'

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

# A 1M window moves the colour bands to 70 and 90, so the same percentage is a different colour there.
function Get-WideContextPayload([double] $Pct) {
    return [pscustomobject]@{ context_window = [pscustomobject]@{ used_percentage = $Pct; total_input_tokens = 650000; total_output_tokens = 0; context_window_size = 1000000 } }
}
Confirm-Equal (Get-ContextSegment (Get-WideContextPayload 65)).Role 'ok' 'context 1M 65: role ok, not warn'
Confirm-Equal (Get-ContextSegment (Get-WideContextPayload 75)).Role 'warn' 'context 1M 75: role warn'
Confirm-Equal (Get-ContextSegment (Get-WideContextPayload 92)).Role 'bad' 'context 1M 92: role bad'
Confirm-Equal (Get-ContextSegment (Get-ContextPayload 65)).Role 'warn' 'context 200k 65: role stays warn'
Confirm-True (Get-ContextSegment (Get-WideContextPayload 65)).Text.Contains("650k/$(K 1000000)") 'context 1M 65: counts'

Write-Host '== unit: threshold' -ForegroundColor Cyan
Confirm-Equal (Get-ThresholdRole 65) 'warn' 'threshold 65: default bands warn'
Confirm-Equal (Get-ThresholdRole 65 70 90) 'ok' 'threshold 65 at 70/90: ok'
Confirm-Equal (Get-ThresholdRole 70 70 90) 'warn' 'threshold 70 at 70/90: warn'
Confirm-Equal (Get-ThresholdRole 89 70 90) 'warn' 'threshold 89 at 70/90: warn'
Confirm-Equal (Get-ThresholdRole 92 70 90) 'bad' 'threshold 92 at 70/90: bad'
Confirm-Equal (Get-ThresholdRole 85) 'bad' 'threshold 85: default bands bad'
Confirm-True (Test-WideWindow 1000000) 'wide window: 1000000'
Confirm-True (-not (Test-WideWindow 200000) -and -not (Test-WideWindow 1048576) -and -not (Test-WideWindow $null)) 'wide window: 200000, 1048576 and null are not'

Write-Host '== unit: model' -ForegroundColor Cyan
function Get-ModelPayload($Size, $Exceeds) {
    $p = [pscustomobject]@{ model = [pscustomobject]@{ display_name = 'Fable 5.1' } }
    if ($null -ne $Size) { $p | Add-Member -NotePropertyName context_window -NotePropertyValue ([pscustomobject]@{ used_percentage = 65; context_window_size = $Size }) }
    if ($null -ne $Exceeds) { $p | Add-Member -NotePropertyName exceeds_200k_tokens -NotePropertyValue $Exceeds }
    return $p
}
$plainCfg = @{ Style = 'plain' }
$seg = Get-ModelSegment (Get-ModelPayload 1000000) $plainCfg
Confirm-True ((ConvertTo-PlainText $seg.Text).EndsWith("$iconModel Fable 5.1 1M")) 'model 1M: text ends in 1M'
Confirm-True ($seg.Text.Contains("$esc[22;36m1M$esc[1;36m")) 'model 1M: plain marker is muted, then bold cyan again'
Confirm-Equal $seg.Role 'model' 'model 1M: role'
Confirm-Equal $seg.Short $null 'model 1M: no short form'
$seg = Get-ModelSegment (Get-ModelPayload 1000000) @{ Style = 'powerline' }
Confirm-True ($seg.Text.Contains("$esc[38;5;152m1M$esc[38;5;231m")) 'model 1M: powerline marker restores the model foreground'
Confirm-Equal (Get-ModelSegment (Get-ModelPayload 200000) $plainCfg).Text "$iconModel Fable 5.1" 'model 200k: exact text'
Confirm-Equal (Get-ModelSegment (Get-ModelPayload $null) $plainCfg).Text "$iconModel Fable 5.1" 'model no size: exact text'
Confirm-Equal (Get-ModelSegment (Get-ModelPayload 400000) $plainCfg).Text "$iconModel Fable 5.1" 'model other size: exact text'
$seg = Get-ModelSegment (Get-ModelPayload 1000000 $true) $plainCfg
Confirm-True ((ConvertTo-PlainText $seg.Text).EndsWith("Fable 5.1 1M $iconConflict")) 'model 1M exceeds: glyph after the marker'
$seg = Get-ModelSegment (Get-ModelPayload 1000000 $false) $plainCfg
Confirm-True (-not $seg.Text.Contains($iconConflict)) 'model 1M not exceeded: no glyph'
Confirm-Equal (Get-ModelSegment (Get-ModelPayload 200000 $true) $plainCfg).Text "$iconModel Fable 5.1 $iconConflict" 'model 200k exceeds: glyph without a marker'
# The field is a documented boolean; anything else, including values -eq $true would coerce, gives no glyph.
foreach ($odd in @(@{ Label = 'string true'; Value = 'true' }, @{ Label = 'number 1'; Value = 1 }, @{ Label = 'null'; Value = $null },
        @{ Label = 'array'; Value = @($true) }, @{ Label = 'object'; Value = [pscustomobject]@{ value = $true } })) {
    $p = Get-ModelPayload 200000
    $p | Add-Member -NotePropertyName exceeds_200k_tokens -NotePropertyValue $odd.Value
    Confirm-Equal (Get-ModelSegment $p $plainCfg).Text "$iconModel Fable 5.1" "model exceeds as $($odd.Label): no glyph"
}
Confirm-Equal (Get-ModelSegment ([pscustomobject]@{ model = [pscustomobject]@{ display_name = '' } }) $plainCfg) $null 'model: empty name omits the segment'
Write-Host '== unit: limits' -ForegroundColor Cyan
# Resets in the past keep TimeLeft empty, so the text is deterministic. Payloads go through ConvertFrom-Json
# so a null used_percentage is a real null property, the way Claude Code sends it.
function Get-LimitsPayload([string] $RateLimits) {
    return ('{"rate_limits":' + $RateLimits + '}') | ConvertFrom-Json
}

$seg = Get-LimitsSegment (Get-LimitsPayload '{"five_hour":{"used_percentage":24,"resets_at":1700000000},"seven_day":{"used_percentage":41,"resets_at":1700000000},"spend_limit":{"used_percentage":62,"resets_at":1700000000}}')
Confirm-Equal $seg.Text "$iconLimit 5h 24% 7d 41% `$ 62%" 'limits all three: 5h, 7d, then spend'
Confirm-Equal $seg.Short "$iconLimit `$ 62%" 'limits all three: short keeps the spend figure that drives the colour'
Confirm-Equal $seg.Role 'warn' 'limits all three: role from the worst figure'

$seg = Get-LimitsSegment (Get-LimitsPayload '{"spend_limit":{"used_percentage":62,"resets_at":1700000000}}')
Confirm-Equal $seg.Text "$iconLimit `$ 62%" 'limits spend alone: one figure, no 5h'
Confirm-True ($null -eq $seg.Short) 'limits spend alone: no short form'

$seg = Get-LimitsSegment (Get-LimitsPayload '{"five_hour":{"used_percentage":10,"resets_at":1700000000},"spend_limit":{"used_percentage":92,"resets_at":1700000000}}')
Confirm-Equal $seg.Text "$iconLimit 5h 10% `$ 92%" 'limits spend 92 with 5h 10: text'
Confirm-Equal $seg.Role 'bad' 'limits spend 92 with 5h 10: spend drives the colour'
Confirm-Equal $seg.Short "$iconLimit `$ 92%" 'limits spend 92 with 5h 10: short keeps the spend figure, not the 5h one'

$seg = Get-LimitsSegment (Get-LimitsPayload '{"five_hour":{"used_percentage":61,"resets_at":1700000000},"seven_day":{"used_percentage":12,"resets_at":1700000000}}')
Confirm-Equal $seg.Text "$iconLimit 5h 61% 7d 12%" 'limits spend_limit absent: unchanged text'
Confirm-Equal $seg.Role 'warn' 'limits spend_limit absent: role'
Confirm-Equal $seg.Short "$iconLimit 5h 61%" 'limits spend_limit absent: short keeps the 5h figure when it is the worst'

# The Short form keeps whichever figure drives the colour, so a fitted line never shows a red segment
# with a calm number on it. Below the warn line nothing drives the colour, and the first present figure
# stands in; a tie keeps render order (5h, 7d, then spend); the countdown never follows.
$seg = Get-LimitsSegment (Get-LimitsPayload '{"five_hour":{"used_percentage":10,"resets_at":1700000000},"seven_day":{"used_percentage":88,"resets_at":1700000000}}')
Confirm-Equal $seg.Text "$iconLimit 5h 10% 7d 88%" 'limits 7d worst: text'
Confirm-Equal $seg.Short "$iconLimit 7d 88%" 'limits 7d worst: short keeps the 7d figure'
Confirm-Equal $seg.Role 'bad' 'limits 7d worst: role'

$seg = Get-LimitsSegment (Get-LimitsPayload '{"five_hour":{"used_percentage":10,"resets_at":1700000000},"seven_day":{"used_percentage":41,"resets_at":1700000000},"spend_limit":{"used_percentage":30,"resets_at":1700000000}}')
Confirm-Equal $seg.Short "$iconLimit 5h 10%" 'limits all below warn: short is the first figure, not the largest'
Confirm-Equal $seg.Role 'ok' 'limits all below warn: role'

$seg = Get-LimitsSegment (Get-LimitsPayload '{"seven_day":{"used_percentage":92,"resets_at":1700000000},"spend_limit":{"used_percentage":10,"resets_at":1700000000}}')
Confirm-Equal $seg.Text "$iconLimit 7d 92% `$ 10%" 'limits no 5h, 7d red: text'
Confirm-Equal $seg.Short "$iconLimit 7d 92%" 'limits no 5h, 7d red: short exists and keeps the 7d figure'
Confirm-Equal $seg.Role 'bad' 'limits no 5h, 7d red: role'

$seg = Get-LimitsSegment (Get-LimitsPayload '{"seven_day":{"used_percentage":20,"resets_at":1700000000},"spend_limit":{"used_percentage":30,"resets_at":1700000000}}')
Confirm-Equal $seg.Text "$iconLimit 7d 20% `$ 30%" 'limits no 5h, all below warn: text'
Confirm-Equal $seg.Short "$iconLimit 7d 20%" 'limits no 5h, all below warn: short is the first present figure'
Confirm-Equal $seg.Role 'ok' 'limits no 5h, all below warn: role'

$seg = Get-LimitsSegment (Get-LimitsPayload '{"five_hour":{"used_percentage":70,"resets_at":1700000000},"seven_day":{"used_percentage":70,"resets_at":1700000000},"spend_limit":{"used_percentage":70,"resets_at":1700000000}}')
Confirm-Equal $seg.Text "$iconLimit 5h 70% 7d 70% `$ 70%" 'limits three-way tie: text'
Confirm-Equal $seg.Short "$iconLimit 5h 70%" 'limits three-way tie: 5h wins by render order'
Confirm-Equal $seg.Role 'warn' 'limits three-way tie: role'
$seg = Get-LimitsSegment (Get-LimitsPayload '{"seven_day":{"used_percentage":70,"resets_at":1700000000},"spend_limit":{"used_percentage":70,"resets_at":1700000000}}')
Confirm-Equal $seg.Text "$iconLimit 7d 70% `$ 70%" 'limits 7d and spend tie: text'
Confirm-Equal $seg.Short "$iconLimit 7d 70%" 'limits 7d and spend tie: 7d wins by render order'
Confirm-Equal $seg.Role 'warn' 'limits 7d and spend tie: role'
$seg = Get-LimitsSegment (Get-LimitsPayload '{"five_hour":{"used_percentage":69.6,"resets_at":1700000000},"seven_day":{"used_percentage":70.4,"resets_at":1700000000}}')
Confirm-Equal $seg.Text "$iconLimit 5h 70% 7d 70%" 'limits tie after rounding: text rounds both to 70'
Confirm-Equal $seg.Short "$iconLimit 5h 70%" 'limits tie after rounding: 5h wins by render order'
Confirm-Equal $seg.Role 'warn' 'limits tie after rounding: role'

$seg = Get-LimitsSegment (Get-LimitsPayload '{"seven_day":{"used_percentage":92,"resets_at":1700000000}}')
Confirm-Equal $seg.Text "$iconLimit 7d 92%" 'limits 7d alone: text'
Confirm-True ($null -eq $seg.Short) 'limits 7d alone: short would equal text, so none'

$seg = Get-LimitsSegment (Get-LimitsPayload '{"five_hour":{"used_percentage":70,"resets_at":4102444800},"seven_day":{"used_percentage":12,"resets_at":4102444800}}')
Confirm-True ($seg.Text.StartsWith("$iconLimit 5h 70% (") -and $seg.Text.EndsWith(') 7d 12%')) 'limits 5h worst with a live reset: text carries the countdown'
Confirm-Equal $seg.Short "$iconLimit 5h 70%" 'limits 5h worst with a live reset: short drops the countdown'

$seg = Get-LimitsSegment (Get-LimitsPayload '{"five_hour":{"used_percentage":61,"resets_at":1700000000},"seven_day":{"used_percentage":12,"resets_at":1700000000},"spend_limit":{"used_percentage":null,"resets_at":null}}')
Confirm-Equal $seg.Text "$iconLimit 5h 61% 7d 12%" 'limits spend_limit null percentage: unchanged text'

Confirm-True ($null -eq (Get-LimitsSegment (Get-LimitsPayload '{"five_hour":{"used_percentage":null},"seven_day":{"used_percentage":null},"spend_limit":{"used_percentage":null}}'))) 'limits all null: segment omitted'
Confirm-True ($null -eq (Get-LimitsSegment ([pscustomobject]@{}))) 'limits: missing rate_limits'

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
# Every row asserts all five columns, so a count that stops feeding Dirty, or a line shape that lands in
# the wrong bucket, cannot pass on the strength of the columns the row happened to check.
$porcelainTable = @(
    @{ Name = 'clean';                        Text = "## main`n";                       Staged = 0; Modified = 0; Untracked = 0; Conflicts = 0; Dirty = $false }
    @{ Name = 'blank and whitespace lines';   Text = "## main`n`n   `n`t`t`n";          Staged = 0; Modified = 0; Untracked = 0; Conflicts = 0; Dirty = $false }
    @{ Name = 'one-character line';           Text = "## main`nM`n";                    Staged = 0; Modified = 0; Untracked = 0; Conflicts = 0; Dirty = $false }
    @{ Name = 'ignored entry';                Text = "## main`n!! build/`n";            Staged = 0; Modified = 0; Untracked = 0; Conflicts = 0; Dirty = $false }
    @{ Name = 'modified';                     Text = "## main`n M file.txt`n";          Staged = 0; Modified = 1; Untracked = 0; Conflicts = 0; Dirty = $true }
    @{ Name = 'untracked (CRLF)';             Text = "## main`r`n?? new.txt`r`n";       Staged = 0; Modified = 0; Untracked = 1; Conflicts = 0; Dirty = $true }
    @{ Name = 'untracked directory';          Text = "## main`n?? src/`n";              Staged = 0; Modified = 0; Untracked = 1; Conflicts = 0; Dirty = $true }
    @{ Name = 'staged add';                   Text = "## main`nA  b`n";                 Staged = 1; Modified = 0; Untracked = 0; Conflicts = 0; Dirty = $true }
    @{ Name = 'staged rename';                Text = "## main`nR  old -> new`n";        Staged = 1; Modified = 0; Untracked = 0; Conflicts = 0; Dirty = $true }
    @{ Name = 'staged and modified';          Text = "## main`nMM a`n";                 Staged = 1; Modified = 1; Untracked = 0; Conflicts = 0; Dirty = $true }
    @{ Name = 'work tree deletion';           Text = "## main`n D gone.txt`n";          Staged = 0; Modified = 1; Untracked = 0; Conflicts = 0; Dirty = $true }
    @{ Name = 'staged deletion';              Text = "## main`nD  staged-gone.txt`n";   Staged = 1; Modified = 0; Untracked = 0; Conflicts = 0; Dirty = $true }
    @{ Name = 'type change';                  Text = "## main`n T mode.txt`n";          Staged = 0; Modified = 1; Untracked = 0; Conflicts = 0; Dirty = $true }
    @{ Name = 'intent-to-add';                Text = "## main`n A new.txt`n";           Staged = 0; Modified = 1; Untracked = 0; Conflicts = 0; Dirty = $true }
    @{ Name = 'conflict';                     Text = "## main`nUU a`n";                 Staged = 0; Modified = 0; Untracked = 0; Conflicts = 1; Dirty = $true }
    @{ Name = 'all seven conflict pairs';     Text = "## main`nDD a`nAA b`nAU c`nUA d`nUD e`nDU f`nUU g`n"; Staged = 0; Modified = 0; Untracked = 0; Conflicts = 7; Dirty = $true }
    @{ Name = 'mixed block';                  Text = "## main`n M a`nA  b`n?? c`n";     Staged = 1; Modified = 1; Untracked = 1; Conflicts = 0; Dirty = $true }
)
foreach ($row in $porcelainTable) {
    $r = Read-PorcelainStatus $row.Text
    foreach ($col in @('Staged', 'Modified', 'Untracked', 'Conflicts', 'Dirty')) {
        Confirm-Equal $r[$col] $row[$col] "porcelain $($row.Name): $col"
    }
}
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

Write-Host '== unit: payload text' -ForegroundColor Cyan
Confirm-Equal (Test-PayloadText 'octo') $true 'payload text: a string with content is text'
Confirm-Equal (Test-PayloadText '   ') $false 'payload text: whitespace only is not'
Confirm-Equal (Test-PayloadText '') $false 'payload text: empty string is not'
Confirm-Equal (Test-PayloadText $null) $false 'payload text: null is not'
Confirm-Equal (Test-PayloadText 7) $false 'payload text: a number is not'
Confirm-Equal (Test-PayloadText @('octo')) $false 'payload text: an array is not'

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
# The counts and the dirty flag read a value by the same rule: a whole number that fits an Int32. Anything
# else gives no count and no dirty flag, except a boolean, which gives the flag but never a fabricated count.
foreach ($case in @(
        @{ Json = '{"modified":"2"}';           Count = 0; Dirty = $false; Name = 'string count' }
        @{ Json = '{"modified":true}';          Count = 0; Dirty = $true;  Name = 'boolean' }
        @{ Json = '{"modified":0}';             Count = 0; Dirty = $false; Name = 'zero' }
        @{ Json = '{"modified":-1}';            Count = 0; Dirty = $false; Name = 'negative' }
        @{ Json = '{"modified":2.0}';           Count = 2; Dirty = $true;  Name = 'whole float' }
        @{ Json = '{"modified":1.5}';           Count = 0; Dirty = $false; Name = 'fraction' }
        @{ Json = '{"modified":0.5}';           Count = 0; Dirty = $false; Name = 'fraction below one' }
        @{ Json = '{"modified":2147483647}';    Count = 2147483647; Dirty = $true; Name = 'Int32 max' }
        @{ Json = '{"modified":2147483648}';    Count = 0; Dirty = $false; Name = 'above Int32 max' }
        @{ Json = '{"modified":1e300}';         Count = 0; Dirty = $false; Name = 'huge double' }
        @{ Json = '{"modified":2}';             Count = 2; Dirty = $true;  Name = 'integer' })) {
    $status = $case.Json | ConvertFrom-Json
    Confirm-Equal (Get-PayloadCount $status).Modified $case.Count "payload counts: $($case.Name) count"
    Confirm-Equal (Test-PayloadDirty $status) $case.Dirty "payload counts: $($case.Name) dirty flag"
}

Write-Host '== unit: payload status' -ForegroundColor Cyan
$s = Read-PayloadStatus ('{"branch":"feature/x","status":{"modified":2,"untracked":1}}' | ConvertFrom-Json)
Confirm-Equal $s.Branch 'feature/x' 'payload status: branch'
Confirm-Equal $s.Dirty $true 'payload status: dirty'
Confirm-Equal $s.Modified 2 'payload status: modified'
Confirm-Equal $s.Untracked 1 'payload status: untracked'
Confirm-Equal (($s.Ahead + $s.Behind + $s.Staged + $s.Conflicts)) 0 'payload status: ahead, behind, staged and conflicts are 0'
# One record shape for both sources: the payload record carries exactly the keys the porcelain record does.
$porcelainKeys = @((Read-PorcelainStatus "## main`n").Keys | Sort-Object) -join ','
Confirm-Equal (@($s.Keys | Sort-Object) -join ',') $porcelainKeys 'payload status: same keys as the porcelain record'
$s = Read-PayloadStatus ('{"branch":"main","status":"clean"}' | ConvertFrom-Json)
Confirm-Equal $s.Branch 'main' 'payload status: string status branch'
Confirm-Equal $s.Dirty $false 'payload status: string status clean'
Confirm-Equal (@($s.Keys | Sort-Object) -join ',') $porcelainKeys 'payload status: string status has the full record'
Confirm-Equal (Read-PayloadStatus ('{"branch":""}' | ConvertFrom-Json)) $null 'payload status: empty branch gives null'
Confirm-Equal (Read-PayloadStatus ('{}' | ConvertFrom-Json)) $null 'payload status: no branch gives null'

Write-Host '== unit: branch segment' -ForegroundColor Cyan
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'main'; status = 'clean' } })
Confirm-True ($null -ne $seg -and $seg.Text.Contains('main')) "branch payload clean: text has the branch name, got '$($seg.Text)'"
Confirm-Equal $seg.Text "$iconHome main" 'branch payload clean: home icon, no pencil'
Confirm-Equal $seg.Role 'branch' 'branch payload clean: role'

# Object statuses go through ConvertFrom-Json, as the samples do. A hashtable would pass the dirty check
# on its own Count property rather than on the named keys.
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = ('{"modified":2}' | ConvertFrom-Json) } })
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ~2 $iconDirty" 'branch payload dirty counts: branch icon, modified count, pencil'
Confirm-Equal $seg.Role 'warn' 'branch payload dirty counts: role'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch payload dirty counts: short drops the count and keeps the pencil'
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = ('{"modified":0}' | ConvertFrom-Json) } })
Confirm-Equal $seg.Text "$iconBranch feature/x" 'branch payload zero count: clean, no count, no pencil'
Confirm-Equal $seg.Role 'branch' 'branch payload zero count: role'
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = ('{"modified":"2"}' | ConvertFrom-Json) } }) @{ Style = 'plain' }
Confirm-Equal $seg.Text "$iconBranch feature/x" 'branch payload string count: not a count, so clean with no pencil'
Confirm-Equal $seg.Role 'branch' 'branch payload string count: role'
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = ('{"modified":true}' | ConvertFrom-Json) } }) @{ Style = 'plain' }
Confirm-Equal $seg.Text "$iconBranch feature/x $iconDirty" 'branch payload boolean: pencil, no fabricated count'
Confirm-Equal $seg.Role 'warn' 'branch payload boolean: role'

$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = ('{"modified":2,"untracked":1}' | ConvertFrom-Json) } }) @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ~2 ?1 $iconDirty" 'branch payload modified and untracked: tilde then question mark'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[90m~2$esc[33m $esc[90m?1$esc[33m $iconDirty" 'branch payload modified and untracked: counts dim, warn colour restored'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch payload modified and untracked: short has no counts'
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = 'modified' } }) @{ Style = 'plain' }
Confirm-Equal $seg.Text "$iconBranch feature/x $iconDirty" 'branch payload string status: pencil only, no counts'
Confirm-Equal $seg.Role 'warn' 'branch payload string status: role'
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = ('{"conflicts":1}' | ConvertFrom-Json) } }) @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ${iconConflict}1 $iconDirty" 'branch payload conflict: conflict glyph and count before the pencil'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[31m${iconConflict}1$esc[33m $iconDirty" 'branch payload conflict: removed colour, warn colour restored'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch payload conflict: short has no conflict glyph'
Confirm-Equal $seg.Role 'warn' 'branch payload conflict: role'

Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{ git = @{} }))) 'branch payload git object with no branch: segment omitted'
Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{ git = @{ branch = '' } }))) 'branch payload empty branch: segment omitted'

# Ahead and behind counts only ever come from the git probe, so stand in for Get-GitBranch here and put
# the real one back afterwards. The "not a repo" checks below then double as proof the restore worked.
# Each stand-in record carries the full key set, the shape Read-PorcelainStatus and Read-PayloadStatus
# both return, so no case passes because a missing key happened to read as nothing.
function Get-GitBranch([string] $Dir, [int] $TimeoutMs) { return $script:mockGitBranch }
function Get-BranchRecord([string] $Branch, [bool] $Dirty, [int] $Ahead = 0, [int] $Behind = 0, [int] $Staged = 0, [int] $Modified = 0, [int] $Untracked = 0, [int] $Conflicts = 0) {
    return @{ Branch = $Branch; Dirty = $Dirty; Ahead = $Ahead; Behind = $Behind; Staged = $Staged; Modified = $Modified; Untracked = $Untracked; Conflicts = $Conflicts }
}
$probePayload = [pscustomobject]@{ workspace = @{ current_dir = 'x' } }
$script:mockGitBranch = Get-BranchRecord 'feature/x' $false -Ahead 1 -Behind 2
$seg = Get-BranchSegment $probePayload
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ${iconAhead}1 ${iconBehind}2" 'branch counts: ahead then behind after the name'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[90m${iconAhead}1$esc[35m $esc[90m${iconBehind}2$esc[35m" 'branch counts: arrows dim, branch colour restored (plain, no cfg)'
Confirm-Equal $seg.Short "$iconBranch feature/x" 'branch counts: short has no arrows'
Confirm-Equal $seg.Role 'branch' 'branch counts: role'
$seg = Get-BranchSegment $probePayload @{ Style = 'powerline' }
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[38;5;245m${iconAhead}1$esc[38;5;231m $esc[38;5;245m${iconBehind}2$esc[38;5;231m" 'branch counts: powerline arrows restore the block fg'
$script:mockGitBranch = Get-BranchRecord 'topic' $false -Ahead 2
$seg = Get-BranchSegment $probePayload @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch topic ${iconAhead}2" 'branch ahead only: no behind arrow'
$script:mockGitBranch = Get-BranchRecord 'main' $false -Behind 3
$seg = Get-BranchSegment $probePayload @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconHome main ${iconBehind}3" 'branch behind only: no ahead arrow'
$script:mockGitBranch = Get-BranchRecord 'main' $false
$seg = Get-BranchSegment $probePayload @{ Style = 'plain' }
Confirm-Equal $seg.Text "$iconHome main" 'branch zero counts: exactly the old text, no escapes'
Confirm-Equal $seg.Short "$iconHome main" 'branch zero counts: short is the same text'
$script:mockGitBranch = Get-BranchRecord 'feature/x' $true -Ahead 1 -Behind 1
$seg = Get-BranchSegment $probePayload @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ${iconAhead}1 ${iconBehind}1 $iconDirty" 'branch dirty with counts: pencil last'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[90m${iconAhead}1$esc[33m $esc[90m${iconBehind}1$esc[33m $iconDirty" 'branch dirty with counts: arrows restore the warn colour'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch dirty with counts: short keeps the pencil, drops the arrows'
Confirm-Equal $seg.Role 'warn' 'branch dirty with counts: role'
$script:mockGitBranch = Get-BranchRecord 'feature/x' $true -Ahead 1 -Behind 2 -Staged 2 -Modified 1 -Untracked 3 -Conflicts 1
$seg = Get-BranchSegment $probePayload @{ Style = 'plain' }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ${iconAhead}1 ${iconBehind}2 +2 ~1 ?3 ${iconConflict}1 $iconDirty" 'branch everything: arrows, staged, modified, untracked, conflict, pencil'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[90m${iconAhead}1$esc[33m $esc[90m${iconBehind}2$esc[33m $esc[90m+2$esc[33m $esc[90m~1$esc[33m $esc[90m?3$esc[33m $esc[31m${iconConflict}1$esc[33m $iconDirty" 'branch everything: counts dim, conflict red, warn colour restored after each'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch everything: short is icon, name, pencil'
$script:mockGitBranch = Get-BranchRecord 'main' $true -Staged 1 -Modified 2
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

Write-Host '== state' -ForegroundColor Cyan
# Whole renders in a child pwsh, which inherits TEMP, so the state files land under $tmp. These payloads
# carry a session_id and a git object (so no git probe); the samples in the matrix below carry neither.
$oldTemp = $env:TEMP
$renderTemp = Join-Path $tmp 'temp-render'
New-Item -ItemType Directory -Force $renderTemp | Out-Null
$env:TEMP = $renderTemp
try {
$renderStateDir = Join-Path $renderTemp 'claude-statusline-state'
function Get-StatePayloadJson([double] $Cost, [string] $SessionId = 'sess-1') {
    $p = [ordered]@{ model = @{ display_name = 'M' }; cost = @{ total_cost_usd = $Cost }; git = @{ branch = 'main'; status = 'clean' } }
    if ($SessionId) { $p.session_id = $SessionId }
    return ($p | ConvertTo-Json -Compress)
}
function Get-RenderStateFileCount { return @(Get-ChildItem -LiteralPath $renderStateDir -Filter *.json -File -ErrorAction SilentlyContinue).Count }
function Confirm-NormalRender($Result, [string] $Cost, [string] $Label) {
    $text = ConvertTo-PlainText ($Result.Lines -join "`n")
    Confirm-True ($Result.ExitCode -eq 0) "${Label}: exit code $($Result.ExitCode)"
    Confirm-True ($Result.Err.Count -eq 0) "${Label}: nothing on stderr, got '$($Result.Err -join ' | ')'"
    Confirm-Equal $text "$iconModel M $chevron $iconCost `$$Cost $chevron $iconHome main" "${Label}: normal line"
}
$iconModel = [char]::ConvertFromUtf32(0xF06A9)
$iconCost = [char]::ConvertFromUtf32(0xF0155)
$stateOffConfig = Write-TempConfig 'state-off.json' '{ "state": false }'

$r1 = Invoke-StatusLine (Get-StatePayloadJson 1.07) $null 0
$r2 = Invoke-StatusLine (Get-StatePayloadJson 1.07) $null 0
Confirm-NormalRender $r1 '1.07' 'state render first'
Confirm-NormalRender $r2 '1.07' 'state render second'
Confirm-Equal ($r2.Lines -join "`n") ($r1.Lines -join "`n") 'state render: both renders print the same bytes'
Confirm-Equal (Get-RenderStateFileCount) 1 'state render: two renders leave one file'
$file = Get-Content -LiteralPath (Join-Path $renderStateDir 'sess-1.json') -Raw | ConvertFrom-Json
Confirm-Equal $file.v 1 'state render: file is version 1'
Confirm-Equal $file.cost_usd 1.07 'state render: cost_usd matches the payload'
Confirm-Equal $file.history.Count 1 'state render: the same cost twice is one history entry'
Confirm-True ([math]::Abs($file.updated_at - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -lt 120) 'state render: updated_at is now'
$r3 = Invoke-StatusLine (Get-StatePayloadJson 1.5) $null 0
Confirm-NormalRender $r3 '1.50' 'state render third'
$file = Get-Content -LiteralPath (Join-Path $renderStateDir 'sess-1.json') -Raw | ConvertFrom-Json
Confirm-Equal $file.cost_usd 1.5 'state render: cost_usd follows the payload'
Confirm-Equal $file.history.Count 2 'state render: a new cost adds a history entry'
Confirm-Equal $file.history[1].cost_usd 1.5 'state render: newest history entry last'
Write-Host ("{0,-40} {1,5:N0} ms  {2}" -f 'state render', $r3.Ms, (ConvertTo-PlainText ($r3.Lines -join ' ')))

# A truncated or empty file is read as no state, the line is normal, and the file is replaced.
foreach ($case in @(@{ Name = 'truncated'; Text = '{ "v": 1, "cost' }, @{ Name = 'empty'; Text = '' })) {
    [System.IO.File]::WriteAllText((Join-Path $renderStateDir 'sess-1.json'), $case.Text)
    $r = Invoke-StatusLine (Get-StatePayloadJson 2) $null 0
    Confirm-NormalRender $r '2.00' "state $($case.Name) file"
    $file = try { Get-Content -LiteralPath (Join-Path $renderStateDir 'sess-1.json') -Raw | ConvertFrom-Json } catch { $null }
    Confirm-Equal $file.cost_usd 2 "state $($case.Name) file: replaced by a good one"
    Confirm-Equal $file.history.Count 1 "state $($case.Name) file: history starts over"
}

# "state": false and a payload without a session_id write nothing, not even the directory.
Remove-Item -LiteralPath $renderStateDir -Recurse -Force
$r = Invoke-StatusLine (Get-StatePayloadJson 1.07 'sess-off') $stateOffConfig 0
Confirm-NormalRender $r '1.07' 'state off'
Confirm-True (-not (Test-Path -LiteralPath $renderStateDir)) 'state off: no files, no directory'
$r = Invoke-StatusLine (Get-StatePayloadJson 1.07 '') $null 0
Confirm-NormalRender $r '1.07' 'state no session_id'
Confirm-True (-not (Test-Path -LiteralPath $renderStateDir)) 'state no session_id: no files, no directory'

# A directory that cannot be created (a file sits at its path) and one that cannot be written to.
[System.IO.File]::WriteAllText($renderStateDir, 'in the way')
$r = Invoke-StatusLine (Get-StatePayloadJson 1.07 'sess-blocked') $null 0
Confirm-NormalRender $r '1.07' 'state directory blocked by a file'
Remove-Item -LiteralPath $renderStateDir -Force
if ($IsWindows) {
    New-Item -ItemType Directory -Force $renderStateDir | Out-Null
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $deny = [System.Security.AccessControl.FileSystemAccessRule]::new($me, 'Write', 'ContainerInherit,ObjectInherit', 'None', 'Deny')
    $acl = Get-Acl -LiteralPath $renderStateDir
    $acl.AddAccessRule($deny)
    Set-Acl -LiteralPath $renderStateDir -AclObject $acl
    try {
        $r = Invoke-StatusLine (Get-StatePayloadJson 1.07 'sess-readonly') $null 0
        Confirm-NormalRender $r '1.07' 'state read-only directory'
        Confirm-Equal (Get-RenderStateFileCount) 0 'state read-only directory: nothing written'
    } finally {
        $acl = Get-Acl -LiteralPath $renderStateDir
        [void] $acl.RemoveAccessRule($deny)
        Set-Acl -LiteralPath $renderStateDir -AclObject $acl
    }
}
} finally {
    if ($null -ne $oldTemp) { $env:TEMP = $oldTemp } else { Remove-Item Env:TEMP -ErrorAction SilentlyContinue }
}

# ---- Install group: install.ps1 against a settings.json inside the temp tree ----
# USERPROFILE is pointed at a folder under $tmp for the child pwsh, so the installer's copy target
# (~/.claude/statusline.ps1) lands there, and -SettingsPath puts the settings file in the same tree. The
# installer run is the worktree's own install.ps1, so $PSScriptRoot in the child is still the worktree
# and the copy source is the real script. The real ~/.claude files are hashed before the group and
# compared after it: nothing here may write outside $tmp.
Write-Host '== install' -ForegroundColor Cyan
$installer = Join-Path $PSScriptRoot 'install.ps1'
$installHome = Join-Path $tmp 'install-home'
New-Item -ItemType Directory -Force $installHome | Out-Null
$realClaudeDir = Join-Path $env:USERPROFILE '.claude'
function Get-WriteStamp([string] $Path) { if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path).LastWriteTimeUtc }; return $null }
# Content, not a timestamp: another process touching the real file during the run would break a
# LastWriteTimeUtc comparison without the installer having written anything.
function Get-ContentHash([string] $Path) { if (Test-Path -LiteralPath $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }; return $null }
$realHash = [ordered]@{}
foreach ($name in @('settings.json', 'settings.json.bak', 'statusline.ps1', 'statusline.json')) { $realHash[$name] = Get-ContentHash (Join-Path $realClaudeDir $name) }
$oldUserProfile = $env:USERPROFILE
try {
$env:USERPROFILE = $installHome
# Runs install.ps1 in a child pwsh. Every call must carry -SettingsPath under $tmp; USERPROFILE is
# already redirected above, so the copy target and the uninstall delete land under $tmp as well.
function Invoke-Installer([string] $Name, [string[]] $Arguments) {
    $r = Invoke-ChildPwsh $installer $Arguments
    Write-Host ("{0,-40} {1,5:N0} ms  exit {2}" -f $Name, $r.Ms, $r.ExitCode)
    return $r
}
# $null for a missing or unparseable file, so an installer regression shows up as FAIL lines below
# instead of a terminating error that takes the rest of the suite with it.
function Read-SettingFile([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return $null }
}
function Get-KeyList($Object) {
    if ($null -eq $Object) { return '(no object)' }
    return (@($Object.PSObject.Properties.Name) -join ',')
}
$installedScript = Join-Path $installHome '.claude\statusline.ps1'
$installedConfig = Join-Path $installHome '.claude\statusline.json'
$expectCommand = 'pwsh -NoProfile -NoLogo -NonInteractive -File ' + ($installedScript -replace '\\', '/')

# A fresh file: neither settings.json nor its parent directory exists yet.
$fresh = Join-Path $installHome 'fresh\settings.json'
$r = Invoke-Installer 'install fresh' @('-SettingsPath', $fresh)
Confirm-True ($r.ExitCode -eq 0) "install fresh: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "install fresh: stderr empty, got '$($r.Err -join ' | ')'"
Confirm-True (Test-Path $fresh) 'install fresh: settings.json created'
Confirm-True (-not (Test-Path "$fresh.bak")) 'install fresh: no .bak when there was nothing to back up'
Confirm-True (Test-Path $installedScript) 'install fresh: statusline.ps1 copied into the temp home'
Confirm-True (Test-Path $installedConfig) 'install fresh: statusline.json copied into the temp home'
if (Test-Path $fresh) {
    $s = Read-SettingFile $fresh
    Confirm-Equal (Get-KeyList $s) 'statusLine' 'install fresh: statusLine is the only key'
    Confirm-Equal (Get-KeyList $s.statusLine) 'type,command,padding,hideVimModeIndicator' 'install fresh: statusLine has four keys in order'
    Confirm-Equal $s.statusLine.type 'command' 'install fresh: type'
    Confirm-Equal $s.statusLine.command $expectCommand 'install fresh: command points at the temp home with forward slashes'
    Confirm-Equal $s.statusLine.padding 0 'install fresh: padding'
    Confirm-True ($s.statusLine.hideVimModeIndicator -is [bool] -and $s.statusLine.hideVimModeIndicator) 'install fresh: hideVimModeIndicator is boolean true'
}

# An existing file with unrelated keys, including a top-level hideVimModeIndicator the installer must not touch.
$existingJson = '{ "theme": "dark", "permissions": { "allow": [ "Bash(git:*)" ] }, "hideVimModeIndicator": false }'
$existing = Write-TempConfig 'install-home\existing.json' $existingJson
$r = Invoke-Installer 'install existing -RefreshInterval 10' @('-SettingsPath', $existing, '-RefreshInterval', '10')
Confirm-True ($r.ExitCode -eq 0) "install existing: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "install existing: stderr empty, got '$($r.Err -join ' | ')'"
Confirm-True (Test-Path "$existing.bak") 'install existing: .bak written'
if (Test-Path "$existing.bak") { Confirm-Equal (Get-Content -LiteralPath "$existing.bak" -Raw) $existingJson 'install existing: .bak holds the previous content' }
$s = Read-SettingFile $existing
Confirm-Equal (Get-KeyList $s) 'theme,permissions,hideVimModeIndicator,statusLine' 'install existing: unrelated keys kept, statusLine appended'
Confirm-Equal $s.theme 'dark' 'install existing: theme kept'
Confirm-Equal ($s.permissions.allow -join ',') 'Bash(git:*)' 'install existing: nested permissions kept'
Confirm-True ($s.hideVimModeIndicator -is [bool] -and -not $s.hideVimModeIndicator) 'install existing: top-level hideVimModeIndicator left alone'
Confirm-Equal (Get-KeyList $s.statusLine) 'type,command,padding,hideVimModeIndicator,refreshInterval' 'install -RefreshInterval 10: five keys in order'
Confirm-Equal $s.statusLine.refreshInterval 10 'install -RefreshInterval 10: refreshInterval is 10'
Confirm-True ((Get-Content -LiteralPath $existing -Raw).Contains('"refreshInterval": 10')) 'install -RefreshInterval 10: written as a number, not a string'
Confirm-True ($s.statusLine.hideVimModeIndicator -is [bool] -and $s.statusLine.hideVimModeIndicator) 'install -RefreshInterval 10: hideVimModeIndicator is boolean true'

# A run without the switch writes no refreshInterval, even over an entry that had one, and says so. The
# child pwsh host prints warnings on stdout, so the warning is looked for in Lines, not Err.
$r = Invoke-Installer 'install existing, no switch' @('-SettingsPath', $existing)
Confirm-True ($r.ExitCode -eq 0) "install no switch: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "install no switch: stderr empty, got '$($r.Err -join ' | ')'"
Confirm-True (($r.Lines -join ' ') -match 'WARNING:.*refreshInterval of 10 is dropped') "install no switch: warning names the dropped value, got '$($r.Lines -join ' | ')'"
$s = Read-SettingFile $existing
Confirm-Equal (Get-KeyList $s.statusLine) 'type,command,padding,hideVimModeIndicator' 'install no switch: no refreshInterval key'
Confirm-Equal (Get-KeyList $s) 'theme,permissions,hideVimModeIndicator,statusLine' 'install no switch: unrelated keys still kept'

# A 0-byte settings file parses to $null; the installer must still end up with a real object.
$empty = Write-TempConfig 'install-home\empty.json' ''
$r = Invoke-Installer 'install empty file' @('-SettingsPath', $empty)
Confirm-True ($r.ExitCode -eq 0) "install empty: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "install empty: stderr empty, got '$($r.Err -join ' | ')'"
$s = Read-SettingFile $empty
Confirm-Equal (Get-KeyList $s) 'statusLine' 'install empty: statusLine is the only key'
Confirm-Equal (Get-KeyList $s.statusLine) 'type,command,padding,hideVimModeIndicator' 'install empty: statusLine has four keys in order'
Confirm-True ((Get-Content -LiteralPath $empty -Raw).Trim() -ne 'null') 'install empty: file is not the literal text null'

# A settings path with wildcard characters: -Path would read it as missing and drop the existing keys.
[void] [System.IO.Directory]::CreateDirectory((Join-Path $installHome 'a[b]'))
$wild = Write-TempConfig 'install-home\a[b]\settings.json' '{ "theme": "light" }'
$r = Invoke-Installer 'install wildcard path' @('-SettingsPath', $wild)
Confirm-True ($r.ExitCode -eq 0) "install wildcard: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "install wildcard: stderr empty, got '$($r.Err -join ' | ')'"
Confirm-True (Test-Path -LiteralPath "$wild.bak") 'install wildcard: .bak written'
$s = Read-SettingFile $wild
Confirm-Equal (Get-KeyList $s) 'theme,statusLine' 'install wildcard: unrelated key kept, statusLine appended'
Confirm-Equal $s.theme 'light' 'install wildcard: theme kept'
Confirm-Equal (Get-KeyList $s.statusLine) 'type,command,padding,hideVimModeIndicator' 'install wildcard: statusLine has four keys in order'
$r = Invoke-Installer 'uninstall wildcard path' @('-Uninstall', '-SettingsPath', $wild)
Confirm-True ($r.ExitCode -eq 0) "uninstall wildcard: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "uninstall wildcard: stderr empty, got '$($r.Err -join ' | ')'"
Confirm-Equal (Get-KeyList (Read-SettingFile $wild)) 'theme' 'uninstall wildcard: statusLine removed, theme kept'

# 0 and a negative value are refused by ValidateRange before anything is written: no settings rewrite,
# no new .bak, no copy.
Remove-Item -LiteralPath $installedScript -Force -ErrorAction SilentlyContinue
foreach ($bad in @('0', '-5')) {
    $label = "install -RefreshInterval $bad"
    $before = Get-Content -LiteralPath $existing -Raw
    $beforeStamp = Get-WriteStamp $existing
    $beforeBakStamp = Get-WriteStamp "$existing.bak"
    $r = Invoke-Installer $label @('-SettingsPath', $existing, '-RefreshInterval', $bad)
    Confirm-True ($r.ExitCode -ne 0) "${label}: exit code $($r.ExitCode) is non-zero"
    Confirm-True (($r.Err -join ' ') -match "parameter 'RefreshInterval'\. The $bad argument is less than the minimum allowed range of 1\.") "${label}: error names the parameter and the range, got '$($r.Err -join ' | ')'"
    Confirm-Equal (Get-Content -LiteralPath $existing -Raw) $before "${label}: settings.json content unchanged"
    Confirm-True ((Get-WriteStamp $existing) -eq $beforeStamp) "${label}: settings.json not rewritten"
    Confirm-True ((Get-WriteStamp "$existing.bak") -eq $beforeBakStamp) "${label}: .bak not rewritten"
    Confirm-True (-not (Test-Path $installedScript)) "${label}: statusline.ps1 not copied"
}

# Uninstall removes the whole statusLine object, both keys with it, and names them; everything else stays.
# The uninstall cases run only if the install before them put statusline.ps1 in the temp home: that is the
# proof the USERPROFILE seam holds, and -Uninstall deletes ~/.claude/statusline.ps1 wherever ~ points.
$r = Invoke-Installer 'install existing -RefreshInterval 7' @('-SettingsPath', $existing, '-RefreshInterval', '7')
Confirm-True ($r.ExitCode -eq 0) "install before uninstall: exit code $($r.ExitCode)"
$seamHolds = Test-Path -LiteralPath $installedScript
Confirm-True $seamHolds 'install before uninstall: statusline.ps1 is in the temp home (uninstall cases skipped otherwise)'
if ($seamHolds) {
    $r = Invoke-Installer 'uninstall' @('-Uninstall', '-SettingsPath', $existing)
    Confirm-True ($r.ExitCode -eq 0) "uninstall: exit code $($r.ExitCode)"
    Confirm-True ($r.Err.Count -eq 0) "uninstall: stderr empty, got '$($r.Err -join ' | ')'"
    $s = Read-SettingFile $existing
    Confirm-Equal (Get-KeyList $s) 'theme,permissions,hideVimModeIndicator' 'uninstall: statusLine removed, unrelated keys kept'
    Confirm-True ($s.hideVimModeIndicator -is [bool] -and -not $s.hideVimModeIndicator) 'uninstall: top-level hideVimModeIndicator left alone'
    Confirm-True (-not (Test-Path -LiteralPath $installedScript)) 'uninstall: statusline.ps1 deleted from the temp home'
    Confirm-True (Test-Path -LiteralPath $installedConfig) 'uninstall: statusline.json kept'
    $bak = Read-SettingFile "$existing.bak"
    Confirm-Equal (Get-KeyList $bak.statusLine) 'type,command,padding,hideVimModeIndicator,refreshInterval' 'uninstall: .bak holds the entry that was removed'
    $text = $r.Lines -join "`n"
    Confirm-True ($text.Contains('hideVimModeIndicator') -and $text.Contains('refreshInterval')) "uninstall: message names both keys, got '$text'"
    # The state files live outside ~/.claude, so the uninstaller has to say where they are; it never
    # deletes them itself.
    Confirm-True ($text.Contains('claude-statusline-state')) "uninstall: message names the state directory, got '$text'"
    Confirm-True ($text -match 'Session state files are in .+claude-statusline-state') "uninstall: message gives the state directory path, got '$text'"

    # A second uninstall has nothing to remove and leaves the file as it is.
    $before = Get-Content -LiteralPath $existing -Raw
    $beforeStamp = Get-WriteStamp $existing
    $r = Invoke-Installer 'uninstall again' @('-Uninstall', '-SettingsPath', $existing)
    Confirm-True ($r.ExitCode -eq 0) "uninstall again: exit code $($r.ExitCode)"
    Confirm-True ($r.Err.Count -eq 0) "uninstall again: stderr empty, got '$($r.Err -join ' | ')'"
    Confirm-Equal (Get-Content -LiteralPath $existing -Raw) $before 'uninstall again: settings.json content unchanged'
    Confirm-True ((Get-WriteStamp $existing) -eq $beforeStamp) 'uninstall again: settings.json not rewritten'
}
} finally {
    $env:USERPROFILE = $oldUserProfile
}
foreach ($name in $realHash.Keys) {
    $p = Join-Path $realClaudeDir $name
    Confirm-True ((Get-ContentHash $p) -eq $realHash[$name]) "install: real $p untouched"
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
# be pointed at a real repository). A sample that also carries workspace.project_dir with current_dir at
# or below it keeps that shape: the probe stands in for the project root and current_dir keeps its path
# under it, so the folder segment still sees the same session. The two paths are compared the way
# Get-FolderSegment compares them (slashes to backslashes, trailing separators trimmed, case ignored),
# and the root has to end at a separator, so `C:\src\demo2` is not under `C:\src\demo`. When current_dir
# is not under project_dir the root is current_dir itself and project_dir is left alone. The rewrite is
# in memory, for every config including a user-supplied -Config; the sample files never change.
function Convert-ToHermeticPayload([string] $Path) {
    $text = Get-Content -LiteralPath $Path -Raw
    $json = $text | ConvertFrom-Json
    if ($null -ne $json.git) { return $text }
    $dir = [string] $json.workspace.current_dir
    if (-not $dir) { return $text }
    $here = ($dir -replace '/', '\').TrimEnd('\')
    $there = (([string] $json.workspace.project_dir) -replace '/', '\').TrimEnd('\')
    $underRoot = $there -and ($here -eq $there -or $here.StartsWith("$there\", [System.StringComparison]::OrdinalIgnoreCase))
    if (-not $underRoot) { $there = $here }
    $probeRoot = Join-Path (Join-Path $tmp 'probe') (Split-Path $there -Leaf)
    $below = $here.Substring($there.Length).TrimStart('\')
    $probe = if ($below) { Join-Path $probeRoot $below } else { $probeRoot }
    if ($underRoot) { $json.workspace.project_dir = $probeRoot }
    New-Item -ItemType Directory -Force $probe | Out-Null
    $json.workspace.current_dir = $probe
    return ($json | ConvertTo-Json -Depth 20 -Compress)
}
$samplePayloads = @{}
foreach ($sample in $sampleFiles) { $samplePayloads[$sample.Name] = Convert-ToHermeticPayload $sample.FullName }
$iconCost = [char]::ConvertFromUtf32(0xF0155)
$iconLines = [char]::ConvertFromUtf32(0xF121)
$iconFast = [char]::ConvertFromUtf32(0xF0E7)
$iconThink = [char]::ConvertFromUtf32(0xF09D0)
$iconEffort = [char]::ConvertFromUtf32(0xF04C5)
$iconVim = [char]::ConvertFromUtf32(0xE62B)
$minus = [char]::ConvertFromUtf32(0x2212)
# Glyphs a sample must NOT show when every segment is enabled. This is the variant coverage the markers
# below cannot give, because a marker can only say that something rendered: a clean tree carries no
# pencil, a feature branch no home icon, a payload without rate limits no tachometer, and 07's badges
# are all off or at the default level. Rows that only said "this glyph is present" are gone - the
# per-segment markers assert that, by value, for every visible segment. The warning glyph is the
# branch segment's conflict mark and the model segment's past-200k mark; only 09 sets
# exceeds_200k_tokens, so the other samples must not show it on the model row.
$absentGlyphs = @{
    '01-main-clean.json'                    = @(
        @{ Icon = $iconDirty; Name = 'pencil' }
        @{ Icon = $iconLines; Name = 'lines' }
        @{ Icon = $iconLimit; Name = 'limits' }
        @{ Icon = $iconBranch; Name = 'branch' }
        @{ Icon = $iconConflict; Name = 'warn' }
        @{ Icon = $iconPr; Name = 'pr' }
    )
    '02-feature-dirty-high.json'            = @(
        @{ Icon = $iconHome; Name = 'home' }
        @{ Icon = $iconLines; Name = 'lines' }
        @{ Icon = $iconLimit; Name = 'limits' }
        @{ Icon = $iconConflict; Name = 'warn' }
    )
    '03-main-dirty-mid.json'                = @(
        @{ Icon = $iconLines; Name = 'lines' }
        @{ Icon = $iconLimit; Name = 'limits' }
        @{ Icon = $iconConflict; Name = 'warn' }
    )
    '04-minimal.json'                       = @(
        @{ Icon = $iconCtx; Name = 'context' }
        @{ Icon = $iconFolder; Name = 'folder' }
        @{ Icon = $iconConflict; Name = 'warn' }
    )
    '05-no-git.json'                        = @(
        @{ Icon = $iconHome; Name = 'home' }
        @{ Icon = $iconBranch; Name = 'branch' }
        @{ Icon = $iconCost; Name = 'cost' }
        @{ Icon = $iconConflict; Name = 'warn' }
    )
    '06-limits-badges-lines.json'           = @(
        @{ Icon = $iconDirty; Name = 'pencil' }
        @{ Icon = $iconConflict; Name = 'warn' }
    )
    '07-limits-expired-default-effort.json' = @(
        @{ Icon = $iconFast; Name = 'fast' }
        @{ Icon = $iconThink; Name = 'think' }
        @{ Icon = $iconEffort; Name = 'effort' }
        @{ Icon = $iconVim; Name = 'vim' }
        @{ Icon = $iconHome; Name = 'home' }
        @{ Icon = $iconBranch; Name = 'branch' }
        @{ Icon = $iconConflict; Name = 'warn' }
    )
    '09-1m-context.json'                    = @(
        @{ Icon = $iconDirty; Name = 'pencil' }
        @{ Icon = $iconLines; Name = 'lines' }
        @{ Icon = $iconLimit; Name = 'limits' }
        @{ Icon = $iconBranch; Name = 'branch' }
    )
    '08-repo-identity.json'                 = @(
        @{ Icon = $iconHome; Name = 'home' }
        @{ Icon = $iconBranch; Name = 'branch' }
        @{ Icon = $iconLines; Name = 'lines' }
        @{ Icon = $iconLimit; Name = 'limits' }
        @{ Icon = $iconPr; Name = 'pr' }
    )
    '10-pr.json'                            = @(
        @{ Icon = $iconHome; Name = 'home' }
        @{ Icon = $iconDirty; Name = 'pencil' }
        @{ Icon = $iconLines; Name = 'lines' }
        @{ Icon = $iconLimit; Name = 'limits' }
        @{ Icon = $iconConflict; Name = 'warn' }
    )
}
# What each sample renders when every segment is enabled and nothing is fitted away: 04 carries nothing
# but a model, 05, 07 and 08 have no git object and their probe directory is not a repository, and 07's
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
    '08-repo-identity.json'                 = @('model', 'context', 'cost', 'folder')
    '09-1m-context.json'                    = @('model', 'context', 'cost', 'folder', 'branch')
    '10-pr.json'                            = @('model', 'context', 'cost', 'pr', 'folder', 'branch')
}
# One marker per segment per sample: the segment's glyph plus the value this payload gives it, spelled
# the way it reaches the line once the escapes are stripped. Every visible segment has to put its marker
# on its own row, so a segment that stops rendering fails by name rather than slipping past the absence
# table, which only names a few glyphs per sample. Money is formatted the way the script formats it so
# the check survives a culture that writes 12,50. Markers stop short of anything that moves: 06's limits
# segment carries a countdown to a 2100 reset, so its marker ends at the percentage. Badges and branch
# have no single glyph of their own, so their markers are the whole segment text. A marker that depends
# on the config's folder mode is a hashtable keyed by mode, repo and leaf.
# Samples with a segment whose Short form differs from its Text, with the icon that proves the segment
# is on the line at all. Checked at every set width in the matrix. A folder entry is checked in repo
# mode only, because the segment has no Short form in leaf mode. The limits Short form keeps the figure
# that drives the colour, the 5h one in 07. 06 would show its 7d figure, but its line with every badge
# on runs past 120 columns, and its five_hour resets in 2100, which puts a drifting countdown in the
# full text (the $sampleMarkers note above stops its marker short of it), so it cannot meet the two-form
# rule below and stays out of this table. The one-off check after that rule covers it instead.
$sampleShortForms = @{
    '02-feature-dirty-high.json'            = @{
        branch = @{ Icon = $iconBranch; Full = "$iconBranch feature/x ~2 ?1 $iconDirty"; Short = "$iconBranch feature/x $iconDirty" }
    }
    '07-limits-expired-default-effort.json' = @{
        limits = @{ Icon = $iconLimit; Full = "$iconLimit 5h 61% 7d 12% `$ 44%"; Short = "$iconLimit 5h 61%" }
    }
    '08-repo-identity.json'                 = @{
        folder = @{ Icon = $iconFolder; Full = "$iconFolder octo/demo $iconChevron tools"; Short = "$iconFolder demo" }
    }
}

$sampleMarkers = @{
    '01-main-clean.json'                    = @{
        model  = "$iconModel Fable 5.1"; context = "$iconCtx 8%"; cost = "$iconCost `$$('{0:N2}' -f 0.4312)"
        folder = "$iconFolder my-project"; branch = "$iconHome main"
    }
    '02-feature-dirty-high.json'            = @{
        model  = "$iconModel Fable 5.1 1M"; context = "$iconCtx 90%"; cost = "$iconCost `$$('{0:N2}' -f 12.5)"
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
        lines  = "$iconLines +156 ${minus}23"; limits = "$iconLimit 5h 24%"
        badges = "$iconFast $iconThink $iconEffort xhigh $iconVim NORMAL"
        folder = "$iconFolder my-project"; branch = "$iconHome main"
    }
    '07-limits-expired-default-effort.json' = @{
        model = "$iconModel Opus 5"; context = "$iconCtx 5%"; cost = "$iconCost `$$('{0:N2}' -f 0.02)"
        lines = "$iconLines +0 ${minus}4"; limits = "$iconLimit 5h 61% 7d 12% `$ 44%"
        folder = "$iconFolder repo"
    }
    '08-repo-identity.json'                 = @{
        model = "$iconModel Fable 5.1"; context = "$iconCtx 12%"; cost = "$iconCost `$$('{0:N2}' -f 0.88)"
        folder = @{ repo = "$iconFolder octo/demo $iconChevron tools"; leaf = "$iconFolder tools" }
    }
    '09-1m-context.json'                    = @{
        model  = "$iconModel Fable 5.1 1M $iconConflict"; context = "$iconCtx 65%"; cost = "$iconCost `$$('{0:N2}' -f 4.21)"
        folder = "$iconFolder my-project"; branch = "$iconHome main"
    }
    '10-pr.json'                            = @{
        model  = "$iconModel Fable 5.1"; context = "$iconCtx 8%"; cost = "$iconCost `$$('{0:N2}' -f 0.4312)"
        pr     = "$iconPr #12"; folder = "$iconFolder my-project"; branch = "$iconBranch feature/x"
    }
}
# Every glyph a segment can put on the line: a segment the config turns off must show none of them, and
# the two-line checks use them to say which row a segment landed on.
$segmentGlyphs = @{
    model   = @($iconModel, $iconConflict)
    context = @($iconCtx)
    cost    = @($iconCost)
    lines   = @($iconLines)
    limits  = @($iconLimit)
    badges  = @($iconFast, $iconThink, $iconEffort, $iconVim)
    pr      = @($iconPr)
    folder  = @($iconFolder)
    branch  = @($iconHome, $iconBranch, $iconDirty, $iconAhead, $iconBehind, $iconConflict)
}
# The segment behind each row of the absence table, so a row can be skipped when its segment is off
# (the per-segment absence assertions cover that case instead, for every glyph the segment owns).
$glyphSegment = @{
    context = 'context'; cost = 'cost'; folder = 'folder'; lines = 'lines'; limits = 'limits'; warn = 'model'
    home = 'branch'; pencil = 'branch'; branch = 'branch'; pr = 'pr'
    fast = 'badges'; think = 'badges'; effort = 'badges'; vim = 'badges'
}
# statusline.ps1's own line sets, derived from the registry so the test knows which segments share a line.
$layoutRows = @{
    one = @(, $allSegments)
    two = @((Get-SegmentOrder 'RowRank' 1), (Get-SegmentOrder 'RowRank' 2))
}
# The oracle turns off every registry segment but model, so a new segment is off here without an edit.
$modelOnlySegments = @($allSegments | Where-Object { $_ -ne 'model' } | ForEach-Object { '"' + $_ + '": false' }) -join ', '
$modelOnlyPath = @{}
foreach ($style in @('plain', 'powerline')) {
    $modelOnlyPath[$style] = Write-TempConfig "model-only-$style.json" ('{ "layout": "one", "style": "' + $style + '", "segments": { ' + $modelOnlySegments + ' } }')
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
    $configSet.Add(@{ Name = (Split-Path $resolved -Leaf); Path = $resolved; Layout = $parsed.Layout; Style = $parsed.Style; Folder = $parsed.Folder; Enabled = $parsed.Segments })
} else {
    foreach ($layout in @('one', 'two')) {
        foreach ($style in @('plain', 'powerline')) {
            $path = Write-TempConfig "$layout-$style.json" ('{ "layout": "' + $layout + '", "style": "' + $style + '" }')
            $parsed = Read-StatusConfig $path
            $configSet.Add(@{ Name = "$layout-$style"; Path = $path; Layout = $layout; Style = $style; Folder = $parsed.Folder; Enabled = $parsed.Segments })
        }
    }
    # Leaf mode through the whole script, so the registry's wiring of the config into Get-FolderSegment
    # is covered by a real render and not only by the unit call.
    $path = Write-TempConfig 'folder-leaf.json' '{ "folder": "leaf" }'
    $parsed = Read-StatusConfig $path
    $configSet.Add(@{ Name = 'folder-leaf'; Path = $path; Layout = $parsed.Layout; Style = $parsed.Style; Folder = $parsed.Folder; Enabled = $parsed.Segments })
}

# No sample carries a session_id, so no render in the matrix may write state. The child renders get a
# TEMP of their own here, and it has to be empty when the matrix is done.
$oldTemp = $env:TEMP
$matrixTemp = Join-Path $tmp 'temp-matrix'
New-Item -ItemType Directory -Force $matrixTemp | Out-Null
$env:TEMP = $matrixTemp
try {
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
            if ($c -gt 0 -and $sampleShortForms.ContainsKey($sample.Name)) {
                # At a set width a segment with a Short form is one of two whole forms or gone: the full
                # text, the Short form, or dropped outright. A half-shed segment, or the full form at a
                # width it cannot fit, is what this catches; the content checks below run only for the
                # unset width.
                $text = ConvertTo-PlainText ($lines -join "`n")
                foreach ($entry in $sampleShortForms[$sample.Name].GetEnumerator()) {
                    if (-not $cfg.Enabled[$entry.Key]) { continue }
                    if ($entry.Key -eq 'folder' -and $cfg.Folder -eq 'leaf') { continue }
                    $forms = $entry.Value
                    $full = $text.Contains($forms.Full)
                    $short = -not $full -and $text.Contains($forms.Short)
                    $dropped = -not $text.Contains($forms.Icon)
                    Confirm-True ($full -or $short -or $dropped) "${label}: $($entry.Key) is the full form, the short form, or dropped"
                    if ($c -ge 120) { Confirm-True $full "${label}: $($entry.Key) shows its full form at $c columns" }
                }
            }
            if ($c -gt 0 -and $sample.Name -eq '06-limits-badges-lines.json' -and $cfg.Enabled['limits']) {
                # Issue #34's case: 06 is red from its 7d figure, 88 against a 5h of 24. Wherever the limits
                # icon survives fitting, the 7d figure has to be on the line, and the 5h figure may only
                # stand beside it, in the full form. A Short form built from the 5h figure alone, which is
                # what the segment used to do, shows 5h 24% on a red segment with the red figure shed.
                $text = ConvertTo-PlainText ($lines -join "`n")
                if ($text.Contains($iconLimit)) {
                    Confirm-True ($text.Contains('7d 88%')) "${label}: limits keeps the 7d figure that drives its colour"
                    Confirm-True (-not $text.Contains('5h 24%') -or $text.Contains('7d 88%')) "${label}: the 5h figure appears only beside the 7d one"
                }
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
                        # A glyph an enabled segment also lists (the warning triangle belongs to both
                        # model and branch) cannot prove the off segment rendered, so it is skipped.
                        $shared = @($allSegments | Where-Object { $_ -ne $name -and $cfg.Enabled[$_] } | ForEach-Object { $segmentGlyphs[$_] })
                        $seen = @($segmentGlyphs[$name] | Where-Object { $_ -notin $shared -and $text.Contains($_) })
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
                                if ($marker -is [hashtable]) { $marker = $marker[$cfg.Folder] }
                                if (-not $marker) { Confirm-True $false "${label}: no marker for $name in the marker table"; continue }
                                Confirm-True ($rowText.Contains($marker)) "${label}: line $($ri + 1) shows $name as '$marker'"
                            }
                            $other = @($visible | Where-Object { $_ -notin $mine })
                            if ($other.Count -gt 0) {
                                # Same one-owner rule as the absence check: a glyph a segment on this row
                                # also lists says nothing about the segments that belong elsewhere.
                                $mineGlyphs = @($mine | ForEach-Object { $segmentGlyphs[$_] })
                                $strayed = @($other | Where-Object { @($segmentGlyphs[$_] | Where-Object { $_ -notin $mineGlyphs -and $rowText.Contains($_) }).Count -gt 0 })
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
Confirm-True (@(Get-ChildItem -LiteralPath $matrixTemp -Recurse -Force -File).Count -eq 0) 'render matrix: no state written for payloads without a session_id'
} finally {
    if ($null -ne $oldTemp) { $env:TEMP = $oldTemp } else { Remove-Item Env:TEMP -ErrorAction SilentlyContinue }
}
} finally {
    if ($null -ne $oldGitCeiling) { $env:GIT_CEILING_DIRECTORIES = $oldGitCeiling } else { Remove-Item Env:GIT_CEILING_DIRECTORIES -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "passed $script:passed, failed $script:failed" -ForegroundColor $(if ($script:failed -gt 0) { 'Red' } else { 'Green' })
if ($script:failed -gt 0) { exit 1 }
