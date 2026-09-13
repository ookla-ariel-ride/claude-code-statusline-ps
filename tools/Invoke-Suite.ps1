#Requires -Version 7.0
<#
.SYNOPSIS
    Starts the full test suite in a detached PowerShell process.

.DESCRIPTION
    Refuses to overlap another test.ps1 suite by default, writes a stamp that identifies the run, and
    can wait on the stamped log after the calling shell is lost.
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
    [scriptblock] $SuiteProbe
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-OtherSuitePid {
    return @(& $SuiteProbe | ForEach-Object { [int] $_ } | Sort-Object -Unique)
}

function Get-LogValue([string[]] $Lines, [string] $Name) {
    $line = @($Lines | Where-Object { $_ -match ('^{0}=(.*)$' -f [regex]::Escape($Name)) } | Select-Object -Last 1)
    if ($line.Count -eq 0) { return $null }
    return $line[0].Substring($Name.Length + 1)
}

function Test-ProcessAlive([int] $ProcessId) {
    if ($ProcessId -le 0) { return $false }
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-SuiteStamp([string] $ResolvedTestScript, [string] $RepoRoot, [int[]] $ConcurrentPids) {
    $sha = (& git -C $RepoRoot rev-parse --short HEAD).Trim()
    $dirty = @(& git -C $RepoRoot status --porcelain).Count
    $freeMb = [math]::Floor((Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory / 1024)
    return [ordered]@{
        utc = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        sha = $sha
        dirty = $dirty
        concurrent = ($ConcurrentPids.Count.ToString([System.Globalization.CultureInfo]::InvariantCulture) + ' pids=' + ($ConcurrentPids -join ','))
        freeMb = $freeMb.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        launch = ('pwsh -NoProfile -File "{0}"' -f $ResolvedTestScript)
    }
}

function ConvertTo-StampLine([System.Collections.Specialized.OrderedDictionary] $Stamp) {
    return @($Stamp.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value })
}

function Get-LockRecord([string] $LockPath) {
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { return $null }
    try {
        $lines = @(Get-Content -LiteralPath $LockPath -ErrorAction Stop)
        $pidText = Get-LogValue $lines 'pid'
        $logPath = Get-LogValue $lines 'log'
        return @{ Pid = if ($pidText -match '^\d+$') { [int] $pidText } else { 0 }; Log = $logPath }
    } catch [System.IO.IOException] {
        return $null
    }
}

function Write-LockRecord([string] $LockPath, [int] $ProcessId, [string] $LogPath, [bool] $CreateNew = $false) {
    $mode = if ($CreateNew) { [System.IO.FileMode]::CreateNew } else { [System.IO.FileMode]::Create }
    $stream = [System.IO.File]::Open($LockPath, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
        try {
            $writer.WriteLine("pid=$ProcessId")
            $writer.WriteLine("log=$LogPath")
        } finally {
            $writer.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Enter-SuiteLock([string] $LockPath, [string] $IntendedLogPath) {
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            Write-LockRecord $LockPath $PID $IntendedLogPath $true
            return @{ Acquired = $true; Existing = $null }
        } catch [System.IO.IOException] {
            $existing = Get-LockRecord $LockPath
            if ($null -ne $existing -and (Test-ProcessAlive $existing.Pid)) {
                return @{ Acquired = $false; Existing = $existing }
            }
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        }
    }
    $existing = Get-LockRecord $LockPath
    return @{ Acquired = $false; Existing = $existing }
}

function Wait-SuiteLog([string] $LogPath, [int] $PollIntervalSeconds, [int] $MaximumStallMinutes, [int] $MaximumWaitMinutes) {
    $started = [DateTime]::UtcNow
    $lastWrite = $started
    $seenLog = $false
    $wrapperPid = 0

    while ($true) {
        $item = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            if (-not $seenLog) {
                $lastWrite = $item.LastWriteTimeUtc
                $seenLog = $true
            } elseif ($item.LastWriteTimeUtc -gt $lastWrite) {
                $lastWrite = $item.LastWriteTimeUtc
            }
            $lines = @(Get-Content -LiteralPath $LogPath)
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

        if ($wrapperPid -gt 0 -and -not (Test-ProcessAlive $wrapperPid)) {
            Write-Output "suite wrapper died before writing exit=: $LogPath"
            $script:waitExitCode = 5
            return
        }
        if ($MaximumWaitMinutes -gt 0 -and ([DateTime]::UtcNow - $started).TotalMinutes -ge $MaximumWaitMinutes) {
            Write-Output "still-running log=$LogPath"
            $script:waitExitCode = 6
            return
        }
        if (([DateTime]::UtcNow - $lastWrite).TotalMinutes -ge $MaximumStallMinutes) {
            Write-Output "suite log stalled for $MaximumStallMinutes minute(s): $LogPath"
            $script:waitExitCode = 4
            return
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

if ($null -eq $SuiteProbe) {
    $SuiteProbe = {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
        $ours = [System.Collections.Generic.HashSet[int]]::new()
        [void] $ours.Add($PID)
        $cursor = $PID
        while ($cursor -gt 0) {
            $current = $processes | Where-Object { [int] $_.ProcessId -eq $cursor } | Select-Object -First 1
            if ($null -eq $current -or -not $ours.Add([int] $current.ParentProcessId)) { break }
            $cursor = [int] $current.ParentProcessId
        }
        do {
            $added = $false
            foreach ($process in $processes) {
                if ($ours.Contains([int] $process.ParentProcessId) -and $ours.Add([int] $process.ProcessId)) {
                    $added = $true
                }
            }
        } while ($added)
        foreach ($process in $processes) {
            if ($process.Name -in @('pwsh.exe', 'powershell.exe') -and
                $process.CommandLine -match '(?i)-File\s+"?[^"\s]*[\\/]test\.ps1"?(\s|$)' -and
                -not $ours.Contains([int] $process.ProcessId)) {
                [int] $process.ProcessId
            }
        }
    }
}

if ($Attach) {
    if (-not (Test-Path -LiteralPath $Attach -PathType Leaf)) {
        Write-Output "suite log does not exist: $Attach"
        exit 2
    }
    $script:waitExitCode = 1
    Wait-SuiteLog (Resolve-Path -LiteralPath $Attach) $PollSeconds $StallMinutes 0
    exit $script:waitExitCode
}

if (-not (Test-Path -LiteralPath $TestScript -PathType Leaf)) {
    Write-Output "test script does not exist: $TestScript"
    exit 2
}

$resolvedTestScript = (Resolve-Path -LiteralPath $TestScript).Path
$testDirectory = Split-Path -Parent $resolvedTestScript
$repoRoot = (& git -C $testDirectory rev-parse --show-toplevel 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
    Write-Output "test script is not inside a git repository: $resolvedTestScript"
    exit 2
}
$concurrentPids = @(Get-OtherSuitePid)
if ($concurrentPids.Count -gt 0 -and -not $Force) {
    Write-Output ('refusing to start beside suite PID(s): ' + ($concurrentPids -join ', '))
    exit 3
}

$stamp = Get-SuiteStamp $resolvedTestScript $repoRoot $concurrentPids
$stampLines = ConvertTo-StampLine $stamp
if ($DryRun) {
    $stampLines | Write-Output
    exit 0
}

$resolvedLogDir = [System.IO.Path]::GetFullPath($LogDir)
New-Item -ItemType Directory -Path $resolvedLogDir -Force | Out-Null
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
$intendedLogPath = Join-Path $resolvedLogDir "suite-$timestamp-$($stamp.sha)-pending.log"
$lockPath = Join-Path $resolvedLogDir 'suite.lock'
if ($Force) { $lockPath = Join-Path $resolvedLogDir "suite.force-$PID.lock" }
$lock = Enter-SuiteLock $lockPath $intendedLogPath
if (-not $lock.Acquired) {
    $existingPid = if ($null -ne $lock.Existing) { $lock.Existing.Pid } else { 0 }
    $existingLog = if ($null -ne $lock.Existing) { $lock.Existing.Log } else { '' }
    Write-Output "refusing to start beside suite PID $existingPid log=$existingLog"
    exit 3
}

$pwshExe = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$childScript = Join-Path $PSScriptRoot 'suite-child.ps1'
try {
    $childArguments = @('-NoProfile', '-File', $childScript, '-TestScript', $resolvedTestScript, '-LogPath', $intendedLogPath, '-LockPath', $lockPath, '-Utc', $stamp.utc, '-Sha', $stamp.sha, '-Dirty', $stamp.dirty, '-Concurrent', $stamp.concurrent, '-FreeMb', $stamp.freeMb) | ForEach-Object {
        if ($_ -match '[\s"]') { '"{0}"' -f $_ } else { $_ }
    }
    $process = Start-Process -FilePath $pwshExe -ArgumentList ($childArguments -join ' ') -WindowStyle Hidden -PassThru
} catch {
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    Write-Output "could not launch suite child: $($_.Exception.Message)"
    exit 2
}

$deadline = [DateTime]::UtcNow.AddSeconds(10)
$logPath = $intendedLogPath
while ([DateTime]::UtcNow -lt $deadline) {
    $record = Get-LockRecord $lockPath
    if ($null -ne $record -and $record.Pid -eq $process.Id -and $record.Log) {
        $logPath = $record.Log
        break
    }
    if ($process.HasExited) { break }
    Start-Sleep -Milliseconds 100
}

Write-Output "log=$logPath"
Write-Output "pid=$($process.Id)"
if ($Wait) {
    $script:waitExitCode = 1
    Wait-SuiteLog $logPath $PollSeconds $StallMinutes $TimeoutMinutes
    exit $script:waitExitCode
}
