#Requires -Version 7.0
# Claude Code status line (PowerShell 7) with Nerd Font glyphs and ANSI colour.
# Requires a Nerd Font in the terminal (install.ps1 can set up JetBrainsMono Nerd Font).
# Reads the JSON Claude Code pipes on stdin and prints one line, e.g.
#   󰚩 Fable 5.1  󰍛 37% ████░░░░░░   $0.43   my-project   main
# Glyphs are emitted from code points so the file's own encoding never matters.
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
