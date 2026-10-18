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
    [Parameter(Mandatory)] [string] $FreeMb,
    # Test seam; omitted by Invoke-Suite in production.
    [switch] $SimulateLockAccessDenied,
    # Test seam; omitted by Invoke-Suite in production.
    [switch] $SimulateStdoutDrainFault
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'suite-common.ps1')

function Write-LockRecord([IO.FileStream] $Stream, [int] $ProcessId, [int] $SuiteId, [string] $RunLogPath) {
    $Stream.SetLength(0)
    $Stream.Position = 0
    $recordWriter = [IO.StreamWriter]::new($Stream, [Text.UTF8Encoding]::new($false), 1024, $true)
    try {
        $recordWriter.WriteLine("pid=$ProcessId")
        $recordWriter.WriteLine("suite=$SuiteId")
        $recordWriter.WriteLine("log=$RunLogPath")
        $recordWriter.Flush()
        $Stream.Flush($true)
    } finally { $recordWriter.Dispose() }
}

function Get-LockHolderMessage([string] $Path) {
    $record = Get-LockRecord $Path
    if ($null -eq $record -or $record.Pid -le 0) { return $null }
    return "lock held by pid=$($record.Pid) log=$($record.Log)"
}

function Test-LockSharingViolation([IO.IOException] $Exception) {
    $code = ([int] $Exception.HResult) -band 0xFFFF
    return $code -eq 0x20 -or $code -eq 0x21
}

function Write-RefusalLog([string] $Path, [string] $Message, [int] $ExitCode = 3) {
    try {
        $refusalWriter = [IO.StreamWriter]::new($Path, $false, [Text.UTF8Encoding]::new($false))
        try {
            $refusalWriter.WriteLine("##suite:child-error=$Message")
            $refusalWriter.WriteLine('##suite:alone=false')
            $refusalWriter.WriteLine("##suite:exit=$ExitCode")
            $refusalWriter.Flush()
        } finally { $refusalWriter.Dispose() }
    } catch { Write-Verbose $_.Exception.Message }
}

function Write-SuiteLogLine([IO.StreamWriter] $Writer, [string] $Line, [string] $LogPath) {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $Writer.WriteLine($Line)
            $Writer.Flush()
            return $true
        } catch {
            if ($attempt -eq 2) {
                try { [IO.File]::AppendAllText($LogPath, ("log-error=$($_.Exception.Message)" + [Environment]::NewLine), [Text.UTF8Encoding]::new($false)) }
                catch { Write-Verbose $_.Exception.Message }
                return $false
            }
        }
    }
    return $false
}

function Close-SuiteStream([Diagnostics.Process] $Process) {
    try { $Process.StandardOutput.Dispose() } catch { Write-Verbose $_.Exception.Message }
    try { $Process.StandardError.Dispose() } catch { Write-Verbose $_.Exception.Message }
}

$lockStream = $null
$writer = $null
$suite = $null
$treeState = $null
try {
    try {
        if ($SimulateLockAccessDenied) { throw [UnauthorizedAccessException]::new('simulated lock access denied') }
        $openedLock = Open-SuiteLock $LockPath
        $lockStream = $openedLock.Stream
        $activeLockPath = $openedLock.Path
    } catch [IO.IOException] {
        if (-not (Test-LockSharingViolation $_.Exception)) { throw }
        $holder = Get-LockHolderMessage $LockPath
        $message = if ($null -ne $holder) { $holder } else { 'lock held but holder record is unavailable' }
        Write-RefusalLog $LogPath $message
        exit 3
    } catch [UnauthorizedAccessException] {
        Write-RefusalLog $LogPath 'lock unavailable: access denied'
        exit 3
    }
    Write-LockRecord $lockStream $PID 0 $LogPath

    $writer = [IO.StreamWriter]::new($LogPath, $false, [Text.UTF8Encoding]::new($false))
    foreach ($line in @(
            "utc=$Utc",
            "sha=$Sha",
            "dirty=$Dirty",
            "concurrent=$Concurrent",
            "freeMb=$FreeMb",
            "lock=$activeLockPath",
            ('launch=pwsh -NoProfile -File "{0}"' -f $TestScript),
            "##suite:wrapper=$PID")) {
        if (-not (Write-SuiteLogLine $writer $line $LogPath)) { throw 'suite log writer failed before launch' }
    }

    $pwshExe = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $startInfo = [Diagnostics.ProcessStartInfo]::new($pwshExe)
    foreach ($argument in @('-NoProfile', '-File', $TestScript)) { [void] $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $suite = [Diagnostics.Process]::Start($startInfo)
    $treeState = Initialize-SuiteProcessTreeState $suite.Id
    try { $null = Get-SuiteProcessTreeSnapshot $treeState } catch { Write-Verbose $_.Exception.Message }
    Write-LockRecord $lockStream $PID $suite.Id $LogPath
    if (-not (Write-SuiteLogLine $writer "suite=$($suite.Id)" $LogPath)) { throw 'suite log writer failed after launch' }

    $launchConcurrent = if ($Concurrent -match '^(\d+)') { [int] $matches[1] } else { 0 }
    $sawConcurrent = $launchConcurrent -gt 0
    $lastProbe = [DateTime]::MinValue
    $nextTreeSnapshot = [DateTime]::UtcNow.AddSeconds(15)
    $stdoutTask = $suite.StandardOutput.ReadLineAsync()
    $stderrTask = $suite.StandardError.ReadLineAsync()
    if ($SimulateStdoutDrainFault) {
        $stdoutFault = [Threading.Tasks.TaskCompletionSource[string]]::new()
        $stdoutFault.SetException([InvalidOperationException]::new('simulated stdout drain fault'))
        $stdoutTask = $stdoutFault.Task
    }
    $stdoutDone = $false
    $stderrDone = $false
    $drainDeadline = $null

    while (-not ($suite.HasExited -and $stdoutDone -and $stderrDone)) {
        $pending = [System.Collections.Generic.List[Threading.Tasks.Task]]::new()
        if (-not $stdoutDone) { [void] $pending.Add($stdoutTask) }
        if (-not $stderrDone) { [void] $pending.Add($stderrTask) }
        if ($suite.HasExited -and $pending.Count -gt 0 -and $null -eq $drainDeadline) { $drainDeadline = [DateTime]::UtcNow.AddSeconds(30) }
        if ($pending.Count -gt 0) {
            $waitMilliseconds = 1000
            if ($null -ne $drainDeadline) {
                $waitMilliseconds = [int] [math]::Max(1, [math]::Min(1000, [math]::Floor(($drainDeadline - [DateTime]::UtcNow).TotalMilliseconds)))
            }
            if ($waitMilliseconds -gt 0) { [void] [Threading.Tasks.Task]::WaitAny($pending.ToArray(), $waitMilliseconds) }
        } else {
            [void] $suite.WaitForExit(1000)
        }
        if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
            if ($stdoutTask.IsFaulted) {
                $null = Write-SuiteLogLine $writer 'log-error=stdout-drain-fault' $LogPath
                Close-SuiteStream $suite
                throw 'suite stdout log drain faulted'
            } else {
                $line = $stdoutTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $stdoutDone = $true }
                elseif (-not (Write-SuiteLogLine $writer $line $LogPath)) { throw 'suite log writer failed while streaming stdout' }
                else { $stdoutTask = $suite.StandardOutput.ReadLineAsync() }
            }
        }
        if (-not $stderrDone -and $stderrTask.IsCompleted) {
            if ($stderrTask.IsFaulted) {
                $null = Write-SuiteLogLine $writer 'log-error=stderr-drain-fault' $LogPath
                Close-SuiteStream $suite
                throw 'suite stderr log drain faulted'
            } else {
                $line = $stderrTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $stderrDone = $true }
                elseif (-not (Write-SuiteLogLine $writer $line $LogPath)) { throw 'suite log writer failed while streaming stderr' }
                else { $stderrTask = $suite.StandardError.ReadLineAsync() }
            }
        }
        if ($null -ne $drainDeadline -and [DateTime]::UtcNow -ge $drainDeadline -and (-not $stdoutDone -or -not $stderrDone)) {
            $null = Write-SuiteLogLine $writer 'log-error=drain-timeout' $LogPath
            Close-SuiteStream $suite
            throw 'suite log drain timed out'
        }
        if ([DateTime]::UtcNow -ge $nextTreeSnapshot -or $suite.HasExited) {
            try { $null = Get-SuiteProcessTreeSnapshot $treeState } catch { Write-Verbose $_.Exception.Message }
            $nextTreeSnapshot = [DateTime]::UtcNow.AddSeconds(15)
        }
        if (([DateTime]::UtcNow - $lastProbe).TotalSeconds -ge 60) {
            try {
                $foreign = @(Get-OtherSuitePid @($PID, $suite.Id))
                if ($foreign.Count -gt 0) {
                    $sawConcurrent = $true
                    if (-not (Write-SuiteLogLine $writer ('concurrent-seen=' + ($foreign -join ',')) $LogPath)) { throw 'suite log writer failed while recording concurrent process' }
                }
            } catch {
                if (-not (Write-SuiteLogLine $writer "probe-error=$($_.Exception.Message)" $LogPath)) { throw 'suite log writer failed while recording probe error' }
            }
            $lastProbe = [DateTime]::UtcNow
        }
    }
    $suite.WaitForExit()
    if (-not (Write-SuiteLogLine $writer ('##suite:alone=' + (-not $sawConcurrent).ToString().ToLowerInvariant()) $LogPath)) { throw 'suite log writer failed at completion' }
    if (-not (Write-SuiteLogLine $writer "##suite:exit=$($suite.ExitCode)" $LogPath)) { throw 'suite log writer failed at completion' }
    exit $suite.ExitCode
} catch {
    $cleanupFailed = @()
    if ($null -ne $suite) { $cleanupFailed = @(Stop-SuiteProcessTree $suite.Id $treeState) }
    if ($null -ne $writer) {
        if ($cleanupFailed.Count -gt 0) { $null = Write-SuiteLogLine $writer ('cleanup-failed=' + ($cleanupFailed -join ',')) $LogPath }
        $null = Write-SuiteLogLine $writer "##suite:child-error=$($_.Exception.Message)" $LogPath
        $null = Write-SuiteLogLine $writer '##suite:alone=false' $LogPath
        $null = Write-SuiteLogLine $writer '##suite:exit=1' $LogPath
    } else {
        Write-RefusalLog $LogPath $_.Exception.Message 1
    }
    exit 1
} finally {
    if ($null -ne $suite) { Close-SuiteStream $suite }
    if ($null -ne $writer) { $writer.Dispose() }
    if ($null -ne $lockStream) { $lockStream.Dispose() }
}
