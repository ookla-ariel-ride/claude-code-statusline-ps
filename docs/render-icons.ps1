#Requires -Version 7.0
# Extracts the Nerd Font glyphs used by statusline.ps1 as SVG outlines into docs/icons/, so the README
# can show them on GitHub, which cannot render the font itself.
# Run from anywhere:  pwsh docs/render-icons.ps1
param(
    [string] $OutDir = (Join-Path $PSScriptRoot 'icons'),
    [string] $FontFamily = 'JetBrainsMono NF',
    [string] $Fill = '#8b949e'   # GitHub's muted foreground; legible on light and dark themes
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$icons = [ordered]@{
    robot       = 0xF06A9
    memory      = 0xF035B
    cash        = 0xF0155
    code        = 0xF121
    tachometer  = 0xF0E4
    bolt        = 0xF0E7
    brain       = 0xF09D0
    speedometer = 0xF04C5
    vim         = 0xE62B
    user        = 0xF007
    tag         = 0xF02B
    'folder-open' = 0xF07C
    home        = 0xF015
    branch      = 0xE0A0
    pencil      = 0xF040
    fork        = 0xF04C1
    'pull-request' = 0xF407
    chevron     = 0xE0B1
    arrow       = 0xE0B0
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$family = [System.Drawing.FontFamily]::new($FontFamily)
$emSize = 100
$fmt = [System.Drawing.StringFormat]::GenericTypographic
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Format-Number([double] $n) { $n.ToString('0.##', $inv) }

foreach ($entry in $icons.GetEnumerator()) {
    $name = $entry.Key
    $text = [char]::ConvertFromUtf32($entry.Value)
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddString($text, $family, [int][System.Drawing.FontStyle]::Regular, $emSize, [System.Drawing.PointF]::new(0, 0), $fmt)
    if ($path.PointCount -eq 0) { Write-Warning "$name (U+$($entry.Value.ToString('X'))) has no outline in $FontFamily"; continue }

    # Walk the flattened path and emit SVG commands. Types: 0 start, 1 line, 3 cubic bezier; 0x80 closes the figure.
    $d = [System.Text.StringBuilder]::new()
    $points = $path.PathPoints
    $types = $path.PathTypes
    $i = 0
    while ($i -lt $points.Count) {
        $t = $types[$i]
        $kind = $t -band 7
        switch ($kind) {
            0 { [void]$d.Append("M$(Format-Number $points[$i].X) $(Format-Number $points[$i].Y)"); $i++ }
            1 { [void]$d.Append("L$(Format-Number $points[$i].X) $(Format-Number $points[$i].Y)"); $i++ }
            3 {
                [void]$d.Append("C$(Format-Number $points[$i].X) $(Format-Number $points[$i].Y) $(Format-Number $points[$i+1].X) $(Format-Number $points[$i+1].Y) $(Format-Number $points[$i+2].X) $(Format-Number $points[$i+2].Y)")
                $t = $types[$i + 2]
                $i += 3
            }
            default { $i++ }
        }
        if ($t -band 0x80) { [void]$d.Append('Z') }
    }

    $b = $path.GetBounds()
    $pad = 4
    $viewBox = "$(Format-Number ($b.X - $pad)) $(Format-Number ($b.Y - $pad)) $(Format-Number ($b.Width + 2 * $pad)) $(Format-Number ($b.Height + 2 * $pad))"
    $svg = "<svg xmlns=`"http://www.w3.org/2000/svg`" viewBox=`"$viewBox`" height=`"20`" role=`"img`" aria-label=`"$name`"><path fill=`"$Fill`" fill-rule=`"evenodd`" d=`"$($d.ToString())`"/></svg>"
    $file = Join-Path $OutDir "$name.svg"
    [System.IO.File]::WriteAllText($file, $svg, [System.Text.UTF8Encoding]::new($false))
    '{0,-12} {1,5} points  {2,6} bytes' -f $name, $path.PointCount, (Get-Item $file).Length
    $path.Dispose()
}
