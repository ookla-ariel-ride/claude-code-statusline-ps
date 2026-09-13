#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TestScript,
    [Parameter(Mandatory)] [string] $LogPath,
    [Parameter(Mandatory)] [string] $LockPath,
    [Parameter(Mandatory)] [string] $Utc,
    [Parameter(Mandatory)] [string] $Sha,
    [Parameter(Mandatory)] [string] $Dirty,
    [Parameter(Mandatory)] [string] $Concurrent,
    [Parameter(Mandatory)] [string] $FreeMb
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-LockRecord([string] $Path, [int] $ProcessId, [string] $RunLogPath) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
        try {
            $writer.WriteLine("pid=$ProcessId")
            $writer.WriteLine("log=$RunLogPath")
        } finally {
            $writer.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-OtherSuitePid([int[]] $ExcludedPids) {
    $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    $ours = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($excludedPid in $ExcludedPids) {
        if ($excludedPid -gt 0) { [void] $ours.Add($excludedPid) }
    }
    foreach ($excludedPid in @($ExcludedPids | Where-Object { $_ -gt 0 })) {
        $cursor = $excludedPid
        while ($cursor -gt 0) {
            $current = $processes | Where-Object { [int] $_.ProcessId -eq $cursor } | Select-Object -First 1
            if ($null -eq $current -or -not $ours.Add([int] $current.ParentProcessId)) { break }
            $cursor = [int] $current.ParentProcessId
        }
    }
    do {
        $added = $false
        foreach ($process in $processes) {
            if ($ours.Contains([int] $process.ParentProcessId) -and $ours.Add([int] $process.ProcessId)) {
                $added = $true
            }
        }
    } while ($added)

    return @($processes | Where-Object {
        $_.Name -in @('pwsh.exe', 'powershell.exe') -and
        $_.CommandLine -match '(?i)-File\s+"?[^"\s]*[\\/]test\.ps1"?(\s|$)' -and
        -not $ours.Contains([int] $_.ProcessId)
    } | ForEach-Object { [int] $_.ProcessId } | Sort-Object -Unique)
}

$finalLogPath = $LogPath -replace '-pending\.log$', ('-{0}.log' -f $PID)
if ($finalLogPath -eq $LogPath) { $finalLogPath = "$LogPath.$PID" }
$writer = $null
try {
    Write-LockRecord $LockPath $PID $finalLogPath
    $writer = [System.IO.StreamWriter]::new($finalLogPath, $false, [System.Text.UTF8Encoding]::new($false))
    foreach ($line in @(
            "utc=$Utc",
            "sha=$Sha",
            "dirty=$Dirty",
            "concurrent=$Concurrent",
            "freeMb=$FreeMb",
            ('launch=pwsh -NoProfile -File "{0}"' -f $TestScript),
            "wrapper=$PID")) {
        $writer.WriteLine($line)
    }
    $writer.Flush()

    $pwshExe = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($pwshExe)
    foreach ($argument in @('-NoProfile', '-File', $TestScript)) { [void] $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $suite = [System.Diagnostics.Process]::Start($startInfo)
    $writer.WriteLine("suite=$($suite.Id)")
    $writer.Flush()
    $stdout = $suite.StandardOutput.ReadToEndAsync()
    $stderr = $suite.StandardError.ReadToEndAsync()
    $lastProbe = [DateTime]::UtcNow
    $sawConcurrent = $false

    while (-not $suite.HasExited) {
        $suite.WaitForExit(1000)
        if (([DateTime]::UtcNow - $lastProbe).TotalSeconds -ge 60) {
            $foreign = @(Get-OtherSuitePid @($PID, $suite.Id))
            if ($foreign.Count -gt 0) {
                $sawConcurrent = $true
                $writer.WriteLine('concurrent-seen=' + ($foreign -join ','))
                $writer.Flush()
            }
            $lastProbe = [DateTime]::UtcNow
        }
    }
    $suite.WaitForExit()
    $outText = $stdout.GetAwaiter().GetResult()
    $errText = $stderr.GetAwaiter().GetResult()
    if ($outText) { $writer.Write($outText) }
    if ($errText) { $writer.Write($errText) }
    $writer.WriteLine('alone=' + (-not $sawConcurrent).ToString().ToLowerInvariant())
    $writer.WriteLine("exit=$($suite.ExitCode)")
    $writer.Flush()
    exit $suite.ExitCode
} catch {
    if ($null -ne $writer) {
        $writer.WriteLine("child-error=$($_.Exception.Message)")
        $writer.WriteLine('alone=false')
        $writer.WriteLine('exit=1')
        $writer.Flush()
    }
    exit 1
} finally {
    if ($null -ne $writer) { $writer.Dispose() }
    $lockLines = if (Test-Path -LiteralPath $LockPath -PathType Leaf) { @(Get-Content -LiteralPath $LockPath -ErrorAction SilentlyContinue) } else { @() }
    if ($lockLines -contains "pid=$PID") { Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue }
}
