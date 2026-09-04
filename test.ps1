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
# The escapes a rendered line can carry and a terminal does not show: an OSC 8 hyperlink wrapper with
# either terminator (ESC \ or BEL), or an SGR colour code. The one pattern behind ConvertTo-PlainText
# and Measure-VisibleWidth, so the two cannot drift apart.
$ansiPattern = "$esc\]8;[^\a$esc]*(?:\a|$esc\\)|$esc\[[0-9;]*m"
$script:passed = 0
$script:failed = 0

# A note about string comparison, because this file learned it twice.
#
# PowerShell's string operators compare by CULTURE, and a culture comparison gives the Unicode Format
# characters no collation weight at all. "oc<U+202E>to" -ceq "octo" is $true; so is a comparison against
# a string carrying a zero-width joiner or a byte order mark. -ceq and -cne are case-sensitive, which is
# not the same thing as ordinal, and the c is easy to read as "exact".
#
# So every comparison in this file falls into one of two categories, and a new one has to be put in the
# right one deliberately:
#
#   Rendered or payload-derived text - a status line, a panel row, a branch or worktree name, a repo
#   owner, anything that came out of a payload or went onto a terminal. These MUST compare ordinally,
#   with [string]::Equals(a, b, [System.StringComparison]::Ordinal). A format character in one of these
#   is the bug the check is there to find, and -ceq cannot see it. Confirm-Equal does this for every
#   caller; the two places that compare outside Confirm-Equal - the worktree name table and the
#   model-only fallback oracle - each say so at the call.
#
#   Hash and stamp values - Get-StateFileName results, git stamp strings. These are hex digits and
#   digits produced by this project's own code, where no format character can occur, so raw -ceq/-cne
#   is safe and is left alone; one of them is deliberately testing a difference of case.
#
# Ordinal, not -ceq, for the reason above: every check in this file that pins a rendered string would
# otherwise have said nothing about a right-to-left override sitting in the middle of it, which is
# exactly the thing those checks exist to catch.
function Confirm-Equal($Actual, $Expected, [string] $Label) {
    if ([string]::Equals("$Actual", "$Expected", [System.StringComparison]::Ordinal)) { $script:passed++; return }
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

# Strips the OSC 8 hyperlink wrappers and the SGR colour codes, so a marker check searches the text a
# terminal would show and a URL can never satisfy or spoil one.
function ConvertTo-PlainText([string] $Text) { $Text -replace $ansiPattern, '' }

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
    $plain = [regex]::Replace($Text, $ansiPattern, '')
    $width = 0
    $en = [System.Globalization.StringInfo]::GetTextElementEnumerator($plain)
    while ($en.MoveNext()) {
        $el = [string] $en.Current
        $cp = try { [char]::ConvertToUtf32($el, 0) } catch { 0x3F }
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($cp)
        $zero = $cat -eq [System.Globalization.UnicodeCategory]::NonSpacingMark -or
                $cat -eq [System.Globalization.UnicodeCategory]::SpacingCombiningMark -or
                $cat -eq [System.Globalization.UnicodeCategory]::EnclosingMark -or
                $cat -eq [System.Globalization.UnicodeCategory]::Format -or $cp -eq 0xFE0F
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
. (Import-ScriptFunction $script @('Get-VisibleWidth', 'Get-IconDefault', 'Get-IconRefusedCategory', 'Read-CodePoint', 'Get-IconSet', 'Read-SegmentNameList', 'Get-DefaultStatusConfig', 'Get-StatusConfigKey', 'Get-ConfigPreset', 'Get-ProjectConfigLimit', 'Get-BoundedFileDelegate', 'Get-BoundedStreamDelegate', 'Read-BoundedFileText', 'Merge-StatusConfigFile', 'Read-StatusConfig', 'Get-Palette', 'Format-Inline', 'Format-Line', 'Get-FittedLine', 'Read-PorcelainStatus', 'Get-GitBranch', 'G', 'K', 'Get-ThresholdRole', 'Get-WholePercent', 'Test-WideWindow', 'Test-AlarmLevel', 'Test-AlarmState', 'Get-ModelSegment', 'Test-QuietValue', 'Get-CacheShare', 'Get-ContextSegment', 'Get-CostSegment', 'Get-PayloadNumber', 'Format-PayloadText', 'Test-PayloadText', 'Test-PayloadDirty', 'Get-PayloadCount', 'Read-PayloadStatus', 'Get-WorktreeName', 'Get-BranchSegment', 'Get-FolderSegment', 'Get-SegmentRegistry', 'Get-SegmentOrder', 'TimeLeft', 'Get-LimitsSegment', 'Format-Link', 'Get-PrSegment', 'Get-FiniteNumber', 'Get-SessionStateDir', 'Get-SessionStatePath', 'Get-StateNumber', 'Read-SessionState', 'Merge-SessionState', 'Write-SessionState', 'Invoke-SessionStateSweep', 'Get-DefaultGitConfig', 'Get-ConfigInteger', 'Get-GitRepoRoot', 'Get-CachedGitBranch', 'Get-ShortHash', 'Write-AtomicJson', 'Get-GitStamp', 'Read-CachedRecord', 'Get-GitCacheDir', 'Get-PaceArrow', 'Write-StatusDiag', 'Invoke-StatusDiagRollover'))

# Get-BranchSegment, Get-FolderSegment, Get-LimitsSegment, Get-ModelSegment and Get-PrSegment close over
# these script-level names in statusline.ps1, so the test has to supply them. The git timeout is not
# one of them any more - the segment reads it from the config - so this is only the test's own
# shorthand for the direct Get-GitBranch calls below, pinned to the script's default.
$gitTimeoutMs = (Get-DefaultGitConfig).TimeoutMs
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
$iconWorktree = [char]::ConvertFromUtf32(0xF04C1)

# A payload with one top-level key whose value is the given JSON. It goes through ConvertFrom-Json so
# a null is a real null property, the way Claude Code sends it, and counts arrive as Int64, the way
# they do from a real payload; a hashtable would not give either.
function Get-JsonPayload([string] $Key, [string] $Json) {
    return ('{"' + $Key + '":' + $Json + '}') | ConvertFrom-Json
}

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
    @{ Text = "$iconWorktree wt-review"; Width = 11 }                                  # the worktree fork is one cell wide
    @{ Text = "$esc]8;;https://example.com/pull/12$esc\abc$esc]8;;$esc\"; Width = 3 } # OSC 8 link: the URL is not visible
    @{ Text = "$esc]8;;https://example.com$esc\$esc[32mab$esc[0m$esc]8;;$esc\"; Width = 2 }  # link around coloured text
    @{ Text = "$esc]8;;$esc\"; Width = 0 }                                              # a bare link terminator
    @{ Text = "$esc]8;;https://example.com`aabcd$esc]8;;`a"; Width = 4 }               # BEL-terminated link
    @{ Text = [string][char]0x202E; Width = 0 }                                        # right-to-left override
    @{ Text = 'ab' + [string][char]0x2066 + 'cd'; Width = 4 }                          # directional isolate
    @{ Text = [string][char]0xFEFF + 'ab'; Width = 2 }                                 # byte order mark
    @{ Text = 'a' + [string][char]0x00AD + 'b'; Width = 2 }                            # soft hyphen
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

# The git object: timeoutMs and cacheSeconds are whole numbers clamped to their ranges, cache is a
# boolean. A key of the wrong type falls back on its own; a git value that is not an object falls
# back for all three. The defaults come from Get-DefaultGitConfig, so the two cannot drift apart.
$gitDefaults = Get-DefaultGitConfig
Confirm-Equal $gitDefaults.TimeoutMs 1500 'git defaults: timeout 1500'
Confirm-Equal $gitDefaults.CacheSeconds 5 'git defaults: cache 5 seconds'
Confirm-Equal $gitDefaults.Cache $true 'git defaults: cache on'
Confirm-True (-not [object]::ReferenceEquals((Get-DefaultGitConfig), (Get-DefaultGitConfig))) 'git defaults: a fresh table each call'
$c = Read-StatusConfig (Join-Path $tmp 'does-not-exist.json')
Confirm-Equal $c.Git.TimeoutMs 1500 'config missing: git timeout 1500'
Confirm-Equal $c.Git.CacheSeconds 5 'config missing: git cache 5 seconds'
Confirm-Equal $c.Git.Cache $true 'config missing: git cache on'
$c = Read-StatusConfig (Write-TempConfig 'git-absent.json' '{ "layout": "two" }')
Confirm-Equal $c.Git.TimeoutMs 1500 'config git absent: timeout default'
Confirm-Equal $c.Git.CacheSeconds 5 'config git absent: cache seconds default'
Confirm-Equal $c.Git.Cache $true 'config git absent: cache on'
$c = Read-StatusConfig (Write-TempConfig 'git-valid.json' '{ "git": { "timeoutMs": 3000, "cacheSeconds": 10, "cache": false } }')
Confirm-Equal $c.Git.TimeoutMs 3000 'config git valid: timeout'
Confirm-Equal $c.Git.CacheSeconds 10 'config git valid: cache seconds'
Confirm-Equal $c.Git.Cache $false 'config git valid: cache off'
Confirm-True ($c.Git.TimeoutMs -is [int] -and $c.Git.CacheSeconds -is [int]) 'config git valid: the integers are Int32, not the Int64 ConvertFrom-Json gives'
$c = Read-StatusConfig (Write-TempConfig 'git-edges.json' '{ "git": { "timeoutMs": 100, "cacheSeconds": 300 } }')
Confirm-Equal $c.Git.TimeoutMs 100 'config git timeout 100: the lower bound is allowed'
Confirm-Equal $c.Git.CacheSeconds 300 'config git cache seconds 300: the upper bound is allowed'
$c = Read-StatusConfig (Write-TempConfig 'git-wrong-types.json' '{ "git": { "timeoutMs": "3000", "cacheSeconds": 2.5, "cache": "yes" } }')
Confirm-Equal $c.Git.TimeoutMs 1500 'config git string timeout: falls back to 1500'
Confirm-Equal $c.Git.CacheSeconds 5 'config git fractional cache seconds: falls back to 5'
Confirm-Equal $c.Git.Cache $true 'config git string cache: falls back to on'
$c = Read-StatusConfig (Write-TempConfig 'git-whole-doubles.json' '{ "git": { "timeoutMs": 3000.0, "cacheSeconds": 1e1 } }')
Confirm-Equal $c.Git.TimeoutMs 3000 'config git timeout 3000.0: a whole double is taken'
Confirm-Equal $c.Git.CacheSeconds 10 'config git cache seconds 1e1: exponent form of a whole number is taken'
Confirm-True ($c.Git.TimeoutMs -is [int] -and $c.Git.CacheSeconds -is [int]) 'config git whole doubles: stored as Int32'
Confirm-Equal (Get-ConfigInteger 1e300 7 0 300) 300 'config integer: a whole double beyond Int32 clamps'
Confirm-Equal (Get-ConfigInteger ([double]::NaN) 7 0 300) 7 'config integer: NaN falls back'
Confirm-Equal (Get-ConfigInteger 2.000001 7 0 300) 7 'config integer: a near-whole double falls back'
$c = Read-StatusConfig (Write-TempConfig 'git-bool-number.json' '{ "git": { "timeoutMs": true, "cacheSeconds": null, "cache": 1 } }')
Confirm-Equal $c.Git.TimeoutMs 1500 'config git boolean timeout: falls back to 1500'
Confirm-Equal $c.Git.CacheSeconds 5 'config git null cache seconds: falls back to 5'
Confirm-Equal $c.Git.Cache $true 'config git numeric cache: falls back to on'
$c = Read-StatusConfig (Write-TempConfig 'git-low.json' '{ "git": { "timeoutMs": 50, "cacheSeconds": -1 } }')
Confirm-Equal $c.Git.TimeoutMs 100 'config git timeout 50: clamped to 100'
Confirm-Equal $c.Git.CacheSeconds 0 'config git cache seconds -1: clamped to 0'
$c = Read-StatusConfig (Write-TempConfig 'git-high.json' '{ "git": { "timeoutMs": 99999, "cacheSeconds": 999 } }')
Confirm-Equal $c.Git.TimeoutMs 10000 'config git timeout 99999: clamped to 10000'
Confirm-Equal $c.Git.CacheSeconds 300 'config git cache seconds 999: clamped to 300'
$c = Read-StatusConfig (Write-TempConfig 'git-huge.json' '{ "git": { "timeoutMs": 99999999999, "cacheSeconds": -99999999999 } }')
Confirm-Equal $c.Git.TimeoutMs 10000 'config git timeout beyond Int32: clamped to 10000'
Confirm-Equal $c.Git.CacheSeconds 0 'config git cache seconds below Int32: clamped to 0'
$c = Read-StatusConfig (Write-TempConfig 'git-zero.json' '{ "git": { "cacheSeconds": 0 } }')
Confirm-Equal $c.Git.CacheSeconds 0 'config git cache seconds 0: kept, which disables the cache'
Confirm-Equal $c.Git.TimeoutMs 1500 'config git cache seconds 0: timeout untouched'
Confirm-Equal $c.Git.Cache $true 'config git cache seconds 0: cache flag untouched'
foreach ($case in @(@{ Name = 'array'; Json = '{ "git": [1500] }' }, @{ Name = 'number'; Json = '{ "git": 1500 }' },
                    @{ Name = 'string'; Json = '{ "git": "fast" }' }, @{ Name = 'null'; Json = '{ "git": null }' })) {
    $c = Read-StatusConfig (Write-TempConfig "git-$($case.Name).json" $case.Json)
    Confirm-Equal $c.Git.TimeoutMs 1500 "config git $($case.Name): timeout default"
    Confirm-Equal $c.Git.CacheSeconds 5 "config git $($case.Name): cache seconds default"
    Confirm-Equal $c.Git.Cache $true "config git $($case.Name): cache on"
}
# The git object does not touch the other keys, and the other keys do not touch it.
$c = Read-StatusConfig (Write-TempConfig 'git-beside.json' '{ "layout": "two", "state": false, "git": { "timeoutMs": 200 } }')
Confirm-Equal $c.Layout 'two' 'config git beside layout: layout kept'
Confirm-Equal $c.State $false 'config git beside state: state kept'
Confirm-Equal $c.Git.TimeoutMs 200 'config git beside others: timeout read'

# The quiet block: the smallest value cost, context and limits are worth building at. Compared with -eq
# rather than through Confirm-Equal, because a threshold is a double and its ToString is culture-bound.
$c = Read-StatusConfig (Join-Path $tmp 'does-not-exist.json')
Confirm-True ($c.Quiet.cost -eq 0 -and $c.Quiet.context -eq 0 -and $c.Quiet.limits -eq 0) 'config missing: quiet is 0 for all three, which hides nothing'
$c = Read-StatusConfig (Write-TempConfig 'quiet-absent.json' '{ "layout": "two" }')
Confirm-True ($c.Quiet.cost -eq 0 -and $c.Quiet.context -eq 0 -and $c.Quiet.limits -eq 0) 'config quiet absent: all three default to 0'
$c = Read-StatusConfig (Write-TempConfig 'quiet-valid.json' '{ "quiet": { "cost": 1.5, "context": 30, "limits": 70 } }')
Confirm-True ($c.Quiet.cost -eq 1.5) 'config quiet valid: a fractional cost is kept as written'
Confirm-True ($c.Quiet.context -eq 30) 'config quiet valid: context 30'
Confirm-True ($c.Quiet.limits -eq 70) 'config quiet valid: limits 70'
$c = Read-StatusConfig (Write-TempConfig 'quiet-one.json' '{ "quiet": { "cost": 2 } }')
Confirm-True ($c.Quiet.cost -eq 2) 'config quiet one name: cost read'
Confirm-True ($c.Quiet.context -eq 0 -and $c.Quiet.limits -eq 0) 'config quiet one name: the other two stay 0'
# Each name falls back on its own, so a string beside a number keeps the number.
$c = Read-StatusConfig (Write-TempConfig 'quiet-wrong-types.json' '{ "quiet": { "cost": "1", "context": true, "limits": [70] } }')
Confirm-True ($c.Quiet.cost -eq 0) 'config quiet string cost: falls back to 0'
Confirm-True ($c.Quiet.context -eq 0) 'config quiet boolean context: falls back to 0'
Confirm-True ($c.Quiet.limits -eq 0) 'config quiet array limits: falls back to 0'
$c = Read-StatusConfig (Write-TempConfig 'quiet-mixed.json' '{ "quiet": { "cost": "1", "context": 30 } }')
Confirm-True ($c.Quiet.cost -eq 0 -and $c.Quiet.context -eq 30) 'config quiet mixed: the bad name falls back, the good one beside it is read'
# A negative clamps to 0 rather than passing through, so a segment whose value is 0 is still shown.
$c = Read-StatusConfig (Write-TempConfig 'quiet-negative.json' '{ "quiet": { "cost": -5, "context": -0.5, "limits": -1e3 } }')
Confirm-True ($c.Quiet.cost -eq 0 -and $c.Quiet.context -eq 0 -and $c.Quiet.limits -eq 0) 'config quiet negative: clamped to 0'
foreach ($case in @(@{ Name = 'array'; Json = '{ "quiet": [1, 2, 3] }' }, @{ Name = 'number'; Json = '{ "quiet": 5 }' },
                    @{ Name = 'string'; Json = '{ "quiet": "loud" }' }, @{ Name = 'null'; Json = '{ "quiet": null }' })) {
    $c = Read-StatusConfig (Write-TempConfig "quiet-$($case.Name).json" $case.Json)
    Confirm-True ($c.Quiet.cost -eq 0 -and $c.Quiet.context -eq 0 -and $c.Quiet.limits -eq 0) "config quiet $($case.Name): all three stay 0"
}
# A name no segment has is ignored rather than added, and the block leaves the keys beside it alone.
$c = Read-StatusConfig (Write-TempConfig 'quiet-beside.json' '{ "layout": "two", "state": false, "quiet": { "folder": 3, "cost": 1 } }')
Confirm-Equal $c.Layout 'two' 'config quiet beside layout: layout kept'
Confirm-Equal $c.State $false 'config quiet beside state: state kept'
Confirm-True ($c.Quiet.cost -eq 1) 'config quiet beside others: cost read'
Confirm-True ($c.Quiet.Count -eq 3 -and -not $c.Quiet.ContainsKey('folder')) 'config quiet unknown name: not added to the table'

# The order key: the segment names of layout one. An unknown name is skipped, a name left out is not
# shown, a repeat keeps its first place and case does not matter. An empty array, an array naming no
# segment, or anything that is not an array falls back to the registry order.
$registryOrder = $allSegments -join ','
Confirm-Equal ((Read-StatusConfig (Join-Path $tmp 'does-not-exist.json')).Order -join ',') $registryOrder 'config missing: order is the registry order'
Confirm-Equal ((Read-StatusConfig (Write-TempConfig 'order-three.json' '{ "order": ["model", "branch", "context"] }')).Order -join ',') 'model,branch,context' 'config order: three names in the given order'
Confirm-Equal ((Read-StatusConfig (Write-TempConfig 'order-unknown.json' '{ "order": ["model", "nonsense"] }')).Order -join ',') 'model' 'config order: unknown name skipped, model alone'
Confirm-Equal ((Read-StatusConfig (Write-TempConfig 'order-case.json' '{ "order": ["Branch", "MODEL", "branch"] }')).Order -join ',') 'branch,model' 'config order: case folded, a repeat keeps its first place'
Confirm-Equal ((Read-StatusConfig (Write-TempConfig 'order-mixed.json' '{ "order": ["cost", 3, null, true, ["model"], "folder"] }')).Order -join ',') 'cost,folder' 'config order: entries that are not strings are skipped'
Confirm-Equal ((Read-StatusConfig (Write-TempConfig 'order-empty.json' '{ "order": [] }')).Order -join ',') $registryOrder 'config order: empty array falls back'
Confirm-Equal ((Read-StatusConfig (Write-TempConfig 'order-none.json' '{ "order": ["nonsense"] }')).Order -join ',') $registryOrder 'config order: no known name falls back'
Confirm-Equal ((Read-StatusConfig (Write-TempConfig 'order-string.json' '{ "order": "model" }')).Order -join ',') $registryOrder 'config order: string falls back'
Confirm-Equal ((Read-StatusConfig (Write-TempConfig 'order-object.json' '{ "order": { "model": 1 } }')).Order -join ',') $registryOrder 'config order: object falls back'
Confirm-Equal ((Read-StatusConfig (Write-TempConfig 'order-null.json' '{ "order": null }')).Order -join ',') $registryOrder 'config order: null falls back'
$c = Read-StatusConfig (Write-TempConfig 'order-toggle.json' '{ "order": ["branch", "model"], "segments": { "branch": false } }')
Confirm-Equal ($c.Order -join ',') 'branch,model' 'config order: a toggled-off name stays in the order'
Confirm-Equal $c.Segments.branch $false 'config order: the toggle still applies'
$c = Read-StatusConfig (Write-TempConfig 'order-good-layout-bad.json' '{ "order": ["model"], "layout": "three" }')
Confirm-Equal ($c.Order -join ',') 'model' 'config order: kept when another key is invalid'
Confirm-Equal $c.Layout 'one' 'config order: the invalid key still falls back on its own'

# The rows key: two arrays of names for layout two, the same rules per row, and a name the first row
# took is skipped on the second. A row may be empty. Anything but an array of exactly two arrays, or
# two rows that between them name no segment, falls back to the registry rows whole.
$registryRows = "$((Get-SegmentOrder 'RowRank' 1) -join ',')|$((Get-SegmentOrder 'RowRank' 2) -join ',')"
function Get-RowText($c) { return "$($c.Rows[0] -join ',')|$($c.Rows[1] -join ',')" }
$c = Read-StatusConfig (Join-Path $tmp 'does-not-exist.json')
Confirm-Equal $c.Rows.Count 2 'config missing: two rows'
Confirm-Equal (Get-RowText $c) $registryRows 'config missing: rows are the registry rows'
Confirm-Equal (Get-RowText (Read-StatusConfig (Write-TempConfig 'rows-swapped.json' '{ "rows": [["context", "cost"], ["model", "branch"]] }'))) 'context,cost|model,branch' 'config rows: two rows as given'
Confirm-Equal (Get-RowText (Read-StatusConfig (Write-TempConfig 'rows-unknown.json' '{ "rows": [["model", "nonsense"], ["Context", 7]] }'))) 'model|context' 'config rows: unknown and non-string entries skipped, case folded'
Confirm-Equal (Get-RowText (Read-StatusConfig (Write-TempConfig 'rows-repeat.json' '{ "rows": [["model", "branch"], ["branch", "cost"]] }'))) 'model,branch|cost' 'config rows: a name on the first row is skipped on the second'
$c = Read-StatusConfig (Write-TempConfig 'rows-empty-first.json' '{ "rows": [[], ["model"]] }')
Confirm-Equal $c.Rows.Count 2 'config rows: an empty first row is still a row'
Confirm-Equal (Get-RowText $c) '|model' 'config rows: an empty first row is kept'
Confirm-Equal (Get-RowText (Read-StatusConfig (Write-TempConfig 'rows-empty-both.json' '{ "rows": [[], []] }'))) $registryRows 'config rows: both rows empty falls back'
Confirm-Equal (Get-RowText (Read-StatusConfig (Write-TempConfig 'rows-none.json' '{ "rows": [["nonsense"], ["bogus"]] }'))) $registryRows 'config rows: no known name falls back'
Confirm-Equal (Get-RowText (Read-StatusConfig (Write-TempConfig 'rows-one.json' '{ "rows": [["model"]] }'))) $registryRows 'config rows: one row falls back'
Confirm-Equal (Get-RowText (Read-StatusConfig (Write-TempConfig 'rows-three.json' '{ "rows": [["model"], ["cost"], ["branch"]] }'))) $registryRows 'config rows: three rows fall back'
Confirm-Equal (Get-RowText (Read-StatusConfig (Write-TempConfig 'rows-flat.json' '{ "rows": ["model", "cost"] }'))) $registryRows 'config rows: a flat array of names falls back'
Confirm-Equal (Get-RowText (Read-StatusConfig (Write-TempConfig 'rows-half.json' '{ "rows": [["model"], "cost"] }'))) $registryRows 'config rows: a row that is not an array falls back whole'
Confirm-Equal (Get-RowText (Read-StatusConfig (Write-TempConfig 'rows-object.json' '{ "rows": { "one": ["model"], "two": ["cost"] } }'))) $registryRows 'config rows: object falls back'
Confirm-Equal (Get-RowText (Read-StatusConfig (Write-TempConfig 'rows-string.json' '{ "rows": "model" }'))) $registryRows 'config rows: string falls back'
$c = Read-StatusConfig (Write-TempConfig 'rows-good-order-bad.json' '{ "rows": [["model"], ["cost"]], "order": 5 }')
Confirm-Equal (Get-RowText $c) 'model|cost' 'config rows: kept when order is invalid'
Confirm-Equal ($c.Order -join ',') $registryOrder 'config rows: the invalid order falls back on its own'

# The thresholds key: warn and bad, whole numbers 0 to 100 with warn at or below bad. Either value
# missing, not a whole number, out of range, or warn above bad falls back to 60 and 85 for both.
function Get-ThresholdText($c) { return "$($c.Thresholds.Warn)/$($c.Thresholds.Bad)" }
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Join-Path $tmp 'does-not-exist.json'))) '60/85' 'config missing: thresholds 60 and 85'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-low.json' '{ "thresholds": { "warn": 20, "bad": 40 } }'))) '20/40' 'config thresholds: 20 and 40'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-crossed.json' '{ "thresholds": { "warn": 90, "bad": 10 } }'))) '60/85' 'config thresholds: warn above bad falls back for both'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-equal.json' '{ "thresholds": { "warn": 50, "bad": 50 } }'))) '50/50' 'config thresholds: equal is allowed'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-edges.json' '{ "thresholds": { "warn": 0, "bad": 100 } }'))) '0/100' 'config thresholds: 0 and 100 are allowed'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-warn-only.json' '{ "thresholds": { "warn": 20 } }'))) '60/85' 'config thresholds: one value alone falls back for both'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-over.json' '{ "thresholds": { "warn": 20, "bad": 101 } }'))) '60/85' 'config thresholds: above 100 falls back for both'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-under.json' '{ "thresholds": { "warn": -1, "bad": 40 } }'))) '60/85' 'config thresholds: below 0 falls back for both'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-fraction.json' '{ "thresholds": { "warn": 20.5, "bad": 40 } }'))) '60/85' 'config thresholds: a fraction falls back for both'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-double.json' '{ "thresholds": { "warn": 20.0, "bad": 40.0 } }'))) '20/40' 'config thresholds: whole numbers written as doubles are accepted'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-exponent.json' '{ "thresholds": { "warn": 2e1, "bad": 4E1 } }'))) '20/40' 'config thresholds: whole numbers in exponent form are accepted'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-string.json' '{ "thresholds": { "warn": "20", "bad": 40 } }'))) '60/85' 'config thresholds: a string falls back for both'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-bool.json' '{ "thresholds": { "warn": true, "bad": 40 } }'))) '60/85' 'config thresholds: a boolean falls back for both'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-array.json' '{ "thresholds": [20, 40] }'))) '60/85' 'config thresholds: array falls back'
Confirm-Equal (Get-ThresholdText (Read-StatusConfig (Write-TempConfig 'thresholds-number.json' '{ "thresholds": 20 }'))) '60/85' 'config thresholds: number falls back'
$c = Read-StatusConfig (Write-TempConfig 'thresholds-good-order-bad.json' '{ "thresholds": { "warn": 20, "bad": 40 }, "order": 5 }')
Confirm-Equal (Get-ThresholdText $c) '20/40' 'config thresholds: kept when order is invalid'
Confirm-Equal ($c.Order -join ',') $registryOrder 'config thresholds: the invalid order falls back on its own'
$c = Read-StatusConfig (Write-TempConfig 'thresholds-bad-order-good.json' '{ "thresholds": { "warn": 90, "bad": 10 }, "order": ["model"] }')
Confirm-Equal (Get-ThresholdText $c) '60/85' 'config thresholds: crossed values fall back beside a valid order'
Confirm-Equal ($c.Order -join ',') 'model' 'config thresholds: the valid order is kept'

# The alarm key: the two percentages at or above which the model segment turns red. Unlike thresholds
# these are read one at a time, the way the git keys are, so a file naming one leaves the other alone.
# 0 turns that alarm off and a negative clamps to it; the top of the range is Int32's own end rather
# than 100, so a value above 100 is kept as written and can then never fire.
function Get-AlarmText($c) { return "$($c.Alarm.Context)/$($c.Alarm.Limits)" }
Confirm-Equal (Get-AlarmText (Read-StatusConfig (Join-Path $tmp 'does-not-exist.json'))) '90/90' 'config missing: alarm 90 and 90'
Confirm-Equal (Get-AlarmText (Read-StatusConfig (Write-TempConfig 'alarm-both.json' '{ "alarm": { "context": 75, "limits": 80 } }'))) '75/80' 'config alarm: both values read'
Confirm-Equal (Get-AlarmText (Read-StatusConfig (Write-TempConfig 'alarm-context-only.json' '{ "alarm": { "context": 50 } }'))) '50/90' 'config alarm: one key alone leaves the other at its default'
Confirm-Equal (Get-AlarmText (Read-StatusConfig (Write-TempConfig 'alarm-off.json' '{ "alarm": { "context": 0, "limits": 0 } }'))) '0/0' 'config alarm: 0 is kept, which turns that alarm off'
Confirm-Equal (Get-AlarmText (Read-StatusConfig (Write-TempConfig 'alarm-negative.json' '{ "alarm": { "context": -5, "limits": -1 } }'))) '0/0' 'config alarm: a negative clamps to 0'
Confirm-Equal (Get-AlarmText (Read-StatusConfig (Write-TempConfig 'alarm-over.json' '{ "alarm": { "context": 150, "limits": 101 } }'))) '150/101' 'config alarm: above 100 is kept and simply never fires'
Confirm-Equal (Get-AlarmText (Read-StatusConfig (Write-TempConfig 'alarm-double.json' '{ "alarm": { "context": 80.0, "limits": 7e1 } }'))) '80/70' 'config alarm: whole numbers as doubles and in exponent form are accepted'
Confirm-Equal (Get-AlarmText (Read-StatusConfig (Write-TempConfig 'alarm-fraction.json' '{ "alarm": { "context": 80.5, "limits": 70 } }'))) '90/70' 'config alarm: a fraction keeps the default and the key beside it still reads'
Confirm-Equal (Get-AlarmText (Read-StatusConfig (Write-TempConfig 'alarm-wrong-types.json' '{ "alarm": { "context": "80", "limits": true } }'))) '90/90' 'config alarm: a string and a boolean keep the defaults'
Confirm-Equal (Get-AlarmText (Read-StatusConfig (Write-TempConfig 'alarm-null.json' '{ "alarm": { "context": null, "limits": 70 } }'))) '90/70' 'config alarm: null keeps the default'
Confirm-Equal (Get-AlarmText (Read-StatusConfig (Write-TempConfig 'alarm-huge.json' '{ "alarm": { "context": 99999999999, "limits": -99999999999 } }'))) "$([int]::MaxValue)/0" 'config alarm: values beyond Int32 clamp to the ends of the range'
$c = Read-StatusConfig (Write-TempConfig 'alarm-int-type.json' '{ "alarm": { "context": 70, "limits": 80 } }')
Confirm-True ($c.Alarm.Context -is [int] -and $c.Alarm.Limits -is [int]) 'config alarm: the values are Int32, not the Int64 ConvertFrom-Json gives'
foreach ($case in @(@{ Name = 'array'; Json = '{ "alarm": [90, 90] }' }, @{ Name = 'number'; Json = '{ "alarm": 90 }' },
                    @{ Name = 'string'; Json = '{ "alarm": "off" }' }, @{ Name = 'null'; Json = '{ "alarm": null }' })) {
    Confirm-Equal (Get-AlarmText (Read-StatusConfig (Write-TempConfig "alarm-$($case.Name).json" $case.Json))) '90/90' "config alarm $($case.Name): falls back to 90 and 90"
}
$c = Read-StatusConfig (Write-TempConfig 'alarm-good-thresholds-bad.json' '{ "alarm": { "context": 70 }, "thresholds": 5 }')
Confirm-Equal (Get-AlarmText $c) '70/90' 'config alarm: kept when thresholds is invalid'
Confirm-Equal (Get-ThresholdText $c) '60/85' 'config alarm: the invalid thresholds fall back on their own'
$c = Read-StatusConfig (Write-TempConfig 'alarm-bad-thresholds-good.json' '{ "alarm": "off", "thresholds": { "warn": 20, "bad": 40 } }')
Confirm-Equal (Get-AlarmText $c) '90/90' 'config alarm: an invalid alarm falls back beside valid thresholds'
Confirm-Equal (Get-ThresholdText $c) '20/40' 'config alarm: the valid thresholds are kept'
# Files are merged in precedence order, so a second file naming one alarm key keeps the first file's other.
$c = Merge-StatusConfigFile (Read-StatusConfig (Write-TempConfig 'alarm-user.json' '{ "alarm": { "context": 75, "limits": 60 } }')) (Write-TempConfig 'alarm-project.json' '{ "alarm": { "limits": 50 } }')
Confirm-Equal (Get-AlarmText $c) '75/50' 'config alarm: the second file wins the key it names and leaves the other'

# The icons key: icon name to a hex code point string, with U+ or 0x allowed in front. A name no icon
# has, or a value that is not a string, not hex, above 10FFFF or a surrogate, is skipped and the built-in
# glyph stays. The parsed table holds the valid overrides only, as name to integer.
Confirm-Equal (Read-StatusConfig (Join-Path $tmp 'does-not-exist.json')).Icons.Count 0 'config missing: no icon overrides'
$c = Read-StatusConfig (Write-TempConfig 'icons-four.json' '{ "icons": { "model": "F0E7", "dirty": "U+F040", "context": "0x2588", "Branch": "e0a0", "limits": "0000F0E4" } }')
Confirm-Equal $c.Icons.Count 5 'config icons: five overrides'
Confirm-Equal $c.Icons.model 0xF0E7 'config icons: bare hex'
Confirm-Equal $c.Icons.dirty 0xF040 'config icons: U+ prefix'
Confirm-Equal $c.Icons.context 0x2588 'config icons: 0x prefix'
Confirm-Equal $c.Icons.branch 0xE0A0 'config icons: name case folded, lower-case hex'
Confirm-Equal $c.Icons.limits 0xF0E4 'config icons: leading zeros'
# The two names the constants shorten are accepted in either spelling, and land under the long one.
$c = Read-StatusConfig (Write-TempConfig 'icons-alias.json' '{ "icons": { "ctx": "2588", "limit": "2591" } }')
Confirm-Equal $c.Icons.Count 2 'config icons: ctx and limit are aliases'
Confirm-Equal $c.Icons.context 0x2588 'config icons: ctx lands under context'
Confirm-Equal $c.Icons.limits 0x2591 'config icons: limit lands under limits'
Confirm-True (-not $c.Icons.ContainsKey('ctx') -and -not $c.Icons.ContainsKey('limit')) 'config icons: the short spellings are not keys of their own'
$c = Read-StatusConfig (Write-TempConfig 'icons-unknown.json' '{ "icons": { "model": "F0E7", "bogus": "F0E7" } }')
Confirm-Equal $c.Icons.Count 1 'config icons: unknown name skipped'
Confirm-Equal $c.Icons.model 0xF0E7 'config icons: the known name beside it is kept'
$c = Read-StatusConfig (Write-TempConfig 'icons-invalid.json' '{ "icons": { "model": "zz", "cost": 61671, "folder": "", "lines": "110000", "limits": "D800", "fast": "DFFF", "think": "-1", "effort": "F0 E7", "vim": null, "home": ["F0E7"], "ahead": true, "behind": "1B", "conflict": "A", "chevron": "0" } }')
Confirm-Equal $c.Icons.Count 0 'config icons: every invalid value is skipped'
$c = Read-StatusConfig (Write-TempConfig 'icons-edges.json' '{ "icons": { "model": "10FFFF", "dirty": "E000", "ahead": "D7FF", "behind": "41" } }')
Confirm-Equal $c.Icons.Count 2 'config icons: the private use and letter edges are allowed'
Confirm-Equal $c.Icons.dirty 0xE000 'config icons: the first private use code point'
Confirm-Equal $c.Icons.behind 0x41 'config icons: a plain letter'
Confirm-True (-not $c.Icons.ContainsKey('model')) 'config icons: 10FFFF is a noncharacter and is skipped'
Confirm-True (-not $c.Icons.ContainsKey('ahead')) 'config icons: D7FF is unassigned and is skipped'
Confirm-Equal (Read-StatusConfig (Write-TempConfig 'icons-array.json' '{ "icons": ["F0E7"] }')).Icons.Count 0 'config icons: array falls back'
Confirm-Equal (Read-StatusConfig (Write-TempConfig 'icons-string.json' '{ "icons": "F0E7" }')).Icons.Count 0 'config icons: string falls back'
$c = Read-StatusConfig (Write-TempConfig 'icons-good-thresholds-bad.json' '{ "icons": { "model": "F0E7" }, "thresholds": 5 }')
Confirm-Equal $c.Icons.model 0xF0E7 'config icons: kept when thresholds is invalid'
Confirm-Equal (Get-ThresholdText $c) '60/85' 'config icons: the invalid thresholds fall back on their own'

# The preset key: one name standing for a layout, a style and every segment toggle. Get-ConfigPreset
# holds the three shapes; a name it does not have, or a value that is not a string, returns $null and
# changes nothing. A preset is expanded before the rest of the file it is named in, so any key beside it
# wins whatever order the file spells them in, and it touches nothing but layout, style and segments.
function Get-SegmentText($c) { return (@($allSegments | Where-Object { $c.Segments[$_] }) -join ',') }
$presetShape = @(
    @{ Name = 'minimal'; Layout = 'one'; Style = 'plain'; On = 'model,context,folder,branch' }
    @{ Name = 'cost'; Layout = 'one'; Style = 'plain'; On = 'model,context,cost,lines,limits' }
    @{ Name = 'full'; Layout = 'two'; Style = 'powerline'; On = ($allSegments -join ',') }
)
foreach ($want in $presetShape) {
    $n = $want.Name
    $p = Get-ConfigPreset $n
    Confirm-True ($null -ne $p) "preset ${n}: the name is known"
    Confirm-Equal $p.Layout $want.Layout "preset ${n}: layout $($want.Layout)"
    Confirm-Equal $p.Style $want.Style "preset ${n}: style $($want.Style)"
    # Every preset states the whole registry and nothing beyond it, so a segment added later has to be
    # placed in all three by hand rather than appearing in `minimal` because no one said otherwise.
    Confirm-Equal (@($allSegments | Where-Object { -not $p.Segments.ContainsKey($_) }) -join ',') '' "preset ${n}: every registry segment is named"
    Confirm-Equal $p.Segments.Count $allSegments.Count "preset ${n}: it names nothing the registry does not have"
    # The same shape through a whole config file.
    $c = Read-StatusConfig (Write-TempConfig "preset-$n.json" ('{ "preset": "' + $n + '" }'))
    Confirm-Equal $c.Layout $want.Layout "preset ${n}: config layout $($want.Layout)"
    Confirm-Equal $c.Style $want.Style "preset ${n}: config style $($want.Style)"
    Confirm-Equal (Get-SegmentText $c) $want.On "preset ${n}: config segments $($want.On)"
    # A preset sets layout, style and the toggles and nothing else: order, rows, thresholds, icons, the
    # state toggle and the git block all stay where the defaults left them.
    Confirm-Equal ($c.Order -join ',') $registryOrder "preset ${n}: the order is untouched"
    Confirm-Equal (Get-RowText $c) $registryRows "preset ${n}: the rows are untouched"
    Confirm-Equal (Get-ThresholdText $c) '60/85' "preset ${n}: the thresholds are untouched"
    Confirm-Equal $c.Icons.Count 0 "preset ${n}: the icons are untouched"
    Confirm-Equal $c.State $true "preset ${n}: the state toggle is untouched"
    Confirm-Equal $c.Git.TimeoutMs 1500 "preset ${n}: the git block is untouched"
    Confirm-Equal $c.Folder 'repo' "preset ${n}: the folder mode is untouched"
}
# A fresh table every call, the segment table included, so a caller that changes its copy cannot reach
# the next caller's the way Get-DefaultStatusConfig cannot.
$p = Get-ConfigPreset 'minimal'
$p.Layout = 'two'; $p.Segments.cost = $true
$p2 = Get-ConfigPreset 'minimal'
Confirm-Equal $p2.Layout 'one' 'preset: a changed copy does not change the next table'
Confirm-Equal $p2.Segments.cost $false 'preset: the segment table is fresh too'
# The name is folded like layout and style are.
foreach ($spelling in @('FULL', 'Full', 'fUlL')) {
    Confirm-Equal (Get-ConfigPreset $spelling).Style 'powerline' "preset: $spelling names the full preset"
}
$c = Read-StatusConfig (Write-TempConfig 'preset-case.json' '{ "preset": "FULL" }')
Confirm-Equal (Get-SegmentText $c) ($allSegments -join ',') 'preset: a name in capitals matches through a config file'
Confirm-Equal $c.Style 'powerline' 'preset: a name in capitals takes the full style'
# Anything the table does not have returns $null and leaves the defaults standing. The helper is untyped
# so a number, an array or a boolean is refused rather than turned into a name.
$defaultSegments = ($allSegments -join ',')
$presetBadIndex = 0
foreach ($case in @(
        @{ Label = 'an unknown name'; Value = 'nope'; Json = '"nope"' }
        @{ Label = 'an empty string'; Value = ''; Json = '""' }
        @{ Label = 'a number'; Value = 5; Json = '5' }
        @{ Label = 'a boolean'; Value = $true; Json = 'true' }
        @{ Label = 'null'; Value = $null; Json = 'null' }
        @{ Label = 'an array'; Value = @('minimal'); Json = '["minimal"]' }
        @{ Label = 'an object'; Value = @{ name = 'minimal' }; Json = '{ "name": "minimal" }' })) {
    Confirm-True ($null -eq (Get-ConfigPreset $case.Value)) "preset: $($case.Label) is not a preset"
    $presetBadIndex++
    $c = Read-StatusConfig (Write-TempConfig "preset-bad-$presetBadIndex.json" ('{ "preset": ' + $case.Json + ' }'))
    Confirm-Equal $c.Layout 'one' "preset: $($case.Label) leaves the default layout"
    Confirm-Equal $c.Style 'plain' "preset: $($case.Label) leaves the default style"
    Confirm-Equal (Get-SegmentText $c) $defaultSegments "preset: $($case.Label) leaves every segment on"
}
# A key beside a preset is written over it, whichever order the file spells the two in. JSON has no
# ordering rule and a person writing one may well put the preset last, so both orders are pinned here.
foreach ($case in @(
        @{ Where = 'after the preset'; Json = '{ "preset": "minimal", "style": "powerline" }' }
        @{ Where = 'before the preset'; Json = '{ "style": "powerline", "preset": "minimal" }' })) {
    $c = Read-StatusConfig (Write-TempConfig "preset-style-$($case.Where -replace ' ', '-').json" $case.Json)
    Confirm-Equal $c.Style 'powerline' "preset: a style $($case.Where) wins"
    Confirm-Equal $c.Layout 'one' "preset: a style $($case.Where) leaves the preset layout"
    Confirm-Equal (Get-SegmentText $c) 'model,context,folder,branch' "preset: a style $($case.Where) leaves the minimal segments"
}
$c = Read-StatusConfig (Write-TempConfig 'preset-segment-on.json' '{ "preset": "cost", "segments": { "branch": true } }')
Confirm-Equal (Get-SegmentText $c) 'model,context,cost,lines,limits,branch' 'preset: a segment turned back on beside it'
$c = Read-StatusConfig (Write-TempConfig 'preset-segment-off.json' '{ "preset": "cost", "segments": { "cost": false } }')
Confirm-Equal (Get-SegmentText $c) 'model,context,lines,limits' 'preset: a segment turned off beside it'
$c = Read-StatusConfig (Write-TempConfig 'preset-layout.json' '{ "preset": "full", "layout": "one" }')
Confirm-Equal $c.Layout 'one' 'preset: the layout beside it wins'
Confirm-Equal $c.Style 'powerline' 'preset: the style it sets is kept'
# A preset beside a key it does not set: both apply.
$c = Read-StatusConfig (Write-TempConfig 'preset-thresholds.json' '{ "preset": "minimal", "thresholds": { "warn": 20, "bad": 40 }, "order": ["branch", "model"] }')
Confirm-Equal (Get-SegmentText $c) 'model,context,folder,branch' 'preset: the segments are set beside a threshold'
Confirm-Equal (Get-ThresholdText $c) '20/40' 'preset: the thresholds beside it are applied'
Confirm-Equal ($c.Order -join ',') 'branch,model' 'preset: the order beside it is applied'
# An invalid key beside a preset falls back to the preset, not to the built-in default.
$c = Read-StatusConfig (Write-TempConfig 'preset-bad-key.json' '{ "preset": "full", "style": 5, "layout": "three" }')
Confirm-Equal $c.Style 'powerline' 'preset: an invalid style falls back to the preset style'
Confirm-Equal $c.Layout 'two' 'preset: an invalid layout falls back to the preset layout'

# ---- The project config: a second file merged over the user file, key by key ----
# Read-StatusConfig builds the defaults, merges the user file, then merges the project file when the
# payload named a project directory holding .claude\statusline.json. The merge is per key, so a project
# file naming one key leaves the rest of the user file standing, and an invalid value there falls back
# to the value beneath it rather than to the built-in default.
function Write-TempProjectDir([string] $Name, $Json) {
    $dir = Join-Path $tmp $Name
    $claude = Join-Path $dir '.claude'
    New-Item -ItemType Directory -Force $claude | Out-Null
    if ($null -ne $Json) { [System.IO.File]::WriteAllText((Join-Path $claude 'statusline.json'), $Json, [System.Text.UTF8Encoding]::new($false)) }
    return $dir
}
$missingConfig = Join-Path $tmp 'does-not-exist.json'

# The defaults and one file merge are functions of their own, so the files can be applied in order.
$defaultCfg = Get-DefaultStatusConfig
Confirm-Equal $defaultCfg.Layout 'one' 'default config: layout one'
Confirm-Equal $defaultCfg.Style 'plain' 'default config: style plain'
Confirm-Equal $defaultCfg.Folder 'repo' 'default config: folder repo'
Confirm-Equal $defaultCfg.State $true 'default config: state on'
Confirm-Equal ($defaultCfg.Order -join ',') $registryOrder 'default config: order is the registry order'
Confirm-Equal (Get-RowText $defaultCfg) $registryRows 'default config: rows are the registry rows'
Confirm-Equal (Get-ThresholdText $defaultCfg) '60/85' 'default config: thresholds 60 and 85'
Confirm-Equal (Get-AlarmText $defaultCfg) '90/90' 'default config: alarm 90 and 90'
Confirm-Equal $defaultCfg.Icons.Count 0 'default config: no icon overrides'
Confirm-Equal $defaultCfg.Git.TimeoutMs 1500 'default config: git timeout 1500'
Confirm-True ($defaultCfg.Quiet.cost -eq 0 -and $defaultCfg.Quiet.context -eq 0 -and $defaultCfg.Quiet.limits -eq 0) 'default config: quiet is 0 for all three'
Confirm-True (@($allSegments | Where-Object { -not $defaultCfg.Segments[$_] }).Count -eq 0) 'default config: every segment on'
# A fresh table every call, nested tables included, so a caller that changes its copy cannot reach the next.
$defaultCfg.Layout = 'two'; $defaultCfg.Segments.cost = $false; $defaultCfg.Git.TimeoutMs = 999; $defaultCfg.Thresholds.Warn = 1; $defaultCfg.Alarm.Context = 1; $defaultCfg.Icons.model = 1; $defaultCfg.Quiet.cost = 9
$fresh = Get-DefaultStatusConfig
Confirm-Equal $fresh.Layout 'one' 'default config: a changed copy does not change the next table'
Confirm-Equal $fresh.Segments.cost $true 'default config: the segment table is fresh too'
Confirm-Equal $fresh.Git.TimeoutMs 1500 'default config: the git table is fresh too'
Confirm-Equal $fresh.Thresholds.Warn 60 'default config: the thresholds table is fresh too'
Confirm-Equal $fresh.Alarm.Context 90 'default config: the alarm table is fresh too'
Confirm-Equal $fresh.Icons.Count 0 'default config: the icons table is fresh too'
Confirm-True ($fresh.Quiet.cost -eq 0) 'default config: the quiet table is fresh too'
$merged = Merge-StatusConfigFile $fresh (Write-TempConfig 'merge-one.json' '{ "layout": "two", "segments": { "cost": false } }')
Confirm-Equal $merged.Layout 'two' 'merge file: the key the file names is applied'
Confirm-Equal $merged.Segments.cost $false 'merge file: the segment toggle is applied'
Confirm-Equal $merged.Style 'plain' 'merge file: a key the file does not name is left alone'
Confirm-Equal (Merge-StatusConfigFile (Get-DefaultStatusConfig) $missingConfig).Layout 'one' 'merge file: a missing file changes nothing'
$twice = Merge-StatusConfigFile (Merge-StatusConfigFile (Get-DefaultStatusConfig) (Write-TempConfig 'merge-first.json' '{ "layout": "two", "style": "powerline" }')) (Write-TempConfig 'merge-second.json' '{ "style": "plain" }')
Confirm-Equal $twice.Layout 'two' 'merge file: the first file survives the second'
Confirm-Equal $twice.Style 'plain' 'merge file: the second file wins the key both name'

# The user file the project cases below merge over: powerline with the cost segment off.
$userPath = Write-TempConfig 'project-user.json' '{ "style": "powerline", "segments": { "cost": false } }'
$c = Read-StatusConfig $userPath (Write-TempProjectDir 'proj-layout' '{ "layout": "two" }')
Confirm-Equal $c.Layout 'two' 'project config: the project layout is applied'
Confirm-Equal $c.Style 'powerline' 'project config: the user style is kept'
Confirm-Equal $c.Segments.cost $false 'project config: the user segment toggle is kept'
Confirm-True (@($allSegments | Where-Object { $_ -ne 'cost' -and -not $c.Segments[$_] }).Count -eq 0) 'project config: the other eight segments stay on'
# The project file with no user file at all: it applies over the built-in defaults.
$c = Read-StatusConfig $missingConfig (Write-TempProjectDir 'proj-alone' '{ "layout": "two", "state": false }')
Confirm-Equal $c.Layout 'two' 'project config alone: the layout is applied'
Confirm-Equal $c.State $false 'project config alone: the state toggle is applied'
Confirm-Equal $c.Style 'plain' 'project config alone: the rest is the built-in defaults'
# A project toggle turns a segment the user file switched off back on.
$c = Read-StatusConfig $userPath (Write-TempProjectDir 'proj-cost-on' '{ "segments": { "cost": true } }')
Confirm-Equal $c.Segments.cost $true 'project config: a segment the user file turned off is turned back on'
Confirm-Equal $c.Style 'powerline' 'project config: the segment toggle does not disturb the style'
# An invalid value falls back to the value beneath it, which is the user file's, not the default.
$richUser = Write-TempConfig 'project-user-rich.json' '{ "layout": "two", "thresholds": { "warn": 20, "bad": 40 }, "git": { "timeoutMs": 3000, "cache": false }, "icons": { "model": "F0E7" } }'
$c = Read-StatusConfig $richUser (Write-TempProjectDir 'proj-invalid' '{ "layout": "three", "thresholds": { "warn": 90, "bad": 10 }, "git": { "timeoutMs": "x", "cache": "no" }, "icons": { "model": "zz" } }')
Confirm-Equal $c.Layout 'two' 'project config: an invalid layout keeps the user layout'
Confirm-Equal (Get-ThresholdText $c) '20/40' 'project config: invalid thresholds keep the user thresholds'
Confirm-Equal $c.Git.TimeoutMs 3000 'project config: an invalid timeout keeps the user timeout'
Confirm-Equal $c.Git.Cache $false 'project config: an invalid cache flag keeps the user flag'
Confirm-Equal $c.Icons.model 0xF0E7 'project config: an invalid icon keeps the user override'
# The git block merges key by key like the rest.
$c = Read-StatusConfig $richUser (Write-TempProjectDir 'proj-git' '{ "git": { "cacheSeconds": 30 } }')
Confirm-Equal $c.Git.CacheSeconds 30 'project config: the project cache window is applied'
Confirm-Equal $c.Git.TimeoutMs 3000 'project config: the user timeout beside it is kept'
Confirm-Equal $c.Git.Cache $false 'project config: the user cache flag beside it is kept'
# Icons merge by name: the project wins the name both spell and adds its own.
$c = Read-StatusConfig (Write-TempConfig 'project-user-icons.json' '{ "icons": { "model": "F0E7", "branch": "E0A0" } }') (Write-TempProjectDir 'proj-icons' '{ "icons": { "model": "2588", "cost": "F0155" } }')
Confirm-Equal $c.Icons.Count 3 'project config: icons merge by name'
Confirm-Equal $c.Icons.model 0x2588 'project config: the project icon wins the shared name'
Confirm-Equal $c.Icons.branch 0xE0A0 'project config: the user icon it does not name is kept'
Confirm-Equal $c.Icons.cost 0xF0155 'project config: the icon only the project names is added'
# order and rows: the project list replaces the user list whole, and one naming nothing falls back to it.
$orderUser = Write-TempConfig 'project-user-order.json' '{ "order": ["model", "cost"], "rows": [["model"], ["cost"]] }'
$c = Read-StatusConfig $orderUser (Write-TempProjectDir 'proj-order' '{ "order": ["branch", "model"] }')
Confirm-Equal ($c.Order -join ',') 'branch,model' 'project config: the project order is applied'
Confirm-Equal (Get-RowText $c) 'model|cost' 'project config: the user rows beside it are kept'
$c = Read-StatusConfig $orderUser (Write-TempProjectDir 'proj-order-bad' '{ "order": ["nonsense"] }')
Confirm-Equal ($c.Order -join ',') 'model,cost' 'project config: an order naming nothing keeps the user order'
$c = Read-StatusConfig $orderUser (Write-TempProjectDir 'proj-rows' '{ "rows": [["branch"], ["limits"]] }')
Confirm-Equal (Get-RowText $c) 'branch|limits' 'project config: the project rows are applied'
Confirm-Equal ($c.Order -join ',') 'model,cost' 'project config: the user order beside them is kept'
# preset: expanded inside the file that names it, so it sits at that file's place in the chain. A user
# preset is a starting point the user's own keys and then the whole project file are written over; a
# project preset outranks the user file entirely, which is the same rule every other project key follows.
# The preset table is built into the script, so naming one from a project config opens no path and reads
# no second file: an untrusted config can pick one of three shapes and nothing else.
$c = Read-StatusConfig (Write-TempConfig 'preset-project-user.json' '{ "preset": "minimal" }') (Write-TempProjectDir 'proj-preset-key' '{ "segments": { "cost": true } }')
Confirm-Equal (Get-SegmentText $c) 'model,context,cost,folder,branch' 'project config: a project toggle lands on the user preset'
Confirm-Equal $c.Layout 'one' 'project config: the user preset layout is kept'
$c = Read-StatusConfig $userPath (Write-TempProjectDir 'proj-preset' '{ "preset": "cost" }')
Confirm-Equal (Get-SegmentText $c) 'model,context,cost,lines,limits' 'project config: a project preset outranks the user segment toggles'
Confirm-Equal $c.Style 'plain' 'project config: a project preset outranks the user style'
$c = Read-StatusConfig $userPath (Write-TempProjectDir 'proj-preset-and-key' '{ "preset": "cost", "style": "powerline" }')
Confirm-Equal $c.Style 'powerline' 'project config: a key beside the project preset wins'
Confirm-Equal (Get-SegmentText $c) 'model,context,cost,lines,limits' 'project config: the project preset segments are kept'
$c = Read-StatusConfig (Write-TempConfig 'preset-project-user-full.json' '{ "preset": "full" }') (Write-TempProjectDir 'proj-preset-over' '{ "preset": "minimal" }')
Confirm-Equal (Get-SegmentText $c) 'model,context,folder,branch' 'project config: the project preset wins the one the user file names'
Confirm-Equal $c.Layout 'one' 'project config: the project preset layout wins'
$c = Read-StatusConfig (Write-TempConfig 'preset-project-user-min.json' '{ "preset": "minimal" }') (Write-TempProjectDir 'proj-preset-unknown' '{ "preset": "nope" }')
Confirm-Equal (Get-SegmentText $c) 'model,context,folder,branch' 'project config: a preset name the project gets wrong keeps the user preset'

# A project file that cannot be read leaves the user config in force.
foreach ($case in @(
        @{ Name = 'proj-broken'; Json = '{ "layout": '; Label = 'broken JSON' }
        @{ Name = 'proj-array'; Json = '[1, 2]'; Label = 'a JSON array' }
        @{ Name = 'proj-number'; Json = '42'; Label = 'a bare number' }
        @{ Name = 'proj-empty-file'; Json = ''; Label = 'an empty file' }
        @{ Name = 'proj-no-file'; Json = $null; Label = 'an empty .claude directory' })) {
    $c = Read-StatusConfig $userPath (Write-TempProjectDir $case.Name $case.Json)
    Confirm-Equal $c.Style 'powerline' "project config: $($case.Label) keeps the user style"
    Confirm-Equal $c.Segments.cost $false "project config: $($case.Label) keeps the user segment toggle"
}
# A directory with no .claude, one that does not exist, and no project directory at all.
$noClaude = Join-Path $tmp 'proj-plain-dir'
New-Item -ItemType Directory -Force $noClaude | Out-Null
Confirm-Equal (Read-StatusConfig $userPath $noClaude).Style 'powerline' 'project config: a directory with no .claude changes nothing'
Confirm-Equal (Read-StatusConfig $userPath (Join-Path $tmp 'proj-does-not-exist')).Style 'powerline' 'project config: a directory that does not exist changes nothing'
Confirm-Equal (Read-StatusConfig $userPath '').Style 'powerline' 'project config: an empty project directory leaves the user file in force'
Confirm-Equal (Read-StatusConfig $userPath $null).Style 'powerline' 'project config: a null project directory leaves the user file in force'
Confirm-Equal (Read-StatusConfig $userPath).Style 'powerline' 'project config: the project directory parameter is optional'
# The payload can spell project_dir any way it likes, so a value that is not a string is ignored rather
# than joined into a path: an array would otherwise become "a b" and a hashtable its type name.
foreach ($bad in @(7, $true, @('a', 'b'), @{ a = 1 })) {
    $c = Read-StatusConfig $userPath $bad
    Confirm-Equal $c.Style 'powerline' "project config: a project directory of type $($bad.GetType().Name) is ignored"
}
# A user file that cannot be read leaves the project file merging over the built-in defaults.
$c = Read-StatusConfig (Write-TempConfig 'project-user-broken.json' '{ "style": ') (Write-TempProjectDir 'proj-over-broken' '{ "layout": "two" }')
Confirm-Equal $c.Layout 'two' 'project config: it still applies when the user file is broken'
Confirm-Equal $c.Style 'plain' 'project config: the broken user file falls back to the defaults'

# ---- The project file as bounded untrusted input ----
# The project file comes with the repository, not from the user, so it is read through Read-BoundedFileText
# rather than Get-Content: an ordinary file, no bigger than the cap, read under a deadline. Everything
# else is refused silently, the same as a value of the wrong type.
$limit = Get-ProjectConfigLimit
Confirm-True ($limit.MaxBytes -ge 4096 -and $limit.MaxBytes -le 262144) 'bounded read: the cap is tens of kilobytes, far past a hand-written config'
Confirm-True ($limit.TimeoutMs -gt 0 -and $limit.TimeoutMs -le 1000) 'bounded read: the deadline is shorter than a render'
$smallProject = Write-TempConfig 'bounded-small.json' '{ "layout": "two" }'
Confirm-Equal (Read-BoundedFileText $smallProject) '{ "layout": "two" }' 'bounded read: a small file reads back whole'
Confirm-Equal (Read-BoundedFileText (Join-Path $tmp 'bounded-missing.json')) $null 'bounded read: a file that is not there is refused'
Confirm-Equal (Read-BoundedFileText $tmp) $null 'bounded read: a directory is refused'
Confirm-Equal (Read-BoundedFileText '') $null 'bounded read: an empty path is refused'
# One byte under the cap reads, the cap plus a little does not. The pad keeps the file valid JSON either
# way, so what separates the two cases is the size and nothing else.
$underCap = Write-TempConfig 'bounded-under-cap.json' ('{ "layout": "two", "pad": "' + ('x' * ($limit.MaxBytes - 40)) + '" }')
Confirm-True ((Get-Item -LiteralPath $underCap).Length -le $limit.MaxBytes) 'bounded read: the under-cap fixture is under the cap'
Confirm-True ($null -ne (Read-BoundedFileText $underCap)) 'bounded read: a file just under the cap reads back'
$overCap = Write-TempConfig 'bounded-over-cap.json' ('{ "layout": "two", "pad": "' + ('x' * $limit.MaxBytes) + '" }')
Confirm-Equal (Read-BoundedFileText $overCap) $null 'bounded read: a file over the cap is refused'
# A byte order mark is dropped, since ConvertFrom-Json will not parse past one.
$bomPath = Join-Path $tmp 'bounded-bom.json'
[System.IO.File]::WriteAllText($bomPath, '{ "layout": "two" }', [System.Text.UTF8Encoding]::new($true))
Confirm-Equal (Read-BoundedFileText $bomPath) '{ "layout": "two" }' 'bounded read: a byte order mark is dropped'
# The same rules through Read-StatusConfig: an oversized project config, and one that is not an ordinary
# file, both leave the user config standing. A file symbolic link needs Developer Mode or an elevated
# shell on Windows; where one cannot be made a directory stands in its place, which is the same rule
# under test - the entry has to be an ordinary file.
$c = Read-StatusConfig $userPath (Write-TempProjectDir 'proj-oversized' ('{ "layout": "two", "pad": "' + ('x' * $limit.MaxBytes) + '" }'))
Confirm-Equal $c.Layout 'one' 'project config: a file over the byte cap is refused'
Confirm-Equal $c.Style 'powerline' 'project config: the user file stands over the oversized one'
$linkDir = Write-TempProjectDir 'proj-link' $null
$linkPath = Join-Path (Join-Path $linkDir '.claude') 'statusline.json'
$linkTarget = Write-TempConfig 'proj-link-target.json' '{ "layout": "two" }'
$madeLink = $true
try { New-Item -ItemType SymbolicLink -Path $linkPath -Target $linkTarget -ErrorAction Stop | Out-Null } catch { $madeLink = $false }
if (-not $madeLink) { New-Item -ItemType Directory -Force $linkPath | Out-Null }
$linkKind = if ($madeLink) { 'a link' } else { 'a directory' }
# Say which one ran, so a green log cannot be read as proof that the link case was exercised on a
# machine where a symbolic link could not be made.
Write-Host "  project link case: $linkKind ($(if ($madeLink) { 'symbolic links available' } else { 'symbolic links need Developer Mode here' }))" -ForegroundColor DarkGray
Confirm-Equal (Read-BoundedFileText $linkPath) $null "bounded read: $linkKind in place of the file is refused"
$c = Read-StatusConfig $userPath $linkDir
Confirm-Equal $c.Layout 'one' "project config: $linkKind in place of the file is refused"
Confirm-Equal $c.Style 'powerline' 'project config: the user file stands over the refused link'

# One clock covers the whole read and starts before the first filesystem call. A budget of zero shows
# where it starts: a file that read back whole a few lines ago is refused, because the budget is spent
# before anything is looked up. The real limit is rebuilt from the values captured here rather than
# retyped, so this cannot drift from the script's own numbers.
$realLimit = Get-ProjectConfigLimit
. ([scriptblock]::Create("function Get-ProjectConfigLimit { return @{ MaxBytes = $($realLimit.MaxBytes); TimeoutMs = 0 } }"))
$zeroSw = [System.Diagnostics.Stopwatch]::StartNew()
Confirm-Equal (Read-BoundedFileText $smallProject) $null 'bounded read: a spent budget refuses a file that is otherwise fine'
Confirm-True ($zeroSw.ElapsedMilliseconds -lt 1000) 'bounded read: a spent budget gives up at once'
. ([scriptblock]::Create("function Get-ProjectConfigLimit { return @{ MaxBytes = $($realLimit.MaxBytes); TimeoutMs = $($realLimit.TimeoutMs) } }"))
Confirm-Equal (Get-ProjectConfigLimit).TimeoutMs $realLimit.TimeoutMs 'bounded read: the real deadline is back'
Confirm-Equal (Get-ProjectConfigLimit).MaxBytes $realLimit.MaxBytes 'bounded read: the real cap is back'
Confirm-Equal (Read-BoundedFileText $smallProject) '{ "layout": "two" }' 'bounded read: the same file reads again with the deadline back'

# What the handle says, not what the name said. The null device opens like a file on Windows and has the
# shape a FIFO has on Unix - a handle that cannot seek - so it is the one non-regular file this machine
# can produce without a privilege, and the check that refuses it is made after the open, from the handle.
$deviceSeek = $null
try { $h = [System.IO.File]::OpenRead('NUL'); $deviceSeek = $h.CanSeek; $h.Dispose() } catch { $deviceSeek = $null }
Write-Host "  device handle case: $(if ($null -eq $deviceSeek) { 'the null device would not open here, so only the refusal is checked' } else { "the null device opens with CanSeek $deviceSeek" })" -ForegroundColor DarkGray
Confirm-True ($null -eq $deviceSeek -or -not $deviceSeek) 'bounded read: a device handle cannot seek'
Confirm-Equal (Read-BoundedFileText 'NUL') $null 'bounded read: a handle that cannot seek is refused'

# A filesystem that does not answer. The open blocks inside the call, which is the case the budget exists
# for and the one that tells this design from the last: a check made before the clock started could only
# wait on the network stack. Where a machine's stack refuses at once this proves the refusal and nothing
# more, so the log says which of the two happened rather than letting a green run imply the harder one.
$deadPath = '\\192.0.2.1\statusline-test\statusline.json'
$deadSw = [System.Diagnostics.Stopwatch]::StartNew()
$deadText = Read-BoundedFileText $deadPath
$deadMs = $deadSw.ElapsedMilliseconds
Write-Host "  unreachable path case: $deadMs ms ($(if ($deadMs -ge $realLimit.TimeoutMs) { 'the open blocked and the budget ended it' } else { 'the network stack refused before the budget mattered' }))" -ForegroundColor DarkGray
Confirm-Equal $deadText $null 'bounded read: a path on an unreachable filesystem is refused'
Confirm-True ($deadMs -lt 2000) 'bounded read: an unreachable filesystem costs the budget, not the network timeout'
$deadSw = [System.Diagnostics.Stopwatch]::StartNew()
$c = Read-StatusConfig $userPath '\\192.0.2.1\statusline-test'
Confirm-True ($deadSw.ElapsedMilliseconds -lt 2000) 'project config: an unreachable project directory costs the budget'
Confirm-Equal $c.Style 'powerline' 'project config: an unreachable project directory leaves the user file in force'
Confirm-Equal $c.Layout 'one' 'project config: an unreachable project directory changes nothing'
# The swap this ordering defeats - a name that becomes a link, a device or a larger file between the
# check and the read - cannot be staged from here, because there is no hook between the open and the
# checks that follow it. What is shown instead is the property that closes the window: the two refusals
# above are made from the handle rather than from the name.
Write-Host '  swap-in-flight case: not staged; the handle checks above are what closes the window' -ForegroundColor DarkGray

# Reading a stream's length and closing it are filesystem calls of their own, and on a handle to a remote
# file either can hang with the file already open. Neither is allowed to run where it would hold up the
# line, and a stream whose Length and Dispose block for five seconds proves it without depending on how
# any real filesystem happens to behave: the length is asked for on the pool and abandoned at the budget,
# and the close is queued and never waited on. Get-BoundedStreamDelegate closes over Stream's own virtual
# members, so this double goes through the very call a FileStream would.
if (-not ('StatuslineTest.BlockingStream' -as [type])) {
    try {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
namespace StatuslineTest {
    public class BlockingStream : Stream {
        private readonly int _lengthDelayMs;
        private readonly int _disposeDelayMs;
        public bool Disposed;
        public BlockingStream(int lengthDelayMs, int disposeDelayMs) { _lengthDelayMs = lengthDelayMs; _disposeDelayMs = disposeDelayMs; }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return true; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { Thread.Sleep(_lengthDelayMs); return 0L; } }
        public override long Position { get { return 0L; } set { } }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) { return 0; }
        public override long Seek(long offset, SeekOrigin origin) { return 0L; }
        public override void SetLength(long value) { }
        public override void Write(byte[] buffer, int offset, int count) { }
        protected override void Dispose(bool disposing) { Thread.Sleep(_disposeDelayMs); Disposed = true; }
    }
}
'@
    } catch { $null = $_ }
}
$blockingType = 'StatuslineTest.BlockingStream' -as [type]
if ($null -eq $blockingType) {
    Write-Host '  blocking handle case: the double would not compile here, so Length and Dispose are not covered' -ForegroundColor DarkGray
} else {
    Write-Host '  blocking handle case: a compiled double holds Length and Dispose for 5000 ms' -ForegroundColor DarkGray
    $blocking = $blockingType::new(5000, 5000)
    $blockingCall = Get-BoundedStreamDelegate $blocking
    # The length, asked for the way the bounded read asks for it.
    $blockSw = [System.Diagnostics.Stopwatch]::StartNew()
    $blockTask = [System.Threading.Tasks.Task]::Run($blockingCall.Length)
    $blockDone = $blockTask.Wait((Get-ProjectConfigLimit).TimeoutMs)
    $blockMs = $blockSw.ElapsedMilliseconds
    Confirm-True (-not $blockDone) 'bounded read: a length that blocks does not answer inside the budget'
    Confirm-True ($blockMs -lt 2000) 'bounded read: a blocking length is abandoned at the budget, not waited out'
    # The close, queued the way the bounded read queues it: control comes back before it has finished.
    $blockSw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = [System.Threading.Tasks.Task]::Run($blockingCall.Dispose)
    $disposeMs = $blockSw.ElapsedMilliseconds
    Confirm-True ($disposeMs -lt 1000) 'bounded read: a close that blocks never runs where the line waits for it'
    Confirm-True (-not $blocking.Disposed) 'bounded read: the close is still running, so it was queued rather than waited on'
    # A stream that answers at once is closed, so the ordinary path does not leak a handle.
    $quick = $blockingType::new(0, 0)
    $quickCall = Get-BoundedStreamDelegate $quick
    $quickTask = [System.Threading.Tasks.Task]::Run($quickCall.Dispose)
    Confirm-True ($quickTask.Wait(5000)) 'bounded read: a close that answers finishes'
    Confirm-True ($quick.Disposed) 'bounded read: the queued close really closes the stream'
    Confirm-Equal ([System.Threading.Tasks.Task]::Run($quickCall.Length).Result) 0 'bounded read: the length delegate reads the stream it was closed over'
}

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
Confirm-Equal $c.Git.TimeoutMs 1500 'shipped config: git timeout 1500'
Confirm-Equal $c.Git.CacheSeconds 5 'shipped config: git cache 5 seconds'
Confirm-Equal $c.Git.Cache $true 'shipped config: git cache on'
Confirm-True ($shippedJson.git -is [System.Management.Automation.PSCustomObject]) 'shipped config: the file itself has a git object'
Confirm-Equal @($shippedJson.git.PSObject.Properties).Count 3 'shipped config: the git object lists three keys'
Confirm-True ($shippedJson.git.timeoutMs -is [long] -and $shippedJson.git.timeoutMs -eq 1500) 'shipped config: the file itself says timeoutMs 1500 as a number'
Confirm-True ($shippedJson.git.cacheSeconds -is [long] -and $shippedJson.git.cacheSeconds -eq 5) 'shipped config: the file itself says cacheSeconds 5 as a number'
Confirm-True ($shippedJson.git.cache -is [bool] -and $shippedJson.git.cache) 'shipped config: the file itself sets cache to the boolean true'
# thresholds and icons ship at their defaults, spelled out. order and rows are left out on purpose: the
# installer keeps an existing config, so a file that listed every segment by name would pin the set and
# a segment added by a later release would never appear for anyone who installed this one.
Confirm-Equal ($c.Order -join ',') $registryOrder 'shipped config: order is the registry order'
Confirm-True ($null -eq $shippedJson.PSObject.Properties['order']) 'shipped config: the file itself has no order key, so a new segment appears on its own'
Confirm-Equal (Get-RowText $c) $registryRows 'shipped config: rows are the registry rows'
Confirm-True ($null -eq $shippedJson.PSObject.Properties['rows']) 'shipped config: the file itself has no rows key'
Confirm-Equal (Get-ThresholdText $c) '60/85' 'shipped config: thresholds 60 and 85'
Confirm-True ($shippedJson.thresholds.warn -eq 60 -and $shippedJson.thresholds.bad -eq 85) 'shipped config: the file itself says 60 and 85'
Confirm-Equal (Get-AlarmText $c) '90/90' 'shipped config: alarm 90 and 90'
Confirm-True ($shippedJson.alarm.context -eq 90 -and $shippedJson.alarm.limits -eq 90) 'shipped config: the file itself says 90 and 90'
Confirm-Equal $c.Icons.Count 0 'shipped config: no icon overrides'
Confirm-True ($shippedJson.icons -is [System.Management.Automation.PSCustomObject] -and @($shippedJson.icons.PSObject.Properties).Count -eq 0) 'shipped config: the file itself has an empty icons object'
# quiet is left out of the shipped file, the way order and rows are: its defaults hide nothing, so a
# file that spelled them out would only be three zeros to keep in step with the segment list.
Confirm-True ($c.Quiet.cost -eq 0 -and $c.Quiet.context -eq 0 -and $c.Quiet.limits -eq 0) 'shipped config: quiet is off for all three'
Confirm-True ($null -eq $shippedJson.PSObject.Properties['quiet']) 'shipped config: the file itself has no quiet key'

Write-Host '== unit: icons' -ForegroundColor Cyan
# Get-IconSet turns the built-in table and the config's overrides into one glyph per name, and the
# script assigns its $icon* constants from that set.
$defaultIcons = Get-IconDefault
Confirm-Equal $defaultIcons.Count 19 'icons: nineteen built-in glyphs'
Confirm-Equal $defaultIcons.pr 0xF407 'icons: pr is the pull-request glyph'
Confirm-Equal $defaultIcons.model 0xF06A9 'icons: model is the robot'
Confirm-Equal $defaultIcons.worktree 0xF04C1 'icons: worktree is the source fork'
# Every built-in code point has to survive the guards a config value goes through. The glyph a config
# may put in its place is held to that bar, so the one it replaces cannot sit below it.
foreach ($e in $defaultIcons.GetEnumerator()) {
    Confirm-Equal (Read-CodePoint ('{0:X}' -f $e.Value)) $e.Value "icons: the built-in $($e.Key) code point passes the guards"
}
$set = Get-IconSet @{ Icons = @{} }
Confirm-Equal $set.Count 19 'icons: one glyph per name'
Confirm-Equal $set.pr $iconPr 'icons: no override gives the built-in pr glyph'
Confirm-Equal $set.model $iconModel 'icons: no override gives the built-in model glyph'
Confirm-Equal $set.dirty $iconDirty 'icons: no override gives the built-in pencil'
$set = Get-IconSet @{ Icons = @{ model = 0xF0E7; dirty = 0x2588 } }
Confirm-Equal $set.model ([char]::ConvertFromUtf32(0xF0E7)) 'icons: model override is the bolt'
Confirm-Equal $set.dirty ([char]::ConvertFromUtf32(0x2588)) 'icons: dirty override is the block'
Confirm-Equal $set.context ([char]::ConvertFromUtf32(0xF035B)) 'icons: an unmentioned name keeps its glyph'
Confirm-Equal $set.limits $iconLimit 'icons: limits is the tachometer'
Confirm-Equal (Get-IconSet @{}).model $iconModel 'icons: a config without an Icons table gives the built-ins'
$set = Get-IconSet (Read-StatusConfig (Write-TempConfig 'icons-bolt.json' '{ "icons": { "model": "F0E7" } }'))
Confirm-Equal $set.model ([char]::ConvertFromUtf32(0xF0E7)) 'icons: the bolt in the config reaches the set'
Confirm-Equal $set.fast ([char]::ConvertFromUtf32(0xF0E7)) 'icons: the fast badge keeps its own bolt'
# Every form Read-CodePoint accepts, and a sample of what it refuses. Leading zeros are dropped before
# the six-digit cap, so a zero-padded form reads. A control character (00 to 1F, 7F to 9F) is refused:
# A is a newline and 1B a bare escape, either of which would break the line.
foreach ($row in @(@('F0E7', 0xF0E7), @('f0e7', 0xF0E7), @('U+F0E7', 0xF0E7), @('u+f0e7', 0xF0E7), @('0xF0E7', 0xF0E7), @('0XF0E7', 0xF0E7),
        @(' F0E7 ', 0xF0E7), @('E000', 0xE000), @('41', 0x41), @('0000F0E7', 0xF0E7), @('U+0000F0E7', 0xF0E7), @('0x0000F0E7', 0xF0E7),
        @('000000000041', 0x41), @('2588', 0x2588), @('4E2D', 0x4E2D), @('7E', 0x7E))) {
    Confirm-Equal (Read-CodePoint $row[0]) $row[1] "code point: '$($row[0])' reads as $($row[1])"
}
foreach ($bad in @('', ' ', 'zz', '110000', 'D800', 'DBFF', 'DC00', 'DFFF', '-1', 'F0 E7', '+F0E7', 'U+', '0x', '1234567', 'U+0xF0E7',
        '0', '0000', 'U+0000', 'A', '1B', '1F', '7F', '9B', '9F', '0x0A', $null, 61671, $true, @('F0E7'))) {
    Confirm-Equal (Read-CodePoint $bad) $null "code point: '$bad' is refused"
}
# A code point can reach the icons table from a repository's own config, so it is admitted only when it
# draws as one glyph standing by itself. A bidi override or isolate could reorder the visible line, a
# zero-width or format character hide part of it, a line or paragraph separator break it in two, a
# combining mark attach to whatever came before, a separator draw as blank, and a noncharacter or an
# unassigned code point has no glyph at all - the last two also make the width count, and the fitting
# that depends on it, a guess. Each is refused three ways: by the parser, in a parsed config, and in the
# glyph set the line is built from, which has to keep the built-in glyph.
$defaultModelGlyph = [char]::ConvertFromUtf32((Get-IconDefault).model)
foreach ($case in @(
        @{ Hex = '202E'; Name = 'a right-to-left override' }
        @{ Hex = '202D'; Name = 'a left-to-right override' }
        @{ Hex = '2066'; Name = 'a left-to-right isolate' }
        @{ Hex = '2069'; Name = 'a pop directional isolate' }
        @{ Hex = '200B'; Name = 'a zero width space' }
        @{ Hex = '200D'; Name = 'a zero width joiner' }
        @{ Hex = 'FEFF'; Name = 'a byte order mark' }
        @{ Hex = '2028'; Name = 'a line separator' }
        @{ Hex = '2029'; Name = 'a paragraph separator' }
        @{ Hex = '0301'; Name = 'a combining acute accent' }
        @{ Hex = 'FE0F'; Name = 'a variation selector' }
        @{ Hex = '20E3'; Name = 'an enclosing keycap' }
        @{ Hex = '0903'; Name = 'a spacing combining mark' }
        @{ Hex = '20'; Name = 'a space' }
        @{ Hex = 'A0'; Name = 'a no-break space' }
        @{ Hex = 'FDD0'; Name = 'a noncharacter in the arabic block' }
        @{ Hex = 'FFFE'; Name = 'a noncharacter' }
        @{ Hex = '1FFFE'; Name = 'a noncharacter above the basic plane' }
        @{ Hex = '10FFFF'; Name = 'the last code point, a noncharacter' }
        @{ Hex = 'D7FF'; Name = 'an unassigned code point' })) {
    Confirm-Equal (Read-CodePoint $case.Hex) $null "code point: $($case.Name) is refused"
    $c = Read-StatusConfig (Write-TempConfig "icons-refused-$($case.Hex).json" ('{ "icons": { "model": "' + $case.Hex + '" } }'))
    Confirm-Equal $c.Icons.Count 0 "config icons: $($case.Name) is skipped"
    Confirm-Equal (Get-IconSet $c).model $defaultModelGlyph "icons: $($case.Name) leaves the built-in glyph"
}
# The categories the refusal list holds, so a later edit cannot quietly drop one.
$refusedCategories = @(Get-IconRefusedCategory)
Confirm-Equal $refusedCategories.Count 10 'code point: ten refused categories'
foreach ($name in @('Control', 'Format', 'Surrogate', 'OtherNotAssigned', 'SpaceSeparator', 'LineSeparator', 'ParagraphSeparator', 'NonSpacingMark', 'SpacingCombiningMark', 'EnclosingMark')) {
    Confirm-True (([System.Globalization.UnicodeCategory] $name) -in $refusedCategories) "code point: $name is refused"
}
Confirm-True (([System.Globalization.UnicodeCategory]::PrivateUse) -notin $refusedCategories) 'code point: private use is allowed, which is where the Nerd Font glyphs live'

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
$oldTmp = Join-Path $stateDir 'gone.json.tmp'
$freshTmp = Join-Path $stateDir 'busy.json.tmp'
[System.IO.File]::WriteAllText($oldTmp, 'half')
[System.IO.File]::WriteAllText($freshTmp, 'half')
Write-StateFileAge $oldFile 25
Write-StateFileAge $oldTmp 25
Write-StateFileAge (Join-Path $stateDir 'abc.json') 25
Remove-Item -LiteralPath $stateStamp -Force
Write-SessionState 'abc' $state
Confirm-True (-not (Test-Path -LiteralPath $oldFile)) 'state sweep: day-old file deleted'
Confirm-True (Test-Path -LiteralPath $freshFile) 'state sweep: fresh file kept'
Confirm-True (-not (Test-Path -LiteralPath $oldTmp)) 'state sweep: a day-old .tmp an interrupted write left is deleted'
Confirm-True (Test-Path -LiteralPath $freshTmp) 'state sweep: a fresh .tmp, which another render may be writing, is kept'
Remove-Item -LiteralPath $freshTmp -Force
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

# A repo owner, a repo name and a directory name all come from outside this script, and any of the three
# can carry a right-to-left override that reorders the whole line. The character goes; the text stays.
$fRlo = [string][char]0x202E
$seg = Get-FolderSegment (Get-FolderPayload 'C:\src\demo' 'C:\src\demo' "oc${fRlo}to" "de${fRlo}mo") $cfgRepo
Confirm-Equal $seg.Text "$iconFolder octo/demo" 'folder override: the override is stripped from owner and name'
Confirm-Equal $seg.Short "$iconFolder demo" 'folder override: the short form is stripped too'
$seg = Get-FolderSegment (Get-FolderPayload "C:\src\de${fRlo}mo\to${fRlo}ols" "C:\src\de${fRlo}mo") $cfgRepo
Confirm-Equal $seg.Text "$iconFolder tools" 'folder override: the directory leaf is stripped as well'
$seg = Get-FolderSegment (Get-FolderPayload 'C:\src\demo\tools' 'C:\src\demo' $fRlo 'demo') $cfgRepo
Confirm-Equal $seg.Text "$iconFolder tools" 'folder override: an owner that is nothing but an override is not text, so the leaf stands in'

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
Confirm-Equal $pal.Inline.cached.Sgr '90' 'palette inline cached sgr'
Confirm-Equal $pal.Inline.cached.Fg 244 'palette inline cached fg'

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
# The helper owns the type gate: an array cast to [string] would join to "https://a b" and pass a scheme
# check, so the raw value is tested and anything but a string comes back unlinked.
Confirm-Equal (Format-Link @('https://example.com/a', 'b') 'abc') 'abc' 'link: an array url leaves the text alone'
Confirm-Equal (Format-Link 7 'abc') 'abc' 'link: a numeric url leaves the text alone'
Confirm-Equal (Format-Link 'https://example.com/a b' 'abc') 'abc' 'link: an embedded space leaves the text alone'
Confirm-Equal (Format-Link 'https://a b' 'abc') 'abc' 'link: a space in the host leaves the text alone'
Confirm-Equal (Format-Link 'https:example.com' 'abc') 'abc' 'link: a url that is not absolute leaves the text alone'
Confirm-Equal (Format-Link 'https://' 'abc') 'abc' 'link: a scheme with no host leaves the text alone'
$url2083 = 'https://example.com/' + ('x' * 2063)
Confirm-Equal $url2083.Length 2083 'link: cap fixture is 2083 characters'
Confirm-Equal (Format-Link $url2083 'abc') "$esc]8;;$url2083$esc\abc${linkClose}" 'link: 2083 characters is linked'
Confirm-Equal (Format-Link ($url2083 + 'x') 'abc') 'abc' 'link: 2084 characters leaves the text alone'

# The segment: glyph, space, #number, the whole text wrapped in the link, coloured by the review state.
$seg = Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $prUrl + '","review_state":"approved","kind":"pull_request"}'))
Confirm-Equal $seg.Name 'pr' 'pr approved: name'
Confirm-Equal $seg.Text "${linkOpen}$iconPr #12${linkClose}" 'pr approved: linked glyph and number'
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconPr #12" 'pr approved: plain text is the glyph and the number'
Confirm-Equal $seg.Role 'ok' 'pr approved: role ok'
Confirm-Equal $seg.Short $null 'pr approved: no short form'
Confirm-Equal $seg.Bold $false 'pr approved: not bold'
Confirm-Equal (Get-VisibleWidth $seg.Text) (Get-VisibleWidth "$iconPr #12") 'pr approved: the link adds no width'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $prUrl + '","review_state":"changes requested"}'))).Role 'bad' 'pr changes requested: role bad'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $prUrl + '","review_state":"CHANGES_REQUESTED"}'))).Role 'bad' 'pr CHANGES_REQUESTED: underscore and case folded, role bad'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $prUrl + '","review_state":"Approved"}'))).Role 'ok' 'pr Approved: case folded, role ok'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $prUrl + '","review_state":"review_required"}'))).Role 'dim' 'pr unknown state: role dim'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $prUrl + '","review_state":null}'))).Role 'dim' 'pr null state: role dim'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $prUrl + '"}'))).Role 'dim' 'pr missing state: role dim'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $prUrl + '","review_state":["approved"]}'))).Role 'dim' 'pr array state: role dim'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $prUrl + '","review_state":7}'))).Role 'dim' 'pr numeric state: role dim'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $prUrl + '","review_state":{"state":"approved"}}'))).Role 'dim' 'pr object state: role dim'
$seg = Get-PrSegment (Get-JsonPayload 'pr' '{"number":12,"review_state":"approved"}')
Confirm-Equal $seg.Text "$iconPr #12" 'pr missing url: text unlinked'
Confirm-Equal $seg.Role 'ok' 'pr missing url: still coloured by the state'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' '{"number":12,"url":"ftp://example.com/12"}')).Text "$iconPr #12" 'pr ftp url: text unlinked'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' '{"number":12,"url":7}')).Text "$iconPr #12" 'pr numeric url: text unlinked'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' '{"number":12,"url":["https://example.com/a","b"]}')).Text "$iconPr #12" 'pr array url: text unlinked'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' '{"number":345,"url":"HTTPS://github.com/octo/demo/pull/345"}')).Text "$esc]8;;HTTPS://github.com/octo/demo/pull/345$esc\$iconPr #345${linkClose}" 'pr upper-case scheme: linked'
Confirm-Equal (Get-PrSegment ([pscustomobject]@{ model = @{ display_name = 'M' } })) $null 'pr missing object: null'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' 'null')) $null 'pr null object: null'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' '"open"')) $null 'pr object is a string: null'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('[{"number":12,"url":"' + $prUrl + '"}]'))) $null 'pr object is an array: null'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' '12')) $null 'pr object is a number: null'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"url":"' + $prUrl + '","review_state":"approved"}'))) $null 'pr missing number: null even with a url'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":"12","url":"' + $prUrl + '"}'))) $null 'pr string number: null'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12.5,"url":"' + $prUrl + '"}'))) $null 'pr float number: null'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":0,"url":"' + $prUrl + '"}'))) $null 'pr zero number: null'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":-3,"url":"' + $prUrl + '"}'))) $null 'pr negative number: null'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":2147483648,"url":"' + $prUrl + '"}'))) $null 'pr number above Int32: null'
Confirm-Equal (Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12.0,"url":"' + $prUrl + '"}'))).Text "${linkOpen}$iconPr #12${linkClose}" 'pr whole float number: rendered as 12'

# The renderer wraps the link in the segment's colour codes in both styles, so the link sits inside the
# colour and the terminal keeps the background through it.
$segPr = Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $prUrl + '","review_state":"approved"}'))
Confirm-Equal (Format-Line @($segPr) 'plain') "$esc[32m${linkOpen}$iconPr #12${linkClose}$esc[0m" 'pr plain: colour outside the link'
Confirm-Equal (Format-Line @($segPr) 'powerline') "$esc[0;48;5;28;38;5;231m ${linkOpen}$iconPr #12${linkClose} $esc[0m$esc[38;5;28m$arrow$esc[0m" 'pr powerline: block colour outside the link'

# The URL never counts towards the width, so a long one fits where a short one does and is shed in the
# same place. The fit set is 44 wide; the pr segment adds five cells and a separator, 52, and 49 needs
# only the limits short form, so at both widths the pr segment must survive whatever the URL length.
$longUrl = 'https://github.com/octo/demo/pull/12?' + ('x' * 263)
Confirm-Equal $longUrl.Length 300 'pr long url: 300 characters'
$fitShort = @(Get-FitSegmentSet) + @(Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $prUrl + '","review_state":"approved"}')))
$fitLong = @(Get-FitSegmentSet) + @(Get-PrSegment (Get-JsonPayload 'pr' ('{"number":12,"url":"' + $longUrl + '","review_state":"approved"}')))
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
# The builders read the colour bands from the config; this is the default pair, and $lowCfg a custom one.
$bandCfg = @{ Thresholds = @{ Warn = 60; Bad = 85 } }
$lowCfg = @{ Thresholds = @{ Warn = 20; Bad = 40 } }

$seg = Get-ContextSegment (Get-ContextPayload 32) $bandCfg
$bar32 = ($blockFull * 3) + ($blockLight * 7)
Confirm-True $seg.Text.StartsWith("$iconCtx 32% ") 'context 32: text prefix'
Confirm-True $seg.Text.Contains($bar32) 'context 32: bar is 3 full + 7 light'
Confirm-Equal $seg.Role 'ok' 'context 32: role'
Confirm-Equal $seg.Short "$iconCtx 32% $bar32" 'context 32: short'

$seg = Get-ContextSegment (Get-ContextPayload 110) $bandCfg
$bar100 = $blockFull * 10
Confirm-True $seg.Text.StartsWith("$iconCtx 100% ") 'context 110: clamped text prefix'
Confirm-True $seg.Text.Contains($bar100) 'context 110: bar is 10 full blocks'
Confirm-Equal $seg.Role 'bad' 'context 110: role'

$seg = Get-ContextSegment (Get-ContextPayload -5) $bandCfg
$bar0 = $blockLight * 10
Confirm-True $seg.Text.StartsWith("$iconCtx 0% ") 'context -5: clamped text prefix'
Confirm-True $seg.Text.Contains($bar0) 'context -5: bar is 10 light blocks'
Confirm-Equal $seg.Role 'ok' 'context -5: role'

Confirm-Equal (Get-ContextSegment (Get-ContextPayload 64) $bandCfg).Role 'warn' 'context 64: role'
Confirm-Equal (Get-ContextSegment (Get-ContextPayload 85) $bandCfg).Role 'bad' 'context 85: role'

Confirm-Equal (Get-ContextSegment ([pscustomobject]@{}) $bandCfg) $null 'context: missing context_window'

# A 1M window moves the colour bands to 70 and 90, so the same percentage is a different colour there.
function Get-WideContextPayload([double] $Pct) {
    return [pscustomobject]@{ context_window = [pscustomobject]@{ used_percentage = $Pct; total_input_tokens = 650000; total_output_tokens = 0; context_window_size = 1000000 } }
}
Confirm-Equal (Get-ContextSegment (Get-WideContextPayload 65) $bandCfg).Role 'ok' 'context 1M 65: role ok, not warn'
Confirm-Equal (Get-ContextSegment (Get-WideContextPayload 75) $bandCfg).Role 'warn' 'context 1M 75: role warn'
Confirm-Equal (Get-ContextSegment (Get-WideContextPayload 92) $bandCfg).Role 'bad' 'context 1M 92: role bad'
Confirm-Equal (Get-ContextSegment (Get-ContextPayload 65) $bandCfg).Role 'warn' 'context 200k 65: role stays warn'
Confirm-True (Get-ContextSegment (Get-WideContextPayload 65) $bandCfg).Text.Contains("650k/$(K 1000000)") 'context 1M 65: counts'

# Custom thresholds move the bands on the standard window. The 1M window keeps its own 70 and 90:
# those bands come from the window size, not from the user's taste for a 200k one.
Confirm-Equal (Get-ContextSegment (Get-ContextPayload 32) $lowCfg).Role 'warn' 'context 32 at 20/40: warn'
Confirm-Equal (Get-ContextSegment (Get-ContextPayload 45) $lowCfg).Role 'bad' 'context 45 at 20/40: bad'
Confirm-Equal (Get-ContextSegment (Get-ContextPayload 10) $lowCfg).Role 'ok' 'context 10 at 20/40: ok'
Confirm-Equal (Get-ContextSegment (Get-ContextPayload 20) $lowCfg).Role 'warn' 'context 20 at 20/40: warn at the edge'
Confirm-Equal (Get-ContextSegment (Get-WideContextPayload 65) $lowCfg).Role 'ok' 'context 1M 65 at 20/40: the 1M bands stay 70 and 90'

# quiet.context hides the meter below the percentage it names. The comparison is on the clamped
# percentage the segment would show, and it is strict, so the threshold itself still renders.
$quietOff = @{ Thresholds = @{ Warn = 60; Bad = 85 }; Quiet = @{ cost = 0.0; context = 0.0; limits = 0.0 } }
$quiet30 = @{ Thresholds = @{ Warn = 60; Bad = 85 }; Quiet = @{ cost = 0.0; context = 30.0; limits = 0.0 } }
Confirm-True ("$((Get-ContextSegment (Get-ContextPayload 8) $quietOff).Text)".StartsWith("$iconCtx 8% ")) 'context quiet 0: an 8% meter is built'
Confirm-Equal (Get-ContextSegment (Get-ContextPayload 8) $quiet30) $null 'context quiet 30: an 8% meter is hidden'
Confirm-Equal (Get-ContextSegment (Get-ContextPayload 29) $quiet30) $null 'context quiet 30: 29% is still below the line'
Confirm-True ($null -ne (Get-ContextSegment (Get-ContextPayload 30) $quiet30)) 'context quiet 30: 30% is on the line and stays'
# A payload at -5 clamps to 0 and is compared as 0, so a quiet of 0 keeps it and any threshold hides it.
Confirm-True ($null -ne (Get-ContextSegment (Get-ContextPayload -5) $quietOff)) 'context quiet 0: a clamped 0% meter is still built'
Confirm-Equal (Get-ContextSegment (Get-ContextPayload -5) $quiet30) $null 'context quiet 30: a clamped 0% meter is hidden'
# $bandCfg carries no Quiet table at all, which is what an older config object looks like to the guard.
Confirm-True ($null -ne (Get-ContextSegment (Get-ContextPayload 0) $bandCfg)) 'context quiet: a config with no Quiet table hides nothing'

# Quiet never hides a segment carrying a warning or an error. With the bands moved down under the quiet
# threshold, a percentage the threshold would hide is already yellow or red, and the meter has to stay.
# Without the role check every one of these would vanish, which is the setting hiding its own alarm.
$quietAlarm = @{ Thresholds = @{ Warn = 20; Bad = 40 }; Quiet = @{ cost = 0.0; context = 50.0; limits = 0.0 } }
$seg = Get-ContextSegment (Get-ContextPayload 25) $quietAlarm
Confirm-Equal $seg.Role 'warn' 'context quiet 50 at 20/40: 25% is warn'
Confirm-True ($null -ne $seg) 'context quiet 50: a warn meter below the threshold is kept'
$seg = Get-ContextSegment (Get-ContextPayload 45) $quietAlarm
Confirm-Equal $seg.Role 'bad' 'context quiet 50 at 20/40: 45% is bad'
Confirm-True ($null -ne $seg) 'context quiet 50: a bad meter below the threshold is kept'
Confirm-Equal (Get-ContextSegment (Get-ContextPayload 19) $quietAlarm) $null 'context quiet 50: 19% is still ok, so the threshold hides it'
Confirm-Equal (Get-ContextSegment (Get-ContextPayload 20) $quietAlarm).Role 'warn' 'context quiet 50: 20% is the first warn, kept at the edge of the band'
# The 1M window keeps its own 70 and 90 whatever the config says, and the rule follows those bands, not
# the config's, so a threshold above 70 cannot hide a wide window's yellow meter either.
$quietWide = @{ Thresholds = @{ Warn = 60; Bad = 85 }; Quiet = @{ cost = 0.0; context = 80.0; limits = 0.0 } }
$seg = Get-ContextSegment (Get-WideContextPayload 75) $quietWide
Confirm-Equal $seg.Role 'warn' 'context quiet 80 on a 1M window: 75% is warn on the fixed bands'
Confirm-True ($null -ne $seg) 'context quiet 80 on a 1M window: the warn meter is kept'
Confirm-Equal (Get-ContextSegment (Get-WideContextPayload 65) $quietWide) $null 'context quiet 80 on a 1M window: 65% is ok there, so the threshold hides it'

# ---- The cached suffix ----
# How much of this turn's input the prompt cache served, appended to the token counts. It is built
# from three token counts rather than read as a percentage, so these cases pin the arithmetic, the
# rounding rule and every way the block can be missing or malformed. The block is absent on older
# Claude Code versions and before the first API response, and then the segment has to render exactly
# the text it rendered before this feature existed.
$cacheCfg = @{ Style = 'plain'; Thresholds = @{ Warn = 60; Bad = 85 } }
$cachePl = @{ Style = 'powerline'; Thresholds = @{ Warn = 60; Bad = 85 } }
$barCache = ($blockFull * 3) + ($blockLight * 7)
# A 32% window with 64k of 200k used, so everything before the suffix is fixed and the assertions
# below can pin the whole rendered string. A $null field is left off the object rather than set to
# null, which is what a payload from an older Claude Code looks like.
function Get-CachePayload($Fresh, $Written, $Served, $Used) {
    $usage = [pscustomobject]@{}
    if ($null -ne $Fresh) { $usage | Add-Member -NotePropertyName input_tokens -NotePropertyValue $Fresh }
    if ($null -ne $Written) { $usage | Add-Member -NotePropertyName cache_creation_input_tokens -NotePropertyValue $Written }
    if ($null -ne $Served) { $usage | Add-Member -NotePropertyName cache_read_input_tokens -NotePropertyValue $Served }
    $tokens = if ($null -eq $Used) { 60000 } else { $Used }
    $out = if ($tokens -gt 0) { 4000 } else { 0 }
    return [pscustomobject]@{ context_window = [pscustomobject]@{
            used_percentage = 32; total_input_tokens = $tokens; total_output_tokens = $out
            context_window_size = 200000; current_usage = $usage
        }
    }
}
# The same window with no current_usage at all: the payload an older Claude Code sends.
function Get-NoUsagePayload {
    return [pscustomobject]@{ context_window = [pscustomobject]@{
            used_percentage = 32; total_input_tokens = 60000; total_output_tokens = 4000
            context_window_size = 200000
        }
    }
}
$counts32 = " $(K 64000)/$(K 200000)"
$plain32 = "$iconCtx 32% $barCache"

# 57500 of 62500, which is 92%. The suffix is a foreground-only run that hands the segment's own
# colour back, so a powerline background is not broken by a reset, and the whole string is pinned
# because Confirm-Equal compares ordinally: a stray format character between the counts and the
# suffix would slip past a culture comparison.
$seg = Get-ContextSegment (Get-CachePayload 2000 3000 57500) $cacheCfg
Confirm-Equal $seg.Text "$plain32$counts32 $esc[90m92% cached$esc[32m" 'context cached 92: the whole rendered text'
Confirm-Equal $seg.Text "$plain32$counts32 $(Format-Inline 'cached' '92% cached' 'ok' 'plain')" 'context cached 92: the suffix is the cached inline role'
Confirm-Equal $seg.Short $plain32 'context cached 92: the suffix never reaches Short'
Confirm-Equal $seg.Role 'ok' 'context cached 92: the suffix does not touch the role'
$seg = Get-ContextSegment (Get-CachePayload 2000 3000 57500) $cachePl
Confirm-Equal $seg.Text "$plain32$counts32 $esc[38;5;244m92% cached$esc[38;5;231m" 'context cached 92 in powerline: the suffix restores the segment foreground'
Confirm-Equal $seg.Short $plain32 'context cached 92 in powerline: the suffix never reaches Short'
# The same payload as JSON: ConvertFrom-Json hands the counts over as Int64 or Double, not Int32.
$seg = Get-ContextSegment (Get-JsonPayload 'context_window' '{"used_percentage":32,"total_input_tokens":60000,"total_output_tokens":4000,"context_window_size":200000,"current_usage":{"input_tokens":2000,"cache_creation_input_tokens":3000,"cache_read_input_tokens":57500}}') $cacheCfg
Confirm-Equal $seg.Text "$plain32$counts32 $esc[90m92% cached$esc[32m" 'context cached 92: a payload parsed from JSON renders the same text'

# The share goes through Get-WholePercent, the one rule behind every percentage this script prints,
# so it rounds half to even like the meter beside it: 92.5 gives 92 and 97.5 gives 98.
Confirm-True (Get-ContextSegment (Get-CachePayload 15 0 185) $cacheCfg).Text.EndsWith("92% cached$esc[32m") 'context cached: 92.5% rounds half to even, to 92'
Confirm-True (Get-ContextSegment (Get-CachePayload 5 0 195) $cacheCfg).Text.EndsWith("98% cached$esc[32m") 'context cached: 97.5% rounds half to even, to 98'

# Nothing served is the interesting case rather than one to hide: a cache that is not helping is why
# a small turn suddenly cost several cents. Everything served says so exactly.
Confirm-True (Get-ContextSegment (Get-CachePayload 0 5000 0) $cacheCfg).Text.EndsWith("0% cached$esc[32m") 'context cached: 5000 written and nothing read prints 0% cached'
Confirm-True (Get-ContextSegment (Get-CachePayload $null $null 1000) $cacheCfg).Text.EndsWith("100% cached$esc[32m") 'context cached: reads alone print 100% cached'

# Every way there is nothing to report renders exactly the segment this script printed before the
# suffix existed, Short form included. The negative rows are the sharpest of them: three counts of
# tokens cannot be negative, so a payload carrying one is refused whole rather than repaired into a
# number. The row that matters most is a negative input_tokens beside a positive read, which divides
# out above 100 and would print as a confident "100% cached" - a perfect cache hit invented from a
# malformed block. Each of the three fields gets its own row, because they reach the total by
# different routes: the read is in its own denominator, the other two are only in the denominator.
foreach ($row in @(
        @{ Label = 'the three fields are all zero'; Payload = (Get-CachePayload 0 0 0) }
        @{ Label = 'current_usage is an empty object'; Payload = (Get-CachePayload $null $null $null) }
        @{ Label = 'current_usage is absent'; Payload = (Get-NoUsagePayload) }
        @{ Label = 'the fields are text'; Payload = (Get-CachePayload 'lots' 'some' 'many') }
        @{ Label = 'the fields are booleans'; Payload = (Get-CachePayload $true $true $true) }
        @{ Label = 'the fields are arrays'; Payload = (Get-CachePayload @(1, 2) @(3) @(4)) }
        # The parentheses are load-bearing. A bare -500 in an argument position is a generic token,
        # not a number: PowerShell hands it over as the string "-500", Get-FiniteNumber refuses it,
        # and every row below would silently become "this field is text" - which a row above already
        # covers - instead of the negative count it is meant to be.
        @{ Label = 'input_tokens is negative and the total is still positive'; Payload = (Get-CachePayload (-100) 0 200) }
        @{ Label = 'cache_creation_input_tokens is negative and the total is still positive'; Payload = (Get-CachePayload 0 (-100) 200) }
        @{ Label = 'cache_read_input_tokens is negative and the total is still positive'; Payload = (Get-CachePayload 200 0 (-100)) }
        @{ Label = 'a negative count cancels the total to zero'; Payload = (Get-CachePayload (-500) 0 500) }
        @{ Label = 'a negative count drives the total below zero'; Payload = (Get-CachePayload (-900) 0 100) }
        @{ Label = 'every count is negative'; Payload = (Get-CachePayload (-1) (-2) (-3)) })) {
    $seg = Get-ContextSegment $row.Payload $cacheCfg
    Confirm-Equal $seg.Text "$plain32$counts32" "context cached: no suffix when $($row.Label)"
    Confirm-Equal $seg.Short $plain32 "context cached: the Short form is untouched when $($row.Label)"
}

# The scale has to happen after the division, not before it. Written as 100 * read / total, a read
# above about 1.8e306 overflows the multiply to Infinity before the divide runs, and Get-WholePercent's
# Int32 guard turns that into 2147483647% cached - a number no share can be, printed with confidence.
# These two rows sit either side of that boundary. The comment above Get-CacheShare once claimed the
# result was in range by arithmetic and no test covered the range, which is how it shipped.
$seg = Get-ContextSegment (Get-CachePayload 1 0 1e307) $cacheCfg
Confirm-Equal $seg.Text "$plain32$counts32 $esc[90m100% cached$esc[32m" 'context cached: a read past the overflow boundary still divides to 100, not to the Int32 ceiling'
$seg = Get-ContextSegment (Get-CachePayload 1 0 1e306) $cacheCfg
Confirm-Equal $seg.Text "$plain32$counts32 $esc[90m100% cached$esc[32m" 'context cached: and just under the boundary, unchanged'

# Short is what stage 1 of the fitting swaps in, so a segment carrying a suffix has to have one even
# when the payload gives it no token counts at all. Without this the suffix could never be shed.
$seg = Get-ContextSegment (Get-CachePayload 2000 3000 57500 0) $cacheCfg
Confirm-Equal $seg.Text "$plain32 $esc[90m92% cached$esc[32m" 'context cached with no token counts: the suffix still renders'
Confirm-Equal $seg.Short $plain32 'context cached with no token counts: there is still a Short form to shed it'
Confirm-Equal (Get-ContextSegment (Get-CachePayload 0 0 0 0) $cacheCfg).Short $null 'context cached: no counts and no suffix leaves no Short form'

# The whole reason the suffix goes through Format-Inline is the code it hands back: the segment's own
# foreground, not a reset, so a powerline background runs on under it. That restore is per role, so
# every band gets its own row in both styles. The bands are moved rather than the payload, so the text
# in front of the suffix is the same 32% in all six and the only thing under test is the colour.
# A red meter in powerline is the case where getting this wrong is most visible, and it is also the
# one the pinned string alone cannot catch: ok and bad share the foreground 231, so the role is
# asserted beside the text, and plain style, where ok is 32 and bad is 31, separates them.
foreach ($row in @(
        @{ Bands = @{ Warn = 60; Bad = 85 }; Role = 'ok'; Plain = '32'; Fg = 231 }
        @{ Bands = @{ Warn = 20; Bad = 40 }; Role = 'warn'; Plain = '33'; Fg = 16 }
        @{ Bands = @{ Warn = 20; Bad = 30 }; Role = 'bad'; Plain = '31'; Fg = 231 })) {
    foreach ($styleName in @('plain', 'powerline')) {
        $roleCfg = @{ Style = $styleName; Thresholds = $row.Bands }
        $seg = Get-ContextSegment (Get-CachePayload 2000 3000 57500) $roleCfg
        $open = if ($styleName -eq 'plain') { "$esc[90m" } else { "$esc[38;5;244m" }
        $back = if ($styleName -eq 'plain') { "$esc[$($row.Plain)m" } else { "$esc[38;5;$($row.Fg)m" }
        $roleLabel = "context cached on a $($row.Role) meter in $styleName"
        Confirm-Equal $seg.Role $row.Role "${roleLabel}: 32% bands as $($row.Role) here"
        Confirm-Equal $seg.Text "$plain32$counts32 ${open}92% cached$back" "${roleLabel}: the suffix hands the segment's own foreground back"
    }
}

# ORDER MATTERS in Get-ContextSegment: the percentage is normalised, the role is read from it, and
# only then does the quiet guard run. A suffix appended after all three cannot move any of them.
$quietCache = @{ Style = 'plain'; Thresholds = @{ Warn = 60; Bad = 85 }; Quiet = @{ cost = 0.0; context = 50.0; limits = 0.0 } }
Confirm-Equal (Get-ContextSegment (Get-CachePayload 2000 3000 57500) $quietCache) $null 'context cached: a cached suffix does not save a meter the quiet threshold hides'
$quietBands = @{ Style = 'plain'; Thresholds = @{ Warn = 20; Bad = 40 }; Quiet = @{ cost = 0.0; context = 50.0; limits = 0.0 } }
$seg = Get-ContextSegment (Get-CachePayload 2000 3000 57500) $quietBands
Confirm-Equal $seg.Role 'warn' 'context cached: the role is still read from the normalised percentage'
Confirm-True $seg.Text.EndsWith("92% cached$esc[33m") 'context cached: a warn meter hands its own colour back after the suffix'

Write-Host '== unit: cost' -ForegroundColor Cyan
$iconCost = [char]::ConvertFromUtf32(0xF0155)
function Get-CostPayload($Usd) { return [pscustomobject]@{ cost = [pscustomobject]@{ total_cost_usd = $Usd } } }
$quiet1 = @{ Thresholds = @{ Warn = 60; Bad = 85 }; Quiet = @{ cost = 1.0; context = 0.0; limits = 0.0 } }
Confirm-Equal (Get-CostSegment (Get-CostPayload 0.4312) $quietOff).Text ("$iconCost `$" + ('{0:N2}' -f 0.4312)) 'cost quiet 0: the figure is built'
Confirm-Equal (Get-CostSegment ([pscustomobject]@{}) $quietOff) $null 'cost: no cost object'
Confirm-Equal (Get-CostSegment (Get-CostPayload 0.4312) $quiet1) $null 'cost quiet 1: 0.4312 is hidden'
# The test is the raw number, not the rounded text: 0.996 prints as 1.00 and is still below 1.
Confirm-Equal (Get-CostSegment (Get-CostPayload 0.996) $quiet1) $null 'cost quiet 1: 0.996 rounds to the threshold and is still hidden'
Confirm-True ($null -ne (Get-CostSegment (Get-CostPayload 1) $quiet1)) 'cost quiet 1: exactly 1 is on the line and stays'
Confirm-Equal (Get-CostSegment (Get-CostPayload 12.5) $quiet1).Text ("$iconCost `$" + ('{0:N2}' -f 12.5)) 'cost quiet 1: 12.50 stays, text unchanged'
Confirm-True ($null -ne (Get-CostSegment (Get-CostPayload 0) $quietOff)) 'cost quiet 0: a zero cost is still built'
Confirm-True ($null -ne (Get-CostSegment (Get-CostPayload 0.02) $bandCfg)) 'cost quiet: a config with no Quiet table hides nothing'
# A cost that is not a number cannot be compared, so the guard stands aside and the builder does what
# it always did with it, which is to format whatever converts.
Confirm-True ($null -ne (Get-CostSegment (Get-CostPayload '0.50') $quiet1)) 'cost quiet 1: a string cost is not a figure the guard can read, so it is not hidden'

Write-Host '== unit: quiet guard' -ForegroundColor Cyan
$quietTable = @{ Quiet = @{ cost = 1.0; context = 30.0; limits = 0.0 } }
Confirm-True (Test-QuietValue $quietTable 'cost' 0.99) 'quiet guard: below the threshold is quiet'
Confirm-True (-not (Test-QuietValue $quietTable 'cost' 1.0)) 'quiet guard: equal to the threshold is not quiet'
Confirm-True (-not (Test-QuietValue $quietTable 'limits' 0)) 'quiet guard: a threshold of 0 hides nothing, not even 0'
Confirm-True (-not (Test-QuietValue $quietTable 'lines' 0)) 'quiet guard: a name the table does not carry hides nothing'
Confirm-True (-not (Test-QuietValue @{} 'cost' 0.5)) 'quiet guard: a config with no Quiet table hides nothing'
Confirm-True (-not (Test-QuietValue @{ Quiet = 30 } 'cost' 0.5)) 'quiet guard: a Quiet that is not a table hides nothing'
Confirm-True (-not (Test-QuietValue $quietTable 'cost' 'lots')) 'quiet guard: a value that is not a number hides nothing'
Confirm-True (-not (Test-QuietValue $quietTable 'cost' $true)) 'quiet guard: a boolean is not a number'
Confirm-True (-not (Test-QuietValue $quietTable 'cost' $null)) 'quiet guard: a missing value hides nothing'
Confirm-True (-not (Test-QuietValue $quietTable 'cost' ([double]::NaN))) 'quiet guard: NaN hides nothing'
Confirm-True (Test-QuietValue @{ Quiet = @{ cost = 1 } } 'COST' 0.5) 'quiet guard: the name is matched the way a hashtable matches, case and all'

Write-Host '== unit: threshold' -ForegroundColor Cyan
# Both bands are always passed; the function has no defaults, so a caller without a config is a bug
# the tests would see as everything red, not as a quiet 60/85.
Confirm-Equal (Get-ThresholdRole 65 60 85) 'warn' 'threshold 65 at 60/85: warn'
Confirm-Equal (Get-ThresholdRole 65 70 90) 'ok' 'threshold 65 at 70/90: ok'
Confirm-Equal (Get-ThresholdRole 70 70 90) 'warn' 'threshold 70 at 70/90: warn'
Confirm-Equal (Get-ThresholdRole 89 70 90) 'warn' 'threshold 89 at 70/90: warn'
Confirm-Equal (Get-ThresholdRole 92 70 90) 'bad' 'threshold 92 at 70/90: bad'
Confirm-Equal (Get-ThresholdRole 85 60 85) 'bad' 'threshold 85 at 60/85: bad'
Confirm-Equal (Get-ThresholdRole 59 60 85) 'ok' 'threshold 59 at 60/85: ok'
Confirm-Equal (Get-ThresholdRole 50 50 50) 'bad' 'threshold 50 at 50/50: bad, the warn band is empty'
Confirm-True (Test-WideWindow 1000000) 'wide window: 1000000'
Confirm-True (-not (Test-WideWindow 200000) -and -not (Test-WideWindow 1048576) -and -not (Test-WideWindow $null)) 'wide window: 200000, 1048576 and null are not'

# The one rule that turns a payload figure into the whole number the line shows, the bands are read
# against and an alarm is compared with. Half to even, which is what the [int] cast in the context
# segment and the bare [math]::Round in the limits segment both did before this had a name, so these
# cases also pin that nothing printed today moves. The Int32 ends are clamped rather than thrown at.
Confirm-Equal (Get-WholePercent 89) 89 'whole percent: a whole number is itself'
Confirm-Equal (Get-WholePercent 89.4) 89 'whole percent: 89.4 rounds down'
Confirm-Equal (Get-WholePercent 89.5) 90 'whole percent: 89.5 goes to the even 90'
Confirm-Equal (Get-WholePercent 89.6) 90 'whole percent: 89.6 rounds up'
Confirm-Equal (Get-WholePercent 89.9) 90 'whole percent: 89.9 rounds up'
Confirm-Equal (Get-WholePercent 90.4) 90 'whole percent: 90.4 rounds down'
Confirm-Equal (Get-WholePercent 90.5) 90 'whole percent: 90.5 stays at the even 90, it does not go to 91'
Confirm-Equal (Get-WholePercent 91.5) 92 'whole percent: 91.5 goes up to the even 92'
Confirm-Equal (Get-WholePercent 0.5) 0 'whole percent: 0.5 goes to the even 0'
Confirm-Equal (Get-WholePercent -0.6) -1 'whole percent: a negative rounds away from zero the same way'
Confirm-Equal (Get-WholePercent 1e300) ([int]::MaxValue) 'whole percent: a figure past Int32 clamps instead of throwing'
Confirm-Equal (Get-WholePercent -1e300) ([int]::MinValue) 'whole percent: and the same at the bottom'
# The two segments that print a percentage go through it, so the rule cannot drift apart between them.
$roundCfg = @{ Style = 'plain'; Thresholds = @{ Warn = 60; Bad = 85 } }
Confirm-True ((Get-ContextSegment (Get-JsonPayload 'context_window' '{"used_percentage":89.6}') $roundCfg).Text.StartsWith("$iconCtx 90%")) 'whole percent: the context meter prints 89.6 as 90%'
Confirm-True ((Get-ContextSegment (Get-JsonPayload 'context_window' '{"used_percentage":89.4}') $roundCfg).Text.StartsWith("$iconCtx 89%")) 'whole percent: and 89.4 as 89%'
Confirm-Equal (Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":89.6}}') $roundCfg).Text "$iconLimit 5h 90%" 'whole percent: the limits segment prints 89.6 as 90% too'

Write-Host '== unit: alarm' -ForegroundColor Cyan
# Test-AlarmState answers one question from the payload and the config alone - no segment record, no
# segment order, no rendering - so the model segment and anything else that wants the same answer
# (#24's taskbar progress) read it the same way. The contract: $true when alarm.context is above 0 and
# context_window.used_percentage is at or above it, or when alarm.limits is above 0 and either
# rate_limits.five_hour.used_percentage or .seven_day.used_percentage is at or above it; $false for
# everything else, a payload with no rate_limits and a config with no Alarm table included.
# Both sides of every level are pinned: 89 against 90 has to be false and 90 has to be true, so an
# operator moved from -ge to -gt (or the level read as -gt 0 dropped) fails here rather than passing.
function Get-AlarmPayload($Context, $FiveHour, $SevenDay) {
    $p = [pscustomobject]@{ context_window = [pscustomobject]@{ used_percentage = $Context } }
    if ($null -ne $FiveHour -or $null -ne $SevenDay) {
        $rl = [pscustomobject]@{}
        if ($null -ne $FiveHour) { $rl | Add-Member -NotePropertyName five_hour -NotePropertyValue ([pscustomobject]@{ used_percentage = $FiveHour }) }
        if ($null -ne $SevenDay) { $rl | Add-Member -NotePropertyName seven_day -NotePropertyValue ([pscustomobject]@{ used_percentage = $SevenDay }) }
        $p | Add-Member -NotePropertyName rate_limits -NotePropertyValue $rl
    }
    return $p
}
$alarmOn = @{ Alarm = @{ Context = 90; Limits = 90 } }
# The level helper on its own: a level of 0 or below, a level that is not a number, and a value that is
# not a number are each no alarm, and the comparison is on the raw percentage rather than a rounded one.
Confirm-True (Test-AlarmLevel 90 90) 'alarm level: 90 at 90 fires'
Confirm-True (-not (Test-AlarmLevel 89 90)) 'alarm level: 89 at 90 does not fire'
Confirm-True (Test-AlarmLevel 90.0 90) 'alarm level: a whole double fires'
# The comparison is on the whole number the segments print, not the raw figure. A raw comparison would
# leave 89.6 under a 90 alarm while the context meter beside it already reads a red 90%.
Confirm-True (Test-AlarmLevel 89.5 90) 'alarm level: 89.5 prints as 90% and fires the 90 alarm'
Confirm-True (Test-AlarmLevel 89.6 90) 'alarm level: 89.6 prints as 90% and fires the 90 alarm'
Confirm-True (Test-AlarmLevel 89.9 90) 'alarm level: 89.9 prints as 90% and fires the 90 alarm'
Confirm-True (-not (Test-AlarmLevel 89.4 90)) 'alarm level: 89.4 prints as 89% and does not fire'
Confirm-True (Test-AlarmLevel 90.4 90) 'alarm level: 90.4 prints as 90% and fires'
Confirm-True (Test-AlarmLevel 90.5 90) 'alarm level: 90.5 prints as 90% by half-to-even and fires'
Confirm-True (-not (Test-AlarmLevel 90.5 91)) 'alarm level: 90.5 prints as 90% and does not reach a 91 alarm'
Confirm-True (Test-AlarmLevel 90.5 90.4) 'alarm level: a fractional level is rounded the same way, so 90.4 is a 90 alarm'
Confirm-True (-not (Test-AlarmLevel 0 0)) 'alarm level: a level of 0 is off, even at 0%'
Confirm-True (-not (Test-AlarmLevel 100 0)) 'alarm level: a level of 0 is off at 100%'
Confirm-True (-not (Test-AlarmLevel 100 -1)) 'alarm level: a negative level is off'
Confirm-True (-not (Test-AlarmLevel 100 $null)) 'alarm level: a missing level is off'
Confirm-True (-not (Test-AlarmLevel 100 '90')) 'alarm level: a level that is a string is off'
Confirm-True (-not (Test-AlarmLevel $null 90)) 'alarm level: a null percentage does not fire'
Confirm-True (-not (Test-AlarmLevel '95' 90)) 'alarm level: a percentage that is a string does not fire'
Confirm-True (-not (Test-AlarmLevel $true 90)) 'alarm level: a boolean percentage does not fire'
Confirm-True (-not (Test-AlarmLevel @(95) 90)) 'alarm level: an array percentage does not fire'
Confirm-True (-not (Test-AlarmLevel ([double]::NaN) 90)) 'alarm level: NaN does not fire'
Confirm-True (Test-AlarmLevel 100 100) 'alarm level: 100 at 100 fires'
Confirm-True (-not (Test-AlarmLevel 100 101)) 'alarm level: a level above 100 can never fire'
# The whole state, through the payload shape the script really sees.
Confirm-True (-not (Test-AlarmState (Get-AlarmPayload 89) $alarmOn)) 'alarm state: context 89 at 90 is no alarm'
Confirm-True (Test-AlarmState (Get-AlarmPayload 90) $alarmOn) 'alarm state: context 90 at 90 alarms'
Confirm-True (Test-AlarmState (Get-AlarmPayload 100) $alarmOn) 'alarm state: context 100 alarms'
Confirm-True (-not (Test-AlarmState (Get-AlarmPayload $null) $alarmOn)) 'alarm state: a null context percentage is no alarm'
Confirm-True (-not (Test-AlarmState (Get-AlarmPayload 99) @{ Alarm = @{ Context = 0; Limits = 0 } })) 'alarm state: 99% with both alarms at 0 is no alarm'
Confirm-True (-not (Test-AlarmState (Get-AlarmPayload 0) @{ Alarm = @{ Context = 0; Limits = 0 } })) 'alarm state: 0% with both alarms at 0 is no alarm'
Confirm-True (Test-AlarmState (Get-AlarmPayload 10 95 10) $alarmOn) 'alarm state: the 5-hour limit alone alarms'
Confirm-True (Test-AlarmState (Get-AlarmPayload 10 10 95) $alarmOn) 'alarm state: the 7-day limit alone alarms'
Confirm-True (-not (Test-AlarmState (Get-AlarmPayload 10 89 89) $alarmOn)) 'alarm state: both limits at 89 is no alarm'
Confirm-True (Test-AlarmState (Get-AlarmPayload 10 90 10) $alarmOn) 'alarm state: the 5-hour limit at 90 alarms'
Confirm-True (-not (Test-AlarmState (Get-AlarmPayload 10 95 95) @{ Alarm = @{ Context = 90; Limits = 0 } })) 'alarm state: limits at 0 leaves the rate limits alone'
Confirm-True (Test-AlarmState (Get-AlarmPayload 95 10 10) @{ Alarm = @{ Context = 90; Limits = 0 } }) 'alarm state: limits at 0 does not disable the context alarm'
Confirm-True (-not (Test-AlarmState (Get-AlarmPayload 95 10 10) @{ Alarm = @{ Context = 0; Limits = 90 } })) 'alarm state: context at 0 leaves the context window alone'
Confirm-True (-not (Test-AlarmState (Get-AlarmPayload 10 $null $null) $alarmOn)) 'alarm state: a payload with no rate_limits is no alarm'
Confirm-True (-not (Test-AlarmState ([pscustomobject]@{}) $alarmOn)) 'alarm state: an empty payload is no alarm'
Confirm-True (-not (Test-AlarmState (Get-AlarmPayload 95) @{})) 'alarm state: a config with no Alarm table is no alarm'
Confirm-True (-not (Test-AlarmState (Get-AlarmPayload 95) @{ Alarm = @{ Context = 101; Limits = 101 } })) 'alarm state: a level above 100 never fires'
# The shipped default is 90 for both, so a payload at 90 alarms straight out of the box.
Confirm-True (Test-AlarmState (Get-AlarmPayload 90) (Get-DefaultStatusConfig)) 'alarm state: the built-in default alarms at 90'
Confirm-True (-not (Test-AlarmState (Get-AlarmPayload 89) (Get-DefaultStatusConfig))) 'alarm state: the built-in default does not alarm at 89'
Confirm-True (Test-AlarmState (Get-AlarmPayload 10 90 10) (Get-DefaultStatusConfig)) 'alarm state: the built-in default alarms on a 90% rate limit'
# The whole point of the shared rule: whatever percentage the context meter prints is the percentage the
# alarm compares, so the two can never contradict each other at the boundary. Both window sizes, because
# a 1M window keeps its own 70 and 90 bands and the alarm has to line up with those too. A raw
# comparison passes the 89.4 and 90 rows and fails every fractional one.
# bad is put at 90 so the meter's own band and the alarm sit on the same figure and any disagreement is
# a real one; a 1M window already has 90 as its fixed band whatever the config says.
$agreeCfg = @{ Style = 'plain'; Thresholds = @{ Warn = 60; Bad = 90 }; Alarm = @{ Context = 90; Limits = 0 } }
foreach ($row in @(
        @{ Pct = 89.4; Whole = 89; Alarm = $false }
        @{ Pct = 89.5; Whole = 90; Alarm = $true }
        @{ Pct = 89.6; Whole = 90; Alarm = $true }
        @{ Pct = 89.9; Whole = 90; Alarm = $true }
        @{ Pct = 90.0; Whole = 90; Alarm = $true }
        @{ Pct = 90.5; Whole = 90; Alarm = $true }
        @{ Pct = 91.5; Whole = 92; Alarm = $true })) {
    foreach ($size in @(200000, 1000000)) {
        $rawPct = $row.Pct.ToString([cultureinfo]::InvariantCulture)
        $d = Get-JsonPayload 'context_window' ('{"used_percentage":' + $rawPct + ',"context_window_size":' + $size + '}')
        $seg = Get-ContextSegment $d $agreeCfg
        $agreeLabel = "$rawPct% on a $size window"
        Confirm-True ($seg.Text.StartsWith("$iconCtx $($row.Whole)%")) "${agreeLabel}: the meter prints $($row.Whole)%"
        Confirm-Equal (Test-AlarmState $d $agreeCfg) $row.Alarm "${agreeLabel}: the 90 alarm agrees with the printed $($row.Whole)%"
        # And the segment's own band is read against that same number, so a red meter beside a cyan
        # model, or the other way round, cannot happen at the line the alarm sits on.
        Confirm-Equal ($seg.Role -eq 'bad') $row.Alarm "${agreeLabel}: the meter's own colour and the alarm reach 90 together"
    }
}

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
# The alarm changes the role and nothing else. Get-ModelPayload sits at 65%, so the alarm is decided by
# the config here: 66 fires, 65 fires (at or above), 64 does not, and the text is the same either way.
function Get-ModelAlarmConfig($At, [string] $Style = 'plain') { return @{ Style = $Style; Alarm = @{ Context = $At; Limits = 0 } } }
Confirm-Equal (Get-ModelSegment (Get-ModelPayload 200000) (Get-ModelAlarmConfig 66)).Role 'model' 'model alarm: 65% under a 66 alarm keeps the model role'
Confirm-Equal (Get-ModelSegment (Get-ModelPayload 200000) (Get-ModelAlarmConfig 65)).Role 'bad' 'model alarm: 65% at a 65 alarm takes the bad role'
Confirm-Equal (Get-ModelSegment (Get-ModelPayload 200000) (Get-ModelAlarmConfig 64)).Role 'bad' 'model alarm: 65% over a 64 alarm takes the bad role'
Confirm-Equal (Get-ModelSegment (Get-ModelPayload 200000) (Get-ModelAlarmConfig 0)).Role 'model' 'model alarm: an alarm of 0 keeps the model role'
Confirm-Equal (Get-ModelSegment (Get-ModelPayload 200000) (Get-ModelAlarmConfig 60)).Text "$iconModel Fable 5.1" 'model alarm: the text is unchanged'
Confirm-Equal (Get-ModelSegment (Get-ModelPayload 200000) (Get-ModelAlarmConfig 60)).Bold $true 'model alarm: still bold'
Confirm-Equal (Get-ModelSegment (Get-ModelPayload 200000) (Get-ModelAlarmConfig 60)).Short $null 'model alarm: still no short form'
# The 1M marker goes through Format-Inline, which restores the segment's own foreground after the muted
# run. That has to be the alarm's colour, not the model's, or the name would be red and everything after
# the marker cyan. This is what a role changed after the text was built would get wrong.
$seg = Get-ModelSegment (Get-ModelPayload 1000000) (Get-ModelAlarmConfig 60)
Confirm-Equal $seg.Role 'bad' 'model alarm 1M: role'
Confirm-True ($seg.Text.Contains("$esc[22;36m1M$esc[31m")) 'model alarm 1M: the plain marker restores red, not cyan'
Confirm-True (-not $seg.Text.Contains("$esc[1;36m")) 'model alarm 1M: no bold cyan is left anywhere in the text'
Confirm-True ((ConvertTo-PlainText $seg.Text).EndsWith("$iconModel Fable 5.1 1M")) 'model alarm 1M: the plain text is unchanged'
$seg = Get-ModelSegment (Get-ModelPayload 1000000) (Get-ModelAlarmConfig 60 'powerline')
Confirm-True ($seg.Text.Contains("$esc[38;5;152m1M$esc[38;5;231m")) 'model alarm 1M: the powerline marker restores 231, which both roles share'
# The rate limits reach the model segment too, with no context percentage in the payload at all.
$limitPayload = [pscustomobject]@{ model = [pscustomobject]@{ display_name = 'Fable 5.1' }
    rate_limits = [pscustomobject]@{ five_hour = [pscustomobject]@{ used_percentage = 95 } } }
Confirm-Equal (Get-ModelSegment $limitPayload @{ Style = 'plain'; Alarm = @{ Context = 0; Limits = 90 } }).Role 'bad' 'model alarm: a rate limit alone turns the model red'
Confirm-Equal (Get-ModelSegment $limitPayload @{ Style = 'plain'; Alarm = @{ Context = 0; Limits = 96 } }).Role 'model' 'model alarm: a rate limit under the level leaves the model alone'
# Format-Line has to paint what the role says, in both styles, or the role change would be invisible.
$alarmSeg = @{ Name = 'model'; Text = 'M'; Short = $null; Role = 'bad'; Bold = $true }
Confirm-Equal (Format-Line @($alarmSeg) 'plain') "$esc[31mM$esc[0m" 'model alarm: plain renders SGR 31'
Confirm-True ((Format-Line @($alarmSeg) 'powerline').StartsWith("$esc[0;1;48;5;160;38;5;231m M ")) 'model alarm: powerline renders a bold block on background 160'

Write-Host '== unit: pace' -ForegroundColor Cyan
# Get-PaceArrow takes the current epoch as a third parameter defaulting to the clock, so the arithmetic
# can be pinned to the second here. That matters: an epoch derived from an earlier reading of the clock
# is one second out whenever the second ticks in between, so a case meant to sit on 16200 seconds left
# would quietly exercise 16199 instead and pass either way. Every eligibility limit is a whole second,
# and the fraction it stands for is not exact in binary - 1 - 16200 / 18000 is 0.09999999999999998 - so
# these are the boundaries a regression moves. Cases are written as the seconds still to run, which is
# what the function tests: 16200 left is a tenth of the 18000-second window gone, the earliest reading
# worth anything, and 0 left is the window spent. The default clock is covered on its own at the end.
$paceUp = [char]::ConvertFromUtf32(0x2191)
$paceFlat = [char]::ConvertFromUtf32(0x2192)
$paceClock = 1700000000
Confirm-Equal (Get-VisibleWidth $paceUp) 1 'pace: the up arrow is a plain character, one cell wide'
Confirm-Equal (Get-VisibleWidth $paceFlat) 1 'pace: the right arrow is a plain character, one cell wide'
$paceTable = @(
    @{ Label = '16201s left, one second short of a tenth gone'; Left = 16201; Used = 5; Arrow = $null }
    @{ Label = '16200s left, exactly a tenth gone: the earliest reading there is'; Left = 16200; Used = 5; Arrow = $paceFlat; Red = $false }
    @{ Label = '16200s left, 10% used: exactly 100% projected holds'; Left = 16200; Used = 10; Arrow = $paceFlat; Red = $false }
    @{ Label = '16200s left, 10.1% used: 101% projected points up'; Left = 16200; Used = 10.1; Arrow = $paceUp; Red = $false }
    @{ Label = '16200s left, 11.9% used: 119% projected is not red yet'; Left = 16200; Used = 11.9; Arrow = $paceUp; Red = $false }
    @{ Label = '16200s left, 12% used: exactly 120% projected turns red'; Left = 16200; Used = 12; Arrow = $paceUp; Red = $true }
    @{ Label = 'half gone, 40% used: 80% projected'; Left = 9000; Used = 40; Arrow = $paceFlat; Red = $false }
    @{ Label = 'half gone, 50% used: exactly on pace holds'; Left = 9000; Used = 50; Arrow = $paceFlat; Red = $false }
    @{ Label = 'half gone, 51% used: 102% projected points up'; Left = 9000; Used = 51; Arrow = $paceUp; Red = $false }
    @{ Label = 'half gone, 59.9% used: 119.8% projected is not red yet'; Left = 9000; Used = 59.9; Arrow = $paceUp; Red = $false }
    @{ Label = 'half gone, 60% used: exactly 120% projected turns red'; Left = 9000; Used = 60; Arrow = $paceUp; Red = $true }
    @{ Label = 'half gone, 80% used: 160% projected'; Left = 9000; Used = 80; Arrow = $paceUp; Red = $true }
    @{ Label = 'half gone, 80% as a JSON double'; Left = 9000; Used = 80.0; Arrow = $paceUp; Red = $true }
    @{ Label = '1s left, the last reading of a window'; Left = 1; Used = 50; Arrow = $paceFlat; Red = $false }
    @{ Label = '0s left, the window spent to the second'; Left = 0; Used = 50; Arrow = $null }
    @{ Label = '1s past the reset'; Left = -1; Used = 50; Arrow = $null }
    @{ Label = '100s past the reset'; Left = -100; Used = 80; Arrow = $null }
    @{ Label = '17500s left, inside the first half hour'; Left = 17500; Used = 90; Arrow = $null }
    @{ Label = "sample 06's 2100 epoch, a window that has not opened"; Left = 4102444800 - 1700000000; Used = 80; Arrow = $null }
)
foreach ($paceRow in $paceTable) {
    $pace = Get-PaceArrow ($paceClock + $paceRow.Left) $paceRow.Used $paceClock
    if ($null -eq $paceRow.Arrow) {
        Confirm-True ($null -eq $pace) "pace: $($paceRow.Label) gives no arrow"
        continue
    }
    Confirm-Equal $pace.Arrow $paceRow.Arrow "pace: $($paceRow.Label) - arrow"
    Confirm-Equal $pace.Red $paceRow.Red "pace: $($paceRow.Label) - red flag"
    # Over is the overrun projection named rather than read off the glyph, so it has to agree with the
    # arrow on every row: the quiet guard reads Over, and the two drifting apart is what would let a
    # threshold hide a warning. Red is the far end of Over, so it can never be set without it.
    Confirm-Equal $pace.Over ($paceRow.Arrow -eq $paceUp) "pace: $($paceRow.Label) - over flag agrees with the arrow"
    Confirm-True (-not $paceRow.Red -or $pace.Over) "pace: $($paceRow.Label) - red implies over"
}
# A reset or a usage figure that is not a number at all. Get-FiniteNumber is the type gate, so a string
# that would cast, a boolean, an array, NaN and infinity all fall out here, as does a usage figure that
# is absent, zero or negative, where every projection is zero or worse and an arrow would be noise.
$noPaceTable = @(
    @{ Label = 'no reset at all'; Reset = $null; Used = 80 }
    @{ Label = 'a reset as text'; Reset = "$($paceClock + 9000)"; Used = 80 }
    @{ Label = 'a reset as a boolean'; Reset = $true; Used = 80 }
    @{ Label = 'a reset as an array'; Reset = @($paceClock + 9000); Used = 80 }
    @{ Label = 'a reset as NaN'; Reset = [double]::NaN; Used = 80 }
    @{ Label = 'a reset as infinity'; Reset = [double]::PositiveInfinity; Used = 80 }
    @{ Label = 'no usage figure'; Reset = $paceClock + 9000; Used = $null }
    @{ Label = 'nothing used yet'; Reset = $paceClock + 9000; Used = 0 }
    @{ Label = 'a negative usage figure'; Reset = $paceClock + 9000; Used = -5 }
    @{ Label = 'usage as text'; Reset = $paceClock + 9000; Used = '80' }
    @{ Label = 'usage as a boolean'; Reset = $paceClock + 9000; Used = $true }
    @{ Label = 'usage as an array'; Reset = $paceClock + 9000; Used = @(80) }
    @{ Label = 'usage as NaN'; Reset = $paceClock + 9000; Used = [double]::NaN }
)
foreach ($paceRow in $noPaceTable) {
    Confirm-True ($null -eq (Get-PaceArrow $paceRow.Reset $paceRow.Used $paceClock)) "pace: $($paceRow.Label) gives no arrow"
}
# The default clock, which is the only path the script itself ever takes, so the parameter above cannot
# become the only thing under test. Real time moves on between the epoch being built here and
# Get-PaceArrow reading it, always forward, which only raises the elapsed fraction and only lowers the
# projection. Every case below therefore sits clear of its threshold on the side drift carries it
# towards, well outside a second's worth of movement. The boundaries themselves are pinned above.
$pace = Get-PaceArrow ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 9000) 80
Confirm-Equal $pace.Arrow $paceUp 'pace on the default clock: half a window gone at 80% points up'
Confirm-Equal $pace.Red $true 'pace on the default clock: 160% projected is red'
Confirm-Equal $pace.Over $true 'pace on the default clock: 160% projected is an overrun'
$pace = Get-PaceArrow ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 9000) 40
Confirm-Equal $pace.Arrow $paceFlat 'pace on the default clock: half a window gone at 40% holds'
Confirm-Equal $pace.Red $false 'pace on the default clock: 80% projected is not red'
Confirm-Equal $pace.Over $false 'pace on the default clock: 80% projected is not an overrun'
Confirm-True ($null -eq (Get-PaceArrow ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 100) 80)) 'pace on the default clock: a reset already past gives no arrow'
Confirm-True ($null -eq (Get-PaceArrow ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 16400) 90)) 'pace on the default clock: the first half hour gives no arrow'
Confirm-True ($null -eq (Get-PaceArrow 4102444800 80)) 'pace on the default clock: a far-future reset gives no arrow'

Write-Host '== unit: limits' -ForegroundColor Cyan
# Resets in the past keep TimeLeft empty, so the text is deterministic. Every call passes a config,
# because the builder reads its colour bands from it.
$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":24,"resets_at":1700000000},"seven_day":{"used_percentage":41,"resets_at":1700000000},"spend_limit":{"used_percentage":62,"resets_at":1700000000}}') $bandCfg
Confirm-Equal $seg.Text "$iconLimit 5h 24% 7d 41% `$ 62%" 'limits all three: 5h, 7d, then spend'
Confirm-Equal $seg.Short "$iconLimit `$ 62%" 'limits all three: short keeps the spend figure that drives the colour'
Confirm-Equal $seg.Role 'warn' 'limits all three: role from the worst figure'

$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"spend_limit":{"used_percentage":62,"resets_at":1700000000}}') $bandCfg
Confirm-Equal $seg.Text "$iconLimit `$ 62%" 'limits spend alone: one figure, no 5h'
Confirm-True ($null -eq $seg.Short) 'limits spend alone: no short form'

$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":10,"resets_at":1700000000},"spend_limit":{"used_percentage":92,"resets_at":1700000000}}') $bandCfg
Confirm-Equal $seg.Text "$iconLimit 5h 10% `$ 92%" 'limits spend 92 with 5h 10: text'
Confirm-Equal $seg.Role 'bad' 'limits spend 92 with 5h 10: spend drives the colour'
Confirm-Equal $seg.Short "$iconLimit `$ 92%" 'limits spend 92 with 5h 10: short keeps the spend figure, not the 5h one'

$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":61,"resets_at":1700000000},"seven_day":{"used_percentage":12,"resets_at":1700000000}}') $bandCfg
Confirm-Equal $seg.Text "$iconLimit 5h 61% 7d 12%" 'limits spend_limit absent: unchanged text'
Confirm-Equal $seg.Role 'warn' 'limits spend_limit absent: role'
Confirm-Equal $seg.Short "$iconLimit 5h 61%" 'limits spend_limit absent: short keeps the 5h figure when it is the worst'

# The Short form keeps whichever figure drives the colour, so a fitted line never shows a red segment
# with a calm number on it. Below the warn line nothing drives the colour, and the first present figure
# stands in; a tie keeps render order (5h, 7d, then spend); the countdown never follows.
$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":10,"resets_at":1700000000},"seven_day":{"used_percentage":88,"resets_at":1700000000}}') $bandCfg
Confirm-Equal $seg.Text "$iconLimit 5h 10% 7d 88%" 'limits 7d worst: text'
Confirm-Equal $seg.Short "$iconLimit 7d 88%" 'limits 7d worst: short keeps the 7d figure'
Confirm-Equal $seg.Role 'bad' 'limits 7d worst: role'

$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":10,"resets_at":1700000000},"seven_day":{"used_percentage":41,"resets_at":1700000000},"spend_limit":{"used_percentage":30,"resets_at":1700000000}}') $bandCfg
Confirm-Equal $seg.Short "$iconLimit 5h 10%" 'limits all below warn: short is the first figure, not the largest'
Confirm-Equal $seg.Role 'ok' 'limits all below warn: role'

$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"seven_day":{"used_percentage":92,"resets_at":1700000000},"spend_limit":{"used_percentage":10,"resets_at":1700000000}}') $bandCfg
Confirm-Equal $seg.Text "$iconLimit 7d 92% `$ 10%" 'limits no 5h, 7d red: text'
Confirm-Equal $seg.Short "$iconLimit 7d 92%" 'limits no 5h, 7d red: short exists and keeps the 7d figure'
Confirm-Equal $seg.Role 'bad' 'limits no 5h, 7d red: role'

$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"seven_day":{"used_percentage":20,"resets_at":1700000000},"spend_limit":{"used_percentage":30,"resets_at":1700000000}}') $bandCfg
Confirm-Equal $seg.Text "$iconLimit 7d 20% `$ 30%" 'limits no 5h, all below warn: text'
Confirm-Equal $seg.Short "$iconLimit 7d 20%" 'limits no 5h, all below warn: short is the first present figure'
Confirm-Equal $seg.Role 'ok' 'limits no 5h, all below warn: role'

$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":70,"resets_at":1700000000},"seven_day":{"used_percentage":70,"resets_at":1700000000},"spend_limit":{"used_percentage":70,"resets_at":1700000000}}') $bandCfg
Confirm-Equal $seg.Text "$iconLimit 5h 70% 7d 70% `$ 70%" 'limits three-way tie: text'
Confirm-Equal $seg.Short "$iconLimit 5h 70%" 'limits three-way tie: 5h wins by render order'
Confirm-Equal $seg.Role 'warn' 'limits three-way tie: role'
$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"seven_day":{"used_percentage":70,"resets_at":1700000000},"spend_limit":{"used_percentage":70,"resets_at":1700000000}}') $bandCfg
Confirm-Equal $seg.Text "$iconLimit 7d 70% `$ 70%" 'limits 7d and spend tie: text'
Confirm-Equal $seg.Short "$iconLimit 7d 70%" 'limits 7d and spend tie: 7d wins by render order'
Confirm-Equal $seg.Role 'warn' 'limits 7d and spend tie: role'
$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":69.6,"resets_at":1700000000},"seven_day":{"used_percentage":70.4,"resets_at":1700000000}}') $bandCfg
Confirm-Equal $seg.Text "$iconLimit 5h 70% 7d 70%" 'limits tie after rounding: text rounds both to 70'
Confirm-Equal $seg.Short "$iconLimit 5h 70%" 'limits tie after rounding: 5h wins by render order'
Confirm-Equal $seg.Role 'warn' 'limits tie after rounding: role'

$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"seven_day":{"used_percentage":92,"resets_at":1700000000}}') $bandCfg
Confirm-Equal $seg.Text "$iconLimit 7d 92%" 'limits 7d alone: text'
Confirm-True ($null -eq $seg.Short) 'limits 7d alone: short would equal text, so none'

$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":70,"resets_at":4102444800},"seven_day":{"used_percentage":12,"resets_at":4102444800}}') $bandCfg
Confirm-True ($seg.Text.StartsWith("$iconLimit 5h 70% (") -and $seg.Text.EndsWith(') 7d 12%')) 'limits 5h worst with a live reset: text carries the countdown'
Confirm-Equal $seg.Short "$iconLimit 5h 70%" 'limits 5h worst with a live reset: short drops the countdown'

# quiet.limits is tested on the larger of the 5h and 7d figures, so a high 7-day window keeps the
# segment even when the 5-hour one is calm. The comparison is strict, and it happens after the figures
# are gathered, so a payload with no readable figure is already gone by then.
# The bands here are 95 and 99 on purpose. Under the default 60 and 85 every figure this block feeds in
# above 60 is already yellow, and the rule that quiet never hides a warning would keep the segment for
# that reason instead - the assertions would pass without the cutoff working at all. High bands leave
# every figure below 95 'ok', so the cutoff is the only thing deciding. The role rule gets its own
# cases further down, where it is what is under test.
$quiet70 = @{ Thresholds = @{ Warn = 95; Bad = 99 }; Quiet = @{ cost = 0.0; context = 0.0; limits = 70.0 } }
# The same high bands with the cutoff off, so the role a hidden segment WOULD have carried can be read
# from a call that returns one. Asserting Role on the hidden call would only ever read $null.
$bands95 = @{ Thresholds = @{ Warn = 95; Bad = 99 }; Quiet = @{ cost = 0.0; context = 0.0; limits = 0.0 } }
$limitsWorst61 = Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":61,"resets_at":1700000000},"seven_day":{"used_percentage":12,"resets_at":1700000000},"spend_limit":{"used_percentage":44,"resets_at":1700000000}}'
$limits7d88 = Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":24,"resets_at":1700000000},"seven_day":{"used_percentage":88,"resets_at":1700000000}}'
Confirm-Equal (Get-LimitsSegment $limitsWorst61 $quietOff).Text "$iconLimit 5h 61% 7d 12% `$ 44%" 'limits quiet 0: the segment is built'
Confirm-Equal (Get-LimitsSegment $limitsWorst61 $bands95).Role 'ok' 'limits quiet 70: under 95/99 a worst of 61 is ok, so only the cutoff is under test'
Confirm-Equal (Get-LimitsSegment $limitsWorst61 $quiet70) $null 'limits quiet 70: a window figure of 61 is hidden'
Confirm-Equal (Get-LimitsSegment $limits7d88 $quiet70).Text "$iconLimit 5h 24% 7d 88%" 'limits quiet 70: a 7d figure of 88 keeps the segment, calm 5h and all'
# The same payload under the default bands: 61 is yellow there, and a yellow segment is an alarm the
# cutoff may not touch. Same threshold, same figures, opposite answer, decided by the role alone.
$quiet70Default = @{ Thresholds = @{ Warn = 60; Bad = 85 }; Quiet = @{ cost = 0.0; context = 0.0; limits = 70.0 } }
Confirm-Equal (Get-LimitsSegment $limitsWorst61 $quiet70Default).Role 'warn' 'limits quiet 70 at 60/85: a worst of 61 is warn'
Confirm-True ($null -ne (Get-LimitsSegment $limitsWorst61 $quiet70Default)) 'limits quiet 70 at 60/85: the warn segment is kept despite being under the cutoff'
# The spend limit drives the colour but not the quiet cutoff: the key is a threshold on how much of an
# allowance is gone, and a spend limit is not one of those. $quiet70's high bands are what make this
# provable - under 60/85 a 90% spend is red and the role rule would keep the segment either way.
$limitsSpend90 = Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":10,"resets_at":1700000000},"spend_limit":{"used_percentage":90,"resets_at":1700000000}}'
Confirm-Equal (Get-LimitsSegment $limitsSpend90 $bands95).Role 'ok' 'limits quiet 70: a 90% spend under 95/99 bands is still ok, so only the cutoff is under test'
Confirm-Equal (Get-LimitsSegment $limitsSpend90 $quiet70) $null 'limits quiet 70: a 5h of 10 is hidden even beside a 90% spend, which is not a window'
Confirm-Equal (Get-LimitsSegment $limitsSpend90 $quietOff).Text "$iconLimit 5h 10% `$ 90%" 'limits quiet 0: the same payload builds both figures'
# The spend figure still drives the colour, which is what $worst is for and what the split leaves alone.
Confirm-Equal (Get-LimitsSegment $limitsSpend90 $quietOff).Role 'bad' 'limits: a 90% spend still drives the colour under the default bands'
# Neither window present: nothing for the cutoff to compare, so the segment is kept whatever it says.
$limitsSpendOnly = Get-JsonPayload 'rate_limits' '{"spend_limit":{"used_percentage":44,"resets_at":1700000000}}'
Confirm-Equal (Get-LimitsSegment $limitsSpendOnly $quiet70).Text "$iconLimit `$ 44%" 'limits quiet 70: a payload with only a spend limit has no window to compare and is kept'
$limitsSpendOnlyHigh = Get-JsonPayload 'rate_limits' '{"spend_limit":{"used_percentage":90,"resets_at":1700000000}}'
Confirm-True ($null -ne (Get-LimitsSegment $limitsSpendOnlyHigh $quiet70)) 'limits quiet 70: a high spend alone is kept too, for the same reason'
# The 7d window counts towards the cutoff even when the 5h one is calm, because both are allowances.
$limits7dOnlyHigh = Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":10,"resets_at":1700000000},"seven_day":{"used_percentage":75,"resets_at":1700000000}}'
Confirm-True ($null -ne (Get-LimitsSegment $limits7dOnlyHigh $quiet70)) 'limits quiet 70: a 7d of 75 is a window above the cutoff and keeps the segment'

# Quiet never hides a segment carrying a warning or an error. Two ways a limits segment can carry one.
# First the role: with the bands under the cutoff, a figure the cutoff would hide is already coloured.
$quietRoleAlarm = @{ Thresholds = @{ Warn = 20; Bad = 40 }; Quiet = @{ cost = 0.0; context = 0.0; limits = 70.0 } }
$limits5h25 = Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":25,"resets_at":1700000000}}'
Confirm-Equal (Get-LimitsSegment $limits5h25 $quietRoleAlarm).Role 'warn' 'limits quiet 70 at 20/40: a 5h of 25 is warn'
Confirm-True ($null -ne (Get-LimitsSegment $limits5h25 $quietRoleAlarm)) 'limits quiet 70: a warn segment below the cutoff is kept'
$limits5h45 = Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":45,"resets_at":1700000000}}'
Confirm-Equal (Get-LimitsSegment $limits5h45 $quietRoleAlarm).Role 'bad' 'limits quiet 70 at 20/40: a 5h of 45 is bad'
Confirm-True ($null -ne (Get-LimitsSegment $limits5h45 $quietRoleAlarm)) 'limits quiet 70: a bad segment below the cutoff is kept'
$limits5h15 = Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":15,"resets_at":1700000000}}'
Confirm-Equal (Get-LimitsSegment $limits5h15 $quietRoleAlarm) $null 'limits quiet 70: a 5h of 15 is still ok there, so the cutoff hides it'

# Then the pace arrow, which is the dangerous one: early in a five-hour window a LOW current percentage
# is exactly what projects an overrun, so a cutoff set above it would hide the warning at the moment it
# is worth most. These resets are built from the live clock, because Get-LimitsSegment calls
# Get-PaceArrow without a clock parameter. A tenth of the window gone (16200 seconds left) makes the
# projection ten times the current figure; real time only moves the reading further into the window,
# which lowers the projection, so each case sits far clear of the limit it is on the safe side of.
$paceNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
function Get-PaceLimitsPayload([double] $Used, [long] $Left) {
    return Get-JsonPayload 'rate_limits' ('{"five_hour":{"used_percentage":' + ([string]::Format([cultureinfo]::InvariantCulture, '{0}', $Used)) + ',"resets_at":' + ($paceNow + $Left) + '}}')
}
# 15% a tenth of the way in projects 150%: a red up arrow on a segment whose role is still ok.
# Every text check below reads the segment through "$($seg.Text)", which is the empty string when the
# builder returned nothing. A regression that hides one of these then fails the assertion by name
# instead of throwing on a null and taking the rest of the file down with it.
$paceRed = Get-PaceLimitsPayload 15 16200
$seg = Get-LimitsSegment $paceRed $quietOff
Confirm-Equal $seg.Role 'ok' 'limits pace red: 15% current is still ok under the default bands'
Confirm-True ("$($seg.Text)".Contains($paceUp)) 'limits pace red: the segment carries the up arrow'
Confirm-True ("$($seg.Text)".Contains("$esc[31m")) 'limits pace red: the arrow is red'
$seg = Get-LimitsSegment $paceRed $quietRoleAlarm
Confirm-True ($null -ne $seg) 'limits quiet 70: a red overrun projection keeps a 15% segment the cutoff would hide'
Confirm-True ("$($seg.Text)".Contains($paceUp)) 'limits quiet 70: and the arrow it was kept for is on the line'
# 11% a tenth of the way in projects 110%: an up arrow that is not red yet. Still a warning, still kept.
$paceUpNotRed = Get-PaceLimitsPayload 11 16200
$seg = Get-LimitsSegment $paceUpNotRed $quietOff
Confirm-True ("$($seg.Text)".Contains($paceUp)) 'limits pace up: the segment carries the up arrow'
Confirm-True (-not "$($seg.Text)".Contains("$esc[31m")) 'limits pace up: 110% projected is not red'
Confirm-True ($null -ne (Get-LimitsSegment $paceUpNotRed $quietRoleAlarm)) 'limits quiet 70: an overrun projection that is not red yet still keeps the segment'
# 5% a tenth of the way in projects 50%: a flat arrow, which is not a warning, so the cutoff applies.
$paceFlatLow = Get-PaceLimitsPayload 5 16200
Confirm-True ("$((Get-LimitsSegment $paceFlatLow $quietOff).Text)".Contains($paceFlat)) 'limits pace flat: 50% projected holds, so the arrow is flat'
Confirm-Equal (Get-LimitsSegment $paceFlatLow $quietRoleAlarm) $null 'limits quiet 70: a flat arrow is not a warning, so the cutoff still hides the segment'
# No arrow at all, inside the first tenth of the window, and the cutoff applies as it always did.
Confirm-Equal (Get-LimitsSegment (Get-PaceLimitsPayload 15 17500) $quietRoleAlarm) $null 'limits quiet 70: no arrow yet inside the first half hour, so the cutoff hides it'
$limits70 = Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":70,"resets_at":1700000000}}'
Confirm-True ($null -ne (Get-LimitsSegment $limits70 $quiet70)) 'limits quiet 70: exactly 70 is on the line and stays'
$limits69 = Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":69,"resets_at":1700000000}}'
Confirm-Equal (Get-LimitsSegment $limits69 $quiet70) $null 'limits quiet 70: 69 is still below the line'
# The worst figure is the rounded one, so 69.6 reads as 70 in the comparison as well as in the text.
$limits696 = Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":69.6,"resets_at":1700000000}}'
Confirm-True ($null -ne (Get-LimitsSegment $limits696 $quiet70)) 'limits quiet 70: 69.6 rounds to 70 and stays'
Confirm-True ($null -ne (Get-LimitsSegment $limitsWorst61 $bandCfg)) 'limits quiet: a config with no Quiet table hides nothing'

$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":61,"resets_at":1700000000},"seven_day":{"used_percentage":12,"resets_at":1700000000},"spend_limit":{"used_percentage":null,"resets_at":null}}') $bandCfg
Confirm-Equal $seg.Text "$iconLimit 5h 61% 7d 12%" 'limits spend_limit null percentage: unchanged text'

Confirm-True ($null -eq (Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":null},"seven_day":{"used_percentage":null},"spend_limit":{"used_percentage":null}}') $bandCfg)) 'limits all null: segment omitted'
Confirm-True ($null -eq (Get-LimitsSegment ([pscustomobject]@{}) $bandCfg)) 'limits: missing rate_limits'

# The config's thresholds colour the rate limits too, whatever the window size, and the Short form
# follows the colour they give: 24 is the worst figure and above a warn of 20, so it stays.
$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":24,"resets_at":1700000000},"seven_day":{"used_percentage":12,"resets_at":1700000000}}') $lowCfg
Confirm-Equal $seg.Role 'warn' 'limits 5h 24 at 20/40: warn'
Confirm-Equal $seg.Text "$iconLimit 5h 24% 7d 12%" 'limits 5h 24 at 20/40: text unchanged'
Confirm-Equal $seg.Short "$iconLimit 5h 24%" 'limits 5h 24 at 20/40: short keeps the figure behind the colour'
Confirm-Equal (Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":45,"resets_at":1700000000}}') $lowCfg).Role 'bad' 'limits 5h 45 at 20/40: bad'
# Below the custom warn line nothing drives the colour, and the first present figure stands in.
$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' '{"five_hour":{"used_percentage":10,"resets_at":1700000000},"seven_day":{"used_percentage":15,"resets_at":1700000000}}') $lowCfg
Confirm-Equal $seg.Role 'ok' 'limits 10 and 15 at 20/40: ok'
Confirm-Equal $seg.Short "$iconLimit 5h 10%" 'limits 10 and 15 at 20/40: short is the first figure'

# The pace arrow rides on the 5-hour figure alone, between the percentage and the countdown. Every case
# below is clock-relative for the reason the pace group gives, and each epoch is taken on the line that
# uses it so drift stays under a second. A live reset is what makes the arrow appear at all, which is
# why none of the fixed-epoch cases above grew one: 1700000000 is long past and 4102444800 is a window
# that has not opened.
$paceCfg = @{ Thresholds = @{ Warn = 60; Bad = 85 }; Style = 'plain' }
$pacePlCfg = @{ Thresholds = @{ Warn = 60; Bad = 85 }; Style = 'powerline' }
$paceLive = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 9000
$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' ('{"five_hour":{"used_percentage":40,"resets_at":' + $paceLive + '},"seven_day":{"used_percentage":12,"resets_at":1700000000}}')) $paceCfg
Confirm-True ($seg.Text.StartsWith("$iconLimit 5h 40% $paceFlat (") -and $seg.Text.EndsWith(') 7d 12%')) 'limits on pace: the right arrow sits after the figure and before the countdown'
Confirm-Equal $seg.Short "$iconLimit 5h 40%" 'limits on pace: the short form drops the arrow with the countdown'
Confirm-Equal $seg.Role 'ok' 'limits on pace: the arrow does not touch the role'

$paceLive = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 9000
$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' ('{"five_hour":{"used_percentage":55,"resets_at":' + $paceLive + '},"seven_day":{"used_percentage":12,"resets_at":1700000000}}')) $paceCfg
Confirm-True ($seg.Text.StartsWith("$iconLimit 5h 55% $paceUp (")) 'limits overrunning under 120: a plain up arrow, no colour'
Confirm-Equal $seg.Role 'ok' 'limits overrunning under 120: the role is still the worse of the figures'

# At 80% with half the window gone the projection is 160, so the arrow goes through the removed inline
# role and restores the segment's own foreground - the warn one here, which the 80 earns on its own.
$paceLive = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 9000
$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' ('{"five_hour":{"used_percentage":80,"resets_at":' + $paceLive + '},"seven_day":{"used_percentage":12,"resets_at":1700000000}}')) $paceCfg
Confirm-True ($seg.Text.StartsWith("$iconLimit 5h 80% $(Format-Inline 'removed' $paceUp 'warn' 'plain') (")) 'limits well over pace: the up arrow is red and hands the warn colour back'
Confirm-Equal $seg.Role 'warn' 'limits well over pace: the role is the worse figure, not the projection'
Confirm-Equal $seg.Short "$iconLimit 5h 80%" 'limits well over pace: the short form keeps the figure without the arrow'

$paceLive = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 9000
$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' ('{"five_hour":{"used_percentage":80,"resets_at":' + $paceLive + '},"seven_day":{"used_percentage":12,"resets_at":1700000000}}')) $pacePlCfg
Confirm-True ($seg.Text.StartsWith("$iconLimit 5h 80% $(Format-Inline 'removed' $paceUp 'warn' 'powerline') (")) 'limits well over pace in powerline: the red arrow restores the segment foreground'

# The 7-day figure never gets an arrow, whatever its reset says: one payload cannot pace a week.
$paceLive = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 9000
$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' ('{"seven_day":{"used_percentage":80,"resets_at":' + $paceLive + '},"spend_limit":{"used_percentage":80,"resets_at":' + $paceLive + '}}')) $paceCfg
Confirm-Equal $seg.Text "$iconLimit 7d 80% `$ 80%" 'limits without a 5h figure: no arrow on the 7d or the spend figure'

# A reset under a minute out leaves TimeLeft empty, so the arrow is the only thing the Text has that the
# Short form does not. Fifty seconds is far enough from both ends - past the reset, or past the minute
# TimeLeft needs - that no plausible drift moves the answer.
$paceEnd = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 50
$seg = Get-LimitsSegment (Get-JsonPayload 'rate_limits' ('{"five_hour":{"used_percentage":55,"resets_at":' + $paceEnd + '}}')) $paceCfg
Confirm-Equal $seg.Text "$iconLimit 5h 55% $paceFlat" 'limits at the end of a window: the arrow with no countdown behind it'
Confirm-Equal $seg.Short "$iconLimit 5h 55%" 'limits at the end of a window: a short form exists purely to drop the arrow'

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
# git permits a right-to-left override in a ref name, so a repository can ship a branch whose name
# reorders the status line. It is taken out at the source, where the probe reads it.
$r = Read-PorcelainStatus ("## fea$([char]0x202E)ture...origin/feature`n")
Confirm-Equal $r.Branch 'feature' 'porcelain: an override in a ref name is stripped where the branch is read'
Confirm-Equal (Read-PorcelainStatus "fatal: not a git repository`n") $null 'porcelain: no header'
Confirm-Equal (Read-PorcelainStatus '') $null 'porcelain: empty'

Write-Host '== unit: payload text' -ForegroundColor Cyan
Confirm-Equal (Test-PayloadText 'octo') $true 'payload text: a string with content is text'
Confirm-Equal (Test-PayloadText '   ') $false 'payload text: whitespace only is not'
Confirm-Equal (Test-PayloadText '') $false 'payload text: empty string is not'
Confirm-Equal (Test-PayloadText $null) $false 'payload text: null is not'
Confirm-Equal (Test-PayloadText 7) $false 'payload text: a number is not'
Confirm-Equal (Test-PayloadText @('octo')) $false 'payload text: an array is not'
# A control character in the text would carry an escape sequence onto the line through the folder
# segment's owner and name, so such a string is not text either.
Confirm-Equal (Test-PayloadText "oc${esc}[31mto") $false 'payload text: a string with ESC inside is not'
Confirm-Equal (Test-PayloadText "octo$([char]0x9B)") $false 'payload text: a string with a C1 control is not'
Confirm-Equal (Test-PayloadText "oct$([char]0xE9)") $true 'payload text: a non-control non-ASCII character is still text'
# The Unicode Format characters are the other half of the rule, and they get the other answer. A
# right-to-left override reorders everything drawn after it without being an escape at all, so it may
# never reach the line; but it is taken out of the value rather than costing the whole value, because a
# branch name is worth more with one invisible character missing than it is missing altogether. What
# Test-PayloadText answers is whether anything visible is left once they are gone.
$rlo = [string][char]0x202E
$isolate = [string][char]0x2066
Confirm-Equal (Format-PayloadText 'octo') 'octo' 'payload strip: a clean value comes back unchanged'
Confirm-Equal (Format-PayloadText "oc${rlo}to") 'octo' 'payload strip: a right-to-left override comes out'
Confirm-Equal (Format-PayloadText ("a$([char]0x200D)b$([char]0xFEFF)c" + $isolate + 'd')) 'abcd' 'payload strip: joiner, byte order mark and isolate all come out'
Confirm-Equal (Format-PayloadText "oct$([char]0xE9)") "oct$([char]0xE9)" 'payload strip: an accented letter is not a format character'
Confirm-Equal (Format-PayloadText "oc${esc}to") "oc${esc}to" 'payload strip: an escape is not a format character, Test-PayloadText refuses it instead'
Confirm-Equal (Format-PayloadText '') '' 'payload strip: an empty string strips to an empty string'
Confirm-Equal (Test-PayloadText "oc${rlo}to") $true 'payload text: a value with an override in it is still text, the override is what goes'
Confirm-Equal (Test-PayloadText $rlo) $false 'payload text: a value that is nothing but an override is not text'
Confirm-Equal (Test-PayloadText ($rlo + '  ' + $isolate)) $false 'payload text: format characters around whitespace are not text either'
Confirm-Equal (Test-PayloadText ("$([char]0x200B)$([char]0xFEFF)")) $false 'payload text: a zero width space and a byte order mark leave nothing visible'

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
$s = Read-PayloadStatus ('{"branch":"fea\u202eture","status":"clean"}' | ConvertFrom-Json)
Confirm-Equal $s.Branch 'feature' 'payload status: an override in the branch is stripped, the name survives'
Confirm-Equal (Read-PayloadStatus ('{"branch":"\u202e\u2066"}' | ConvertFrom-Json)) $null 'payload status: a branch that is nothing but format characters is no branch'
Confirm-Equal (Read-PayloadStatus ('{"branch":""}' | ConvertFrom-Json)) $null 'payload status: empty branch gives null'
Confirm-Equal (Read-PayloadStatus ('{}' | ConvertFrom-Json)) $null 'payload status: no branch gives null'

Write-Host '== unit: branch segment' -ForegroundColor Cyan
# The segment reads the git settings from the config it is handed, as Read-StatusConfig always supplies
# them, so every call here passes a full git table. The probe path is stood in for below; the payload
# path never reaches it.
$branchCfg = @{ Style = 'plain'; Git = (Get-DefaultGitConfig) }
$branchPowerlineCfg = @{ Style = 'powerline'; Git = (Get-DefaultGitConfig) }
$branchNoCacheCfg = @{ Style = 'plain'; Git = @{ TimeoutMs = 1500; CacheSeconds = 5; Cache = $false } }
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'main'; status = 'clean' } }) $branchCfg
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
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = ('{"modified":"2"}' | ConvertFrom-Json) } }) $branchCfg
Confirm-Equal $seg.Text "$iconBranch feature/x" 'branch payload string count: not a count, so clean with no pencil'
Confirm-Equal $seg.Role 'branch' 'branch payload string count: role'
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = ('{"modified":true}' | ConvertFrom-Json) } }) $branchCfg
Confirm-Equal $seg.Text "$iconBranch feature/x $iconDirty" 'branch payload boolean: pencil, no fabricated count'
Confirm-Equal $seg.Role 'warn' 'branch payload boolean: role'

$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = ('{"modified":2,"untracked":1}' | ConvertFrom-Json) } }) $branchCfg
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ~2 ?1 $iconDirty" 'branch payload modified and untracked: tilde then question mark'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[90m~2$esc[33m $esc[90m?1$esc[33m $iconDirty" 'branch payload modified and untracked: counts dim, warn colour restored'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch payload modified and untracked: short has no counts'
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = 'modified' } }) $branchCfg
Confirm-Equal $seg.Text "$iconBranch feature/x $iconDirty" 'branch payload string status: pencil only, no counts'
Confirm-Equal $seg.Role 'warn' 'branch payload string status: role'
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'feature/x'; status = ('{"conflicts":1}' | ConvertFrom-Json) } }) $branchCfg
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ${iconConflict}1 $iconDirty" 'branch payload conflict: conflict glyph and count before the pencil'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[31m${iconConflict}1$esc[33m $iconDirty" 'branch payload conflict: removed colour, warn colour restored'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch payload conflict: short has no conflict glyph'
Confirm-Equal $seg.Role 'warn' 'branch payload conflict: role'

Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{ git = @{} }))) 'branch payload git object with no branch: segment omitted'
Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{ git = @{ branch = '' } }))) 'branch payload empty branch: segment omitted'
$seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = "fea$([char]0x202E)ture"; status = 'clean' } }) $branchCfg
Confirm-Equal $seg.Text "$iconBranch feature" 'branch override: the override never reaches the line and the name still names the branch'
Confirm-True ($seg.Text -notmatch '\p{Cf}') 'branch override: nothing of the format category is left in the rendered text'
Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{ git = @{ branch = "$([char]0x202E)$([char]0x2066)" } }) $branchCfg)) 'branch override: a name that is nothing but format characters is no branch at all'

Write-Host '== unit: worktree name' -ForegroundColor Cyan
# The worktree badge's text comes from the payload and never from git. worktree.name when it is text;
# otherwise, when workspace.git_worktree marks the session as being in one, the last segment of
# worktree.path; otherwise nothing. The empty string is the third answer - "in a worktree, with no name
# to show" - and the builder draws the glyph on its own for it, so a $null and an empty string are told
# apart here rather than both being read as "no text". Each payload goes through ConvertFrom-Json, so a
# missing key is a real missing property, a JSON true a real boolean and a number a real number.
function Get-WorktreePayload([string] $Json) { return ($Json | ConvertFrom-Json) }
$worktreeTable = @(
    @{ Json = '{"worktree":{"name":"wt-review"}}'; Text = 'wt-review'; Label = 'a name on its own' }
    @{ Json = '{"worktree":{"name":"wt-review"},"workspace":{"git_worktree":false}}'; Text = 'wt-review'; Label = 'a name with the flag off' }
    @{ Json = '{"worktree":{"name":"  wt-review  "},"workspace":{"git_worktree":true}}'; Text = 'wt-review'; Label = 'a padded name is trimmed' }
    @{ Json = '{"worktree":{"name":"","path":"C:\\src\\wt-x"},"workspace":{"git_worktree":true}}'; Text = 'wt-x'; Label = 'an empty name falls back to the path leaf' }
    @{ Json = '{"worktree":{"path":"/home/j/src/wt-y/"},"workspace":{"git_worktree":true}}'; Text = 'wt-y'; Label = 'a posix path with a trailing slash' }
    @{ Json = '{"worktree":{"path":"C:\\src\\wt-b\\"},"workspace":{"git_worktree":true}}'; Text = 'wt-b'; Label = 'a windows path with a trailing separator' }
    @{ Json = '{"worktree":{"path":"wt-d"},"workspace":{"git_worktree":true}}'; Text = 'wt-d'; Label = 'a path with no separator at all' }
    @{ Json = '{"worktree":{"name":42,"path":"C:\\src\\wt-n"},"workspace":{"git_worktree":true}}'; Text = 'wt-n'; Label = 'a number is not a name' }
    @{ Json = '{"worktree":{"name":true},"workspace":{"git_worktree":true}}'; Text = ''; Label = 'a boolean is not a name' }
    @{ Json = '{"worktree":{"name":["a","b"]},"workspace":{"git_worktree":true}}'; Text = ''; Label = 'a list is not a name' }
    @{ Json = '{"worktree":{"name":" "},"workspace":{"git_worktree":true}}'; Text = ''; Label = 'a blank name' }
    @{ Json = '{"worktree":"wt-review","workspace":{"git_worktree":true}}'; Text = ''; Label = 'a worktree that is a string, not an object' }
    @{ Json = '{"worktree":null,"workspace":{"git_worktree":true}}'; Text = ''; Label = 'a null worktree with the flag on' }
    @{ Json = '{"worktree":{"name":null,"path":null},"workspace":{"git_worktree":true}}'; Text = ''; Label = 'both fields null with the flag on' }
    @{ Json = '{"workspace":{"git_worktree":true}}'; Text = ''; Label = 'the flag on its own' }
    @{ Json = '{"worktree":{},"workspace":{"git_worktree":true}}'; Text = ''; Label = 'an empty worktree object with the flag on' }
    @{ Json = '{"worktree":{"path":"/"},"workspace":{"git_worktree":true}}'; Text = ''; Label = 'a path with nothing but a separator' }
    @{ Json = '{"worktree":{"name":"wt\u001b[31mx"},"workspace":{"git_worktree":true}}'; Text = ''; Label = 'an escape in the name' }
    @{ Json = '{"worktree":{"path":"C:\\src\\wt\u000ay"},"workspace":{"git_worktree":true}}'; Text = ''; Label = 'a newline in the path' }
    @{ Json = '{"worktree":{"path":"C:\\src\\wt-z"},"workspace":{"git_worktree":false}}'; Text = $null; Label = 'a path with the flag off' }
    @{ Json = '{"worktree":{"path":"C:\\src\\wt-z"},"workspace":{"current_dir":"C:\\src"}}'; Text = $null; Label = 'a path with no flag at all' }
    @{ Json = '{"workspace":{"git_worktree":"true"}}'; Text = $null; Label = 'the flag as a string' }
    @{ Json = '{"workspace":{"git_worktree":1}}'; Text = $null; Label = 'the flag as a number' }
    @{ Json = '{"workspace":{"current_dir":"C:\\src"}}'; Text = $null; Label = 'a payload with no worktree in it' }
    @{ Json = '{}'; Text = $null; Label = 'an empty payload' }
)
foreach ($row in $worktreeTable) {
    $got = Get-WorktreeName (Get-WorktreePayload $row.Json)
    if ($null -eq $row.Text) {
        Confirm-True ($null -eq $got) "worktree name: $($row.Label) gives no badge, got '$got'"
    } else {
        # Ordinal, for the reason Confirm-Equal is: -ceq compares by culture, and a culture comparison
        # gives the Unicode Format characters no weight at all, so it would call "wt<U+202E>-x" and
        # "wt-x" the same string and say nothing about an override sitting in the badge.
        Confirm-True ($got -is [string] -and [string]::Equals($got, $row.Text, [System.StringComparison]::Ordinal)) "worktree name: $($row.Label) gives '$($row.Text)', got '$got'"
    }
}

# A worktree directory is named by whoever made the repository, the same argument the branch name gets,
# so an override in the name or in the path leaf is stripped and the badge still names the checkout.
Confirm-Equal (Get-WorktreeName (Get-WorktreePayload '{"worktree":{"name":"wt-re\u202eview"},"workspace":{"git_worktree":true}}')) 'wt-review' 'worktree name: an override in the name is stripped'
Confirm-Equal (Get-WorktreeName (Get-WorktreePayload '{"worktree":{"path":"C:\\src\\wt-\u202ey"},"workspace":{"git_worktree":true}}')) 'wt-y' 'worktree name: an override in the path leaf is stripped'
Confirm-Equal (Get-WorktreeName (Get-WorktreePayload '{"worktree":{"name":"  wt-\u200dq  "},"workspace":{"git_worktree":true}}')) 'wt-q' 'worktree name: a joiner comes out and the padding is still trimmed'
# The three answers survive a name that strips to nothing, and no fourth one is invented for it. A name
# with nothing visible left is not a name, so the chain carries on the way it does for a blank one.
Confirm-Equal (Get-WorktreeName (Get-WorktreePayload '{"worktree":{"name":"\u202e\u2066","path":"C:\\src\\wt-p"},"workspace":{"git_worktree":true}}')) 'wt-p' 'worktree name: a name that is nothing but format characters falls through to the path leaf'
$got = Get-WorktreeName (Get-WorktreePayload '{"worktree":{"name":"\u202e"},"workspace":{"git_worktree":true}}')
Confirm-True ($got -is [string] -and $got.Length -eq 0) "worktree name: a name that strips to nothing, with no path behind it, is the glyph on its own, got '$got'"
# And a directory whose own name is invisible: the leaf strips to nothing, which is the same answer.
$got = Get-WorktreeName (Get-WorktreePayload '{"worktree":{"path":"C:\\src\\\u202e"},"workspace":{"git_worktree":true}}')
Confirm-True ($got -is [string] -and $got.Length -eq 0) "worktree name: a path leaf that strips to nothing is the glyph on its own, not the parent directory, got '$got'"
# The flag is what says "in a worktree" at all, so with it off there is still no badge.
Confirm-True ($null -eq (Get-WorktreeName (Get-WorktreePayload '{"worktree":{"name":"\u202e"},"workspace":{"git_worktree":false}}'))) 'worktree name: a name that strips to nothing outside a worktree is still no badge'

# The badge on the segment: the glyph and the name between the branch name and the counts, so the
# identity of the checkout reads left to right and the pencil still lands last. The Short form is the
# one the counts already fold into - icon, name, pencil - so a narrow line sheds the worktree with them.
$seg = Get-BranchSegment ('{"git":{"branch":"main","status":"clean"},"worktree":{"name":"wt-review"}}' | ConvertFrom-Json) $branchCfg
Confirm-Equal $seg.Text "$iconHome main $iconWorktree wt-review" 'branch worktree: the glyph and the name after the branch'
Confirm-Equal $seg.Short "$iconHome main" 'branch worktree: short drops the badge'
Confirm-Equal $seg.Role 'branch' 'branch worktree: a worktree is not a reason to change the colour'
Confirm-Equal (Get-VisibleWidth $seg.Text) 18 'branch worktree: the badge measures as a glyph, a space and the name'
$seg = Get-BranchSegment ('{"git":{"branch":"feature/x","status":{"modified":2}},"worktree":{"name":"wt-review"},"workspace":{"git_worktree":true}}' | ConvertFrom-Json) $branchCfg
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x $iconWorktree wt-review ~2 $iconDirty" 'branch worktree dirty: badge, then the counts, then the pencil'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch worktree dirty: short is icon, name and pencil'
Confirm-Equal $seg.Role 'warn' 'branch worktree dirty: the pencil still sets the colour'
$seg = Get-BranchSegment ('{"git":{"branch":"main","status":"clean"},"worktree":{"path":"C:\\src\\wt-y"},"workspace":{"git_worktree":true}}' | ConvertFrom-Json) $branchCfg
Confirm-Equal $seg.Text "$iconHome main $iconWorktree wt-y" 'branch worktree path: the leaf stands in for the name'
$seg = Get-BranchSegment ('{"git":{"branch":"main","status":"clean"},"workspace":{"git_worktree":true}}' | ConvertFrom-Json) $branchCfg
Confirm-Equal $seg.Text "$iconHome main $iconWorktree" 'branch worktree bare: the glyph on its own'
Confirm-Equal (Get-VisibleWidth $seg.Text) 8 'branch worktree bare: the glyph is one cell and there is no trailing space'
$seg = Get-BranchSegment ('{"git":{"branch":"main","status":"clean"},"worktree":{"name":"wt-re\u202eview"}}' | ConvertFrom-Json) $branchCfg
Confirm-Equal $seg.Text "$iconHome main $iconWorktree wt-review" 'branch worktree override: the badge draws the name without the override'
Confirm-True ($seg.Text -notmatch '\p{Cf}') 'branch worktree override: no format character reaches the line'
Confirm-Equal (Get-VisibleWidth $seg.Text) 18 'branch worktree override: the width is what the badge draws, the same as the clean name'
$seg = Get-BranchSegment ('{"git":{"branch":"main","status":"clean"},"worktree":{"name":"\u202e"},"workspace":{"git_worktree":true}}' | ConvertFrom-Json) $branchCfg
Confirm-Equal $seg.Text "$iconHome main $iconWorktree" 'branch worktree override: a name that strips to nothing draws the glyph on its own'
Confirm-Equal (Get-VisibleWidth $seg.Text) 8 'branch worktree override: and no trailing space is left where the name was'
$seg = Get-BranchSegment ('{"git":{"branch":"main","status":"clean"}}' | ConvertFrom-Json) $branchCfg
Confirm-Equal $seg.Text "$iconHome main" 'branch without a worktree: exactly the text it printed before'
Confirm-True (-not $seg.Text.Contains($iconWorktree)) 'branch without a worktree: no fork glyph anywhere'

# A worktree name is the repository's word, not the user's: a directory called `wt-<ESC>[31m` would
# recolour the rest of the line, and one holding a newline would break it in two. The name and the path
# go through Test-PayloadText, the same guard the branch name and the repository name pass, so a
# hostile one leaves the glyph standing on its own rather than reaching the line. The cases below are
# what that guard refuses today; it may refuse more later, and none of them asks it to accept anything.
$seg = Get-BranchSegment ('{"git":{"branch":"main","status":"clean"},"worktree":{"name":"wt\u001b[31mx","path":"C:\\src\\wt\u000ay"},"workspace":{"git_worktree":true}}' | ConvertFrom-Json) $branchCfg
Confirm-Equal $seg.Text "$iconHome main $iconWorktree" 'branch worktree hostile: an escape in the name and a newline in the path leave the glyph alone'
Confirm-True ($seg.Text -notmatch '\p{Cc}') 'branch worktree hostile: no control character reaches the line'
Confirm-Equal (Get-VisibleWidth $seg.Text) 8 'branch worktree hostile: the width is the glyph, not the refused text'
$seg = Get-BranchSegment ('{"git":{"branch":"main","status":"clean"},"worktree":{"name":"wt\u001b[31mx"}}' | ConvertFrom-Json) $branchCfg
Confirm-Equal $seg.Text "$iconHome main" 'branch worktree hostile name with no flag: no badge at all'

# A worktree directory can be named in any script, and the script's width count and the test's own have
# to agree on it or the fitting pipeline shrinks against a width the terminal never sees.
$wideName = [char]::ConvertFromUtf32(0x691C) + [char]::ConvertFromUtf32(0x8A3C)
$seg = Get-BranchSegment (('{"git":{"branch":"main","status":"clean"},"worktree":{"name":"' + $wideName + '"}}') | ConvertFrom-Json) $branchCfg
Confirm-Equal $seg.Text "$iconHome main $iconWorktree $wideName" 'branch worktree wide name: the name reaches the line'
Confirm-Equal (Get-VisibleWidth $seg.Text) 13 'branch worktree wide name: two cells for each wide character'
Confirm-Equal (Measure-VisibleWidth $seg.Text) (Get-VisibleWidth $seg.Text) 'branch worktree wide name: the script and the test count the same width'

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
$seg = Get-BranchSegment $probePayload @{ Git = (Get-DefaultGitConfig) }
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ${iconAhead}1 ${iconBehind}2" 'branch counts: ahead then behind after the name'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[90m${iconAhead}1$esc[35m $esc[90m${iconBehind}2$esc[35m" 'branch counts: arrows dim, branch colour restored (plain, no style in the cfg)'
Confirm-Equal $seg.Short "$iconBranch feature/x" 'branch counts: short has no arrows'
Confirm-Equal $seg.Role 'branch' 'branch counts: role'
$seg = Get-BranchSegment $probePayload $branchPowerlineCfg
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[38;5;245m${iconAhead}1$esc[38;5;231m $esc[38;5;245m${iconBehind}2$esc[38;5;231m" 'branch counts: powerline arrows restore the block fg'
$script:mockGitBranch = Get-BranchRecord 'topic' $false -Ahead 2
$seg = Get-BranchSegment $probePayload $branchCfg
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch topic ${iconAhead}2" 'branch ahead only: no behind arrow'
$script:mockGitBranch = Get-BranchRecord 'main' $false -Behind 3
$seg = Get-BranchSegment $probePayload $branchCfg
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconHome main ${iconBehind}3" 'branch behind only: no ahead arrow'
$script:mockGitBranch = Get-BranchRecord 'main' $false
$seg = Get-BranchSegment $probePayload $branchCfg
Confirm-Equal $seg.Text "$iconHome main" 'branch zero counts: exactly the old text, no escapes'
Confirm-Equal $seg.Short "$iconHome main" 'branch zero counts: short is the same text'
$script:mockGitBranch = Get-BranchRecord 'feature/x' $true -Ahead 1 -Behind 1
$seg = Get-BranchSegment $probePayload $branchCfg
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ${iconAhead}1 ${iconBehind}1 $iconDirty" 'branch dirty with counts: pencil last'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[90m${iconAhead}1$esc[33m $esc[90m${iconBehind}1$esc[33m $iconDirty" 'branch dirty with counts: arrows restore the warn colour'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch dirty with counts: short keeps the pencil, drops the arrows'
Confirm-Equal $seg.Role 'warn' 'branch dirty with counts: role'
$script:mockGitBranch = Get-BranchRecord 'feature/x' $true -Ahead 1 -Behind 2 -Staged 2 -Modified 1 -Untracked 3 -Conflicts 1
$seg = Get-BranchSegment $probePayload $branchCfg
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch feature/x ${iconAhead}1 ${iconBehind}2 +2 ~1 ?3 ${iconConflict}1 $iconDirty" 'branch everything: arrows, staged, modified, untracked, conflict, pencil'
Confirm-Equal $seg.Text "$iconBranch feature/x $esc[90m${iconAhead}1$esc[33m $esc[90m${iconBehind}2$esc[33m $esc[90m+2$esc[33m $esc[90m~1$esc[33m $esc[90m?3$esc[33m $esc[31m${iconConflict}1$esc[33m $iconDirty" 'branch everything: counts dim, conflict red, warn colour restored after each'
Confirm-Equal $seg.Short "$iconBranch feature/x $iconDirty" 'branch everything: short is icon, name, pencil'
$script:mockGitBranch = Get-BranchRecord 'main' $true -Staged 1 -Modified 2
$seg = Get-BranchSegment $probePayload $branchCfg
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconHome main +1 ~2 $iconDirty" 'branch file counts only: no arrows, zero counts omitted'
# The badge does not care where the branch came from: the payload names the worktree, git names the
# branch, and the badge still sits between the name and the counts. The probe path is the normal one
# for a real session, which is the only place a worktree name ever arrives.
$script:mockGitBranch = Get-BranchRecord 'wt-branch' $false -Ahead 1
$probeWtPayload = '{"workspace":{"current_dir":"x","git_worktree":true},"worktree":{"name":"wt-review"}}' | ConvertFrom-Json
$seg = Get-BranchSegment $probeWtPayload $branchCfg
Confirm-Equal (ConvertTo-PlainText $seg.Text) "$iconBranch wt-branch $iconWorktree wt-review ${iconAhead}1" 'branch worktree on the probe path: the badge sits between the probed name and its counts'
Confirm-Equal $seg.Short "$iconBranch wt-branch" 'branch worktree on the probe path: short is icon and name'

Write-Host '== unit: git cache' -ForegroundColor Cyan
# The cache in front of the probe, with a stand-in Get-GitBranch that counts its calls and answers with
# $script:cacheProbe, so a count that stays put is proof the probe was skipped. Each repository is a
# hand-made .git directory holding HEAD and index files and the refs tree: the cache reads only their
# stamps, and no git runs anywhere in this group. The cache directory is passed in, so nothing here
# goes near the machine's TEMP until the Get-BranchSegment cases at the end, which point TEMP into
# $tmp first.
$script:probeCalls = 0
$script:lastProbeTimeout = -1
$script:cacheProbe = Get-BranchRecord 'main' $false
function Get-GitBranch([string] $Dir, [int] $TimeoutMs) { $script:probeCalls++; $script:lastProbeTimeout = $TimeoutMs; return $script:cacheProbe }
function Write-FakeRepo([string] $Name, [bool] $WithIndex = $true) {
    $p = Join-Path $tmp $Name
    foreach ($d in @('.git', '.git\refs\heads', '.git\refs\tags')) { New-Item -ItemType Directory -Force (Join-Path $p $d) | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $p '.git' 'HEAD'), "ref: refs/heads/main`n")
    if ($WithIndex) { [System.IO.File]::WriteAllBytes((Join-Path $p '.git' 'index'), [byte[]] @(68, 73, 82, 67)) }
    return $p
}
# The test's own spelling of the entry name, so the script's cannot agree with itself.
function Get-CacheEntryName([string] $Root) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant())) } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($bytes, 0, 8).Replace('-', '').ToLowerInvariant() + '.json')
}
function Get-CacheFileCount([string] $Dir) { return @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue).Count }
function Edit-CacheEntry([string] $Path, [scriptblock] $Change) {
    $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    & $Change $j
    [System.IO.File]::WriteAllText($Path, ($j | ConvertTo-Json -Depth 4 -Compress), [System.Text.UTF8Encoding]::new($false))
}
# Get-ShortHash is the one hash behind the state file name and the cache entry name.
Confirm-Equal (Get-ShortHash 'abc') 'ba7816bf8f01cfea' 'short hash: first 16 hex characters of SHA-256("abc")'
Confirm-Equal (Get-ShortHash '') 'e3b0c44298fc1c14' 'short hash: the empty string hashes too'
$cacheRepo = Write-FakeRepo 'cache-repo'
$cacheGitDir = Join-Path $cacheRepo '.git'
$cacheSub = Join-Path $cacheRepo 'src' 'deep'
New-Item -ItemType Directory -Force $cacheSub | Out-Null
$cacheDir = Join-Path $tmp 'cache-unit'
$cacheHead = Join-Path $cacheGitDir 'HEAD'
$cacheIndex = Join-Path $cacheGitDir 'index'
$cacheEntry = Join-Path $cacheDir (Get-CacheEntryName $cacheRepo)

# Get-GitRepoRoot: the walk up to the first .git entry that is a repository, as a WorkTree/GitDir pair.
function Get-RootPair([string] $Dir) { $r = Get-GitRepoRoot $Dir; if ($r) { "$($r.WorkTree)|$($r.GitDir)" } else { $null } }
Confirm-Equal (Get-RootPair $cacheRepo) "$cacheRepo|$cacheGitDir" 'repo root: the repository itself'
Confirm-Equal (Get-RootPair $cacheSub) "$cacheRepo|$cacheGitDir" 'repo root: two levels down finds the same root'
Confirm-Equal (Get-RootPair ($cacheRepo + [System.IO.Path]::DirectorySeparatorChar)) "$cacheRepo|$cacheGitDir" 'repo root: a trailing separator is dropped'
Confirm-Equal (Get-RootPair (Join-Path $cacheSub '..' '..')) "$cacheRepo|$cacheGitDir" 'repo root: dot-dot segments are resolved'
Confirm-Equal (Get-GitRepoRoot (Join-Path $tmp 'cache-not-there')) $null 'repo root: a missing directory is null'
Confirm-Equal (Get-GitRepoRoot '') $null 'repo root: an empty path is null'
Confirm-Equal (Get-GitRepoRoot $cacheHead) $null 'repo root: a file path is null'
# A plain directory under the temp root. The walk does not stop at GIT_CEILING_DIRECTORIES, so on a
# machine whose temp folder sits inside a repository it would find that; what it must not find is
# anything inside $tmp.
$cachePlain = Join-Path $tmp 'cache-plain'
New-Item -ItemType Directory -Force $cachePlain | Out-Null
$plainRoot = (Get-GitRepoRoot $cachePlain).WorkTree
Confirm-True ($null -eq $plainRoot -or -not $plainRoot.StartsWith($tmp, [System.StringComparison]::OrdinalIgnoreCase)) "repo root: a plain directory finds nothing in the temp tree, got '$plainRoot'"
# A .git directory without a HEAD is not a repository: the walk carries on above it, so a stray
# folder inside a repository keys the entry on the real root, and one on its own finds nothing.
$cacheStray = Join-Path $cacheRepo 'stray'
New-Item -ItemType Directory -Force (Join-Path $cacheStray '.git') | Out-Null
Confirm-Equal (Get-RootPair $cacheStray) "$cacheRepo|$cacheGitDir" 'repo root: an empty .git folder inside a repository is walked past to the real root'
$cacheStrayAlone = Join-Path $tmp 'cache-stray-alone'
New-Item -ItemType Directory -Force (Join-Path $cacheStrayAlone '.git') | Out-Null
$strayRoot = (Get-GitRepoRoot $cacheStrayAlone).WorkTree
Confirm-True ($null -eq $strayRoot -or -not $strayRoot.StartsWith($tmp, [System.StringComparison]::OrdinalIgnoreCase)) "repo root: an empty .git folder on its own is not a root, got '$strayRoot'"
# A .git file names the git directory: a worktree or a submodule. A relative path resolves against the
# directory holding the file, git's forward slashes are fine, and a path that leads nowhere is null.
$cacheWtGitDir = Join-Path $cacheGitDir 'worktrees' 'wt'
New-Item -ItemType Directory -Force $cacheWtGitDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cacheWtGitDir 'HEAD'), "ref: refs/heads/wt`n")
[System.IO.File]::WriteAllText((Join-Path $cacheWtGitDir 'commondir'), "../..`n")
$cacheWorktree = Join-Path $tmp 'cache-worktree'
New-Item -ItemType Directory -Force (Join-Path $cacheWorktree 'below') | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cacheWorktree '.git'), "gitdir: ../cache-repo/.git/worktrees/wt`n")
Confirm-Equal (Get-RootPair $cacheWorktree) "$cacheWorktree|$cacheWtGitDir" 'repo root: a .git file with a relative gitdir resolves against its own directory'
Confirm-Equal (Get-RootPair (Join-Path $cacheWorktree 'below')) "$cacheWorktree|$cacheWtGitDir" 'repo root: below a worktree the walk stops at the .git file'
$cacheWorktreeAbs = Join-Path $tmp 'cache-worktree-abs'
New-Item -ItemType Directory -Force $cacheWorktreeAbs | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cacheWorktreeAbs '.git'), "gitdir: $($cacheWtGitDir.Replace('\', '/'))`r`n")
Confirm-Equal (Get-RootPair $cacheWorktreeAbs) "$cacheWorktreeAbs|$cacheWtGitDir" 'repo root: an absolute gitdir with forward slashes and a CRLF line'
$cacheWorktreeGone = Join-Path $tmp 'cache-worktree-gone'
New-Item -ItemType Directory -Force $cacheWorktreeGone | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cacheWorktreeGone '.git'), "gitdir: $cacheRepo/.git/worktrees/missing`n")
Confirm-Equal (Get-GitRepoRoot $cacheWorktreeGone) $null 'repo root: a gitdir that leads nowhere is null'
$cacheWorktreeOdd = Join-Path $tmp 'cache-worktree-odd'
New-Item -ItemType Directory -Force $cacheWorktreeOdd | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cacheWorktreeOdd '.git'), "not a gitdir line`n")
Confirm-Equal (Get-GitRepoRoot $cacheWorktreeOdd) $null 'repo root: a .git file without a gitdir line is null'
$cacheNestedFile = Join-Path $cacheRepo 'nested-wt'
New-Item -ItemType Directory -Force $cacheNestedFile | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cacheNestedFile '.git'), "gitdir: elsewhere`n")
Confirm-Equal (Get-GitRepoRoot $cacheNestedFile) $null 'repo root: a .git file inside a repository still wins, the walk does not carry on to the directory above'

# Get-GitStamp: the directory, nine files (0 when absent), then refs and every directory under it.
$stamp = Get-GitStamp $cacheGitDir
$stampFields = $stamp -split ','
Confirm-Equal $stampFields.Count 13 'git stamp: the directory, nine files, refs and its two subdirectories'
Confirm-Equal $stampFields[0] ([System.IO.Directory]::GetLastWriteTimeUtc($cacheGitDir).Ticks) 'git stamp: first field is the git directory itself'
Confirm-Equal $stampFields[1] ([System.IO.File]::GetLastWriteTimeUtc($cacheIndex).Ticks) 'git stamp: second field is index'
Confirm-Equal $stampFields[2] ([System.IO.File]::GetLastWriteTimeUtc($cacheHead).Ticks) 'git stamp: third field is HEAD'
Confirm-Equal (($stampFields[3..9]) -join ',') '0,0,0,0,0,0,0' 'git stamp: ORIG_HEAD, FETCH_HEAD, MERGE_HEAD, packed-refs, logs/HEAD, config and info/exclude are 0 when absent'
Confirm-Equal $stampFields[10] ([System.IO.Directory]::GetLastWriteTimeUtc((Join-Path $cacheGitDir 'refs')).Ticks) 'git stamp: refs follows the files'
Confirm-Equal $stampFields[11] ([System.IO.Directory]::GetLastWriteTimeUtc((Join-Path $cacheGitDir 'refs' 'heads')).Ticks) 'git stamp: refs/heads in ordinal order'
Confirm-Equal $stampFields[12] ([System.IO.Directory]::GetLastWriteTimeUtc((Join-Path $cacheGitDir 'refs' 'tags')).Ticks) 'git stamp: refs/tags last'
Confirm-Equal (Get-GitStamp $cacheGitDir) $stamp 'git stamp: the same directory stamps the same twice'
$wtStamp = Get-GitStamp $cacheWtGitDir
Confirm-True ($wtStamp.Contains('|')) 'git stamp: a worktree git directory carries its commondir stamps after a bar'
Confirm-Equal ($wtStamp -split '\|', 2)[1] (Get-GitStamp $cacheGitDir -NoCommon) 'git stamp: the part after the bar is the main repository'
Confirm-Equal (($wtStamp -split '\|', 2)[0] -split ',').Count 10 'git stamp: the worktree part has no refs directory of its own'
Confirm-Equal ((Get-GitStamp (Join-Path $tmp 'cache-not-there')) -split ',').Count 10 'git stamp: a missing directory does not throw and has no refs'
Confirm-Equal (((Get-GitStamp (Join-Path $tmp 'cache-not-there')) -split ',')[1..9] -join ',') '0,0,0,0,0,0,0,0,0' 'git stamp: every file of a missing directory is 0'
# The walk under refs is capped at 256 directories. A repository over the cap gets a stamp that never
# matches, so every call probes and nothing is written; one at 200 is cached as usual.
function Write-RefDir([string] $Name, [int] $Count) {
    $p = Write-FakeRepo $Name
    for ($i = 1; $i -le $Count; $i++) { [void] [System.IO.Directory]::CreateDirectory((Join-Path $p '.git' 'refs' 'pull' "$i")) }
    return $p
}
$cacheRepoMany = Write-RefDir 'cache-repo-many' 300
$cacheRepoSome = Write-RefDir 'cache-repo-some' 200
$manyStamp = Get-GitStamp (Join-Path $cacheRepoMany '.git')
Confirm-True ($manyStamp.StartsWith('over-cap:')) "git stamp: over 256 ref directories gives the over-cap marker, got '$manyStamp'"
Confirm-True ($manyStamp -cne (Get-GitStamp (Join-Path $cacheRepoMany '.git'))) 'git stamp: the over-cap stamp never matches itself'
Confirm-Equal ((Get-GitStamp (Join-Path $cacheRepoSome '.git')) -split ',').Count (10 + 1 + 2 + 1 + 200) 'git stamp: 200 ref directories are all stamped (refs, heads, tags, pull and 200 below it)'
# A cache directory of its own, and the probe count is reset afterwards, because the miss and hit cases
# below count from zero.
$cacheCapDir = Join-Path $tmp 'cache-unit-cap'
$before = $script:probeCalls
$g = Get-CachedGitBranch $cacheRepoMany 1500 $cacheCapDir 5
$g = Get-CachedGitBranch $cacheRepoMany 1500 $cacheCapDir 5
Confirm-Equal $script:probeCalls ($before + 2) 'over the ref cap: both calls probe'
Confirm-Equal $g.Branch 'main' 'over the ref cap: the probe answers'
Confirm-True (-not (Test-Path -LiteralPath $cacheCapDir)) 'over the ref cap: nothing written, not even the directory'
$g = Get-CachedGitBranch $cacheRepoSome 1500 $cacheCapDir 5
$g = Get-CachedGitBranch $cacheRepoSome 1500 $cacheCapDir 5
Confirm-Equal $script:probeCalls ($before + 3) 'under the ref cap: one probe, then a hit'
Confirm-True (Test-Path -LiteralPath (Join-Path $cacheCapDir (Get-CacheEntryName $cacheRepoSome))) 'under the ref cap: the entry is written'
$script:probeCalls = 0
$cacheWtGitDirMany = Join-Path $cacheRepoMany '.git' 'worktrees' 'wt'
New-Item -ItemType Directory -Force $cacheWtGitDirMany | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cacheWtGitDirMany 'HEAD'), "ref: refs/heads/wt`n")
[System.IO.File]::WriteAllText((Join-Path $cacheWtGitDirMany 'commondir'), "../..`n")
Confirm-True ((Get-GitStamp $cacheWtGitDirMany).StartsWith('over-cap:')) 'git stamp: a worktree of a repository over the cap is over the cap too'

# A miss probes and writes; a hit answers from the file and does not.
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
Confirm-Equal $g.Branch 'main' 'cache miss: the probe result comes back'
Confirm-Equal $script:probeCalls 1 'cache miss: the probe ran once'
Confirm-Equal $script:lastProbeTimeout 1500 'cache miss: the timeout reaches the probe'
Confirm-Equal (Get-CacheFileCount $cacheDir) 2 'cache miss: the entry and the sweep stamp written'
Confirm-True (Test-Path -LiteralPath $cacheEntry) 'cache file: named by the first 16 hex characters of the SHA-256 of the lower-cased root'
Confirm-True (Test-Path -LiteralPath (Join-Path $cacheDir '.sweep')) 'cache file: the first write leaves the sweep stamp'
Confirm-True (-not (Test-Path (Join-Path $cacheDir '*.tmp'))) 'cache file: no .tmp left behind'
$bytes = [System.IO.File]::ReadAllBytes($cacheEntry)
Confirm-True ($bytes.Count -gt 3 -and -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'cache file: UTF-8 without a BOM'
Confirm-True (-not [System.Text.Encoding]::UTF8.GetString($bytes).Contains("`n")) 'cache file: one compact line'
$entry = Get-Content -LiteralPath $cacheEntry -Raw | ConvertFrom-Json
Confirm-Equal $entry.v 1 'cache file: version 1'
Confirm-Equal $entry.root $cacheRepo 'cache file: root is the work tree'
Confirm-Equal $entry.stamps (Get-GitStamp $cacheGitDir) 'cache file: stamps is the stamp string of the git directory'
Confirm-True ($entry.stamps -is [string]) 'cache file: stamps is one string'
Confirm-True ([math]::Abs($entry.writtenAt - $now) -le 5) 'cache file: writtenAt is now, in Unix seconds'
Confirm-Equal (@($entry.PSObject.Properties.Name) -join ',') 'v,root,stamps,writtenAt,result' 'cache file: keys in schema order'
Confirm-Equal $entry.result.Branch 'main' 'cache file: result holds the branch'
Confirm-Equal @($entry.result.PSObject.Properties).Count 8 'cache file: result holds every key of the record'
$g = Get-CachedGitBranch $cacheSub 1500 $cacheDir 5
Confirm-Equal $g.Branch 'main' 'cache hit: the branch comes from the file'
Confirm-Equal $script:probeCalls 1 'cache hit: the probe did not run'
Confirm-True ($g -is [hashtable]) 'cache hit: the record is a hashtable, as the probe returns'
foreach ($key in @('Branch', 'Dirty', 'Ahead', 'Behind', 'Staged', 'Modified', 'Untracked', 'Conflicts')) {
    Confirm-True ($g.ContainsKey($key)) "cache hit: the record has $key"
}
Confirm-True ($g.Dirty -is [bool] -and -not $g.Dirty) 'cache hit: Dirty is the boolean false'
Confirm-True ($g.Ahead -eq 0 -and -not ($g.Ahead -gt 0)) 'cache hit: a zero count compares as zero'
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
Confirm-Equal $script:probeCalls 1 'cache hit: a third call is still a hit'

# A dirty record with every count set round-trips whole, so the segment reads the same either way.
$script:cacheProbe = Get-BranchRecord 'feature/x' $true -Ahead 1 -Behind 2 -Staged 3 -Modified 4 -Untracked 5 -Conflicts 6
$cacheRepo2 = Write-FakeRepo 'cache-repo-2'
$fromProbe = Get-CachedGitBranch $cacheRepo2 1500 $cacheDir 5
Confirm-Equal $script:probeCalls 2 'second repository: its first call probes'
Confirm-Equal (Get-CacheFileCount $cacheDir) 3 'second repository: its own file beside the first and the sweep stamp'
$fromCache = Get-CachedGitBranch $cacheRepo2 1500 $cacheDir 5
Confirm-Equal $script:probeCalls 2 'second repository: its second call hits'
foreach ($key in @('Branch', 'Dirty', 'Ahead', 'Behind', 'Staged', 'Modified', 'Untracked', 'Conflicts')) {
    Confirm-Equal $fromCache[$key] $fromProbe[$key] "round trip: $key survives the file"
}
Confirm-True ($fromCache.Dirty -is [bool] -and $fromCache.Dirty) 'round trip: Dirty is the boolean true'
Confirm-Equal (ConvertTo-PlainText (Get-BranchSegment ([pscustomobject]@{ git = @{ branch = $fromCache.Branch; status = [pscustomobject]@{ staged = $fromCache.Staged; modified = $fromCache.Modified; untracked = $fromCache.Untracked; conflicts = $fromCache.Conflicts } } })).Text) "$iconBranch feature/x +3 ~4 ?5 ${iconConflict}6 $iconDirty" 'round trip: the counts render'
$script:cacheProbe = Get-BranchRecord 'main' $false

# Invalidation: every stamp that moves is a miss, and the rewritten entry hits again. The stamps are
# set by hand rather than waited for, so the touched one is the only thing that changed.
$later = [DateTime]::UtcNow.AddSeconds(30)
$invalidations = @(
    @{ Name = 'touched HEAD';               Do = { [System.IO.File]::SetLastWriteTimeUtc($cacheHead, $later) } }
    @{ Name = 'touched index';              Do = { [System.IO.File]::SetLastWriteTimeUtc($cacheIndex, [DateTime]::UtcNow.AddSeconds(-30)) } }
    @{ Name = 'ORIG_HEAD written';          Do = { [System.IO.File]::WriteAllText((Join-Path $cacheGitDir 'ORIG_HEAD'), "abc`n") } }
    @{ Name = 'FETCH_HEAD written';         Do = { [System.IO.File]::WriteAllText((Join-Path $cacheGitDir 'FETCH_HEAD'), "abc`n") } }
    @{ Name = 'MERGE_HEAD written';         Do = { [System.IO.File]::WriteAllText((Join-Path $cacheGitDir 'MERGE_HEAD'), "abc`n") } }
    @{ Name = 'packed-refs written';        Do = { [System.IO.File]::WriteAllText((Join-Path $cacheGitDir 'packed-refs'), "# pack-refs`n") } }
    @{ Name = 'logs/HEAD written';          Do = { New-Item -ItemType Directory -Force (Join-Path $cacheGitDir 'logs') | Out-Null; [System.IO.File]::WriteAllText((Join-Path $cacheGitDir 'logs' 'HEAD'), "log`n") } }
    @{ Name = 'config written';             Do = { [System.IO.File]::WriteAllText((Join-Path $cacheGitDir 'config'), "[core]`n") } }
    @{ Name = 'config edited';              Do = { [System.IO.File]::AppendAllText((Join-Path $cacheGitDir 'config'), "`tbare = false`n") } }
    @{ Name = 'info/exclude written';       Do = { New-Item -ItemType Directory -Force (Join-Path $cacheGitDir 'info') | Out-Null; [System.IO.File]::WriteAllText((Join-Path $cacheGitDir 'info' 'exclude'), "*.log`n") } }
    @{ Name = 'a line appended to info/exclude'; Do = { [System.IO.File]::AppendAllText((Join-Path $cacheGitDir 'info' 'exclude'), "build/`n") } }
    @{ Name = 'refs/heads touched';         Do = { [System.IO.Directory]::SetLastWriteTimeUtc((Join-Path $cacheGitDir 'refs' 'heads'), $later) } }
    @{ Name = 'a ref written by rename';    Do = { $lock = Join-Path $cacheGitDir 'refs' 'heads' 'main.lock'; [System.IO.File]::WriteAllText($lock, "abc`n"); [System.IO.File]::Move($lock, (Join-Path $cacheGitDir 'refs' 'heads' 'main'), $true) } }
    @{ Name = 'refs/remotes/origin created'; Do = { New-Item -ItemType Directory -Force (Join-Path $cacheGitDir 'refs' 'remotes' 'origin') | Out-Null } }
    @{ Name = 'the git directory touched'; Do = { [System.IO.Directory]::SetLastWriteTimeUtc($cacheGitDir, $later.AddSeconds(5)) } }
)
foreach ($case in $invalidations) {
    $g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
    $before = $script:probeCalls
    $stampBefore = (Get-Content -LiteralPath $cacheEntry -Raw | ConvertFrom-Json).stamps
    & $case.Do
    $g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
    Confirm-Equal $script:probeCalls ($before + 1) "$($case.Name): a miss, the probe ran"
    $stampAfter = (Get-Content -LiteralPath $cacheEntry -Raw | ConvertFrom-Json).stamps
    Confirm-True ($stampAfter -cne $stampBefore) "$($case.Name): the entry carries new stamps"
    Confirm-Equal $stampAfter (Get-GitStamp $cacheGitDir) "$($case.Name): the entry's stamps are the directory's now"
    $g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
    Confirm-Equal $script:probeCalls ($before + 1) "$($case.Name): the rewritten entry hits"
}
Confirm-Equal ((Get-GitStamp $cacheGitDir) -split ',').Count 15 'git stamp: refs/remotes and refs/remotes/origin joined the list'
# A change to the main repository's refs invalidates a worktree's entry through its commondir.
$g = Get-CachedGitBranch $cacheWorktree 1500 $cacheDir 5
$g = Get-CachedGitBranch $cacheWorktree 1500 $cacheDir 5
$before = $script:probeCalls
Confirm-True (Test-Path -LiteralPath (Join-Path $cacheDir (Get-CacheEntryName $cacheWorktree))) 'worktree: its entry is named for the worktree path'
[System.IO.Directory]::SetLastWriteTimeUtc((Join-Path $cacheGitDir 'refs' 'heads'), $later.AddSeconds(10))
$g = Get-CachedGitBranch $cacheWorktree 1500 $cacheDir 5
Confirm-Equal $script:probeCalls ($before + 1) 'worktree: a ref change in the main repository is a miss'
$g = Get-CachedGitBranch $cacheWorktree 1500 $cacheDir 5
Confirm-Equal $script:probeCalls ($before + 1) 'worktree: then a hit'
# No index at all - a repository with no commits yet - stamps as 0 rather than failing.
Remove-Item -LiteralPath $cacheIndex -Force
$before = $script:probeCalls
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
Confirm-Equal $script:probeCalls ($before + 1) 'index removed: a miss'
Confirm-Equal ((Get-Content -LiteralPath $cacheEntry -Raw | ConvertFrom-Json).stamps -split ',')[1] '0' 'index removed: the index field is the sentinel 0'
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
Confirm-Equal $g.Branch 'main' 'index removed: the entry with the sentinel hits'
Confirm-Equal $script:probeCalls ($before + 1) 'index removed: no probe on the hit'
[System.IO.File]::WriteAllBytes($cacheIndex, [byte[]] @(68, 73, 82, 67))
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
Confirm-Equal $script:probeCalls ($before + 2) 'index back: a miss'
$cacheRepoUnborn = Write-FakeRepo 'cache-repo-unborn' $false
$g = Get-CachedGitBranch $cacheRepoUnborn 1500 $cacheDir 5
$g = Get-CachedGitBranch $cacheRepoUnborn 1500 $cacheDir 5
Confirm-Equal $script:probeCalls ($before + 3) 'repository without an index: one probe, then a hit'

# Age: writtenAt outside the lifetime is a miss either way, inside it is a hit.
foreach ($case in @(@{ Name = 'aged out'; Offset = -10 }, @{ Name = 'dated in the future'; Offset = 10 }, @{ Name = 'exactly the lifetime old'; Offset = -5 })) {
    $offset = $case.Offset
    Edit-CacheEntry $cacheEntry { param($j) $j.writtenAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $offset }
    $before = $script:probeCalls
    $g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
    Confirm-Equal $script:probeCalls ($before + 1) "entry $($case.Name): a miss"
    Confirm-True ([math]::Abs((Get-Content -LiteralPath $cacheEntry -Raw | ConvertFrom-Json).writtenAt - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -le 5) "entry $($case.Name): rewritten with the time now"
}
Edit-CacheEntry $cacheEntry { param($j) $j.writtenAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 3 }
$before = $script:probeCalls
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
Confirm-Equal $script:probeCalls $before 'entry three seconds old: a hit with a lifetime of five'
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 300
Confirm-Equal $script:probeCalls $before 'entry three seconds old: a hit with a lifetime of 300'
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 2
Confirm-Equal $script:probeCalls ($before + 1) 'entry three seconds old: a miss with a lifetime of two'

# A lifetime of 0 always probes and never writes.
$stamp = (Get-Item -LiteralPath $cacheEntry).LastWriteTimeUtc
$before = $script:probeCalls
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 0
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 0
Confirm-Equal $script:probeCalls ($before + 2) 'lifetime 0: every call probes'
Confirm-Equal $g.Branch 'main' 'lifetime 0: the probe result comes back'
Confirm-Equal (Get-Item -LiteralPath $cacheEntry).LastWriteTimeUtc $stamp 'lifetime 0: the entry is not rewritten'
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir -1
Confirm-Equal $script:probeCalls ($before + 3) 'lifetime below 0: probes'
$g = Get-CachedGitBranch $cacheRepo 1500 '' 5
Confirm-Equal $script:probeCalls ($before + 4) 'no cache directory given: probes'

# A cache directory that is missing, or cannot be made, gives the same answer as a direct call.
$cacheMissing = Join-Path $tmp 'cache-missing'
$before = $script:probeCalls
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheMissing 5
Confirm-Equal $g.Branch 'main' 'missing cache directory: the probe answers'
Confirm-Equal $script:probeCalls ($before + 1) 'missing cache directory: the probe ran'
Confirm-True (Test-Path -LiteralPath (Join-Path $cacheMissing (Get-CacheEntryName $cacheRepo))) 'missing cache directory: created and the entry written'
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheMissing 5
Confirm-Equal $script:probeCalls ($before + 1) 'missing cache directory: the next call hits'
$cacheBlocked = Join-Path $tmp 'cache-blocked'
[System.IO.File]::WriteAllText($cacheBlocked, 'in the way')
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheBlocked 5
Confirm-Equal $g.Branch 'main' 'cache directory blocked by a file: the probe answers'
Confirm-Equal $script:probeCalls ($before + 2) 'cache directory blocked by a file: the probe ran'
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheBlocked 5
Confirm-Equal $script:probeCalls ($before + 3) 'cache directory blocked by a file: every call probes'
Confirm-Equal (Get-Content -LiteralPath $cacheBlocked -Raw) 'in the way' 'cache directory blocked by a file: the file is untouched'

# A null probe result - a timeout, no git - is cached like any other, so the slow repository pays for
# the probe once per lifetime: the next call within it reads the null back without asking.
$script:cacheProbe = $null
$cacheRepoNull = Write-FakeRepo 'cache-repo-null'
$cacheEntryNull = Join-Path $cacheDir (Get-CacheEntryName $cacheRepoNull)
$before = $script:probeCalls
Confirm-Equal (Get-CachedGitBranch $cacheRepoNull 1500 $cacheDir 5) $null 'null probe: null comes back'
Confirm-Equal $script:probeCalls ($before + 1) 'null probe: the first call probed'
Confirm-True (Test-Path -LiteralPath $cacheEntryNull) 'null probe: an entry is written'
$entry = Get-Content -LiteralPath $cacheEntryNull -Raw | ConvertFrom-Json
Confirm-True ($null -ne $entry.PSObject.Properties['result'] -and $null -eq $entry.result) 'null probe: the entry holds result null'
Confirm-Equal (Get-CachedGitBranch $cacheRepoNull 1500 $cacheDir 5) $null 'null probe: null again from the entry'
Confirm-Equal $script:probeCalls ($before + 1) 'null probe: the second call did not probe'
$script:cacheProbe = Get-BranchRecord 'main' $false
Confirm-Equal (Get-CachedGitBranch $cacheRepoNull 1500 $cacheDir 5) $null 'null probe: still null while the entry is fresh, even though git would answer now'
Confirm-Equal $script:probeCalls ($before + 1) 'null probe: no probe while the entry is fresh'
[System.IO.File]::SetLastWriteTimeUtc((Join-Path $cacheRepoNull '.git' 'HEAD'), $later)
Confirm-Equal (Get-CachedGitBranch $cacheRepoNull 1500 $cacheDir 5).Branch 'main' 'null probe: a stamp change asks git again and the branch is back'
Confirm-Equal $script:probeCalls ($before + 2) 'null probe: the stamp change probed'
Edit-CacheEntry $cacheEntryNull { param($j) $j.writtenAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 10 }
$script:cacheProbe = $null
Confirm-Equal (Get-CachedGitBranch $cacheRepoNull 1500 $cacheDir 5) $null 'null probe: an aged-out entry asks git again, which fails this time'
Confirm-Equal $script:probeCalls ($before + 3) 'null probe: the aged-out entry probed'
$script:cacheProbe = Get-BranchRecord 'main' $false

# A bad entry is a miss and is replaced: corrupt JSON, an empty file, the wrong root, the wrong
# version, no result key at all (which is not the same as a null result), a result that fails the
# payload guards - no branch, a blank or numeric branch, a count that is a string, a fraction or
# negative, a Dirty that is not a boolean - and stamps or writtenAt of the wrong type.
$badEntries = @(
    @{ Name = 'corrupt json';         Text = '{ "v": 1, "root' }
    @{ Name = 'empty file';           Text = '' }
    @{ Name = 'a json array';         Text = '[1, 2]' }
    @{ Name = 'a json string';        Text = '"main"' }
    @{ Name = 'another root';         Change = { param($j) $j.root = Join-Path $tmp 'cache-repo-2' } }
    @{ Name = 'root missing';         Change = { param($j) $j.PSObject.Properties.Remove('root') } }
    @{ Name = 'version 2';            Change = { param($j) $j.v = 2 } }
    @{ Name = 'version missing';      Change = { param($j) $j.PSObject.Properties.Remove('v') } }
    @{ Name = 'no result key';        Change = { param($j) $j.PSObject.Properties.Remove('result') } }
    @{ Name = 'result a string';      Change = { param($j) $j.result = 'main' } }
    @{ Name = 'result without branch'; Change = { param($j) $j.result.PSObject.Properties.Remove('Branch') } }
    @{ Name = 'empty branch';         Change = { param($j) $j.result.Branch = '' } }
    @{ Name = 'blank branch';         Change = { param($j) $j.result.Branch = '  ' } }
    @{ Name = 'branch a number';      Change = { param($j) $j.result.Branch = 7 } }
    @{ Name = 'Dirty a string';       Change = { param($j) $j.result.Dirty = 'clean' } }
    @{ Name = 'Dirty a number';       Change = { param($j) $j.result.Dirty = 0 } }
    @{ Name = 'Dirty missing';        Change = { param($j) $j.result.PSObject.Properties.Remove('Dirty') } }
    @{ Name = 'Staged a string';      Change = { param($j) $j.result.Staged = '1' } }
    @{ Name = 'Ahead negative';       Change = { param($j) $j.result.Ahead = -1 } }
    @{ Name = 'Modified a fraction';  Change = { param($j) $j.result.Modified = 1.5 } }
    @{ Name = 'Untracked a boolean';  Change = { param($j) $j.result.Untracked = $true } }
    @{ Name = 'Conflicts missing';    Change = { param($j) $j.result.PSObject.Properties.Remove('Conflicts') } }
    @{ Name = 'stamps a number';      Change = { param($j) $j.stamps = 5 } }
    @{ Name = 'stamps missing';       Change = { param($j) $j.PSObject.Properties.Remove('stamps') } }
    @{ Name = 'stamps one field off'; Change = { param($j) $j.stamps = $j.stamps -replace '^\d+', '1' } }
    @{ Name = 'stamps with an extra field'; Change = { param($j) $j.stamps = $j.stamps + ',0' } }
    @{ Name = 'string writtenAt';     Change = { param($j) $j.writtenAt = 'now' } }
    @{ Name = 'writtenAt missing';    Change = { param($j) $j.PSObject.Properties.Remove('writtenAt') } }
)
foreach ($case in $badEntries) {
    $g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
    $before = $script:probeCalls
    if ($case.ContainsKey('Text')) { [System.IO.File]::WriteAllText($cacheEntry, $case.Text) } else { Edit-CacheEntry $cacheEntry $case.Change }
    $g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
    Confirm-Equal $g.Branch 'main' "bad entry, $($case.Name): the probe answers"
    Confirm-Equal $script:probeCalls ($before + 1) "bad entry, $($case.Name): a miss"
    $g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
    Confirm-Equal $script:probeCalls ($before + 1) "bad entry, $($case.Name): replaced by a good one"
}
# The guards on a hit record, and the record's shape after them.
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
$before = $script:probeCalls
Edit-CacheEntry $cacheEntry { param($j) $j.result.Staged = 2.0; $j.result.Ahead = 3 }
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
Confirm-Equal $script:probeCalls $before 'hit record: a whole double count passes the guard'
Confirm-True ($g.Staged -is [int] -and $g.Staged -eq 2) 'hit record: counts come back as Int32'
Confirm-True ($g.Ahead -is [int] -and $g.Ahead -eq 3) 'hit record: Ahead too'
Confirm-True ($g.Dirty -is [bool]) 'hit record: Dirty is a boolean'
Confirm-True ($g.Branch -is [string]) 'hit record: Branch is a string'
Confirm-Equal (Read-CachedRecord $null) $null 'cached record: null is not a record'
Confirm-Equal (Read-CachedRecord 'main') $null 'cached record: a string is not a record'
Confirm-Equal (Read-CachedRecord ('{"Branch":"x","Dirty":true,"Ahead":0,"Behind":0,"Staged":0,"Modified":0,"Untracked":0,"Conflicts":"0"}' | ConvertFrom-Json)) $null 'cached record: one string count fails the whole record'
Confirm-Equal (Read-CachedRecord ('{"Branch":"x","Dirty":true,"Ahead":0,"Behind":0,"Staged":0,"Modified":0,"Untracked":0,"Conflicts":0}' | ConvertFrom-Json)).Branch 'x' 'cached record: a good record passes'
# The cache file is on disk, so it is the one branch source a hand edit can reach. It gets the same
# treatment as the other two on the way out of the file.
Confirm-Equal (Read-CachedRecord ('{"Branch":"ma\u202ein","Dirty":true,"Ahead":0,"Behind":0,"Staged":0,"Modified":0,"Untracked":0,"Conflicts":0}' | ConvertFrom-Json)).Branch 'main' 'cached record: an override in a cached branch is stripped'
Confirm-Equal (Read-CachedRecord ('{"Branch":"\u202e","Dirty":true,"Ahead":0,"Behind":0,"Staged":0,"Modified":0,"Untracked":0,"Conflicts":0}' | ConvertFrom-Json)) $null 'cached record: a branch that is nothing but an override is not a record'
# An entry whose root differs only in case is the same file and the same repository on Windows.
Edit-CacheEntry $cacheEntry { param($j) $j.root = $j.root.ToUpperInvariant() }
$before = $script:probeCalls
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
Confirm-Equal $script:probeCalls $before 'entry root in another case: a hit'
# Extra keys in the entry are ignored, and extra keys in the result come back with it.
Edit-CacheEntry $cacheEntry { param($j) $j | Add-Member -NotePropertyName 'note' -NotePropertyValue 'x'; $j.result | Add-Member -NotePropertyName 'Stash' -NotePropertyValue 2 }
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
Confirm-Equal $script:probeCalls $before 'entry with extra keys: a hit'
Confirm-Equal $g.Stash 2 'entry with extra keys: a key the probe may grow later is read back as is'

# A directory that is not a repository, a missing one and an empty path bypass the cache: every call
# probes and nothing is written.
$before = $script:probeCalls
$files = Get-CacheFileCount $cacheDir
$g = Get-CachedGitBranch $cachePlain 1500 $cacheDir 5
Confirm-Equal $script:probeCalls ($before + 1) 'not a repository: probes'
Confirm-True ((Get-CacheFileCount $cacheDir) -eq $files -or $null -ne $plainRoot) 'not a repository: nothing written'
$g = Get-CachedGitBranch (Join-Path $tmp 'cache-not-there') 1500 $cacheDir 5
Confirm-Equal $script:probeCalls ($before + 2) 'missing directory: handed to the probe'
$g = Get-CachedGitBranch '' 1500 $cacheDir 5
Confirm-Equal $script:probeCalls ($before + 3) 'empty directory: handed to the probe'
$g = Get-CachedGitBranch $cacheWorktreeGone 1500 $cacheDir 5
Confirm-Equal $script:probeCalls ($before + 4) 'gitdir leading nowhere: handed to the probe'
Confirm-Equal (Get-CacheFileCount $cacheDir) $files 'bypassed calls: nothing written'

# The sweep runs from the write path: with the stamp gone, a write clears day-old entries and .tmp
# files from the cache directory and leaves fresh ones.
$sweepOld = Join-Path $cacheDir 'old-entry.json'
$sweepOldTmp = Join-Path $cacheDir 'old-entry.json.tmp'
$sweepFresh = Join-Path $cacheDir 'fresh-entry.json'
foreach ($f in @($sweepOld, $sweepOldTmp, $sweepFresh)) { [System.IO.File]::WriteAllText($f, '{}') }
foreach ($f in @($sweepOld, $sweepOldTmp)) { [System.IO.File]::SetLastWriteTimeUtc($f, [DateTime]::UtcNow.AddHours(-25)) }
Remove-Item -LiteralPath (Join-Path $cacheDir '.sweep') -Force
[System.IO.File]::SetLastWriteTimeUtc($cacheHead, $later.AddSeconds(20))
$g = Get-CachedGitBranch $cacheRepo 1500 $cacheDir 5
Confirm-True (-not (Test-Path -LiteralPath $sweepOld)) 'cache sweep: a day-old entry is deleted on the next write'
Confirm-True (-not (Test-Path -LiteralPath $sweepOldTmp)) 'cache sweep: a day-old .tmp is deleted too'
Confirm-True (Test-Path -LiteralPath $sweepFresh) 'cache sweep: a fresh entry is kept'
Confirm-True (Test-Path -LiteralPath (Join-Path $cacheDir '.sweep')) 'cache sweep: the stamp is written'
Confirm-True (Test-Path -LiteralPath $cacheEntry) 'cache sweep: the entry just written is kept'

# Get-BranchSegment always goes through Get-CachedGitBranch with the config's values, handing it the
# directory from Get-GitCacheDir when the cache is on and nothing when it is off; the lifetime and
# the repository walk are the function's own business. The directory is claude-statusline under TEMP,
# else TMPDIR, else the runtime's temp path, which on Windows reads TMP.
$oldTemp = $env:TEMP
$oldTmpDir = $env:TMPDIR
$oldTmp = $env:TMP
$segTemp = Join-Path $tmp 'temp-cache-unit'
New-Item -ItemType Directory -Force $segTemp | Out-Null
$env:TEMP = $segTemp
try {
    $segCacheDir = Join-Path $segTemp 'claude-statusline'
    Confirm-Equal (Get-GitCacheDir) $segCacheDir 'cache dir: claude-statusline under TEMP'
    $segPayload = [pscustomobject]@{ workspace = @{ current_dir = $cacheSub } }
    $before = $script:probeCalls
    $seg = Get-BranchSegment $segPayload @{ Style = 'plain'; Git = (Get-DefaultGitConfig) }
    Confirm-Equal $seg.Text "$iconHome main" 'branch segment via cache: the first render probes and prints'
    Confirm-Equal $script:probeCalls ($before + 1) 'branch segment via cache: the first render probed'
    Confirm-Equal $script:lastProbeTimeout 1500 'branch segment via cache: the default timeout reaches the probe'
    Confirm-True (Test-Path -LiteralPath (Join-Path $segCacheDir (Get-CacheEntryName $cacheRepo))) 'branch segment via cache: the entry sits in claude-statusline under TEMP'
    $seg = Get-BranchSegment $segPayload @{ Style = 'plain'; Git = (Get-DefaultGitConfig) }
    Confirm-Equal $seg.Text "$iconHome main" 'branch segment via cache: the second render prints the same'
    Confirm-Equal $script:probeCalls ($before + 1) 'branch segment via cache: the second render did not probe'
    $seg = Get-BranchSegment $segPayload (Read-StatusConfig $null)
    Confirm-Equal $seg.Text "$iconHome main" 'branch segment, the config Read-StatusConfig gives with no file: prints'
    Confirm-Equal $script:probeCalls ($before + 1) 'branch segment, the config Read-StatusConfig gives with no file: the defaults, so a hit'
    $seg = Get-BranchSegment $segPayload @{ Style = 'plain'; Git = @{ TimeoutMs = 700; CacheSeconds = 5; Cache = $false } }
    Confirm-Equal $seg.Text "$iconHome main" 'branch segment, cache off: prints'
    Confirm-Equal $script:probeCalls ($before + 2) 'branch segment, cache off: probes'
    Confirm-Equal $script:lastProbeTimeout 700 'branch segment, cache off: the configured timeout reaches the probe'
    $seg = Get-BranchSegment $segPayload @{ Style = 'plain'; Git = @{ TimeoutMs = 800; CacheSeconds = 0; Cache = $true } }
    Confirm-Equal $script:probeCalls ($before + 3) 'branch segment, cacheSeconds 0: probes'
    Confirm-Equal $script:lastProbeTimeout 800 'branch segment, cacheSeconds 0: the configured timeout reaches the probe'
    $seg = Get-BranchSegment $segPayload @{ Style = 'plain'; Git = @{ TimeoutMs = 900; CacheSeconds = 5; Cache = $true } }
    Confirm-Equal $script:probeCalls ($before + 3) 'branch segment, cache on again: a hit'
    $seg = Get-BranchSegment ([pscustomobject]@{ git = @{ branch = 'topic'; status = 'clean' }; workspace = @{ current_dir = $cacheSub } }) @{ Style = 'plain'; Git = (Get-DefaultGitConfig) }
    Confirm-Equal $seg.Text "$iconBranch topic" 'branch segment, payload with a git object: the payload wins'
    Confirm-Equal $script:probeCalls ($before + 3) 'branch segment, payload with a git object: neither cache nor probe'
    Confirm-Equal (Get-CacheFileCount $segCacheDir) 2 'branch segment: one entry and the sweep stamp under TEMP'
    # No TEMP: TMPDIR, as on Linux and macOS.
    Remove-Item Env:TEMP
    $segTmpDir = Join-Path $tmp 'temp-cache-tmpdir'
    New-Item -ItemType Directory -Force $segTmpDir | Out-Null
    $env:TMPDIR = $segTmpDir
    Confirm-Equal (Get-GitCacheDir) (Join-Path $segTmpDir 'claude-statusline') 'cache dir: TMPDIR when there is no TEMP'
    $seg = Get-BranchSegment $segPayload @{ Style = 'plain'; Git = (Get-DefaultGitConfig) }
    Confirm-Equal $seg.Text "$iconHome main" 'branch segment, TMPDIR: prints'
    Confirm-Equal $script:probeCalls ($before + 4) 'branch segment, TMPDIR: a fresh directory, so a probe'
    Confirm-True (Test-Path -LiteralPath (Join-Path $segTmpDir 'claude-statusline' (Get-CacheEntryName $cacheRepo))) 'branch segment, TMPDIR: the entry sits under TMPDIR'
    $seg = Get-BranchSegment $segPayload @{ Style = 'plain'; Git = (Get-DefaultGitConfig) }
    Confirm-Equal $script:probeCalls ($before + 4) 'branch segment, TMPDIR: then a hit'
    # Neither: the runtime's temp path, which Windows takes from TMP.
    Remove-Item Env:TMPDIR
    $segTmp = Join-Path $tmp 'temp-cache-tmp'
    New-Item -ItemType Directory -Force $segTmp | Out-Null
    $env:TMP = $segTmp
    Confirm-Equal ([System.IO.Path]::TrimEndingDirectorySeparator((Split-Path (Get-GitCacheDir) -Parent))) $segTmp 'cache dir: the runtime temp path when there is neither TEMP nor TMPDIR'
    $seg = Get-BranchSegment $segPayload @{ Style = 'plain'; Git = (Get-DefaultGitConfig) }
    Confirm-Equal $seg.Text "$iconHome main" 'branch segment, runtime temp path: prints'
    Confirm-Equal $script:probeCalls ($before + 5) 'branch segment, runtime temp path: a fresh directory, so a probe'
    Confirm-True (Test-Path -LiteralPath (Join-Path $segTmp 'claude-statusline' (Get-CacheEntryName $cacheRepo))) 'branch segment, runtime temp path: the entry sits there'
} finally {
    if ($null -ne $oldTemp) { $env:TEMP = $oldTemp } else { Remove-Item Env:TEMP -ErrorAction SilentlyContinue }
    if ($null -ne $oldTmpDir) { $env:TMPDIR = $oldTmpDir } else { Remove-Item Env:TMPDIR -ErrorAction SilentlyContinue }
    if ($null -ne $oldTmp) { $env:TMP = $oldTmp } else { Remove-Item Env:TMP -ErrorAction SilentlyContinue }
}

Write-Host '== unit: diag' -ForegroundColor Cyan
# The diagnostics log. Every failure the probe, the cache and the state file swallow stays swallowed;
# with CLAUDE_STATUSLINE_DEBUG set, each one also appends a line to claude-statusline-diag.log in the
# temp folder. The log's path comes from TEMP, so point that at a folder of its own for the group. The
# stub Get-GitBranch from the cache checks above is still in place, so nothing here starts git.
$oldTemp = $env:TEMP
$oldDebug = $env:CLAUDE_STATUSLINE_DEBUG
$diagTemp = Join-Path $tmp 'temp-diag'
New-Item -ItemType Directory -Force $diagTemp | Out-Null
$env:TEMP = $diagTemp
# The test's own spelling of the log's name and of a line's shape, so the script's cannot agree with itself.
$diagLog = Join-Path $diagTemp 'claude-statusline-diag.log'
$diagStamp = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z \d+ '
function Get-DiagLine {
    # The comma keeps a one-line log an array rather than one string the caller would index by character.
    if (-not (Test-Path -LiteralPath $diagLog)) { return , @() }
    return , @([System.IO.File]::ReadAllText($diagLog) -split "`n" | Where-Object { $_ -ne '' })
}
function Clear-DiagLog { if (Test-Path -LiteralPath $diagLog) { Remove-Item -LiteralPath $diagLog -Force } }
function Measure-DiagMatch([string] $Pattern) { return @(Get-DiagLine | Where-Object { $_ -match $Pattern }).Count }
try {
    $script:cacheProbe = Get-BranchRecord 'main' $false
    # Unset - the normal case - the helper writes nothing at all.
    Remove-Item Env:CLAUDE_STATUSLINE_DEBUG -ErrorAction SilentlyContinue
    Write-StatusDiag 'nobody asked for this'
    Confirm-True (-not (Test-Path -LiteralPath $diagLog)) 'diag off: no log file'

    # Set, one call appends one line: the UTC time, the process id, then the reason.
    $env:CLAUDE_STATUSLINE_DEBUG = '1'
    Write-StatusDiag 'hello'
    $diagLines = Get-DiagLine
    Confirm-Equal $diagLines.Count 1 'diag on: one call writes one line'
    Confirm-True ($diagLines[0] -match ($diagStamp + 'hello$')) "diag on: the line reads '<utc> <pid> hello', got '$($diagLines[0])'"
    Confirm-Equal $diagLines[0].Split(' ')[1] "$PID" 'diag on: the second field is the process id'
    Write-StatusDiag 'again'
    $diagLines = Get-DiagLine
    Confirm-Equal $diagLines.Count 2 'diag on: the second call appends rather than replaces'
    Confirm-True ($diagLines[1] -match 'again$') 'diag on: the second line holds the second reason'
    $diagBytes = [System.IO.File]::ReadAllBytes($diagLog)
    Confirm-True (-not ($diagBytes[0] -eq 0xEF -and $diagBytes[1] -eq 0xBB -and $diagBytes[2] -eq 0xBF)) 'diag file: UTF-8 without a BOM'
    Confirm-Equal $diagBytes[$diagBytes.Count - 1] 10 'diag file: every line ends with a newline'

    # An exception message can carry newlines, and one call has to stay one line.
    Clear-DiagLog
    Write-StatusDiag "two`r`nlines`tand   spaces "
    $diagLines = Get-DiagLine
    Confirm-Equal $diagLines.Count 1 'diag on: a reason with newlines in it is still one line'
    Confirm-True ($diagLines[0].EndsWith('two lines and spaces')) "diag on: the whitespace is folded, got '$($diagLines[0])'"

    # Nothing reaches the pipeline, so a call can sit in front of a return without changing it.
    Confirm-Equal @(Write-StatusDiag 'quiet').Count 0 'diag on: the helper returns nothing'

    # The values that read as off, and a sample of the values that read as on.
    foreach ($off in @('0', 'false', 'FALSE', 'no', 'off', ' false ')) {
        Clear-DiagLog
        $env:CLAUDE_STATUSLINE_DEBUG = $off
        Write-StatusDiag 'not this one'
        Confirm-True (-not (Test-Path -LiteralPath $diagLog)) "diag off: '$off' writes nothing"
    }
    foreach ($on in @('1', 'true', 'yes', 'please')) {
        Clear-DiagLog
        $env:CLAUDE_STATUSLINE_DEBUG = $on
        Write-StatusDiag 'this one'
        Confirm-Equal (Get-DiagLine).Count 1 "diag on: '$on' writes"
    }

    # A log that cannot be written costs the line and nothing else. TEMP points at a file here, so the
    # append throws inside the helper the way a read-only temp folder would.
    $env:CLAUDE_STATUSLINE_DEBUG = '1'
    $diagBlocked = Join-Path $tmp 'diag-blocked'
    [System.IO.File]::WriteAllText($diagBlocked, 'not a directory')
    $env:TEMP = $diagBlocked
    $diagThrew = $false
    try { Write-StatusDiag 'into a path that is not a directory' } catch { $diagThrew = $true }
    Confirm-True (-not $diagThrew) 'diag write failure: the helper does not throw'
    $env:TEMP = $diagTemp

    # The cache says miss, then hit, and the record the caller gets is the same either way.
    Clear-DiagLog
    $diagCacheDir = Join-Path $diagTemp 'cache'
    $before = $script:probeCalls
    $diagMiss = Get-CachedGitBranch $cacheRepo 1500 $diagCacheDir 5
    Confirm-Equal $script:probeCalls ($before + 1) 'diag cache: the first call still probes'
    Confirm-Equal $diagMiss.Branch 'main' 'diag cache: the miss still returns the probe record'
    Confirm-True ($diagMiss -is [hashtable]) 'diag cache: the miss returns one record, not a pipeline of two things'
    Confirm-Equal (Measure-DiagMatch 'git cache: miss') 1 "diag cache: the miss is logged, got '$((Get-DiagLine) -join ' | ')'"
    Clear-DiagLog
    $diagHit = Get-CachedGitBranch $cacheRepo 1500 $diagCacheDir 5
    Confirm-Equal $script:probeCalls ($before + 1) 'diag cache: the second call still hits'
    Confirm-Equal $diagHit.Branch 'main' 'diag cache: the hit still returns the record from the file'
    Confirm-True ($diagHit -is [hashtable]) 'diag cache: the hit returns one record, not a pipeline of two things'
    Confirm-Equal (Measure-DiagMatch 'git cache: hit') 1 "diag cache: the hit is logged, got '$((Get-DiagLine) -join ' | ')'"
    # A lifetime of 0 never looks at the cache at all, and says so.
    Clear-DiagLog
    $null = Get-CachedGitBranch $cacheRepo 1500 $diagCacheDir 0
    Confirm-Equal (Measure-DiagMatch 'git cache: skipped') 1 'diag cache: a lifetime of 0 says the cache was skipped'
    # A corrupt entry is still a miss, and now says so.
    Clear-DiagLog
    [System.IO.File]::WriteAllText((Join-Path $diagCacheDir (Get-CacheEntryName $cacheRepo)), '{ not json')
    $diagCorrupt = Get-CachedGitBranch $cacheRepo 1500 $diagCacheDir 5
    Confirm-Equal $diagCorrupt.Branch 'main' 'diag cache: a corrupt entry still returns the probe record'
    Confirm-Equal (Measure-DiagMatch 'git cache: read failed') 1 'diag cache: a corrupt entry logs the read failure'

    # With the variable unset the same calls leave no log at all.
    Clear-DiagLog
    Remove-Item Env:CLAUDE_STATUSLINE_DEBUG -ErrorAction SilentlyContinue
    $diagQuietDir = Join-Path $diagTemp 'cache-quiet'
    $null = Get-CachedGitBranch $cacheRepo 1500 $diagQuietDir 5
    $null = Get-CachedGitBranch $cacheRepo 1500 $diagQuietDir 5
    Confirm-True (-not (Test-Path -LiteralPath $diagLog)) 'diag off: the cache writes no log'

    # The state file: a corrupt file still reads as no state, and now says why; a write says it wrote.
    $env:CLAUDE_STATUSLINE_DEBUG = '1'
    Clear-DiagLog
    $diagStateDir = Join-Path $diagTemp 'claude-statusline-state'
    New-Item -ItemType Directory -Force $diagStateDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $diagStateDir 'diag-session.json'), '{ not json')
    Confirm-Equal (Read-SessionState 'diag-session') $null 'diag state: a corrupt file still reads as no state'
    Confirm-Equal (Measure-DiagMatch 'state read failed') 1 "diag state: the read failure is logged, got '$((Get-DiagLine) -join ' | ')'"
    Clear-DiagLog
    Write-SessionState 'diag-session' (Merge-SessionState $null (Get-StatePayload 1.07) 1767225600)
    Confirm-True (Test-Path -LiteralPath (Join-Path $diagStateDir 'diag-session.json')) 'diag state: the write still happens'
    Confirm-Equal (Measure-DiagMatch 'state: written') 1 'diag state: the write is logged'
    Clear-DiagLog
    Confirm-Equal (Read-SessionState 'diag-session').cost_usd 1.07 'diag state: the record still reads back'
    Confirm-Equal (Measure-DiagMatch 'state: read') 1 'diag state: the read is logged'

    # The log is rolled over rather than left to grow: an append that would take the file past the cap
    # moves it aside first. The cap is spelled out here rather than read from the script, so the two
    # cannot agree with each other about a wrong number.
    $diagCap = 4194304
    $diagRolled = $diagLog + '.1'
    function Clear-DiagRollover { if (Test-Path -LiteralPath $diagRolled) { Remove-Item -LiteralPath $diagRolled -Recurse -Force } }
    function Get-DiagLogSize { return (Get-Item -LiteralPath $diagLog).Length }
    Clear-DiagLog
    Clear-DiagRollover
    # Room for the line: it lands in the same file and nothing is moved aside.
    [System.IO.File]::WriteAllText($diagLog, ('x' * ($diagCap - 200)))
    Write-StatusDiag 'still room'
    Confirm-True ((Get-DiagLogSize) -gt ($diagCap - 200) -and (Get-DiagLogSize) -le $diagCap) "diag rollover: under the cap the line is appended, size $(Get-DiagLogSize)"
    Confirm-True (-not (Test-Path -LiteralPath $diagRolled)) 'diag rollover: under the cap nothing is moved aside'
    # No room: the full log becomes .log.1 and the line starts a fresh one.
    [System.IO.File]::WriteAllText($diagLog, ('y' * $diagCap))
    Write-StatusDiag 'over the cap'
    $diagLines = Get-DiagLine
    Confirm-Equal $diagLines.Count 1 'diag rollover: the new log holds only the line that crossed the cap'
    Confirm-True ($diagLines[0].EndsWith('over the cap')) 'diag rollover: and that line is the one just written'
    Confirm-True (Test-Path -LiteralPath $diagRolled) 'diag rollover: the full log is kept as .log.1'
    Confirm-Equal (Get-Item -LiteralPath $diagRolled).Length $diagCap 'diag rollover: the kept file is the one that was full'
    # A second rollover replaces the first .log.1 rather than piling up a third file.
    [System.IO.File]::WriteAllText($diagLog, ('z' * $diagCap))
    Write-StatusDiag 'over the cap again'
    $diagStream = [System.IO.File]::OpenRead($diagRolled)
    try { $diagFirstByte = $diagStream.ReadByte() } finally { $diagStream.Dispose() }
    Confirm-Equal $diagFirstByte 122 'diag rollover: the second rollover replaced the first .log.1'
    Confirm-Equal @(Get-ChildItem -LiteralPath $diagTemp -File -Filter 'claude-statusline-diag.log*').Count 2 'diag rollover: two files at most, never a third'

    # Bounded through the real callers: with the log parked just under the cap, a run of cache reads and
    # state reads and writes rolls it over instead of pushing past it.
    Clear-DiagLog
    Clear-DiagRollover
    [System.IO.File]::WriteAllText($diagLog, ('x' * ($diagCap - 120)))
    $diagBoundDir = Join-Path $diagTemp 'cache-bound'
    $diagOverCap = 0
    for ($i = 0; $i -lt 12; $i++) {
        $null = Get-CachedGitBranch $cacheRepo 1500 $diagBoundDir 5
        $null = Read-SessionState 'diag-session'
        Write-SessionState 'diag-session' (Merge-SessionState $null (Get-StatePayload 1.07) 1767225600)
        if ((Get-DiagLogSize) -gt $diagCap) { $diagOverCap++ }
    }
    Confirm-Equal $diagOverCap 0 'diag rollover: the log never passes the cap across a run of renders'
    Confirm-True (Test-Path -LiteralPath $diagRolled) 'diag rollover: the run rolled the full log aside'
    Confirm-True ((Get-DiagLine).Count -gt 0) 'diag rollover: and carried on logging into the fresh file'

    # A rollover that cannot happen is as silent as a write that cannot happen: a directory holds the
    # .log.1 name here, so the move throws where the append would.
    Clear-DiagLog
    Clear-DiagRollover
    New-Item -ItemType Directory -Force $diagRolled | Out-Null
    [System.IO.File]::WriteAllText($diagLog, ('w' * $diagCap))
    $diagRollThrew = $false
    $diagRollOut = @('not run')
    try { $diagRollOut = @(Write-StatusDiag 'the rollover cannot happen') } catch { $diagRollThrew = $true }
    Confirm-True (-not $diagRollThrew) 'diag rollover failure: the helper does not throw'
    Confirm-Equal $diagRollOut.Count 0 'diag rollover failure: nothing reaches the pipeline'
    Confirm-Equal (Get-DiagLogSize) $diagCap 'diag rollover failure: the log is left exactly as it was'
    Clear-DiagRollover

    # One record cannot set the size of the file on its own: a reason of any length is cut and marked,
    # so a pathological exception message cannot land in the file the rollover has just emptied and
    # leave the log over the cap again.
    Clear-DiagLog
    Clear-DiagRollover
    Write-StatusDiag ('q' * 5000)
    $diagLines = Get-DiagLine
    Confirm-Equal $diagLines.Count 1 'diag record cap: an enormous reason is still one line'
    Confirm-Equal $diagLines[0].Split(' ', 3)[2] (('q' * 1000) + ' [cut]') 'diag record cap: the reason is cut at 1000 characters and marked'
    Confirm-True ((Get-DiagLogSize) -lt 1200) "diag record cap: the record is bounded, size $(Get-DiagLogSize)"
    [System.IO.File]::WriteAllText($diagLog, ('y' * $diagCap))
    Write-StatusDiag ('r' * 5000)
    Confirm-True ((Get-DiagLogSize) -le $diagCap) 'diag record cap: an enormous reason on a full log still leaves the log at or under the cap'

    # The rollover is taken under a named mutex with no wait at all, so a render that finds another one
    # already rotating appends rather than waiting on it. A mutex belongs to a thread and is reentrant,
    # so only another process can hold it against this one: a child pwsh takes it, says so by writing a
    # file, and keeps it until this one says to let go. The name is spelled out here rather than read
    # from the script, so the two cannot agree with each other about the wrong one.
    Clear-DiagLog
    Clear-DiagRollover
    [System.IO.File]::WriteAllText($diagLog, ('y' * $diagCap))
    $diagReady = Join-Path $tmp 'diag-lock-ready'
    $diagGo = Join-Path $tmp 'diag-lock-go'
    foreach ($diagSignal in @($diagReady, $diagGo)) { if (Test-Path -LiteralPath $diagSignal) { Remove-Item -LiteralPath $diagSignal -Force } }
    $diagHoldFile = Join-Path $tmp 'diag-hold-mutex.ps1'
    [System.IO.File]::WriteAllText($diagHoldFile, @'
param([string] $Ready, [string] $Go)
$m = [System.Threading.Mutex]::new($false, 'claude-code-statusline-diag-rollover')
[void] $m.WaitOne()
[System.IO.File]::WriteAllText($Ready, 'held')
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not [System.IO.File]::Exists($Go) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
$m.ReleaseMutex()
$m.Dispose()
'@)
    $diagPsi = [System.Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
    foreach ($diagArg in @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', $diagHoldFile, $diagReady, $diagGo)) { $diagPsi.ArgumentList.Add($diagArg) }
    $diagPsi.UseShellExecute = $false
    $diagPsi.CreateNoWindow = $true
    $diagHolder = [System.Diagnostics.Process]::Start($diagPsi)
    try {
        $diagDeadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not [System.IO.File]::Exists($diagReady) -and [DateTime]::UtcNow -lt $diagDeadline) { Start-Sleep -Milliseconds 20 }
        Confirm-True ([System.IO.File]::Exists($diagReady)) 'diag rollover lock: another process holds the mutex the rollover takes'
        $diagLockThrew = $false
        $diagLockOut = @('not run')
        try { $diagLockOut = @(Write-StatusDiag 'another render is rotating') } catch { $diagLockThrew = $true }
        Confirm-True (-not $diagLockThrew) 'diag rollover lock: a rollover it cannot take does not throw'
        Confirm-Equal $diagLockOut.Count 0 'diag rollover lock: and nothing reaches the pipeline'
        Confirm-True (-not (Test-Path -LiteralPath $diagRolled)) 'diag rollover lock: the file the other render is rotating is left alone'
        Confirm-True ((Get-DiagLogSize) -gt $diagCap) 'diag rollover lock: the line is appended anyway rather than waited for, which is what makes the cap approximate'
    } finally {
        [System.IO.File]::WriteAllText($diagGo, 'go')
        [void] $diagHolder.WaitForExit(30000)
        $diagHolder.Dispose()
    }
    # With the mutex free again the next record rotates as it always did.
    Write-StatusDiag 'the other render has finished'
    Confirm-True (Test-Path -LiteralPath $diagRolled) 'diag rollover lock: once the mutex is free the rollover happens'
    Confirm-Equal (Get-DiagLine).Count 1 'diag rollover lock: and the fresh log holds only the new record'
    Clear-DiagLog
    Clear-DiagRollover

    # The whole script, run twice on one payload: the log changes nothing a terminal would show, and
    # the run with it on leaves a log behind.
    Clear-DiagLog
    $diagRenderDir = Join-Path $diagTemp 'render'
    New-Item -ItemType Directory -Force $diagRenderDir | Out-Null
    $diagPayload = ([ordered]@{ model = @{ display_name = 'M' }; session_id = 'diag-render'
                                cost = @{ total_cost_usd = 0.5 }; workspace = @{ current_dir = $diagRenderDir } } | ConvertTo-Json -Compress)
    Remove-Item Env:CLAUDE_STATUSLINE_DEBUG -ErrorAction SilentlyContinue
    $diagQuietRun = Invoke-StatusLine $diagPayload $null 0
    Confirm-True (-not (Test-Path -LiteralPath $diagLog)) 'diag render: a render with the variable unset writes no log'
    $env:CLAUDE_STATUSLINE_DEBUG = '1'
    $diagLoudRun = Invoke-StatusLine $diagPayload $null 0
    Confirm-Equal ($diagLoudRun.Lines -join "`n") ($diagQuietRun.Lines -join "`n") 'diag render: the log changes nothing on the line'
    Confirm-Equal $diagLoudRun.Err.Count 0 'diag render: nothing on stderr'
    Confirm-Equal $diagLoudRun.ExitCode 0 'diag render: exit 0'
    Confirm-True ((Get-DiagLine).Count -gt 0) 'diag render: the child wrote the log'
    Confirm-Equal (@(Get-DiagLine | Where-Object { $_ -notmatch $diagStamp }).Count) 0 'diag render: every line the child wrote carries the stamp and the process id'
    Confirm-Equal (@(Get-DiagLine | Where-Object { $_.Split(' ')[1] -eq "$PID" }).Count) 0 'diag render: the child logged under its own process id, not the one running the test'
} finally {
    if ($null -ne $oldTemp) { $env:TEMP = $oldTemp } else { Remove-Item Env:TEMP -ErrorAction SilentlyContinue }
    if ($null -ne $oldDebug) { $env:CLAUDE_STATUSLINE_DEBUG = $oldDebug } else { Remove-Item Env:CLAUDE_STATUSLINE_DEBUG -ErrorAction SilentlyContinue }
}
. (Import-ScriptFunction $script @('Get-GitBranch'))

# No git key at all falls through to Get-GitBranch. GIT_CEILING_DIRECTORIES (set above) stops the probe
# from walking out of the temp tree, so this cannot find a repository on the machine running the test.
# The cache is off in the config here: with it on, the walk to a root could leave the temp tree and the
# entry would be read from the machine's own cache directory.
$branchProbeDir = Join-Path $tmp 'branch-unit-not-a-repo'
New-Item -ItemType Directory -Force $branchProbeDir | Out-Null
Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{ workspace = @{ current_dir = $branchProbeDir } }) $branchNoCacheCfg)) 'branch no git key: falls through to git and finds no repo'
Confirm-True ($null -eq (Get-BranchSegment ([pscustomobject]@{}) $branchNoCacheCfg)) 'branch no git key and no dir: segment omitted'

Write-Host '== git' -ForegroundColor Cyan
# The renders here probe real repositories, and the probe cache lives under TEMP, so the child pwsh
# gets a TEMP under $tmp for the group and the entries land there rather than in the machine's own
# temp folder. The in-process cache cases pass a directory of their own.
$oldTemp = $env:TEMP
$gitTemp = Join-Path $tmp 'temp-git'
New-Item -ItemType Directory -Force $gitTemp | Out-Null
$env:TEMP = $gitTemp
$gitRenderCacheDir = Join-Path $gitTemp 'claude-statusline'
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
# git.timeoutMs moves the wait. The hang fake pings for ten seconds, so 3000 still kills it, and with
# 100 the render is back well inside the 3000 case's floor; its budget is loose because a whole pwsh
# start sits around the 100 ms wait, and its marker is not asserted for the same reason. Each gets its
# own copy of the fake. Neither directory is a repository, so the cache is never consulted and every
# render really waits.
$fakeHang3000 = Write-FakeGit 'fake-hang-3000' "echo ran > `"%~dp0fake.ran`"`r`nping -n 11 -w $pingTag 127.0.0.1 > nul`r`nexit 0"
$fakeHang100 = Write-FakeGit 'fake-hang-100' "echo ran > `"%~dp0fake.ran`"`r`nping -n 11 -w $pingTag 127.0.0.1 > nul`r`nexit 0"
$gitTimeout3000 = Write-TempConfig 'git-timeout-3000.json' '{ "git": { "timeoutMs": 3000 } }'
$gitTimeout100 = Write-TempConfig 'git-timeout-100.json' '{ "git": { "timeoutMs": 100 } }'
$gitCases.Add(@{ Name = 'git hangs, timeoutMs 3000'; Dir = $notRepo; NoBranch = $true; NoStderr = $true; MinMs = 3000; MaxMs = 6000; Marker = (Join-Path $fakeHang3000 'fake.ran'); NoPing = $true
                 PathPrefix = $fakeHang3000; Config = $gitTimeout3000 })
$gitCases.Add(@{ Name = 'git hangs, timeoutMs 100'; Dir = $notRepo; NoBranch = $true; NoStderr = $true; MinMs = 100; MaxMs = 4000; NoPing = $true
                 PathPrefix = $fakeHang100; Config = $gitTimeout100 })

function Get-FakePingCount([string] $Tag) {
    return @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "-n 11 -w $Tag " }).Count
}

foreach ($case in $gitCases) {
    $r = Invoke-StatusLine (Get-GitPayload $case.Dir) $case.Config 0 $case.PathPrefix
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

# Every render of a real repository left one entry in the redirected TEMP, plus the sweep stamp, and
# the renders of the plain directory, with real git, the failing fake and the hanging fakes, left
# none: those never reach the cache. Each entry is named for its repository root.
$gitRepoCases = @($gitCases | Where-Object { -not $_.NoBranch })
Confirm-Equal (Get-CacheFileCount $gitRenderCacheDir) ($gitRepoCases.Count + $(if ($gitRepoCases.Count) { 1 } else { 0 })) "git renders: one cache entry per repository rendered ($($gitRepoCases.Count)) and the sweep stamp"
foreach ($case in $gitRepoCases) {
    Confirm-True (Test-Path -LiteralPath (Join-Path $gitRenderCacheDir (Get-CacheEntryName $case.Dir))) "git renders: entry for $($case.Name) is named for its root"
}
Confirm-True (-not (Test-Path (Join-Path $gitRenderCacheDir '*.tmp'))) 'git renders: no .tmp left behind'

if ($haveGit) {
    # The success criterion for the cache, end to end: a second render of the same clean repository
    # within the lifetime starts no git process. The first render fills the entry with real git; the
    # second runs with a git on PATH that only writes a marker and fails, and still prints the branch.
    $fakeFailCached = Write-FakeGit 'fake-fail-cached' "echo ran > `"%~dp0fake.ran`"`r`necho fatal: not a git repository 1>&2`r`nexit 128"
    $cachedMarker = Join-Path $fakeFailCached 'fake.ran'
    # A long lifetime, so two whole child renders cannot straddle the shipped five seconds on a slow day.
    $gitCache300 = Write-TempConfig 'git-cache-300.json' '{ "git": { "cacheSeconds": 300 } }'
    $r1 = Invoke-StatusLine (Get-GitPayload $clean) $gitCache300 0
    $r2 = Invoke-StatusLine (Get-GitPayload $clean) $gitCache300 0 $fakeFailCached
    $text1 = ConvertTo-PlainText ($r1.Lines -join "`n")
    $text2 = ConvertTo-PlainText ($r2.Lines -join "`n")
    Confirm-True ($text1.Contains("$iconHome main")) "git clean, first render: branch printed, got '$text1'"
    Confirm-True ($text2.Contains("$iconHome main")) "git clean, second render with a failing git: branch still printed, got '$text2'"
    Confirm-Equal ($r2.Lines -join "`n") ($r1.Lines -join "`n") 'git clean, second render with a failing git: the same bytes as the first'
    Confirm-True (-not (Test-Path $cachedMarker)) 'git clean, second render with a failing git: no git process was started'
    Confirm-True ($r2.Err.Count -eq 0) "git clean, second render with a failing git: nothing on stderr, got '$($r2.Err -join ' | ')'"
    Write-Host ("{0,-40} {1,5:N0} ms  {2}" -f 'clean, cached', $r2.Ms, $text2)
    # The same second render with the cache off in the config reaches the failing fake and loses the
    # branch: the control that the marker really is the proof above, and the one end-to-end check that
    # git.cache reaches the segment. cacheSeconds 0 is covered in process below.
    $gitCacheOff = Write-TempConfig 'git-cache-off.json' '{ "git": { "cache": false } }'
    $r3 = Invoke-StatusLine (Get-GitPayload $clean) $gitCacheOff 0 $fakeFailCached
    $text3 = ConvertTo-PlainText ($r3.Lines -join "`n")
    Confirm-True (-not $text3.Contains($iconHome)) "git clean, cache off, failing git: no branch, got '$text3'"
    Confirm-True (Test-Path $cachedMarker) 'git clean, cache off, failing git: the fake was started'
    Remove-Item -LiteralPath $cachedMarker -Force
    # The dirty fixture round-trips its counts through a render's entry.
    $r5 = Invoke-StatusLine (Get-GitPayload $mixed) $gitCache300 0
    $r6 = Invoke-StatusLine (Get-GitPayload $mixed) $gitCache300 0 $fakeFailCached
    Confirm-Equal (ConvertTo-PlainText ($r6.Lines -join "`n")) (ConvertTo-PlainText ($r5.Lines -join "`n")) 'git mixed, second render with a failing git: the same counts'
    Confirm-True ((ConvertTo-PlainText ($r6.Lines -join "`n")).Contains("$iconHome main +1 ~1 ?1 $iconDirty")) 'git mixed, second render with a failing git: the counts come from the entry'
    Confirm-True (-not (Test-Path $cachedMarker)) 'git mixed, second render with a failing git: no git process was started'

    # In process, with a cache directory of its own: the entry answers while git fails, and a checkout
    # moves HEAD so the next call probes again and sees the new branch. A failing probe on a miss
    # would cache its null, so the failing fake is only ever put on PATH for a hit or a lifetime of 0.
    $realCache = Join-Path $tmp 'cache-real'
    $cacheRepoReal = Initialize-TestRepo 'repo-cache'; Add-Commit $cacheRepoReal
    $g = Get-CachedGitBranch $cacheRepoReal $gitTimeoutMs $realCache 300
    Confirm-Equal $g.Branch 'main' 'cached probe: the first call answers from git'
    Confirm-Equal $g.Dirty $false 'cached probe: clean'
    Confirm-Equal (Get-CacheFileCount $realCache) 2 'cached probe: one entry and the sweep stamp written'
    $oldPath = $env:PATH
    try {
        $env:PATH = $fakeFailCached + [System.IO.Path]::PathSeparator + $env:PATH
        Confirm-Equal (Get-GitBranch $cacheRepoReal $gitTimeoutMs) $null 'failing git on PATH: a direct probe gets nothing (control)'
        Confirm-True (Test-Path $cachedMarker) 'failing git on PATH: the fake ran for the direct probe (control)'
        Remove-Item -LiteralPath $cachedMarker -Force
        $g = Get-CachedGitBranch $cacheRepoReal $gitTimeoutMs $realCache 300
        Confirm-Equal $g.Branch 'main' 'cached probe with a failing git: answers from the entry'
        Confirm-True (-not (Test-Path $cachedMarker)) 'cached probe with a failing git: git was never started'
        Confirm-Equal (Get-CachedGitBranch $cacheRepoReal $gitTimeoutMs $realCache 0) $null 'cached probe with a failing git and lifetime 0: the probe runs and fails'
        Confirm-True (Test-Path $cachedMarker) 'cached probe with a failing git and lifetime 0: the fake ran'
        Remove-Item -LiteralPath $cachedMarker -Force
        Confirm-Equal (Get-CachedGitBranch $cacheRepoReal $gitTimeoutMs $realCache 300).Branch 'main' 'cached probe with a failing git: lifetime 0 wrote nothing, so the entry still answers'
    } finally { $env:PATH = $oldPath }
    git -C $cacheRepoReal checkout -q -b topic
    $g = Get-CachedGitBranch $cacheRepoReal $gitTimeoutMs $realCache 300
    Confirm-Equal $g.Branch 'topic' 'cached probe after a checkout: HEAD moved, so git was asked and the new branch shows'
    Set-Content (Join-Path $cacheRepoReal 'new.txt') 'x'
    $g = Get-CachedGitBranch $cacheRepoReal $gitTimeoutMs $realCache 300
    Confirm-Equal $g.Untracked 0 'cached probe after a new file: no stamp moved, so the entry still says clean until it ages out'
    git -C $cacheRepoReal add new.txt
    $g = Get-CachedGitBranch $cacheRepoReal $gitTimeoutMs $realCache 300
    Confirm-Equal $g.Staged 1 'cached probe after git add: the index moved, so git was asked and the staged file shows'
    Confirm-Equal $g.Branch 'topic' 'cached probe after git add: still on topic'
    # The recovery half of the lag: with a lifetime of one second, a new file shows once the entry
    # has aged out.
    $g = Get-CachedGitBranch $cacheRepoReal $gitTimeoutMs (Join-Path $tmp 'cache-recover') 1
    Confirm-Equal $g.Untracked 0 'cached probe, lifetime 1: clean to start with'
    Set-Content (Join-Path $cacheRepoReal 'later.txt') 'y'
    Start-Sleep -Milliseconds 1100
    $g = Get-CachedGitBranch $cacheRepoReal $gitTimeoutMs (Join-Path $tmp 'cache-recover') 1
    Confirm-Equal $g.Untracked 1 'cached probe, lifetime 1: the new file shows once the entry has aged out'

    # Ref-only changes: a fetch, a push, an empty commit and a soft reset move no file the work tree
    # can see and neither index nor HEAD, only refs, ORIG_HEAD, FETCH_HEAD and the reflog. Each must
    # invalidate the entry, or ahead/behind would sit stale for the whole lifetime. A bare repository
    # on disk stands in for the remote, and a second clone pushes to it. The lifetime is long, so a
    # changed count can only mean a changed stamp.
    $bare = Join-Path $tmp 'remote.git'
    git init -q --bare -b main $bare
    $syncA = Initialize-TestRepo 'repo-sync-a'; Add-Commit $syncA
    git -C $syncA remote add origin $bare
    git -C $syncA push -q -u origin main
    $syncB = Join-Path $tmp 'repo-sync-b'
    git clone -q $bare $syncB
    $syncCache = Join-Path $tmp 'cache-sync'
    function Get-SyncCount { $g = Get-CachedGitBranch $syncA $gitTimeoutMs $syncCache 300; return "$($g.Ahead)/$($g.Behind)" }
    Confirm-Equal (Get-SyncCount) '0/0' 'ref-only: in step with the remote to start with'
    Add-Commit $syncB 'from b'
    git -C $syncB push -q
    Confirm-Equal (Get-SyncCount) '0/0' 'ref-only: a push from elsewhere moves nothing here, so the entry still says 0/0 (control)'
    git -C $syncA fetch -q
    Confirm-Equal (Get-SyncCount) '0/1' 'ref-only: git fetch invalidates the entry and shows one behind'
    Confirm-Equal (Get-GitBranch $syncA $gitTimeoutMs).Behind 1 'ref-only: a direct probe agrees (control)'
    git -C $syncA merge -q --ff-only origin/main
    Confirm-Equal (Get-SyncCount) '0/0' 'ref-only: a fast-forward merge invalidates and shows in step'
    git -C $syncA @gitCfg commit -q --allow-empty -m empty
    Confirm-Equal (Get-SyncCount) '1/0' 'ref-only: an empty commit invalidates and shows one ahead'
    git -C $syncA reset -q --soft HEAD~1
    Confirm-Equal (Get-SyncCount) '0/0' 'ref-only: a soft reset invalidates and shows in step again'
    git -C $syncA @gitCfg commit -q --allow-empty -m empty2
    Confirm-Equal (Get-SyncCount) '1/0' 'ref-only: the next empty commit shows one ahead'
    git -C $syncA push -q
    Confirm-Equal (Get-SyncCount) '0/0' 'ref-only: git push invalidates and clears the ahead count'

    # A real worktree: .git is a file, the entry is keyed on the worktree path, its own index and HEAD
    # stamp it, and a ref written in the main repository reaches it through commondir.
    $wtMain = Initialize-TestRepo 'repo-wt-main'; Add-Commit $wtMain
    $wt = Join-Path $tmp 'repo-wt'
    git -C $wtMain worktree add -q $wt -b wt-branch
    $wtPair = Get-GitRepoRoot $wt
    Confirm-Equal $wtPair.WorkTree $wt 'worktree: the work tree is the worktree path'
    Confirm-Equal $wtPair.GitDir (Join-Path $wtMain '.git' 'worktrees' 'repo-wt') 'worktree: the git directory is under the main repository'
    Confirm-True ((Get-GitStamp $wtPair.GitDir).Contains('|')) 'worktree: its stamps carry the main repository after a bar'
    $wtCache = Join-Path $tmp 'cache-wt'
    $g = Get-CachedGitBranch $wt $gitTimeoutMs $wtCache 300
    Confirm-Equal $g.Branch 'wt-branch' 'worktree: the first call answers from git'
    Confirm-True (Test-Path -LiteralPath (Join-Path $wtCache (Get-CacheEntryName $wt))) 'worktree: the entry is named for the worktree path'
    $oldPath = $env:PATH
    try {
        $env:PATH = $fakeFailCached + [System.IO.Path]::PathSeparator + $env:PATH
        Confirm-Equal (Get-CachedGitBranch $wt $gitTimeoutMs $wtCache 300).Branch 'wt-branch' 'worktree: the second call answers from the entry with git failing'
        Confirm-True (-not (Test-Path $cachedMarker)) 'worktree: git was never started'
    } finally { $env:PATH = $oldPath }
    Set-Content (Join-Path $wt 'wt.txt') 'w'
    git -C $wt add wt.txt
    Confirm-Equal (Get-CachedGitBranch $wt $gitTimeoutMs $wtCache 300).Staged 1 'worktree: git add moves its own index, so git was asked and the staged file shows'
    git -C $wt @gitCfg commit -q -m wt
    $g = Get-CachedGitBranch $wt $gitTimeoutMs $wtCache 300
    Confirm-True ($g.Staged -eq 0 -and $g.Branch -eq 'wt-branch') 'worktree: a commit in the worktree invalidates and shows clean'
    git -C $wtMain branch newref
    $oldPath = $env:PATH
    try {
        $env:PATH = $fakeFailCached + [System.IO.Path]::PathSeparator + $env:PATH
        Confirm-Equal (Get-CachedGitBranch $wt $gitTimeoutMs $wtCache 0) $null 'worktree: with git failing and no lifetime the probe fails (control)'
        Remove-Item -LiteralPath $cachedMarker -Force
        Confirm-Equal (Get-CachedGitBranch $wt $gitTimeoutMs $wtCache 300) $null 'worktree: a branch created in the main repository invalidates the entry, so the failing git is asked'
        Confirm-True (Test-Path $cachedMarker) 'worktree: the failing git really ran'
        Remove-Item -LiteralPath $cachedMarker -Force
    } finally { $env:PATH = $oldPath }
    git -C $wtMain branch -D newref
    Confirm-Equal (Get-CachedGitBranch $wt $gitTimeoutMs $wtCache 300).Branch 'wt-branch' 'worktree: deleting that branch invalidates the cached null and git answers again'
    Confirm-Equal (Get-GitRepoRoot (Join-Path $wtMain 'sub-not-there')) $null 'worktree main: a missing directory is null'
    $wtStray = Join-Path $wtMain 'stray'
    New-Item -ItemType Directory -Force (Join-Path $wtStray '.git') | Out-Null
    Confirm-Equal (Get-GitRepoRoot $wtStray).WorkTree $wtMain 'worktree main: an empty .git folder in a subdirectory is walked past'
}

# The config gates the probe. A segment the active layout's list leaves out is never built, so an order
# without branch never launches git at all, which a marker-writing fake on PATH proves; the same fake
# with branch listed is launched and renders. The toggle is checked the same way, and the payload has no
# git object, so the fake is the only source of a branch.
$fakeMark = Write-FakeGit 'fake-mark' "echo ran > `"%~dp0fake.ran`"`r`necho ## main`r`nexit 0"
$markerPath = Join-Path $fakeMark 'fake.ran'
foreach ($case in @(
        @{ Name = 'order without branch';  Json = '{ "order": ["model", "folder"] }'; Ran = $false }
        @{ Name = 'order with branch';     Json = '{ "order": ["model", "branch"] }'; Ran = $true }
        @{ Name = 'rows without branch';   Json = '{ "layout": "two", "rows": [["model"], ["folder"]] }'; Ran = $false }
        @{ Name = 'rows with branch';      Json = '{ "layout": "two", "rows": [["model"], ["branch"]] }'; Ran = $true }
        @{ Name = 'order ignored by two';  Json = '{ "layout": "two", "order": ["model"] }'; Ran = $true }
        @{ Name = 'branch toggled off';    Json = '{ "order": ["model", "branch"], "segments": { "branch": false } }'; Ran = $false })) {
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    $r = Invoke-StatusLine (Get-GitPayload $notRepo) (Write-TempConfig "git-gate-$($case.Name -replace ' ', '-').json" $case.Json) 0 $fakeMark
    $text = ConvertTo-PlainText ($r.Lines -join "`n")
    $label = "git gate $($case.Name)"
    Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) "${label}: exit code 0, stderr empty"
    Confirm-Equal (Test-Path -LiteralPath $markerPath) $case.Ran "${label}: fake git launched is $($case.Ran)"
    if ($case.Ran) { Confirm-True ($text.Contains("$iconHome main")) "${label}: the branch the fake reports is on the line" }
    else { Confirm-True (-not $text.Contains($iconHome) -and -not $text.Contains($iconBranch)) "${label}: no branch on the line, got '$text'" }
    Write-Host ("{0,-40} {1,5:N0} ms  {2}" -f $label, $r.Ms, $text)
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
    if ($null -ne $oldTemp) { $env:TEMP = $oldTemp } else { Remove-Item Env:TEMP -ErrorAction SilentlyContinue }
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
$expectCommand = 'pwsh -NoProfile -NoLogo -NonInteractive -File "' + ($installedScript -replace '\\', '/') + '"'

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
    )
    '10-pr.json'                            = @(
        @{ Icon = $iconHome; Name = 'home' }
        @{ Icon = $iconDirty; Name = 'pencil' }
        @{ Icon = $iconLines; Name = 'lines' }
        @{ Icon = $iconLimit; Name = 'limits' }
        @{ Icon = $iconConflict; Name = 'warn' }
    )
    '11-worktree.json'                      = @(
        @{ Icon = $iconHome; Name = 'home' }
        @{ Icon = $iconLines; Name = 'lines' }
        @{ Icon = $iconLimit; Name = 'limits' }
        @{ Icon = $iconConflict; Name = 'warn' }
    )
    '12-context-alarm.json'                 = @(
        @{ Icon = $iconHome; Name = 'home' }
        @{ Icon = $iconBranch; Name = 'branch' }
        @{ Icon = $iconDirty; Name = 'pencil' }
        @{ Icon = $iconLines; Name = 'lines' }
        @{ Icon = $iconLimit; Name = 'limits' }
        @{ Icon = $iconConflict; Name = 'warn' }
    )
}
# 11 is the only sample whose session is in a worktree, so every other one has to keep the fork glyph
# off its line. One row per sample rather than ten written out by hand, and a sample added later is
# covered without an edit: a builder that started drawing the badge from a payload that names no
# worktree would show up on all of them at once.
foreach ($sample in $sampleFiles) {
    if ($sample.Name -eq '11-worktree.json') { continue }
    $rows = @(if ($absentGlyphs.ContainsKey($sample.Name)) { $absentGlyphs[$sample.Name] })
    $absentGlyphs[$sample.Name] = $rows + @{ Icon = $iconWorktree; Name = 'worktree' }
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
    '11-worktree.json'                      = @('model', 'context', 'cost', 'folder', 'branch')
    '12-context-alarm.json'                 = @('model', 'context', 'cost', 'folder')
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
    '11-worktree.json'                      = @{
        branch = @{ Icon = $iconBranch; Full = "$iconBranch review/x $iconWorktree wt-review ~2 $iconDirty"; Short = "$iconBranch review/x $iconDirty" }
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
    # 06's context marker is the whole segment text rather than the percentage: nothing in it moves,
    # every part is fixed at 32% of a 200k window, and the payload's current_usage is 57500 read of
    # 62500, so it is what pins the cached suffix to the end of the segment at the unset width.
    '06-limits-badges-lines.json'           = @{
        model  = "$iconModel Fable 5.1"; cost = "$iconCost `$$('{0:N2}' -f 1.07)"
        context = "$iconCtx 32% $(($blockFull * 3) + ($blockLight * 7)) $(K 64000)/$(K 200000) 92% cached"
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
    '11-worktree.json'                      = @{
        model  = "$iconModel Sonnet 5"; context = "$iconCtx 21%"; cost = "$iconCost `$$('{0:N2}' -f 0.75)"
        folder = "$iconFolder wt-review"; branch = "$iconBranch review/x $iconWorktree wt-review ~2 $iconDirty"
    }
    '12-context-alarm.json'                 = @{
        model = "$iconModel Sonnet 5"; context = "$iconCtx 92%"; cost = "$iconCost `$$('{0:N2}' -f 2.4)"
        folder = "$iconFolder alarm-demo"
    }
}
# The samples whose model segment the alarm turns red with the built-in alarm of 90: 12 sits at 92% of a
# standard window and 02 at 90% of a 1M one, which is the boundary the alarm fires on. The alarm reads
# the percentage whatever the window size, so 02's fixed 90 band and the alarm agree and the context
# segment and the model turn red together there. Every other sample keeps the model's own cyan, which is
# what holds the rest of the matrix to the colours it printed before this key existed. The markers are
# plain text and cannot see any of it, so the colour is checked raw below.
$alarmSamples = @('02-feature-dirty-high.json', '12-context-alarm.json')
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
    branch  = @($iconHome, $iconBranch, $iconDirty, $iconAhead, $iconBehind, $iconConflict, $iconWorktree)
}
# The segment behind each row of the absence table, so a row can be skipped when its segment is off
# (the per-segment absence assertions cover that case instead, for every glyph the segment owns).
$glyphSegment = @{
    context = 'context'; cost = 'cost'; folder = 'folder'; lines = 'lines'; limits = 'limits'; warn = 'model'
    home = 'branch'; pencil = 'branch'; branch = 'branch'; worktree = 'branch'
    fast = 'badges'; think = 'badges'; effort = 'badges'; vim = 'badges'
}
# A config record for the matrix. Rows is what the script prints from this config, read the way the
# script reads it: the order key for layout one, the two rows for layout two. Enabled is the segments
# the script will build, toggled on and listed on a row, so a segment the order leaves out is checked
# for absence like one toggled off. Widths is the column list the config renders at, every width in
# -Columns unless the config asks for fewer.
function Get-ConfigRecord([string] $Name, [string] $Path, $Parsed, [int[]] $Widths = $Columns) {
    $rows = @(if ($Parsed.Layout -eq 'two') { $Parsed.Rows } else { , $Parsed.Order })
    $listed = @($rows | ForEach-Object { $_ })
    $enabled = @{}
    foreach ($n in $allSegments) { $enabled[$n] = [bool] ($Parsed.Segments[$n] -and $n -in $listed) }
    return @{ Name = $Name; Path = $Path; Layout = $Parsed.Layout; Style = $Parsed.Style; Folder = $Parsed.Folder; Enabled = $enabled; Rows = $rows; Widths = $Widths }
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
    $configSet.Add((Get-ConfigRecord (Split-Path $resolved -Leaf) $resolved $parsed))
} else {
    foreach ($layout in @('one', 'two')) {
        foreach ($style in @('plain', 'powerline')) {
            $path = Write-TempConfig "$layout-$style.json" ('{ "layout": "' + $layout + '", "style": "' + $style + '" }')
            $configSet.Add((Get-ConfigRecord "$layout-$style" $path (Read-StatusConfig $path)))
        }
    }
    # Leaf mode through the whole script, so the registry's wiring of the config into Get-FolderSegment
    # is covered by a real render and not only by the unit call.
    $path = Write-TempConfig 'folder-leaf.json' '{ "folder": "leaf" }'
    $configSet.Add((Get-ConfigRecord 'folder-leaf' $path (Read-StatusConfig $path)))
    # The order and rows keys through the whole script: layout one in the registry order reversed with
    # cost left out, and layout two with the rows swapped and each reversed. The row checks below then
    # prove every marker lands on the row, and at the place on it, that the config asks for, and that
    # the segment left out is not on the line at all. Those checks run at the unset width, so the two
    # render there and at one narrow width, which keeps the fitting path covered without another 72
    # child renders.
    $keyWidths = @($Columns | Where-Object { $_ -in @(0, 60) })
    $reversed = @($allSegments | Where-Object { $_ -ne 'cost' })
    [array]::Reverse($reversed)
    $path = Write-TempConfig 'order-reversed.json' ('{ "layout": "one", "style": "plain", "order": ' + (ConvertTo-Json -InputObject $reversed -Compress) + ' }')
    $configSet.Add((Get-ConfigRecord 'order-reversed' $path (Read-StatusConfig $path) $keyWidths))
    $swappedRows = @(@(Get-SegmentOrder 'RowRank' 2), @(Get-SegmentOrder 'RowRank' 1))
    foreach ($row in $swappedRows) { [array]::Reverse($row) }
    $path = Write-TempConfig 'rows-swapped.json' ('{ "layout": "two", "style": "powerline", "rows": ' + (ConvertTo-Json -InputObject $swappedRows -Compress) + ' }')
    $configSet.Add((Get-ConfigRecord 'rows-swapped' $path (Read-StatusConfig $path) $keyWidths))
    Confirm-Equal ($configSet[$configSet.Count - 1].Rows[0] -join ',') 'lines,cost,limits,context' 'rows-swapped config: first row is the registry second row reversed'
    Confirm-Equal ($configSet[$configSet.Count - 1].Rows[1] -join ',') 'badges,pr,branch,folder,model' 'rows-swapped config: second row is the registry first row reversed'
    Confirm-Equal ($configSet[$configSet.Count - 2].Rows[0] -join ',') 'branch,folder,pr,badges,limits,lines,context,model' 'order-reversed config: one row, reversed, without cost'
}

# No sample carries a session_id, so no render in the matrix may write state. The child renders get a
# TEMP of their own here, and it has to be empty when the matrix is done.
$oldTemp = $env:TEMP
$matrixTemp = Join-Path $tmp 'temp-matrix'
New-Item -ItemType Directory -Force $matrixTemp | Out-Null
$env:TEMP = $matrixTemp
try {
foreach ($cfg in $configSet) {
    foreach ($c in $cfg.Widths) {
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
            # A -Config that turns model off and leaves this sample nothing else to show is a render with
            # no line in it at all: the zero-segment fallback stands in for the model segment, so a config
            # without one prints nothing rather than the claude line. That is the configured answer here
            # and not a fault, so it is asserted from the other side instead of failing the empty check.
            # None of the built-in configs reach it - every one of them lists model and leaves it on.
            $couldShow = @($allSegments | Where-Object { $cfg.Enabled[$_] -and $_ -in @($sampleSegments[$sample.Name]) })
            $blank = [string]::IsNullOrWhiteSpace(($lines -join ''))
            if (-not $cfg.Enabled['model'] -and $couldShow.Count -eq 0) {
                Confirm-True $blank "${label}: model off with nothing else buildable prints nothing"
                continue
            }
            if ($blank) { Confirm-True $false "${label}: empty output"; continue }
            Confirm-True ($lines.Count -le $maxLines) "${label}: $($lines.Count) lines, layout allows $maxLines"
            foreach ($line in $lines) {
                Confirm-True (-not [string]::IsNullOrWhiteSpace($line)) "${label}: empty line"
                if ($c -le 0) { continue }
                $w = Measure-VisibleWidth $line
                if ($w -le $c - 1) { $script:passed++; continue }
                $only = Invoke-StatusLine $payload $modelOnlyPath[$cfg.Style] $c
                Confirm-True ($only.ExitCode -eq 0) "${label}: model-only oracle exit code $($only.ExitCode)"
                Confirm-True ($only.Err.Count -eq 0) "${label}: model-only oracle stderr empty"
                # Ordinal, not -ceq: these two are rendered lines, so a format character in one of them
                # is exactly what this comparison must not wave through as "the same text".
                $isModelOnly = [string]::Equals((ConvertTo-PlainText $line), (ConvertTo-PlainText ($only.Lines -join '')), [System.StringComparison]::Ordinal)
                Confirm-True $isModelOnly "${label}: width $w exceeds $($c - 1) and the line is not the model-only fallback"
            }
            # The model segment has no short form and is never dropped, which is the whole reason the
            # alarm rides on it: the colour has to survive every width in the list, 20 columns included,
            # where every other segment has been shed. Checked at every width, and raw, because the
            # plain-text markers below cannot see a colour at all.
            if ($cfg.Enabled['model'] -and $sample.Name -in $alarmSamples) {
                $rawAlarm = $lines -join "`n"
                if ($cfg.Style -eq 'plain') {
                    Confirm-True ($rawAlarm.Contains("$esc[31m$iconModel")) "${label}: the alarm keeps the plain model segment red"
                } else {
                    Confirm-True ($rawAlarm.Contains("$esc[0;1;48;5;160;38;5;231m $iconModel")) "${label}: the alarm keeps the model block on background 160"
                }
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
                foreach ($row in $cfg.Rows) { $rowVisible.Add(@($row | Where-Object { $_ -in $visible })) }
                if ($visible.Count -eq 0) {
                    # The config turns off everything this sample could show. statusline.ps1 builds no
                    # segments at all then and prints its fallback, the model glyph and the word claude.
                    # Model is still on and listed here - the case where it is not exits above, with no
                    # line at all - so the fallback is the model segment's stand-in and belongs on screen.
                    Confirm-True $cfg.Enabled['model'] "${label}: the claude fallback is only reached with model on"
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
                    # A segment the config leaves on but the sample gives no data for has to stay off the
                    # line too, under the same one-owner rule: a glyph that a listed, enabled segment also
                    # owns proves nothing. This is what catches a builder that starts rendering from a
                    # payload that should give it nothing, for every sample rather than the few the
                    # absence table names.
                    foreach ($name in $allSegments) {
                        if (-not $cfg.Enabled[$name] -or $name -in $known) { continue }
                        $shared = @($allSegments | Where-Object { $_ -ne $name -and $cfg.Enabled[$_] -and $_ -in $known } | ForEach-Object { $segmentGlyphs[$_] })
                        $seen = @($segmentGlyphs[$name] | Where-Object { $_ -notin $shared -and $text.Contains($_) })
                        Confirm-True ($seen.Count -eq 0) "${label}: $name has no data in this sample, none of its glyphs appear"
                    }
                    # The rows this render should print, in order: the config's rows with the segments
                    # this sample shows, minus a row that has nothing visible left on it, because
                    # Get-FittedLine returns $null for an empty set and the print loop skips it.
                    $rows = @($rowVisible | Where-Object { $_.Count -gt 0 })
                    Confirm-Equal $lines.Count $rows.Count "${label}: renders $($rows.Count) line(s)"
                    if ($lines.Count -eq $rows.Count) {
                        for ($ri = 0; $ri -lt $rows.Count; $ri++) {
                            $rowText = ConvertTo-PlainText $lines[$ri]
                            $mine = @($rows[$ri])
                            # Every visible segment has to prove it rendered, by its own marker, on its
                            # own row, and after the segment the config puts before it. This is the
                            # check that a dropped or misplaced segment cannot slip past: the absence
                            # table names only a few glyphs per sample.
                            $lastAt = -1
                            foreach ($name in $mine) {
                                $marker = $marks[$name]
                                if ($marker -is [hashtable]) { $marker = $marker[$cfg.Folder] }
                                if (-not $marker) { Confirm-True $false "${label}: no marker for $name in the marker table"; continue }
                                $at = $rowText.IndexOf($marker)
                                Confirm-True ($at -ge 0) "${label}: line $($ri + 1) shows $name as '$marker'"
                                if ($at -lt 0) { continue }
                                Confirm-True ($at -gt $lastAt) "${label}: line $($ri + 1) has $name after the segment listed before it"
                                $lastAt = $at
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
                    # The alarm only changes a colour, so it is the one thing the plain-text markers
                    # cannot see. Both sides are checked for every sample: the two alarm samples have to
                    # be red and every other sample has to still be the bold cyan it was.
                    if ($cfg.Enabled['model'] -and $cfg.Style -eq 'plain') {
                        $rawText = $lines -join "`n"
                        if ($sample.Name -in $alarmSamples) {
                            Confirm-True ($rawText.Contains("$esc[31m$iconModel")) "${label}: the alarm turns the plain model segment red"
                            Confirm-True (-not $rawText.Contains("$esc[1;36m$iconModel")) "${label}: no bold cyan model segment beside the alarm"
                        } else {
                            Confirm-True ($rawText.Contains("$esc[1;36m$iconModel")) "${label}: the plain model segment is bold cyan"
                            Confirm-True (-not $rawText.Contains("$esc[31m$iconModel")) "${label}: no alarm, so the model segment is not red"
                        }
                    }
                    if ($cfg.Style -eq 'powerline') {
                        $rawJoined = $lines -join "`n"
                        if ($cfg.Enabled['model']) {
                            $modelBg = if ($sample.Name -in $alarmSamples) { 160 } else { 31 }
                            $otherBg = if ($modelBg -eq 160) { 31 } else { 160 }
                            Confirm-True ($rawJoined.Contains("$esc[0;1;48;5;$modelBg;38;5;231m")) "${label}: powerline bold model block on background $modelBg"
                            Confirm-True (-not $rawJoined.Contains("$esc[0;1;48;5;$otherBg;38;5;231m")) "${label}: no bold model block on background $otherBg"
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

# The thresholds and icons keys through the whole script, one sample each at the unset width: 06 has a
# 32% context meter, green at 60/85 and yellow at 20/40, and 01 renders the model glyph, which the
# config swaps for the bolt. Plain style, so a segment's colour is the SGR code in front of its text.
Write-Host ''
Write-Host '== render: thresholds and icons' -ForegroundColor Cyan
$payload06 = $samplePayloads[$sample06.Name]
foreach ($case in @(
        @{ Name = 'thresholds-default'; Json = '{}'; Sgr = '32'; Label = 'default 60/85 leaves the 32% meter green' }
        @{ Name = 'thresholds-low'; Json = '{ "thresholds": { "warn": 20, "bad": 40 } }'; Sgr = '33'; Label = '20/40 turns the 32% meter yellow' }
        @{ Name = 'thresholds-high'; Json = '{ "thresholds": { "warn": 33, "bad": 34 } }'; Sgr = '32'; Label = '33/34 leaves the 32% meter green' }
        @{ Name = 'thresholds-crossed'; Json = '{ "thresholds": { "warn": 90, "bad": 10 } }'; Sgr = '32'; Label = '90/10 falls back to 60/85, the meter is green' }
        @{ Name = 'thresholds-fraction'; Json = '{ "thresholds": { "warn": 20.5, "bad": 40 } }'; Sgr = '32'; Label = 'a fraction falls back to 60/85, the meter is green' })) {
    $r = Invoke-StatusLine $payload06 (Write-TempConfig "render-$($case.Name).json" $case.Json) 0
    Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) "render $($case.Name): exit code 0, stderr empty"
    Confirm-True (($r.Lines -join "`n").Contains("$esc[$($case.Sgr)m$iconCtx 32%")) "render $($case.Name): $($case.Label)"
}
$bolt = [char]::ConvertFromUtf32(0xF0E7)
$payload01 = $samplePayloads['01-main-clean.json']
$r = Invoke-StatusLine $payload01 (Write-TempConfig 'render-icons-bolt.json' '{ "icons": { "model": "F0E7", "home": "U+2302", "cost": "zz" } }') 0
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'render icons: exit code 0, stderr empty'
$text = ConvertTo-PlainText ($r.Lines -join "`n")
Confirm-True ($text.Contains("$bolt Fable 5.1")) 'render icons: the model segment carries the bolt'
Confirm-True (-not $text.Contains($iconModel)) 'render icons: the robot is gone'
Confirm-True ($text.Contains("$([char]::ConvertFromUtf32(0x2302)) main")) 'render icons: the home glyph takes a U+ form'
Confirm-True ($text.Contains("$iconCost `$")) 'render icons: an invalid value keeps the built-in cash glyph'
Confirm-True ($text.Contains("$iconFolder my-project")) 'render icons: an icon not mentioned keeps its glyph'
$r = Invoke-StatusLine $payload01 (Write-TempConfig 'render-icons-surrogate.json' '{ "icons": { "model": "D800" } }') 0
Confirm-True ((ConvertTo-PlainText ($r.Lines -join "`n")).Contains("$iconModel Fable 5.1")) 'render icons: a surrogate falls back to the robot'
$r = Invoke-StatusLine 'not json' (Write-TempConfig 'render-icons-bolt.json' '{ "icons": { "model": "F0E7" } }') 0
Confirm-Equal (ConvertTo-PlainText ($r.Lines -join "`n")) "$bolt claude" 'render icons: the bad-payload fallback line carries the override too'

# The zero-segment fallback through the whole script. Every enabled and listed builder returned nothing,
# and the fallback line is the model glyph and the word claude: it stands in for the model segment, so it
# is printed only where a model segment would have been allowed, toggled on and named by order or rows.
# A config that turns model off, or one whose order or rows leave it out, asked for a line with no model
# on it, and no output is that answer. Each case renders the whole script, so what is compared is the
# child's whole output - an empty render included - and not a helper's return value.
Write-Host ''
Write-Host '== render: zero-segment fallback' -ForegroundColor Cyan
$nothingPayload = '{ }'
$modelOnlyPayload = '{ "model": { "display_name": "Sonnet 5" } }'
$fallbackLine = "$iconModel claude"
foreach ($case in @(
        @{ Name = 'order-unavailable'; Payload = $modelOnlyPayload; Json = '{ "order": ["cost"] }'; Want = ''
            Label = 'an order naming one segment the payload cannot fill prints nothing' }
        @{ Name = 'order-available'; Payload = '{ "cost": { "total_cost_usd": 1.5 } }'; Json = '{ "order": ["cost"] }'; Want = "$iconCost `$$('{0:N2}' -f 1.5)"
            Label = 'the same order with the figure present still renders that segment' }
        @{ Name = 'model-off-nothing-else'; Payload = $modelOnlyPayload; Json = '{ "segments": { "model": false } }'; Want = ''
            Label = 'model off with nothing else buildable prints nothing, model name in the payload or not' }
        @{ Name = 'model-off-empty-payload'; Payload = $nothingPayload; Json = '{ "segments": { "model": false } }'; Want = ''
            Label = 'model off and an empty payload prints nothing' }
        @{ Name = 'model-unlisted'; Payload = $nothingPayload; Json = '{ "order": ["cost", "context"] }'; Want = ''
            Label = 'model left on but out of the order prints nothing' }
        @{ Name = 'rows-without-model'; Payload = $nothingPayload; Json = '{ "layout": "two", "rows": [["cost"], ["lines"]] }'; Want = ''
            Label = 'layout two with model on neither row prints nothing' }
        @{ Name = 'model-on-and-listed'; Payload = $nothingPayload; Json = '{ }'; Want = $fallbackLine
            Label = 'model on and listed keeps the fallback line when the payload names no model' }
        @{ Name = 'model-alone-in-order'; Payload = $nothingPayload; Json = '{ "order": ["model"] }'; Want = $fallbackLine
            Label = 'an order of model alone keeps the fallback line' }
        @{ Name = 'model-on-second-row'; Payload = $nothingPayload; Json = '{ "layout": "two", "rows": [["cost"], ["model"]] }'; Want = $fallbackLine
            Label = 'model listed on the second row of layout two keeps the fallback line' }
        @{ Name = 'config-unusable'; Payload = $nothingPayload; Json = 'this file is not json'; Want = $fallbackLine
            Label = 'a config that will not parse falls back to the defaults, which keep the fallback line' })) {
    $r = Invoke-StatusLine $case.Payload (Write-TempConfig "render-zero-$($case.Name).json" $case.Json) 0
    Confirm-True ($r.ExitCode -eq 0) "render zero $($case.Name): exit code $($r.ExitCode)"
    Confirm-True ($r.Err.Count -eq 0) "render zero $($case.Name): stderr empty, got '$($r.Err -join ' | ')'"
    Confirm-Equal (ConvertTo-PlainText ($r.Lines -join "`n")) $case.Want "render zero $($case.Name): $($case.Label)"
}
# The bad-payload fallback reads the same two keys. A payload that is not JSON loses only the PROJECT
# overlay, because it names no project directory; the file -Config points at was read and merged over the
# defaults before this line, so it is honoured here exactly as it is on a payload that parsed. Both
# directions, so this cannot pass by printing nothing whatever the config says.
foreach ($case in @(
        @{ Name = 'model-on'; Json = '{ }'; Want = $fallbackLine; Label = 'model on and listed prints the fallback' }
        @{ Name = 'model-in-order'; Json = '{ "order": ["model", "cost"] }'; Want = $fallbackLine; Label = 'an order that names model prints the fallback' }
        @{ Name = 'model-on-second-row'; Json = '{ "layout": "two", "rows": [["cost"], ["model"]] }'; Want = $fallbackLine; Label = 'model on the second row of layout two prints the fallback' }
        @{ Name = 'config-unusable'; Json = 'this file is not json'; Want = $fallbackLine; Label = 'a config that will not parse leaves the defaults, which print the fallback' }
        @{ Name = 'model-off'; Json = '{ "segments": { "model": false } }'; Want = ''; Label = 'model toggled off prints nothing' }
        @{ Name = 'model-unlisted'; Json = '{ "order": ["cost"] }'; Want = ''; Label = 'model left out of the order prints nothing' }
        @{ Name = 'rows-without-model'; Json = '{ "layout": "two", "rows": [["cost"], ["lines"]] }'; Want = ''; Label = 'layout two with model on neither row prints nothing' })) {
    $r = Invoke-StatusLine 'not json' (Write-TempConfig "render-zero-bad-$($case.Name).json" $case.Json) 0
    Confirm-True ($r.ExitCode -eq 0) "render zero bad-payload $($case.Name): exit code $($r.ExitCode)"
    Confirm-True ($r.Err.Count -eq 0) "render zero bad-payload $($case.Name): stderr empty, got '$($r.Err -join ' | ')'"
    Confirm-Equal (ConvertTo-PlainText ($r.Lines -join "`n")) $case.Want "render zero bad-payload $($case.Name): $($case.Label)"
}
# The same thing through the USER file rather than -Config, which is the config a real session has: a copy
# of the script beside a statusline.json of our own, run with no -Config at all, so the child reads that
# file from its own $PSScriptRoot. This is the only way to cover that path without editing the
# repository's installed default, and it is the path that decides what a user who turned model off sees
# when Claude Code hands the script something that is not JSON.
$zeroHome = Join-Path $tmp 'zero-user-config'
New-Item -ItemType Directory -Force $zeroHome | Out-Null
$zeroScript = Join-Path $zeroHome 'statusline.ps1'
Copy-Item -LiteralPath $script -Destination $zeroScript -Force
foreach ($case in @(
        @{ Name = 'user-default'; Json = '{ }'; Want = $fallbackLine; Label = 'a user file that says nothing about model prints the fallback' }
        @{ Name = 'user-model-off'; Json = '{ "segments": { "model": false } }'; Want = ''; Label = 'a user file with model off prints nothing' }
        @{ Name = 'user-model-unlisted'; Json = '{ "order": ["cost", "context"] }'; Want = ''; Label = 'a user file whose order leaves model out prints nothing' })) {
    [System.IO.File]::WriteAllText((Join-Path $zeroHome 'statusline.json'), $case.Json, [System.Text.UTF8Encoding]::new($false))
    $zeroOldCols = $env:COLUMNS
    try {
        Remove-Item Env:COLUMNS -ErrorAction SilentlyContinue
        $r = Invoke-ChildPwsh $zeroScript @() 'not json'
    } finally {
        if ($null -ne $zeroOldCols) { $env:COLUMNS = $zeroOldCols } else { Remove-Item Env:COLUMNS -ErrorAction SilentlyContinue }
    }
    Confirm-True ($r.ExitCode -eq 0) "render zero user-file $($case.Name): exit code $($r.ExitCode)"
    Confirm-True ($r.Err.Count -eq 0) "render zero user-file $($case.Name): stderr empty, got '$($r.Err -join ' | ')'"
    Confirm-Equal (ConvertTo-PlainText ($r.Lines -join "`n")) $case.Want "render zero user-file $($case.Name): $($case.Label)"
}

# A render that prints nothing still has a payload behind it, carrying the session id and the cost, token
# and rate figures whatever the config chose to show, and the state file is where the next render reads
# them back from. So the empty path must still write and merge state: what the config decides is what
# goes on screen, not what is worth remembering. Each case is rendered twice with different costs, so a
# write that never merged would fail here as well as one that never happened. The quiet case is the one
# most likely to regress, because there the segment exists and its builder chose to say nothing.
# Its own TEMP, the way the state section takes one, so these files cannot reach any other check.
$zeroOldTemp = $env:TEMP
$zeroTemp = Join-Path $tmp 'temp-zero-state'
New-Item -ItemType Directory -Force $zeroTemp | Out-Null
$env:TEMP = $zeroTemp
try {
    $zeroStateDir = Join-Path $zeroTemp 'claude-statusline-state'
    foreach ($case in @(
            @{ Name = 'order-unavailable'; Session = 'zero-order'; Json = '{ "order": ["lines"] }'
                Label = 'an order naming only a segment the payload cannot fill' }
            @{ Name = 'quiet'; Session = 'zero-quiet'; Json = '{ "order": ["cost"], "quiet": { "cost": 10 } }'
                Label = 'a quiet threshold hiding the only listed segment' }
            @{ Name = 'model-off'; Session = 'zero-modeloff'; Json = '{ "segments": { "model": false }, "order": ["model"] }'
                Label = 'model listed but toggled off' })) {
        $zeroCfg = Write-TempConfig "render-zero-state-$($case.Name).json" $case.Json
        $zeroPath = Join-Path $zeroStateDir "$($case.Session).json"
        $r = Invoke-StatusLine ('{ "session_id": "' + $case.Session + '", "cost": { "total_cost_usd": 2.5 } }') $zeroCfg 0
        Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) "render zero state $($case.Name): exit code 0, stderr empty, got '$($r.Err -join ' | ')'"
        Confirm-Equal (ConvertTo-PlainText ($r.Lines -join "`n")) '' "render zero state $($case.Name): $($case.Label) prints nothing"
        Confirm-True (Test-Path -LiteralPath $zeroPath) "render zero state $($case.Name): the empty render still wrote the state file"
        $r = Invoke-StatusLine ('{ "session_id": "' + $case.Session + '", "cost": { "total_cost_usd": 3.25 } }') $zeroCfg 0
        Confirm-Equal (ConvertTo-PlainText ($r.Lines -join "`n")) '' "render zero state $($case.Name): the second empty render prints nothing either"
        # Read only if it is there. A regression that skips the write makes every assertion below fail
        # anyway, and reading it unguarded would end the whole run on a terminating error instead, one
        # named assertion in and with the rest of the suite unreported.
        $zeroState = if (Test-Path -LiteralPath $zeroPath) { Get-Content -LiteralPath $zeroPath -Raw | ConvertFrom-Json } else { $null }
        Confirm-Equal $zeroState.cost_usd 3.25 "render zero state $($case.Name): cost_usd follows the second payload"
        Confirm-Equal $zeroState.history.Count 2 "render zero state $($case.Name): the second render merged onto the first, two history entries"
        # Indexed only if there is something to index, for the same reason the read above is guarded: a
        # regression that writes no state must fail this assertion, not end the run on it.
        $zeroNewest = if (@($zeroState.history).Count -gt 1) { $zeroState.history[1].cost_usd } else { $null }
        Confirm-Equal $zeroNewest 3.25 "render zero state $($case.Name): newest history entry last"
    }
    # And the state key still turns it off there, so falling through has not made the toggle moot.
    $zeroCfg = Write-TempConfig 'render-zero-state-off.json' '{ "order": ["lines"], "state": false }'
    $r = Invoke-StatusLine '{ "session_id": "zero-stateoff", "cost": { "total_cost_usd": 2.5 } }' $zeroCfg 0
    Confirm-Equal (ConvertTo-PlainText ($r.Lines -join "`n")) '' 'render zero state off: an empty render with state false prints nothing'
    Confirm-True (-not (Test-Path -LiteralPath (Join-Path $zeroStateDir 'zero-stateoff.json'))) 'render zero state off: state false writes no file on the empty path'
} finally {
    if ($null -ne $zeroOldTemp) { $env:TEMP = $zeroOldTemp } else { Remove-Item Env:TEMP -ErrorAction SilentlyContinue }
}

# The alarm key through the whole script, plain style so a segment's colour is the SGR code in front of
# its text. 12 sits at 92% of a standard window and carries no rate limits, 07 at 5% with a 5-hour limit
# of 61 and a 7-day of 12, and 05 at 25% with no rate_limits object at all. Each level is rendered from
# both sides - one above the figure and one at it - so the render path, and not only the unit call,
# would fail if the comparison moved by one.
Write-Host ''
Write-Host '== render: alarm' -ForegroundColor Cyan
$payload12 = $samplePayloads['12-context-alarm.json']
$payload07 = $samplePayloads['07-limits-expired-default-effort.json']
$payload05 = $samplePayloads['05-no-git.json']
foreach ($case in @(
        @{ Name = 'alarm-default'; Payload = '12'; Json = '{}'; Red = $true; Label = 'the built-in 90 turns the 92% model red' }
        @{ Name = 'alarm-off'; Payload = '12'; Json = '{ "alarm": { "context": 0, "limits": 0 } }'; Red = $false; Label = 'both alarms at 0 give the model its colour back at 92%' }
        @{ Name = 'alarm-at'; Payload = '12'; Json = '{ "alarm": { "context": 92 } }'; Red = $true; Label = 'a level of 92 fires at 92%' }
        @{ Name = 'alarm-above'; Payload = '12'; Json = '{ "alarm": { "context": 93 } }'; Red = $false; Label = 'a level of 93 does not fire at 92%' }
        @{ Name = 'alarm-over-100'; Payload = '12'; Json = '{ "alarm": { "context": 150 } }'; Red = $false; Label = 'a level above 100 never fires' }
        @{ Name = 'alarm-context-invalid'; Payload = '12'; Json = '{ "alarm": { "context": "off" } }'; Red = $true; Label = 'an unusable level keeps the built-in 90, which fires at 92%' }
        @{ Name = 'alarm-limit-at'; Payload = '07'; Json = '{ "alarm": { "context": 0, "limits": 61 } }'; Red = $true; Label = 'the 5-hour limit alone turns the model red' }
        @{ Name = 'alarm-limit-above'; Payload = '07'; Json = '{ "alarm": { "context": 0, "limits": 62 } }'; Red = $false; Label = 'a level one above the 5-hour figure does not fire' }
        @{ Name = 'alarm-limit-context-quiet'; Payload = '07'; Json = '{ "alarm": { "context": 90, "limits": 90 } }'; Red = $false; Label = '5% context and a 61% limit raise no alarm at 90' }
        @{ Name = 'alarm-no-limits'; Payload = '05'; Json = '{ "alarm": { "context": 0, "limits": 1 } }'; Red = $false; Label = 'a payload with no rate_limits raises no alarm at a level of 1' })) {
    $payload = switch ($case.Payload) { '12' { $payload12 } '07' { $payload07 } default { $payload05 } }
    $r = Invoke-StatusLine $payload (Write-TempConfig "render-$($case.Name).json" $case.Json) 0
    Confirm-True ($r.ExitCode -eq 0) "render $($case.Name): exit code $($r.ExitCode)"
    Confirm-True ($r.Err.Count -eq 0) "render $($case.Name): stderr empty, got '$($r.Err -join ' | ')'"
    $alarmRaw = $r.Lines -join "`n"
    $want = if ($case.Red) { "$esc[31m$iconModel" } else { "$esc[1;36m$iconModel" }
    $other = if ($case.Red) { "$esc[1;36m$iconModel" } else { "$esc[31m$iconModel" }
    Confirm-True ($alarmRaw.Contains($want)) "render $($case.Name): $($case.Label)"
    Confirm-True (-not $alarmRaw.Contains($other)) "render $($case.Name): and the model segment is in no other colour"
}
# The text is the alarm's only silence: the same payload renders the same characters either way, and
# only the escape in front of them differs.
$onText = ConvertTo-PlainText ((Invoke-StatusLine $payload12 (Write-TempConfig 'render-alarm-text-on.json' '{ "alarm": { "context": 90 } }') 0).Lines -join "`n")
$offText = ConvertTo-PlainText ((Invoke-StatusLine $payload12 (Write-TempConfig 'render-alarm-text-off.json' '{ "alarm": { "context": 0 } }') 0).Lines -join "`n")
Confirm-Equal $onText $offText 'render alarm: the alarm changes no character of the line'
Confirm-True ($onText.Contains("$iconModel Sonnet 5")) 'render alarm: the model name is still there'
# Powerline, where the alarm is a block background rather than an SGR code, and the arrow after the
# model block picks the alarm colour up because Format-Line reads both from the same role.
$r = Invoke-StatusLine $payload12 (Write-TempConfig 'render-alarm-powerline.json' '{ "style": "powerline" }') 0
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'render alarm powerline: exit code 0, stderr empty'
$alarmRaw = $r.Lines -join "`n"
Confirm-True ($alarmRaw.Contains("$esc[0;1;48;5;160;38;5;231m $iconModel Sonnet 5 ")) 'render alarm powerline: the model block is 231 on 160'
Confirm-True ($alarmRaw.Contains("$esc[38;5;160;48;5;")) 'render alarm powerline: the arrow after it carries 160'
Confirm-True (-not $alarmRaw.Contains("$esc[0;1;48;5;31;38;5;231m")) 'render alarm powerline: no bold block on the model background'
# The boundary end to end. A fractional percentage is where a raw comparison and a printed figure come
# apart: 89.6 prints as 90% and has to alarm, or the line shows a red 90% meter beside a cyan model.
# Both window sizes, because a 1M window keeps its own fixed 90 band, and both styles, because the
# alarm is an SGR code in one and a block background in the other. The payload carries no workspace, so
# there is no folder, no branch and no git probe: this is the meter and the model on their own.
foreach ($style in @('plain', 'powerline')) {
    $boundaryConfig = Write-TempConfig "render-alarm-boundary-$style.json" ('{ "style": "' + $style + '" }')
    foreach ($size in @(200000, 1000000)) {
        foreach ($row in @(
                @{ Pct = 89.4; Whole = 89; Red = $false }
                @{ Pct = 89.5; Whole = 90; Red = $true }
                @{ Pct = 89.6; Whole = 90; Red = $true }
                @{ Pct = 89.9; Whole = 90; Red = $true })) {
            $rawPct = $row.Pct.ToString([cultureinfo]::InvariantCulture)
            $boundaryPayload = '{ "model": { "display_name": "Sonnet 5" }, "context_window": { "used_percentage": ' +
                $rawPct + ', "context_window_size": ' + $size + ' } }'
            $r = Invoke-StatusLine $boundaryPayload $boundaryConfig 0
            $boundaryLabel = "render alarm boundary $style $size $rawPct%"
            Confirm-True ($r.ExitCode -eq 0) "${boundaryLabel}: exit code $($r.ExitCode)"
            Confirm-True ($r.Err.Count -eq 0) "${boundaryLabel}: stderr empty, got '$($r.Err -join ' | ')'"
            $alarmRaw = $r.Lines -join "`n"
            Confirm-True ((ConvertTo-PlainText $alarmRaw).Contains("$iconCtx $($row.Whole)%")) "${boundaryLabel}: the meter prints $($row.Whole)%"
            $want = if ($style -eq 'plain') {
                if ($row.Red) { "$esc[31m$iconModel" } else { "$esc[1;36m$iconModel" }
            } elseif ($row.Red) { "$esc[0;1;48;5;160;38;5;231m $iconModel" } else { "$esc[0;1;48;5;31;38;5;231m $iconModel" }
            $other = if ($style -eq 'plain') {
                if ($row.Red) { "$esc[1;36m$iconModel" } else { "$esc[31m$iconModel" }
            } elseif ($row.Red) { "$esc[0;1;48;5;31;38;5;231m $iconModel" } else { "$esc[0;1;48;5;160;38;5;231m $iconModel" }
            $shown = if ($row.Red) { 'red' } else { 'its own colour' }
            Confirm-True ($alarmRaw.Contains($want)) "${boundaryLabel}: the model segment is $shown, agreeing with the printed $($row.Whole)%"
            Confirm-True (-not $alarmRaw.Contains($other)) "${boundaryLabel}: and it is in no other colour"
        }
    }
}
# 20 columns: everything but the model has been shed, and the alarm colour is still there.
$r = Invoke-StatusLine $payload12 (Write-TempConfig 'render-alarm-narrow.json' '{}') 20
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'render alarm 20 columns: exit code 0, stderr empty'
$alarmRaw = $r.Lines -join "`n"
Confirm-True ($alarmRaw.Contains("$esc[31m$iconModel Sonnet 5")) 'render alarm 20 columns: the model segment prints and is still red'
Confirm-True (-not (ConvertTo-PlainText $alarmRaw).Contains($iconCtx)) 'render alarm 20 columns: the context segment was dropped to fit'

# The quiet key through the whole script, at the unset width, on the samples whose figures straddle it:
# 01 spends $0.43 in an 8% context and carries no rate limits, 02 spends $12.50, 06 is at 32% context
# with a 7-day figure of 88, and 07's window figures are 61 and 12 with a cost of $0.02. One config
# covers all four, so the same three thresholds are seen to hide one sample's segment and keep another's.
# The colour bands are raised to 95 and 99 in that config for the same reason the unit cases raise them:
# under the default 60 and 85, 07's 5-hour figure of 61 is already yellow, and quiet may not hide a
# segment carrying a warning, so the tachometer would stay for that reason and the cutoff would never be
# under test. The default-band case is exercised on its own below, where the rule is the point.
Write-Host ''
Write-Host '== render: quiet' -ForegroundColor Cyan
$payload02 = $samplePayloads['02-feature-dirty-high.json']
$payload07 = $samplePayloads['07-limits-expired-default-effort.json']
$quietPath = Write-TempConfig 'render-quiet.json' '{ "quiet": { "cost": 1, "context": 30, "limits": 70 }, "thresholds": { "warn": 95, "bad": 99 } }'
$quietGlyph = @{ cost = $iconCost; context = $iconCtx; limits = $iconLimit }
foreach ($case in @(
        @{ Payload = $payload01; Label = '01'; Hidden = @('cost', 'context'); Shown = @() }
        @{ Payload = $payload02; Label = '02'; Hidden = @(); Shown = @('cost', 'context') }
        @{ Payload = $payload06; Label = '06'; Hidden = @(); Shown = @('cost', 'context', 'limits') }
        @{ Payload = $payload07; Label = '07'; Hidden = @('cost', 'context', 'limits'); Shown = @() })) {
    $r = Invoke-StatusLine $case.Payload $quietPath 0
    Confirm-True ($r.ExitCode -eq 0) "render quiet $($case.Label): exit code $($r.ExitCode)"
    Confirm-True ($r.Err.Count -eq 0) "render quiet $($case.Label): stderr empty"
    $text = ConvertTo-PlainText ($r.Lines -join "`n")
    foreach ($n in $case.Hidden) { Confirm-True (-not $text.Contains($quietGlyph[$n])) "render quiet $($case.Label): $n is below the line and gone" }
    foreach ($n in $case.Shown) { Confirm-True ($text.Contains($quietGlyph[$n])) "render quiet $($case.Label): $n is at or above the line and shown" }
    Confirm-True ($text.Contains($iconModel)) "render quiet $($case.Label): the model segment has no threshold and stays"
}
# 01 carries no rate_limits at all, so the tachometer is absent whatever quiet.limits says; asserting it
# here would pass for the wrong reason, and the case above leaves it out on purpose. What is worth
# pinning is that hiding two of 01's segments leaves the rest of its line exactly as it was.
$r = Invoke-StatusLine $payload01 $quietPath 0
Confirm-True ((ConvertTo-PlainText ($r.Lines -join "`n")).Contains("$iconFolder my-project")) 'render quiet 01: the segments with no threshold are untouched'
# The rule through a whole render: the same sample and the same cutoff, with the default bands back, so
# 07's 5-hour figure of 61 is yellow. Quiet may not hide a segment carrying a warning, so the tachometer
# stays even though 61 is under the cutoff of 70 - and the cost and context thresholds beside it, which
# have no warning to preserve, still take effect. This is the case the feature would otherwise get wrong.
$quietAlarmPath = Write-TempConfig 'render-quiet-alarm.json' '{ "quiet": { "cost": 1, "context": 30, "limits": 70 } }'
$r = Invoke-StatusLine $payload07 $quietAlarmPath 0
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'render quiet alarm: exit code 0, stderr empty'
$text = ConvertTo-PlainText ($r.Lines -join "`n")
Confirm-True ($text.Contains("$iconLimit 5h 61%")) 'render quiet alarm: a warn limits segment under the cutoff is kept, with its figure'
Confirm-True (-not $text.Contains($iconCost)) 'render quiet alarm: cost has no warning state, so its threshold still hides it'
Confirm-True (-not $text.Contains($iconCtx)) 'render quiet alarm: the 5% meter is ok, so its threshold still hides it'
# A quiet block the script cannot read leaves every segment visible and says nothing on stderr.
foreach ($case in @(
        @{ Name = 'render-quiet-scalar'; Json = '{ "quiet": 5 }'; Label = 'a quiet that is not an object' }
        @{ Name = 'render-quiet-strings'; Json = '{ "quiet": { "cost": "1", "context": "30", "limits": "70" } }'; Label = 'quiet values written as strings' }
        @{ Name = 'render-quiet-negative'; Json = '{ "quiet": { "cost": -1, "context": -1, "limits": -1 } }'; Label = 'negative quiet values' })) {
    $r = Invoke-StatusLine $payload07 (Write-TempConfig "$($case.Name).json" $case.Json) 0
    Confirm-True ($r.ExitCode -eq 0) "render quiet: $($case.Label), exit code $($r.ExitCode)"
    Confirm-True ($r.Err.Count -eq 0) "render quiet: $($case.Label) prints nothing on stderr"
    $text = ConvertTo-PlainText ($r.Lines -join "`n")
    Confirm-True ($text.Contains($iconCost) -and $text.Contains($iconCtx) -and $text.Contains($iconLimit)) "render quiet: $($case.Label) leaves every segment visible"
}

# The presets through the whole script, against the sample that carries every segment's data. What is
# checked is glyphs on the line rather than a config table, so a preset that parsed and then failed to
# reach the render would show up here. 06 has no pull-request block, so `pr` prints nothing whatever the
# toggle says and is not asserted either way.
Write-Host ''
Write-Host '== render: presets' -ForegroundColor Cyan
$presetArrow = [char]::ConvertFromUtf32(0xE0B0)
$presetGlyph = @{
    model = $iconModel; context = $iconCtx; cost = $iconCost; lines = $iconLines; limits = $iconLimit
    fast = $iconFast; think = $iconThink; effort = $iconEffort; vim = $iconVim; folder = $iconFolder; branch = $iconHome
}
function Get-PresetRender([string] $Name, [string] $Json) {
    $r = Invoke-StatusLine $payload06 (Write-TempConfig "render-preset-$Name.json" $Json) 0
    Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) "render preset ${Name}: exit code 0, stderr empty"
    return $r
}
function Confirm-PresetGlyph([string] $Label, [string] $Text, [string[]] $Present, [string[]] $Absent) {
    foreach ($g in $Present) { Confirm-True ($Text.Contains($presetGlyph[$g])) "render preset ${Label}: the $g glyph is on the line" }
    foreach ($g in $Absent) { Confirm-True (-not $Text.Contains($presetGlyph[$g])) "render preset ${Label}: the $g glyph is gone" }
}
$r = Get-PresetRender 'minimal' '{ "preset": "minimal" }'
$text = ConvertTo-PlainText ($r.Lines -join "`n")
Confirm-Equal $r.Lines.Count 1 'render preset minimal: one line'
Confirm-True (-not $text.Contains($presetArrow)) 'render preset minimal: plain style, no powerline arrow'
Confirm-PresetGlyph 'minimal' $text @('model', 'context', 'folder', 'branch') @('cost', 'lines', 'limits', 'fast', 'think', 'effort', 'vim')
$r = Get-PresetRender 'cost' '{ "preset": "cost" }'
$text = ConvertTo-PlainText ($r.Lines -join "`n")
Confirm-Equal $r.Lines.Count 1 'render preset cost: one line'
Confirm-PresetGlyph 'cost' $text @('model', 'context', 'cost', 'lines', 'limits') @('fast', 'think', 'effort', 'vim', 'folder', 'branch')
$r = Get-PresetRender 'full' '{ "preset": "full" }'
$text = ConvertTo-PlainText ($r.Lines -join "`n")
Confirm-Equal $r.Lines.Count 2 'render preset full: two lines'
Confirm-True (($r.Lines -join "`n").Contains($presetArrow)) 'render preset full: powerline arrows between the blocks'
Confirm-PresetGlyph 'full' $text @('model', 'context', 'cost', 'lines', 'limits', 'fast', 'think', 'effort', 'vim', 'folder', 'branch') @()
# A segment turned off beside the preset it belongs to, through the whole script.
$r = Get-PresetRender 'cost-no-cost' '{ "preset": "cost", "segments": { "cost": false } }'
$text = ConvertTo-PlainText ($r.Lines -join "`n")
Confirm-PresetGlyph 'cost-no-cost' $text @('lines', 'limits') @('cost')
# An unknown preset renders the same bytes as an empty config, and the shipped statusline.json still
# renders what it always did: a preset is a starting point, not a change to the defaults.
$plainRender = (Get-PresetRender 'none' '{}').Lines -join "`n"
Confirm-Equal ((Get-PresetRender 'unknown' '{ "preset": "nope" }').Lines -join "`n") $plainRender 'render preset: an unknown name renders the empty config byte for byte'
Confirm-Equal ((Get-PresetRender 'number' '{ "preset": 5 }').Lines -join "`n") $plainRender 'render preset: a non-string name renders the empty config byte for byte'
$r = Invoke-StatusLine $payload06 (Join-Path $PSScriptRoot 'statusline.json') 0
Confirm-Equal ($r.Lines -join "`n") $plainRender 'render preset: the shipped statusline.json still renders the default line'

# The project config through the whole script, at the unset width. 06 carries a cost figure, and the
# payload names a project directory holding a .claude\statusline.json that turns the cost segment off.
# With no -Config the script reads the user file beside it (the shipped one, every segment on) and then
# that project file; with -Config the project file is not looked for at all, which is what keeps the
# render matrix and the screenshot script free of any dependency on the directory a payload names.
Write-Host ''
Write-Host '== render: project config' -ForegroundColor Cyan
function Write-RenderProjectPayload([string] $Name, $Json) {
    $dir = Join-Path $tmp $Name
    $claude = Join-Path $dir '.claude'
    New-Item -ItemType Directory -Force $claude | Out-Null
    if ($null -ne $Json) { [System.IO.File]::WriteAllText((Join-Path $claude 'statusline.json'), $Json, [System.Text.UTF8Encoding]::new($false)) }
    $payload = $payload06 | ConvertFrom-Json
    $payload.workspace | Add-Member -NotePropertyName project_dir -NotePropertyValue $dir -Force
    return ($payload | ConvertTo-Json -Depth 20 -Compress)
}
$projectPayload = Write-RenderProjectPayload 'render-project' '{ "segments": { "cost": false } }'
$r = Invoke-StatusLine $projectPayload $null 0
Confirm-True ($r.ExitCode -eq 0) "render project: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) 'render project: stderr empty'
$text = ConvertTo-PlainText ($r.Lines -join "`n")
Confirm-True (-not $text.Contains($iconCost)) 'render project: the project file turns the cost segment off'
Confirm-True ($text.Contains($iconLines)) 'render project: a segment the project file does not name stays on'
$r = Invoke-StatusLine $projectPayload (Write-TempConfig 'render-project-config.json' '{}') 0
Confirm-True ($r.Err.Count -eq 0) 'render project: -Config stderr empty'
Confirm-True ((ConvertTo-PlainText ($r.Lines -join "`n")).Contains($iconCost)) 'render project: -Config does not read the project file'
# A malformed project file, a project directory with no config in it, and a file the bounded read
# refuses all leave the user file in force and say nothing on stderr. The oversized case is the one that
# matters most: it is a whole render, so a config a repository grew to megabytes would show up here as a
# slow or hanging child rather than as a quiet fallback.
$overSized = '{ "segments": { "cost": false }, "pad": "' + ('x' * (Get-ProjectConfigLimit).MaxBytes) + '" }'
foreach ($case in @(
        @{ Name = 'render-project-broken'; Json = '{ "segments": '; Label = 'a malformed project file' }
        @{ Name = 'render-project-none'; Json = $null; Label = 'an empty .claude directory' }
        @{ Name = 'render-project-huge'; Json = $overSized; Label = 'a project file over the byte cap' })) {
    $r = Invoke-StatusLine (Write-RenderProjectPayload $case.Name $case.Json) $null 0
    Confirm-True ($r.ExitCode -eq 0) "render project: $($case.Label) exit code $($r.ExitCode)"
    Confirm-True ($r.Err.Count -eq 0) "render project: $($case.Label) prints nothing on stderr"
    Confirm-True ((ConvertTo-PlainText ($r.Lines -join "`n")).Contains($iconCost)) "render project: $($case.Label) leaves the user config in force"
}
# A link, or anything else that is not an ordinary file, where the project config should be. The payload
# is built first with a real file so the directory exists, then the file is replaced.
$linkPayload = Write-RenderProjectPayload 'render-project-link' '{ "segments": { "cost": false } }'
$renderLink = Join-Path (Join-Path (Join-Path $tmp 'render-project-link') '.claude') 'statusline.json'
Remove-Item -LiteralPath $renderLink -Force
$renderLinkMade = $true
try { New-Item -ItemType SymbolicLink -Path $renderLink -Target (Write-TempConfig 'render-link-target.json' '{ "segments": { "cost": false } }') -ErrorAction Stop | Out-Null } catch { $renderLinkMade = $false }
if (-not $renderLinkMade) { New-Item -ItemType Directory -Force $renderLink | Out-Null }
$renderLinkKind = if ($renderLinkMade) { 'a link' } else { 'a directory' }
$r = Invoke-StatusLine $linkPayload $null 0
Confirm-True ($r.ExitCode -eq 0) "render project: $renderLinkKind in place of the file, exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "render project: $renderLinkKind in place of the file prints nothing on stderr"
Confirm-True ((ConvertTo-PlainText ($r.Lines -join "`n")).Contains($iconCost)) "render project: $renderLinkKind in place of the file leaves the user config in force"
# An unreachable project directory through a whole render. The line still prints, and it prints without
# waiting on the network stack: a render is a few hundred milliseconds of pwsh start-up, so the bound
# here is loose, and what it catches is a filesystem wait of the tens of seconds an SMB timeout runs to.
$deadRender = $payload06 | ConvertFrom-Json
$deadRender.workspace | Add-Member -NotePropertyName project_dir -NotePropertyValue '\\192.0.2.1\statusline-test' -Force
$r = Invoke-StatusLine ($deadRender | ConvertTo-Json -Depth 20 -Compress) $null 0
Write-Host "  unreachable render: $($r.Ms) ms" -ForegroundColor DarkGray
Confirm-True ($r.ExitCode -eq 0) "render project: an unreachable project directory, exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) 'render project: an unreachable project directory prints nothing on stderr'
Confirm-True ((ConvertTo-PlainText ($r.Lines -join "`n")).Contains($iconCost)) 'render project: an unreachable project directory leaves the user config in force'
Confirm-True ($r.Ms -lt 20000) 'render project: an unreachable project directory does not wait on the filesystem timeout'
# The icons a repository can ask for reach a whole render too: a right-to-left override in the project
# config must not touch the line, and the built-in glyph has to survive it.
$r = Invoke-StatusLine (Write-RenderProjectPayload 'render-project-bidi' '{ "icons": { "model": "202E", "cost": "2588" } }') $null 0
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'render project: a bidi override in the project icons, exit code 0, stderr empty'
$text = ConvertTo-PlainText ($r.Lines -join "`n")
Confirm-True (-not $text.Contains([char]::ConvertFromUtf32(0x202E))) 'render project: the right-to-left override never reaches the line'
Confirm-True ($text.Contains($iconModel)) 'render project: the built-in model glyph survives the refused override'
Confirm-True ($text.Contains([char]::ConvertFromUtf32(0x2588))) 'render project: the valid override beside it is applied'
Confirm-True (@(Get-ChildItem -LiteralPath $matrixTemp -Recurse -Force -File).Count -eq 0) 'render matrix: no state written for payloads without a session_id'
} finally {
    if ($null -ne $oldTemp) { $env:TEMP = $oldTemp } else { Remove-Item Env:TEMP -ErrorAction SilentlyContinue }
}
} finally {
    if ($null -ne $oldGitCeiling) { $env:GIT_CEILING_DIRECTORIES = $oldGitCeiling } else { Remove-Item Env:GIT_CEILING_DIRECTORIES -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# ---- Subagent group: subagent-statusline.ps1 ----
# A separate script with a different contract from the main status line: Claude Code runs it once for
# the whole agent panel, hands it every live row in one payload, and reads one JSON object per line,
# {"id","content"}, keyed by the task id. It renders none of the segments, so it appears in none of
# the tables above and gets its own temp tree here rather than sharing $tmp, which is already gone.
Write-Host ''
Write-Host '== subagent' -ForegroundColor Cyan
$subScript = Join-Path $PSScriptRoot 'subagent-statusline.ps1'
$subSampleDir = Join-Path $PSScriptRoot 'samples\subagent'
$subTmp = Join-Path ([System.IO.Path]::GetTempPath()) "statusline-subagent-test-$PID"
New-Item -ItemType Directory -Force $subTmp | Out-Null
$iconRobot = [char]::ConvertFromUtf32(0xF06A9)
$ellipsis = [char]::ConvertFromUtf32(0x2026)

# Runs the subagent script in a child pwsh and reads stdout the way Claude Code does: line by line,
# each line an object with a string id and a string content, anything else dropped. Rows holds the
# replies in the order they arrived; Bad counts the lines Claude Code would have thrown away.
function Invoke-SubagentLine([string] $Payload) {
    $r = Invoke-ChildPwsh $subScript @() $Payload
    # Ordinal, because two live tasks can have ids that differ only in case and the panel keeps them
    # apart. A plain [ordered] hashtable would fold them together here and hide the very bug below.
    $rows = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    $bad = 0
    foreach ($line in $r.Lines) {
        if (-not "$line".Trim()) { continue }
        $obj = try { "$line" | ConvertFrom-Json } catch { $null }
        if ($obj -isnot [System.Management.Automation.PSCustomObject] -or
            $obj.id -isnot [string] -or $obj.content -isnot [string]) { $bad++; continue }
        $rows[$obj.id] = $obj.content
    }
    $r.Rows = $rows
    $r.Bad = $bad
    return $r
}

# The payload text of one sample by file name.
function Get-SubagentSample([string] $Name) { return (Get-Content -LiteralPath (Join-Path $subSampleDir $Name) -Raw) }

try {
# Every sample end to end: exit 0, nothing on stderr, every line a well-formed reply, no row for a
# task the payload does not have, one line of text per row carrying the robot glyph, and a width that
# fits the columns the payload asked for.
$subSamples = Get-ChildItem $subSampleDir -Filter *.json | Sort-Object Name
Confirm-True ($subSamples.Count -gt 0) 'subagent samples: the directory holds payloads'
foreach ($sample in $subSamples) {
    $payload = Get-Content -LiteralPath $sample.FullName -Raw
    $json = $payload | ConvertFrom-Json
    $r = Invoke-SubagentLine $payload
    $label = "subagent $($sample.Name)"
    Confirm-True ($r.ExitCode -eq 0) "${label}: exit code $($r.ExitCode)"
    Confirm-True ($r.Err.Count -eq 0) "${label}: stderr empty, got '$($r.Err -join ' | ')'"
    Confirm-Equal $r.Bad 0 "${label}: every line parses as an id and a content string"
    $ids = @($json.tasks | ForEach-Object { $_.id } | Where-Object { $_ -is [string] -and $_.Trim() })
    $cols = if ($json.columns -is [ValueType]) { [int] $json.columns } else { 0 }
    Confirm-True (@($r.Rows.Keys).Count -le $ids.Count) "${label}: no more rows than the payload has tasks"
    foreach ($id in @($r.Rows.Keys)) {
        $content = $r.Rows[$id]
        Confirm-True ($ids -contains $id) "${label}: row id '$id' is one of the payload's tasks"
        Confirm-True ($content -notmatch "[`r`n]") "${label}/${id}: one line, no newline inside it"
        Confirm-True ((ConvertTo-PlainText $content).Contains($iconRobot)) "${label}/${id}: carries the robot glyph"
        if ($cols -gt 0) {
            $w = Measure-VisibleWidth $content
            Confirm-True ($w -le $cols) "${label}/${id}: visible width $w fits the payload's $cols columns"
        }
    }
}

# 01: two running agents on a 200k window. The percentage takes the threshold colour and the token
# figure is dim, the same palette roles the main line uses; the glyph and the name are the model role.
$r = Invoke-SubagentLine (Get-SubagentSample '01-two-agents.json')
Confirm-Equal (@($r.Rows.Keys) -join ',') 'task_01,task_02' 'subagent 01: one row per task, in payload order'
Confirm-Equal (ConvertTo-PlainText $r.Rows['task_01']) "$iconRobot Explore  24%  48k" 'subagent 01: the registered name, the percentage and the token count'
Confirm-True ($r.Rows['task_01'].Contains("$esc[1;36m$iconRobot Explore$esc[0m")) 'subagent 01: glyph and name in the model colour'
Confirm-True ($r.Rows['task_01'].Contains("$esc[32m24%$esc[0m")) 'subagent 01: 24% of a 200k window is green'
Confirm-Equal (ConvertTo-PlainText $r.Rows['task_02']) "$iconRobot general-purpose  91%  182k" 'subagent 01: the second row reads the same way'
Confirm-True ($r.Rows['task_02'].Contains("$esc[31m91%$esc[0m")) 'subagent 01: 91% is red'
Confirm-True ($r.Rows['task_02'].Contains("$esc[90m182k$esc[0m")) 'subagent 01: the token figure is dim'

# 02: an id, a type and a status and nothing else. The type stands in for a name and the status word
# stands in for a figure, so a row still says something.
$r = Invoke-SubagentLine (Get-SubagentSample '02-minimal.json')
Confirm-Equal (ConvertTo-PlainText $r.Rows['t1']) "$iconRobot local_bash  running" 'subagent 02: the type names the row and the status is the progress'

# 03: an empty task list is not an error, and an empty stdout is what the panel expects for it.
$r = Invoke-SubagentLine (Get-SubagentSample '03-no-tasks.json')
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'subagent 03: exit code 0, stderr empty'
Confirm-Equal (@($r.Lines | Where-Object { "$_".Trim() }).Count) 0 'subagent 03: no tasks, no output'

# 04: hostile fields. A name carrying an escape is not text, so the label is used instead and the
# escape never reaches the row; a blank id and an array id get no row at all, because a row only
# renders when its id comes back; 20.0 and 2e1 arrive as Double and still count as whole numbers; a
# zero window yields no percentage rather than a division by zero; the long label is clipped to 40.
$r = Invoke-SubagentLine (Get-SubagentSample '04-hostile-fields.json')
Confirm-Equal (@($r.Rows.Keys) -join ',') 'ok-1,ok-2,ok-3,ok-4' 'subagent 04: only the tasks with usable text for an id get a row'
Confirm-Equal (ConvertTo-PlainText $r.Rows['ok-1']) "$iconRobot safe label  0%" 'subagent 04: an escape in the name falls through to the label, and 20 of 200000 is 0% with no token figure'
Confirm-True (-not $r.Rows['ok-1'].Contains('red')) 'subagent 04: nothing of the escaped name reaches the row'
Confirm-True ((ConvertTo-PlainText $r.Rows['ok-1']) -notmatch '\p{Cc}') 'subagent 04: the row carries no control character of its own'
Confirm-True ((ConvertTo-PlainText $r.Rows['ok-2']).Contains($ellipsis)) 'subagent 04: the long label is clipped with an ellipsis'
Confirm-True ((ConvertTo-PlainText $r.Rows['ok-2']).EndsWith('completed')) 'subagent 04: a zero window leaves no percentage, so the status word is the progress'
Confirm-Equal (ConvertTo-PlainText $r.Rows['ok-3']) "$iconRobot remote_agent  pending" 'subagent 04: 2e1 tokens with no window is below a thousand, so the status shows instead'
Confirm-True ($r.Rows['ok-4'].Contains("$esc[33m72%$esc[0m")) 'subagent 04: a 1M window uses the 70 and 90 bands, so 72% is yellow'

# 05: a 1M window and no columns key. Nothing is clipped and 65% is still green under the wider bands.
$r = Invoke-SubagentLine (Get-SubagentSample '05-wide-window.json')
Confirm-Equal (ConvertTo-PlainText $r.Rows['wide_01']) "$iconRobot in-process teammate  65%  655k" 'subagent 05: no columns key means nothing is cut'
Confirm-True ($r.Rows['wide_01'].Contains("$esc[32m65%$esc[0m")) 'subagent 05: 65% of a 1M window is still green'

# Two ids that differ only in case are two tasks. The panel keeps them apart, so this script has to as
# well: its own id map used to be a PowerShell hashtable, which compares keys case-insensitively, and
# the second row was silently dropped - that subagent showed nothing at all.
$r = Invoke-SubagentLine '{ "columns": 60, "tasks": [ { "id": "T1", "name": "upper", "status": "running" }, { "id": "t1", "name": "lower", "status": "running" } ] }'
Confirm-Equal (@($r.Rows.Keys) -join ',') 'T1,t1' 'subagent case ids: both ids get a row'
Confirm-Equal (ConvertTo-PlainText $r.Rows['T1']) "$iconRobot upper  running" 'subagent case ids: the upper case id gets its own task'
Confirm-Equal (ConvertTo-PlainText $r.Rows['t1']) "$iconRobot lower  running" 'subagent case ids: the lower case id gets its own task'
# And the same id twice, in the same case, is still answered once.
$r = Invoke-SubagentLine '{ "columns": 60, "tasks": [ { "id": "d1", "name": "first", "status": "running" }, { "id": "d1", "name": "second", "status": "running" } ] }'
Confirm-Equal (@($r.Lines | Where-Object { "$_".Trim() }).Count) 1 'subagent repeat id: an exact repeat is still answered once'
Confirm-Equal (ConvertTo-PlainText $r.Rows['d1']) "$iconRobot first  running" 'subagent repeat id: the first one is the one answered'

# A name carrying a right-to-left override is not an escape sequence, so nothing about the escape rule
# catches it, and ConvertTo-Json emits it raw. It reorders whatever the panel draws after it. The
# character is stripped and the name is still the name: falling through to the label would throw away a
# perfectly good name over one invisible character.
$r = Invoke-SubagentLine '{ "columns": 60, "tasks": [ { "id": "b1", "name": "sa\u202efe", "label": "fallback", "status": "running" } ] }'
Confirm-Equal (ConvertTo-PlainText $r.Rows['b1']) "$iconRobot safe  running" 'subagent bidi: the override is stripped and the name still names the row'
Confirm-True ($r.Rows['b1'] -notmatch '\p{Cf}') 'subagent bidi: no format character reaches the row'
# A name that is nothing but format characters would draw nothing at all, so it is not text and the
# label takes over, the same way an escape in a name hands over to the label.
$r = Invoke-SubagentLine '{ "columns": 60, "tasks": [ { "id": "b2", "name": "\u202e\u2066", "label": "fallback", "status": "running" } ] }'
Confirm-Equal (ConvertTo-PlainText $r.Rows['b2']) "$iconRobot fallback  running" 'subagent bidi: a name that is only overrides falls through to the label'
# The status word is the other payload string that reaches a row.
$r = Invoke-SubagentLine '{ "columns": 60, "tasks": [ { "id": "b3", "type": "local_bash", "status": "run\u202ening" } ] }'
Confirm-Equal (ConvertTo-PlainText $r.Rows['b3']) "$iconRobot local_bash  running" 'subagent bidi: the status word is stripped too'
Confirm-True ($r.Rows['b3'] -notmatch '\p{Cf}') 'subagent bidi: no format character reaches the row through the status'
# The id is the panel's key, not text it draws, so it is echoed exactly as it arrived: a sanitised copy
# would match no task and the row would never appear.
$r = Invoke-SubagentLine '{ "columns": 60, "tasks": [ { "id": "id\u202ex", "name": "keyed", "status": "running" } ] }'
Confirm-Equal (@($r.Rows.Keys) -join ',') "id$([char]0x202E)x" 'subagent bidi: the id is echoed exactly as the panel sent it'

# Anything the script cannot read prints nothing and exits 0. A bare glyph could not stand in here the
# way the main script's fallback line does: it is not JSON, so the panel would log it and drop it.
foreach ($case in @(
        @{ Name = 'malformed JSON'; Payload = 'not json at all' }
        @{ Name = 'empty stdin'; Payload = '' }
        @{ Name = 'a truncated object'; Payload = '{ "tasks": [ { "id": "x"' }
        @{ Name = 'an array payload'; Payload = '[1, 2, 3]' }
        @{ Name = 'a bare number'; Payload = '42' }
        @{ Name = 'no tasks key'; Payload = '{ "columns": 80 }' }
        @{ Name = 'tasks as an object'; Payload = '{ "tasks": { "id": "x" } }' }
        @{ Name = 'tasks as a string'; Payload = '{ "tasks": "x" }' }
        @{ Name = 'a task that is a number'; Payload = '{ "tasks": [ 1, 2 ] }' }
        @{ Name = 'a task with no id'; Payload = '{ "tasks": [ { "name": "no id" } ] }' })) {
    $r = Invoke-SubagentLine $case.Payload
    $label = "subagent $($case.Name)"
    Confirm-True ($r.ExitCode -eq 0) "${label}: exit code $($r.ExitCode)"
    Confirm-True ($r.Err.Count -eq 0) "${label}: stderr empty, got '$($r.Err -join ' | ')'"
    Confirm-Equal (@($r.Lines | Where-Object { "$_".Trim() }).Count) 0 "${label}: no output"
}

# A repeated id is answered once: the panel keys its map by id, so a second line would only overwrite.
$r = Invoke-SubagentLine '{ "tasks": [ { "id": "same", "name": "first" }, { "id": "same", "name": "second" } ] }'
Confirm-Equal (@($r.Lines | Where-Object { "$_".Trim() }).Count) 1 'subagent duplicate id: one line, not two'
Confirm-True ((ConvertTo-PlainText $r.Rows['same']).Contains('first')) 'subagent duplicate id: the first task wins'

# The panel can be very narrow. At every width the row still fits, and the glyph is the last thing to
# go, so a row never disappears and never wraps the panel.
$narrowTask = '{ "id": "n1", "name": "a name long enough to need clipping", "status": "running", "contextWindowSize": 200000, "tokenCount": 120000 }'
foreach ($cols in @(80, 40, 20, 12, 8, 4, 2, 1)) {
    $r = Invoke-SubagentLine ('{ "columns": ' + $cols + ', "tasks": [ ' + $narrowTask + ' ] }')
    $label = "subagent columns $cols"
    Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) "${label}: exit code 0, stderr empty"
    Confirm-Equal (@($r.Rows.Keys).Count) 1 "${label}: one row"
    $w = Measure-VisibleWidth $r.Rows['n1']
    Confirm-True ($w -le $cols) "${label}: visible width $w fits"
    Confirm-True ((ConvertTo-PlainText $r.Rows['n1']).Contains($iconRobot)) "${label}: the glyph is never dropped"
}
# At a width that can hold them, the figures survive and the name is what gets clipped.
$r = Invoke-SubagentLine ('{ "columns": 20, "tasks": [ ' + $narrowTask + ' ] }')
Confirm-True ($r.Rows['n1'].Contains('60%') -and $r.Rows['n1'].Contains('120k')) 'subagent columns 20: the percentage and the token count are kept'
Confirm-True ((ConvertTo-PlainText $r.Rows['n1']).Contains($ellipsis)) 'subagent columns 20: the name is what gets clipped'
# An explicit columns of 0 is the panel saying it has no room, which is not the same as saying nothing
# about the width: a row printed into no room would wrap or overwrite the panel, so none is printed.
$r = Invoke-SubagentLine ('{ "columns": 0, "tasks": [ ' + $narrowTask + ' ] }')
Confirm-True ($r.ExitCode -eq 0) "subagent columns 0: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "subagent columns 0: stderr empty, got '$($r.Err -join ' | ')'"
Confirm-Equal (@($r.Lines | Where-Object { "$_".Trim() }).Count) 0 'subagent columns 0: no room means no row'
# Every task in the payload goes, not just the one that would not have fitted.
$r = Invoke-SubagentLine ('{ "columns": 0, "tasks": [ ' + $narrowTask + ', { "id": "n2", "name": "x" } ] }')
Confirm-Equal (@($r.Lines | Where-Object { "$_".Trim() }).Count) 0 'subagent columns 0: no row for any task'
# One is still a width, and the glyph fits in it, so zero is the only value that prints nothing.
$r = Invoke-SubagentLine ('{ "columns": 1, "tasks": [ ' + $narrowTask + ' ] }')
Confirm-Equal (@($r.Rows.Keys).Count) 1 'subagent columns 1: one column is still a column'

# A columns value that is not a whole count says nothing about the width, so nothing is cut. This is
# the fallback, and an explicit 0 above must not reach it.
foreach ($bad in @('"columns": "80"', '"columns": 20.5', '"columns": true', '"columns": -5')) {
    $r = Invoke-SubagentLine ('{ ' + $bad + ', "tasks": [ ' + $narrowTask + ' ] }')
    Confirm-True ((ConvertTo-PlainText $r.Rows['n1']) -eq "$iconRobot a name long enough to need clipping  60%  120k") "subagent $($bad): an unusable columns value cuts nothing"
}

# The helpers the subagent script copies out of statusline.ps1. Both copies are pulled from the source
# by the parser and compared as text, so a fix made to one and not the other fails here instead of
# turning into two scripts that measure a line or colour a percentage differently.
$sharedHelpers = @('G', 'C', 'Get-VisibleWidth', 'Get-Palette', 'Get-ThresholdRole', 'Test-WideWindow', 'K', 'Get-FiniteNumber', 'Get-PayloadNumber', 'Format-PayloadText', 'Test-PayloadText')
foreach ($name in $sharedHelpers) {
    $a = try { "$(Import-ScriptFunction $script @($name))" } catch { "not found in statusline.ps1" }
    $b = try { "$(Import-ScriptFunction $subScript @($name))" } catch { "not found in subagent-statusline.ps1" }
    Confirm-Equal $b $a "subagent drift: $name is the same text in both scripts"
}


# ---- Review findings: bounded capture, atomic settings write, ownership, quoting, explicit zero ----

# The capture helper is bounded. It rotates over one sibling rather than growing forever, and a write
# it cannot make stops it once, with a reason, instead of failing silently every five seconds.
$capScript = Join-Path $PSScriptRoot 'tools\capture-stdin.ps1'
$capFile = Join-Path $subTmp 'cap.jsonl'
$capRecord = '{"tasks":[{"id":"x","name":"' + ('y' * 400) + '"}]}'
$capMax = 1024
$capRecordBytes = [System.Text.Encoding]::UTF8.GetByteCount($capRecord) + 2
for ($i = 0; $i -lt 12; $i++) {
    $c = Invoke-ChildPwsh $capScript @('-Path', $capFile, '-MaxBytes', "$capMax") $capRecord
    if ($i -eq 0) { Confirm-True ($c.ExitCode -eq 0 -and $c.Err.Count -eq 0) 'capture: exit code 0, stderr empty' }
    Confirm-Equal (@($c.Lines | Where-Object { "$_".Trim() }).Count) 0 "capture write $($i): nothing on stdout"
}
$capMain = (Get-Item -LiteralPath $capFile).Length
Confirm-True (Test-Path -LiteralPath "$capFile.1") 'capture: the file rotated over its one sibling'
Confirm-True (-not (Test-Path -LiteralPath "$capFile.2")) 'capture: only one generation is kept'
Confirm-True ($capMain -le $capMax + $capRecordBytes) "capture: the live file is bounded, $capMain bytes against a $capMax cap"
$capTotal = $capMain + (Get-Item -LiteralPath "$capFile.1").Length
Confirm-True ($capTotal -le 2 * ($capMax + $capRecordBytes)) "capture: the whole capture is bounded, $capTotal bytes"
# Twelve records of over 400 bytes each would be more than 4800 bytes unbounded.
Confirm-True ($capTotal -lt 12 * $capRecordBytes) 'capture: twelve records did not all survive, so the bound is doing something'

# A path that cannot be written (a directory of that name) stops the capture once and says why: a line
# on stderr, never on stdout, a sidecar file, and exit 0 so the panel is not taken down with it.
$capDir = Join-Path $subTmp 'cap-is-a-directory'
New-Item -ItemType Directory -Force $capDir | Out-Null
$c = Invoke-ChildPwsh $capScript @('-Path', $capDir) $capRecord
Confirm-True ($c.ExitCode -eq 0) "capture failure: exit code $($c.ExitCode) is still 0"
Confirm-Equal (@($c.Lines | Where-Object { "$_".Trim() }).Count) 0 'capture failure: nothing on stdout'
Confirm-True (($c.Err -join ' ').Contains('capture-stdin:')) "capture failure: the reason went to stderr, got '$($c.Err -join ' | ')'"
Confirm-True (Test-Path -LiteralPath "$capDir.error") 'capture failure: the sidecar names the failure'
$sidecar = Get-Content -LiteralPath "$capDir.error" -Raw
# A second run finds the sidecar and gives up quietly rather than retrying every tick.
$c = Invoke-ChildPwsh $capScript @('-Path', $capDir) $capRecord
Confirm-True ($c.ExitCode -eq 0 -and $c.Err.Count -eq 0) 'capture failure: a later run is silent while the sidecar is there'
Confirm-Equal (Get-Content -LiteralPath "$capDir.error" -Raw) $sidecar 'capture failure: the sidecar is written once, not once per tick'

# One payload bigger than the whole cap. Stdin is read to a ceiling and the record is cut to fit, so
# neither memory nor the file follows the payload's size.
$capBigFile = Join-Path $subTmp 'cap-big.jsonl'
$capBigMax = 2048
$capBigPayload = '{"x":"' + ('z' * 20000) + '"}'
$c = Invoke-ChildPwsh $capScript @('-Path', $capBigFile, '-MaxBytes', "$capBigMax") $capBigPayload
Confirm-True ($c.ExitCode -eq 0) "capture oversize: exit code $($c.ExitCode)"
Confirm-True ($c.Err.Count -eq 0) "capture oversize: stderr empty, got '$($c.Err -join ' | ')'"
$capBigLen = (Get-Item -LiteralPath $capBigFile).Length
Confirm-True ($capBigLen -le $capBigMax) "capture oversize: one payload of $($capBigPayload.Length) bytes left a $capBigLen byte file, under the $capBigMax cap"
Confirm-True ((Get-Content -LiteralPath $capBigFile -Raw).Contains('...[truncated]')) 'capture oversize: the record says it was cut'
# And repeated oversize payloads leave both generations under the cap rather than one of them over it.
for ($i = 0; $i -lt 6; $i++) { $null = Invoke-ChildPwsh $capScript @('-Path', $capBigFile, '-MaxBytes', "$capBigMax") $capBigPayload }
$capBigLen = (Get-Item -LiteralPath $capBigFile).Length
$capBigRotated = if (Test-Path -LiteralPath "$capBigFile.1") { (Get-Item -LiteralPath "$capBigFile.1").Length } else { 0 }
Confirm-True ($capBigLen -le $capBigMax) "capture oversize: the live file stays under the cap at $capBigLen bytes"
Confirm-True ($capBigRotated -le $capBigMax) "capture oversize: the rotated file stays under the cap at $capBigRotated bytes"
Confirm-True (($capBigLen + $capBigRotated) -le 2 * $capBigMax) 'capture oversize: both generations together stay under twice the cap'
Confirm-True (-not (Test-Path -LiteralPath "$capBigFile.2")) 'capture oversize: still only one generation is kept'


# The two ownership tests, driven directly. Both decide whether the uninstaller may delete something, so
# each one is checked against the forms that must NOT count as ours as well as the ones that must.
. (Import-ScriptFunction $installer @('Split-CommandArgument', 'Test-SamePath', 'Test-OwnSubagentEntry', 'Test-OwnSubagentScript'))
$subagentMarkerLine = '# claude-code-statusline-ps:subagent-statusline'
$subagentMarkerWithin = 10
Confirm-True ((Get-Content -LiteralPath $installer -Raw).Contains("`$subagentMarkerLine = '$subagentMarkerLine'")) 'ownership: the marker the tests use is the one install.ps1 defines'
Confirm-True ((Get-Content -LiteralPath $installer -Raw).Contains("`$subagentMarkerWithin = $subagentMarkerWithin")) 'ownership: the header window the tests use is the one install.ps1 defines'

# The command has to be the whole form this installer writes, with the target as the -File argument
# itself. A command that merely carries the path somewhere is somebody else's, and deleting it would be
# the destructive mistake; a command that runs our script under a different spelling is still ours.
$ownTarget = 'C:\Users\me\.claude\subagent-statusline.ps1'
foreach ($case in @(
        @{ Own = $true;  Command = 'pwsh -NoProfile -NoLogo -NonInteractive -File "C:/Users/me/.claude/subagent-statusline.ps1"'; Label = 'the form the installer writes' }
        @{ Own = $true;  Command = 'pwsh -NoProfile -NoLogo -NonInteractive -File C:/Users/me/.claude/subagent-statusline.ps1'; Label = 'the older unquoted form' }
        @{ Own = $true;  Command = 'pwsh -File C:\Users\me\.claude\subagent-statusline.ps1'; Label = 'backslashes and fewer switches' }
        @{ Own = $true;  Command = 'pwsh.exe -NoProfile -File "c:/users/me/.claude/SUBAGENT-STATUSLINE.PS1"'; Label = 'a different case and an .exe suffix' }
        @{ Own = $false; Command = 'node wrapper.js "C:/Users/me/.claude/subagent-statusline.ps1"'; Label = 'a foreign wrapper that carries the path as an argument' }
        @{ Own = $false; Command = 'pwsh -NoProfile -File other.ps1 # C:/Users/me/.claude/subagent-statusline.ps1'; Label = 'the path only in a trailing comment' }
        @{ Own = $false; Command = 'pwsh -NoProfile -File "C:/Users/me/.claude/subagent-statusline.ps1" --extra'; Label = 'an argument after the script' }
        @{ Own = $false; Command = 'pwsh -NoProfile -File "C:/Users/me/.claude/subagent-statusline.ps1" & rm -rf /'; Label = 'a chained command' }
        @{ Own = $false; Command = 'pwsh -NoProfile -File "C:/Users/me/.claude/subagent-statusline.ps1" | tee log'; Label = 'a pipeline' }
        @{ Own = $false; Command = 'pwsh -NoProfile -Command "& C:/Users/me/.claude/subagent-statusline.ps1"'; Label = '-Command rather than -File' }
        @{ Own = $false; Command = 'pwsh -NoProfile -File "C:/Users/me/.claude/subagent-statusline-2.ps1"'; Label = 'a different file whose name starts the same' }
        @{ Own = $false; Command = 'pwsh -NoProfile -File "C:/Users/me/.claude/"'; Label = 'the directory rather than the script' }
        @{ Own = $false; Command = 'pwsh -NoProfile -File "$HOME/.claude/subagent-statusline.ps1"'; Label = 'an environment variable standing in for the path' }
        @{ Own = $false; Command = 'pwsh -NoProfile -File "C:/Users/me/.claude/subagent-statusline.ps1'; Label = 'a quote that never closes' }
        @{ Own = $false; Command = 'pwsh -NoProfile -File'; Label = 'no argument after -File' }
        @{ Own = $false; Command = ''; Label = 'an empty command' })) {
    $entry = [pscustomobject]@{ type = 'command'; command = $case.Command }
    Confirm-Equal (Test-OwnSubagentEntry $entry $ownTarget) $case.Own "ownership entry: $($case.Label)"
}
# The shape of the entry matters as much as the command inside it.
Confirm-Equal (Test-OwnSubagentEntry ([pscustomobject]@{ type = 'other'; command = "pwsh -File $ownTarget" }) $ownTarget) $false 'ownership entry: a type that is not command'
Confirm-Equal (Test-OwnSubagentEntry ([pscustomobject]@{ type = 'command'; command = @('pwsh', '-File', $ownTarget) }) $ownTarget) $false 'ownership entry: a command that is an array, not a string'
Confirm-Equal (Test-OwnSubagentEntry 'a bare string' $ownTarget) $false 'ownership entry: an entry that is not an object'
Confirm-Equal (Test-OwnSubagentEntry $null $ownTarget) $false 'ownership entry: no entry at all'

# The marker has to be a line of its own near the top. The token appearing anywhere else is not evidence
# the file is ours, and treating it as such would delete somebody's script.
$markerCases = @(
    @{ Own = $true;  Label = 'the marker on its own line, as installed'; Text = "#Requires -Version 7.0`n$subagentMarkerLine`n# and the rest of the header" }
    @{ Own = $true;  Label = 'the marker line indented'; Text = "#Requires -Version 7.0`n   $subagentMarkerLine   `n# rest" }
    @{ Own = $false; Label = 'the token inside a longer comment line'; Text = "# see claude-code-statusline-ps:subagent-statusline for the marker rule" }
    @{ Own = $false; Label = 'the token inside a string literal'; Text = "`$marker = 'claude-code-statusline-ps:subagent-statusline'" }
    @{ Own = $false; Label = 'the token in a comment trailing real code'; Text = "Write-Host 'hi'  # claude-code-statusline-ps:subagent-statusline" }
    @{ Own = $false; Label = 'the marker line below the header window'; Text = ((1..12 | ForEach-Object { "# filler $_" }) -join "`n") + "`n$subagentMarkerLine" }
    @{ Own = $false; Label = 'the marker in the wrong case'; Text = '# CLAUDE-CODE-STATUSLINE-PS:SUBAGENT-STATUSLINE' }
    @{ Own = $false; Label = 'the token as embedded data on a line of its own'; Text = "#Requires -Version 7.0`nclaude-code-statusline-ps:subagent-statusline" }
    @{ Own = $false; Label = 'an empty file'; Text = '' }
)
$markerIndex = 0
foreach ($case in $markerCases) {
    $markerFile = Join-Path $subTmp "marker-$markerIndex.ps1"
    $markerIndex++
    Set-Content -LiteralPath $markerFile -Value $case.Text -Encoding utf8NoBOM
    Confirm-Equal (Test-OwnSubagentScript $markerFile) $case.Own "ownership file: $($case.Label)"
}
Confirm-Equal (Test-OwnSubagentScript (Join-Path $subTmp 'no-such-file.ps1')) $false 'ownership file: a file that is not there'
Confirm-Equal (Test-OwnSubagentScript $subScript) $true 'ownership file: the repo copy is recognised as ours'

# Read-UserSetting and Write-UserSetting driven directly, so the write path can be failed on purpose
# without a second process racing this one. $settingsBaseline is the script-scope table install.ps1
# keeps, and has to exist here for the same reason it does there.
. (Import-ScriptFunction $installer @('Read-UserSetting', 'Write-UserSetting', 'Get-SettingLock', 'Confirm-SettingUnchanged'))
$settingsBaseline = @{}
$settingsLockTimeoutMs = 5000

# A change made between the read and the write is refused, and the other writer's file survives intact.
$conflictPath = Join-Path $subTmp 'conflict.json'
Set-Content -LiteralPath $conflictPath -Value '{ "a": 1 }' -Encoding utf8NoBOM
Confirm-Equal $settingsBaseline.Count 0 'settings baseline: nothing is recorded before the first read'
$conflictObj = Read-UserSetting $conflictPath
Confirm-True ($settingsBaseline.ContainsKey($conflictPath)) 'settings baseline: the read records the text it saw, which is what the write compares against'
Set-Content -LiteralPath $conflictPath -Value '{ "a": 2, "b": 3 }' -Encoding utf8NoBOM
$threw = $false
try { Write-UserSetting $conflictObj $conflictPath } catch { $threw = $true; $conflictMessage = "$_" }
Confirm-True $threw 'settings conflict: a file that changed after the read is refused'
Confirm-True ((Get-Content -LiteralPath $installer -Raw).Contains("`$settingsLockTimeoutMs = $settingsLockTimeoutMs")) 'settings conflict: the lock timeout the tests use is the one install.ps1 defines'
Confirm-True ($conflictMessage -match 'changed after this installer read it') "settings conflict: the message says why, got '$conflictMessage'"
Confirm-Equal (Get-Content -LiteralPath $conflictPath -Raw).Trim() '{ "a": 2, "b": 3 }' 'settings conflict: the other writer''s content is untouched'
Confirm-Equal (@(Get-ChildItem -LiteralPath $subTmp -Filter 'conflict.json.tmp-*' -Force).Count) 0 'settings conflict: no temporary file is left behind'

# A replace that cannot be made leaves the original exactly as it was. A read-only destination is the
# failure that is deterministic on Windows; a full disk or a killed process lands in the same place,
# because nothing is truncated in the first place - the new text goes to a sibling and is moved over.
$roPath = Join-Path $subTmp 'readonly.json'
Set-Content -LiteralPath $roPath -Value '{ "keep": "me" }' -Encoding utf8NoBOM
$roObj = Read-UserSetting $roPath
$roObj | Add-Member -NotePropertyName statusLine -NotePropertyValue 'would be written'
Set-ItemProperty -LiteralPath $roPath -Name IsReadOnly -Value $true
$threw = $false
try { Write-UserSetting $roObj $roPath } catch { $threw = $true }
Confirm-True $threw 'settings write failure: a replace that cannot be made throws'
Confirm-Equal (Get-Content -LiteralPath $roPath -Raw).Trim() '{ "keep": "me" }' 'settings write failure: the original is neither emptied nor half-written'
Confirm-Equal (@(Get-ChildItem -LiteralPath $subTmp -Filter 'readonly.json.tmp-*' -Force).Count) 0 'settings write failure: no temporary file is left behind'
Set-ItemProperty -LiteralPath $roPath -Name IsReadOnly -Value $false

# A write that does go through leaves no temporary file either, and the result parses.
$okPath = Join-Path $subTmp 'ok.json'
Set-Content -LiteralPath $okPath -Value '{ "a": 1 }' -Encoding utf8NoBOM
$okObj = Read-UserSetting $okPath
$okObj | Add-Member -NotePropertyName b -NotePropertyValue 2
Write-UserSetting $okObj $okPath
Confirm-Equal ((Get-Content -LiteralPath $okPath -Raw | ConvertFrom-Json).b) 2 'settings write: the new key landed'
Confirm-Equal (@(Get-ChildItem -LiteralPath $subTmp -Filter 'ok.json.tmp-*' -Force).Count) 0 'settings write: no temporary file is left behind'
Confirm-Equal (Get-Content -LiteralPath "$okPath.bak" -Raw).Trim() '{ "a": 1 }' 'settings write: the .bak holds the file as it was'
# A second write in the same process must not mistake its own last write for somebody else's change.
# The baseline is refreshed from the file, not from the serialized text, because the two differ by the
# newline Set-Content adds.
$okObj | Add-Member -NotePropertyName c -NotePropertyValue 3
$threw = $false
try { Write-UserSetting $okObj $okPath } catch { $threw = $true; $conflictMessage = "$_" }
Confirm-True (-not $threw) "settings write: a second write in the same process is not a conflict, got '$conflictMessage'"
Confirm-Equal ((Get-Content -LiteralPath $okPath -Raw | ConvertFrom-Json).c) 3 'settings write: the second write landed'

# ---- Install group: install.ps1 -Subagents against a settings.json inside the temp tree ----
# USERPROFILE is redirected under $subTmp and -SettingsPath points there too, so the copy target, the
# settings file and the uninstall delete all land in the temp tree. The real ~/.claude files are
# hashed before the group and compared after it: nothing here may write outside $subTmp.
$subRealDir = Join-Path $env:USERPROFILE '.claude'
$subRealNames = @('settings.json', 'settings.json.bak', 'statusline.ps1', 'statusline.json', 'subagent-statusline.ps1')
$subRealHash = [ordered]@{}
foreach ($n in $subRealNames) { $subRealHash[$n] = Get-ContentHash (Join-Path $subRealDir $n) }
# The ownership cases below are the ones that delete files, so the guard is widened from the five files
# the installer writes to every name in the real ~/.claude. Names only, not content: this suite runs
# while Claude Code is live and its own files move underneath us, but nothing here may make one vanish.
$subRealNamesBefore = @(Get-ChildItem -LiteralPath $subRealDir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
$subHome = Join-Path $subTmp 'install-home'
New-Item -ItemType Directory -Force $subHome | Out-Null
$subOldProfile = $env:USERPROFILE
try {
$env:USERPROFILE = $subHome
$subSettings = Join-Path $subHome 'settings.json'
Set-Content -LiteralPath $subSettings -Value '{ "theme": "dark" }' -Encoding utf8NoBOM
$installedSub = Join-Path $subHome '.claude\subagent-statusline.ps1'
$expectSubCommand = 'pwsh -NoProfile -NoLogo -NonInteractive -File "' + ($installedSub -replace '\\', '/') + '"'

# Without the switch neither the file nor the key appears, so an existing install is left as it was.
$r = Invoke-Installer 'install without -Subagents' @('-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0) "subagent install plain: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "subagent install plain: stderr empty, got '$($r.Err -join ' | ')'"
Confirm-Equal (Get-KeyList (Read-SettingFile $subSettings)) 'theme,statusLine' 'subagent install plain: no subagentStatusLine key'
Confirm-True (-not (Test-Path -LiteralPath $installedSub)) 'subagent install plain: subagent-statusline.ps1 not copied'

$r = Invoke-Installer 'install -Subagents' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0) "subagent install: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "subagent install: stderr empty, got '$($r.Err -join ' | ')'"
Confirm-True (Test-Path -LiteralPath $installedSub) 'subagent install: subagent-statusline.ps1 copied into the temp home'
$s = Read-SettingFile $subSettings
Confirm-Equal (Get-KeyList $s) 'theme,statusLine,subagentStatusLine' 'subagent install: the unrelated key is kept and both entries are there'
Confirm-Equal $s.theme 'dark' 'subagent install: theme kept'
Confirm-Equal (Get-KeyList $s.statusLine) 'type,command,padding,hideVimModeIndicator' 'subagent install: the statusLine entry is untouched'
Confirm-Equal (Get-KeyList $s.subagentStatusLine) 'type,command' 'subagent install: the subagent entry is type and command only'
Confirm-Equal $s.subagentStatusLine.type 'command' 'subagent install: type'
Confirm-Equal $s.subagentStatusLine.command $expectSubCommand 'subagent install: command points at the temp home with forward slashes'
Confirm-True (($r.Lines -join "`n").Contains('subagentStatusLine')) "subagent install: the message names the key, got '$($r.Lines -join ' | ')'"

# The copy in the temp home is the script itself, so it answers for a real payload.
if (Test-Path -LiteralPath $installedSub) {
    $c = Invoke-ChildPwsh $installedSub @() (Get-SubagentSample '02-minimal.json')
    Confirm-True ($c.ExitCode -eq 0 -and $c.Err.Count -eq 0) 'subagent install: the installed copy runs clean'
    Confirm-True ((@($c.Lines) -join '').Contains('"id":"t1"')) 'subagent install: the installed copy answers for the task'
}

# A second run replaces the entry rather than adding another one.
$r = Invoke-Installer 'install -Subagents again' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'subagent install twice: exit code 0, stderr empty'
Confirm-Equal (Get-KeyList (Read-SettingFile $subSettings)) 'theme,statusLine,subagentStatusLine' 'subagent install twice: still one subagentStatusLine key'

# Uninstall takes both entries out in a single write, so the .bak still holds the settings as they
# were, and deletes both scripts. The switch is not needed for the removal.
$r = Invoke-Installer 'uninstall with a subagent line' @('-Uninstall', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0) "subagent uninstall: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "subagent uninstall: stderr empty, got '$($r.Err -join ' | ')'"
Confirm-Equal (Get-KeyList (Read-SettingFile $subSettings)) 'theme' 'subagent uninstall: both entries removed, theme kept'
Confirm-True (-not (Test-Path -LiteralPath $installedSub)) 'subagent uninstall: subagent-statusline.ps1 deleted from the temp home'
Confirm-Equal (Get-KeyList (Read-SettingFile "$subSettings.bak")) 'theme,statusLine,subagentStatusLine' 'subagent uninstall: the .bak holds the settings as they were, both entries in it'
$text = $r.Lines -join "`n"
Confirm-True ($text -match 'Removed statusLine \([^)]+\) and subagentStatusLine') "subagent uninstall: the message names both keys, got '$text'"
Confirm-True ($text.Contains('subagent-statusline.ps1')) "subagent uninstall: the message names the deleted script, got '$text'"

# A settings file that never had a subagent line still uninstalls, and says only what it removed.
$r = Invoke-Installer 'install before a plain uninstall' @('-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'subagent plain uninstall: the install before it is clean'
$r = Invoke-Installer 'uninstall without a subagent line' @('-Uninstall', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'subagent plain uninstall: exit code 0, stderr empty'
Confirm-Equal (Get-KeyList (Read-SettingFile $subSettings)) 'theme' 'subagent plain uninstall: statusLine removed, theme kept'
Confirm-True (-not (($r.Lines -join "`n").Contains('subagentStatusLine'))) 'subagent plain uninstall: the message does not name a key that was not there'

# Nothing left to remove: no rewrite, so the .bak from the run before it survives.
$before = Get-Content -LiteralPath $subSettings -Raw
$beforeStamp = Get-WriteStamp $subSettings
$r = Invoke-Installer 'uninstall a third time' @('-Uninstall', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'subagent empty uninstall: exit code 0, stderr empty'
Confirm-Equal (Get-Content -LiteralPath $subSettings -Raw) $before 'subagent empty uninstall: settings.json content unchanged'
Confirm-True ((Get-WriteStamp $subSettings) -eq $beforeStamp) 'subagent empty uninstall: settings.json not rewritten'

# A subagentStatusLine somebody else set up, and a file of that name somebody else wrote, are not this
# installer's to delete. The key is ours only when its command names ~/.claude/subagent-statusline.ps1
# and the file is ours only when it carries the marker line, so both of these survive -Uninstall and
# are reported. This is the case that would destroy a user's own configuration if it regressed.
$r = Invoke-Installer 'install -Subagents before the ownership cases' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'subagent ownership: the install before it is clean'
Confirm-True (Test-Path -LiteralPath $installedSub) 'subagent ownership: the seam holds, the script is in the temp home'
$foreignScript = '# not this project, someone else wrote this'
Set-Content -LiteralPath $installedSub -Value $foreignScript -Encoding utf8NoBOM
$s = Read-SettingFile $subSettings
$s.subagentStatusLine.command = 'node /home/me/my-own-panel.js'
$s | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $subSettings -Encoding utf8NoBOM
$r = Invoke-Installer 'uninstall with a foreign subagent line' @('-Uninstall', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0) "subagent ownership: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "subagent ownership: stderr empty, got '$($r.Err -join ' | ')'"
$s = Read-SettingFile $subSettings
Confirm-Equal (Get-KeyList $s) 'theme,subagentStatusLine' 'subagent ownership: a foreign subagentStatusLine is kept, statusLine still removed'
Confirm-Equal $s.subagentStatusLine.command 'node /home/me/my-own-panel.js' 'subagent ownership: the foreign command is untouched'
Confirm-True (Test-Path -LiteralPath $installedSub) 'subagent ownership: a file without the marker is not deleted'
Confirm-Equal (Get-Content -LiteralPath $installedSub -Raw).Trim() $foreignScript 'subagent ownership: the foreign file is untouched'
$text = $r.Lines -join "`n"
Confirm-True ($text -match 'Kept:.+does not point at') "subagent ownership: the run says the key was kept, got '$text'"
Confirm-True ($text -match "Kept:.+does not carry this project's marker") "subagent ownership: the run says the file was kept, got '$text'"

# A key that is ours but a file that is not, and the other way round, are judged one at a time. Getting
# to that state now takes a detour, because the install path applies the same ownership rule as the
# uninstall path: a foreign file cannot be reinstalled over, it has to be moved out of the way first.
$r = Invoke-Installer 'install -Subagents over the foreign file' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -ne 0) "subagent ownership mixed: a reinstall over a foreign file is refused rather than forced, exit $($r.ExitCode)"
Confirm-Equal (Get-Content -LiteralPath $installedSub -Raw).Trim() $foreignScript 'subagent ownership mixed: the foreign file survives the refused reinstall'
Remove-Item -LiteralPath $installedSub -Force
$r = Invoke-Installer 'install -Subagents once the foreign file is gone' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'subagent ownership mixed: the install is clean once the foreign file is out of the way'
Confirm-True ((Get-Content -LiteralPath $installedSub -Raw).Contains('claude-code-statusline-ps:subagent-statusline')) 'subagent ownership mixed: the installed file is ours, marker and all'
Set-Content -LiteralPath $installedSub -Value $foreignScript -Encoding utf8NoBOM
$r = Invoke-Installer 'uninstall, our key and a foreign file' @('-Uninstall', '-SettingsPath', $subSettings)
Confirm-Equal (Get-KeyList (Read-SettingFile $subSettings)) 'theme' 'subagent ownership mixed: our key is removed'
Confirm-True (Test-Path -LiteralPath $installedSub) 'subagent ownership mixed: the foreign file is still kept'
Remove-Item -LiteralPath $installedSub -Force

# The marker is what makes a file ours, so the installed copy has to carry it and the repo copy has to
# be the source of it. A rename or a reword in either place breaks the uninstaller quietly otherwise.
Confirm-True ((Get-Content -LiteralPath $subScript -Raw).Contains('claude-code-statusline-ps:subagent-statusline')) 'subagent ownership: the repo copy carries the marker'


# Installing over a file this project did not write. The uninstall path got an ownership rule in the
# round before this one and the install path did not, so -Subagents would replace it with -Force. It
# now refuses, and refuses before anything at all has changed.
$foreignInstall = '# someone elses subagent line'
Set-Content -LiteralPath $installedSub -Value $foreignInstall -Encoding utf8NoBOM
$settingsBefore = Get-Content -LiteralPath $subSettings -Raw
# The refusal says "Nothing was installed", so nothing may have been. Sentinels in the two files the
# installer writes before it ever looks at the subagent script prove it: this used to refuse only after
# statusline.ps1 had already been copied over the top, and the message was untrue. Checking the settings
# alone, which is all this case used to check, cannot see that.
$subInstalledMain = Join-Path $subHome '.claude\statusline.ps1'
$subInstalledConfig = Join-Path $subHome '.claude\statusline.json'
$mainSentinel = '# not this installer, and not to be replaced by a run that refuses'
Set-Content -LiteralPath $subInstalledMain -Value $mainSentinel -Encoding utf8NoBOM
Remove-Item -LiteralPath $subInstalledConfig -Force -ErrorAction SilentlyContinue
$r = Invoke-Installer 'install -Subagents over an unowned file' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -ne 0) "install over unowned: exit code $($r.ExitCode) is non-zero"
Confirm-True ((($r.Lines + $r.Err) -join ' ') -match 'is not this project') "install over unowned: the message names the file and says why, got '$(($r.Lines + $r.Err) -join ' | ')'"
Confirm-Equal (Get-Content -LiteralPath $installedSub -Raw).Trim() $foreignInstall 'install over unowned: the file is not replaced'
Confirm-Equal (Get-Content -LiteralPath $subSettings -Raw) $settingsBefore 'install over unowned: the settings are not written either'
Confirm-Equal (Get-Content -LiteralPath $subInstalledMain -Raw).Trim() $mainSentinel 'install over unowned: statusline.ps1 is not copied over, so "Nothing was installed" is the truth'
Confirm-True (-not (Test-Path -LiteralPath $subInstalledConfig)) 'install over unowned: statusline.json is not written either'
Confirm-Equal (@(Get-ChildItem -LiteralPath (Join-Path $subHome '.claude') -Filter '*.tmp-*' -Force).Count) 0 'install over unowned: nothing is staged and left behind'
Remove-Item -LiteralPath $installedSub -Force

# The rollback copy: a reinstall over our own file keeps the version it replaced, under a name carrying
# this project's id rather than the generic .bak beside the script.
$installedRollback = Join-Path $subHome '.claude\.claude-code-statusline-ps.subagent-rollback.ps1'
$r = Invoke-Installer 'install -Subagents onto a clean home' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'install rollback copy: the first install is clean'
Confirm-True (-not (Test-Path -LiteralPath $installedRollback)) 'install rollback copy: nothing kept when there was nothing to replace'
$r = Invoke-Installer 'install -Subagents a second time' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'install rollback copy: the reinstall is clean'
Confirm-True (Test-Path -LiteralPath $installedRollback) 'install rollback copy: the replaced version is kept'
Confirm-True (-not (Test-Path -LiteralPath "$installedSub.bak")) 'install rollback copy: the generic .bak name beside the script is not used at all'
$r = Invoke-Installer 'uninstall after a reinstall' @('-Uninstall', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'install rollback copy: the uninstall is clean'
Confirm-True (-not (Test-Path -LiteralPath $installedRollback)) 'install rollback copy: the uninstall takes the rollback copy with it'

# A .bak beside the script that this installer did not write. It used to be overwritten on install and
# deleted on uninstall; nothing touches that name now, in either direction.
$foreignBak = "$installedSub.bak"
$foreignBakText = '# my own backup of my own subagent line'
Set-Content -LiteralPath $foreignBak -Value $foreignBakText -Encoding utf8NoBOM
$r = Invoke-Installer 'install -Subagents beside a foreign .bak' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'foreign .bak: the install is clean'
Confirm-Equal (Get-Content -LiteralPath $foreignBak -Raw).Trim() $foreignBakText 'foreign .bak: an install does not overwrite it'
$r = Invoke-Installer 'install -Subagents again beside a foreign .bak' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-Equal (Get-Content -LiteralPath $foreignBak -Raw).Trim() $foreignBakText 'foreign .bak: a reinstall, which does write a rollback copy, still does not overwrite it'
$r = Invoke-Installer 'uninstall beside a foreign .bak' @('-Uninstall', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'foreign .bak: the uninstall is clean'
Confirm-True (Test-Path -LiteralPath $foreignBak) 'foreign .bak: an uninstall does not delete it'
Confirm-Equal (Get-Content -LiteralPath $foreignBak -Raw).Trim() $foreignBakText 'foreign .bak: its content is untouched throughout'
Remove-Item -LiteralPath $foreignBak -Force

# And a foreign file sitting at the rollback name itself. The name is this project's, which is not proof
# that the file at it is, so it is checked by the marker before being overwritten or deleted.
$foreignRollbackText = '# not ours either, despite the name'
Set-Content -LiteralPath $installedRollback -Value $foreignRollbackText -Encoding utf8NoBOM
$r = Invoke-Installer 'install -Subagents onto a foreign rollback name' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0) "foreign rollback: the install still succeeds, exit $($r.ExitCode)"
Confirm-Equal (Get-Content -LiteralPath $installedRollback -Raw).Trim() $foreignRollbackText 'foreign rollback: the first install does not overwrite it'
$r = Invoke-Installer 'install -Subagents again onto a foreign rollback name' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0) "foreign rollback: the reinstall still succeeds, exit $($r.ExitCode)"
Confirm-Equal (Get-Content -LiteralPath $installedRollback -Raw).Trim() $foreignRollbackText 'foreign rollback: a reinstall skips the copy rather than overwriting it'
Confirm-True ((($r.Lines + $r.Err) -join ' ') -match 'Kept:.+rollback') "foreign rollback: the run says the copy was skipped, got '$(($r.Lines + $r.Err) -join ' | ')'"
$r = Invoke-Installer 'uninstall beside a foreign rollback name' @('-Uninstall', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'foreign rollback: the uninstall is clean'
Confirm-True (Test-Path -LiteralPath $installedRollback) 'foreign rollback: an uninstall does not delete it'
Confirm-Equal (Get-Content -LiteralPath $installedRollback -Raw).Trim() $foreignRollbackText 'foreign rollback: its content is untouched throughout'
Confirm-True ((($r.Lines + $r.Err) -join ' ') -match "Kept:.+rollback.+marker line") "foreign rollback: the uninstall says it was left alone, got '$(($r.Lines + $r.Err) -join ' | ')'"
Remove-Item -LiteralPath $installedRollback -Force

# The subagent script goes into place before settings.json is written, not after it. A move that cannot
# happen therefore leaves no subagentStatusLine key naming a file that is not on disk - which is what
# Claude Code would then launch on every panel tick. The destination is held open here with a share mode
# that forbids a replace, the same thing an antivirus scan or another reader does to a file, and
# File.Move fails on it; the ownership read and the rollback copy in front of it still succeed, so the
# run really does reach the move.
$r = Invoke-Installer 'install -Subagents before the failing move' @('-Subagents', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'move failure: the install that seeds the destination is clean'
Set-Content -LiteralPath $subSettings -Value '{ "theme": "dark" }' -Encoding utf8NoBOM
Remove-Item -LiteralPath "$subSettings.bak" -Force -ErrorAction SilentlyContinue
$movedBefore = Get-Content -LiteralPath $installedSub -Raw
$settingsBefore = Get-Content -LiteralPath $subSettings -Raw
$blocked = $null
try {
    $blocked = [System.IO.File]::Open($installedSub, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
} catch {
    $blocked = $null
}
Confirm-True ($null -ne $blocked) 'move failure: the test can hold the destination open against a replace'
if ($null -ne $blocked) {
    $r = Invoke-Installer 'install -Subagents while the move fails' @('-Subagents', '-SettingsPath', $subSettings)
    $blocked.Dispose()
    Confirm-True ($r.ExitCode -ne 0) "move failure: exit code $($r.ExitCode) is non-zero"
    Confirm-Equal (Get-Content -LiteralPath $subSettings -Raw) $settingsBefore 'move failure: settings.json is exactly what it was, so no key names a file that is not there'
    Confirm-True (-not (Test-Path -LiteralPath "$subSettings.bak")) 'move failure: settings.json was never rewritten, so there is no .bak from this run'
    Confirm-Equal (Get-Content -LiteralPath $installedSub -Raw) $movedBefore 'move failure: the destination still holds the version it held'
    Confirm-Equal (@(Get-ChildItem -LiteralPath (Join-Path $subHome '.claude') -Filter '*.tmp-*' -Force).Count) 0 'move failure: the staged copy is cleaned up'
    # And with the handle gone the same command goes through: the key and the file it names arrive together.
    $r = Invoke-Installer 'install -Subagents once the move can happen' @('-Subagents', '-SettingsPath', $subSettings)
    Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'move failure: the install goes through once the destination is free'
    $s = Read-SettingFile $subSettings
    Confirm-Equal $s.subagentStatusLine.command $expectSubCommand 'move failure: the key is written once the file is really in place'
    Confirm-True (Test-Path -LiteralPath $installedSub) 'move failure: and the file that key names is on disk'
}
$r = Invoke-Installer 'uninstall after the move failure case' @('-Uninstall', '-SettingsPath', $subSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'move failure: the uninstall that clears up after it is clean'
Remove-Item -LiteralPath $installedRollback -Force -ErrorAction SilentlyContinue

# A second installer holding the lock. The settings write waits for it, and when it cannot have the
# lock it writes nothing at all rather than racing the other one. This is the interprocess half of the
# conflict rule: the in-process case above proves the comparison, this proves the exclusion.
$lockHeld = $null
try {
    $lockHeld = [System.IO.File]::Open("$subSettings.lock", [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
    $lockHeld = $null
}
Confirm-True ($null -ne $lockHeld) 'settings lock: the test can take the lock the installer uses'
if ($null -ne $lockHeld) {
    $lockedBefore = Get-Content -LiteralPath $subSettings -Raw
    $r = Invoke-Installer 'install while the lock is held' @('-SettingsPath', $subSettings)
    Confirm-True ($r.ExitCode -ne 0) "settings lock: exit code $($r.ExitCode) is non-zero while another process holds it"
    Confirm-True ((($r.Lines + $r.Err) -join ' ') -match 'Could not lock') "settings lock: the message says it could not lock, got '$(($r.Lines + $r.Err) -join ' | ')'"
    Confirm-Equal (Get-Content -LiteralPath $subSettings -Raw) $lockedBefore 'settings lock: nothing was written while the lock was held'
    $lockHeld.Dispose()
    # And once it is free the same command goes through, so the lock is a wait and not a wall.
    $r = Invoke-Installer 'install once the lock is free' @('-SettingsPath', $subSettings)
    Confirm-True ($r.ExitCode -eq 0) "settings lock: exit code $($r.ExitCode) once the lock is released"
    Confirm-True ((Get-KeyList (Read-SettingFile $subSettings)).Contains('statusLine')) 'settings lock: the write goes through once the lock is free'
}

# A user profile with a space and with characters cmd treats as syntax. Unquoted, the command parser
# stops the -File argument at the first space and the status line never runs, so the path is quoted and
# the generated command is run through cmd here to prove it.
$spacedHome = Join-Path $subTmp 'home (a&b) c'
New-Item -ItemType Directory -Force $spacedHome | Out-Null
$spacedSettings = Join-Path $spacedHome 'settings.json'
Set-Content -LiteralPath $spacedSettings -Value '{ "theme": "dark" }' -Encoding utf8NoBOM
$env:USERPROFILE = $spacedHome
$r = Invoke-Installer 'install -Subagents into a spaced profile' @('-Subagents', '-SettingsPath', $spacedSettings)
Confirm-True ($r.ExitCode -eq 0) "spaced profile: exit code $($r.ExitCode)"
Confirm-True ($r.Err.Count -eq 0) "spaced profile: stderr empty, got '$($r.Err -join ' | ')'"
$s = Read-SettingFile $spacedSettings
$spacedMain = Join-Path $spacedHome '.claude\statusline.ps1'
$spacedSub = Join-Path $spacedHome '.claude\subagent-statusline.ps1'
Confirm-Equal $s.statusLine.command ('pwsh -NoProfile -NoLogo -NonInteractive -File "' + ($spacedMain -replace '\\', '/') + '"') 'spaced profile: the statusLine path is quoted'
Confirm-Equal $s.subagentStatusLine.command ('pwsh -NoProfile -NoLogo -NonInteractive -File "' + ($spacedSub -replace '\\', '/') + '"') 'spaced profile: the subagentStatusLine path is quoted'
Confirm-True ($s.statusLine.command.Contains(' c/.claude/')) 'spaced profile: the path really does carry a space'
Confirm-True ($s.statusLine.command.Contains('&')) 'spaced profile: the path really does carry an ampersand'
# Through cmd, which is what Claude Code hands the command to on Windows. The subagent line answers a
# payload, so its output is the proof; the main line prints a bar for the same reason.
if (Test-Path -LiteralPath $spacedSub) {
    $out = @('{ "tasks": [ { "id": "t1", "type": "local_bash", "status": "running" } ] }' | & cmd.exe /c $s.subagentStatusLine.command 2>&1)
    Confirm-True ($LASTEXITCODE -eq 0) "spaced profile: the subagent command runs through cmd, exit $LASTEXITCODE"
    Confirm-True ((@($out) -join '').Contains('"id":"t1"')) "spaced profile: the subagent command answers through cmd, got '$($out -join ' | ')'"
}
if (Test-Path -LiteralPath $spacedMain) {
    $out = @('{ "model": { "display_name": "Fable 5.1" } }' | & cmd.exe /c $s.statusLine.command 2>&1)
    Confirm-True ($LASTEXITCODE -eq 0) "spaced profile: the statusLine command runs through cmd, exit $LASTEXITCODE"
    Confirm-True ((ConvertTo-PlainText (@($out) -join '')).Contains('Fable 5.1')) "spaced profile: the statusLine command renders through cmd, got '$($out -join ' | ')'"
}
# Git Bash is the other shell Claude Code may use, and it is not always on PATH; skip rather than fail.
$shExe = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($shExe -and (Test-Path -LiteralPath $spacedSub)) {
    $out = @('{ "tasks": [ { "id": "t1", "type": "local_bash", "status": "running" } ] }' | & $shExe.Source -c $s.subagentStatusLine.command 2>&1)
    Confirm-True ((@($out) -join '').Contains('"id":"t1"')) "spaced profile: the subagent command answers through sh, got '$($out -join ' | ')'"
}
# The uninstall path has to survive the same profile: it is the one that deletes files.
$r = Invoke-Installer 'uninstall from a spaced profile' @('-Uninstall', '-SettingsPath', $spacedSettings)
Confirm-True ($r.ExitCode -eq 0 -and $r.Err.Count -eq 0) 'spaced profile: uninstall is clean'
Confirm-Equal (Get-KeyList (Read-SettingFile $spacedSettings)) 'theme' 'spaced profile: both entries removed, theme kept'
Confirm-True (-not (Test-Path -LiteralPath $spacedSub)) 'spaced profile: the subagent script is deleted'
$env:USERPROFILE = $subHome
} finally {
    $env:USERPROFILE = $subOldProfile
}
foreach ($n in $subRealNames) {
    $p = Join-Path $subRealDir $n
    Confirm-True ((Get-ContentHash $p) -eq $subRealHash[$n]) "subagent install: real $p untouched"
}
$subRealNamesAfter = @(Get-ChildItem -LiteralPath $subRealDir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
$subRealGone = @($subRealNamesBefore | Where-Object { $_ -notin $subRealNamesAfter })
Confirm-Equal ($subRealGone -join ',') '' "subagent install: nothing was deleted from the real $subRealDir"
} finally {
    Remove-Item -Recurse -Force $subTmp -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "passed $script:passed, failed $script:failed" -ForegroundColor $(if ($script:failed -gt 0) { 'Red' } else { 'Green' })
if ($script:failed -gt 0) { exit 1 }
