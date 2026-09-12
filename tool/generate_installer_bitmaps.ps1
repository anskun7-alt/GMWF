Add-Type -AssemblyName System.Drawing

$logoPath = "e:\GMWF\gmwf\assets\logo\gmwf-1.png"
$logo = [System.Drawing.Image]::FromFile($logoPath)

# 1. Create Wizard Large BMP (240 x 400)
$wLarge = 240
$hLarge = 400
$bmpLarge = New-Object System.Drawing.Bitmap($wLarge, $hLarge, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$gLarge = [System.Drawing.Graphics]::FromImage($bmpLarge)
$gLarge.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$gLarge.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$gLarge.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

# Draw Rich GMWF Emerald Green Gradient
$rect = New-Object System.Drawing.Rectangle(0, 0, $wLarge, $hLarge)
$topColor = [System.Drawing.Color]::FromArgb(0, 48, 38)
$botColor = [System.Drawing.Color]::FromArgb(0, 88, 72)
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $topColor, $botColor, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
$gLarge.FillRectangle($brush, $rect)

# Draw subtle diagonal accent lines
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(12, 255, 255, 255), 2)
for ($i = -400; $i -lt 500; $i += 32) {
    $gLarge.DrawLine($pen, 0, $i, $wLarge, $i + $wLarge)
}

# Draw Logo centered at top (size 115 x 115)
$logoW = 115
$logoH = 115
$logoX = [int](($wLarge - $logoW) / 2)
$logoY = 50

# Draw soft glow behind logo
$glowBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(35, 255, 255, 255))
$gLarge.FillEllipse($glowBrush, $logoX - 12, $logoY - 12, $logoW + 24, $logoH + 24)

$gLarge.DrawImage($logo, $logoX, $logoY, $logoW, $logoH)

# Draw Title Text
$titleFont = New-Object System.Drawing.Font("Segoe UI", 19, [System.Drawing.FontStyle]::Bold)
$titleBrush = [System.Drawing.Brushes]::White
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = [System.Drawing.StringAlignment]::Center

$gLarge.DrawString("GMWF", $titleFont, $titleBrush, [float]($wLarge / 2), 185, $sf)

# Draw Subtitle
$subFont = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
$subBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(210, 255, 255, 255))
$gLarge.DrawString("Management Platform", $subFont, $subBrush, [float]($wLarge / 2), 224, $sf)

# Draw Tagline
$tagFont = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
$tagBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 255, 255, 255))
$gLarge.DrawString("Healthcare & Community Welfare", $tagFont, $tagBrush, [float]($wLarge / 2), 248, $sf)

# Draw Bottom decorative separator
$sepPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 255, 255, 255), 1)
$gLarge.DrawLine($sepPen, 35, 355, $wLarge - 35, 355)

$verFont = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)
$verBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 255, 255, 255))
$gLarge.DrawString("Production Edition", $verFont, $verBrush, [float]($wLarge / 2), 365, $sf)

$bmpLarge.Save("e:\GMWF\gmwf\Installer\gmwf_wizard_large.bmp", [System.Drawing.Imaging.ImageFormat]::Bmp)
$gLarge.Dispose()
$bmpLarge.Dispose()

# 2. Create Wizard Small BMP (64 x 64)
$wSmall = 64
$hSmall = 64
$bmpSmall = New-Object System.Drawing.Bitmap($wSmall, $hSmall, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$gSmall = [System.Drawing.Graphics]::FromImage($bmpSmall)
$gSmall.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$gSmall.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

# Clean White Background matching Inno Setup header
$gSmall.Clear([System.Drawing.Color]::White)

# Draw GMWF Logo (size 56 x 56 centered)
$sW = 56
$sH = 56
$sX = [int](($wSmall - $sW) / 2)
$sY = [int](($hSmall - $sH) / 2)
$gSmall.DrawImage($logo, $sX, $sY, $sW, $sH)

$bmpSmall.Save("e:\GMWF\gmwf\Installer\gmwf_wizard_small.bmp", [System.Drawing.Imaging.ImageFormat]::Bmp)
$gSmall.Dispose()
$bmpSmall.Dispose()
$logo.Dispose()

Write-Output "GMWF Inno Setup BMPs generated successfully!"
