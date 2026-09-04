#Requires -Version 7.0
<#
.SYNOPSIS
  Appends whatever Claude Code pipes on stdin to a bounded file, one payload per line.

.DESCRIPTION
  A capture stub for working out what a Claude Code integration point actually sends. Point a
  settings key at it, run a session, then read the file. It prints nothing on stdout, so a status line
  or subagent status line wired to it renders as if it were not there, and it never fails a run.

  The file is bounded, and so is one record. Claude Code ticks the subagent status line every five
  seconds while any row is alive, and a panel of large payloads fills a file quickly, so a capture
  command left in place would otherwise grow until the volume did. Stdin is read to a ceiling rather
  than to the end, so one enormous payload cannot be pulled into memory whole; the record is then cut
  to fit -MaxBytes on its own, with " ...[truncated]" marking where; and the file is rotated over a
  single sibling, <name>.1, when what is already there plus this record would go over. Each generation
  therefore stays at or under -MaxBytes and the whole capture at or under twice it. The oldest payloads
  are the ones lost, because the useful ones are the recent ones.

  The append is taken under an exclusive lock on <name>.lock, so two ticks cannot interleave a rotation
  with an append and leave a generation over the cap. A tick that cannot take the lock in time drops
  its payload rather than waiting: this is a capture stub, and a lost sample costs nothing.

  Failures are reported once rather than hidden. If a write fails, or a rotation cannot be made, the
  reason is written to <name>.error and to stderr, and later runs stop trying while that file is
  there. Nothing ever goes to stdout and the exit code is always 0, so a broken capture degrades to an
  empty panel row rather than an error in the session.

  To capture a subagent payload, add this to ~/.claude/settings.json and start a session that runs a
  few subagents:

      "subagentStatusLine": {
        "type": "command",
        "command": "pwsh -NoProfile -NoLogo -NonInteractive -File \"C:/path/to/tools/capture-stdin.ps1\""
      }

  Remove the key when you are done, and delete <name>.error to re-arm a capture that stopped.

.PARAMETER Path
  The file to append to. Defaults to claude-stdin-capture.jsonl in the temp directory.

.PARAMETER MaxBytes
  The cap on one record and on each of the two generations, so the capture and its one rotation hold
  at most twice this between them. Default 1 MiB. Must be 1024 or more.

.EXAMPLE
  Get-Content payload.json -Raw | pwsh -NoProfile -File .\tools\capture-stdin.ps1 -Path .\capture.jsonl

.EXAMPLE
  Get-Content payload.json -Raw | pwsh -NoProfile -File .\tools\capture-stdin.ps1 -MaxBytes 65536
#>
[CmdletBinding()]
param(
    [string] $Path,
    [ValidateRange(1024, [long]::MaxValue)] [long] $MaxBytes = 1048576
)
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Path) { $Path = Join-Path ([System.IO.Path]::GetTempPath()) 'claude-stdin-capture.jsonl' }
$errorPath = "$Path.error"
$rotatedPath = "$Path.1"

# One line on stderr and one sidecar file, written once and only once: every tick is a new process, so
# the sidecar's own existence is what makes this once rather than every five seconds. stderr and not
# stdout, because Claude Code parses this command's stdout and would log anything that is not JSON.
function Write-CaptureStop([string] $Reason) {
    [Console]::Error.WriteLine("capture-stdin: $Reason")
    if (-not (Test-Path -LiteralPath $errorPath)) {
        $stamp = [DateTimeOffset]::UtcNow.ToString('u', [System.Globalization.CultureInfo]::InvariantCulture)
        # Best effort: the sidecar is a courtesy, and if even it cannot be written there is nowhere
        # left to say so. The line on stderr above has already carried the reason.
        Set-Content -LiteralPath $errorPath -Value "$stamp $Reason" -Encoding utf8NoBOM -ErrorAction SilentlyContinue
    }
}

# Reads at most $MaxChars characters from stdin and stops, so a payload of any size costs a bounded
# amount of memory. What is left unread goes nowhere; this is a capture stub and the record is cut to
# the cap below in any case.
function Read-BoundedInput([int] $MaxChars) {
    $sb = [System.Text.StringBuilder]::new()
    $buf = [char[]]::new(8192)
    while ($sb.Length -lt $MaxChars) {
        $want = [Math]::Min($buf.Length, $MaxChars - $sb.Length)
        $n = [Console]::In.Read($buf, 0, $want)
        if ($n -le 0) { break }
        [void] $sb.Append($buf, 0, $n)
    }
    return $sb.ToString()
}

# One record, encoded, plus the line ending Add-Content writes, at or under $Cap. Cut by characters and
# measured in bytes each time rather than estimated, because a payload can hold any amount of non-ASCII
# and an estimate would be wrong in the direction that breaks the bound.
function Get-BoundedRecord([string] $Record, [long] $Cap) {
    $enc = [System.Text.Encoding]::UTF8
    $budget = $Cap - $enc.GetByteCount([Environment]::NewLine)
    if ($budget -lt 1) { return '' }
    if ($enc.GetByteCount($Record) -le $budget) { return $Record }
    $suffix = ' ...[truncated]'
    $room = $budget - $enc.GetByteCount($suffix)
    if ($room -lt 1) { $suffix = ''; $room = $budget }
    $take = [Math]::Min($Record.Length, [int] $room)
    while ($take -gt 0 -and $enc.GetByteCount($Record.Substring(0, $take)) -gt $room) { $take-- }
    return $Record.Substring(0, $take) + $suffix
}

# A capture that has already stopped stays stopped until the sidecar is deleted, so a full volume or a
# permission problem is not retried every five seconds for the rest of the session.
if (Test-Path -LiteralPath $errorPath) { exit 0 }

# The character ceiling is the byte cap: UTF-16 in memory makes that at most twice the cap in bytes,
# and the record is cut to the byte cap straight after.
$raw = Read-BoundedInput ([int] [Math]::Min($MaxBytes, [int]::MaxValue))
if (-not $raw) { exit 0 }

# One payload per line, so a pretty-printed payload does not spread over the file and a later reader
# can split on newlines.
$record = Get-BoundedRecord ($raw -replace '\r?\n', ' ') $MaxBytes
if (-not $record) { exit 0 }
$recordBytes = [System.Text.Encoding]::UTF8.GetByteCount($record) + [System.Text.Encoding]::UTF8.GetByteCount([Environment]::NewLine)

$lock = $null
try {
    # A short wait, then give up quietly: a dropped sample is not a failure worth a sidecar.
    $deadline = [DateTime]::UtcNow.AddMilliseconds(2000)
    while ($null -eq $lock) {
        try {
            $lock = [System.IO.File]::Open("$Path.lock", [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch {
            if ([DateTime]::UtcNow -ge $deadline) { exit 0 }
            Start-Sleep -Milliseconds 25
        }
    }
    # Rotate when this record would take the file over the cap, not when the file is already over it:
    # the size that matters is the one the file would end at. One generation only, so two files of at
    # most MaxBytes each is the whole footprint.
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.Length + $recordBytes) -gt $MaxBytes) {
        Move-Item -LiteralPath $Path -Destination $rotatedPath -Force -ErrorAction Stop
    }
    Add-Content -LiteralPath $Path -Value $record -Encoding utf8NoBOM -ErrorAction Stop
} catch {
    Write-CaptureStop "stopped capturing to $Path : $($_.Exception.Message). Delete $errorPath to try again."
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
exit 0
