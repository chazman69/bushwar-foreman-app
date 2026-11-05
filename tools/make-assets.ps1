# Derives all Foreman brand assets from the official BUSHWAR mark:
#   assets\bw-mark.png  (source of truth — the white BW wings on black, 1024x1024)
#     -> assets\logo.png  (mark keyed to transparent, cropped — for the app header)
#     -> assets\icon.ico  (black tile + mark, 256/48/32/16 BMP entries)
# Run:  powershell -ExecutionPolicy Bypass -File tools\make-assets.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $root 'assets'
$src = Join-Path $assets 'bw-mark.png'
if (-not (Test-Path $src)) { throw "assets\bw-mark.png missing — that's the brand source of truth." }

# ---- 1. key the mark: white-on-black -> white-on-transparent (alpha = luminance) ----
$srcBmp = New-Object System.Drawing.Bitmap($src)
$w = $srcBmp.Width; $h = $srcBmp.Height
$rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
$data = $srcBmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stride = $data.Stride
[byte[]]$px = New-Object byte[] ($stride * $h)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $px, 0, $px.Length)
$srcBmp.UnlockBits($data)
$srcBmp.Dispose()

$minX = $w; $minY = $h; $maxX = 0; $maxY = 0
for ($y = 0; $y -lt $h; $y++) {
    $row = $y * $stride
    for ($x = 0; $x -lt $w; $x++) {
        $i = $row + ($x * 4)
        $lum = $px[$i]                       # B (mark is white/grey: B=G=R)
        if ($px[$i + 1] -gt $lum) { $lum = $px[$i + 1] }
        if ($px[$i + 2] -gt $lum) { $lum = $px[$i + 2] }
        $px[$i] = 255; $px[$i + 1] = 255; $px[$i + 2] = 255   # colour -> pure white
        $px[$i + 3] = $lum                                     # alpha  -> luminance
        if ($lum -gt 32) {
            if ($x -lt $minX) { $minX = $x }
            if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }
            if ($y -gt $maxY) { $maxY = $y }
        }
    }
}

$keyed = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$data = $keyed.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
[System.Runtime.InteropServices.Marshal]::Copy($px, 0, $data.Scan0, $px.Length)
$keyed.UnlockBits($data)

# ---- 2. logo.png — cropped transparent mark for the app header ----
$pad = 24
$cx = [Math]::Max(0, $minX - $pad); $cy = [Math]::Max(0, $minY - $pad)
$cw = [Math]::Min($w, $maxX + $pad) - $cx; $ch = [Math]::Min($h, $maxY + $pad) - $cy
$crop = $keyed.Clone((New-Object System.Drawing.Rectangle($cx, $cy, $cw, $ch)), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$logoPath = Join-Path $assets 'logo.png'
$crop.Save($logoPath, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host "wrote $logoPath (${cw}x${ch}, transparent)"

# ---- 3. icon.ico — black tile + the mark, classic BMP entries ----
function New-IconBitmap([int]$size, [System.Drawing.Bitmap]$mark) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.Clear([System.Drawing.Color]::FromArgb(255, 12, 12, 12))
    $scale = ($size * 0.92) / $mark.Width
    $mw = [int]($mark.Width * $scale); $mh = [int]($mark.Height * $scale)
    $g.DrawImage($mark, [int](($size - $mw) / 2), [int](($size - $mh) / 2), $mw, $mh)
    $g.Dispose()
    return $bmp
}

function Get-IcoBmpEntry([System.Drawing.Bitmap]$bmp) {
    $bw2 = $bmp.Width; $bh2 = $bmp.Height
    $r2 = New-Object System.Drawing.Rectangle(0, 0, $bw2, $bh2)
    $d2 = $bmp.LockBits($r2, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $st2 = $d2.Stride
    [byte[]]$raw = New-Object byte[] ($st2 * $bh2)
    [System.Runtime.InteropServices.Marshal]::Copy($d2.Scan0, $raw, 0, $raw.Length)
    $bmp.UnlockBits($d2)
    $ms = New-Object System.IO.MemoryStream
    $bwr = New-Object System.IO.BinaryWriter($ms)
    $bwr.Write([uint32]40); $bwr.Write([int32]$bw2); $bwr.Write([int32]($bh2 * 2))
    $bwr.Write([uint16]1); $bwr.Write([uint16]32); $bwr.Write([uint32]0)
    $bwr.Write([uint32]($bw2 * $bh2 * 4)); $bwr.Write([int32]0); $bwr.Write([int32]0)
    $bwr.Write([uint32]0); $bwr.Write([uint32]0)
    for ($y = $bh2 - 1; $y -ge 0; $y--) { $bwr.Write($raw, ($y * $st2), ($bw2 * 4)) }
    $maskRow = [int]([Math]::Ceiling($bw2 / 32.0) * 4)
    [byte[]]$mask = New-Object byte[] ($maskRow * $bh2)
    $bwr.Write($mask, 0, $mask.Length)
    $bwr.Flush()
    return ,([byte[]]$ms.ToArray())
}

$sizes = @(256, 48, 32, 16)
$entries = @()
foreach ($s in $sizes) {
    $tile = New-IconBitmap $s $crop
    [byte[]]$entryBytes = Get-IcoBmpEntry $tile
    $entries += , @{ Size = $s; Bytes = $entryBytes }
    $tile.Dispose()
}
$icoPath = Join-Path $assets 'icon.ico'
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$entries.Count)
$offset = 6 + (16 * $entries.Count)
foreach ($p in $entries) {
    $dim = $p.Size; if ($dim -ge 256) { $dim = 0 }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim)
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$p.Bytes.Length); $bw.Write([uint32]$offset)
    $offset += $p.Bytes.Length
}
foreach ($p in $entries) { [byte[]]$b = $p.Bytes; $bw.Write($b, 0, $b.Length) }
$bw.Close(); $fs.Close()
$crop.Dispose(); $keyed.Dispose()
Write-Host "wrote $icoPath ($((Get-Item $icoPath).Length) bytes)"
