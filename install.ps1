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

.PARAMETER Subagents
  Also install subagent-statusline.ps1 and add a "subagentStatusLine" entry, the per-subagent line
  Claude Code renders in the agent panel. Its settings schema is {type, command} only, so the entry
  carries no padding or vim key. Leave the switch out and neither the file nor the key is written.

.PARAMETER Uninstall
  Remove the statusLine entry from settings.json and delete ~/.claude/statusline.ps1.
  ~/.claude/statusline.json is kept. The subagentStatusLine entry and
  ~/.claude/subagent-statusline.ps1 are removed only when they are this project's: the entry has to
  point at ~/.claude/subagent-statusline.ps1 and the file has to carry this project's marker line.
  Anything else of that name is left alone and reported.

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

.EXAMPLE
  .\install.ps1 -Subagents
#>
[CmdletBinding()]
param(
    [switch] $InstallFont,
    [switch] $ConfigureWindowsTerminal,
    [switch] $Uninstall,
    [switch] $Subagents,
    [ValidateRange(1, [int]::MaxValue)] [int] $RefreshInterval,
    [string] $SettingsPath
)

$ErrorActionPreference = 'Stop'
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$target = Join-Path $claudeDir 'statusline.ps1'
$configTarget = Join-Path $claudeDir 'statusline.json'
$subagentTarget = Join-Path $claudeDir 'subagent-statusline.ps1'
# PowerShell variable names are case-insensitive, so $settingsPath below is the -SettingsPath parameter.
if (-not $SettingsPath) { $settingsPath = Join-Path $claudeDir 'settings.json' }
$fontFace = 'JetBrainsMono NF'
# The line subagent-statusline.ps1 carries so the uninstaller can tell this project's copy from a file
# of the same name that someone else put there. Kept short and literal, and checked as a substring, so
# a version bump or an edit to the rest of the header does not make an installed copy unrecognisable.
$subagentMarker = 'claude-code-statusline-ps:subagent-statusline'

# The command Claude Code runs for one of the installed scripts. Forward slashes because Claude Code may
# run the command through Git Bash, which eats backslashes, and the path is double-quoted because a user
# profile can hold spaces (C:\Users\Jane Doe) and both cmd and sh otherwise end the -File argument at the
# first one. Double quotes are the one form both shells honour, and every character Windows forbids in a
# path (" < > | ? * and : outside the drive) is exactly the set that could break out of them. A dollar
# sign and a backtick are legal in a Windows path and still expand inside sh double quotes, so those two
# are warned about below rather than silently mangled.
function Format-ScriptCommand([string] $ScriptPath) {
    return 'pwsh -NoProfile -NoLogo -NonInteractive -File "' + ($ScriptPath -replace '\\', '/') + '"'
}

# -LiteralPath throughout: a settings path with [ or ] in it would otherwise read as missing, so its keys
# would be dropped and the write would fail.
# The raw text of every settings file read is kept so Write-UserSetting can tell whether the file changed
# underneath us between the read and the write, which is the window a second installer or an editor would
# land in. $null means the file was not there when it was read.
$settingsBaseline = @{}
function Read-UserSetting([string] $Path) {
    $raw = $null
    if (Test-Path -LiteralPath $Path) { $raw = Get-Content -LiteralPath $Path -Raw }
    $settingsBaseline[$Path] = $raw
    if ($null -ne $raw) {
        $parsed = $raw | ConvertFrom-Json
        # An empty file parses to nothing, and a bare value or array has no properties to add to; either
        # would otherwise be written back as the literal text "null" or a broken document. The null check
        # comes first because an empty pipeline result passes -is [pscustomobject], and the full type name
        # is used because a bare string or number passes the short one.
        if ($null -ne $parsed -and $parsed -is [System.Management.Automation.PSCustomObject]) { return $parsed }
    }
    return [pscustomobject]@{}
}

# Replaces the settings file in one step. The same shape as Write-AtomicJson in statusline.ps1: serialize
# to a uniquely named sibling, then move it over the destination, which is atomic on Windows and on Linux,
# so a reader never sees a half-written file and a crash, a full disk or a failed encode leaves the old
# file exactly as it was. The copy is deliberate duplication rather than a shared helper: statusline.ps1
# runs its whole body on load, so the installer cannot dot-source it, and other branches are open in that
# file. Consolidate the two when those land.
# Extra steps the cache and state files do not need, because this one is the user's own settings:
#   - the serialized text is parsed back before anything is replaced, so a broken document never lands;
#   - the file is compared with what Read-UserSetting saw, so a change made between the read and the
#     write is refused instead of being silently dropped;
#   - the .bak is taken from the file as it stands, after that check and before the replace.
function Write-UserSetting($obj, [string] $Path) {
    $dir = Split-Path $Path -Parent
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $json = ConvertTo-Json -InputObject $obj -Depth 32
    if (-not $json) { throw "Refusing to write $Path : the settings serialized to nothing." }

    $current = $null
    if (Test-Path -LiteralPath $Path) { $current = Get-Content -LiteralPath $Path -Raw }
    if ($settingsBaseline.ContainsKey($Path) -and $current -cne $settingsBaseline[$Path]) {
        throw "Refusing to write $Path : it changed after this installer read it. Nothing was written; run the installer again."
    }

    # A unique name, so two installers running at once cannot write the same temporary file, and in the
    # same directory, so the move is a rename on one volume rather than a copy across two.
    $tmp = "$Path.tmp-$([System.IO.Path]::GetRandomFileName())"
    try {
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
        # Read the temporary file back before it replaces anything: an encoding fault or a short write
        # shows up here, while the destination is still the old file.
        $check = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
        if ($null -eq $check -or $check -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Refusing to write $Path : the serialized settings did not read back as an object."
        }
        Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force -ErrorAction SilentlyContinue
        [System.IO.File]::Move($tmp, $Path, $true)
        # Re-read rather than remembering $json: Set-Content ends the file with a newline that the
        # serialized text does not have, and a second write in the same process would otherwise compare
        # the two and call its own last write a conflict.
        $settingsBaseline[$Path] = Get-Content -LiteralPath $Path -Raw
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# Whether the subagentStatusLine entry in the settings is the one this installer writes: it has to be a
# command entry whose command names ~/.claude/subagent-statusline.ps1. Compared with slashes normalised
# and case ignored, because Windows paths are case-insensitive and the entry may have been written by an
# older version that used backslashes or no quotes. Anything else is somebody else's key.
function Test-OwnSubagentEntry($Entry, [string] $ScriptPath) {
    if ($null -eq $Entry -or $Entry -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $command = [string] $Entry.command
    if (-not $command) { return $false }
    $needle = ($ScriptPath -replace '\\', '/')
    return $command.Replace('\', '/').IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

# Whether the file at $Path is this project's subagent status line, by its marker line. A file that
# cannot be read is not treated as ours, so an unreadable file is kept rather than deleted.
function Test-OwnSubagentScript([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $text = $null
    try { $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return $false }
    return ($null -ne $text -and $text.Contains($subagentMarker))
}

if ($Uninstall) {
    $s = Read-UserSetting $settingsPath
    # Both keys go in one Write-UserSetting: a second write would overwrite the .bak with the state
    # after the first, so the backup would no longer hold the settings as they were.
    $removed = @()
    $kept = @()
    if ($s.PSObject.Properties['statusLine']) {
        $removed += "statusLine ($(@($s.statusLine.PSObject.Properties.Name) -join ', '))"
        $s.PSObject.Properties.Remove('statusLine')
    }
    # The subagent line is opt-in, so its key and its file are only this installer's when they look like
    # it. -Subagents is not required to remove them, but ownership is: a subagentStatusLine somebody else
    # set up, or a file of that name they wrote themselves, is left where it is and reported.
    if ($s.PSObject.Properties['subagentStatusLine']) {
        if (Test-OwnSubagentEntry $s.subagentStatusLine $subagentTarget) {
            $removed += 'subagentStatusLine'
            $s.PSObject.Properties.Remove('subagentStatusLine')
        } else {
            $kept += "the subagentStatusLine entry in $settingsPath does not point at $subagentTarget, so it was left alone"
        }
    }
    if ($removed.Count -gt 0) {
        Write-UserSetting $s $settingsPath
        Write-Host "Removed $($removed -join ' and ') from $settingsPath"
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force; Write-Host "Deleted $target" }
    if (Test-Path -LiteralPath $subagentTarget) {
        if (Test-OwnSubagentScript $subagentTarget) {
            Remove-Item -LiteralPath $subagentTarget -Force
            Write-Host "Deleted $subagentTarget"
        } else {
            $kept += "$subagentTarget does not carry this project's marker, so it was left alone"
        }
    }
    foreach ($k in $kept) { Write-Warning "Kept: $k" }
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
# The two characters that survive double quotes in sh but are legal in a Windows path. Nothing here can
# quote for cmd and for sh at once, so say so rather than write a command that silently does the wrong
# thing on one of them.
if ($claudeDir -match '[$`]') {
    Write-Warning "$claudeDir contains a dollar sign or a backtick. The command written to settings.json is quoted for cmd, but Git Bash expands both inside double quotes; move the profile or edit the command by hand if the status line does not appear."
}

$command = Format-ScriptCommand $target
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
# The per-subagent line is a second command Claude Code runs for the agent panel. Its settings schema
# is {type, command}, so no padding and no vim key go with it, and it is written into the same object
# so both entries land in one write and one .bak.
if ($Subagents) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'subagent-statusline.ps1') -Destination $subagentTarget -Force
    $subagentEntry = [pscustomobject]@{ type = 'command'; command = (Format-ScriptCommand $subagentTarget) }
    if ($s.PSObject.Properties['subagentStatusLine']) { $s.subagentStatusLine = $subagentEntry }
    else { $s | Add-Member -NotePropertyName subagentStatusLine -NotePropertyValue $subagentEntry }
}
Write-UserSetting $s $settingsPath
Write-Host "Configured statusLine in $settingsPath (hideVimModeIndicator on$(if ($wantRefresh) { ", refreshInterval $RefreshInterval s" }))"
if ($Subagents) {
    Write-Host "Installed $subagentTarget"
    Write-Host "Configured subagentStatusLine in $settingsPath"
}

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
