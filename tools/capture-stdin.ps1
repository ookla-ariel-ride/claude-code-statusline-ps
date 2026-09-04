#Requires -Version 7.0
<#
.SYNOPSIS
  Appends whatever Claude Code pipes on stdin to a file, one payload per line.

.DESCRIPTION
  A capture stub for working out what a Claude Code integration point actually sends. Point a
  settings key at it, run a session, then read the file. It prints nothing, so a status line or
  subagent status line wired to it renders as if it were not there, and it never fails a run: an
  unwritable path is swallowed rather than raised.

  To capture a subagent payload, add this to ~/.claude/settings.json and start a session that runs
  a few subagents:

      "subagentStatusLine": {
        "type": "command",
        "command": "pwsh -NoProfile -NoLogo -NonInteractive -File C:/path/to/tools/capture-stdin.ps1"
      }

  Claude Code sends a tick 300 ms after a change and every 5 s while any row is alive, so the file
  fills quickly. Remove the key when you are done.

.PARAMETER Path
  The file to append to. Defaults to claude-stdin-capture.jsonl in the temp directory.

.EXAMPLE
  Get-Content payload.json -Raw | pwsh -NoProfile -File .\tools\capture-stdin.ps1 -Path .\capture.jsonl
#>
[CmdletBinding()]
param(
    [string] $Path
)
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Path) { $Path = Join-Path ([System.IO.Path]::GetTempPath()) 'claude-stdin-capture.jsonl' }
$raw = [Console]::In.ReadToEnd()
# One payload per line, so a pretty-printed payload does not spread over the file and a later reader
# can split on newlines. The write is best-effort: a capture stub must never take a session down.
if ($raw) { Add-Content -LiteralPath $Path -Value ($raw -replace '\r?\n', ' ') -Encoding utf8NoBOM }
