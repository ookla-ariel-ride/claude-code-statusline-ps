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
  Set Windows Terminal's default font face to "JetBrainsMono NF" (the previous settings.json is kept at
  a project-owned backup name beside it, not a generic ".bak").

.PARAMETER Subagents
  Also install subagent-statusline.ps1 and add a "subagentStatusLine" entry, the per-subagent line
  Claude Code renders in the agent panel. Its settings schema is {type, command} only, so the entry
  carries no padding or vim key. Leave the switch out and neither the file nor the key is CREATED - but
  an entry this installer already wrote is refreshed by any run that changes the style or the palette,
  so the command never outlives the settings it describes.
  The command carries -Style and -Palette: the panel reads no config file, so the pair the status line
  will use is baked into the command here. It is the pair -Style and -Palette were given, else the one
  -DetectTheme worked out, else the one already in ~/.claude/statusline.json, else plain and dark. It
  is fixed until the installer runs again, which fits what those two are - a font and a background
  belong to the terminal, not to the session.

.PARAMETER Style
  plain, powerline or ascii, written as the "style" key in ~/.claude/statusline.json (every other key
  is kept) and carried into the subagentStatusLine command - which is refreshed whenever this installer
  recognises the entry as its own, with or without -Subagents. Leave it out and both the file and the
  panel keep the style already in that file. The panel draws ascii differently and draws plain and
  powerline the same, because it has no separators to shape.

.PARAMETER Palette
  dark or light, written as the "palette" key in ~/.claude/statusline.json (every other key is kept)
  and carried into the subagentStatusLine command, which is refreshed whenever this installer
  recognises the entry as its own. It outranks -DetectTheme, which still says what it found. Leave it
  out and the palette comes from the detection, or from the file.

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
  corrected by hand. Without the switch, and without -Style or -Palette, statusline.json is not
  touched at all. -Palette outranks this: the guess does not overwrite an answer that was given.

.PARAMETER Uninstall
  Remove the statusLine entry from settings.json and delete ~/.claude/statusline.ps1.
  ~/.claude/statusline.json is kept. The subagentStatusLine entry and
  ~/.claude/subagent-statusline.ps1 are removed only when they are this project's: the entry has to be
  the exact command form this installer writes - pwsh, its switches, -File, that path, and after it
  only the panel's own -Style and -Palette arguments with values the panel has - and the file has to
  carry this project's marker line. The rollback copy an install leaves,
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

.EXAMPLE
  .\install.ps1 -Subagents -Style ascii -Palette light
#>
[CmdletBinding()]
param(
    [switch] $InstallFont,
    [switch] $ConfigureWindowsTerminal,
    [switch] $DetectTheme,
    [switch] $Uninstall,
    [switch] $Subagents,
    [ValidateSet('plain', 'powerline', 'ascii')] [string] $Style,
    [ValidateSet('dark', 'light')] [string] $Palette,
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

# The arguments this installer puts on the subagentStatusLine command: the parameter name, the
# statusline.json key that holds the same setting, the values each takes, what it falls back to, and
# whether -DetectTheme can decide it.
#
# ONE TABLE, AND EVERY READER LOOPS OVER IT. Format-SubagentCommand writes the arguments,
# Test-OwnSubagentEntry recognises them, the decide block below works out the value of each, the
# statusline.json write puts them in the file, and every printed line reads the answer back out. Those
# disagreeing is worse here than anywhere else in this file: an entry this installer wrote and no
# longer recognises is a key -Uninstall walks past and leaves for the user to find. A third argument
# should be one row here and nothing else, and it was hand-unrolled into five places before this.
#
# The values are the ones statusline.json allows for `style` and `palette` and the ones the panel
# accepts; test.ps1 compares this table against the status line's own key table, and against the
# panel's own two lists and the ValidateSet below, rather than taking the comment's word for it.
# A function and not a script variable, because test.ps1 lifts functions out of this file by name and
# a script-level constant does not come with them.
function Get-SubagentArgumentSpec {
    return @(
        @{ Name = 'Style';   Key = 'style';   Allowed = @('plain', 'powerline', 'ascii'); Default = 'plain'; Detected = $false }
        # Detected: -DetectTheme works out a palette and nothing else, so the detection branch of the
        # decide block is a property of this row rather than a name tested for in the loop.
        @{ Name = 'Palette'; Key = 'palette'; Allowed = @('dark', 'light');               Default = 'dark';  Detected = $true }
    )
}

# The subagentStatusLine command: the script, then the style and the palette. The panel reads no config
# file - one process per panel tick, and that read is the one the render path was taught to avoid - so
# the two settings it needs are baked in here, from the same statusline.json the status line reads.
# BOTH ARE ALWAYS WRITTEN, defaults included. A command that leaves them out would mean "whatever the
# panel's own defaults are", which is a different promise from "what the status line draws today", and
# the whole point of writing them is that the two agree.
#
# $Decided is the map the block below builds, one entry per row of the spec, so the composer reads the
# same object every other reader does rather than a pair of positional strings that could be passed the
# wrong way round.
#
# A value outside the table THROWS rather than being quietly defaulted. Nothing should be able to get
# one this far - the parameters are ValidateSet, the config reader refuses anything else, and the
# detection only ever answers with a row's own value - so a value that arrives here anyway means the
# decide block has a bug, and defaulting it would compose a command that silently disagrees with
# statusline.json. Throwing stops the install with the settings file untouched, which is the failure
# this whole table exists to make impossible.
function Format-SubagentCommand([string] $ScriptPath, $Decided) {
    $command = Format-ScriptCommand $ScriptPath
    foreach ($rec in Get-SubagentArgumentSpec) {
        $v = ([string] $Decided[$rec.Name].Value).ToLowerInvariant()
        if ($v -notin $rec.Allowed) {
            throw "Refusing to compose the subagentStatusLine command: -$($rec.Name) worked out to `"$v`", which is not one of $($rec.Allowed -join ', ')."
        }
        $command += " -$($rec.Name) $v"
    }
    return $command
}

# The size cap this installer reads statusline.json under. The same 65536 the status line's own
# Get-BoundedReadLimit uses, so a file the render path refuses to read is a file this refuses to read.
# Written out rather than imported because install.ps1 loads nothing from statusline.ps1; test.ps1
# compares the two numbers. A function rather than a script variable for the same reason the argument
# spec is one: test.ps1 lifts functions out of this file by name, and a constant would not come along.
function Get-StatusConfigReadLimit { return 65536 }

# One enum value out of statusline.json, folded to lower case, or $null when the file, the key or the
# value is not there or is not one of $Allowed - the same answer Merge-StatusConfigFile gives the same
# key.
#
# BOUNDED THE SAME WAY THE RENDER PATH IS, and for a reason that is not this installer's own safety.
# Read-BoundedFileText in statusline.ps1 refuses a config over 64 KiB and falls back to the defaults,
# so a file over the cap gives the BAR its defaults; if this read had no cap the PANEL would be
# installed with that file's values instead, and the one rule this feature exists to keep - the panel
# draws what the status line draws - would break on exactly the file that is hardest to notice.
# Same cap, same answer, both on the defaults.
#
# What is deliberately NOT copied is the 250 ms clock. That bound is there because a render may not
# block; an installer someone typed may wait, and a slow disk should hold this up rather than silently
# hand the panel a different answer from the bar's. So one divergence remains, stated rather than
# hidden: a config on a share slow enough to trip the render's clock but not this read leaves the bar
# on its defaults and the panel on the file's values. It needs a filesystem that answers in over 250 ms
# and a user who reinstalls while it is that slow, and closing it would mean a panel whose settings
# depend on how busy the disk was during the install.
function Read-StatusConfigEnum([string] $Path, [string] $Name, [string[]] $Allowed) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $obj = $null
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        # A directory, or anything without a length, is not a config file either.
        if ($item -isnot [System.IO.FileInfo] -or $item.Length -gt (Get-StatusConfigReadLimit)) { return $null }
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ($raw) { $obj = $raw | ConvertFrom-Json -ErrorAction Stop }
    } catch { return $null }
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $v = $obj.$Name
    if ($v -isnot [string]) { return $null }
    $v = $v.ToLowerInvariant()
    if ($v -notin $Allowed) { return $null }
    return $v
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

# Where a JSON settings file this installer writes keeps the version it replaced: settings.json here,
# and Windows Terminal's settings.json under -ConfigureWindowsTerminal. Not "$Path.bak": that is exactly
# the name a user's own tooling might already be using for the same file, and this installer overwrites
# it on every write without being asked. A name carrying this project's id instead is not one anyone
# else's tooling is likely to have picked already - the same reasoning behind $subagentRollback above -
# but a name alone is still not proof of ownership. JSON has no comment syntax to carry a marker line the
# way a .ps1 file does, and writing one into the JSON itself would mean the "backup" was no longer a
# faithful copy of what it replaced. So the marker lives beside the backup instead of inside it: a small
# sidecar file holding the SHA-256 of the backup's own content, written every time this installer writes
# the backup. Before the backup is ever overwritten, the sidecar is read back and compared against the
# backup file's actual hash; a match means this installer's own last write is still sitting there, and
# anything else - no sidecar, a sidecar that does not match, a file with no sidecar at all - is left
# alone.
function Get-JsonBackupPath([string] $Path) { return "$Path.claude-code-statusline-ps-rollback" }
function Get-BackupHashPath([string] $BackupPath) { return "$BackupPath.sha256" }

# Whether the file at $BackupPath is a backup this installer wrote and that has not been replaced since:
# its sidecar hash file has to exist and its content has to equal the SHA-256 of $BackupPath as it
# stands right now. A file that cannot be read, a sidecar that cannot be read, or a hash that does not
# match are all "not ours" - the same "a name alone is not proof" rule Test-OwnSubagentScript applies to
# the .ps1 rollback file, carried over to a shape JSON can actually hold.
function Test-OwnBackupFile([string] $BackupPath) {
    if (-not (Test-Path -LiteralPath $BackupPath)) { return $false }
    $hashPath = Get-BackupHashPath $BackupPath
    if (-not (Test-Path -LiteralPath $hashPath)) { return $false }
    $recorded = $null
    try { $recorded = Get-Content -LiteralPath $hashPath -Raw -ErrorAction Stop } catch { return $false }
    if ($null -eq $recorded) { return $false }
    $recorded = $recorded.Trim()
    if (-not $recorded) { return $false }
    $actual = $null
    try { $actual = (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash } catch { return $false }
    return [string]::Equals($recorded, $actual, [System.StringComparison]::OrdinalIgnoreCase)
}

# Copies $SourcePath over $BackupPath and records its hash in the sidecar next to it. $false, with
# neither file touched, in two cases: something already at $BackupPath fails Test-OwnBackupFile, or
# $BackupPath itself is missing while its sidecar is already there - an orphan sidecar is not proof of
# anything either, since there is no backup content left to check it against, so it is as unverifiable
# as a foreign one and is not written over. $false also, again with neither file left in a state that
# claims a backup that was not really taken, when the copy itself fails: a locked destination, a full
# disk, or any other reason Copy-Item cannot complete must not be reported as success by hashing
# whatever was already sitting at $BackupPath before the attempt. Losing the ability to roll back is a
# smaller harm than overwriting a file that was never this installer's, or claiming a rollback exists
# that does not, the same trade the subagent rollback copy makes.
function Backup-OwnedFile([string] $SourcePath, [string] $BackupPath) {
    $hashPath = Get-BackupHashPath $BackupPath
    if ((Test-Path -LiteralPath $BackupPath) -and -not (Test-OwnBackupFile $BackupPath)) { return $false }
    if ((-not (Test-Path -LiteralPath $BackupPath)) -and (Test-Path -LiteralPath $hashPath)) { return $false }
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $BackupPath -Force -ErrorAction Stop
    } catch {
        return $false
    }
    $hash = (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash
    Set-Content -LiteralPath $hashPath -Value $hash -Encoding UTF8 -NoNewline
    return $true
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
#   - the backup is taken from the file as it stands, before the replace, at the project-owned name
#     Get-JsonBackupPath names rather than "$Path.bak", and only when Backup-OwnedFile says it may be.
# What this does not do, stated plainly rather than implied away: a writer that does not take the lock
# can still save in the gap between that second comparison and the rename, and the rename replaces it.
# The gap is one filesystem operation wide and closing it would need a compare-and-swap the filesystem
# does not offer, or a lock every writer honours. The content that was replaced is in that backup, when
# there was one at $Path to replace and the backup name was this installer's to write.
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
        if (Test-Path -LiteralPath $Path) {
            $backupPath = Get-JsonBackupPath $Path
            if (-not (Backup-OwnedFile $Path $backupPath)) {
                Write-Warning "Kept: $backupPath does not carry this project's hash record, so the previous version of $Path was not backed up."
            }
        }
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
# it writes and nothing else: pwsh, then only the switches it passes, then -File, then one more
# argument, which has to BE the target path rather than merely contain it, and then only the arguments
# this installer puts on the panel - see the loop at the end - and then the end of the string.
# A substring test would claim `node wrapper.js "C:/.../subagent-statusline.ps1"` as ours and
# delete it, and that command never runs our script. An unquoted shell operator anywhere disqualifies
# the command too, because it means something is being chained that this installer did not write.
# There is no provenance field to lean on instead: the setting's schema is {type, command} and an
# unknown key in it is not something to rely on surviving.
#
# The tail used to be "exactly one argument and then nothing", which #78 had to widen so the style and
# the palette could ride on the command. Widened, not loosened: what follows the path is still only
# what this installer writes, still checked name by name and value by value against the same table the
# composer reads, so a switch nobody here writes, a value the panel does not have, a repeat, or a name
# with no value after it all still say "not ours". The alternative - checking the path and stopping -
# would have taken `pwsh -File our.ps1 -ExecutionPolicy Bypass -Command ...` as ours, and the strict
# tail is the only reason a command that runs our script under someone else's supervision is not.
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
    # One argument after -File, and it has to be the script itself.
    if ($parts.Count -lt $i + 2) { return $false }
    if (-not (Test-SamePath $parts[$i + 1].Text $ScriptPath)) { return $false }
    # Then only the panel's own arguments, each one a name this installer writes followed by a value
    # the panel has, at most once each, in either order, and then the end of the command.
    $i += 2
    $allowed = @{}
    foreach ($rec in Get-SubagentArgumentSpec) { $allowed[$rec.Name.ToLowerInvariant()] = $rec.Allowed }
    $seen = @{}
    while ($i -lt $parts.Count) {
        # Indexing the char rather than StartsWith: a leading Unicode Format character weighs nothing
        # in a culture comparison, so `StartsWith('-')` would answer yes for a name that does not begin
        # with one, and the whole job of this function is to be exact about the shape of a command.
        $name = $parts[$i].Text.ToLowerInvariant()
        if ($name.Length -lt 2 -or $name[0] -ne '-') { return $false }
        $name = $name.Substring(1)
        if (-not $allowed.ContainsKey($name) -or $seen.ContainsKey($name)) { return $false }
        if ($i + 1 -ge $parts.Count) { return $false }
        if ($parts[$i + 1].Text.ToLowerInvariant() -notin $allowed[$name]) { return $false }
        $seen[$name] = $true
        $i += 2
    }
    return $true
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

# Sets top-level keys in statusline.json and leaves every other key exactly as it was. The same
# atomic shape Write-UserSetting uses - serialize to a uniquely named sibling, read it back, then move
# it over the destination - because the status line reads this file on every render and a reader must
# never see a half-written one. No lock file: nothing else writes this file, and the render path only
# reads it. The file is reformatted by the round trip through ConvertTo-Json, which is a cosmetic
# change to a file the user may have laid out by hand, and is the price of not writing a JSON editor.
#
# A MAP OF KEYS RATHER THAN ONE KEY, so `style` and `palette` are one read-modify-write and one move.
# Called once per key this used to leave a window where the first key was committed and the second
# threw - a file saying `ascii` and `dark` when the install had decided `ascii` and `light`, with the
# subagentStatusLine command carrying the pair that was decided rather than the pair on disk. All the
# keys land or none of them do.
function Write-StatusConfigValue([string] $Path, $Values) {
    $obj = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -eq $obj -or $obj -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Refusing to write $Path : it did not read back as a JSON object."
    }
    foreach ($name in @($Values.Keys)) {
        if ($obj.PSObject.Properties[$name]) { $obj.$name = $Values[$name] }
        else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $Values[$name] }
    }
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

# ---- The style and the palette, decided here and used twice ----
# ONE RULE: the panel is installed with the style and the palette THE STATUS LINE WILL USE. The panel
# reads no config file, so its two settings ride on the subagentStatusLine command; deciding them here,
# above both writes, is what stops the command and statusline.json being installed disagreeing.
#
# The detection READ happens here rather than in the -DetectTheme block at the foot of this script,
# because its answer is an input to the command written below and that block runs after the settings
# write. Only the read moved: the write into statusline.json and the printed explanation are still down
# there, after the settings entry, so nothing about a guess at somebody's terminal can stand between a
# working install and the key that names it.
$themeFound = $null
$themeLuminance = $null
$themePalette = $null
if ($DetectTheme) {
    $themeFound = Get-SchemeBackground (Get-WindowsTerminalSettingPath)
    $themeLuminance = if ($themeFound.Background) { Get-BackgroundLuminance $themeFound.Background } else { $null }
    # 0.5 is the midpoint of the luminance scale rather than a tuned figure; see the -DetectTheme block.
    if ($null -ne $themeLuminance) { $themePalette = if ($themeLuminance -gt 0.5) { 'light' } else { 'dark' } }
}
# Precedence, highest first: the switch, because it is the user saying it in so many words; then the
# theme detection, which is about to write the same answer into statusline.json; then the file as it
# stands, which is what makes a hand-edited config reach the panel on the next install; then the
# shipped default. The file read is of the copy at its destination, so it sees the file that was just
# kept or installed rather than the repo's.
#
# Two things that file can say which this read does NOT follow, both stated rather than hidden.
# A `preset`, which stands for a layout and a style at once: `full` means powerline and the other two
# mean plain, and the panel draws all three of those identically, so following it would change nothing
# that is drawn. If a preset ever names `ascii` that stops being true and this has to read the preset
# table too. And a REPOSITORY's own .claude\statusline.json, which the status line merges over the user
# file per project: the panel is one command for the whole session and there is no per-project answer
# for it to carry, so it follows the user file and nothing else.
#
# One loop over the spec, one record per row, and every reader below iterates the same map: the
# statusline.json write, the command composer, and every line printed about either. Want says the
# switch was given; Write says this run puts the value into statusline.json (a switch, or the palette
# the detection worked out); Source names where the value came from, for the messages; Written and
# Error are filled in by the write and are what the messages are conditioned on, so nothing claims a
# key landed that did not.
$decided = [ordered]@{}
foreach ($rec in Get-SubagentArgumentSpec) {
    $want = $PSBoundParameters.ContainsKey($rec.Name)
    $value = $rec.Default
    $source = 'the built-in default'
    if ($want) {
        $value = ([string] $PSBoundParameters[$rec.Name]).ToLowerInvariant()
        $source = "-$($rec.Name)"
    } elseif ($rec.Detected -and $themePalette) {
        $value = $themePalette
        $source = 'theme detection'
    } else {
        $fromFile = Read-StatusConfigEnum $configTarget $rec.Key $rec.Allowed
        if ($fromFile) { $value = $fromFile; $source = "the `"$($rec.Key)`" key already in $configTarget" }
    }
    $decided[$rec.Name] = @{
        Name = $rec.Name; Key = $rec.Key; Want = $want; Source = $source
        # Requested is what this run decided to put in the file; Value is what the file turned out to
        # hold afterwards and is what the command carries. They differ exactly when a write failed,
        # which is the case the messages below have to be able to tell apart.
        Requested = $value; Value = $value
        Write = ($want -or ($rec.Detected -and $null -ne $themePalette)); Written = $false; Error = $null
    }
}

# ---- statusline.json first, THEN the command that has to agree with it ----
# The order is the whole point. The panel's command is a claim about what the status line will draw,
# and a claim written before the thing it describes can outlive it: this used to commit the pair into
# settings.json and only then try statusline.json, where the write could be skipped (no file) or throw
# and the run still exit 0, leaving a command promising `light` over a file that says `dark`.
# So the file is written here, the values are read back from it, and the command is composed from what
# the file NOW HOLDS. A write that fails leaves the file as it was and the command follows the file, so
# the two still agree - on the old value, which is the honest answer - and the failure is printed.
$configKeysToWrite = [ordered]@{}
foreach ($d in $decided.Values) { if ($d.Write) { $configKeysToWrite[$d.Key] = $d.Requested } }
if ($configKeysToWrite.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $configTarget)) {
        foreach ($d in $decided.Values) { if ($d.Write) { $d.Error = "there is no $configTarget to write it into" } }
    } else {
        try {
            Write-StatusConfigValue $configTarget $configKeysToWrite
            foreach ($d in $decided.Values) { if ($d.Write) { $d.Written = $true } }
        } catch {
            $why = $_.Exception.Message
            foreach ($d in $decided.Values) { if ($d.Write) { $d.Error = $why } }
        }
    }
}
# What the file holds now decides what the command says. A key that was written reads back as itself;
# one whose write failed reads back as whatever survived, and the command carries that rather than the
# value this run wanted. Anything the file cannot answer for falls back to the row's default, which is
# the same rule Merge-StatusConfigFile applies to the same key.
foreach ($rec in Get-SubagentArgumentSpec) {
    $onDisk = Read-StatusConfigEnum $configTarget $rec.Key $rec.Allowed
    $decided[$rec.Name].Value = if ($onDisk) { $onDisk } else { $rec.Default }
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
#
# WHEN THE ENTRY IS REWRITTEN, and it is not only under -Subagents. The command carries the style and
# the palette, so a run that changes either - `-Style ascii`, `-Palette light`, `-DetectTheme` - and
# leaves an installed panel entry alone would leave that entry describing a status line that no longer
# exists: the bar redrawn in ascii on the next render, the panel still on the pair it was installed
# with, and nothing said about it. So an entry that is ALREADY THIS INSTALLER'S is refreshed by any
# run, whether or not -Subagents was passed. Ownership is the whole test, and it is the same
# Test-OwnSubagentEntry -Uninstall uses: an entry someone else wrote is not ours to rewrite any more
# than it is ours to delete. Only -Subagents CREATES one, so a user who has never asked for the panel
# still gets no key.
$panelOwned = $s.PSObject.Properties['subagentStatusLine'] -and (Test-OwnSubagentEntry $s.subagentStatusLine $subagentTarget)
$panelForeign = $s.PSObject.Properties['subagentStatusLine'] -and -not $panelOwned
if ($Subagents -or $panelOwned) {
    $subagentEntry = [pscustomobject]@{ type = 'command'; command = (Format-SubagentCommand $subagentTarget $decided) }
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
if ($Subagents -or $panelOwned) {
    $pair = (@(Get-SubagentArgumentSpec | ForEach-Object { "$($_.Key) $($decided[$_.Name].Value)" }) -join ', ')
    $verb = if ($Subagents) { 'Configured' } else { 'Refreshed' }
    $why = if ($Subagents) { '' } else { ' (it is this installer''s, and the pair it carried is no longer what the status line uses)' }
    Write-Host "$verb subagentStatusLine in $settingsPath ($pair)$why"
} elseif ($panelForeign) {
    Write-Warning "Kept: the subagentStatusLine entry in $settingsPath is not this installer's, so the style and palette on it were left alone."
}
} finally {
    # A staged file still under its temporary name means the install did not finish; it is this script's
    # to clean up either way.
    if ($subagentStaged -and (Test-Path -LiteralPath $subagentStaged)) { Remove-Item -LiteralPath $subagentStaged -Force -ErrorAction SilentlyContinue }
}

# What the statusline.json write above actually did, one line per key that was meant to change, read
# off the outcome rather than assumed from the intent. The write itself happened before the settings
# entry, because the command has to be composed from the file; the REPORTING is here, after the
# install, so a line about a config key never sits between a working install and the entry naming it.
# A switch is written because it was asked for; the detected palette is written only when no -Palette
# said otherwise; and a key whose write failed says so and says what the command carries instead.
foreach ($rec in Get-SubagentArgumentSpec) {
    $d = $decided[$rec.Name]
    if (-not $d.Write) { continue }
    # The -DetectTheme block below tells the whole story for the row it decides - what it found, what it
    # chose and what became of the write - so this loop does not say half of it first.
    if ($DetectTheme -and $rec.Detected) { continue }
    if ($d.Written) {
        Write-Host "Wrote `"$($d.Key)`": `"$($d.Value)`" to $configTarget; every other key was kept."
    } else {
        Write-Warning "$($d.Source) asked for `"$($d.Key)`": `"$($d.Requested)`", but $($d.Error). The subagentStatusLine command follows the file, so it carries `"$($d.Value)`" instead."
    }
}

if ($DetectTheme) {
    # The read is up above, because its answer is an input to the subagentStatusLine command; what is
    # left here is the write and the explanation. Every branch below ends in a printed line: the answer
    # is a guess about somebody's terminal and the only thing that makes a guess safe is saying it out
    # loud. 0.5 is the midpoint of the luminance scale rather than a tuned figure, and it does not need
    # to be tuned: every scheme Windows Terminal ships is under 0.05 or over 0.85, so the cut sits in an
    # empty band. The scheme name is printed beside the number because THIS IS A READ OF A
    # CONFIGURATION, NOT A LOOK AT YOUR SCREEN - a session in conhost, VS Code, an SSH client or a
    # profile that is not the default one is a terminal this never saw.
    # The write is up above too, in the one batch that puts every decided key in the file at once; what
    # is left here is the explanation, and EVERY BRANCH READS THE OUTCOME rather than restating the
    # intent. "-Palette was given, so that is what was written" was printed unconditionally before this,
    # including on runs where the write was skipped for want of a file or had thrown - the one line a
    # user would check to find out what happened, saying the opposite of what did.
    $found = $themeFound
    $lum = $themeLuminance
    $p = $decided['Palette']
    $landed = if ($p.Written) { "Wrote `"palette`": `"$($p.Requested)`" to $configTarget; every other key was kept." }
              else { "Nothing was written: $($p.Error). $configTarget still says `"$($p.Value)`"." }
    if ($p.Want) {
        # -Palette is the user saying in so many words what the detection was there to guess, so the
        # guess does not overwrite it. It is still reported: a probe silenced without a word is a probe
        # nobody can check, and the two answers disagreeing is worth seeing.
        $saw = if ($null -ne $lum) { "would have chosen $themePalette from colour scheme `"$($found.Scheme)`"" } else { "could not tell: $($found.Reason)" }
        Write-Host "Theme detection: -Palette $($p.Requested) was given, so the detection did not decide this. Detection $saw. $landed"
    } elseif ($null -eq $lum) {
        Write-Host "Theme detection: $($found.Reason). Nothing was written, so $configTarget keeps the palette it had - dark unless you have set one. Set `"palette`" to `"light`" in that file by hand if your terminal has a pale background."
    } else {
        Write-Host ("Theme detection: Windows Terminal's default profile uses colour scheme `"{0}`" ({1}), whose background {2} has a relative luminance of {3:N3}, so it chose `"{4}`". {5}" -f $found.Scheme, $found.Reason, $found.Background, $lum, $p.Requested, $landed)
        if ($p.Written) { Write-Host "  If that is not the terminal you use Claude Code in, edit that one key." }
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
        # Same treatment as settings.json: a project-owned backup name, not "$wt.bak-before-nerdfont" -
        # a name distinctive enough that a collision is unlikely, but the shape of the risk is the same
        # one Write-UserSetting guards against, so it gets the same guard. A foreign file at the backup
        # name does not block the font change itself; it only means this run has nothing to roll back to.
        $wtBackupPath = Get-JsonBackupPath $wt
        $wtBackedUp = Backup-OwnedFile $wt $wtBackupPath
        if (-not $wtBackedUp) {
            Write-Warning "Kept: $wtBackupPath does not carry this project's hash record, so $wt was not backed up before this change."
        }
        $j = Get-Content $wt -Raw | ConvertFrom-Json
        if (-not $j.profiles.defaults) { $j.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{}) }
        if (-not $j.profiles.defaults.font) { $j.profiles.defaults | Add-Member -NotePropertyName font -NotePropertyValue ([pscustomobject]@{}) -Force }
        $j.profiles.defaults.font | Add-Member -NotePropertyName face -NotePropertyValue $fontFace -Force
        $j | ConvertTo-Json -Depth 32 | Set-Content $wt -Encoding UTF8
        if ($wtBackedUp) {
            Write-Host "Windows Terminal default font set to '$fontFace' (backup kept at $wtBackupPath)"
        } else {
            Write-Host "Windows Terminal default font set to '$fontFace' (no backup written; see warning above)"
        }
    }
}

Write-Host ''
Write-Host 'Done. Claude Code picks the status line up on its next refresh or session start.'
Write-Host "If icons render as boxes, set your terminal font to '$fontFace' (or any Nerd Font)."
