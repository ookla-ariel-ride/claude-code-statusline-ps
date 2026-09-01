<#
.SYNOPSIS
  Renders statusline.ps1 against every sample payload in ./samples and prints the result.
  Add -Raw to show ANSI escapes as <ESC> for inspection.
#>
[CmdletBinding()]
param([switch] $Raw)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script = Join-Path $PSScriptRoot 'statusline.ps1'
$failed = 0

foreach ($sample in Get-ChildItem (Join-Path $PSScriptRoot 'samples') -Filter *.json | Sort-Object Name) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = Get-Content $sample.FullName -Raw | pwsh -NoProfile -NoLogo -NonInteractive -File $script
    $sw.Stop()
    if ([string]::IsNullOrWhiteSpace($out)) { $failed++; Write-Host "FAIL $($sample.Name): empty output" -ForegroundColor Red; continue }
    $shown = if ($Raw) { $out -replace [char]27, '<ESC>' } else { $out }
    Write-Host ("{0,-28} {1,5:N0} ms  " -f $sample.Name, $sw.ElapsedMilliseconds) -NoNewline
    Write-Host $shown
}

if ($failed -gt 0) { exit 1 }
