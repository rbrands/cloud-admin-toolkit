<#
.SYNOPSIS
    Creates a PEM file by combining an existing .key and .cer file.

.DESCRIPTION
    Reads <CertificateBaseName>.key (private key, PEM format) and
    <CertificateBaseName>.cer (certificate, DER format) from a certificate
    directory and creates <CertificateBaseName>.pem.

    The resulting PEM file layout is:
      1) Private key block
      2) Certificate block

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Create-PemFromCerAndKey.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

.EXAMPLE
    .\Create-PemFromCerAndKey.ps1 -CertificateBaseName 'my-app-prd'

.EXAMPLE
    .\Create-PemFromCerAndKey.ps1 -ConfigName prod
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$ConfigName,

    # Directory to search for the config file. Defaults to the script directory.
    [Parameter(Mandatory = $false)]
    [string]$ConfigDir,

    # Base file name without extension, e.g. 'my-app-prd'.
    [Parameter(Mandatory = $false)]
    [string]$CertificateBaseName,

    # Directory containing .cer/.key input and .pem output.
    [Parameter(Mandatory = $false)]
    [string]$CertificatesDir = '.\Certificates'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\shared\AzToolkit.Config.psm1') -Force

# ── Config loading ─────────────────────────────────────────────────────────────

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Create-PemFromCerAndKey'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

if (-not $PSBoundParameters.ContainsKey('CertificateBaseName') -and $null -ne $config -and $config.certificateBaseName) {
    $CertificateBaseName = [string]$config.certificateBaseName
}

if (-not $PSBoundParameters.ContainsKey('CertificatesDir') -and $null -ne $config -and $config.certificatesDir) {
    $CertificatesDir = [string]$config.certificatesDir
}

# ── Validation ─────────────────────────────────────────────────────────────────

if (-not $CertificateBaseName) {
    Write-Host "No certificate base name provided. Specify -CertificateBaseName or set certificateBaseName in the config file." -ForegroundColor Red
    exit 1
}

if ([System.IO.Path]::GetExtension($CertificateBaseName)) {
    Write-Host "CertificateBaseName must be provided without extension, for example 'my-app-prd'." -ForegroundColor Red
    exit 1
}

$CertificatesDir = [System.IO.Path]::GetFullPath($CertificatesDir)

if (-not (Test-Path $CertificatesDir)) {
    Write-Host "Certificates directory not found: $CertificatesDir" -ForegroundColor Red
    exit 1
}

$cerPath = [System.IO.Path]::GetFullPath((Join-Path $CertificatesDir "$CertificateBaseName.cer"))
$keyPath = [System.IO.Path]::GetFullPath((Join-Path $CertificatesDir "$CertificateBaseName.key"))
$pemPath = [System.IO.Path]::GetFullPath((Join-Path $CertificatesDir "$CertificateBaseName.pem"))

if (-not (Test-Path $cerPath)) {
    Write-Host "CER file not found: $cerPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $keyPath)) {
    Write-Host "KEY file not found: $keyPath" -ForegroundColor Red
    exit 1
}

# ── Main ───────────────────────────────────────────────────────────────────────

Write-Host "=== Create-PemFromCerAndKey ===" -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Config            : $resolvedConfigPath" -ForegroundColor Gray
}
Write-Host "Base name         : $CertificateBaseName" -ForegroundColor Gray
Write-Host "Certificates dir  : $CertificatesDir" -ForegroundColor Gray
Write-Host "CER               : $cerPath" -ForegroundColor Gray
Write-Host "KEY               : $keyPath" -ForegroundColor Gray
Write-Host "PEM               : $pemPath" -ForegroundColor Gray
Write-Host ""

try {
    # Convert binary DER certificate (.cer) into PEM certificate block.
    $cerBytes  = [System.IO.File]::ReadAllBytes($cerPath)
    $cerBase64 = [System.Convert]::ToBase64String($cerBytes)

    $cerPemLines = for ($i = 0; $i -lt $cerBase64.Length; $i += 64) {
        $cerBase64.Substring($i, [Math]::Min(64, $cerBase64.Length - $i))
    }

    $certPemBlock = "-----BEGIN CERTIFICATE-----`n" +
                    ($cerPemLines -join "`n") +
                    "`n-----END CERTIFICATE-----"

    # Read private key block (already in PEM format).
    $keyContent = (Get-Content -LiteralPath $keyPath -Raw).Trim()

    # Assemble PEM with private key first, then certificate.
    $pemContent = $keyContent + "`n`n" + $certPemBlock + "`n"
    Set-Content -LiteralPath $pemPath -Value $pemContent -NoNewline

    Write-Host "PEM file created successfully: $pemPath" -ForegroundColor Green
    Write-Host ""
    Write-Host "Usage in Python (azure-identity):" -ForegroundColor Cyan
    Write-Host "  from azure.identity import CertificateCredential" -ForegroundColor White
    Write-Host "  credential = CertificateCredential(" -ForegroundColor White
    Write-Host "      tenant_id=`"<TENANT-ID>`"," -ForegroundColor White
    Write-Host "      client_id=`"<CLIENT-ID>`"," -ForegroundColor White
    Write-Host "      certificate_path=`"$pemPath`"" -ForegroundColor White
    Write-Host "  )" -ForegroundColor White
    Write-Host ""
    Write-Host "IMPORTANT SECURITY NOTICE:" -ForegroundColor Red
    Write-Host "  The PEM file contains an unencrypted private key." -ForegroundColor Red
    Write-Host "  Store it securely and NEVER commit it to source control." -ForegroundColor Red
}
catch {
    Write-Host "ERROR: Failed to create PEM file." -ForegroundColor Red
    Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Script completed successfully." -ForegroundColor Green
