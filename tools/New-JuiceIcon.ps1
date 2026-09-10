<#
    Generates assets/juice.ico (a glass of juice) so the installer and its
    shortcuts have a real icon. Pure GDI+ drawing, no binary assets in the repo.
#>

[CmdletBinding()]
param(
    [string]$OutputPath
)

# $PSScriptRoot is not populated while parameter defaults are bound, so the
# default output path is resolved here instead.
if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\juice.ico'
}

Add-Type -AssemblyName System.Drawing

function New-JuiceBitmap {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    # Everything below is authored on a 256x256 grid and scaled to $Size.
    $g.ScaleTransform($Size / 256.0, $Size / 256.0)

    $juicePath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $juicePath.AddPolygon(@(
        (New-Object System.Drawing.PointF(64, 92)),
        (New-Object System.Drawing.PointF(192, 92)),
        (New-Object System.Drawing.PointF(172, 224)),
        (New-Object System.Drawing.PointF(84, 224))
    ))
    $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF(0, 92)),
        (New-Object System.Drawing.PointF(0, 224)),
        [System.Drawing.Color]::FromArgb(255, 176, 59),
        [System.Drawing.Color]::FromArgb(233, 112, 32))
    $g.FillPath($fill, $juicePath)
    $fill.Dispose(); $juicePath.Dispose()

    # Straw, drawn before the outline so the glass edge sits on top of it.
    $straw = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(228, 90, 90)), 18
    $straw.StartCap = 'Round'; $straw.EndCap = 'Round'
    $g.DrawLine($straw, 168, 24, 118, 150)
    $straw.Dispose()

    $outline = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(96, 66, 40)), 12
    $outline.LineJoin = 'Round'
    $g.DrawPolygon($outline, @(
        (New-Object System.Drawing.PointF(56, 56)),
        (New-Object System.Drawing.PointF(200, 56)),
        (New-Object System.Drawing.PointF(172, 228)),
        (New-Object System.Drawing.PointF(84, 228))
    ))
    $outline.Dispose()

    $g.Dispose()
    return $bmp
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)

function Get-IconDibEntry {
    <#
        Converts a bitmap into the classic ICO "DIB" payload: a
        BITMAPINFOHEADER whose height is doubled, the 32bpp BGRA pixels
        bottom-up, then a 1bpp AND mask. PNG-compressed entries are legal on
        Vista and later but are rejected by several GDI+ based readers, so the
        old format is used for every size.
    #>
    param([System.Drawing.Bitmap]$Bitmap)

    $w = $Bitmap.Width
    $h = $Bitmap.Height

    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                             [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $pixels = New-Object byte[] ($data.Stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    $stride = $data.Stride
    $Bitmap.UnlockBits($data)

    $maskStride = [math]::Ceiling($w / 32.0) * 4
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    $bw.Write([UInt32]40)            # biSize
    $bw.Write([Int32]$w)             # biWidth
    $bw.Write([Int32]($h * 2))       # biHeight: colour data plus mask
    $bw.Write([UInt16]1)             # biPlanes
    $bw.Write([UInt16]32)            # biBitCount
    $bw.Write([UInt32]0)             # biCompression: BI_RGB
    $bw.Write([UInt32]($w * $h * 4 + $maskStride * $h))
    $bw.Write([Int32]0); $bw.Write([Int32]0)   # pixels-per-metre
    $bw.Write([UInt32]0); $bw.Write([UInt32]0) # palette

    # Colour rows, bottom-up.
    for ($y = $h - 1; $y -ge 0; $y--) {
        $bw.Write($pixels, $y * $stride, $w * 4)
    }

    # AND mask: fully transparent pixels are masked out, everything else drawn.
    for ($y = $h - 1; $y -ge 0; $y--) {
        $row = New-Object byte[] $maskStride
        for ($x = 0; $x -lt $w; $x++) {
            $alpha = $pixels[($y * $stride) + ($x * 4) + 3]
            if ($alpha -eq 0) {
                $row[[math]::Floor($x / 8)] = $row[[math]::Floor($x / 8)] -bor (0x80 -shr ($x % 8))
            }
        }
        $bw.Write($row, 0, $maskStride)
    }

    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    return ,$bytes
}

$entries = @()
foreach ($size in $sizes) {
    $bmp = New-JuiceBitmap -Size $size
    $entries += ,(Get-IconDibEntry -Bitmap $bmp)
    $bmp.Dispose()
}

# ICO container: 6-byte header, then a 16-byte directory entry per image.
$out = New-Object System.IO.MemoryStream
$bw  = New-Object System.IO.BinaryWriter($out)

$bw.Write([UInt16]0)                 # reserved
$bw.Write([UInt16]1)                 # type: icon
$bw.Write([UInt16]$sizes.Count)

$offset = 6 + (16 * $sizes.Count)
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $bw.Write([byte]$dim)            # width
    $bw.Write([byte]$dim)            # height
    $bw.Write([byte]0)               # palette colours
    $bw.Write([byte]0)               # reserved
    $bw.Write([UInt16]1)             # colour planes
    $bw.Write([UInt16]32)            # bits per pixel
    $bw.Write([UInt32]$entries[$i].Length)
    $bw.Write([UInt32]$offset)
    $offset += $entries[$i].Length
}
foreach ($entry in $entries) { $bw.Write($entry) }

$bw.Flush()
$dir = Split-Path -Parent $OutputPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
[System.IO.File]::WriteAllBytes($OutputPath, $out.ToArray())
$bw.Dispose(); $out.Dispose()

Write-Host "Wrote $OutputPath ($([math]::Round((Get-Item $OutputPath).Length / 1KB, 1)) KB, $($sizes.Count) sizes)"
