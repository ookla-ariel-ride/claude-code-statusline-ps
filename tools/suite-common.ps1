#Requires -Version 7.0
Set-StrictMode -Version Latest

function Split-WindowsCommandLine([string] $CommandLine) {
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return @() }
    $tokens = [System.Collections.Generic.List[string]]::new()
    $token = [Text.StringBuilder]::new()
    $quoted = $false
    $started = $false
    $index = 0
    while ($index -lt $CommandLine.Length) {
        $character = $CommandLine[$index]
        if (-not $quoted -and [char]::IsWhiteSpace($character)) {
            if ($started) {
                [void] $tokens.Add($token.ToString())
                [void] $token.Clear()
                $started = $false
            }
            $index++
            continue
        }
        if ($character -eq '\') {
            $slashes = 0
            while ($index + $slashes -lt $CommandLine.Length -and $CommandLine[$index + $slashes] -eq '\') { $slashes++ }
            if ($index + $slashes -lt $CommandLine.Length -and $CommandLine[$index + $slashes] -eq '"') {
                [void] $token.Append(('\' * [math]::Floor($slashes / 2)))
                if (($slashes % 2) -eq 0) { $quoted = -not $quoted } else { [void] $token.Append('"') }
                $started = $true
                $index += $slashes + 1
                continue
            }
            [void] $token.Append(('\' * $slashes))
            $started = $true
            $index += $slashes
            continue
        }
        if ($character -eq '"') {
            $quoted = -not $quoted
            $started = $true
            $index++
            continue
        }
        [void] $token.Append($character)
        $started = $true
        $index++
    }
    if ($started) { [void] $tokens.Add($token.ToString()) }
    return @($tokens)
}

function Test-SuiteCommandLine([string] $CommandLine) {
    $tokens = @(Split-WindowsCommandLine $CommandLine)
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $option = $tokens[$index]
        if ($option -ieq '-Command' -or $option -ieq '-c' -or $option -ieq '-EncodedCommand') { return $false }
        if (($option -ieq '-File' -or $option -ieq '-f') -and $index -lt $tokens.Count - 1) {
            $target = $tokens[$index + 1]
            return $target -match '(?i)(?:^test\.ps1$|[\\/]test\.ps1$)'
        }
    }
    return $false
}

function Get-ProcessDescendantPid([object[]] $Processes, [int[]] $RootPids) {
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($rootPid in $RootPids) {
        if ($rootPid -gt 0) { [void] $ids.Add($rootPid) }
    }
    do {
        $added = $false
        foreach ($process in $Processes) {
            if ($ids.Contains([int] $process.ParentProcessId) -and $ids.Add([int] $process.ProcessId)) { $added = $true }
        }
    } while ($added)
    return ,$ids
}

function Get-OtherSuitePid([int[]] $ExcludedPids = @()) {
    $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    $excluded = Get-ProcessDescendantPid $processes $ExcludedPids
    return @($processes | Where-Object {
        (Test-SuiteCommandLine $_.CommandLine) -and -not $excluded.Contains([int] $_.ProcessId)
    } | ForEach-Object { [int] $_.ProcessId } | Sort-Object -Unique)
}

function Get-SuiteLockPath() {
    $commonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if (-not [string]::IsNullOrWhiteSpace($commonData)) {
        $directory = Join-Path $commonData 'statusline-suite'
        try {
            New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
            return (Join-Path $directory 'suite.lock')
        } catch { Write-Verbose "Could not create the common suite lock directory: $($_.Exception.Message)" }
    }
    $fallback = Join-Path ([IO.Path]::GetTempPath()) 'statusline-suite'
    New-Item -ItemType Directory -Path $fallback -Force -ErrorAction Stop | Out-Null
    return (Join-Path $fallback 'suite.lock')
}

function Get-LockRecord([string] $LockPath) {
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { return $null }
    try {
        $stream = [IO.File]::Open($LockPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true, 1024, $true)
            try { $lines = @($reader.ReadToEnd() -split "`r?`n") } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
        $values = @{}
        foreach ($line in $lines) {
            if ($line -match '^(pid|suite|log)=(.*)$') { $values[$matches[1]] = $matches[2] }
        }
        return @{ Pid = if ($values['pid'] -match '^\d+$') { [int] $values['pid'] } else { 0 }; Suite = if ($values['suite'] -match '^\d+$') { [int] $values['suite'] } else { 0 }; Log = $values['log'] }
    } catch [IO.IOException] { return $null }
}

function Test-SuiteLockHeld([string] $LockPath) {
    try {
        $stream = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        $stream.Dispose()
        return $false
    } catch [IO.IOException] { return $true }
}

function Get-SuiteCreationKey([object] $Process) {
    return ('{0}|{1:o}' -f [int] $Process.ProcessId, ([datetime] $Process.CreationDate).ToUniversalTime())
}

function Initialize-SuiteProcessTreeState([int] $SuiteId) {
    return @{ RootPid = $SuiteId; Seen = @{}; Snapshot = @() }
}

function Get-SuiteProcessTreeSnapshot([hashtable] $State) {
    $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    $byId = @{}
    foreach ($process in $processes) { $byId[[int] $process.ProcessId] = $process }
    $knownIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($entry in $State.Seen.Values) { [void] $knownIds.Add([int] $entry.ProcessId) }
    if ($State.Seen.Count -eq 0 -and $byId.ContainsKey($State.RootPid)) {
        $root = $byId[$State.RootPid]
        $State.Seen[([int] $root.ProcessId)] = @{ ProcessId = [int] $root.ProcessId; CreationKey = Get-SuiteCreationKey $root; Depth = 0 }
        [void] $knownIds.Add([int] $root.ProcessId)
    }
    do {
        $added = $false
        foreach ($process in $processes) {
            $processId = [int] $process.ProcessId
            if ($knownIds.Contains([int] $process.ParentProcessId) -and -not $State.Seen.ContainsKey($processId)) {
                $parent = $State.Seen[[int] $process.ParentProcessId]
                $State.Seen[$processId] = @{ ProcessId = $processId; CreationKey = Get-SuiteCreationKey $process; Depth = [int] $parent.Depth + 1 }
                [void] $knownIds.Add($processId)
                $added = $true
            }
        }
    } while ($added)
    $State.Snapshot = @($processes | Where-Object {
        $entry = $State.Seen[[int] $_.ProcessId]
        $null -ne $entry -and $entry.CreationKey -eq (Get-SuiteCreationKey $_)
    })
    return @($State.Snapshot)
}

function Stop-SuiteProcessTree {
    [OutputType([int[]])]
    [CmdletBinding(SupportsShouldProcess)]
    param([int] $SuiteId, [hashtable] $State)

    if ($SuiteId -le 0) { return [int[]] @() }
    if ($null -eq $State) { $State = Initialize-SuiteProcessTreeState $SuiteId }
    for ($round = 1; $round -le 3; $round++) {
        try { $live = @(Get-SuiteProcessTreeSnapshot $State) }
        catch {
            if ($PSCmdlet.ShouldProcess("process $SuiteId", 'stop after process snapshot failed')) { Stop-Process -Id $SuiteId -Force -ErrorAction SilentlyContinue }
            continue
        }
        if ($live.Count -eq 0) { return [int[]] @() }
        $depthByPid = @{}
        foreach ($entry in $State.Seen.Values) { $depthByPid[[int] $entry.ProcessId] = [int] $entry.Depth }
        foreach ($process in @($live | Sort-Object { $depthByPid[[int] $_.ProcessId] } -Descending)) {
            $processId = [int] $process.ProcessId
            if ($PSCmdlet.ShouldProcess("process $processId", 'stop suite process tree')) { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue }
        }
        foreach ($process in $live) {
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            do {
                Start-Sleep -Milliseconds 100
                try {
                    $current = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$([int] $process.ProcessId)" -ErrorAction Stop)
                    if ($current.Count -eq 0 -or (Get-SuiteCreationKey $current[0]) -ne (Get-SuiteCreationKey $process)) { break }
                } catch { break }
            } while ([DateTime]::UtcNow -lt $deadline)
        }
    }
    try { $remaining = @(Get-SuiteProcessTreeSnapshot $State) } catch { return [int[]] @($SuiteId) }
    return [int[]] @($remaining | ForEach-Object { [int] $_.ProcessId } | Sort-Object -Unique)
}
