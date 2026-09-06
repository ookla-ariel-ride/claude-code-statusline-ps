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
    fire        = 0xF0238
    cash        = 0xF0114
    code        = 0xF121
    tachometer  = 0xF0E4
    bolt        = 0xF0E7
    brain       = 0xF09D1
    speedometer = 0xF04C5
    'timer-outline' = 0xF051B
    'clock-outline' = 0xF0150
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
$pad = 4

function Format-Number([double] $n) { $n.ToString('0.##', $inv) }

# chevron and arrow are not icons: they are the powerline divider and arrow Format-Line draws between
# segments, and they are deliberately drawn edge to edge to butt up against the next block with no gap,
# which is why their own tight bounds already run the full height of the shared em box (a coincidence
# confirmed below, not assumed). branch (the git-branch glyph, used only for a non-default branch name)
# is cut from the same cloth: a single stroke, narrower by design than a filled icon, the same way a
# lower-case "l" is narrower than an "m" in the same font. Folding any of the three into the shared frame
# below would not make the table more even - it would stretch a deliberately thin mark to look like a
# square icon it was never drawn to be. They keep rendering from their own tight bounds, exactly as
# before this change.
$scaleExempt = @('chevron', 'arrow', 'branch')

# First pass: build every glyph's outline and measure its own tight bounds, without writing anything yet.
$glyphs = [ordered]@{}
foreach ($entry in $icons.GetEnumerator()) {
    $name = $entry.Key
    $text = [char]::ConvertFromUtf32($entry.Value)
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddString($text, $family, [int][System.Drawing.FontStyle]::Regular, $emSize, [System.Drawing.PointF]::new(0, 0), $fmt)
    if ($path.PointCount -eq 0) { Write-Warning "$name (U+$($entry.Value.ToString('X'))) has no outline in $FontFamily"; $path.Dispose(); continue }

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

    $glyphs[$name] = @{ D = $d.ToString(); Bounds = $path.GetBounds(); PointCount = $path.PointCount }
    $path.Dispose()
}

# The shared vertical scale: the union of the Y-extent of every icon EXCEPT the three exempted above,
# taken from the glyphs actually in the table rather than the font's own ascent/descent metrics. Those
# metrics measured 102/30 (Cell Ascent/Descent) on JetBrainsMono NF - a box padded to fit accented
# capitals and the tall powerline marks this font also carries, about 40% taller than any ordinary icon
# in this table actually uses. A shared frame built from that box shrank every icon by roughly a third to
# stay clear of ink none of them have, which fixed cash's width by making everything else worse. The
# union of the icons that are meant to look alike is already exactly where most of them already sit
# (several land within a fraction of a unit of each other), so cash grows up to meet its neighbours
# instead of all of them shrinking down to meet cash.
$scaleTop = [double]::PositiveInfinity
$scaleBottom = [double]::NegativeInfinity
foreach ($entry in $glyphs.GetEnumerator()) {
    if ($scaleExempt -contains $entry.Key) { continue }
    $b = $entry.Value.Bounds
    if ($b.Y -lt $scaleTop) { $scaleTop = $b.Y }
    if (($b.Y + $b.Height) -gt $scaleBottom) { $scaleBottom = $b.Y + $b.Height }
}

# Second pass: write each SVG. An exempt glyph keeps its own tight bounds on every axis, exactly as
# before; every other glyph takes its X and width from its own bounds (unlike Y, a glyph's natural width
# already tells you how wide it should look, and cash's neighbours are not made of unevenly-wide glyphs)
# but takes its Y and height from the shared frame computed above, so every icon in the table is drawn
# against the same vertical scale and only the truly different marks are left out of it.
foreach ($entry in $glyphs.GetEnumerator()) {
    $name = $entry.Key
    $b = $entry.Value.Bounds
    if ($scaleExempt -contains $name) {
        $y = $b.Y; $height = $b.Height
    } else {
        $y = $scaleTop; $height = $scaleBottom - $scaleTop
    }
    $viewBox = "$(Format-Number ($b.X - $pad)) $(Format-Number ($y - $pad)) $(Format-Number ($b.Width + 2 * $pad)) $(Format-Number ($height + 2 * $pad))"
    $svg = "<svg xmlns=`"http://www.w3.org/2000/svg`" viewBox=`"$viewBox`" height=`"20`" role=`"img`" aria-label=`"$name`"><path fill=`"$Fill`" fill-rule=`"evenodd`" d=`"$($entry.Value.D)`"/></svg>"
    $file = Join-Path $OutDir "$name.svg"
    [System.IO.File]::WriteAllText($file, $svg, [System.Text.UTF8Encoding]::new($false))
    '{0,-12} {1,5} points  {2,6} bytes' -f $name, $entry.Value.PointCount, (Get-Item $file).Length
}
