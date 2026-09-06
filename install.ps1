#Requires -Version 7.0
<#
.SYNOPSIS
  Installs the PowerShell status line for Claude Code (Windows).

.DESCRIPTION
  Copies statusline.ps1 to ~/.claude/statusline.ps1, copies statusline.json there if none exists, and adds a "statusLine" entry to the USER-level
  Claude Code settings (~/.claude/settings.json), preserving every other key. The entry always sets
  hideVimModeIndicator, because the status line draws its own vim badge, and sets refreshInterval when
  -RefreshInterval is given. Optionally installs the JetBrainsMono Nerd Font via winget and sets it as
  Windows Terminal's default font so the glyphs render, and with -DetectTheme reads Windows Terminal's
  colour scheme to set the "palette" key in statusline.json.

.PARAMETER InstallFont
  Install JetBrainsMono Nerd Font with winget (asks for elevation once).

.PARAMETER ConfigureWindowsTerminal
  Set Windows Terminal's default font face to "JetBrainsMono NF" (a backup of settings.json is kept).

.PARAMETER Subagents
  Also install subagent-statusline.ps1 and add a "subagentStatusLine" entry, the per-subagent line
  Claude Code renders in the agent panel. Its settings schema is {type, command} only, so the entry
  carries no padding or vim key. Leave the switch out and neither the file nor the key is written.

.PARAMETER DetectTheme
  Look at Windows Terminal's default colour scheme, work out whether its background is light or dark,
  and write the answer into ~/.claude/statusline.json as "palette", preserving every other key. It
  prints the scheme it found, that scheme's background and the palette it chose, so a wrong answer is
  visible and can be corrected by editing the one key.
  WHAT THIS CAN AND CANNOT KNOW. It reads Windows Terminal's CONFIGURATION, not the terminal you are
  looking at: a session in conhost, VS Code, an SSH client or a non-default Windows Terminal profile is
  none of its business, and it says so by naming the scheme it read. When any link in the chain is
  missing - no settings file, no default profile, a scheme it cannot find a background for, or a
  profile that follows the OS light/dark setting and so has two schemes with nothing to say which is in
  force - IT WRITES NOTHING and prints why. That is deliberate: the palette defaults to dark, a wrong
  guess of "light" would make the line unreadable, and leaving the key out is the answer that can be
  corrected by hand. Without the switch statusline.json is not touched at all.

.PARAMETER Uninstall
  Remove the statusLine entry from settings.json and delete ~/.claude/statusline.ps1.
  ~/.claude/statusline.json is kept. The subagentStatusLine entry and
  ~/.claude/subagent-statusline.ps1 are removed only when they are this project's: the entry has to be
  the exact command form this installer writes, with that path as its -File argument, and the file has
  to carry this project's marker line. The rollback copy an install leaves,
  ~/.claude/.claude-code-statusline-ps.subagent-rollback.ps1, is removed on the same test. Anything
  else of those names is left alone and reported.

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

.EXAMPLE
  .\install.ps1 -DetectTheme
#>
[CmdletBinding()]
param(
    [switch] $InstallFont,
    [switch] $ConfigureWindowsTerminal,
    [switch] $DetectTheme,
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
# Where an install keeps the version it replaced. Not subagent-statusline.ps1.bak: a .bak beside a file
# is a name anyone's own tooling might already be using, and this installer writes and deletes this file
# without being asked, so it uses a name carrying this project's id instead. Ownership is still checked
# by the marker line before it is overwritten or removed, because a name alone is not proof.
$subagentRollback = Join-Path $claudeDir '.claude-code-statusline-ps.subagent-rollback.ps1'
# PowerShell variable names are case-insensitive, so $settingsPath below is the -SettingsPath parameter.
if (-not $SettingsPath) { $settingsPath = Join-Path $claudeDir 'settings.json' }
$fontFace = 'JetBrainsMono NF'
# The line subagent-statusline.ps1 carries so the uninstaller can tell this project's copy from a file
# of the same name that someone else put there. It has to be a whole line, on its own, inside the first
# few lines of the file: the token appearing anywhere in a file is not evidence it is ours, because it
# can just as easily sit in a comment about this project, in a string literal, or in embedded data.
$subagentMarkerLine = '# claude-code-statusline-ps:subagent-statusline'
$subagentMarkerWithin = 10

# How long a settings write waits for another installer to finish before giving up. This is a lock held
# across a read-modify-write of the user's settings by a command someone runs by hand, so waiting is
# free; the render path never comes here.
$settingsLockTimeoutMs = 5000

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

# An exclusive handle on <settings>.lock, taken with FileShare::None so a second installer blocks on it
# rather than interleaving with this one. A lock file rather than a named mutex, because a mutex name is
# global to a machine and would serialise installs against unrelated settings files (see
# Invoke-StatusDiagRollover in statusline.ps1, #49, for what a machine- or session-scoped mutex name
# actually does on Unix and Windows and why a lock file is the safer default here too). The file is
# left behind, empty: deleting it on release would race a process already waiting to open it.
function Get-SettingLock([string] $Path, [int] $TimeoutMs) {
    $lockPath = "$Path.lock"
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        try {
            return [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Could not lock $lockPath after $TimeoutMs ms; another installer is holding it. Nothing was written."
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

# Replaces the settings file in one step. The same shape as Write-AtomicJson in statusline.ps1: serialize
# to a uniquely named sibling, then move it over the destination, which is atomic on Windows and on Linux,
# so a reader never sees a half-written file and a crash, a full disk or a failed encode leaves the old
# file exactly as it was. The copy is deliberate duplication rather than a shared helper: statusline.ps1
# runs its whole body on load, so the installer cannot dot-source it, and other branches are open in that
# file. Consolidate the two when those land.
# Extra steps the cache and state files do not need, because this one is the user's own settings:
#   - the read-modify-write runs under an exclusive lock on a sibling lock file. That serialises this
#     installer against anything else that takes the same lock, and does nothing at all about a writer
#     that does not take it: a cooperative lock cannot exclude a process that ignores it;
#   - the file is compared with what Read-UserSetting saw twice, when the lock is taken and again
#     immediately before the rename. A change that lands before that second comparison is refused;
#   - the serialized text is parsed back before anything is replaced, so a broken document never lands;
#   - the .bak is taken from the file as it stands, before the replace.
# What this does not do, stated plainly rather than implied away: a writer that does not take the lock
# can still save in the gap between that second comparison and the rename, and the rename replaces it.
# The gap is one filesystem operation wide and closing it would need a compare-and-swap the filesystem
# does not offer, or a lock every writer honours. The content that was replaced is in the .bak.
function Write-UserSetting($obj, [string] $Path) {
    $dir = Split-Path $Path -Parent
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $json = ConvertTo-Json -InputObject $obj -Depth 32
    if (-not $json) { throw "Refusing to write $Path : the settings serialized to nothing." }

    # A unique name, so two installers cannot write the same temporary file, and in the same directory,
    # so the move is a rename on one volume rather than a copy across two.
    $tmp = "$Path.tmp-$([System.IO.Path]::GetRandomFileName())"
    $lock = Get-SettingLock $Path $settingsLockTimeoutMs
    try {
        Confirm-SettingUnchanged $Path
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
        # Read the temporary file back before it replaces anything: an encoding fault or a short write
        # shows up here, while the destination is still the old file.
        $check = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
        if ($null -eq $check -or $check -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Refusing to write $Path : the serialized settings did not read back as an object."
        }
        Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force -ErrorAction SilentlyContinue
        Confirm-SettingUnchanged $Path
        [System.IO.File]::Move($tmp, $Path, $true)
        # Re-read rather than remembering $json: Set-Content ends the file with a newline that the
        # serialized text does not have, and a second write in the same process would otherwise compare
        # the two and call its own last write a conflict.
        $settingsBaseline[$Path] = Get-Content -LiteralPath $Path -Raw
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        $lock.Dispose()
    }
}

# Throws when the file on disk is no longer the text Read-UserSetting saw. Called twice by the write,
# once on taking the lock and once immediately before the rename, so it is a function rather than two
# copies of the comparison. The second call narrows the window to the rename; it does not remove it.
function Confirm-SettingUnchanged([string] $Path) {
    if (-not $settingsBaseline.ContainsKey($Path)) { return }
    $current = $null
    if (Test-Path -LiteralPath $Path) { $current = Get-Content -LiteralPath $Path -Raw }
    if ($current -cne $settingsBaseline[$Path]) {
        throw "Refusing to write $Path : it changed after this installer read it. Nothing was written; run the installer again."
    }
}

# Splits a command line into its arguments the way a shell would, for the purpose of recognising one:
# whitespace separates, double quotes group. Each argument comes back as @{ Text; Quoted }, so a
# character that means something to a shell can be judged on whether it was inside quotes - the path
# this installer writes really does contain, say, an ampersand when the profile does. $null when the
# quoting never closes, which is not a command this installer wrote.
function Split-CommandArgument([string] $Command) {
    $parts = [System.Collections.Generic.List[hashtable]]::new()
    $cur = [System.Text.StringBuilder]::new()
    $inQuote = $false
    $started = $false
    $quoted = $false
    foreach ($ch in $Command.ToCharArray()) {
        if ($ch -eq '"') { $inQuote = -not $inQuote; $started = $true; $quoted = $true; continue }
        if (-not $inQuote -and [char]::IsWhiteSpace($ch)) {
            if ($started) { $parts.Add(@{ Text = $cur.ToString(); Quoted = $quoted }); [void] $cur.Clear(); $started = $false; $quoted = $false }
            continue
        }
        [void] $cur.Append($ch)
        $started = $true
    }
    if ($inQuote) { return $null }
    if ($started) { $parts.Add(@{ Text = $cur.ToString(); Quoted = $quoted }) }
    return $parts
}

# Two paths naming the same file, as far as this installer can tell: slashes normalised, a trailing
# separator ignored, case ignored because Windows paths are case-insensitive.
function Test-SamePath([string] $A, [string] $B) {
    if (-not $A -or -not $B) { return $false }
    $na = ($A -replace '\\', '/').TrimEnd('/')
    $nb = ($B -replace '\\', '/').TrimEnd('/')
    return [string]::Equals($na, $nb, [System.StringComparison]::OrdinalIgnoreCase)
}

# Whether the subagentStatusLine entry is one this installer wrote. The whole command has to be the form
# it writes and nothing else: pwsh, then only the switches it passes, then -File, then exactly one more
# argument, which has to BE the target path rather than merely contain it, and then the end of the
# string. A substring test would claim `node wrapper.js "C:/.../subagent-statusline.ps1"` as ours and
# delete it, and that command never runs our script. An unquoted shell operator anywhere disqualifies
# the command too, because it means something is being chained that this installer did not write.
# There is no provenance field to lean on instead: the setting's schema is {type, command} and an
# unknown key in it is not something to rely on surviving.
function Test-OwnSubagentEntry($Entry, [string] $ScriptPath) {
    if ($null -eq $Entry -or $Entry -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    if (([string] $Entry.type) -ne 'command') { return $false }
    $command = $Entry.command
    if ($command -isnot [string] -or -not $command) { return $false }
    $parts = Split-CommandArgument $command
    if ($null -eq $parts -or $parts.Count -lt 3) { return $false }
    foreach ($p in $parts) {
        if (-not $p.Quoted -and $p.Text -match '[&|;<>`$()]') { return $false }
    }
    $exe = [System.IO.Path]::GetFileName(($parts[0].Text -replace '\\', '/'))
    if ($exe.ToLowerInvariant() -notin @('pwsh', 'pwsh.exe')) { return $false }
    $i = 1
    while ($i -lt $parts.Count -and $parts[$i].Text.ToLowerInvariant() -in @('-noprofile', '-nologo', '-noninteractive')) { $i++ }
    if ($i -ge $parts.Count -or $parts[$i].Text.ToLowerInvariant() -ne '-file') { return $false }
    # Exactly one argument after -File, and nothing at all after that.
    if ($parts.Count -ne $i + 2) { return $false }
    return (Test-SamePath $parts[$i + 1].Text $ScriptPath)
}

# Whether the file at $Path is this project's subagent status line. The marker has to be a whole line of
# its own, trimmed, within the first few lines of the file. Matching the token anywhere would claim any
# file that merely mentions this project - a note in a comment, a string literal, a copied header - and
# then delete it. A file that cannot be read is not ours either, so an unreadable file is kept.
function Test-OwnSubagentScript([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $lines = $null
    try { $lines = Get-Content -LiteralPath $Path -TotalCount $subagentMarkerWithin -ErrorAction Stop } catch { return $false }
    foreach ($line in @($lines)) {
        if (($line -is [string]) -and $line.Trim() -ceq $subagentMarkerLine) { return $true }
    }
    return $false
}

# Windows Terminal's settings.json, or $null. One function rather than the glob written out twice, so
# -ConfigureWindowsTerminal and -DetectTheme cannot end up looking in different places. The package
# name is a wildcard because the folder carries a publisher hash that differs between the Store build,
# the Preview build and the unpackaged one.
function Get-WindowsTerminalSettingPath {
    if (-not $env:LOCALAPPDATA) { return $null }
    $found = Get-ChildItem "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal*\LocalState\settings.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

# The WCAG 2.1 relative luminance of an #RRGGBB colour, 0 for black and 1 for white: each channel
# scaled to 0..1, linearised (the plain divide under 0.03928, the 2.4 power above it, which is the step
# that is easy to leave out and would put #808080 at 0.502 instead of 0.216), then weighted 0.2126,
# 0.7152 and 0.0722.
# $null - not 0 - for anything that is not a six-digit hex colour, because the caller's whole decision
# rests on this number and a 0 for an unreadable value would be a silent vote for the dark palette.
# \z rather than $ so a trailing newline cannot smuggle a value past the pattern, and the parameter is
# untyped so a number, an array or a boolean is refused rather than cast into a string first.
function Get-BackgroundLuminance($Hex) {
    if ($Hex -isnot [string]) { return $null }
    if ($Hex -notmatch '^#?([0-9A-Fa-f]{6})\z') { return $null }
    $digits = $Matches[1]
    $channels = foreach ($i in 0, 2, 4) {
        $v = [System.Convert]::ToInt32($digits.Substring($i, 2), 16) / 255
        if ($v -le 0.03928) { $v / 12.92 } else { [math]::Pow((($v + 0.055) / 1.055), 2.4) }
    }
    return 0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
}

# The background colour of the scheme Windows Terminal's DEFAULT PROFILE uses, as
# @{ Scheme; Background; Reason }. Background is $null whenever the chain below breaks, and Reason
# always says where it broke, because a detection nobody can see is a detection nobody can correct.
#
# The chain, and every place it can end early:
#   defaultProfile          a guid. Absent on a settings file that has never been saved.
#   profiles                either { defaults, list } or, on the older schema, the list itself.
#   the matching profile    may not exist: a guid can name a profile that has since been removed.
#   colorScheme             may sit on profiles.defaults instead of on the profile. May also be an
#                           OBJECT with light and dark members, which means the terminal follows the
#                           OS theme - and nothing in the settings file says which way that is set, so
#                           there is no answer to give and this returns none rather than picking one.
#   schemes                 the user's own definitions. Windows Terminal does NOT write the schemes it
#                           ships into this file, so a name found nowhere in it may still be a real
#                           scheme; the table at the foot of this function holds those nine
#                           backgrounds. A file that redefines a shipped name wins over the table,
#                           because the file is what the terminal actually reads.
# -LiteralPath throughout, so a profile path with a bracket in it is read rather than treated as a
# wildcard, and every read is in a try: this function is a convenience on top of an install and must
# never be the thing that fails one.
function Get-SchemeBackground([string] $Path) {
    $answer = @{ Scheme = $null; Background = $null; Reason = 'no Windows Terminal settings file was found' }
    if (-not $Path) { return $answer }
    if (-not (Test-Path -LiteralPath $Path)) { $answer.Reason = "there is no Windows Terminal settings file at $Path"; return $answer }
    $settings = $null
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ($raw) { $settings = $raw | ConvertFrom-Json -ErrorAction Stop }
    } catch { $settings = $null }
    if ($null -eq $settings -or $settings -isnot [System.Management.Automation.PSCustomObject]) {
        $answer.Reason = "$Path did not parse as a settings object"
        return $answer
    }
    $default = $settings.defaultProfile
    if ($default -isnot [string] -or -not $default) { $answer.Reason = "$Path names no defaultProfile"; return $answer }
    $list = @()
    $defaults = $null
    if ($settings.profiles -is [array]) {
        $list = $settings.profiles
    } elseif ($settings.profiles -is [System.Management.Automation.PSCustomObject]) {
        if ($settings.profiles.list -is [array]) { $list = $settings.profiles.list }
        $defaults = $settings.profiles.defaults
    }
    $entry = $null
    foreach ($p in $list) {
        if ($p -is [System.Management.Automation.PSCustomObject] -and ([string] $p.guid) -eq $default) { $entry = $p; break }
    }
    $scheme = $null
    if ($null -ne $entry) { $scheme = $entry.colorScheme }
    if ($null -eq $scheme -and $defaults -is [System.Management.Automation.PSCustomObject]) { $scheme = $defaults.colorScheme }
    if ($null -eq $scheme) {
        $answer.Reason = if ($null -eq $entry) { "no profile in $Path carries the guid $default, and profiles.defaults names no colorScheme" }
        else { "the default profile in $Path names no colorScheme" }
        return $answer
    }
    if ($scheme -is [System.Management.Automation.PSCustomObject]) {
        $answer.Reason = "the default profile follows the OS light/dark setting (light `"$([string] $scheme.light)`", dark `"$([string] $scheme.dark)`") and the settings file does not say which is in force"
        return $answer
    }
    if ($scheme -isnot [string] -or -not $scheme) { $answer.Reason = "the default profile's colorScheme in $Path is not a scheme name"; return $answer }
    $answer.Scheme = $scheme
    foreach ($s in @($settings.schemes)) {
        if ($s -isnot [System.Management.Automation.PSCustomObject] -or ([string] $s.name) -ne $scheme) { continue }
        if ($s.background -is [string] -and $s.background -match '^#?[0-9A-Fa-f]{6}\z') {
            $answer.Background = $s.background
            $answer.Reason = "defined in $Path"
        } else {
            $answer.Reason = "scheme `"$scheme`" is defined in $Path but its background is not a colour"
        }
        return $answer
    }
    # The nine schemes Windows Terminal ships. They are real schemes a profile can name and are absent
    # from the user's file, so without this table the commonest case of all - a default install using
    # Campbell - would come back as "unknown scheme".
    $builtin = [ordered]@{
        'Campbell'            = '#0C0C0C'
        'Campbell Powershell' = '#012456'
        'Vintage'             = '#000000'
        'One Half Dark'       = '#282C34'
        'One Half Light'      = '#FAFAFA'
        'Solarized Dark'      = '#002B36'
        'Solarized Light'     = '#FDF6E3'
        'Tango Dark'          = '#000000'
        'Tango Light'         = '#FFFFFF'
    }
    foreach ($name in $builtin.Keys) {
        if ([string]::Equals($name, $scheme, [System.StringComparison]::OrdinalIgnoreCase)) {
            $answer.Background = $builtin[$name]
            $answer.Reason = 'one of the schemes Windows Terminal ships'
            return $answer
        }
    }
    $answer.Reason = "scheme `"$scheme`" is not defined in $Path and is not one of the schemes Windows Terminal ships"
    return $answer
}

# Sets one top-level key in statusline.json and leaves every other key exactly as it was. The same
# atomic shape Write-UserSetting uses - serialize to a uniquely named sibling, read it back, then move
# it over the destination - because the status line reads this file on every render and a reader must
# never see a half-written one. No lock file: nothing else writes this file, and the render path only
# reads it. The file is reformatted by the round trip through ConvertTo-Json, which is a cosmetic
# change to a file the user may have laid out by hand, and is the price of not writing a JSON editor.
function Write-StatusConfigValue([string] $Path, [string] $Name, $Value) {
    $obj = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -eq $obj -or $obj -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Refusing to write $Path : it did not read back as a JSON object."
    }
    if ($obj.PSObject.Properties[$Name]) { $obj.$Name = $Value }
    else { $obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
    $json = ConvertTo-Json -InputObject $obj -Depth 32
    if (-not $json) { throw "Refusing to write $Path : it serialized to nothing." }
    $tmp = "$Path.tmp-$([System.IO.Path]::GetRandomFileName())"
    try {
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
        $check = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
        if ($null -eq $check -or $check -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Refusing to write $Path : the serialized config did not read back as an object."
        }
        [System.IO.File]::Move($tmp, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
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
            # The rollback copy an install leaves is litter once the script is gone, but it is only ours
            # to delete when it carries the marker: the name is this project's, and that is still not
            # proof that the file at it is.
            if (Test-Path -LiteralPath $subagentRollback) {
                if (Test-OwnSubagentScript $subagentRollback) {
                    Remove-Item -LiteralPath $subagentRollback -Force -ErrorAction SilentlyContinue
                    Write-Host "Deleted $subagentRollback"
                } else {
                    $kept += "$subagentRollback does not carry this project's marker line, so it was left alone"
                }
            }
        } else {
            $kept += "$subagentTarget does not carry this project's marker line, so it was left alone"
        }
    }
    foreach ($k in $kept) { Write-Warning "Kept: $k" }
    if (Test-Path -LiteralPath $configTarget) { Write-Host "Kept $configTarget (delete it yourself if you no longer want it)" }
    # The status line writes one small JSON file per session outside ~/.claude, so say where they are.
    $stateDir = if ($env:TEMP) { Join-Path $env:TEMP 'claude-statusline-state' } else { Join-Path $HOME '.claude' 'statusline-state' }
    Write-Host "Session state files are in $stateDir (delete the folder yourself if you no longer want it)"
    return
}

# The one thing that can refuse an install outright is whether the file already at $subagentTarget is
# this project's, and answering it is a read, so it is answered here: above the New-Item below, which is
# the first line of this script that writes anything at all. The refusal therefore leaves every
# destination file exactly as it was, which is what its message says. Everything below this line writes;
# a failure down there can leave statusline.ps1 and statusline.json in place, but both are this
# project's own files at their own names, so re-running the installer finishes the job.
if ($Subagents -and (Test-Path -LiteralPath $subagentTarget) -and -not (Test-OwnSubagentScript $subagentTarget)) {
    throw "$subagentTarget already exists and is not this project's file: it carries no '$subagentMarkerLine' line in its first $subagentMarkerWithin lines. Nothing was installed. Move or delete that file yourself if you want the subagent status line there."
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

# The subagent script is staged beside its destination under a temporary name. A directory that cannot
# be written fails here, before either the file or the settings are committed, and the destination still
# holds whatever it held until the move below. Whether it may be replaced at all was settled at the top
# of the script, before anything was written.
$subagentStaged = $null
if ($Subagents) {
    $subagentStaged = "$subagentTarget.tmp-$([System.IO.Path]::GetRandomFileName())"
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'subagent-statusline.ps1') -Destination $subagentStaged -Force
}

try {
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
    $subagentEntry = [pscustomobject]@{ type = 'command'; command = (Format-ScriptCommand $subagentTarget) }
    if ($s.PSObject.Properties['subagentStatusLine']) { $s.subagentStatusLine = $subagentEntry }
    else { $s | Add-Member -NotePropertyName subagentStatusLine -NotePropertyValue $subagentEntry }
}
# The file goes in before the settings that name it, not after. The two failures are not the same size:
# a subagent script sitting at its own path with no key naming it is inert, because Claude Code runs
# only what settings.json points at, while a subagentStatusLine key naming a file that is not there
# launches a missing script on every panel tick. So the move, the rollback copy in front of it, and
# every permission error, lock and full disk either of them can raise happen while settings.json still
# says nothing about a subagent line.
if ($Subagents) {
    # The version being replaced, which the check at the top of the script proved is ours, is kept so an
    # install can be undone. Anything already sitting at the rollback name that is not ours is left
    # alone and the copy is skipped: losing the ability to roll back is a smaller harm than overwriting
    # someone's file, and the install itself is unaffected either way.
    if (Test-Path -LiteralPath $subagentTarget) {
        if ((Test-Path -LiteralPath $subagentRollback) -and -not (Test-OwnSubagentScript $subagentRollback)) {
            Write-Warning "Kept: $subagentRollback does not carry this project's marker line, so the copy of the version being replaced was not written."
        } else {
            Copy-Item -LiteralPath $subagentTarget -Destination $subagentRollback -Force
        }
    }
    [System.IO.File]::Move($subagentStaged, $subagentTarget, $true)
    $subagentStaged = $null
    Write-Host "Installed $subagentTarget"
}
# Both entries are in one object and one write, so a conflict or a failed write throws here having
# changed no key at all, and every path settings.json names is already a file on disk.
Write-UserSetting $s $settingsPath
Write-Host "Configured statusLine in $settingsPath (hideVimModeIndicator on$(if ($wantRefresh) { ", refreshInterval $RefreshInterval s" }))"
if ($Subagents) { Write-Host "Configured subagentStatusLine in $settingsPath" }
} finally {
    # A staged file still under its temporary name means the install did not finish; it is this script's
    # to clean up either way.
    if ($subagentStaged -and (Test-Path -LiteralPath $subagentStaged)) { Remove-Item -LiteralPath $subagentStaged -Force -ErrorAction SilentlyContinue }
}

if ($DetectTheme) {
    # After the install, so statusline.json is already at its destination, and after the settings
    # write, so nothing here can stand between a working install and the entry that names it. Every
    # branch below ends in a printed line: the answer is a guess about somebody's terminal and the only
    # thing that makes a guess safe is saying it out loud.
    $found = Get-SchemeBackground (Get-WindowsTerminalSettingPath)
    $lum = if ($found.Background) { Get-BackgroundLuminance $found.Background } else { $null }
    if ($null -eq $lum) {
        Write-Host "Theme detection: $($found.Reason). Nothing was written, so $configTarget keeps the palette it had - dark unless you have set one. Set `"palette`" to `"light`" in that file by hand if your terminal has a pale background."
    } elseif (-not (Test-Path -LiteralPath $configTarget)) {
        Write-Warning "Theme detection found a background of $($found.Background), but there is no $configTarget to write it into."
    } else {
        # 0.5 is the midpoint of the luminance scale rather than a tuned figure, and it does not need to
        # be tuned: every scheme Windows Terminal ships is under 0.05 or over 0.85, so the cut sits in
        # an empty band. The scheme name is printed beside the number because THIS IS A READ OF A
        # CONFIGURATION, NOT A LOOK AT YOUR SCREEN - a session in conhost, VS Code, an SSH client or a
        # profile that is not the default one is a terminal this never saw.
        $palette = if ($lum -gt 0.5) { 'light' } else { 'dark' }
        try {
            Write-StatusConfigValue $configTarget 'palette' $palette
            Write-Host ("Theme detection: Windows Terminal's default profile uses colour scheme `"{0}`" ({1}), whose background {2} has a relative luminance of {3:N3}. Wrote `"palette`": `"{4}`" to {5}; every other key was kept." -f $found.Scheme, $found.Reason, $found.Background, $lum, $palette, $configTarget)
            Write-Host "  If that is not the terminal you use Claude Code in, edit that one key."
        } catch {
            Write-Warning "Theme detection chose the $palette palette but could not write it to $configTarget : $($_.Exception.Message)"
        }
    }
}

if ($InstallFont) {
    Write-Host 'Installing JetBrainsMono Nerd Font (winget; expect an elevation prompt)...'
    winget install --id DEVCOM.JetBrainsMonoNerdFont --exact --accept-package-agreements --accept-source-agreements | Out-Host
}

if ($ConfigureWindowsTerminal) {
    $wt = Get-WindowsTerminalSettingPath
    if (-not $wt) { Write-Warning 'Windows Terminal settings.json not found; set the font manually.' }
    else {
        Copy-Item $wt "$wt.bak-before-nerdfont" -Force
        $j = Get-Content $wt -Raw | ConvertFrom-Json
        if (-not $j.profiles.defaults) { $j.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{}) }
        if (-not $j.profiles.defaults.font) { $j.profiles.defaults | Add-Member -NotePropertyName font -NotePropertyValue ([pscustomobject]@{}) -Force }
        $j.profiles.defaults.font | Add-Member -NotePropertyName face -NotePropertyValue $fontFace -Force
        $j | ConvertTo-Json -Depth 32 | Set-Content $wt -Encoding UTF8
        Write-Host "Windows Terminal default font set to '$fontFace' (backup kept next to settings.json)"
    }
}

Write-Host ''
Write-Host 'Done. Claude Code picks the status line up on its next refresh or session start.'
Write-Host "If icons render as boxes, set your terminal font to '$fontFace' (or any Nerd Font)."
