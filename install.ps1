#Requires -Version 7.0
<#
.SYNOPSIS
  Installs the PowerShell status line for Claude Code (Windows).

.DESCRIPTION
  Copies statusline.ps1 to ~/.claude/statusline.ps1, copies statusline.json there if none exists, and adds a "statusLine" entry to the USER-level
  Claude Code settings (~/.claude/settings.json), preserving every other key. The entry always sets
  hideVimModeIndicator, because the status line draws its own vim badge, and sets refreshInterval when
  -RefreshInterval is given. Optionally installs the JetBrainsMono Nerd Font via winget and sets it as
  Windows Terminal's default font so the glyphs render.

.PARAMETER InstallFont
  Install JetBrainsMono Nerd Font with winget (asks for elevation once).

.PARAMETER ConfigureWindowsTerminal
  Set Windows Terminal's default font face to "JetBrainsMono NF" (a backup of settings.json is kept).

.PARAMETER Uninstall
  Remove the statusLine entry from settings.json and delete ~/.claude/statusline.ps1. ~/.claude/statusline.json is kept.

.PARAMETER RefreshInterval
  Seconds between timed re-renders, written as statusLine.refreshInterval. Must be 1 or more. Leave it
  out and the key is not written, so Claude Code keeps its own behaviour.

.PARAMETER SettingsPath
  The settings.json to edit. Defaults to ~/.claude/settings.json. The tests point this into a temp folder.

.EXAMPLE
  .\install.ps1 -InstallFont -ConfigureWindowsTerminal

.EXAMPLE
  .\install.ps1 -RefreshInterval 10
#>
[CmdletBinding()]
param(
    [switch] $InstallFont,
    [switch] $ConfigureWindowsTerminal,
    [switch] $Uninstall,
    [int] $RefreshInterval,
    [string] $SettingsPath
)

$ErrorActionPreference = 'Stop'
if ($PSBoundParameters.ContainsKey('RefreshInterval') -and $RefreshInterval -lt 1) {
    Write-Error "-RefreshInterval must be 1 or more (got $RefreshInterval)."
    return
}
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$target = Join-Path $claudeDir 'statusline.ps1'
$configTarget = Join-Path $claudeDir 'statusline.json'
# PowerShell variable names are case-insensitive, so $settingsPath below is the -SettingsPath parameter.
if (-not $SettingsPath) { $settingsPath = Join-Path $claudeDir 'settings.json' }
$fontFace = 'JetBrainsMono NF'

function Read-UserSetting([string] $Path) {
    if (Test-Path $Path) { return (Get-Content $Path -Raw | ConvertFrom-Json) }
    return [pscustomobject]@{}
}

function Write-UserSetting($obj, [string] $Path) {
    $dir = Split-Path $Path -Parent
    if ($dir) { New-Item -ItemType Directory -Force $dir | Out-Null }
    Copy-Item $Path "$Path.bak" -Force -ErrorAction SilentlyContinue
    $obj | ConvertTo-Json -Depth 32 | Set-Content $Path -Encoding UTF8
}

if ($Uninstall) {
    $s = Read-UserSetting $settingsPath
    if ($s.PSObject.Properties['statusLine']) {
        $keys = @($s.statusLine.PSObject.Properties.Name) -join ', '
        $s.PSObject.Properties.Remove('statusLine')
        Write-UserSetting $s $settingsPath
        Write-Host "Removed statusLine ($keys) from $settingsPath"
    }
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
$s = Read-UserSetting $settingsPath
# hideVimModeIndicator is always on: the badges segment already shows vim.mode, so Claude Code's own
# indicator would be the same word twice on one bar. refreshInterval is written only when asked for, so
# a reinstall without the switch leaves the key out rather than picking a rate for the user.
$entry = [pscustomobject]@{ type = 'command'; command = $command; padding = 0; hideVimModeIndicator = $true }
if ($PSBoundParameters.ContainsKey('RefreshInterval')) { $entry | Add-Member -NotePropertyName refreshInterval -NotePropertyValue $RefreshInterval }
if ($s.PSObject.Properties['statusLine']) { $s.statusLine = $entry } else { $s | Add-Member -NotePropertyName statusLine -NotePropertyValue $entry }
Write-UserSetting $s $settingsPath
Write-Host "Configured statusLine in $settingsPath (hideVimModeIndicator on$(if ($PSBoundParameters.ContainsKey('RefreshInterval')) { ", refreshInterval $RefreshInterval s" }))"

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
