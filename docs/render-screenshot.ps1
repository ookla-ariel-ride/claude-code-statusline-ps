#Requires -Version 7.0
# Renders statusline.ps1 output for a demo payload to a PNG using the installed Nerd Font.
# Run from anywhere:
#   pwsh docs/render-screenshot.ps1                                                         # docs/statusline.png
#   pwsh docs/render-screenshot.ps1 -Config docs/statusline-two-line.json -Out docs/statusline-two-line.png
param(
    [string] $Repo = (Split-Path $PSScriptRoot -Parent),
    [string] $Out = (Join-Path $PSScriptRoot 'statusline.png'),
    [string] $Config
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$PSStyle.OutputRendering = 'Ansi'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8   # decode the child's UTF-8 output correctly
# The other half of the same contract, and the half that is easy to forget: $OutputEncoding is what a
# payload piped to a native command is encoded WITH. statusline.ps1 now decodes its stdin as UTF-8
# whatever the console says, so saying it here too is what makes a demo payload with a name that is
# not English survive the trip; the default is already UTF-8, and this script runs with the user's
# profile loaded, which is free to have changed it.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# THE CLOCK IS PINNED, and that is what makes these two PNGs regenerate to the same bytes on every run
# on one machine. statusline.ps1 reads its clock once and CLAUDE_STATUSLINE_NOW replaces that reading,
# so the child render below measures the payload's expiries against the same instant this script builds
# them from, and the `time` segment in the two-line shot draws this instant's wall clock instead of
# whatever time the capture happened at. The offset is the zone rule: +00:00 here means the two-line
# shot reads 14:05 whatever zone the machine is in.
# What is pinned is the TEXT of the render, not the image. Everything below the render - GDI+'s
# rasteriser, the display's DPI and ClearType settings, the installed version of JetBrainsMono NF, the
# Windows build - still chooses the pixels, so two different machines can draw the same line into
# different bytes. Regenerating on the machine that last regenerated leaves git clean; that is the
# promise, and it is the one that stops a docs PR carrying a binary diff.
# Any instant would do; this one is the 14:05 the README and docs/segments.md already print as the
# example wall clock, so the image and the prose agree.
$fixedNow = '2026-01-15T14:05:00+00:00'
$now = [DateTimeOffset]::Parse($fixedNow, [System.Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds()
# One payload feeds both screenshots; only -Config differs between them. The default (one-line,
# no -Config) render shows the eleven segments that ship Default = $true; docs/statusline-two-line.json
# turns the twelfth, `time`, on with "segments": { "time": true }, so the two-line shot is the one that
# shows all twelve.
# The base is samples/06-limits-badges-lines.json itself, not a hand-typed copy of its fields: that
# sample is what test.ps1 exercises a golden render against in several places, so the hero image and
# the suite read the same numbers by construction. Only the fields the sample does not carry, or that
# need a value relative to render time, are overlaid on top of it.
$payload = Get-Content -Raw (Join-Path $Repo 'samples/06-limits-badges-lines.json') | ConvertFrom-Json -AsHashtable

# Both reset times are still nudged to the middle of a minute rather than the top of one. The drift
# they were put there for is gone - this script and the child now share one pinned instant, so a
# countdown cannot land a minute short of the other screenshot's - but mid-minute is also where a
# figure is furthest from the boundary that would change it, so a later change to the pinned instant,
# or a render taken with the pin lifted, still prints these numbers rather than the ones below them.
$payload.rate_limits.five_hour.resets_at = $now + 4350    # 1h12m30s out -> "(1h12m)"
$payload.rate_limits.seven_day.resets_at = $now + 400000  # never printed as a countdown; just fresh
$payload.prompt_cache = @{ warm = $true; expires_at = $now + 2550 }  # 42m30s out -> "cache 42m"
$payload.effort.level = 'medium'   # the sample's own 'xhigh' already clears the default; this demo
                                    # wants a plausible value rather than the most extreme one
$payload.agent = @{ name = 'reviewer' }
$payload.session_name = 'release prep'
$payload.pr = @{ number = 12; url = 'https://github.com/octo/my-project/pull/12'; review_state = 'approved' }
$payload.git.status = @{ staged = 1; modified = 2; untracked = 1 }
$payload = $payload | ConvertTo-Json -Depth 5

$scriptArgs = @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', (Join-Path $Repo 'statusline.ps1'))
if ($Config) { $scriptArgs += @('-Config', (Resolve-Path $Config).Path) }
Remove-Item Env:COLUMNS -ErrorAction SilentlyContinue
# The pin is set for the length of the child render and PUT BACK, rather than left on the process. The
# header says to run this file with `pwsh docs/render-screenshot.ps1`, where the process is this render
# and nothing else - but `.\docs\render-screenshot.ps1`, `& ...` and a dot-source all run it in a shell
# that goes on living, and a variable left behind there pins every later status line in that shell:
# `time` frozen at 14:05 all day, a real cache expiry refused by the 86400-second ceiling and printed
# as a bare "cache warm", a reset an hour out rendered as "(238d)". Restoring what was there also means
# a caller who had pinned the clock deliberately gets their own value back rather than nothing.
$oldPin = $env:CLAUDE_STATUSLINE_NOW
try {
    $env:CLAUDE_STATUSLINE_NOW = $fixedNow
    $rows = @($payload | pwsh @scriptArgs)
} finally {
    if ($null -ne $oldPin) { $env:CLAUDE_STATUSLINE_NOW = $oldPin } else { Remove-Item Env:CLAUDE_STATUSLINE_NOW -ErrorAction SilentlyContinue }
}

# One Half Dark palette for the 16 system colours; the 256-colour cube and greys are computed.
$palette = @{ 30 = '#282C34'; 31 = '#E06C75'; 32 = '#98C379'; 33 = '#E5C07B'; 34 = '#61AFEF'; 35 = '#C678DD'; 36 = '#56B6C2'; 37 = '#DCDFE4'; 90 = '#5C6370'
              91 = '#E06C75'; 92 = '#98C379'; 93 = '#E5C07B'; 94 = '#61AFEF'; 95 = '#C678DD'; 96 = '#56B6C2'; 97 = '#FFFFFF' }
$fg = [System.Drawing.ColorTranslator]::FromHtml('#DCDFE4')
$bg = [System.Drawing.ColorTranslator]::FromHtml('#282C34')
function ConvertFrom-Xterm256([int] $n) {
    if ($n -lt 8) { return [System.Drawing.ColorTranslator]::FromHtml($palette[30 + $n]) }
    if ($n -lt 16) { return [System.Drawing.ColorTranslator]::FromHtml($palette[90 + $n - 8]) }
    if ($n -ge 232) { $v = 8 + 10 * ($n - 232); return [System.Drawing.Color]::FromArgb($v, $v, $v) }
    $n -= 16
    $levels = @(0, 95, 135, 175, 215, 255)
    return [System.Drawing.Color]::FromArgb($levels[[math]::Floor($n / 36)], $levels[[math]::Floor(($n % 36) / 6)], $levels[$n % 6])
}

# Parse each row's SGR sequences into runs of (text, fg, bg, bold). Any OSC string (either terminator,
# ESC \ or BEL) is skipped the way Get-VisibleWidth strips them and test.ps1's $ansiPattern matches
# them - an OSC 8 hyperlink wrapper or the OSC 9;4 taskbar sequence alike. `taskbar` defaults to false,
# so no OSC 9;4 reaches a screenshot render today, but a render with it turned on would otherwise draw
# the raw escape sequence into the image as literal text instead of a hidden zero-width run.
$esc = [char]27
$pattern = "$esc\[([0-9;]*)m|$esc\][^\a$esc]*(?:\a|$esc\\)"
$rowRuns = @(foreach ($line in $rows) {
    $runs = [System.Collections.Generic.List[object]]::new()
    $colour = $fg; $back = $null; $bold = $false
    $pos = 0
    foreach ($m in [regex]::Matches($line, $pattern)) {
        if ($m.Index -gt $pos) { $runs.Add(@{ text = $line.Substring($pos, $m.Index - $pos); colour = $colour; back = $back; bold = $bold }) }
        $pos = $m.Index + $m.Length
        if (-not $m.Groups[1].Success) { continue }
        $codes = @($m.Groups[1].Value -split ';' | ForEach-Object { if ($_ -eq '') { 0 } else { [int] $_ } })
        for ($i = 0; $i -lt $codes.Count; $i++) {
            $code = $codes[$i]
            if ($code -eq 0) { $colour = $fg; $back = $null; $bold = $false }
            elseif ($code -eq 1) { $bold = $true }
            elseif ($code -eq 22) { $bold = $false }
            elseif ($code -eq 39) { $colour = $fg }
            elseif ($code -eq 49) { $back = $null }
            elseif ($code -eq 38 -and $codes[$i + 1] -eq 5) { $colour = ConvertFrom-Xterm256 $codes[$i + 2]; $i += 2 }
            elseif ($code -eq 48 -and $codes[$i + 1] -eq 5) { $back = ConvertFrom-Xterm256 $codes[$i + 2]; $i += 2 }
            elseif ($palette.ContainsKey($code)) { $colour = [System.Drawing.ColorTranslator]::FromHtml($palette[$code]) }
        }
    }
    if ($pos -lt $line.Length) { $runs.Add(@{ text = $line.Substring($pos); colour = $colour; back = $back; bold = $bold }) }
    , $runs
})

$scale = 2
$fontSize = 13 * $scale
$pad = 14 * $scale
$regular = [System.Drawing.Font]::new('JetBrainsMono NF', $fontSize, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$boldFont = [System.Drawing.Font]::new('JetBrainsMono NF', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$fmt = [System.Drawing.StringFormat]::GenericTypographic
$fmt.FormatFlags = $fmt.FormatFlags -bor [System.Drawing.StringFormatFlags]::MeasureTrailingSpaces

# Measure
$probe = [System.Drawing.Bitmap]::new(10, 10)
$g = [System.Drawing.Graphics]::FromImage($probe)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$width = 0
foreach ($runs in $rowRuns) {
    $w = 0
    foreach ($r in $runs) { $f = if ($r.bold) { $boldFont } else { $regular }; $w += $g.MeasureString($r.text, $f, 10000, $fmt).Width }
    $width = [math]::Max($width, $w)
}
$lineHeight = $regular.GetHeight($g)
$g.Dispose(); $probe.Dispose()

$bmp = [System.Drawing.Bitmap]::new([int] ($width + 2 * $pad), [int] ($lineHeight * $rowRuns.Count + 2 * $pad))
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear($bg)
$y = [float] $pad
foreach ($runs in $rowRuns) {
    $x = [float] $pad
    foreach ($r in $runs) {
        $f = if ($r.bold) { $boldFont } else { $regular }
        $w = $g.MeasureString($r.text, $f, 10000, $fmt).Width
        if ($r.back) {
            $bb = [System.Drawing.SolidBrush]::new($r.back)
            $g.FillRectangle($bb, $x, $y, $w, $lineHeight)
            $bb.Dispose()
        }
        $brush = [System.Drawing.SolidBrush]::new($r.colour)
        $g.DrawString($r.text, $f, $brush, $x, $y, $fmt)
        $brush.Dispose()
        $x += $w
    }
    $y += $lineHeight
}
$g.Dispose()
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
"wrote $Out ($($bmp.Width) x $($bmp.Height))"
$bmp.Dispose()
foreach ($line in $rows) { $line -replace $esc, '<ESC>' }
