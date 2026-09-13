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
    [ValidateRange(1, 3600)] [int] $PollSeconds = 60,
    [ValidateRange(1, 1440)] [int] $StallMinutes = 30,
    [string] $Attach,
    [switch] $Force,
    [switch] $DryRun,
    [scriptblock] $SuiteProbe
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:childPid = $null

function Get-OtherSuitePid {
    return @(& $SuiteProbe | ForEach-Object { [int] $_ } | Sort-Object -Unique)
}

function Get-SuiteStamp([string] $ResolvedTestScript, [int[]] $ConcurrentPids) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $sha = (& git -C $repoRoot rev-parse --short HEAD).Trim()
    $dirty = @(& git -C $repoRoot status --porcelain).Count
    $freeMb = [math]::Floor((Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory / 1024)
    $innerCommand = "pwsh -NoProfile -File `"$ResolvedTestScript`""

    return @(
        ('utc=' + [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)),
        "sha=$sha",
        "dirty=$dirty",
        ('concurrent=' + $ConcurrentPids.Count + ' pids=' + ($ConcurrentPids -join ',')),
        "freeMb=$freeMb",
        "launch=$innerCommand"
    )
}

function Wait-SuiteLog([string] $LogPath, [bool] $SawConcurrentSuite, [int] $PollIntervalSeconds, [int] $MaximumStallMinutes) {
    $lastLength = -1L
    $lastGrowth = [DateTime]::UtcNow

    while ($true) {
        $pids = @(Get-OtherSuitePid)
        if ($pids.Count -gt 0) { $SawConcurrentSuite = $true }

        $item = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            if ($item.Length -ne $lastLength) {
                $lastLength = $item.Length
                $lastGrowth = [DateTime]::UtcNow
            }

            $lines = @(Get-Content -LiteralPath $LogPath)
            if ($lines.Count -gt 0 -and $lines[-1] -match '^exit=(-?\d+)$') {
                $exitCode = [int] $Matches[1]
                $passedLine = @($lines | Where-Object { $_ -match 'passed \d+, failed \d+' } | Select-Object -Last 1)
                if ($passedLine.Count -gt 0) { Write-Host $passedLine[0] }
                Write-Host $lines[-1]
                Write-Host ('alone=' + (-not $SawConcurrentSuite).ToString().ToLowerInvariant())
                return $exitCode
            }
        }

        if (([DateTime]::UtcNow - $lastGrowth).TotalMinutes -ge $MaximumStallMinutes) {
            [Console]::Error.WriteLine("suite log stalled for $MaximumStallMinutes minute(s): $LogPath")
            return 4
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

if ($null -eq $SuiteProbe) {
    $SuiteProbe = {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
        $ours = [System.Collections.Generic.HashSet[int]]::new()
        [void] $ours.Add($PID)
        if ($null -ne $script:childPid) { [void] $ours.Add($script:childPid) }

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
                $process.CommandLine -match '(?i)test\.ps1\b' -and
                -not $ours.Contains([int] $process.ProcessId)) {
                [int] $process.ProcessId
            }
        }
    }
}

if ($Attach) {
    if (-not (Test-Path -LiteralPath $Attach -PathType Leaf)) {
        [Console]::Error.WriteLine("suite log does not exist: $Attach")
        exit 2
    }

    $attachResult = Wait-SuiteLog (Resolve-Path -LiteralPath $Attach) $false $PollSeconds $StallMinutes
    exit $attachResult
}

if (-not (Test-Path -LiteralPath $TestScript -PathType Leaf)) {
    [Console]::Error.WriteLine("test script does not exist: $TestScript")
    exit 2
}

$resolvedTestScript = (Resolve-Path -LiteralPath $TestScript).Path
$concurrentPids = @(Get-OtherSuitePid)
if ($concurrentPids.Count -gt 0 -and -not $Force) {
    [Console]::Error.WriteLine('refusing to start beside suite PID(s): ' + ($concurrentPids -join ', '))
    exit 3
}

$stamp = Get-SuiteStamp $resolvedTestScript $concurrentPids
if ($DryRun) {
    $stamp | Write-Output
    exit 0
}

$resolvedLogDir = [System.IO.Path]::GetFullPath($LogDir)
New-Item -ItemType Directory -Path $resolvedLogDir -Force | Out-Null
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
$shortSha = ($stamp | Where-Object { $_ -like 'sha=*' } | Select-Object -First 1).Substring(4)
$logPath = Join-Path $resolvedLogDir "suite-$timestamp-$shortSha.log"

$stampCommands = @($stamp | ForEach-Object { "Write-Output '$($_.Replace("'", "''"))'" }) -join '; '
$pwshExe = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$quotedPwsh = $pwshExe.Replace("'", "''")
$quotedTestScript = $resolvedTestScript.Replace("'", "''")
$wrapperCommand = "$stampCommands; & '$quotedPwsh' -NoProfile -File '$quotedTestScript' *>&1; `$suiteExit = `$LASTEXITCODE; Write-Output ('exit=' + `$suiteExit); exit `$suiteExit"
$encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapperCommand))
$process = Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile', '-EncodedCommand', $encodedCommand) -WindowStyle Hidden -RedirectStandardOutput $logPath -PassThru
$script:childPid = $process.Id

Write-Output "log=$logPath"
Write-Output "pid=$($process.Id)"
if ($Wait) {
    $waitResult = Wait-SuiteLog $logPath ($concurrentPids.Count -gt 0) $PollSeconds $StallMinutes
    exit $waitResult
}
