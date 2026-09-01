# Claude Code status line (PowerShell 7) with Nerd Font glyphs and ANSI colour.
# Requires a Nerd Font in the terminal (JetBrainsMono Nerd Font is installed; Windows Terminal is set to it).
# Reads the JSON Claude Code pipes on stdin and prints one line, e.g.
#   󰚩 Fable 5.1  󰍛 37% ████░░░░░░   $0.43   Phi-Silica-OpenAI   main
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
$sep = ' ' + (C '90' (G 0xE0B1)) + ' '   # powerline thin separator, dim

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
