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

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$payload = [ordered]@{
    model          = @{ display_name = 'Fable 5.1' }
    context_window = @{ total_input_tokens = 60000; total_output_tokens = 4000; context_window_size = 200000; used_percentage = 32 }
    cost           = @{ total_cost_usd = 1.07; total_lines_added = 156; total_lines_removed = 23 }
    rate_limits    = @{ five_hour = @{ used_percentage = 23.5; resets_at = $now + 4320 }; seven_day = @{ used_percentage = 41.2; resets_at = $now + 400000 } }
    fast_mode      = $true
    thinking       = @{ enabled = $true }
    effort         = @{ level = 'high' }
    workspace      = @{ current_dir = 'C:\Users\jim\src\my-project' }
    git            = @{ branch = 'main'; status = @{ staged = 1; modified = 2; untracked = 1 } }
} | ConvertTo-Json -Depth 5

$scriptArgs = @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', (Join-Path $Repo 'statusline.ps1'))
if ($Config) { $scriptArgs += @('-Config', (Resolve-Path $Config).Path) }
Remove-Item Env:COLUMNS -ErrorAction SilentlyContinue
$rows = @($payload | pwsh @scriptArgs)

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

# Parse each row's SGR sequences into runs of (text, fg, bg, bold)
$esc = [char]27
$pattern = "$esc\[([0-9;]*)m"
$rowRuns = @(foreach ($line in $rows) {
    $runs = [System.Collections.Generic.List[object]]::new()
    $colour = $fg; $back = $null; $bold = $false
    $pos = 0
    foreach ($m in [regex]::Matches($line, $pattern)) {
        if ($m.Index -gt $pos) { $runs.Add(@{ text = $line.Substring($pos, $m.Index - $pos); colour = $colour; back = $back; bold = $bold }) }
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
        $pos = $m.Index + $m.Length
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
