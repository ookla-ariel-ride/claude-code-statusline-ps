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
  out and the key is not written; a reinstall without the switch drops a previous value.

.PARAMETER SettingsPath
  The settings.json to edit. Defaults to ~/.claude/settings.json. This changes only which settings file
  is edited: the statusline.ps1 and statusline.json copies, and the delete on -Uninstall, still use
  ~/.claude. It exists for the test suite.

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
    [ValidateRange(1, [int]::MaxValue)] [int] $RefreshInterval,
    [string] $SettingsPath
)

$ErrorActionPreference = 'Stop'
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$target = Join-Path $claudeDir 'statusline.ps1'
$configTarget = Join-Path $claudeDir 'statusline.json'
# PowerShell variable names are case-insensitive, so $settingsPath below is the -SettingsPath parameter.
if (-not $SettingsPath) { $settingsPath = Join-Path $claudeDir 'settings.json' }
$fontFace = 'JetBrainsMono NF'

# -LiteralPath throughout: a settings path with [ or ] in it would otherwise read as missing, so its keys
# would be dropped and the write would fail.
function Read-UserSetting([string] $Path) {
    if (Test-Path -LiteralPath $Path) {
        $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        # An empty file parses to nothing, and a bare value or array has no properties to add to; either
        # would otherwise be written back as the literal text "null" or a broken document. The null check
        # comes first because an empty pipeline result passes -is [pscustomobject], and the full type name
        # is used because a bare string or number passes the short one.
        if ($null -ne $parsed -and $parsed -is [System.Management.Automation.PSCustomObject]) { return $parsed }
    }
    return [pscustomobject]@{}
}

function Write-UserSetting($obj, [string] $Path) {
    $dir = Split-Path $Path -Parent
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force -ErrorAction SilentlyContinue
    $obj | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $Path -Encoding UTF8
}

if ($Uninstall) {
    $s = Read-UserSetting $settingsPath
    if ($s.PSObject.Properties['statusLine']) {
        $keys = @($s.statusLine.PSObject.Properties.Name) -join ', '
        $s.PSObject.Properties.Remove('statusLine')
        Write-UserSetting $s $settingsPath
        Write-Host "Removed statusLine ($keys) from $settingsPath"
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force; Write-Host "Deleted $target" }
    if (Test-Path -LiteralPath $configTarget) { Write-Host "Kept $configTarget (delete it yourself if you no longer want it)" }
    # The status line writes one small JSON file per session outside ~/.claude, so say where they are.
    $stateDir = if ($env:TEMP) { Join-Path $env:TEMP 'claude-statusline-state' } else { Join-Path $HOME '.claude' 'statusline-state' }
    Write-Host "Session state files are in $stateDir (delete the folder yourself if you no longer want it)"
    return
}

New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'statusline.ps1') -Destination $target -Force
Write-Host "Installed $target"
if (Test-Path -LiteralPath $configTarget) {
    Write-Host "Kept existing $configTarget"
} else {
    $configSource = Join-Path $PSScriptRoot 'statusline.json'
    if (Test-Path -LiteralPath $configSource) {
        Copy-Item -LiteralPath $configSource -Destination $configTarget
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
$wantRefresh = $PSBoundParameters.ContainsKey('RefreshInterval')
if ($wantRefresh) { $entry | Add-Member -NotePropertyName refreshInterval -NotePropertyValue $RefreshInterval }
$old = $s.PSObject.Properties['statusLine']
if ($old -and -not $wantRefresh -and $old.Value.PSObject.Properties['refreshInterval']) {
    Write-Warning "The existing statusLine.refreshInterval of $($old.Value.refreshInterval) is dropped; pass -RefreshInterval $($old.Value.refreshInterval) to keep it."
}
if ($old) { $s.statusLine = $entry } else { $s | Add-Member -NotePropertyName statusLine -NotePropertyValue $entry }
Write-UserSetting $s $settingsPath
Write-Host "Configured statusLine in $settingsPath (hideVimModeIndicator on$(if ($wantRefresh) { ", refreshInterval $RefreshInterval s" }))"

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
