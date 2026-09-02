#Requires -Version 7.0
<#
.SYNOPSIS
  Installs the PowerShell status line for Claude Code (Windows).

.DESCRIPTION
  Copies statusline.ps1 to ~/.claude/statusline.ps1, copies statusline.json there if none exists, and adds a "statusLine" entry to the USER-level
  Claude Code settings (~/.claude/settings.json), preserving every other key. Optionally installs the
  JetBrainsMono Nerd Font via winget and sets it as Windows Terminal's default font so the glyphs render.

.PARAMETER InstallFont
  Install JetBrainsMono Nerd Font with winget (asks for elevation once).

.PARAMETER ConfigureWindowsTerminal
  Set Windows Terminal's default font face to "JetBrainsMono NF" (a backup of settings.json is kept).

.PARAMETER Uninstall
  Remove the statusLine entry from settings.json and delete ~/.claude/statusline.ps1. ~/.claude/statusline.json is kept.

.EXAMPLE
  .\install.ps1 -InstallFont -ConfigureWindowsTerminal
#>
[CmdletBinding()]
param(
    [switch] $InstallFont,
    [switch] $ConfigureWindowsTerminal,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$target = Join-Path $claudeDir 'statusline.ps1'
$configTarget = Join-Path $claudeDir 'statusline.json'
$settingsPath = Join-Path $claudeDir 'settings.json'
$fontFace = 'JetBrainsMono NF'

function Read-UserSetting {
    if (Test-Path $settingsPath) { return (Get-Content $settingsPath -Raw | ConvertFrom-Json) }
    return [pscustomobject]@{}
}

function Write-UserSetting($obj) {
    Copy-Item $settingsPath "$settingsPath.bak" -Force -ErrorAction SilentlyContinue
    $obj | ConvertTo-Json -Depth 32 | Set-Content $settingsPath -Encoding UTF8
}

if ($Uninstall) {
    $s = Read-UserSetting
    if ($s.PSObject.Properties['statusLine']) { $s.PSObject.Properties.Remove('statusLine'); Write-UserSetting $s; Write-Host "Removed statusLine from $settingsPath" }
    if (Test-Path $target) { Remove-Item $target -Force; Write-Host "Deleted $target" }
    if (Test-Path $configTarget) { Write-Host "Kept $configTarget (delete it yourself if you no longer want it)" }
    return
}

New-Item -ItemType Directory -Force $claudeDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'statusline.ps1') $target -Force
Write-Host "Installed $target"
if (Test-Path $configTarget) {
    Write-Host "Kept existing $configTarget"
} else {
    $configSource = Join-Path $PSScriptRoot 'statusline.json'
    if (Test-Path $configSource) {
        Copy-Item $configSource $configTarget
        Write-Host "Installed $configTarget (edit it to change layout, style or segments)"
    } else {
        Write-Warning "statusline.json was not found beside the installer; the status line will use its built-in defaults."
    }
}

# Forward slashes: Claude Code may run the command through Git Bash, which eats backslashes.
$command = "pwsh -NoProfile -NoLogo -NonInteractive -File " + ($target -replace '\\', '/')
$s = Read-UserSetting
$entry = [pscustomobject]@{ type = 'command'; command = $command; padding = 0 }
if ($s.PSObject.Properties['statusLine']) { $s.statusLine = $entry } else { $s | Add-Member -NotePropertyName statusLine -NotePropertyValue $entry }
Write-UserSetting $s
Write-Host "Configured statusLine in $settingsPath"

if ($InstallFont) {
    Write-Host 'Installing JetBrainsMono Nerd Font (winget; expect an elevation prompt)...'
    winget install --id DEVCOM.JetBrainsMonoNerdFont --exact --accept-package-agreements --accept-source-agreements | Out-Host
}

if ($ConfigureWindowsTerminal) {
    $wt = Get-ChildItem "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal*\LocalState\settings.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $wt) { Write-Warning 'Windows Terminal settings.json not found; set the font manually.' }
    else {
        Copy-Item $wt.FullName "$($wt.FullName).bak-before-nerdfont" -Force
        $j = Get-Content $wt.FullName -Raw | ConvertFrom-Json
        if (-not $j.profiles.defaults) { $j.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{}) }
        if (-not $j.profiles.defaults.font) { $j.profiles.defaults | Add-Member -NotePropertyName font -NotePropertyValue ([pscustomobject]@{}) -Force }
        $j.profiles.defaults.font | Add-Member -NotePropertyName face -NotePropertyValue $fontFace -Force
        $j | ConvertTo-Json -Depth 32 | Set-Content $wt.FullName -Encoding UTF8
        Write-Host "Windows Terminal default font set to '$fontFace' (backup kept next to settings.json)"
    }
}

Write-Host ''
Write-Host 'Done. Claude Code picks the status line up on its next refresh or session start.'
Write-Host "If icons render as boxes, set your terminal font to '$fontFace' (or any Nerd Font)."
