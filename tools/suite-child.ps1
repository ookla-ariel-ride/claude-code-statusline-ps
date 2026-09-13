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
    } finally {
        $recordWriter.Dispose()
    }
}

function Get-LockHolderMessage([string] $Path) {
    $record = Get-LockRecord $Path
    $holderPid = if ($null -ne $record) { $record.Pid } else { 0 }
    $log = if ($null -ne $record -and $record.Log) { $record.Log } else { '' }
    return "lock held by pid=$holderPid log=$log"
}

function Write-RefusalLog([string] $Path, [string] $Message) {
    try {
        $refusalWriter = [IO.StreamWriter]::new($Path, $false, [Text.UTF8Encoding]::new($false))
        try {
            $refusalWriter.WriteLine("child-error=$Message")
            $refusalWriter.WriteLine('alone=false')
            $refusalWriter.WriteLine('exit=3')
            $refusalWriter.Flush()
        } finally { $refusalWriter.Dispose() }
    } catch { Write-Verbose $_.Exception.Message }
}

function Stop-SuiteProcessTree {
    [CmdletBinding(SupportsShouldProcess)]
    param([int] $SuiteId)

    if ($SuiteId -le 0) { return }
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
        $tree = Get-ProcessDescendantPid $processes @($SuiteId)
        foreach ($id in @($tree | Sort-Object -Descending)) {
            if ($PSCmdlet.ShouldProcess("process $id", 'stop')) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        if ($PSCmdlet.ShouldProcess("process $SuiteId", 'stop')) { Stop-Process -Id $SuiteId -Force -ErrorAction SilentlyContinue }
    }
}

$lockStream = $null
$writer = $null
$suite = $null
try {
    try {
        $lockStream = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    } catch [IO.IOException] {
        $message = Get-LockHolderMessage $LockPath
        Write-RefusalLog $LogPath $message
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
            ('launch=pwsh -NoProfile -File "{0}"' -f $TestScript),
            "wrapper=$PID")) {
        $writer.WriteLine($line)
    }
    $writer.Flush()

    $pwshExe = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $startInfo = [Diagnostics.ProcessStartInfo]::new($pwshExe)
    foreach ($argument in @('-NoProfile', '-File', $TestScript)) { [void] $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $suite = [Diagnostics.Process]::Start($startInfo)
    Write-LockRecord $lockStream $PID $suite.Id $LogPath
    $writer.WriteLine("suite=$($suite.Id)")
    $writer.Flush()

    $launchConcurrent = if ($Concurrent -match '^(\d+)') { [int] $matches[1] } else { 0 }
    $sawConcurrent = $launchConcurrent -gt 0
    $lastProbe = [DateTime]::MinValue
    $stdoutTask = $suite.StandardOutput.ReadLineAsync()
    $stderrTask = $suite.StandardError.ReadLineAsync()
    $stdoutDone = $false
    $stderrDone = $false

    while (-not ($suite.HasExited -and $stdoutDone -and $stderrDone)) {
        [void] [Threading.Tasks.Task]::WaitAny(@($stdoutTask, $stderrTask), 1000)
        if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
            $line = $stdoutTask.GetAwaiter().GetResult()
            if ($null -eq $line) { $stdoutDone = $true }
            else {
                try { $writer.WriteLine($line); $writer.Flush() }
                catch { try { [IO.File]::AppendAllText($LogPath, "log-error=$($_.Exception.Message)`r`n", [Text.UTF8Encoding]::new($false)) } catch { Write-Verbose $_.Exception.Message } }
                $stdoutTask = $suite.StandardOutput.ReadLineAsync()
            }
        }
        if (-not $stderrDone -and $stderrTask.IsCompleted) {
            $line = $stderrTask.GetAwaiter().GetResult()
            if ($null -eq $line) { $stderrDone = $true }
            else {
                try { $writer.WriteLine($line); $writer.Flush() }
                catch { try { [IO.File]::AppendAllText($LogPath, "log-error=$($_.Exception.Message)`r`n", [Text.UTF8Encoding]::new($false)) } catch { Write-Verbose $_.Exception.Message } }
                $stderrTask = $suite.StandardError.ReadLineAsync()
            }
        }
        if (([DateTime]::UtcNow - $lastProbe).TotalSeconds -ge 60) {
            try {
                $foreign = @(Get-OtherSuitePid @($PID, $suite.Id))
                if ($foreign.Count -gt 0) {
                    $sawConcurrent = $true
                    try { $writer.WriteLine('concurrent-seen=' + ($foreign -join ',')); $writer.Flush() }
                    catch {
                        try { [IO.File]::AppendAllText($LogPath, "log-error=$($_.Exception.Message)`r`n", [Text.UTF8Encoding]::new($false)) } catch { Write-Verbose $_.Exception.Message }
                    }
                }
            } catch {
                try { $writer.WriteLine("probe-error=$($_.Exception.Message)"); $writer.Flush() }
                catch { try { [IO.File]::AppendAllText($LogPath, "probe-error=$($_.Exception.Message)`r`n", [Text.UTF8Encoding]::new($false)) } catch { Write-Verbose $_.Exception.Message } }
            }
            $lastProbe = [DateTime]::UtcNow
        }
    }
    $suite.WaitForExit()
    $writer.WriteLine('alone=' + (-not $sawConcurrent).ToString().ToLowerInvariant())
    $writer.WriteLine("exit=$($suite.ExitCode)")
    $writer.Flush()
    exit $suite.ExitCode
} catch {
    if ($null -ne $suite -and -not $suite.HasExited) { Stop-SuiteProcessTree $suite.Id }
    if ($null -ne $writer) {
        try {
            $writer.WriteLine("child-error=$($_.Exception.Message)")
            $writer.WriteLine('alone=false')
            $writer.WriteLine('exit=1')
            $writer.Flush()
        } catch { Write-Verbose $_.Exception.Message }
    } else {
        Write-RefusalLog $LogPath $_.Exception.Message
    }
    exit 1
} finally {
    if ($null -ne $writer) { $writer.Dispose() }
    if ($null -ne $lockStream) { $lockStream.Dispose() }
}
