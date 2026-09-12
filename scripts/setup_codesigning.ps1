# scripts/setup_codesigning.ps1
# GMWF Digital Code Signing & Authenticode Tool

$ErrorActionPreference = "Stop"

Write-Host "=== 1. Checking / Generating GMWF Code Signing Certificate ===" -ForegroundColor Cyan
$certSubject = "CN=GMWF, O=GMWF, OU=Developer: Ans, C=PK"
$existingCert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.Subject -like "*CN=GMWF*" } | Select-Object -First 1

if ($existingCert) {
    $cert = $existingCert
    Write-Host "Found existing certificate: $($cert.Thumbprint)" -ForegroundColor Green
} else {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert `
        -Subject $certSubject `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -NotAfter (Get-Date).AddYears(10) `
        -FriendlyName "GMWF (Developed by Ans)"
    Write-Host "Created certificate: $($cert.Thumbprint)" -ForegroundColor Green
}

# 2. Export PFX and CER files
$installerDir = "E:\GMWF\gmwf\Installer"
if (-not (Test-Path $installerDir)) {
    New-Item -ItemType Directory -Path $installerDir -Force | Out-Null
}

$pfxPath = Join-Path $installerDir "gmwf_codesign.pfx"
$cerPath = Join-Path $installerDir "gmwf_trusted.cer"
$pfxPassword = ConvertTo-SecureString -String "GMWF@Secure2026" -Force -AsPlainText

Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pfxPassword -Force | Out-Null
Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null
Write-Host "Exported certificates to $installerDir" -ForegroundColor Green

# 3. Add to TrustedPublisher store (Silent)
Write-Host "`n=== 2. Adding Certificate to CurrentUser\TrustedPublisher ===" -ForegroundColor Cyan
try {
    Import-Certificate -FilePath $cerPath -CertStoreLocation "Cert:\CurrentUser\TrustedPublisher" | Out-Null
    Write-Host "Certificate registered in Trusted Publisher store." -ForegroundColor Green
} catch {
    Write-Host "Notice: $_" -ForegroundColor Yellow
}

# 4. Sign EXEs
Write-Host "`n=== 3. Digitally Signing Executables ===" -ForegroundColor Cyan

$targets = @(
    "E:\GMWF\gmwf\Installer\GMWF-v1.4.7-x64.exe",
    "E:\GMWF\gmwf\build\windows\x64\runner\Release\gmwf.exe"
)

foreach ($target in $targets) {
    if (Test-Path $target) {
        $sig = Set-AuthenticodeSignature -FilePath $target -Certificate $cert -HashAlgorithm SHA256
        Write-Host "Signed $target -> Status: $($sig.Status)" -ForegroundColor Green
    } else {
        Write-Host "Target not found: $target" -ForegroundColor Yellow
    }
}

Write-Host "`n=== GMWF Code Signing Complete! ===" -ForegroundColor Green


