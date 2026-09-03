#Requires -Version 7.0
# Claude Code status line (PowerShell 7) with Nerd Font glyphs and ANSI colour.
# Requires a Nerd Font in the terminal (install.ps1 can set up JetBrainsMono Nerd Font).
# Reads the JSON Claude Code pipes on stdin and prints one or two lines, e.g.
#   󰚩 Fable 5.1  󰍛 37% ████░░░░░░   $0.43   my-project   main
# Layout, separator style and segment toggles come from statusline.json next to this script.
# Glyphs are emitted from code points so the file's own encoding never matters.
[CmdletBinding()]
param(
    # Path to the config file. Defaults to statusline.json beside this script. Claude Code never passes it.
    [string] $Config
)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# PowerShell strips ANSI colour when stdout is redirected unless told otherwise; the host always redirects it.
$PSStyle.OutputRendering = 'Ansi'

function G([int] $cp) { [char]::ConvertFromUtf32($cp) }
$e = [char]27
function C([string] $code, [string] $text) { "$e[${code}m$text$e[0m" }

$iconModel  = G 0xF06A9   # nf-md-robot
$iconCtx    = G 0xF035B   # nf-md-memory
$iconCost   = G 0xF0155   # nf-md-cash
$iconFolder = G 0xF07C    # nf-fa-folder_open
$iconChevron = G 0x203A   # single right-pointing angle quotation mark (between owner/name and the leaf)
$iconBranch = G 0xE0A0    # powerline branch
$iconHome   = G 0xF015    # nf-fa-home  (on main/master)
$iconDirty  = G 0xF040    # nf-fa-pencil (uncommitted changes)
$iconAhead  = G 0x2191    # up arrow (commits ahead of upstream)
$iconBehind = G 0x2193    # down arrow (commits behind upstream)
$iconConflict = G 0xF071  # nf-fa-exclamation_triangle (merge conflicts)
$iconPr     = G 0xF407    # nf-oct-git_pull_request
$iconLines  = G 0xF121    # nf-fa-code  (lines added/removed)
$iconLimit  = G 0xF0E4    # nf-fa-tachometer (rate limits)
$iconFast   = G 0xF0E7    # nf-fa-bolt  (fast mode)
$iconThink  = G 0xF09D0   # nf-md-brain (extended thinking)
$iconEffort = G 0xF04C5   # nf-md-speedometer (effort level)
$iconVim    = G 0xE62B    # nf-custom-vim
$defaultEffort = 'high'   # effort badge is hidden at this level

$gitTimeoutMs = 1500      # how long the branch segment waits for `git status` before giving up

# Visible cell width of a rendered line: escapes stripped, combining marks 0, CJK and emoji 2, else 1.
# A small wcwidth approximation; Nerd Font glyphs count as 1. The OSC 8 hyperlink wrappers go first,
# with either terminator (ESC \ or BEL), so a URL is never counted as text; then the SGR colour codes.
function Get-VisibleWidth([string] $Text) {
    if (-not $Text) { return 0 }
    $plain = [regex]::Replace($Text, "`e\]8;[^`a`e]*(?:`a|`e\\)", '')
    $plain = [regex]::Replace($plain, "`e\[[0-9;]*m", '')
    $width = 0
    $en = [System.Globalization.StringInfo]::GetTextElementEnumerator($plain)
    while ($en.MoveNext()) {
        $el = [string] $en.Current
        $cp = try { [char]::ConvertToUtf32($el, 0) } catch { 0x3F }
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($cp)
        if ($cat -eq [System.Globalization.UnicodeCategory]::NonSpacingMark -or
            $cat -eq [System.Globalization.UnicodeCategory]::SpacingCombiningMark -or
            $cat -eq [System.Globalization.UnicodeCategory]::EnclosingMark -or
            ($cp -ge 0x200B -and $cp -le 0x200D) -or $cp -eq 0xFE0F) { continue }
        if (($cp -ge 0x1100 -and $cp -le 0x115F) -or ($cp -ge 0x2E80 -and $cp -le 0xA4CF) -or
            ($cp -ge 0xAC00 -and $cp -le 0xD7A3) -or ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or
            ($cp -ge 0xFE30 -and $cp -le 0xFE4F) -or ($cp -ge 0xFF00 -and $cp -le 0xFF60) -or
            ($cp -ge 0xFFE0 -and $cp -le 0xFFE6) -or ($cp -ge 0x20000 -and $cp -le 0x3FFFD) -or
            ($cp -ge 0x1F300 -and $cp -le 0x1F64F) -or ($cp -ge 0x1F680 -and $cp -le 0x1F6FF) -or
            ($cp -ge 0x1F900 -and $cp -le 0x1FAFF) -or ($cp -ge 0x2600 -and $cp -le 0x27BF)) { $width += 2; continue }
        $width += 1
    }
    return $width
}

# The segment table: one record per segment, in layout-one order. It is the single source for the config
# defaults, the shrink and drop order in Get-FittedLine, the build dispatch and the layout-two rows.
# Build names the builder function; the build loop calls it with the payload and the config, and a builder
# that only takes the payload leaves the config in $args. It returns the segment record or $null. Default
# seeds Read-StatusConfig. ShrinkRank orders stage one of Get-FittedLine for the segments that can have a
# Short form; a record whose Short is $null is skipped there. DropRank orders stage two, and the model
# record has none because it is never dropped.
# Row is the layout-two line and RowRank the position on it, because a row is not in layout-one order.
# The table is built once per run: a render asks for it several times, and this is on the startup path.
function Get-SegmentRegistry {
    if (-not $script:segmentRegistry) {
        $script:segmentRegistry = @(
            @{ Name = 'model';   Build = 'Get-ModelSegment';   Default = $true; ShrinkRank = $null; DropRank = $null; Row = 1; RowRank = 1 }
            @{ Name = 'context'; Build = 'Get-ContextSegment'; Default = $true; ShrinkRank = 2;     DropRank = 8;     Row = 2; RowRank = 1 }
            @{ Name = 'cost';    Build = 'Get-CostSegment';    Default = $true; ShrinkRank = $null; DropRank = 3;     Row = 2; RowRank = 3 }
            @{ Name = 'lines';   Build = 'Get-LinesSegment';   Default = $true; ShrinkRank = $null; DropRank = 1;     Row = 2; RowRank = 4 }
            @{ Name = 'limits';  Build = 'Get-LimitsSegment';  Default = $true; ShrinkRank = 1;     DropRank = 4;     Row = 2; RowRank = 2 }
            @{ Name = 'badges';  Build = 'Get-BadgesSegment';  Default = $true; ShrinkRank = $null; DropRank = 2;     Row = 1; RowRank = 5 }
            @{ Name = 'pr';      Build = 'Get-PrSegment';      Default = $true; ShrinkRank = $null; DropRank = 5;     Row = 1; RowRank = 4 }
            @{ Name = 'folder';  Build = 'Get-FolderSegment';  Default = $true; ShrinkRank = 4;     DropRank = 6;     Row = 1; RowRank = 2 }
            @{ Name = 'branch';  Build = 'Get-BranchSegment';  Default = $true; ShrinkRank = 3;     DropRank = 7;     Row = 1; RowRank = 3 }
        )
    }
    return $script:segmentRegistry
}

# Segment names sorted by one of the registry's rank keys, skipping records where it is $null. A row
# number limits the list to that layout-two row. Ranks are dense, 1 to N within the list asked for, so
# the names are dropped into slots by rank and read back in order: a plain loop over a hashtable, because
# this runs before the first line is printed and a cold pipeline, generic list or [array]::Sort each cost
# several milliseconds the first time.
function Get-SegmentOrder([ValidateSet('ShrinkRank', 'DropRank', 'RowRank')] [string] $Rank, [int] $Row = 0) {
    $slots = @{}
    foreach ($rec in Get-SegmentRegistry) {
        if ($null -ne $rec[$Rank] -and ($Row -eq 0 -or $rec.Row -eq $Row)) { $slots[$rec[$Rank]] = $rec.Name }
    }
    return @(for ($i = 1; $i -le $slots.Count; $i++) { $slots[$i] })
}

# Reads statusline.json. Anything missing or invalid silently falls back to its default.
function Read-StatusConfig([string] $Path) {
    $cfg = @{ Layout = 'one'; Style = 'plain'; Folder = 'repo'; State = $true; Segments = @{} }
    foreach ($rec in Get-SegmentRegistry) { $cfg.Segments[$rec.Name] = $rec.Default }
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $cfg }
        $j = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($j -isnot [System.Management.Automation.PSCustomObject]) { return $cfg }
        if ($j.layout -is [string] -and $j.layout.ToLowerInvariant() -in @('one', 'two')) { $cfg.Layout = $j.layout.ToLowerInvariant() }
        if ($j.style -is [string] -and $j.style.ToLowerInvariant() -in @('plain', 'powerline')) { $cfg.Style = $j.style.ToLowerInvariant() }
        if ($j.folder -is [string] -and $j.folder.ToLowerInvariant() -in @('repo', 'leaf')) { $cfg.Folder = $j.folder.ToLowerInvariant() }
        if ($j.state -is [bool]) { $cfg.State = $j.state }
        $segs = $j.segments
        if ($segs -is [System.Management.Automation.PSCustomObject]) {
            foreach ($n in @($cfg.Segments.Keys)) {
                $v = $segs.$n
                if ($v -is [bool]) { $cfg.Segments[$n] = $v }
            }
        }
    } catch { return $cfg }
    return $cfg
}

# Colour table. Plain style uses the SGR codes the script has always used; powerline uses 256-colour
# foreground/background pairs so blocks look the same on every terminal theme.
function Get-Palette {
    return @{
        Roles = @{
            model  = @{ Sgr = '1;36'; Fg = 231; Bg = 31 }
            ok     = @{ Sgr = '32';   Fg = 231; Bg = 28 }
            warn   = @{ Sgr = '33';   Fg = 16;  Bg = 178 }
            bad    = @{ Sgr = '31';   Fg = 231; Bg = 160 }
            dim    = @{ Sgr = '90';   Fg = 250; Bg = 238 }
            folder = @{ Sgr = '34';   Fg = 231; Bg = 25 }
            branch = @{ Sgr = '35';   Fg = 231; Bg = 90 }
        }
        Inline = @{
            added   = @{ Sgr = '32'; Fg = 46 }
            removed = @{ Sgr = '31'; Fg = 203 }
            track   = @{ Sgr = '90'; Fg = 245 }
            muted   = @{ Sgr = '22;36'; Fg = 152 }
        }
    }
}

# A foreground-only colour change inside a segment that restores the segment's own foreground afterwards,
# so a powerline background is never interrupted by a reset.
function Format-Inline([string] $Role, [string] $Text, [string] $SegmentRole, [string] $Style) {
    $pal = Get-Palette
    if ($Style -eq 'powerline') { return "`e[38;5;$($pal.Inline[$Role].Fg)m$Text`e[38;5;$($pal.Roles[$SegmentRole].Fg)m" }
    return "`e[$($pal.Inline[$Role].Sgr)m$Text`e[$($pal.Roles[$SegmentRole].Sgr)m"
}

# Wraps text in an OSC 8 hyperlink, ESC ] 8 ; ; url ESC \ text ESC ] 8 ; ; ESC \, which a terminal that
# understands it (Windows Terminal on ctrl-click) opens. The text comes back unchanged for an empty url,
# one that is not http or https, or one holding any Unicode control character (category Cc: the C0
# range, DEL and the C1 range, where U+009B, U+009C and U+009D are CSI, ST and OSC in their 8-bit
# forms), so nothing a payload puts there can end the sequence early or put a stray escape on the line.
# The link goes into the segment's Text, so Format-Line wraps it in the segment's colour codes in either
# style: OSC 8 carries no SGR state, so a powerline background runs on through it, and Get-VisibleWidth
# strips it before measuring.
function Format-Link([string] $Url, [string] $Text) {
    if (-not $Url -or $Url -notmatch '^https?://' -or $Url -match '\p{Cc}') { return $Text }
    return "`e]8;;$Url`e\$Text`e]8;;`e\"
}

# Renders an ordered list of segment records as one line in the given style.
function Format-Line($Segments, [string] $Style) {
    $segs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($s in $Segments) { if ($s) { $segs.Add($s) } }
    if ($segs.Count -eq 0) { return '' }
    $pal = Get-Palette
    if ($Style -eq 'powerline') {
        $arrow = [char]::ConvertFromUtf32(0xE0B0)
        $sb = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt $segs.Count; $i++) {
            $s = $segs[$i]
            $c = $pal.Roles[$s.Role]
            $bold = if ($s.Bold) { '1;' } else { '' }
            [void] $sb.Append("`e[0;${bold}48;5;$($c.Bg);38;5;$($c.Fg)m $($s.Text) ")
            if ($i -lt $segs.Count - 1) {
                $n = $pal.Roles[$segs[$i + 1].Role]
                [void] $sb.Append("`e[38;5;$($c.Bg);48;5;$($n.Bg)m$arrow")
            } else {
                [void] $sb.Append("`e[0m`e[38;5;$($c.Bg)m$arrow`e[0m")
            }
        }
        return $sb.ToString()
    }
    $sep = " `e[90m$([char]::ConvertFromUtf32(0xE0B1))`e[0m "
    $parts = foreach ($s in $segs) { $c = $pal.Roles[$s.Role]; "`e[$($c.Sgr)m$($s.Text)`e[0m" }
    return ($parts -join $sep)
}

# Renders a line and, when a width is given, shrinks then drops segments until it fits.
# Stage 1 swaps segments for their Short form in $ShrinkOrder (limits, context, branch, then folder by default).
# Stage 2 drops whole segments in $DropOrder. Either order left $null comes from the registry's ranks; an
# empty array skips that stage. The model segment is never dropped whatever the drop order says, so it may
# overflow on its own. Returns $null when nothing is left.
function Get-FittedLine($Segments, [string] $Style, $Width, [string[]] $ShrinkOrder = $null, [string[]] $DropOrder = $null) {
    $segs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($s in $Segments) { if ($s) { $segs.Add($s.Clone()) } }
    if ($segs.Count -eq 0) { return $null }
    $line = Format-Line $segs $Style
    if ($null -eq $Width) { return $line }
    $target = [int] $Width
    if ((Get-VisibleWidth $line) -le $target) { return $line }
    if ($null -eq $ShrinkOrder) { $ShrinkOrder = Get-SegmentOrder 'ShrinkRank' }
    if ($null -eq $DropOrder) { $DropOrder = Get-SegmentOrder 'DropRank' }
    foreach ($name in $ShrinkOrder) {
        for ($i = 0; $i -lt $segs.Count; $i++) {
            if ($segs[$i].Name -eq $name -and $segs[$i].Short) {
                $segs[$i].Text = $segs[$i].Short
                $line = Format-Line $segs $Style
                if ((Get-VisibleWidth $line) -le $target) { return $line }
            }
        }
    }
    foreach ($name in $DropOrder) {
        if ($name -eq 'model') { continue }
        $at = -1
        for ($i = 0; $i -lt $segs.Count; $i++) { if ($segs[$i].Name -eq $name) { $at = $i } }
        if ($at -lt 0) { continue }
        $segs.RemoveAt($at)
        if ($segs.Count -eq 0) { return $null }
        $line = Format-Line $segs $Style
        if ((Get-VisibleWidth $line) -le $target) { return $line }
    }
    return $line
}

# Parses `git status --porcelain=v1 --branch` output. $null when the header line is missing.
# Ahead and Behind come from the header's bracket ([ahead 1], [behind 2], [ahead 1, behind 2]); no bracket
# or [gone] means 0 and 0. Every later line starts with two status columns, XY, and is counted as
# staged (X set and not a conflict), modified (Y set: M, D, T, or A for an intent-to-add file), untracked
# (??) or a conflict (the unmerged pairs: U in either column, DD or AA). A file can be both staged and
# modified. Dirty is true when any count is above zero.
function Read-PorcelainStatus([string] $Text) {
    if (-not $Text) { return $null }
    $lines = $Text -split "`r?`n"
    if (-not $lines[0].StartsWith('## ')) { return $null }
    $head = $lines[0].Substring(3)
    $branch = if ($head -eq 'HEAD (no branch)') { 'detached' }
    elseif ($head -match '^(No commits yet|Initial commit) on (.+)$') { ($Matches[2] -split '\.\.\.', 2)[0] }
    else { ($head -split '\.\.\.', 2)[0] }
    $ahead = 0
    $behind = 0
    if ($head -match '\[(?:ahead (\d+))?(?:, )?(?:behind (\d+))?\]') {
        if ($Matches[1]) { $ahead = [int] $Matches[1] }
        if ($Matches[2]) { $behind = [int] $Matches[2] }
    }
    $staged = 0
    $modified = 0
    $untracked = 0
    $conflicts = 0
    # Porcelain v1 keeps the leading space of " M file", so the columns are read from the raw line. An
    # index loop with char tests rather than a pipeline: this runs once per entry, and a large unignored
    # tree has thousands of them.
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Length -lt 2 -or -not $line.Trim()) { continue }
        $x = $line[0]
        $y = $line[1]
        if ($x -eq '!') { continue }
        if ($x -eq 'U' -or $y -eq 'U' -or ($x -eq 'D' -and $y -eq 'D') -or ($x -eq 'A' -and $y -eq 'A')) { $conflicts++; continue }
        if ($x -eq '?') { $untracked++; continue }
        if ($x -ne ' ') { $staged++ }
        if ($y -ne ' ') { $modified++ }
    }
    $dirty = ($staged + $modified + $untracked + $conflicts) -gt 0
    return @{ Branch = $branch; Dirty = $dirty; Ahead = $ahead; Behind = $behind
              Staged = $staged; Modified = $modified; Untracked = $untracked; Conflicts = $conflicts }
}

# Runs git status in $Dir with a hard timeout. Any failure, or no git on PATH, returns $null.
# Stdout and stderr are drained on .NET threads so a long listing cannot fill the pipe and stall git.
function Get-GitBranch([string] $Dir, [int] $TimeoutMs) {
    if (-not $Dir) { return $null }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    $git = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $git) { return $null }
    $p = $null
    $outTask = $null
    $errTask = $null
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($git)
        foreach ($a in @('-C', $Dir, 'status', '--porcelain=v1', '--branch')) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.Environment['GIT_OPTIONAL_LOCKS'] = '0'
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $exited = $p.WaitForExit($TimeoutMs)
        if (-not $exited) {
            # Kill the whole tree, then give it a moment to actually go away before we dispose the handles.
            try { $p.Kill($true) } catch { $null = $_ }
            [void] $p.WaitForExit(100)
        }
        # Bounded waits on both drains: the full timeout after a clean exit, so a slow reader cannot cost
        # us the branch, and a short grace after a kill, where the result is discarded anyway. A faulted
        # task is observed here rather than left to the finalizer.
        $drainMs = if ($exited) { $TimeoutMs } else { 100 }
        try { [void] [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), $drainMs) } catch { $null = $_ }
        if (-not $exited) { return $null }
        if (-not $outTask.IsCompletedSuccessfully) { return $null }
        if ($p.ExitCode -ne 0) { return $null }
        return Read-PorcelainStatus $outTask.Result
    } catch { return $null }
    finally {
        # Disposing closes the redirected streams, so it is only safe once both drains have finished. The
        # bounded wait after a kill can return with a ReadToEndAsync still pending; disposing then would
        # pull the reader out from under it. In that case leave the handles alone - the script exits a few
        # milliseconds later and the operating system reclaims them.
        if ($p -and $outTask -and $errTask -and $outTask.IsCompleted -and $errTask.IsCompleted) { $p.Dispose() }
    }
}

# A payload or state field as a finite double, or $null when it is not a number at all: missing, a
# boolean, a string, an array, NaN or infinite. This is the one guard behind Get-PayloadNumber and
# Get-StateNumber, each of which then applies its own rule to the result - a count that fits an Int32,
# or a figure floored to a long. It sits here because the script runs top to bottom and both callers
# are below.
function Get-FiniteNumber($v) {
    if (-not ($v -is [ValueType]) -or $v -is [bool]) { return $null }
    $n = try { [double] $v } catch { return $null }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $null }
    return $n
}

# ---- Per-session state ----
# Each render is a fresh process that sees one payload, so a small JSON file per session keeps the last
# cost, token totals and a short cost history for the next render to compare against. Nothing on the line
# reads it yet, and the read, merge and write all happen after the line is printed. Every failure here is
# silent: no directory, no file, no state, and the line is unchanged.

# The state directory: claude-statusline-state under TEMP, or ~/.claude/statusline-state when TEMP is
# empty. Created only when $Create is set, which the write path does. $null when it is not there and
# cannot be made, including when a file sits at its path.
function Get-SessionStateDir([bool] $Create) {
    try {
        $dir = if ($env:TEMP) { Join-Path $env:TEMP 'claude-statusline-state' } else { Join-Path $HOME '.claude' 'statusline-state' }
        if (-not [System.IO.Directory]::Exists($dir)) {
            if (-not $Create) { return $null }
            [void] [System.IO.Directory]::CreateDirectory($dir)
        }
        return $dir
    } catch { return $null }
}

# The file for a session, <name>.json. When the id is already lower-case, at most 64 characters and has
# nothing outside [A-Za-z0-9_.-] (a UUID), the id is the name. Any other id would not name itself
# uniquely: stripping or cutting gives two ids one file (`a/b` and `ab`, or two long ids with the same
# first 64 characters), and so does case alone, because the file system folds it (`A1` and `a1`). Such
# an id gets the lower-cased readable part, cut to 47 characters, a hyphen, and the first 16 hex
# characters of the SHA-256 of the whole original id; the hash alone when nothing readable is left.
# Slashes are never kept, so an id cannot name a path outside the directory. $null for an empty id or
# when there is no directory.
function Get-SessionStatePath([string] $SessionId, [bool] $Create) {
    if (-not $SessionId) { return $null }
    $name = [regex]::Replace($SessionId, '[^A-Za-z0-9_.-]', '')
    if ($name -cne $SessionId.ToLowerInvariant() -or $name.Length -gt 64) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($SessionId)) } finally { $sha.Dispose() }
        $hash = [BitConverter]::ToString($digest, 0, 8).Replace('-', '').ToLowerInvariant()
        $prefix = $name.ToLowerInvariant()
        if ($prefix.Length -gt 47) { $prefix = $prefix.Substring(0, 47) }
        $name = if ($prefix) { "$prefix-$hash" } else { $hash }
    }
    $dir = Get-SessionStateDir $Create
    if (-not $dir) { return $null }
    return Join-Path $dir "$name.json"
}

# A payload or state value as a figure, or $null when Get-FiniteNumber says it is not a number.
# With -Whole the result is floored to a long, and $null when it would not fit one.
function Get-StateNumber($v, [switch] $Whole) {
    $n = Get-FiniteNumber $v
    if ($null -eq $n) { return $null }
    if (-not $Whole) { return $n }
    if ([math]::Abs($n) -gt 9e15) { return $null }
    return [long] [math]::Floor($n)
}

# The state last written for a session, as a hashtable with the schema's keys, or $null for no file,
# unreadable JSON, or a version other than 1. Each figure is a number or $null; history entries without
# both a time and a cost are dropped.
function Read-SessionState([string] $SessionId) {
    try {
        $path = Get-SessionStatePath $SessionId $false
        if (-not $path -or -not [System.IO.File]::Exists($path)) { return $null }
        $j = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        if ($j -isnot [System.Management.Automation.PSCustomObject] -or (Get-StateNumber $j.v) -ne 1) { return $null }
        $history = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($h in @($j.history)) {
            $t = Get-StateNumber $h.t -Whole
            $c = Get-StateNumber $h.cost_usd
            if ($null -ne $t -and $null -ne $c) { $history.Add(@{ t = $t; cost_usd = $c }) }
        }
        $state = @{ v = 1; history = @($history) }
        foreach ($key in @('updated_at', 'input_tokens', 'output_tokens')) { $state[$key] = Get-StateNumber $j.$key -Whole }
        foreach ($key in @('cost_usd', 'used_percentage', 'five_hour_percentage')) { $state[$key] = Get-StateNumber $j.$key }
        return $state
    } catch { return $null }
}

# The next state for a session: the payload's figures now, and the history ring carried over from the
# previous state with a new entry when the cost moved (a first render counts as moved). The ring keeps
# the newest 20. Keys are in schema order so the file always reads the same way.
# The comparison is against the last entry in the ring, not against the previous record's cost_usd: a
# payload can arrive with no cost object at all (the minimal sample is that shape), which stores a null
# cost, and comparing against that null would re-append an unchanged cost on the render after it.
function Merge-SessionState($Previous, $Payload, [long] $Now) {
    $cost = Get-StateNumber $Payload.cost.total_cost_usd
    $history = [System.Collections.Generic.List[hashtable]]::new()
    if ($Previous) {
        foreach ($h in @($Previous.history)) { if ($h) { $history.Add($h) } }
    }
    $last = if ($history.Count -gt 0) { Get-StateNumber $history[$history.Count - 1].cost_usd } else { $null }
    if ($null -ne $cost -and $cost -ne $last) { $history.Add(@{ t = $Now; cost_usd = $cost }) }
    while ($history.Count -gt 20) { $history.RemoveAt(0) }
    $ctx = $Payload.context_window
    return [ordered]@{
        v = 1
        updated_at = $Now
        cost_usd = $cost
        input_tokens = Get-StateNumber $ctx.total_input_tokens -Whole
        output_tokens = Get-StateNumber $ctx.total_output_tokens -Whole
        used_percentage = Get-StateNumber $ctx.used_percentage
        five_hour_percentage = Get-StateNumber $Payload.rate_limits.five_hour.used_percentage
        history = @($history)
    }
}

# Housekeeping, at most once per six hours per directory: a .sweep stamp marks the last finished pass.
# When it is missing or older than six hours, state files not written for a day are deleted, at most 200
# in one pass. A pass that hits the cap leaves the stamp alone, so the next render carries on with the
# backlog instead of draining 200 files every six hours. Ages are absolute, so a stamp or a file dated
# in the future - a clock change, a restored backup - reads as stale rather than as freshly written,
# which would park housekeeping until the wall clock caught up.
# The common render pays for one stat of the stamp and nothing else.
function Invoke-SessionStateSweep([string] $Dir) {
    try {
        $stamp = Join-Path $Dir '.sweep'
        $now = [DateTime]::UtcNow
        if ([System.IO.File]::Exists($stamp) -and [math]::Abs(($now - [System.IO.File]::GetLastWriteTimeUtc($stamp)).TotalHours) -lt 6) { return }
        $deleted = 0
        $capped = $false
        foreach ($f in [System.IO.Directory]::EnumerateFiles($Dir, '*.json')) {
            if ($deleted -ge 200) { $capped = $true; break }
            if ([math]::Abs(($now - [System.IO.File]::GetLastWriteTimeUtc($f)).TotalDays) -lt 1) { continue }
            try { [System.IO.File]::Delete($f); $deleted++ } catch { $null = $_ }
        }
        if (-not $capped) { [System.IO.File]::WriteAllText($stamp, '') }
    } catch { $null = $_ }
}

# Writes a session's state as compact JSON, then runs the sweep. Nothing is written for an empty record,
# an id that leaves no file name, or JSON that would not serialise - a half-written or empty file would
# cost the whole ring rather than one delta, so the record goes to a sibling .tmp file and is moved over
# the real one, which is atomic on both Windows and Linux. Every failure is swallowed: the line has
# already been printed. Concurrent renders of one session still race, and the last writer wins; a lock
# file is out of scope for the same reason, the cost of losing is one missing delta.
function Write-SessionState([string] $SessionId, $State) {
    try {
        if (-not $State) { return }
        $path = Get-SessionStatePath $SessionId $true
        if (-not $path) { return }
        $json = ConvertTo-Json -InputObject $State -Depth 4 -Compress -ErrorAction Stop
        if (-not $json) { return }
        $tmp = "$path.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tmp, $path, $true)
        Invoke-SessionStateSweep (Split-Path $path -Parent)
    } catch { $null = $_ }
}

$raw = [Console]::In.ReadToEnd()
try { $d = $raw | ConvertFrom-Json } catch { Write-Host (C '36' "$iconModel claude"); exit 0 }

$configPath = if ($Config) { $Config } else { Join-Path $PSScriptRoot 'statusline.json' }
$cfg = Read-StatusConfig $configPath

# ---- Segment builders. Each returns $null (segment omitted) or @{ Name; Text; Short; Role; Bold }. ----

# Colour bands for a percentage. The defaults suit a 200k window; a 1M window passes wider bands, because
# 85% of 1M still leaves 150k tokens, more than a whole fresh 200k session.
function Get-ThresholdRole([int] $pct, [int] $Warn = 60, [int] $Bad = 85) { if ($pct -ge $Bad) { 'bad' } elseif ($pct -ge $Warn) { 'warn' } else { 'ok' } }

# The one window size that gets the 1M marker and the wider bands. Claude Code reports it as exactly 1000000.
function Test-WideWindow($size) { return $size -eq 1000000 }

# Thousands of tokens: 1.5k, 64k, 1.0M
function K([double] $n) { if ($n -ge 1000000) { '{0:N1}M' -f ($n / 1000000) } elseif ($n -ge 10000) { '{0:N0}k' -f ($n / 1000) } else { '{0:N1}k' -f ($n / 1000) } }

# A 1M window gets a dim "1M" after the name, so a percentage in the context segment reads against the
# right total. Once the session has passed 200k tokens the warning glyph follows it.
function Get-ModelSegment($d, $cfg) {
    $model = $d.model.display_name
    if (-not $model) { return $null }
    $text = "$iconModel $model"
    if (Test-WideWindow $d.context_window.context_window_size) { $text += ' ' + (Format-Inline 'muted' '1M' 'model' $cfg.Style) }
    if ($d.exceeds_200k_tokens -is [bool] -and $d.exceeds_200k_tokens) { $text += " $iconConflict" }
    return @{ Name = 'model'; Text = $text; Short = $null; Role = 'model'; Bold = $true }
}

function Get-ContextSegment($d) {
    $pct = $d.context_window.used_percentage
    if ($null -eq $pct) { return $null }
    $pct = [int] $pct
    $pct = [math]::Max(0, [math]::Min(100, $pct))
    $filled = [math]::Round($pct / 10)
    $bar = ((G 0x2588) * $filled) + ((G 0x2591) * (10 - $filled))
    $used = [double] ($d.context_window.total_input_tokens ?? 0) + [double] ($d.context_window.total_output_tokens ?? 0)
    $size = $d.context_window.context_window_size
    $counts = if ($used -gt 0 -and $size) { " $(K $used)/$(K $size)" } elseif ($used -gt 0) { " $(K $used)" } else { '' }
    $short = "$iconCtx $pct% $bar"
    $role = if (Test-WideWindow $size) { Get-ThresholdRole $pct 70 90 } else { Get-ThresholdRole $pct }
    return @{ Name = 'context'; Text = "$short$counts"; Short = $(if ($counts) { $short } else { $null }); Role = $role; Bold = $false }
}

function Get-CostSegment($d) {
    $cost = $d.cost.total_cost_usd
    if ($null -eq $cost) { return $null }
    return @{ Name = 'cost'; Text = ("$iconCost `$" + ('{0:N2}' -f [double] $cost)); Short = $null; Role = 'dim'; Bold = $false }
}

# Lines added/removed this session; shown when either is non-zero. Inline colours keep the dim background intact.
function Get-LinesSegment($d, $cfg) {
    $added = [int] ($d.cost.total_lines_added ?? 0)
    $removed = [int] ($d.cost.total_lines_removed ?? 0)
    if ($added -le 0 -and $removed -le 0) { return $null }
    $text = "$iconLines " + (Format-Inline 'added' "+$added" 'dim' $cfg.Style) + ' ' + (Format-Inline 'removed' ((G 0x2212) + "$removed") 'dim' $cfg.Style)
    return @{ Name = 'lines'; Text = $text; Short = $null; Role = 'dim'; Bold = $false }
}

# " (1h12m)" or " (3d)" until the given epoch; empty when absent or already past.
function TimeLeft([object] $epoch) {
    if ($null -eq $epoch) { return '' }
    $left = [DateTimeOffset]::FromUnixTimeSeconds([long] $epoch) - [DateTimeOffset]::UtcNow
    if ($left.TotalMinutes -lt 1) { return '' }
    if ($left.TotalHours -ge 48) { return ' ({0}d)' -f [int] [math]::Floor($left.TotalDays) }
    return ' ({0}h{1:00}m)' -f [int] [math]::Floor($left.TotalHours), $left.Minutes
}

# Rate limits: 5-hour and 7-day usage, plus time until the 5-hour window resets, and the spend limit when
# the payload carries one (Claude Code sends it behind a Claude apps gateway with a spend limit). The spend
# figure uses a literal dollar sign, not the cash glyph, so it does not read as a second cost; its resets_at
# is not shown, one countdown is enough. Every figure that is present joins the worst-of colour.
function Get-LimitsSegment($d) {
    $rl = $d.rate_limits
    if (-not $rl) { return $null }
    $bits = [System.Collections.Generic.List[string]]::new()
    $worst = 0
    $short = $null
    # Label, source object and whether the countdown follows, in render order.
    foreach ($row in @(@('5h', $rl.five_hour, $true), @('7d', $rl.seven_day, $false), @('$', $rl.spend_limit, $false))) {
        $pct = $row[1].used_percentage
        if ($null -eq $pct) { continue }
        $pct = [int] [math]::Round([double] $pct)
        $worst = [math]::Max($worst, $pct)
        $tail = if ($row[2]) { TimeLeft $row[1].resets_at } else { '' }
        $bits.Add("$($row[0]) $pct%$tail")
        if ($row[0] -eq '5h') { $short = "$iconLimit 5h $pct%" }
    }
    if ($bits.Count -eq 0) { return $null }
    $text = "$iconLimit $($bits -join ' ')"
    if ($short -eq $text) { $short = $null }
    return @{ Name = 'limits'; Text = $text; Short = $short; Role = (Get-ThresholdRole $worst); Bold = $false }
}

# Session mode badges: fast mode, thinking, non-default effort, vim mode. Omitted when nothing is on.
function Get-BadgesSegment($d) {
    $badges = [System.Collections.Generic.List[string]]::new()
    if ($d.fast_mode -eq $true) { $badges.Add($iconFast) }
    if ($d.thinking.enabled -eq $true) { $badges.Add($iconThink) }
    $effort = $d.effort.level
    if ($effort -and $effort -ne $defaultEffort) { $badges.Add("$iconEffort $effort") }
    $vim = $d.vim.mode
    if ($vim) { $badges.Add("$iconVim $vim") }
    if ($badges.Count -eq 0) { return $null }
    return @{ Name = 'badges'; Text = ($badges -join ' '); Short = $null; Role = 'dim'; Bold = $false }
}

# The pull request on the session's branch: the glyph and #number, the whole text wrapped in a link to
# pr.url, coloured by pr.review_state - approved is ok, changes requested (spaces or underscores, any
# case) is bad, anything else or nothing is dim. The number goes through Get-PayloadNumber and has to
# be positive; without one there is no segment, whatever else the object holds. A url that is not text
# or not http(s) leaves the text unlinked. pr.kind is not rendered. Omitted when the payload has no pr.
function Get-PrSegment($d) {
    $pr = $d.pr
    if ($null -eq $pr) { return $null }
    $number = Get-PayloadNumber $pr.number
    if ($null -eq $number -or $number -le 0) { return $null }
    $state = [regex]::Replace("$($pr.review_state)", '[_\s]+', ' ').Trim().ToLowerInvariant()
    $role = switch ($state) { 'approved' { 'ok' } 'changes requested' { 'bad' } default { 'dim' } }
    $url = if (Test-PayloadText $pr.url) { $pr.url } else { '' }
    return @{ Name = 'pr'; Text = (Format-Link $url "$iconPr #$number"); Short = $null; Role = $role; Bold = $false }
}

# With workspace.repo in the payload and the folder config at repo, the text is owner/name, followed by a
# chevron and the leaf of current_dir once the session has moved below project_dir (no project_dir counts
# as the root). The two paths are compared with forward slashes turned into backslashes, trailing
# separators trimmed and case ignored, since the payload can spell the same directory either way. Short
# is the name alone. Without a repo, with either field not a string or blank, or in leaf mode, it is the
# leaf of current_dir as it always was, with no Short form. No current_dir means no segment.
function Get-FolderSegment($d, $cfg) {
    $dir = [string] $d.workspace.current_dir
    if (-not $dir) { return $null }
    $leaf = Split-Path $dir -Leaf
    $owner = $d.workspace.repo.owner
    $name = $d.workspace.repo.name
    if ($cfg.Folder -eq 'leaf' -or -not (Test-PayloadText $owner) -or -not (Test-PayloadText $name)) {
        return @{ Name = 'folder'; Text = "$iconFolder $leaf"; Short = $null; Role = 'folder'; Bold = $false }
    }
    $root = [string] $d.workspace.project_dir
    $here = ($dir -replace '/', '\').TrimEnd('\')
    $there = ($root -replace '/', '\').TrimEnd('\')
    $text = "$owner/$name"
    if ($root -and $here -ne $there) { $text += " $iconChevron $leaf" }
    return @{ Name = 'folder'; Text = "$iconFolder $text"; Short = "$iconFolder $name"; Role = 'folder'; Bold = $false }
}

# A payload value as a count, or $null when it is not one: a whole number that fits an Int32. ConvertFrom-Json
# hands counts over as Int64; booleans, strings, fractions and out-of-range values are not counts.
# Test-PayloadDirty and Get-PayloadCount share this one rule so the pencil and the counts can never
# disagree about what a value means.
function Get-PayloadNumber($v) {
    $d = Get-FiniteNumber $v
    if ($null -eq $d -or $d -ne [math]::Floor($d)) { return $null }
    if ($d -gt [int]::MaxValue -or $d -lt [int]::MinValue) { return $null }
    return [int] $d
}

# Whether a payload value is text: a string with visible content. Numbers, arrays, objects, nulls and
# blank strings are not, so a field that should name something cannot be rendered from one of those.
function Test-PayloadText($v) {
    return ($v -is [string] -and -not [string]::IsNullOrWhiteSpace($v))
}

# Dirty flag from a payload git.status value: "clean"/other string, or an object of counts/booleans.
function Test-PayloadDirty($status) {
    if ($status -is [string]) { return [bool] ($status -and $status -ne 'clean') }
    if (-not $status) { return $false }
    foreach ($p in $status.PSObject.Properties) {
        $v = $p.Value
        $n = Get-PayloadNumber $v
        if (($null -ne $n -and $n -gt 0) -or ($v -is [bool] -and $v)) { return $true }
    }
    return $false
}

# File counts from a payload git.status object: the named properties staged, modified, untracked and
# conflicts, each 0 when missing or not a positive number. A string status ("clean", "modified") or
# nothing gives four zeros.
function Get-PayloadCount($status) {
    $counts = @{ Staged = 0; Modified = 0; Untracked = 0; Conflicts = 0 }
    if ($null -eq $status -or $status -is [string]) { return $counts }
    foreach ($key in @($counts.Keys)) {
        $n = Get-PayloadNumber $status.($key.ToLowerInvariant())
        if ($null -ne $n -and $n -gt 0) { $counts[$key] = $n }
    }
    return $counts
}

# The branch record from a payload git object, in the shape Read-PorcelainStatus returns, so the segment
# builder reads one record whichever source filled it. Ahead and Behind are always 0 here: the payload
# carries no upstream data. $null when the object names no branch, which means "no branch", not "go
# and look".
function Read-PayloadStatus($git) {
    if (-not $git.branch) { return $null }
    $info = Get-PayloadCount $git.status
    $info.Branch = "$($git.branch)"
    $info.Dirty = Test-PayloadDirty $git.status
    $info.Ahead = 0
    $info.Behind = 0
    return $info
}

# Branch from the payload's git object when present; otherwise from git status in current_dir. Either
# way the record has the same keys. Ahead/behind counts only exist on the git path; the file counts come
# from either source. All of them render dim between the name and the pencil, arrows first, then +staged
# ~modified ?untracked, then the conflict glyph in red. Short is icon, name and pencil, so a wide line
# sheds the counts before it sheds whole segments. Zero counts render nothing, so a clean tree is the
# same text as before.
function Get-BranchSegment($d, $cfg) {
    $info = if ($null -ne $d.git) { Read-PayloadStatus $d.git } else { Get-GitBranch $d.workspace.current_dir $gitTimeoutMs }
    if (-not $info) { return $null }
    $isMain = $info.Branch -in @('main', 'master')
    $icon = if ($isMain) { $iconHome } else { $iconBranch }
    $role = if ($info.Dirty) { 'warn' } else { 'branch' }
    $name = "$icon $($info.Branch)"
    $counts = ''
    # Record key, prefix and inline colour role for each count, in the order they render.
    foreach ($row in @(@('Ahead', $iconAhead, 'track'), @('Behind', $iconBehind, 'track'), @('Staged', '+', 'track'),
                       @('Modified', '~', 'track'), @('Untracked', '?', 'track'), @('Conflicts', $iconConflict, 'removed'))) {
        $n = $info[$row[0]]
        if ($n -gt 0) { $counts += ' ' + (Format-Inline $row[2] "$($row[1])$n" $role $cfg.Style) }
    }
    $pencil = if ($info.Dirty) { " $iconDirty" } else { '' }
    return @{ Name = 'branch'; Text = "$name$counts$pencil"; Short = "$name$pencil"; Role = $role; Bold = $false }
}

# ---- Build, lay out, fit, print ----

$segments = [System.Collections.Generic.List[hashtable]]::new()
foreach ($rec in Get-SegmentRegistry) {
    if (-not $cfg.Segments[$rec.Name]) { continue }
    $seg = & $rec.Build $d $cfg
    if ($seg) { $segments.Add($seg) }
}
if ($segments.Count -eq 0) { Write-Host (C '36' "$iconModel claude"); exit 0 }

# Claude Code sets COLUMNS before running the script. Leave one column free to avoid the pending-wrap glitch.
$width = $null
$cols = 0
if ([int]::TryParse([string] $env:COLUMNS, [ref] $cols) -and $cols -gt 0) { $width = $cols - 1 }

$lineSets = @(if ($cfg.Layout -eq 'two') {
    @((Get-SegmentOrder 'RowRank' 1), (Get-SegmentOrder 'RowRank' 2))
} else { , @((Get-SegmentRegistry).Name) })

# A line that fits down to nothing is not printed. With model toggled off and a very narrow terminal
# that can mean no output at all, which is what the user asked for.
foreach ($names in $lineSets) {
    $onLine = foreach ($n in $names) { foreach ($s in $segments) { if ($s.Name -eq $n) { $s } } }
    $text = Get-FittedLine @($onLine) $cfg.Style $width
    if ($text) { Write-Host $text }
}

# All of the state work - the read, the merge and the write - sits after the last Write-Host, so none of
# it is in front of the visible line. Nothing above this point reads the file.
$sessionId = [string] $d.session_id
if ($cfg.State -and $sessionId) {
    Write-SessionState $sessionId (Merge-SessionState (Read-SessionState $sessionId) $d ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
}
