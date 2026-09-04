#Requires -Version 7.0
# Claude Code status line (PowerShell 7) with Nerd Font glyphs and ANSI colour.
# Requires a Nerd Font in the terminal (install.ps1 can set up JetBrainsMono Nerd Font).
# Reads the JSON Claude Code pipes on stdin and prints one or two lines, e.g.
#   󰚩 Fable 5.1  󰍛 37% ████░░░░░░   $0.43   my-project   main
# Layout, separator style, segment toggles and order, colour bands and glyph overrides come from
# statusline.json next to this script, with the project's own .claude\statusline.json merged over it.
# Glyphs are emitted from code points so the file's own encoding never matters.
[CmdletBinding()]
param(
    # Path to the config file. Defaults to statusline.json beside this script; given, it replaces that
    # file and the project's own file is not read at all. Claude Code never passes it.
    [string] $Config
)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# PowerShell strips ANSI colour when stdout is redirected unless told otherwise; the host always redirects it.
$PSStyle.OutputRendering = 'Ansi'

function G([int] $cp) { [char]::ConvertFromUtf32($cp) }
$e = [char]27
function C([string] $code, [string] $text) { "$e[${code}m$text$e[0m" }

# ---- Diagnostics log ----
# The git probe, the probe cache and the state file swallow every failure on purpose: a status line
# that throws, or that prints an error where the branch should be, is worse than one that is a little
# stale. The cost is that "git still runs on every render" and "the state file never appears" cannot be
# looked into without editing the installed script. CLAUDE_STATUSLINE_DEBUG buys that back without
# giving the silence up: set to anything other than 0, false, no or off, each swallowed catch, each
# cache branch and each state read and write appends one line - UTC time, process id, reason - to
# claude-statusline-diag.log in the temp folder. Unset, which is the normal case, this reads one
# environment variable and returns.
# Writing the log is itself silent, for the same reason the caller's catch is: a temp folder that is
# not there or cannot be written, or another render holding the file, costs the line and nothing else.
# The reason is folded onto one line, because an exception message can carry newlines and one call has
# to stay one line. Nothing here reaches the pipeline, so a call can sit in front of a return without
# changing what the caller returns.
# The log is rolled over rather than left to grow, and one record is bounded so that a reason of any
# length cannot set the size of the file on its own. The 4 MB cap is a target rather than a promise;
# Invoke-StatusDiagRollover has the reason why.

# Moves a log with no room left for the next record over claude-statusline-diag.log.1, so a variable
# left set in a profile costs two files of the cap's size at most rather than the temp volume.
# Two renders can be printing at once and would both see the same full file, so the move is taken
# under a named mutex and the size is read again with the mutex in hand: the second render then finds
# the small file the first one left and does nothing, rather than moving that over the archive the
# first one just made. The wait is zero. A render that cannot have the mutex at once skips the
# rollover and appends, because the file it would have moved is about to shrink under it anyway, so
# nothing here ever waits on another process - which is the point of a log that must not delay a
# render. The append itself is not locked at all. That leaves the cap approximate: two renders that
# overlap can leave the file a little over it, or lose a line to each other, which is the right trade
# for a diagnostic that is off by default and read by a person. Anything that throws is
# Write-StatusDiag's to swallow, and nothing here reaches the pipeline.
function Invoke-StatusDiagRollover([string] $Path, [long] $Need, [long] $Cap) {
    $mutex = [System.Threading.Mutex]::new($false, 'claude-code-statusline-diag-rollover')
    try {
        $held = $false
        # An abandoned mutex is one this process now owns: the render holding it died mid-move.
        try { $held = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { return }
        try {
            $fi = [System.IO.FileInfo]::new($Path)
            if ($fi.Exists -and $fi.Length + $Need -gt $Cap) { [System.IO.File]::Move($Path, $Path + '.1', $true) }
        } finally { $mutex.ReleaseMutex() }
    } finally { $mutex.Dispose() }
}

function Write-StatusDiag([string] $Reason) {
    $flag = $env:CLAUDE_STATUSLINE_DEBUG
    if (-not $flag -or $flag.Trim() -in @('0', 'false', 'no', 'off')) { return }
    try {
        $base = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { [System.IO.Path]::GetTempPath() }
        $path = [System.IO.Path]::Combine($base, 'claude-statusline-diag.log')
        $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
        $text = [regex]::Replace($Reason, '\s+', ' ').Trim()
        # A record is one line a person reads, and an exception message has no length limit, so a reason
        # past 1000 characters is cut and marked. Without this one record could be larger than the whole
        # cap and land in the file the rollover had just emptied, leaving the log over the cap again.
        if ($text.Length -gt 1000) { $text = $text.Substring(0, 1000) + ' [cut]' }
        $line = "$stamp $PID $text`n"
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $need = $utf8.GetByteCount($line)
        $fi = [System.IO.FileInfo]::new($path)
        if ($fi.Exists -and $fi.Length + $need -gt 4MB) { Invoke-StatusDiagRollover $path $need 4MB }
        [System.IO.File]::AppendAllText($path, $line, $utf8)
    } catch { $null = $_ }
}

# The built-in code point of every glyph the segments use, keyed by the name the icons key of
# statusline.json takes: the $icon* constant minus its prefix, lower-cased. The constants themselves
# are assigned from Get-IconSet once the config is read, so an override is in place before any builder runs.
function Get-IconDefault {
    return @{
        model    = 0xF06A9   # nf-md-robot
        context  = 0xF035B   # nf-md-memory
        cost     = 0xF0155   # nf-md-cash
        folder   = 0xF07C    # nf-fa-folder_open
        chevron  = 0x203A    # single right-pointing angle quotation mark (between owner/name and the leaf)
        branch   = 0xE0A0    # powerline branch
        worktree = 0xF04C1   # nf-md-source_fork (the session is in a git worktree)
        home     = 0xF015    # nf-fa-home  (on main/master)
        dirty    = 0xF040    # nf-fa-pencil (uncommitted changes)
        ahead    = 0x2191    # up arrow (commits ahead of upstream)
        behind   = 0x2193    # down arrow (commits behind upstream)
        conflict = 0xF071    # nf-fa-exclamation_triangle (merge conflicts)
        pr       = 0xF407    # nf-oct-git_pull_request
        lines    = 0xF121    # nf-fa-code  (lines added/removed)
        limits   = 0xF0E4    # nf-fa-tachometer (rate limits)
        fast     = 0xF0E7    # nf-fa-bolt  (fast mode)
        think    = 0xF09D0   # nf-md-brain (extended thinking)
        effort   = 0xF04C5   # nf-md-speedometer (effort level)
        vim      = 0xE62B    # nf-custom-vim
    }
}

# The Unicode categories an icon code point may not have. A config is not always the user's own - a
# repository's .claude\statusline.json reaches the icons table too - so a code point is admitted only
# when the terminal can draw it as one glyph standing by itself. Control and Format cover a bare escape,
# a right-to-left override, a directional isolate, a zero-width joiner and a byte order mark, any of
# which can reorder or hide the rest of the line without breaking the escape syntax; the two separators
# would break the line in half; the three marks attach to whatever came before them instead of standing
# alone; a surrogate half is not a character; and an unassigned code point has no glyph, so the terminal
# draws a placeholder of its own choosing. Private use is deliberately not on the list: every Nerd Font
# glyph the script ships lives there.
function Get-IconRefusedCategory {
    return @(
        [System.Globalization.UnicodeCategory]::Control
        [System.Globalization.UnicodeCategory]::Format
        [System.Globalization.UnicodeCategory]::Surrogate
        [System.Globalization.UnicodeCategory]::OtherNotAssigned
        [System.Globalization.UnicodeCategory]::SpaceSeparator
        [System.Globalization.UnicodeCategory]::LineSeparator
        [System.Globalization.UnicodeCategory]::ParagraphSeparator
        [System.Globalization.UnicodeCategory]::NonSpacingMark
        [System.Globalization.UnicodeCategory]::SpacingCombiningMark
        [System.Globalization.UnicodeCategory]::EnclosingMark
    )
}

# A code point from a config value: a string of hex digits, with U+ or 0x allowed in front, space around
# it and leading zeros, at most six digits once those are gone. What comes back is a code point that
# draws as a single glyph: inside Unicode, not a noncharacter (xFFFE, xFFFF and FDD0 to FDEF, which no
# process may interchange), none of the categories above, and one or two cells wide by the script's own
# width rule, so an override can never throw the fitting off. $null for anything else, so the caller
# keeps the built-in glyph.
function Read-CodePoint($Value) {
    if ($Value -isnot [string]) { return $null }
    $hex = $Value.Trim()
    if ($hex.StartsWith('U+', [StringComparison]::OrdinalIgnoreCase) -or $hex.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) { $hex = $hex.Substring(2) }
    $hex = $hex.TrimStart('0')
    if ($hex.Length -lt 1 -or $hex.Length -gt 6) { return $null }
    $cp = 0
    if (-not [int]::TryParse($hex, [System.Globalization.NumberStyles]::AllowHexSpecifier, [cultureinfo]::InvariantCulture, [ref] $cp)) { return $null }
    if (-not [System.Text.Rune]::IsValid($cp)) { return $null }
    if (($cp -band 0xFFFE) -eq 0xFFFE -or ($cp -ge 0xFDD0 -and $cp -le 0xFDEF)) { return $null }
    if ([System.Text.Rune]::GetUnicodeCategory([System.Text.Rune]::new($cp)) -in (Get-IconRefusedCategory)) { return $null }
    if ((Get-VisibleWidth ([char]::ConvertFromUtf32($cp))) -notin @(1, 2)) { return $null }
    return $cp
}

# One glyph per icon name: the built-in code point, or the config's override where its Icons table has
# one. A plain loop over the table, because this runs before the first line is printed.
function Get-IconSet($cfg) {
    $set = @{}
    foreach ($e in (Get-IconDefault).GetEnumerator()) {
        $cp = $e.Value
        if ($cfg.Icons -and $cfg.Icons.ContainsKey($e.Key)) { $cp = $cfg.Icons[$e.Key] }
        $set[$e.Key] = G $cp
    }
    return $set
}

$defaultEffort = 'high'   # effort badge is hidden at this level

# The git probe's settings when statusline.json has no git object: how long the branch segment waits
# for `git status` before giving up, how long a probe result is reused for, and whether it is reused at
# all. Read-StatusConfig starts from these. A fresh table each call, so a caller can change its copy.
function Get-DefaultGitConfig { return @{ TimeoutMs = 1500; CacheSeconds = 5; Cache = $true } }

# A whole-number config value clamped to $Min..$Max, or $Default when it is not a whole number at all:
# missing, a string, a boolean, a fraction. Get-FiniteNumber is the type test, so 3000.0 and 1e1 count
# as whole, and a value far outside Int32 clamps rather than throws.
function Get-ConfigInteger($v, [int] $Default, [int] $Min, [int] $Max) {
    $n = Get-FiniteNumber $v
    if ($null -eq $n -or $n -ne [math]::Floor($n)) { return $Default }
    return [int] [math]::Min([math]::Max($n, [double] $Min), [double] $Max)
}

# Visible cell width of a rendered line: escapes stripped, combining marks and the Unicode Format
# characters 0, CJK and emoji 2, else 1. Format is the whole category rather than the U+200B to U+200D
# range it used to be: a zero-width joiner, a bidi override, a directional isolate and a byte order
# mark all draw nothing, and counting one as a cell measures a line wider than it renders.
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
            $cat -eq [System.Globalization.UnicodeCategory]::Format -or $cp -eq 0xFE0F) { continue }
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

# The segment names in a config array, lower-cased and known to the registry, each at its first place:
# a repeat, an entry that is not a string and a name no segment has are skipped. $Seen carries the names
# already taken and is updated, so the second row of layout two cannot list a segment the first row has.
# $null when the value is not an array at all, which the caller tells from an empty list. A plain loop
# and array rather than a pipeline, because this runs on the startup path for every render.
function Read-SegmentNameList($Value, [hashtable] $Known, [hashtable] $Seen) {
    if ($Value -isnot [array]) { return $null }
    $names = @()
    foreach ($v in $Value) {
        if ($v -isnot [string]) { continue }
        $n = $v.ToLowerInvariant()
        if (-not $Known.ContainsKey($n) -or $Seen.ContainsKey($n)) { continue }
        $Seen[$n] = $true
        $names += $n
    }
    return , $names
}

# The built-in defaults: the table every config file is merged over. A fresh table each call, the nested
# tables included, so a merge that changes one caller's copy cannot reach the next caller's.
function Get-DefaultStatusConfig {
    $cfg = @{ Layout = 'one'; Style = 'plain'; Folder = 'repo'; State = $true; Segments = @{}; Git = Get-DefaultGitConfig }
    foreach ($rec in Get-SegmentRegistry) { $cfg.Segments[$rec.Name] = $rec.Default }
    $cfg.Order = @((Get-SegmentRegistry).Name)
    $cfg.Rows = @((Get-SegmentOrder 'RowRank' 1), (Get-SegmentOrder 'RowRank' 2))
    $cfg.Thresholds = @{ Warn = 60; Bad = 85 }
    $cfg.Icons = @{}
    return $cfg
}

# The one-value config keys: the JSON name, the config key it lands in, and how the value is read. Enum
# takes a string that Allowed lists, folded to lower case; Bool takes a boolean. A value of any other
# shape leaves the key at the value beneath it. A new one-value key is one row here and nothing else; a
# key carrying an object or a list of its own gets a block of its own in Merge-StatusConfigFile, beside
# preset, segments, order, rows, thresholds, icons and git. `preset` is one of those: it is a string,
# but it stands for several keys at once rather than landing in one.
function Get-StatusConfigKey {
    return @(
        @{ Json = 'layout'; Key = 'Layout'; Kind = 'Enum'; Allowed = @('one', 'two') }
        @{ Json = 'style';  Key = 'Style';  Kind = 'Enum'; Allowed = @('plain', 'powerline') }
        @{ Json = 'folder'; Key = 'Folder'; Kind = 'Enum'; Allowed = @('repo', 'leaf') }
        @{ Json = 'state';  Key = 'State';  Kind = 'Bool'; Allowed = $null }
    )
}

# A named starting point: one word standing for a layout, a style and the whole set of segment toggles,
# so a config that wants a common shape is {"preset": "minimal"} rather than nine booleans. The three
# names are built into this table and nothing here opens a path, so a preset named by a project config
# reads no file and needs no budget; it can only pick one of the shapes below.
#   minimal - which model, how full, where am I. One plain line.
#   cost    - the spend line, for watching a budget or a rate limit.
#   full    - everything, split across two powerline rows.
# $Name is untyped and gated here rather than declared [string], because a config file spells the value
# however it likes and a [string] parameter would turn a number or an array into a name instead of
# refusing it. An unknown name returns $null, which leaves the config exactly as it was.
# Each preset states every segment in the registry rather than only the ones it turns on, so a segment
# added later has to be placed in all three by hand; the test that compares these tables to the registry
# is what makes that a failure rather than a silent appearance in `minimal`. A fresh table every call,
# the nested one included, so a caller that changes its copy cannot reach the next caller's.
function Get-ConfigPreset($Name) {
    if ($Name -isnot [string]) { return $null }
    switch ($Name.ToLowerInvariant()) {
        'minimal' {
            return @{ Layout = 'one'; Style = 'plain'; Segments = @{
                    model = $true; context = $true; cost = $false; lines = $false; limits = $false
                    badges = $false; pr = $false; folder = $true; branch = $true
                }
            }
        }
        'cost' {
            return @{ Layout = 'one'; Style = 'plain'; Segments = @{
                    model = $true; context = $true; cost = $true; lines = $true; limits = $true
                    badges = $false; pr = $false; folder = $false; branch = $false
                }
            }
        }
        'full' {
            return @{ Layout = 'two'; Style = 'powerline'; Segments = @{
                    model = $true; context = $true; cost = $true; lines = $true; limits = $true
                    badges = $true; pr = $true; folder = $true; branch = $true
                }
            }
        }
    }
    return $null
}

# What a project config may cost to read. A config a person wrote is a few hundred bytes, so 64 KiB is
# far past any real one and still reads in under a millisecond from a disk; the deadline is what a read
# that never finishes may cost, and the status line is redrawn on every event, so a quarter of a second
# is already longer than a render. Both are constants rather than config keys: they guard the file the
# config itself comes from.
function Get-ProjectConfigLimit { return @{ MaxBytes = 65536; TimeoutMs = 250 } }

# The two calls the bounded read makes, each closed over the path so it can go straight to the thread
# pool. Nothing here can be a script block: converted to a delegate one needs a runspace, and a thread
# pool thread has none. Delegate.CreateDelegate over a one-argument static method is plain .NET, needs no
# runspace, and the pair costs about a sixth of a millisecond - which is what makes it possible to put a
# blocking open behind a deadline without starting a process, and a process per render would cost more
# than everything else the line does. Both APIs are .NET Standard, so they hold on the 7.0 floor.
function Get-BoundedFileDelegate([string] $Path) {
    return @{
        Open       = [System.Delegate]::CreateDelegate([Func[System.IO.FileStream]], $Path, [System.IO.File].GetMethod('OpenRead', [type[]] @([string])))
        Attributes = [System.Delegate]::CreateDelegate([Func[System.IO.FileAttributes]], $Path, [System.IO.File].GetMethod('GetAttributes', [type[]] @([string])))
    }
}

# The same trick for the two things done to an open stream that are filesystem calls in their own right.
# Length is not a field: on Windows it asks the handle for the file's size, which over SMB is a round
# trip to the server and can hang with the stream already open. Closing is a filesystem call too - a
# remote close goes back to the redirector - so it is queued rather than run where it could block the
# line. Both delegates are closed over Stream's own virtual members rather than FileStream's, so they
# dispatch through the same call whatever the stream turns out to be.
function Get-BoundedStreamDelegate($Stream) {
    return @{
        Length  = [System.Delegate]::CreateDelegate([Func[long]], $Stream, [System.IO.Stream].GetProperty('Length').GetMethod)
        Dispose = [System.Delegate]::CreateDelegate([Action], $Stream, [System.IO.Stream].GetMethod('Dispose', [type[]] @()))
    }
}

# The text of a file a repository controls, or $null when it is anything but a small, ordinary, promptly
# readable one. Test-Path and Get-Content are not enough for this file: they follow a link wherever it
# leads and read whatever comes back, for as long as it takes, so a repository could point the path at a
# device, a FIFO or a dead network share and hold up every render, or hand over a file large enough to
# matter. So one clock covers the whole thing, started before the first filesystem call of any kind, and
# every call runs on the thread pool and is waited on for what is left of it: the open, the file's length,
# the attribute probe, each read, and the close at the end. When the budget runs out the attempt is
# abandoned and the caller keeps the config it had, exactly like any other refusal. Abandoning means what
# it says: a thread may stay blocked in the kernel until the process exits, a handle opened after that is
# never closed, and a stream is left open rather than closed on the way out, since closing it would wait
# on whatever is already stuck. That is the price of not waiting, and this process renders one line and
# exits. What the clock does not cover is what the caller does with the text afterwards, or a filesystem
# degraded enough to hang calls this function never makes.
function Read-BoundedFileText([string] $Path) {
    $limit = Get-ProjectConfigLimit
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stream = $null
    try {
        if (-not $Path) { return $null }
        $call = Get-BoundedFileDelegate $Path
        # The open goes first and what it hands back is what gets judged, so there is no gap between a
        # question asked about a name and a read of whatever that name means by then. A name swapped in
        # that gap can still only point at another ordinary file, whose bytes this repository could have
        # written into the config anyway; what it cannot do is make the line block on a device or read
        # past the cap, because both of those are settled from the handle just below.
        $left = $limit.TimeoutMs - $sw.ElapsedMilliseconds
        if ($left -le 0) { return $null }
        $open = [System.Threading.Tasks.Task]::Run($call.Open)
        if (-not $open.Wait([int] $left)) { return $null }
        $fs = $open.Result
        $stream = Get-BoundedStreamDelegate $fs
        # From the handle: a stream that cannot seek is not an ordinary file - a FIFO, a pipe, a
        # character device. CanSeek is settled when the handle is made and costs nothing to read back;
        # the length is a call of its own, so it goes to the pool under the budget like everything else.
        # It is the length the handle reports, not one read off the path before the open.
        if (-not $fs.CanSeek) { return $null }
        $left = $limit.TimeoutMs - $sw.ElapsedMilliseconds
        if ($left -le 0) { return $null }
        $length = [System.Threading.Tasks.Task]::Run($stream.Length)
        if (-not $length.Wait([int] $left)) { return $null }
        if ($length.Result -gt $limit.MaxBytes) { return $null }
        # Belt and braces, and all this runtime offers against a link: a FileStream follows one, and the
        # APIs that name a handle's own target arrived in .NET 6, past the floor. So the name is asked
        # once more, and a reparse point or a directory is refused even though the handle looked ordinary.
        $left = $limit.TimeoutMs - $sw.ElapsedMilliseconds
        if ($left -le 0) { return $null }
        $attr = [System.Threading.Tasks.Task]::Run($call.Attributes)
        if (-not $attr.Wait([int] $left)) { return $null }
        if (($attr.Result -band ([System.IO.FileAttributes]::ReparsePoint -bor [System.IO.FileAttributes]::Directory)) -ne 0) { return $null }
        $buf = [byte[]]::new($limit.MaxBytes + 1)
        $read = 0
        while ($read -lt $buf.Length) {
            $left = $limit.TimeoutMs - $sw.ElapsedMilliseconds
            if ($left -le 0) { return $null }
            $task = $fs.ReadAsync($buf, $read, $buf.Length - $read)
            if (-not $task.Wait([int] $left)) { return $null }
            $n = $task.Result
            if ($n -le 0) { break }
            $read += $n
        }
        # The cap once more, in case the file grew past the length the handle reported.
        if ($read -gt $limit.MaxBytes) { return $null }
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        # UTF8.GetString keeps a byte order mark as U+FEFF, which ConvertFrom-Json will not parse past.
        if ($text.Length -gt 0 -and $text[0] -eq [char] 0xFEFF) { $text = $text.Substring(1) }
        return $text
    } catch { return $null } finally {
        # Cleanup obeys the same clock. With budget left the close is queued on the pool and not waited
        # on, so it cannot become the thing that overruns; with the budget gone the stream is abandoned
        # outright, whichever stage spent it, because a close would only wait on what is already stuck.
        # An abandoned handle is closed by the process exit that follows the line.
        if ($null -ne $stream -and ($limit.TimeoutMs - $sw.ElapsedMilliseconds) -gt 0) {
            try { $null = [System.Threading.Tasks.Task]::Run($stream.Dispose) } catch { $null = $_ }
        }
    }
}

# Applies one config file over a table and returns it. Anything missing or invalid silently falls back to
# the value already there, and each key falls back on its own: a valid order beside a broken thresholds
# keeps the order. Files are applied lowest precedence first, so what an invalid value in the project
# file falls back to is the user file's value rather than the built-in default. -Bounded reads the file
# as untrusted input, which is what the project file is; the user's own file, written by the installer
# or by the user, is read as it always was, so an encoding Get-Content works out still loads.
function Merge-StatusConfigFile([hashtable] $Cfg, [string] $Path, [switch] $Bounded) {
    try {
        if (-not $Path) { return $Cfg }
        $text = if ($Bounded) { Read-BoundedFileText $Path } else {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $Cfg }
            Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        }
        if (-not $text) { return $Cfg }
        $j = $text | ConvertFrom-Json -ErrorAction Stop
        if ($j -isnot [System.Management.Automation.PSCustomObject]) { return $Cfg }
        # preset: a name standing for a layout, a style and every segment toggle, expanded first so that
        # every other key in this same file is written over it whatever order the file spells them in.
        # A preset therefore sits at the precedence of the file naming it: defaults, then the user file's
        # preset and the user file's own keys, then the project file's preset and the project file's own
        # keys. A project preset outranking a user toggle is the same rule as any other project key.
        # A name no preset has, or a value that is not a string, leaves everything as it was.
        $preset = Get-ConfigPreset $j.preset
        if ($null -ne $preset) {
            $Cfg.Layout = $preset.Layout
            $Cfg.Style = $preset.Style
            foreach ($n in @($Cfg.Segments.Keys)) {
                if ($preset.Segments.ContainsKey($n)) { $Cfg.Segments[$n] = $preset.Segments[$n] }
            }
        }
        foreach ($rec in Get-StatusConfigKey) {
            $v = $j.($rec.Json)
            if ($rec.Kind -eq 'Bool') {
                if ($v -is [bool]) { $Cfg[$rec.Key] = $v }
            } elseif ($v -is [string] -and $v.ToLowerInvariant() -in $rec.Allowed) {
                $Cfg[$rec.Key] = $v.ToLowerInvariant()
            }
        }
        # segments: one boolean per name, so a file naming one segment leaves the others as they were.
        $segs = $j.segments
        if ($segs -is [System.Management.Automation.PSCustomObject]) {
            foreach ($n in @($Cfg.Segments.Keys)) {
                $v = $segs.$n
                if ($v -is [bool]) { $Cfg.Segments[$n] = $v }
            }
        }
        # order: the segment names of layout one. Empty, or naming no segment, keeps the order beneath.
        $order = Read-SegmentNameList $j.order $Cfg.Segments @{}
        if ($null -ne $order -and $order.Count -gt 0) { $Cfg.Order = $order }
        # rows: two arrays of names for layout two, read against one seen set so a segment sits on one
        # row only. Anything but exactly two arrays, or two rows naming nothing, keeps the rows beneath.
        $rows = $j.rows
        if ($rows -is [array] -and $rows.Count -eq 2) {
            $seen = @{}
            $row1 = Read-SegmentNameList $rows[0] $Cfg.Segments $seen
            $row2 = Read-SegmentNameList $rows[1] $Cfg.Segments $seen
            if ($null -ne $row1 -and $null -ne $row2 -and ($row1.Count + $row2.Count) -gt 0) { $Cfg.Rows = @($row1, $row2) }
        }
        # thresholds: warn and bad, whole numbers 0 to 100 with warn at or below bad, for the context
        # meter on a standard window and for the rate limits. A whole number written as 20.0 counts, the
        # way Get-PayloadNumber reads a count, since a config written by another tool can spell it so.
        # Either value wrong keeps both as they were.
        $t = $j.thresholds
        if ($t -is [System.Management.Automation.PSCustomObject]) {
            $w = Get-FiniteNumber $t.warn
            $b = Get-FiniteNumber $t.bad
            if ($null -ne $w -and $null -ne $b -and $w -eq [math]::Floor($w) -and $b -eq [math]::Floor($b) -and $w -ge 0 -and $b -le 100 -and $w -le $b) {
                $Cfg.Thresholds = @{ Warn = [int] $w; Bad = [int] $b }
            }
        }
        # icons: icon name to a hex code point string, merged one name at a time. Only a known name with
        # a code point Read-CodePoint accepts is kept, as name to integer; every other entry leaves the
        # glyph beneath alone. The two names the constants shorten are accepted in either spelling.
        $ic = $j.icons
        if ($ic -is [System.Management.Automation.PSCustomObject]) {
            $known = Get-IconDefault
            $alias = @{ ctx = 'context'; limit = 'limits' }
            foreach ($p in $ic.PSObject.Properties) {
                $n = $p.Name.ToLowerInvariant()
                if ($alias.ContainsKey($n)) { $n = $alias[$n] }
                $cp = Read-CodePoint $p.Value
                if ($known.ContainsKey($n) -and $null -ne $cp) { $Cfg.Icons[$n] = $cp }
            }
        }
        # ---- git: probe timeout and cache ----
        # Whole numbers are clamped to their range; a key of the wrong type keeps the value beneath it,
        # and a git value that is not an object keeps all three.
        $g = $j.git
        if ($g -is [System.Management.Automation.PSCustomObject]) {
            $Cfg.Git.TimeoutMs = Get-ConfigInteger $g.timeoutMs $Cfg.Git.TimeoutMs 100 10000
            $Cfg.Git.CacheSeconds = Get-ConfigInteger $g.cacheSeconds $Cfg.Git.CacheSeconds 0 300
            if ($g.cache -is [bool]) { $Cfg.Git.Cache = $g.cache }
        }
    } catch { return $Cfg }
    return $Cfg
}

# The config a render runs on: the built-in defaults, the user file, then the project file when the
# payload named a project directory holding .claude\statusline.json. The merge is per key, so a project
# file of {"layout": "two"} keeps every user toggle. A project directory that is missing, holds no
# .claude\statusline.json, or holds an unreadable one leaves the config below it exactly as it was. That
# file arrives with the repository rather than from the user, so it is read as bounded untrusted input.
# $ProjectDir is untyped and gated here rather than declared [string]: a payload spells project_dir
# however it likes, and a [string] parameter would join an array into a path instead of rejecting it.
# The caller passes it only when -Config named no file, so an explicit config renders the same whatever
# directory the payload names.
function Read-StatusConfig([string] $Path, $ProjectDir) {
    $cfg = Merge-StatusConfigFile (Get-DefaultStatusConfig) $Path
    if ($ProjectDir -isnot [string] -or -not $ProjectDir) { return $cfg }
    # No Test-Path on the project directory on the way in. It would be a filesystem call on a path the
    # repository chose, outside the one budget below, which is the whole thing that budget is for; a
    # directory that is not there is refused by the bounded read like anything else it cannot open.
    # Join-Path only joins strings, so the first call to touch a disk is inside Read-BoundedFileText.
    try { return Merge-StatusConfigFile $cfg (Join-Path $ProjectDir '.claude' 'statusline.json') -Bounded } catch { return $cfg }
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
# understands it (Windows Terminal on ctrl-click) opens. The helper owns its own type gate, so it takes
# the raw payload value: the text comes back unchanged unless the url is a string (a cast would join an
# array into one that passes), at most 2083 characters (the classic browser cap), free of whitespace and
# of any Unicode control character (category Cc: the C0 range, DEL and the C1 range, where U+009B,
# U+009C and U+009D are CSI, ST and OSC in their 8-bit forms), and parses as an absolute http or https
# URI. So nothing a payload puts there can end the sequence early or put a stray escape on the line.
# The link goes into the segment's Text, so Format-Line wraps it in the segment's colour codes in either
# style: OSC 8 carries no SGR state, so a powerline background runs on through it, and Get-VisibleWidth
# strips it before measuring.
function Format-Link($Url, [string] $Text) {
    if ($Url -isnot [string] -or $Url.Length -gt 2083 -or $Url -match '[\s\p{Cc}]') { return $Text }
    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref] $uri)) { return $Text }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { return $Text }
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
    # git permits a right-to-left override in a ref name, so the Format characters come out of the
    # branch here, at the source, rather than being left to whatever renders it.
    return @{ Branch = (Format-PayloadText $branch); Dirty = $dirty; Ahead = $ahead; Behind = $behind
              Staged = $staged; Modified = $modified; Untracked = $untracked; Conflicts = $conflicts }
}

# Runs git status in $Dir with a hard timeout. Any failure, or no git on PATH, returns $null.
# Stdout and stderr are drained on .NET threads so a long listing cannot fill the pipe and stall git.
function Get-GitBranch([string] $Dir, [int] $TimeoutMs) {
    if (-not $Dir) { return $null }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    $git = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $git) { Write-StatusDiag 'git probe: git is not on PATH'; return $null }
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
            try { $p.Kill($true) } catch { Write-StatusDiag "git probe: kill failed: $($_.Exception.Message)" }
            [void] $p.WaitForExit(100)
        }
        # Bounded waits on both drains: the full timeout after a clean exit, so a slow reader cannot cost
        # us the branch, and a short grace after a kill, where the result is discarded anyway. A faulted
        # task is observed here rather than left to the finalizer.
        $drainMs = if ($exited) { $TimeoutMs } else { 100 }
        try { [void] [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), $drainMs) } catch { Write-StatusDiag "git probe: drain failed: $($_.Exception.Message)" }
        if (-not $exited) { Write-StatusDiag "git probe: no answer within $TimeoutMs ms"; return $null }
        if (-not $outTask.IsCompletedSuccessfully) { Write-StatusDiag 'git probe: stdout did not drain'; return $null }
        if ($p.ExitCode -ne 0) { Write-StatusDiag "git probe: git exited $($p.ExitCode)"; return $null }
        return Read-PorcelainStatus $outTask.Result
    } catch { Write-StatusDiag "git probe failed: $($_.Exception.Message)"; return $null }
    finally {
        # Disposing closes the redirected streams, so it is only safe once both drains have finished. The
        # bounded wait after a kill can return with a ReadToEndAsync still pending; disposing then would
        # pull the reader out from under it. In that case leave the handles alone - the script exits a few
        # milliseconds later and the operating system reclaims them.
        if ($p -and $outTask -and $errTask -and $outTask.IsCompleted -and $errTask.IsCompleted) { $p.Dispose() }
    }
}

# The first 16 hex characters, lower-case, of the SHA-256 of a string's UTF-8 bytes. Names the state
# file for an id that cannot name itself, and the cache entry for a repository.
function Get-ShortHash([string] $Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) } finally { $sha.Dispose() }
    return [BitConverter]::ToString($digest, 0, 8).Replace('-', '').ToLowerInvariant()
}

# Writes an object as compact UTF-8 JSON without a BOM: to a sibling .tmp file first, then moved over
# the real one, which is atomic on both Windows and Linux, so a reader never sees half a file and an
# interrupted write costs nothing. $false, and nothing written, when the JSON came out empty. Anything
# that throws is the caller's to swallow.
function Write-AtomicJson([string] $Path, $Object, [int] $Depth) {
    $json = ConvertTo-Json -InputObject $Object -Depth $Depth -Compress -ErrorAction Stop
    if (-not $json) { return $false }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($tmp, $Path, $true)
    return $true
}

# ---- Git probe cache ----
# Every render is a new process, so without help each one would shell out to git status and wait for
# it. The branch segment instead keeps the last probe result per repository in a small JSON file and
# reuses it while the repository's git directory carries the same stamps and the entry is young. The
# stamps cover the files and ref directories that every commit, checkout, add, reset, merge, fetch and
# push moves; an edit or a new file in the work tree moves none of them, so those show up when the
# entry ages out. Every failure here is silent and ends in a probe.

# The work tree at or above $Dir and its git directory, as @{ WorkTree; GitDir }, neither with a
# trailing separator. The walk stops at the first .git entry that is a repository: a directory holding
# a HEAD file, or a file whose one line is `gitdir: <path>` (a worktree or a submodule), the path taken
# relative to the directory holding the file when it is not rooted. A .git directory without a HEAD is
# not a repository, and the walk carries on above it as git does, so a stray empty .git folder cannot
# key the cache on the wrong root. $null when $Dir is missing, the walk reaches the file system root, or
# a gitdir file points nowhere. The walk knows nothing of GIT_CEILING_DIRECTORIES, which is for git
# itself: a root found here is only a place to look for an entry, and an entry is only written after
# git has answered.
function Get-GitRepoRoot([string] $Dir) {
    try {
        if (-not $Dir -or -not [System.IO.Directory]::Exists($Dir)) { return $null }
        $path = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Dir))
        while ($path) {
            $dotGit = [System.IO.Path]::Combine($path, '.git')
            if ([System.IO.Directory]::Exists($dotGit)) {
                if ([System.IO.File]::Exists([System.IO.Path]::Combine($dotGit, 'HEAD'))) { return @{ WorkTree = $path; GitDir = $dotGit } }
            } elseif ([System.IO.File]::Exists($dotGit)) {
                $line = ([System.IO.File]::ReadAllText($dotGit) -split "`r?`n", 2)[0].Trim()
                if (-not $line.StartsWith('gitdir:')) { return $null }
                $gitDir = $line.Substring(7).Trim()
                if (-not $gitDir) { return $null }
                if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = [System.IO.Path]::Combine($path, $gitDir) }
                $gitDir = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($gitDir))
                if (-not [System.IO.File]::Exists([System.IO.Path]::Combine($gitDir, 'HEAD'))) { return $null }
                return @{ WorkTree = $path; GitDir = $gitDir }
            }
            $path = [System.IO.Path]::GetDirectoryName($path)
        }
        return $null
    } catch { Write-StatusDiag "git cache: repository walk failed: $($_.Exception.Message)"; return $null }
}

# The stamp string for a git directory: the UTC ticks, joined with commas, of the directory itself, of
# index, HEAD, ORIG_HEAD, FETCH_HEAD, MERGE_HEAD, packed-refs, logs/HEAD, config and info/exclude (0
# for one that is not there, as index is in a repository with no commits yet), then of refs and every
# directory below it in ordinal order. Git writes a ref as x.lock renamed into place, and a rename
# moves the parent directory's stamp, so a fetch, a push or an empty commit that touches no file above
# still shows. A worktree's git directory names its main repository's in a commondir file, and that
# directory's stamps follow after a bar, because the refs live there. One FileInfo or DirectoryInfo per
# stamp. The walk under refs stops at 256 directories: a repository with more (pull-request fetch
# refs, notes, automation refs) would pay for enumerating and sorting them on every render, so it gets
# a stamp that can never match - the ticks now behind an over-cap: marker - and Get-CachedGitBranch
# treats that as no cache at all.
function Get-GitStamp([string] $GitDir, [switch] $NoCommon) {
    $ticks = [System.Collections.Generic.List[string]]::new()
    $ticks.Add([string] [System.IO.DirectoryInfo]::new($GitDir).LastWriteTimeUtc.Ticks)
    foreach ($rel in @('index', 'HEAD', 'ORIG_HEAD', 'FETCH_HEAD', 'MERGE_HEAD', 'packed-refs', 'logs/HEAD', 'config', 'info/exclude')) {
        $fi = [System.IO.FileInfo]::new([System.IO.Path]::Combine($GitDir, $rel))
        $ticks.Add([string] $(if ($fi.Exists) { $fi.LastWriteTimeUtc.Ticks } else { 0 }))
    }
    $refs = [System.IO.Path]::Combine($GitDir, 'refs')
    if ([System.IO.Directory]::Exists($refs)) {
        $dirs = [System.Collections.Generic.List[string]]::new()
        foreach ($d in [System.IO.Directory]::EnumerateDirectories($refs, '*', [System.IO.SearchOption]::AllDirectories)) {
            if ($dirs.Count -ge 256) { return 'over-cap:' + [DateTime]::UtcNow.Ticks }
            $dirs.Add($d)
        }
        $dirs.Sort([System.StringComparer]::Ordinal)
        $ticks.Add([string] [System.IO.DirectoryInfo]::new($refs).LastWriteTimeUtc.Ticks)
        foreach ($d in $dirs) { $ticks.Add([string] [System.IO.DirectoryInfo]::new($d).LastWriteTimeUtc.Ticks) }
    }
    $stamp = $ticks -join ','
    if ($NoCommon) { return $stamp }
    $commonFile = [System.IO.FileInfo]::new([System.IO.Path]::Combine($GitDir, 'commondir'))
    if ($commonFile.Exists) {
        $common = ([System.IO.File]::ReadAllText($commonFile.FullName) -split "`r?`n", 2)[0].Trim()
        if ($common) {
            if (-not [System.IO.Path]::IsPathRooted($common)) { $common = [System.IO.Path]::Combine($GitDir, $common) }
            $common = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($common))
            if ($common -ne $GitDir -and [System.IO.Directory]::Exists($common)) {
                $commonStamp = Get-GitStamp $common -NoCommon
                if ($commonStamp.StartsWith('over-cap:')) { return $commonStamp }
                $stamp += '|' + $commonStamp
            }
        }
    }
    return $stamp
}

# A cache entry's result as the branch record, or $null when it does not pass the guards the payload
# path applies: Branch must be text, Dirty a boolean, and each count a whole non-negative number. The
# record keeps any other key the probe may grow later, as it was stored.
function Read-CachedRecord($r) {
    if ($r -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    if (-not (Test-PayloadText $r.Branch) -or $r.Dirty -isnot [bool]) { return $null }
    $info = @{}
    foreach ($prop in $r.PSObject.Properties) { $info[$prop.Name] = $prop.Value }
    # Stripped again on the way out of the file. A cache entry written by this script is already clean,
    # but the file is on disk and this is the path an edited one comes back through.
    $info.Branch = Format-PayloadText ([string] $r.Branch)
    foreach ($key in @('Ahead', 'Behind', 'Staged', 'Modified', 'Untracked', 'Conflicts')) {
        $n = Get-PayloadNumber $r.$key
        if ($null -eq $n -or $n -lt 0) { return $null }
        $info[$key] = $n
    }
    return $info
}

# The cache directory: claude-statusline under TEMP, else TMPDIR, else the runtime's temp path, so the
# cache works on Linux and macOS too. TEMP is read first so a test can point the cache into its own tree.
function Get-GitCacheDir {
    $base = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { [System.IO.Path]::GetTempPath() }
    return [System.IO.Path]::Combine($base, 'claude-statusline')
}

# Get-GitBranch with a cache in front of it. The entry for a repository is <hash>.json in $CacheDir,
# where the hash is Get-ShortHash of the lower-cased work tree path. It holds v (1), root (the work
# tree), stamps (Get-GitStamp of its git directory), writtenAt (Unix seconds) and result: the record
# Get-GitBranch returned with whatever keys it had, or null when it returned nothing. The entry is used
# when it parses, names the same root, carries the same stamps, and writtenAt is within $Ttl seconds of
# now either way, so a clock that went backwards reads as stale rather than as fresh for years. A null
# result is a hit too: the slow repository, and the machine with no git, pay for the probe once per
# lifetime rather than once per render. Anything else - no entry, a stale one, a corrupt one, a record
# that fails Read-CachedRecord, a read that throws - is a miss: git runs, and the answer is written
# back through Write-AtomicJson, then the directory is swept of day-old files. With no directory, a
# $Ttl of 0, no repository found, or a stamp that cannot be taken (the walk threw, or refs are over the
# cap) this is a plain probe, and nothing is written. The stamps are read before git runs, so a change
# that lands during the probe invalidates the entry. The directory is created only when there is
# something to write, and a failure to create it, or to write, costs nothing but the cache.
function Get-CachedGitBranch([string] $Dir, [int] $TimeoutMs, [string] $CacheDir, [int] $Ttl) {
    $repo = if ($CacheDir -and $Ttl -gt 0) { Get-GitRepoRoot $Dir } else { $null }
    if (-not $repo) {
        if ($CacheDir -and $Ttl -gt 0) { Write-StatusDiag "git cache: skipped (no repository above $Dir)" } else { Write-StatusDiag 'git cache: skipped (off in the config)' }
        return Get-GitBranch $Dir $TimeoutMs
    }
    $root = $repo.WorkTree
    $stamps = $null
    try { $stamps = Get-GitStamp $repo.GitDir } catch { Write-StatusDiag "git cache: stamp failed: $($_.Exception.Message)" }
    if (-not $stamps -or $stamps.StartsWith('over-cap:')) {
        if ($stamps) { Write-StatusDiag 'git cache: skipped (the repository is over the ref cap)' } else { Write-StatusDiag 'git cache: skipped (no stamp)' }
        return Get-GitBranch $Dir $TimeoutMs
    }
    $path = [System.IO.Path]::Combine($CacheDir, (Get-ShortHash $root.ToLowerInvariant()) + '.json')
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    try {
        if ([System.IO.File]::Exists($path)) {
            $j = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
            if ($j -is [System.Management.Automation.PSCustomObject] -and [long] $j.v -eq 1 -and
                $j.root -is [string] -and $j.root -eq $root -and
                $j.stamps -is [string] -and $j.stamps -ceq $stamps -and
                [math]::Abs($now - [long] $j.writtenAt) -lt $Ttl -and $null -ne $j.PSObject.Properties['result']) {
                if ($null -eq $j.result) { Write-StatusDiag 'git cache: hit (the entry holds no branch)'; return $null }
                $info = Read-CachedRecord $j.result
                if ($info) { Write-StatusDiag "git cache: hit ($($info.Branch))"; return $info }
                Write-StatusDiag 'git cache: miss (the record did not pass the guards)'
            } else {
                Write-StatusDiag 'git cache: miss (the entry is stale or does not match)'
            }
        } else {
            Write-StatusDiag 'git cache: miss (no entry yet)'
        }
    } catch { Write-StatusDiag "git cache: read failed: $($_.Exception.Message)" }
    $info = Get-GitBranch $Dir $TimeoutMs
    try {
        [void] [System.IO.Directory]::CreateDirectory($CacheDir)
        if (Write-AtomicJson $path ([ordered]@{ v = 1; root = $root; stamps = $stamps; writtenAt = $now; result = $info }) 3) { Invoke-SessionStateSweep $CacheDir }
    } catch { Write-StatusDiag "git cache: write failed: $($_.Exception.Message)" }
    return $info
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
    } catch { Write-StatusDiag "state dir failed: $($_.Exception.Message)"; return $null }
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
        $hash = Get-ShortHash $SessionId
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
        if (-not $path -or -not [System.IO.File]::Exists($path)) { Write-StatusDiag 'state: no file yet'; return $null }
        $j = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        if ($j -isnot [System.Management.Automation.PSCustomObject] -or (Get-StateNumber $j.v) -ne 1) { Write-StatusDiag 'state: the file is not a version 1 record'; return $null }
        $history = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($h in @($j.history)) {
            $t = Get-StateNumber $h.t -Whole
            $c = Get-StateNumber $h.cost_usd
            if ($null -ne $t -and $null -ne $c) { $history.Add(@{ t = $t; cost_usd = $c }) }
        }
        $state = @{ v = 1; history = @($history) }
        foreach ($key in @('updated_at', 'input_tokens', 'output_tokens')) { $state[$key] = Get-StateNumber $j.$key -Whole }
        foreach ($key in @('cost_usd', 'used_percentage', 'five_hour_percentage')) { $state[$key] = Get-StateNumber $j.$key }
        Write-StatusDiag "state: read ($path)"
        return $state
    } catch { Write-StatusDiag "state read failed: $($_.Exception.Message)"; return $null }
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

# Housekeeping for a directory of JSON files - the state files, and the git cache entries - at most
# once per six hours per directory: a .sweep stamp marks the last finished pass. When it is missing or
# older than six hours, .json files not written for a day, and .tmp files an interrupted write left
# behind, are deleted, at most 200 in one pass. A pass that hits the cap leaves the stamp alone, so the
# next render carries on with the backlog instead of draining 200 files every six hours. Ages are
# absolute, so a stamp or a file dated in the future - a clock change, a restored backup - reads as
# stale rather than as freshly written, which would park housekeeping until the wall clock caught up.
# The common render pays for one stat of the stamp and nothing else.
function Invoke-SessionStateSweep([string] $Dir) {
    try {
        $stamp = Join-Path $Dir '.sweep'
        $now = [DateTime]::UtcNow
        if ([System.IO.File]::Exists($stamp) -and [math]::Abs(($now - [System.IO.File]::GetLastWriteTimeUtc($stamp)).TotalHours) -lt 6) { return }
        $deleted = 0
        $capped = $false
        foreach ($pattern in @('*.json', '*.tmp')) {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($Dir, $pattern)) {
                if ($deleted -ge 200) { $capped = $true; break }
                if ([math]::Abs(($now - [System.IO.File]::GetLastWriteTimeUtc($f)).TotalDays) -lt 1) { continue }
                try { [System.IO.File]::Delete($f); $deleted++ } catch { Write-StatusDiag "sweep: delete failed: $($_.Exception.Message)" }
            }
            if ($capped) { break }
        }
        if (-not $capped) { [System.IO.File]::WriteAllText($stamp, '') }
    } catch { Write-StatusDiag "sweep failed: $($_.Exception.Message)" }
}

# Writes a session's state through Write-AtomicJson, then runs the sweep. Nothing is written for an
# empty record, an id that leaves no file name, or JSON that would not serialise - a half-written or
# empty file would cost the whole ring rather than one delta, which is why the write is atomic. Every
# failure is swallowed: the line has already been printed. Concurrent renders of one session still
# race, and the last writer wins; a lock file is out of scope for the same reason, the cost of losing
# is one missing delta.
function Write-SessionState([string] $SessionId, $State) {
    try {
        if (-not $State) { Write-StatusDiag 'state: not written (nothing to write)'; return }
        $path = Get-SessionStatePath $SessionId $true
        if (-not $path) { Write-StatusDiag 'state: not written (the session id leaves no file name)'; return }
        if (Write-AtomicJson $path $State 4) {
            Write-StatusDiag "state: written ($path)"
            Invoke-SessionStateSweep (Split-Path $path -Parent)
        } else {
            Write-StatusDiag 'state: not written (the record serialised to nothing)'
        }
    } catch { Write-StatusDiag "state write failed: $($_.Exception.Message)" }
}

$raw = [Console]::In.ReadToEnd()
$payloadOk = $true
$d = $null
try { $d = $raw | ConvertFrom-Json } catch { $payloadOk = $false }

# The config is read after the payload, because the payload names the project directory whose
# .claude\statusline.json is merged over the user file, and still before anything is printed. -Config
# replaces the user file and leaves the project file unread: it is the explicit override the tests and
# the screenshot script use, and both need a render that no directory a sample payload names can change.
$configPath = if ($Config) { $Config } else { Join-Path $PSScriptRoot 'statusline.json' }
$projectDir = if ($Config) { $null } else { $d.workspace.project_dir }
$cfg = Read-StatusConfig $configPath $projectDir

# The glyphs the builders and the fallback line use, with the config's icons overrides applied.
$icons = Get-IconSet $cfg
$iconModel = $icons.model
$iconCtx = $icons.context
$iconCost = $icons.cost
$iconFolder = $icons.folder
$iconChevron = $icons.chevron
$iconBranch = $icons.branch
$iconWorktree = $icons.worktree
$iconHome = $icons.home
$iconDirty = $icons.dirty
$iconAhead = $icons.ahead
$iconBehind = $icons.behind
$iconConflict = $icons.conflict
$iconPr = $icons.pr
$iconLines = $icons.lines
$iconLimit = $icons.limits
$iconFast = $icons.fast
$iconThink = $icons.think
$iconEffort = $icons.effort
$iconVim = $icons.vim

# A payload that is not JSON gets the fallback line. It is printed here rather than where the payload was
# read so that it carries the config's glyph overrides, which are only settled above.
if (-not $payloadOk) { Write-Host (C '36' "$iconModel claude"); exit 0 }

# ---- Segment builders. Each returns $null (segment omitted) or @{ Name; Text; Short; Role; Bold }. ----

# Colour bands for a percentage. Every caller passes both bands: the config's thresholds, 60 and 85 unless
# statusline.json moves them, which suit a 200k window, or the fixed 70 and 90 of a 1M window, because 85%
# of 1M still leaves 150k tokens, more than a whole fresh 200k session, so the config does not reach them.
# No defaults here: a caller that forgot the config would bind 0 and 0 and colour everything red.
function Get-ThresholdRole([int] $pct, [int] $Warn, [int] $Bad) { if ($pct -ge $Bad) { 'bad' } elseif ($pct -ge $Warn) { 'warn' } else { 'ok' } }

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

function Get-ContextSegment($d, $cfg) {
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
    $role = if (Test-WideWindow $size) { Get-ThresholdRole $pct 70 90 } else { Get-ThresholdRole $pct $cfg.Thresholds.Warn $cfg.Thresholds.Bad }
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

# How the 5-hour window is being spent, as one plain arrow: U+2192 when carrying on at this rate lands
# inside the window, U+2191 when it overruns, with Red set once the projection reaches 120% so the caller
# can colour it. Returned as @{ Arrow; Red }, or $null for no arrow at all - which is the answer whenever
# there is nothing honest to say: no reset time, a reset already past or one so far out that the window
# has not opened, less than the first tenth of the window gone (one busy minute swings the projection
# there), or no usage yet, where every projection is zero and a right arrow would just be noise.
# The window is a fixed 18000 seconds, so the elapsed fraction follows from the reset alone and no state
# file is needed. The arithmetic stays in whole seconds rather than DateTimeOffset, which throws on an
# epoch outside its own range; a payload's absurd number here just falls out as no arrow. The two limits
# are tested on the seconds left rather than on the fraction, because a tenth of the window is 16200
# seconds exactly while 1 - 16200 / 18000 is 0.09999999999999998, which would drop the first honest
# reading of every window.
# $Now is the current epoch and defaults to the clock, so no caller passes one. It exists for the tests:
# an epoch derived from an earlier reading of the clock is one second out whenever the second ticks in
# between, which is enough to miss both of those limits by exactly the margin a regression would move.
function Get-PaceArrow([object] $resetsAt, [object] $used, [long] $Now = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())) {
    $reset = Get-FiniteNumber $resetsAt
    $pct = Get-FiniteNumber $used
    if ($null -eq $reset -or $null -eq $pct -or $pct -le 0) { return $null }
    $left = $reset - $Now
    if ($left -le 0 -or $left -gt 16200) { return $null }
    $projected = $pct * 18000 / (18000 - $left)
    if ($projected -le 100) { return @{ Arrow = (G 0x2192); Red = $false } }
    return @{ Arrow = (G 0x2191); Red = ($projected -ge 120) }
}

# Rate limits: 5-hour and 7-day usage, plus time until the 5-hour window resets, and the spend limit when
# the payload carries one (Claude Code sends it behind a Claude apps gateway with a spend limit). The spend
# figure uses a literal dollar sign, not the cash glyph, so it does not read as a second cost; its resets_at
# is not shown, one countdown is enough. Every figure that is present joins the worst-of colour, banded by
# the config's thresholds whatever the window size, and the Short form a narrow terminal falls back to
# keeps the figure behind that colour: the worst one, or the first present one when nothing is above the
# warn line. Either way it carries neither the countdown nor the pace arrow.
# The 5-hour figure also gets the pace arrow, between the percentage and the countdown, because that is
# the only window one payload can honestly pace. It is added after the loop rather than inside it: a red
# arrow goes through Format-Inline, which hands the segment's own foreground back afterwards, and which
# foreground that is depends on every figure the loop has yet to see.
function Get-LimitsSegment($d, $cfg) {
    $rl = $d.rate_limits
    if (-not $rl) { return $null }
    $bits = [System.Collections.Generic.List[string]]::new()
    $worst = -1
    $first = $null
    $top = $null
    $pace = $null
    $paceAt = -1
    $paceHead = ''
    $paceTail = ''
    # Label, source object and whether the pace arrow and the countdown follow, in render order.
    foreach ($row in @(@('5h', $rl.five_hour, $true), @('7d', $rl.seven_day, $false), @('$', $rl.spend_limit, $false))) {
        $pct = $row[1].used_percentage
        if ($null -eq $pct) { continue }
        $pct = [int] [math]::Round([double] $pct)
        $bit = "$($row[0]) $pct%"
        if ($null -eq $first) { $first = $bit }
        # A strict comparison keeps the earlier figure on a tie, so 5h beats 7d beats spend.
        if ($pct -gt $worst) { $top = $bit; $worst = $pct }
        $tail = ''
        if ($row[2]) {
            $tail = TimeLeft $row[1].resets_at
            # The raw percentage, not the rounded one: the projection is the arrow's whole point.
            $pace = Get-PaceArrow $row[1].resets_at $row[1].used_percentage
            if ($pace) { $paceAt = $bits.Count; $paceHead = $bit; $paceTail = $tail }
        }
        $bits.Add("$bit$tail")
    }
    if ($bits.Count -eq 0) { return $null }
    $role = Get-ThresholdRole $worst $cfg.Thresholds.Warn $cfg.Thresholds.Bad
    if ($paceAt -ge 0) {
        $arrow = if ($pace.Red) { Format-Inline 'removed' $pace.Arrow $role $cfg.Style } else { $pace.Arrow }
        $bits[$paceAt] = "$paceHead $arrow$paceTail"
    }
    $text = "$iconLimit $($bits -join ' ')"
    $short = "$iconLimit " + $(if ($role -eq 'ok') { $first } else { $top })
    if ($short -eq $text) { $short = $null }
    return @{ Name = 'limits'; Text = $text; Short = $short; Role = $role; Bold = $false }
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
# case) is bad, anything else is dim, including a state that is not text at all. The number goes
# through Get-PayloadNumber and has to be positive; without one there is no segment, whatever else the
# object holds. The url goes to Format-Link as it is, which leaves the text unlinked for anything that
# is not a plain http(s) URL. pr.kind is not rendered. Omitted when the payload has no pr object, or
# has something other than an object there.
function Get-PrSegment($d) {
    $pr = $d.pr
    if ($pr -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $number = Get-PayloadNumber $pr.number
    if ($null -eq $number -or $number -le 0) { return $null }
    $state = if (Test-PayloadText $pr.review_state) { [regex]::Replace($pr.review_state, '[_\s]+', ' ').Trim().ToLowerInvariant() } else { '' }
    $role = switch ($state) { 'approved' { 'ok' } 'changes requested' { 'bad' } default { 'dim' } }
    return @{ Name = 'pr'; Text = (Format-Link $pr.url "$iconPr #$number"); Short = $null; Role = $role; Bold = $false }
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
    # Every piece of text this segment draws comes from outside it - a directory name, a repo owner -
    # and each one is stripped of its Format characters, so none of them can reorder the rest of the line.
    $leaf = Format-PayloadText (Split-Path $dir -Leaf)
    $owner = $d.workspace.repo.owner
    $name = $d.workspace.repo.name
    if ($cfg.Folder -eq 'leaf' -or -not (Test-PayloadText $owner) -or -not (Test-PayloadText $name)) {
        return @{ Name = 'folder'; Text = "$iconFolder $leaf"; Short = $null; Role = 'folder'; Bold = $false }
    }
    $owner = Format-PayloadText ([string] $owner)
    $name = Format-PayloadText ([string] $name)
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

# The two families of invisible character a rendered value may not carry, and the two different answers
# to them. Cc, the C0 range, DEL and the C1 range, is an escape: U+001B, and U+009B, U+009C and U+009D
# which are CSI, ST and OSC in their 8-bit forms. A value carrying one is refused outright, because half
# an escape sequence is not a name and its presence is evidence the value is hostile rather than
# careless. Cf, the Unicode Format category, is a right-to-left override, a directional isolate, a
# zero-width joiner or a byte order mark: none of them breaks the escape syntax and ConvertTo-Json emits
# them raw, but each one reorders or hides the rest of the line, which is exactly the reasoning
# Get-IconRefusedCategory already applies to an icon code point. Those are stripped rather than refused,
# because one stray override in a branch name - and git permits one in a ref name - should cost the
# character, not the segment that says which branch the session is on. Format-PayloadText takes them
# out; Test-PayloadText answers whether anything visible is left once they are gone, so a value that is
# nothing but overrides is not text and a caller with a fallback list moves on to the next field.
# Numbers, arrays, objects, nulls and blank strings are not text either.
function Format-PayloadText([string] $Text) {
    return [regex]::Replace($Text, '\p{Cf}', '')
}

function Test-PayloadText($v) {
    return ($v -is [string] -and -not [string]::IsNullOrWhiteSpace($v) -and $v -notmatch '\p{Cc}' -and
            -not [string]::IsNullOrWhiteSpace((Format-PayloadText $v)))
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
    # Stripped rather than refused: a name that is nothing but Format characters leaves no branch to
    # put on the line, but one carrying a stray override keeps the rest of its text.
    $branch = Format-PayloadText "$($git.branch)"
    if (-not $branch) { return $null }
    $info = Get-PayloadCount $git.status
    $info.Branch = $branch
    $info.Dirty = Test-PayloadDirty $git.status
    $info.Ahead = 0
    $info.Behind = 0
    return $info
}

# The name of the worktree the session is in, for the badge inside the branch segment. Three answers:
# the name, when worktree.name is text; the empty string, meaning "in a worktree, with nothing to call
# it", which draws the glyph on its own; and $null, meaning the session is not in a worktree at all and
# there is no badge. worktree.name is the field to use when Claude Code sends one, whatever
# workspace.git_worktree says, because a payload that names a worktree is in one. Without a usable name
# the boolean is the signal, and only a real boolean: a "true" string or a 1 is a payload that does not
# mean what this reads, so it gets no badge. Then the last segment of worktree.path stands in, taken
# after the separators are folded and any trailing one is dropped, so C:\src\wt-x\ and /home/j/wt-x
# both give wt-x. Both fields go through Test-PayloadText, the one guard the branch name and the repo
# owner and name already pass: a worktree directory is named by whoever made the repository, not by the
# person at the keyboard, and a name carrying an escape would recolour or break the rest of the line.
# Whatever that guard refuses, this refuses with it, rather than keeping a second rule of its own that
# could fall behind. Whatever that guard strips, this strips with it: the name and the path leaf are
# rendered text, so they go through Format-PayloadText the way the branch name and the repo owner do,
# and a right-to-left override in a worktree directory costs the character rather than the badge. That
# leaves the three answers where they were. A name with nothing visible left in it is not a name, so it
# falls through this chain rather than becoming a fourth answer; a path leaf with nothing left lands on
# the empty string, which is already what "in a worktree, with nothing to call it" means. Nothing here
# starts a process or touches the disk - the payload is the only source, so a render costs no more.
function Get-WorktreeName($d) {
    $wt = $d.worktree
    if (Test-PayloadText $wt.name) { return (Format-PayloadText "$($wt.name)").Trim() }
    if ($d.workspace.git_worktree -isnot [bool] -or -not $d.workspace.git_worktree) { return $null }
    if (Test-PayloadText $wt.path) {
        # The leaf is taken from the path as it arrived and stripped afterwards, not the other way
        # round: stripping first would turn C:\src\<override> into C:\src\ and then call the worktree
        # "src", naming the parent of a directory whose own name is invisible.
        $path = ("$($wt.path)" -replace '/', '\').TrimEnd('\')
        $leaf = Format-PayloadText $path.Substring($path.LastIndexOf('\') + 1)
        if ($leaf) { return $leaf }
    }
    return ''
}

# Branch from the payload's git object when present; otherwise from git status in current_dir, through
# the probe cache, which is handed no directory when the config turns it off and does the rest of the
# deciding itself. Either way the record has the same keys. Ahead/behind counts only exist on the git
# path; the file counts come from either source. All of them render dim between the name and the
# pencil, arrows first, then +staged ~modified ?untracked, then the conflict glyph in red. A session in
# a git worktree gets the fork glyph and the worktree's name in front of the counts, from the payload
# rather than from git. Short is icon, name and pencil, so a wide line sheds the badge and the counts
# before it sheds whole segments. Zero counts render nothing, and a session outside a worktree gets no
# badge, so an ordinary clean checkout is the same text as before.
function Get-BranchSegment($d, $cfg) {
    $info = if ($null -ne $d.git) { Read-PayloadStatus $d.git } else {
        $cacheDir = if ($cfg.Git.Cache) { Get-GitCacheDir } else { $null }
        Get-CachedGitBranch $d.workspace.current_dir $cfg.Git.TimeoutMs $cacheDir $cfg.Git.CacheSeconds
    }
    if (-not $info) { return $null }
    $isMain = $info.Branch -in @('main', 'master')
    $icon = if ($isMain) { $iconHome } else { $iconBranch }
    $role = if ($info.Dirty) { 'warn' } else { 'branch' }
    $name = "$icon $($info.Branch)"
    # The worktree badge, when the session is in one: the fork glyph and the name, straight after the
    # branch name, so the two halves of "which checkout is this" read together and the counts and the
    # pencil keep their places behind them. It is not in Short, so a narrow line sheds it with the
    # counts, and it is not in the role either: a worktree is never the reason a colour changes.
    $worktree = Get-WorktreeName $d
    $badge = if ($null -eq $worktree) { '' } elseif ($worktree) { " $iconWorktree $worktree" } else { " $iconWorktree" }
    $counts = ''
    # Record key, prefix and inline colour role for each count, in the order they render.
    foreach ($row in @(@('Ahead', $iconAhead, 'track'), @('Behind', $iconBehind, 'track'), @('Staged', '+', 'track'),
                       @('Modified', '~', 'track'), @('Untracked', '?', 'track'), @('Conflicts', $iconConflict, 'removed'))) {
        $n = $info[$row[0]]
        if ($n -gt 0) { $counts += ' ' + (Format-Inline $row[2] "$($row[1])$n" $role $cfg.Style) }
    }
    $pencil = if ($info.Dirty) { " $iconDirty" } else { '' }
    return @{ Name = 'branch'; Text = "$name$badge$counts$pencil"; Short = "$name$pencil"; Role = $role; Bold = $false }
}

# ---- Build, lay out, fit, print ----

# The names on each printed line: the config's order for layout one, the two rows for layout two. A
# segment that is toggled off, or that no line lists, is not built at all, so an order without branch
# never runs the git probe.
$lineSets = @(if ($cfg.Layout -eq 'two') { $cfg.Rows } else { , $cfg.Order })
$listed = @{}
foreach ($names in $lineSets) { foreach ($n in $names) { $listed[$n] = $true } }

$segments = [System.Collections.Generic.List[hashtable]]::new()
foreach ($rec in Get-SegmentRegistry) {
    if (-not $cfg.Segments[$rec.Name] -or -not $listed[$rec.Name]) { continue }
    $seg = & $rec.Build $d $cfg
    if ($seg) { $segments.Add($seg) }
}
if ($segments.Count -eq 0) { Write-Host (C '36' "$iconModel claude"); exit 0 }

# Claude Code sets COLUMNS before running the script. Leave one column free to avoid the pending-wrap glitch.
$width = $null
$cols = 0
if ([int]::TryParse([string] $env:COLUMNS, [ref] $cols) -and $cols -gt 0) { $width = $cols - 1 }

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
