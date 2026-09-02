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
$iconBranch = G 0xE0A0    # powerline branch
$iconHome   = G 0xF015    # nf-fa-home  (on main/master)
$iconDirty  = G 0xF040    # nf-fa-pencil (uncommitted changes)
$iconAhead  = G 0x2191    # up arrow (commits ahead of upstream)
$iconBehind = G 0x2193    # down arrow (commits behind upstream)
$iconConflict = G 0xF071  # nf-fa-exclamation_triangle (merge conflicts)
$iconLines  = G 0xF121    # nf-fa-code  (lines added/removed)
$iconLimit  = G 0xF0E4    # nf-fa-tachometer (rate limits)
$iconFast   = G 0xF0E7    # nf-fa-bolt  (fast mode)
$iconThink  = G 0xF09D0   # nf-md-brain (extended thinking)
$iconEffort = G 0xF04C5   # nf-md-speedometer (effort level)
$iconVim    = G 0xE62B    # nf-custom-vim
$defaultEffort = 'high'   # effort badge is hidden at this level

$gitTimeoutMs = 1500      # how long the branch segment waits for `git status` before giving up

# Visible cell width of a rendered line: escapes stripped, combining marks 0, CJK and emoji 2, else 1.
# A small wcwidth approximation; Nerd Font glyphs count as 1.
function Get-VisibleWidth([string] $Text) {
    if (-not $Text) { return 0 }
    $plain = [regex]::Replace($Text, "`e\[[0-9;]*m", '')
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

# Reads statusline.json. Anything missing or invalid silently falls back to its default.
function Read-StatusConfig([string] $Path) {
    $cfg = @{ Layout = 'one'; Style = 'plain'; Segments = @{} }
    foreach ($n in @('model', 'context', 'cost', 'lines', 'limits', 'badges', 'folder', 'branch')) { $cfg.Segments[$n] = $true }
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $cfg }
        $j = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($j -isnot [System.Management.Automation.PSCustomObject]) { return $cfg }
        if ($j.layout -is [string] -and $j.layout.ToLowerInvariant() -in @('one', 'two')) { $cfg.Layout = $j.layout.ToLowerInvariant() }
        if ($j.style -is [string] -and $j.style.ToLowerInvariant() -in @('plain', 'powerline')) { $cfg.Style = $j.style.ToLowerInvariant() }
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
# Stage 1 swaps limits, context, then branch for their Short form. Stage 2 drops whole segments in a fixed order.
# The model segment is never dropped and may overflow on its own. Returns $null when nothing is left.
function Get-FittedLine($Segments, [string] $Style, $Width) {
    $segs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($s in $Segments) { if ($s) { $segs.Add($s.Clone()) } }
    if ($segs.Count -eq 0) { return $null }
    $line = Format-Line $segs $Style
    if ($null -eq $Width) { return $line }
    $target = [int] $Width
    if ((Get-VisibleWidth $line) -le $target) { return $line }
    foreach ($name in @('limits', 'context', 'branch')) {
        for ($i = 0; $i -lt $segs.Count; $i++) {
            if ($segs[$i].Name -eq $name -and $segs[$i].Short) {
                $segs[$i].Text = $segs[$i].Short
                $line = Format-Line $segs $Style
                if ((Get-VisibleWidth $line) -le $target) { return $line }
            }
        }
    }
    foreach ($name in @('lines', 'badges', 'cost', 'limits', 'folder', 'branch', 'context')) {
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

$raw = [Console]::In.ReadToEnd()
try { $d = $raw | ConvertFrom-Json } catch { Write-Host (C '36' "$iconModel claude"); exit 0 }

$configPath = if ($Config) { $Config } else { Join-Path $PSScriptRoot 'statusline.json' }
$cfg = Read-StatusConfig $configPath

# ---- Segment builders. Each returns $null (segment omitted) or @{ Name; Text; Short; Role; Bold }. ----

function Get-ThresholdRole([int] $pct) { if ($pct -ge 85) { 'bad' } elseif ($pct -ge 60) { 'warn' } else { 'ok' } }

# Thousands of tokens: 1.5k, 64k, 1.0M
function K([double] $n) { if ($n -ge 1000000) { '{0:N1}M' -f ($n / 1000000) } elseif ($n -ge 10000) { '{0:N0}k' -f ($n / 1000) } else { '{0:N1}k' -f ($n / 1000) } }

function Get-ModelSegment($d) {
    $model = $d.model.display_name
    if (-not $model) { return $null }
    return @{ Name = 'model'; Text = "$iconModel $model"; Short = $null; Role = 'model'; Bold = $true }
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
    return @{ Name = 'context'; Text = "$short$counts"; Short = $(if ($counts) { $short } else { $null }); Role = (Get-ThresholdRole $pct); Bold = $false }
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

# Rate limits: 5-hour and 7-day usage, plus time until the 5-hour window resets.
function Get-LimitsSegment($d) {
    $rl = $d.rate_limits
    if (-not $rl) { return $null }
    $h5 = $rl.five_hour.used_percentage
    $d7 = $rl.seven_day.used_percentage
    if ($null -eq $h5 -and $null -eq $d7) { return $null }
    $bits = [System.Collections.Generic.List[string]]::new()
    $worst = 0
    $short = $null
    if ($null -ne $h5) {
        $h5 = [int] [math]::Round([double] $h5); $worst = [math]::Max($worst, $h5)
        $bits.Add("5h $h5%$(TimeLeft $rl.five_hour.resets_at)")
        $short = "$iconLimit 5h $h5%"
    }
    if ($null -ne $d7) { $d7 = [int] [math]::Round([double] $d7); $worst = [math]::Max($worst, $d7); $bits.Add("7d $d7%") }
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

function Get-FolderSegment($d) {
    $dir = $d.workspace.current_dir
    if (-not $dir) { return $null }
    return @{ Name = 'folder'; Text = "$iconFolder $(Split-Path $dir -Leaf)"; Short = $null; Role = 'folder'; Bold = $false }
}

# A payload value as a number, or $null when it is not one. ConvertFrom-Json hands counts over as Int64;
# booleans and strings are not counts. Test-PayloadDirty and Get-PayloadCount share this one rule so the
# pencil and the counts can never disagree about what a value means.
function Get-PayloadNumber($v) {
    if ($v -is [ValueType] -and -not ($v -is [bool])) { return [double] $v }
    return $null
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
        if ($null -ne $n -and $n -gt 0) { $counts[$key] = [int] $n }
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

$segmentNames = @('model', 'context', 'cost', 'lines', 'limits', 'badges', 'folder', 'branch')
$segments = [System.Collections.Generic.List[hashtable]]::new()
foreach ($name in $segmentNames) {
    if (-not $cfg.Segments[$name]) { continue }
    $seg = switch ($name) {
        'model'   { Get-ModelSegment $d }
        'context' { Get-ContextSegment $d }
        'cost'    { Get-CostSegment $d }
        'lines'   { Get-LinesSegment $d $cfg }
        'limits'  { Get-LimitsSegment $d }
        'badges'  { Get-BadgesSegment $d }
        'folder'  { Get-FolderSegment $d }
        'branch'  { Get-BranchSegment $d $cfg }
    }
    if ($seg) { $segments.Add($seg) }
}
if ($segments.Count -eq 0) { Write-Host (C '36' "$iconModel claude"); exit 0 }

# Claude Code sets COLUMNS before running the script. Leave one column free to avoid the pending-wrap glitch.
$width = $null
$cols = 0
if ([int]::TryParse([string] $env:COLUMNS, [ref] $cols) -and $cols -gt 0) { $width = $cols - 1 }

$lineSets = @(if ($cfg.Layout -eq 'two') {
    @(@('model', 'folder', 'branch', 'badges'), @('context', 'limits', 'cost', 'lines'))
} else { , $segmentNames })

# A line that fits down to nothing is not printed. With model toggled off and a very narrow terminal
# that can mean no output at all, which is what the user asked for.
foreach ($names in $lineSets) {
    $onLine = foreach ($n in $names) { foreach ($s in $segments) { if ($s.Name -eq $n) { $s } } }
    $text = Get-FittedLine @($onLine) $cfg.Style $width
    if ($text) { Write-Host $text }
}
