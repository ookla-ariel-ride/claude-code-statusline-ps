#Requires -Version 7.0
<#
.SYNOPSIS
    Starts the full test suite in a detached PowerShell process.

.DESCRIPTION
    Refuses overlapping suites by default, starts test.ps1 in a child wrapper, and records a durable log.

.PARAMETER LockPath
    Test seam for an isolated lock file. Production callers use the machine-wide default.
#>
[CmdletBinding()]
param(
    [string] $TestScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'test.ps1'),
    [string] $LogDir = (Join-Path $env:TEMP 'statusline-suite'),
    [switch] $Wait,
    [ValidateRange(0, 1440)] [int] $TimeoutMinutes = 0,
    [ValidateRange(1, 3600)] [int] $PollSeconds = 60,
    [ValidateRange(1, 1440)] [int] $StallMinutes = 30,
    [string] $Attach,
    [switch] $Force,
    [switch] $DryRun,
    [scriptblock] $SuiteProbe,
    [string] $LockPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'suite-common.ps1')

function Get-RunnerOtherSuitePid {
    if ($null -ne $SuiteProbe) { return @(& $SuiteProbe | ForEach-Object { [int] $_ } | Sort-Object -Unique) }
    return @(Get-OtherSuitePid @($PID))
}

function Get-LogValue([string[]] $Lines, [string] $Name) {
    $line = @($Lines | Where-Object { $_ -match ('^{0}=(.*)$' -f [regex]::Escape($Name)) } | Select-Object -Last 1)
    if ($line.Count -eq 0) { return $null }
    return $line[0].Substring($Name.Length + 1)
}

function Test-ProcessAlive([int] $ProcessId) {
    return $ProcessId -gt 0 -and $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-SuiteStamp([string] $ResolvedTestScript, [string] $RepoRoot, [int[]] $ConcurrentPids, [string] $RunLockPath) {
    $sha = 'unknown'
    $dirty = 0
    if ($RepoRoot) {
        $sha = (& git -C $RepoRoot rev-parse --short HEAD).Trim()
        $dirty = @(& git -C $RepoRoot status --porcelain).Count
    }
    $freeMb = [math]::Floor((Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory / 1024)
    return [ordered]@{
        utc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        sha = $sha
        dirty = $dirty
        concurrent = ($ConcurrentPids.Count.ToString([Globalization.CultureInfo]::InvariantCulture) + ' pids=' + ($ConcurrentPids -join ','))
        freeMb = $freeMb.ToString([Globalization.CultureInfo]::InvariantCulture)
        lock = $RunLockPath
        launch = ('pwsh -NoProfile -File "{0}"' -f $ResolvedTestScript)
    }
}

function ConvertTo-StampLine([Collections.Specialized.OrderedDictionary] $Stamp) {
    return @($Stamp.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value })
}

function Write-LogTail([string] $LogPath) {
    if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
        try { @(Get-Content -LiteralPath $LogPath -Tail 20 -ErrorAction Stop) | Write-Output } catch { Write-Verbose $_.Exception.Message }
    }
}

function Wait-SuiteLog([string] $LogPath, [int] $PollIntervalSeconds, [int] $MaximumStallMinutes, [int] $MaximumWaitMinutes) {
    $started = [DateTime]::UtcNow
    $lastWrite = $started
    $seenLog = $false
    $wrapperPid = 0
    while ($true) {
        try {
            $item = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
            if ($null -ne $item) {
                if (-not $seenLog -or $item.LastWriteTimeUtc -gt $lastWrite) { $lastWrite = $item.LastWriteTimeUtc; $seenLog = $true }
                $lines = @(Get-Content -LiteralPath $LogPath -ErrorAction Stop)
                $wrapperText = Get-LogValue $lines 'wrapper'
                if ($wrapperText -match '^\d+$') { $wrapperPid = [int] $wrapperText }
                $exitText = Get-LogValue $lines 'exit'
                if ($exitText -match '^-?\d+$') {
                    $passedLine = @($lines | Where-Object { $_ -match 'passed \d+, failed \d+' } | Select-Object -Last 1)
                    if ($passedLine.Count -gt 0) { Write-Output $passedLine[0] }
                    Write-Output "exit=$exitText"
                    $aloneText = Get-LogValue $lines 'alone'
                    if ($null -eq $aloneText) { $aloneText = if (@($lines | Where-Object { $_ -match '^concurrent-seen=' }).Count -gt 0) { 'false' } else { 'true' } }
                    Write-Output "alone=$aloneText"
                    $script:waitExitCode = [int] $exitText
                    return
                }
            }
        } catch { Write-Verbose $_.Exception.Message }
        if ($wrapperPid -gt 0 -and -not (Test-ProcessAlive $wrapperPid)) {
            Write-Output "suite wrapper died before writing exit=: $LogPath"
            $script:waitExitCode = 5
            return
        }
        $elapsed = ([DateTime]::UtcNow - $started).TotalSeconds
        $remaining = if ($MaximumWaitMinutes -gt 0) { ($MaximumWaitMinutes * 60) - $elapsed } else { [double]::PositiveInfinity }
        if ($remaining -le 0) {
            Write-Output "still-running log=$LogPath"
            $script:waitExitCode = 6
            return
        }
        if (([DateTime]::UtcNow - $lastWrite).TotalMinutes -ge $MaximumStallMinutes) {
            Write-Output "suite log stalled for $MaximumStallMinutes minute(s): $LogPath"
            $script:waitExitCode = 4
            return
        }
        $sleepMilliseconds = if ($MaximumWaitMinutes -gt 0) {
            [int] ([math]::Min($PollIntervalSeconds * 1000, [math]::Max(1, [math]::Floor($remaining * 1000))))
        } else { $PollIntervalSeconds * 1000 }
        Start-Sleep -Milliseconds $sleepMilliseconds
    }
}

function Stop-UnacknowledgedSuiteChild {
    [CmdletBinding(SupportsShouldProcess)]
    param([Diagnostics.Process] $Process, [hashtable] $TreeState)
    $unresolved = @()
    if ($PSCmdlet.ShouldProcess("process $($Process.Id)", 'terminate unacknowledged suite child')) {
        $unresolved = @(Stop-SuiteProcessTree $Process.Id $TreeState)
    }
    if ($unresolved.Count -gt 0) { Write-Output ('cleanup-failed=' + ($unresolved -join ',')) }
}

if ($PSBoundParameters.ContainsKey('Attach')) {
    if ([string]::IsNullOrWhiteSpace($Attach)) {
        Write-Output 'suite log path must not be empty'
        exit 2
    }
    if (-not (Test-Path -LiteralPath $Attach -PathType Leaf)) {
        Write-Output "suite log does not exist: $Attach"
        exit 2
    }
    $script:waitExitCode = 1
    Wait-SuiteLog (Resolve-Path -LiteralPath $Attach) $PollSeconds $StallMinutes $TimeoutMinutes
    exit $script:waitExitCode
}

if (-not (Test-Path -LiteralPath $TestScript -PathType Leaf)) {
    Write-Output "test script does not exist: $TestScript"
    exit 2
}
$resolvedTestScript = (Resolve-Path -LiteralPath $TestScript).Path
$testDirectory = Split-Path -Parent $resolvedTestScript
$repoRootResult = @(& git -C $testDirectory rev-parse --show-toplevel 2>$null)
$repoRoot = if ($LASTEXITCODE -eq 0 -and $repoRootResult.Count -gt 0) { $repoRootResult[0].Trim() } else { '' }
$concurrentPids = @(Get-RunnerOtherSuitePid)
$lockPath = if ($PSBoundParameters.ContainsKey('LockPath')) { $LockPath } else { Get-SuiteLockPath }
$lockHeld = Test-SuiteLockHeld $lockPath
$lockRecord = if ($lockHeld) { Get-LockRecord $lockPath } else { $null }
if (($concurrentPids.Count -gt 0 -or $lockHeld) -and -not $Force) {
    if ($lockHeld) {
        $ownerPid = if ($null -ne $lockRecord) { $lockRecord.Pid } else { 0 }
        $ownerLog = if ($null -ne $lockRecord) { $lockRecord.Log } else { '' }
        Write-Output "refusing to start beside suite PID $ownerPid log=$ownerLog"
    } else { Write-Output ('refusing to start beside suite PID(s): ' + ($concurrentPids -join ', ')) }
    exit 3
}
$stamp = Get-SuiteStamp $resolvedTestScript $repoRoot $concurrentPids $lockPath
$stampLines = ConvertTo-StampLine $stamp
if ($DryRun) { $stampLines | Write-Output; exit 0 }

$resolvedLogDir = [IO.Path]::GetFullPath($LogDir)
New-Item -ItemType Directory -Path $resolvedLogDir -Force | Out-Null
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
$randomHex = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(4)).ToLowerInvariant()
$logPath = Join-Path $resolvedLogDir "suite-$timestamp-$randomHex.log"
$pwshExe = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$childScript = Join-Path $PSScriptRoot 'suite-child.ps1'
try {
    $childArguments = @('-NoProfile', '-File', $childScript, '-TestScript', $resolvedTestScript, '-LogPath', $logPath, '-LockPath', $lockPath, '-Utc', $stamp.utc, '-Sha', $stamp.sha, '-Dirty', $stamp.dirty, '-Concurrent', $stamp.concurrent, '-FreeMb', $stamp.freeMb) | ForEach-Object {
        if ($_ -match '[\s"]') { '"{0}"' -f ($_ -replace '"', '\\"') } else { $_ }
    }
    $process = Start-Process -FilePath $pwshExe -ArgumentList ($childArguments -join ' ') -WindowStyle Hidden -PassThru
    $treeState = Initialize-SuiteProcessTreeState $process.Id
} catch {
    Write-Output "could not launch suite child: $($_.Exception.Message)"
    exit 2
}
$deadline = [DateTime]::UtcNow.AddSeconds(10)
$acknowledged = $false
while ([DateTime]::UtcNow -lt $deadline) {
    try { $null = Get-SuiteProcessTreeSnapshot $treeState } catch { Write-Verbose $_.Exception.Message }
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        try {
            if (@(Get-Content -LiteralPath $logPath -ErrorAction Stop | Where-Object { $_ -match '^wrapper=\d+$' }).Count -gt 0) { $acknowledged = $true; break }
        } catch { Write-Verbose $_.Exception.Message }
    }
    $process.Refresh()
    if ($process.HasExited) { break }
    Start-Sleep -Milliseconds 100
}
$process.Refresh()
if (-not $acknowledged) {
    Stop-UnacknowledgedSuiteChild $process $treeState
    if ($process.HasExited) {
        $lines = if (Test-Path -LiteralPath $logPath -PathType Leaf) { @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue) } else { @() }
        $childError = Get-LogValue $lines 'child-error'
        $childExit = Get-LogValue $lines 'exit'
        if ($process.ExitCode -eq 3 -and $childExit -eq '3' -and $childError -match '^lock held by pid=') {
            Write-Output $childError
            exit 3
        }
        Write-Output "child exited before acknowledgement exit=$($process.ExitCode)"
        Write-LogTail $logPath
    } else { Write-Output 'no acknowledgement' }
    exit 5
}
Write-Output "log=$logPath"
Write-Output "pid=$($process.Id)"
if ($Wait) {
    $script:waitExitCode = 1
    Wait-SuiteLog $logPath $PollSeconds $StallMinutes $TimeoutMinutes
    exit $script:waitExitCode
}
