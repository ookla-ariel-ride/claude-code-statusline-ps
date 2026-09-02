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
$iconLines  = G 0xF121    # nf-fa-code  (lines added/removed)
$iconLimit  = G 0xF0E4    # nf-fa-tachometer (rate limits)
$iconFast   = G 0xF0E7    # nf-fa-bolt  (fast mode)
$iconThink  = G 0xF09D0   # nf-md-brain (extended thinking)
$iconEffort = G 0xF04C5   # nf-md-speedometer (effort level)
$iconVim    = G 0xE62B    # nf-custom-vim
$sep = ' ' + (C '90' (G 0xE0B1)) + ' '   # powerline thin separator, dim
$defaultEffort = 'high'   # effort badge is hidden at this level

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Used in later tasks')]
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
# Stage 1 swaps limits then context for their Short form. Stage 2 drops whole segments in a fixed order.
# The model segment is never dropped and may overflow on its own. Returns $null when nothing is left.
function Get-FittedLine($Segments, [string] $Style, $Width) {
    $segs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($s in $Segments) { if ($s) { $segs.Add($s.Clone()) } }
    if ($segs.Count -eq 0) { return $null }
    $line = Format-Line $segs $Style
    if ($null -eq $Width) { return $line }
    $target = [int] $Width
    if ((Get-VisibleWidth $line) -le $target) { return $line }
    foreach ($name in @('limits', 'context')) {
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

if (-not $Config) { $Config = Join-Path $PSScriptRoot 'statusline.json' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Used in later tasks')]
$statusConfig = Read-StatusConfig $Config

$raw = [Console]::In.ReadToEnd()
try { $d = $raw | ConvertFrom-Json } catch { Write-Host (C '36' "$iconModel claude"); exit 0 }

$parts = [System.Collections.Generic.List[string]]::new()

$model = $d.model.display_name
if ($model) { $parts.Add((C '1;36' "$iconModel $model")) }

$pct = $d.context_window.used_percentage
if ($null -ne $pct) {
    $pct = [int]$pct
    $filled = [math]::Round($pct / 10)
    $bar = ((G 0x2588) * $filled) + ((G 0x2591) * (10 - $filled))
    $colour = if ($pct -ge 85) { '31' } elseif ($pct -ge 60) { '33' } else { '32' }

    # used/total in thousands of tokens, when the payload carries the counts.
    function K([double] $n) { if ($n -ge 1000000) { '{0:N1}M' -f ($n / 1000000) } elseif ($n -ge 10000) { '{0:N0}k' -f ($n / 1000) } else { '{0:N1}k' -f ($n / 1000) } }
    $used = [double]($d.context_window.total_input_tokens ?? 0) + [double]($d.context_window.total_output_tokens ?? 0)
    $size = $d.context_window.context_window_size
    $counts = if ($used -gt 0 -and $size) { " $(K $used)/$(K $size)" } elseif ($used -gt 0) { " $(K $used)" } else { '' }

    $parts.Add((C $colour "$iconCtx $pct% $bar$counts"))
}

$cost = $d.cost.total_cost_usd
if ($null -ne $cost) { $parts.Add((C '90' ("$iconCost `$" + ('{0:N2}' -f [double]$cost)))) }

# Lines added/removed this session; shown when either is non-zero.
$added = [int]($d.cost.total_lines_added ?? 0)
$removed = [int]($d.cost.total_lines_removed ?? 0)
if ($added -gt 0 -or $removed -gt 0) {
    $parts.Add((C '90' $iconLines) + ' ' + (C '32' "+$added") + ' ' + (C '31' ((G 0x2212) + "$removed")))
}

# Rate limits: 5-hour and 7-day usage, plus time until the 5-hour window resets.
$rl = $d.rate_limits
if ($rl -and ($null -ne $rl.five_hour.used_percentage -or $null -ne $rl.seven_day.used_percentage)) {
    # " (1h12m)" or " (3d)" until the given epoch; empty when absent or already past.
    function TimeLeft([object] $epoch) {
        if ($null -eq $epoch) { return '' }
        $left = [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch) - [DateTimeOffset]::UtcNow
        if ($left.TotalMinutes -lt 1) { return '' }
        if ($left.TotalHours -ge 48) { return ' ({0}d)' -f [int][math]::Floor($left.TotalDays) }
        return ' ({0}h{1:00}m)' -f [int][math]::Floor($left.TotalHours), $left.Minutes
    }
    $bits = [System.Collections.Generic.List[string]]::new()
    $worst = 0
    $h5 = $rl.five_hour.used_percentage
    if ($null -ne $h5) { $h5 = [int][math]::Round([double]$h5); $worst = [math]::Max($worst, $h5); $bits.Add("5h $h5%$(TimeLeft $rl.five_hour.resets_at)") }
    $d7 = $rl.seven_day.used_percentage
    if ($null -ne $d7) { $d7 = [int][math]::Round([double]$d7); $worst = [math]::Max($worst, $d7); $bits.Add("7d $d7%") }
    $colour = if ($worst -ge 85) { '31' } elseif ($worst -ge 60) { '33' } else { '32' }
    $parts.Add((C $colour "$iconLimit $($bits -join ' ')"))
}

# Session mode badges: fast mode, thinking, non-default effort, vim mode. Omitted when nothing is on.
$badges = [System.Collections.Generic.List[string]]::new()
if ($d.fast_mode -eq $true) { $badges.Add($iconFast) }
if ($d.thinking.enabled -eq $true) { $badges.Add($iconThink) }
$effort = $d.effort.level
if ($effort -and $effort -ne $defaultEffort) { $badges.Add("$iconEffort $effort") }
$vim = $d.vim.mode
if ($vim) { $badges.Add("$iconVim $vim") }
if ($badges.Count -gt 0) { $parts.Add((C '90' ($badges -join ' '))) }

$dir = $d.workspace.current_dir
if ($dir) { $parts.Add((C '34' "$iconFolder $(Split-Path $dir -Leaf)")) }

$branch = $d.git.branch
if ($branch) {
    $dirty = $false
    $status = $d.git.status
    if ($status -is [string]) { $dirty = $status -and $status -ne 'clean' }
    elseif ($status) {
        # Counts arrive as Int64 from ConvertFrom-Json; treat any positive numeric or "true" as dirty.
        foreach ($p in $status.PSObject.Properties) {
            $v = $p.Value
            if (($v -is [ValueType] -and -not ($v -is [bool]) -and [double]$v -gt 0) -or ($v -is [bool] -and $v)) { $dirty = $true }
        }
    }

    $isMain = $branch -in @('main', 'master')
    $icon = if ($isMain) { $iconHome } else { $iconBranch }
    $text = "$icon $branch"
    if ($dirty) { $text += " $iconDirty" }
    $parts.Add((C ($(if ($dirty) { '33' } else { '35' })) $text))
}

if ($parts.Count -eq 0) { $parts.Add((C '36' "$iconModel claude")) }
Write-Host ($parts -join $sep)
