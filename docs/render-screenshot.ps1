#Requires -Version 7.0
# Renders statusline.ps1 output for a demo payload to docs/statusline.png using the installed Nerd Font.
# Run from anywhere:  pwsh docs/render-screenshot.ps1
param(
    [string] $Repo = (Split-Path $PSScriptRoot -Parent),
    [string] $Out = (Join-Path $PSScriptRoot 'statusline.png')
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
    git            = @{ branch = 'main'; status = 'clean' }
} | ConvertTo-Json -Depth 5

$line = ($payload | pwsh -NoProfile -NoLogo -NonInteractive -File (Join-Path $Repo 'statusline.ps1')) -join ''

# One Half Dark palette
$palette = @{ 30 = '#282C34'; 31 = '#E06C75'; 32 = '#98C379'; 33 = '#E5C07B'; 34 = '#61AFEF'; 35 = '#C678DD'; 36 = '#56B6C2'; 37 = '#DCDFE4'; 90 = '#5C6370' }
$fg = [System.Drawing.ColorTranslator]::FromHtml('#DCDFE4')
$bg = [System.Drawing.ColorTranslator]::FromHtml('#282C34')

# Parse SGR sequences into runs of (text, colour, bold)
$runs = [System.Collections.Generic.List[object]]::new()
$colour = $fg; $bold = $false
$esc = [char]27
$pattern = "$esc\[([0-9;]*)m"
$pos = 0
foreach ($m in [regex]::Matches($line, $pattern)) {
    if ($m.Index -gt $pos) { $runs.Add(@{ text = $line.Substring($pos, $m.Index - $pos); colour = $colour; bold = $bold }) }
    foreach ($code in ($m.Groups[1].Value -split ';')) {
        switch ([int]$code) {
            0 { $colour = $fg; $bold = $false }
            1 { $bold = $true }
            default { if ($palette.ContainsKey([int]$code)) { $colour = [System.Drawing.ColorTranslator]::FromHtml($palette[[int]$code]) } }
        }
    }
    $pos = $m.Index + $m.Length
}
if ($pos -lt $line.Length) { $runs.Add(@{ text = $line.Substring($pos); colour = $colour; bold = $bold }) }

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
foreach ($r in $runs) { $f = if ($r.bold) { $boldFont } else { $regular }; $width += $g.MeasureString($r.text, $f, 10000, $fmt).Width }
$lineHeight = $regular.GetHeight($g)
$g.Dispose(); $probe.Dispose()

$bmp = [System.Drawing.Bitmap]::new([int]($width + 2 * $pad), [int]($lineHeight + 2 * $pad))
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear($bg)
$x = [float]$pad
foreach ($r in $runs) {
    $f = if ($r.bold) { $boldFont } else { $regular }
    $brush = [System.Drawing.SolidBrush]::new($r.colour)
    $g.DrawString($r.text, $f, $brush, $x, [float]$pad, $fmt)
    $x += $g.MeasureString($r.text, $f, 10000, $fmt).Width
    $brush.Dispose()
}
$g.Dispose()
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"wrote $Out ($([int]$width + 2 * $pad) x $([int]$lineHeight + 2 * $pad))"
$line -replace $esc, '<ESC>'
