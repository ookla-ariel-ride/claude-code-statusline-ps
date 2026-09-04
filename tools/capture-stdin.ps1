#Requires -Version 7.0
<#
.SYNOPSIS
  Appends whatever Claude Code pipes on stdin to a bounded file, one payload per line.

.DESCRIPTION
  A capture stub for working out what a Claude Code integration point actually sends. Point a
  settings key at it, run a session, then read the file. It prints nothing on stdout, so a status line
  or subagent status line wired to it renders as if it were not there, and it never fails a run.

  The file is bounded. Claude Code ticks the subagent status line every five seconds while any row is
  alive, and a panel of large payloads fills a file quickly, so a capture command left in place would
  otherwise grow until the volume did. When the file reaches -MaxBytes it is rotated over a single
  sibling, <name>.1, and a fresh one is started, which caps the whole capture at roughly twice
  -MaxBytes. The oldest payloads are the ones lost, because the useful ones are the recent ones.

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
  Rotate once the file reaches this size. Default 1 MiB, so the capture and its one rotation hold
  about 2 MiB between them. Must be 1024 or more.

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

# A capture that has already stopped stays stopped until the sidecar is deleted, so a full volume or a
# permission problem is not retried every five seconds for the rest of the session.
if (Test-Path -LiteralPath $errorPath) { exit 0 }

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }

try {
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    # Rotate before appending, not after, so the file never sits above the cap between runs. One
    # generation only: two files of at most MaxBytes each is the whole footprint.
    if ($null -ne $item -and $item.Length -ge $MaxBytes) {
        Move-Item -LiteralPath $Path -Destination $rotatedPath -Force -ErrorAction Stop
    }
    # One payload per line, so a pretty-printed payload does not spread over the file and a later
    # reader can split on newlines.
    Add-Content -LiteralPath $Path -Value ($raw -replace '\r?\n', ' ') -Encoding utf8NoBOM -ErrorAction Stop
} catch {
    Write-CaptureStop "stopped capturing to $Path : $($_.Exception.Message). Delete $errorPath to try again."
}
exit 0
