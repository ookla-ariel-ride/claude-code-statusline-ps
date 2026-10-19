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
    # Test seam for simulating the lock open outcome without changing machine ACLs.
    [scriptblock] $LockStatusOpenFile,
    # Test seam for verifying a faulted stdout drain is terminal.
    [switch] $SimulateStdoutDrainFault,
    [ValidateRange(0, 10000)] [int] $AcknowledgementDelayMilliseconds = 0,
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) { throw 'LockPath must not be empty.' }
        if (-not [IO.Path]::IsPathFullyQualified($_)) { throw 'LockPath must be an absolute path.' }
        if ([IO.Path]::GetFileName($_) -ine 'suite.lock') { throw 'LockPath must name suite.lock.' }
        return $true
    })]
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
    $prefix = '##suite:' + $Name + '='
    $line = @($Lines | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } | Select-Object -Last 1)
    if ($line.Count -eq 0) { return $null }
    return $line[0].Substring($prefix.Length)
}

function Test-ProcessAlive([int] $ProcessId) {
    return $ProcessId -gt 0 -and $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-SuiteStamp([string] $ResolvedTestScript, [string] $RepoRoot, [int[]] $ConcurrentPids, [string] $RunLockPath) {
    $sha = 'unknown'
    $dirty = 'unknown'
    if ($RepoRoot) {
        try {
            $head = @(& git -C $RepoRoot rev-parse --short HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $head.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($head[0])) { $sha = $head[0].Trim() }
            $status = @(& git -C $RepoRoot status --porcelain)
            if ($LASTEXITCODE -eq 0) { $dirty = $status.Count }
        } catch { Write-Verbose "Could not stamp the git repository: $($_.Exception.Message)" }
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
                # The wrapper header is written once near the start of the log. Read the full log until
                # it is latched; tailing before that can permanently hide it behind verbose output.
                if ($wrapperPid -gt 0) { $lines = @(Get-Content -LiteralPath $LogPath -Tail 100 -ErrorAction Stop) }
                else { $lines = @(Get-Content -LiteralPath $LogPath -ErrorAction Stop) }
                $wrapperText = Get-LogValue $lines 'wrapper'
                if ($wrapperText -match '^\d+$') { $wrapperPid = [int] $wrapperText }
                $exitText = Get-LogValue $lines 'exit'
                if ($exitText -match '^-?\d+$') {
                    $passedLine = @($lines | Where-Object { $_ -match 'passed \d+, failed \d+' } | Select-Object -Last 1)
                    if ($passedLine.Count -gt 0) { Write-Output $passedLine[0] }
                    Write-Output "exit=$exitText"
                    $aloneText = Get-LogValue $lines 'alone'
                    if ($null -eq $aloneText) { $aloneText = 'false' }
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
$repoRootResult = @()
$repoRootExitCode = $null
try {
    $repoRootResult = @(& git -C $testDirectory rev-parse --show-toplevel 2>$null)
    $repoRootExitCode = $LASTEXITCODE
} catch { Write-Verbose "Could not find the git repository root: $($_.Exception.Message)" }
$repoRoot = if ($repoRootExitCode -eq 0 -and $repoRootResult.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($repoRootResult[0])) { $repoRootResult[0].Trim() } else { '' }
$concurrentPids = @(Get-RunnerOtherSuitePid)
try { $lockPath = if ($PSBoundParameters.ContainsKey('LockPath')) { $LockPath } else { Get-SuiteLockPath } }
catch {
    Write-Output "could not prepare machine-wide suite lock: $($_.Exception.Message)"
    exit 2
}
$lockStatus = Get-SuiteLockStatus $lockPath $LockStatusOpenFile
$lockHeld = $lockStatus.Held
$lockRecord = if ($lockHeld -or $lockStatus.AccessDenied) { Get-LockRecord $lockPath } else { $null }
if (($concurrentPids.Count -gt 0 -or $lockHeld -or $lockStatus.AccessDenied) -and -not $Force) {
    if ($lockStatus.AccessDenied) {
        $recordedPid = if ($null -ne $lockRecord) { $lockRecord.Pid } else { 0 }
        if ($recordedPid -gt 0 -and (Test-ProcessAlive $recordedPid)) { Write-Output "suite lock is not writable by this user; active suite PID $recordedPid" }
        else { Write-Output "suite lock is not writable by this user; recorded PID $recordedPid is not running" }
    } elseif ($lockHeld) {
        $ownerPid = if ($null -ne $lockRecord) { $lockRecord.Pid } else { 0 }
        $ownerLog = if ($null -ne $lockRecord) { $lockRecord.Log } else { '' }
        Write-Output "refusing to start beside suite PID $ownerPid log=$ownerLog"
    } else { Write-Output ('refusing to start beside suite PID(s): ' + ($concurrentPids -join ', ')) }
    exit 3
}
$stamp = Get-SuiteStamp $resolvedTestScript $repoRoot $concurrentPids $lockPath
$stampLines = ConvertTo-StampLine $stamp
if ($DryRun) { $stampLines | Write-Output; exit 0 }

$resolvedLogDir = if ([IO.Path]::IsPathFullyQualified($LogDir)) { $LogDir } else { [IO.Path]::GetFullPath($LogDir, $PWD.ProviderPath) }
New-Item -ItemType Directory -Path $resolvedLogDir -Force | Out-Null
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
$randomHex = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(4)).ToLowerInvariant()
$logPath = Join-Path $resolvedLogDir "suite-$timestamp-$randomHex.log"
$pwshExe = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$childScript = Join-Path $PSScriptRoot 'suite-child.ps1'
try {
    $childArguments = @('-NoProfile', '-File', $childScript, '-TestScript', $resolvedTestScript, '-LogPath', $logPath, '-LockPath', $lockPath, '-Utc', $stamp.utc, '-Sha', $stamp.sha, '-Dirty', $stamp.dirty, '-Concurrent', $stamp.concurrent, '-FreeMb', $stamp.freeMb)
    if ($SimulateStdoutDrainFault) { $childArguments += '-SimulateStdoutDrainFault' }
    $startInfo = [Diagnostics.ProcessStartInfo]::new($pwshExe)
    foreach ($argument in $childArguments) { [void] $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $process = [Diagnostics.Process]::Start($startInfo)
    $treeState = Initialize-SuiteProcessTreeState $process.Id
} catch {
    Write-Output "could not launch suite child: $($_.Exception.Message)"
    exit 2
}
$deadline = [DateTime]::UtcNow.AddSeconds(10)
$nextTreeSnapshot = [DateTime]::MinValue
$acknowledged = $false
while ([DateTime]::UtcNow -lt $deadline) {
    if ([DateTime]::UtcNow -ge $nextTreeSnapshot) {
        try { $null = Get-SuiteProcessTreeSnapshot $treeState } catch { Write-Verbose $_.Exception.Message }
        $nextTreeSnapshot = [DateTime]::UtcNow.AddSeconds(1)
    }
    if ($AcknowledgementDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $AcknowledgementDelayMilliseconds }
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        try {
            # Do not tail before the one-time wrapper header has been observed.
            if (@(Get-Content -LiteralPath $logPath -ErrorAction Stop | Where-Object { $_ -match '^##suite:wrapper=\d+$' }).Count -gt 0) { $acknowledged = $true; break }
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
        if ($process.ExitCode -eq 3 -and $childExit -eq '3' -and $childError -match '^lock (held|unavailable)') {
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
exit 0
