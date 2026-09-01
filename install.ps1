<#
.SYNOPSIS
  Installs the PowerShell status line for Claude Code (Windows).

.DESCRIPTION
  Copies statusline.ps1 to ~/.claude/statusline.ps1 and adds a "statusLine" entry to the USER-level
  Claude Code settings (~/.claude/settings.json), preserving every other key. Optionally installs the
  JetBrainsMono Nerd Font via winget and sets it as Windows Terminal's default font so the glyphs render.

.PARAMETER InstallFont
  Install JetBrainsMono Nerd Font with winget (asks for elevation once).

.PARAMETER ConfigureWindowsTerminal
  Set Windows Terminal's default font face to "JetBrainsMono NF" (a backup of settings.json is kept).

.PARAMETER Uninstall
  Remove the statusLine entry from settings.json and delete ~/.claude/statusline.ps1.

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
$settingsPath = Join-Path $claudeDir 'settings.json'
$fontFace = 'JetBrainsMono NF'

function Read-Settings {
    if (Test-Path $settingsPath) { return (Get-Content $settingsPath -Raw | ConvertFrom-Json) }
    return [pscustomobject]@{}
}

function Write-Settings($obj) {
    Copy-Item $settingsPath "$settingsPath.bak" -Force -ErrorAction SilentlyContinue
    $obj | ConvertTo-Json -Depth 32 | Set-Content $settingsPath -Encoding UTF8
}

if ($Uninstall) {
    $s = Read-Settings
    if ($s.PSObject.Properties['statusLine']) { $s.PSObject.Properties.Remove('statusLine'); Write-Settings $s; Write-Host "Removed statusLine from $settingsPath" }
    if (Test-Path $target) { Remove-Item $target -Force; Write-Host "Deleted $target" }
    return
}

New-Item -ItemType Directory -Force $claudeDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'statusline.ps1') $target -Force
Write-Host "Installed $target"

# Forward slashes: Claude Code may run the command through Git Bash, which eats backslashes.
$command = "pwsh -NoProfile -NoLogo -NonInteractive -File " + ($target -replace '\\', '/')
$s = Read-Settings
$entry = [pscustomobject]@{ type = 'command'; command = $command; padding = 0 }
if ($s.PSObject.Properties['statusLine']) { $s.statusLine = $entry } else { $s | Add-Member -NotePropertyName statusLine -NotePropertyValue $entry }
Write-Settings $s
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
