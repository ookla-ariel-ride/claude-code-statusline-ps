#Requires -Version 7.0
Set-StrictMode -Version Latest

function Split-WindowsCommandLine([string] $CommandLine) {
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return @() }
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($CommandLine, '"(?:[^"\\]|\\.)*"|\S+')) {
        $token = $match.Value
        if ($token.Length -ge 2 -and $token[0] -eq '"' -and $token[$token.Length - 1] -eq '"') {
            $token = $token.Substring(1, $token.Length - 2) -replace '\\"', '"'
        }
        [void] $tokens.Add($token)
    }
    return @($tokens)
}

function Test-SuiteCommandLine([string] $CommandLine) {
    $tokens = @(Split-WindowsCommandLine $CommandLine)
    for ($index = 0; $index -lt $tokens.Count - 1; $index++) {
        if ($tokens[$index] -ieq '-File' -or $tokens[$index] -ieq '-f') {
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
            if ($ids.Contains([int] $process.ParentProcessId) -and $ids.Add([int] $process.ProcessId)) {
                $added = $true
            }
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
    return (Join-Path ([IO.Path]::GetTempPath()) 'statusline-suite.lock')
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
    } catch [IO.IOException] {
        return $null
    }
}

function Test-SuiteLockHeld([string] $LockPath) {
    try {
        $stream = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        $stream.Dispose()
        return $false
    } catch [IO.IOException] {
        return $true
    }
}
