#Requires -Version 7.0
# Claude Code subagent status line (PowerShell 7) with Nerd Font glyphs and ANSI colour.
# Wired up as the subagentStatusLine setting, which Claude Code runs for the agent panel. It is not
# the same contract as the main status line: the command is run once for the whole panel and gets one
# payload holding every live row, and it answers with one JSON object per line, {"id","content"},
# keyed by the task id. A line that is not JSON, or that misses either string field, is dropped.
#
# The payload (verified against the Claude Code 2.1.259 bundle):
#   session_id, transcript_path, cwd   the same base the main status line payload spreads
#   columns                            cells left for one row
#   tasks[]                            id, name, type, status, description, label, startTime, model,
#                                      effort, contextWindowSize, tokenCount, tokenSamples[], cwd
# Every field is optional and anything missing is left out, the same rule the main script follows.
#
# One line per row, no wrapping and no second row: the panel is not a full-width bar. No git probe,
# because a panel can hold several rows and each tick would pay for a git status per row. No config
# file either, so this script has no toggles.
#
# The helpers below, G, C, Get-VisibleWidth, Get-Palette, Get-ThresholdRole, Test-WideWindow, K,
# Get-FiniteNumber, Get-PayloadNumber and Test-PayloadText, are copied verbatim from statusline.ps1
# and test.ps1 checks that the two copies stay byte-identical. They cannot be shared by dot-sourcing:
# statusline.ps1 reads stdin to the end and prints as it loads, so loading it here would eat this
# script's payload and print a status line.
[CmdletBinding()]
param()
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# PowerShell strips ANSI colour when stdout is redirected unless told otherwise; the host always redirects it.
$PSStyle.OutputRendering = 'Ansi'

function G([int] $cp) { [char]::ConvertFromUtf32($cp) }
$e = [char]27
function C([string] $code, [string] $text) { "$e[${code}m$text$e[0m" }

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

# Colour bands for a percentage. Every caller passes both bands: the config's thresholds, 60 and 85 unless
# statusline.json moves them, which suit a 200k window, or the fixed 70 and 90 of a 1M window, because 85%
# of 1M still leaves 150k tokens, more than a whole fresh 200k session, so the config does not reach them.
# No defaults here: a caller that forgot the config would bind 0 and 0 and colour everything red.
function Get-ThresholdRole([int] $pct, [int] $Warn, [int] $Bad) { if ($pct -ge $Bad) { 'bad' } elseif ($pct -ge $Warn) { 'warn' } else { 'ok' } }

# The one window size that gets the 1M marker and the wider bands. Claude Code reports it as exactly 1000000.
function Test-WideWindow($size) { return $size -eq 1000000 }

# Thousands of tokens: 1.5k, 64k, 1.0M
function K([double] $n) { if ($n -ge 1000000) { '{0:N1}M' -f ($n / 1000000) } elseif ($n -ge 10000) { '{0:N0}k' -f ($n / 1000) } else { '{0:N1}k' -f ($n / 1000) } }

# A payload or state field as a finite double, or $null when it is not a number at all: missing, a
# boolean, a string, an array, NaN or infinite.
function Get-FiniteNumber($v) {
    if (-not ($v -is [ValueType]) -or $v -is [bool]) { return $null }
    $n = try { [double] $v } catch { return $null }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $null }
    return $n
}

# A payload value as a count, or $null when it is not one: a whole number that fits an Int32.
# ConvertFrom-Json hands 20.0 and 2e1 over as Double, so the floor test decides, not the type.
function Get-PayloadNumber($v) {
    $d = Get-FiniteNumber $v
    if ($null -eq $d -or $d -ne [math]::Floor($d)) { return $null }
    if ($d -gt [int]::MaxValue -or $d -lt [int]::MinValue) { return $null }
    return [int] $d
}

# Whether a payload value is text: a string with visible content and no control character. Numbers,
# arrays, objects, nulls, blank strings and strings carrying an escape (any Unicode Cc character, so
# the C0 range, DEL and the C1 range where U+009B, U+009C and U+009D are CSI, ST and OSC in their
# 8-bit forms) are not, so a subagent name cannot smuggle an escape sequence onto a panel row.
function Test-PayloadText($v) {
    return ($v -is [string] -and -not [string]::IsNullOrWhiteSpace($v) -and $v -notmatch '\p{Cc}')
}

# ---- Row parts ----

$iconModel = G 0xF06A9   # nf-md-robot, the same glyph the model segment uses
$palette = Get-Palette
$ellipsis = G 0x2026

# What to call the row: the agent's registered name, else its label (a progress summary, a bash
# command, a workflow name or a remote title), else the task description, else its type. $null when
# none of them is usable text, which leaves the row as the glyph and its progress.
function Get-RowIdentity($task) {
    foreach ($v in @($task.name, $task.label, $task.description, $task.type)) {
        if (Test-PayloadText $v) { return ([string] $v).Trim() }
    }
    return $null
}

# The progress side of a row as an ordered list of @{ Role; Text }: the context percentage when the
# task reports both a window size and a token count, then the token count itself, and the status word
# only when there is no figure at all. A window the payload gives as 0, as a fraction or as text
# yields no percentage rather than a division by zero or a rounded lie. A count below a thousand is
# left out: K would render it as 0.0k, which reads as a bug rather than as a task that has just started.
function Get-RowProgress($task) {
    $parts = @()
    $tokens = Get-PayloadNumber $task.tokenCount
    $size = Get-PayloadNumber $task.contextWindowSize
    if ($null -ne $tokens -and $tokens -ge 0 -and $null -ne $size -and $size -gt 0) {
        $pct = [int] [math]::Floor(($tokens / $size) * 100)
        if ($pct -lt 0) { $pct = 0 }
        if ($pct -gt 999) { $pct = 999 }
        $warn = if (Test-WideWindow $size) { 70 } else { 60 }
        $bad = if (Test-WideWindow $size) { 90 } else { 85 }
        $parts += @{ Role = (Get-ThresholdRole $pct $warn $bad); Text = "$pct%" }
    }
    if ($null -ne $tokens -and $tokens -ge 1000) {
        $parts += @{ Role = 'dim'; Text = (K $tokens) }
    } elseif ($parts.Count -eq 0 -and (Test-PayloadText $task.status)) {
        $parts += @{ Role = 'dim'; Text = ([string] $task.status).Trim() }
    }
    return $parts
}

# Plain text clipped to $Width cells, with a one-cell ellipsis when anything was cut. Measured by text
# element, so a surrogate pair or a combining sequence is never split down the middle. The result is
# never wider than $Width.
function Get-ClippedText([string] $Text, [int] $Width) {
    if ($Width -le 0) { return '' }
    if ((Get-VisibleWidth $Text) -le $Width) { return $Text }
    if ($Width -eq 1) { return $ellipsis }
    $out = ''
    $used = 0
    $en = [System.Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($en.MoveNext()) {
        $el = [string] $en.Current
        $w = Get-VisibleWidth $el
        if ($used + $w -gt $Width - 1) { break }
        $out += $el
        $used += $w
    }
    return $out + $ellipsis
}

# One panel row: the robot glyph and the identity in the model colour, then the progress parts, each
# after two spaces. $Width of 0 means the payload gave no usable columns, so nothing is cut. Fitting
# keeps the figures and clips the identity first, because a percentage that has been dropped looks
# like a task reporting nothing; only when the identity is down to fewer than three cells does a
# progress part go, right to left. The glyph is never dropped, so a row always renders.
function Format-SubagentRow($task, [int] $Width) {
    $identity = Get-RowIdentity $task
    $progress = @(Get-RowProgress $task)
    $shown = ''
    while ($true) {
        $tail = ''
        foreach ($p in $progress) { $tail += '  ' + $p.Text }
        $budget = if ($Width -gt 0) { $Width - (Get-VisibleWidth $iconModel) - (Get-VisibleWidth $tail) - 1 } else { [int]::MaxValue }
        if ($identity -and $budget -ge 3) { $shown = Get-ClippedText $identity $budget; break }
        if (-not $identity -and $budget -ge 0) { break }
        if ($progress.Count -eq 0) { break }
        $progress = if ($progress.Count -eq 1) { @() } else { @($progress[0..($progress.Count - 2)]) }
    }
    $text = C $palette.Roles.model.Sgr ($iconModel + $(if ($shown) { " $shown" } else { '' }))
    foreach ($p in $progress) { $text += '  ' + (C $palette.Roles[$p.Role].Sgr $p.Text) }
    # Last guard: a row that still overflows falls back to the glyph on its own rather than pushing the
    # panel into a wrap. Nothing above should reach here; the check costs one measurement per row.
    if ($Width -gt 0 -and (Get-VisibleWidth $text) -gt $Width) { return C $palette.Roles.model.Sgr $iconModel }
    return $text
}

# ---- Render ----
# Anything unusable prints nothing and exits 0. A bare glyph is not valid JSON, so it cannot stand in
# for a whole-payload failure the way the main script's fallback line does; the per-row fallback below
# covers a task whose own fields are all unusable.
$raw = [Console]::In.ReadToEnd()
$d = $null
if ($raw) { try { $d = $raw | ConvertFrom-Json } catch { $d = $null } }
if ($d -isnot [System.Management.Automation.PSCustomObject]) { exit 0 }
$tasks = $d.tasks
if ($tasks -isnot [System.Object[]]) { exit 0 }

$width = Get-PayloadNumber $d.columns
if ($null -eq $width -or $width -lt 0) { $width = 0 }

# A row only renders when its id comes back, so a task without usable text for an id is skipped, and a
# repeated id is answered once: the panel keys its map by id and a second line would only overwrite.
$seen = @{}
foreach ($task in $tasks) {
    if ($task -isnot [System.Management.Automation.PSCustomObject]) { continue }
    $id = $task.id
    if (-not (Test-PayloadText $id)) { continue }
    if ($seen[$id]) { continue }
    $seen[$id] = $true
    $content = try { Format-SubagentRow $task $width } catch { C $palette.Roles.model.Sgr $iconModel }
    if (-not $content) { $content = C $palette.Roles.model.Sgr $iconModel }
    Write-Host ([pscustomobject]@{ id = $id; content = $content } | ConvertTo-Json -Compress -Depth 3)
}
