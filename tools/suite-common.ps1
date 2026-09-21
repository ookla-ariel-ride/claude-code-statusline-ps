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

function Test-PowerShellParameterAbbreviation([string] $Option, [string] $CanonicalName) {
    return $Option.Length -ge 2 -and $CanonicalName.StartsWith($Option, [StringComparison]::OrdinalIgnoreCase)
}

function Test-SuiteCommandLine([string] $CommandLine) {
    $tokens = @(Split-WindowsCommandLine $CommandLine)
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $option = $tokens[$index]
        if ((Test-PowerShellParameterAbbreviation $option '-Command') -or (Test-PowerShellParameterAbbreviation $option '-EncodedCommand')) { return $false }
        if ((Test-PowerShellParameterAbbreviation $option '-File') -and $index -lt $tokens.Count - 1) {
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

function Get-OtherSuitePid([int[]] $ExcludedPids = @(), [scriptblock] $ProcessSource) {
    $processes = if ($null -ne $ProcessSource) { @(& $ProcessSource) } else { @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) }
    $excluded = Get-ProcessDescendantPid $processes $ExcludedPids
    return @($processes | Where-Object {
        (Test-SuiteCommandLine $_.CommandLine) -and -not $excluded.Contains([int] $_.ProcessId)
    } | ForEach-Object { [int] $_.ProcessId } | Sort-Object -Unique)
}

function Get-SuiteLockPath() {
    $commonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($commonData)) { throw 'The machine-wide suite lock directory is unavailable.' }
    $directory = Join-Path $commonData 'statusline-suite'
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    return (Join-Path $directory 'suite.lock')
}

function Open-SuiteLock([string] $LockPath, [scriptblock] $OpenFile) {
    if ($null -eq $OpenFile) {
        $OpenFile = { param([string] $Path) [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read) }
    }
    return @{ Stream = (& $OpenFile $LockPath); Path = $LockPath }
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
    catch [UnauthorizedAccessException] { return $null }
}

function Get-SuiteLockStatus([string] $LockPath, [scriptblock] $OpenFile) {
    if ([string]::IsNullOrWhiteSpace($LockPath) -or -not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { return @{ Held = $false; AccessDenied = $false } }
    if ($null -eq $OpenFile) {
        $OpenFile = { param([string] $Path) [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read) }
    }
    try {
        $stream = & $OpenFile $LockPath
        $stream.Dispose()
        return @{ Held = $false; AccessDenied = $false }
    } catch [IO.IOException] { return @{ Held = $true; AccessDenied = $false } }
    catch [UnauthorizedAccessException] { return @{ Held = $false; AccessDenied = $true } }
}

function Test-SuiteLockHeld([string] $LockPath, [scriptblock] $OpenFile) {
    return (Get-SuiteLockStatus $LockPath $OpenFile).Held
}

function Get-SuiteCreationKey([object] $Process) {
    if ($null -eq $Process -or $null -eq $Process.CreationDate) { return $null }
    try { return ('{0}|{1:o}' -f [int] $Process.ProcessId, ([datetime] $Process.CreationDate).ToUniversalTime()) }
    catch { return $null }
}

function Initialize-SuiteProcessTreeState([int] $SuiteId) {
    return @{ RootPid = $SuiteId; RootCreationKey = $null; Seen = @{}; Snapshot = @() }
}

function Get-SuiteProcessTreeSnapshot([hashtable] $State, [scriptblock] $ProcessSource) {
    $processes = if ($null -ne $ProcessSource) { @(& $ProcessSource) } else { @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) }
    $byId = @{}
    foreach ($process in $processes) { $byId[[int] $process.ProcessId] = $process }
    $validSeen = @{}
    foreach ($entry in $State.Seen.Values) {
        $processId = [int] $entry.ProcessId
        $current = $byId[$processId]
        if ($null -ne $current -and $entry.CreationKey -eq (Get-SuiteCreationKey $current)) {
            $validSeen[$processId] = $entry
        } elseif ($null -eq $current -and $entry.ParentProcessId -gt 0 -and $null -ne $State.Seen[$entry.ParentProcessId] -and $null -ne $byId[$entry.ParentProcessId] -and $State.Seen[$entry.ParentProcessId].CreationKey -eq (Get-SuiteCreationKey $byId[$entry.ParentProcessId]) -and @($processes | Where-Object { [int] $_.ParentProcessId -eq $processId }).Count -gt 0) {
            # Retain a dead intermediate only while its own tracked parent remains live; this permits
            # descendants it spawned after the prior snapshot without treating a dead root PID as an anchor.
            $validSeen[$processId] = $entry
        }
    }
    $State.Seen = $validSeen
    if ($null -eq $State.RootCreationKey -and $State.Seen.Count -eq 0 -and $byId.ContainsKey($State.RootPid)) {
        $root = $byId[$State.RootPid]
        $State.RootCreationKey = Get-SuiteCreationKey $root
        if ($null -ne $State.RootCreationKey) {
            $State.Seen[([int] $root.ProcessId)] = @{ ProcessId = [int] $root.ProcessId; ParentProcessId = 0; CreationKey = $State.RootCreationKey; Depth = 0 }
        }
    }
    $knownIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($entry in $State.Seen.Values) { [void] $knownIds.Add([int] $entry.ProcessId) }
    do {
        $added = $false
        foreach ($process in $processes) {
            $processId = [int] $process.ProcessId
            $parent = $State.Seen[[int] $process.ParentProcessId]
            if ($null -ne $parent -and $knownIds.Contains([int] $process.ParentProcessId) -and -not $State.Seen.ContainsKey($processId)) {
                $creationKey = Get-SuiteCreationKey $process
                if ($null -ne $creationKey) {
                    $State.Seen[$processId] = @{ ProcessId = $processId; ParentProcessId = [int] $process.ParentProcessId; CreationKey = $creationKey; Depth = [int] $parent.Depth + 1 }
                    [void] $knownIds.Add($processId)
                    $added = $true
                }
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
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        foreach ($process in $live) {
            if ([DateTime]::UtcNow -ge $deadline) { break }
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
