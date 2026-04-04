<#
.SYNOPSIS
    Creates an Entra ID App Registration with a self-signed certificate credential.

.DESCRIPTION
    Creates an App Registration and matching Enterprise Application (service principal),
    generates a self-signed certificate, uploads the public key as an app key credential,
    and exports certificate files to disk.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Create-AppRegistrationWithCertificate.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

    Authentication can be handled in two explicit ways:
    - Pre-connect manually via Connect-MgGraph before running the script, or
    - Use -ConnectGraph to let this script call Connect-MgGraph explicitly.

.EXAMPLE
    .\Create-AppRegistrationWithCertificate.ps1 -ConfigName prod

.EXAMPLE
    .\Create-AppRegistrationWithCertificate.ps1 -AppRegistrationName 'my-app-prd' -ServiceNowTicket 'RITM1234567'

.EXAMPLE
    .\Create-AppRegistrationWithCertificate.ps1 -ConfigName prod -ConnectGraph
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

    # Display name for the new App Registration.
    [Parameter(Mandatory = $false)]
    [string]$AppRegistrationName,

    # Optional notes field, typically used for ticket references.
    [Parameter(Mandatory = $false)]
    [string]$ServiceNowTicket,

    # Output directory for certificate files.
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = '.\Certificates',

    # Certificate validity in years.
    [Parameter(Mandatory = $false)]
    [int]$ValidityYears = 2,

    # RSA key length for the generated certificate.
    [Parameter(Mandatory = $false)]
    [int]$KeyLength = 2048,

    # Temporary password used for intermediate PFX export.
    [Parameter(Mandatory = $false)]
    [string]$PfxPassword = 'temp',

    # Explicitly connect to Microsoft Graph from this script.
    [Parameter(Mandatory = $false)]
    [switch]$ConnectGraph,

    # Optional tenant ID used for Connect-MgGraph.
    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    # Graph scopes requested when -ConnectGraph is used.
    [Parameter(Mandatory = $false)]
    [string[]]$GraphScopes = @('Application.ReadWrite.All'),

    # Use device authentication flow for Connect-MgGraph.
    [Parameter(Mandatory = $false)]
    [switch]$UseDeviceAuthentication
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\shared\AzToolkit.Config.psm1') -Force

# ── Config loading ─────────────────────────────────────────────────────────────

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Create-AppRegistrationWithCertificate'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# Merge: direct parameter wins over config file
if (-not $PSBoundParameters.ContainsKey('AppRegistrationName') -and $null -ne $config -and $config.appRegistrationName) {
    $AppRegistrationName = [string]$config.appRegistrationName
}

if (-not $PSBoundParameters.ContainsKey('ServiceNowTicket') -and $null -ne $config -and
    $config.PSObject.Properties['serviceNowTicket']) {
    $ServiceNowTicket = [string]$config.serviceNowTicket
}

if (-not $PSBoundParameters.ContainsKey('OutputPath') -and $null -ne $config -and $config.outputPath) {
    $OutputPath = [string]$config.outputPath
}

if (-not $PSBoundParameters.ContainsKey('ValidityYears') -and $null -ne $config -and
    $config.PSObject.Properties['validityYears']) {
    $ValidityYears = [int]$config.validityYears
}

if (-not $PSBoundParameters.ContainsKey('KeyLength') -and $null -ne $config -and
    $config.PSObject.Properties['keyLength']) {
    $KeyLength = [int]$config.keyLength
}

if (-not $PSBoundParameters.ContainsKey('PfxPassword') -and $null -ne $config -and
    $config.PSObject.Properties['pfxPassword']) {
    $PfxPassword = [string]$config.pfxPassword
}

if (-not $PSBoundParameters.ContainsKey('TenantId') -and $null -ne $config -and $config.tenantId) {
    $TenantId = [string]$config.tenantId
}

if (-not $PSBoundParameters.ContainsKey('GraphScopes') -and $null -ne $config -and $config.graphScopes) {
    $GraphScopes = [string[]]$config.graphScopes
}

if (-not $ConnectGraph.IsPresent -and $null -ne $config -and
    $config.PSObject.Properties['auth'] -and
    $config.auth.PSObject.Properties['connectGraph'] -and
    $config.auth.connectGraph -eq $true) {
    $ConnectGraph = $true
}

if (-not $UseDeviceAuthentication.IsPresent -and $null -ne $config -and
    $config.PSObject.Properties['auth'] -and
    $config.auth.PSObject.Properties['useDeviceAuthentication'] -and
    $config.auth.useDeviceAuthentication -eq $true) {
    $UseDeviceAuthentication = $true
}

# ── Validation ─────────────────────────────────────────────────────────────────

if (-not $AppRegistrationName) {
    Write-Host "No app registration name provided. Specify -AppRegistrationName or set appRegistrationName in the config file." -ForegroundColor Red
    exit 1
}

if ($ValidityYears -lt 1) {
    Write-Host "ValidityYears must be greater than or equal to 1." -ForegroundColor Red
    exit 1
}

if ($KeyLength -lt 2048) {
    Write-Host "KeyLength must be greater than or equal to 2048." -ForegroundColor Red
    exit 1
}

# ── Header ─────────────────────────────────────────────────────────────────────

Write-Host "=== Create-AppRegistrationWithCertificate ===" -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Config           : $resolvedConfigPath" -ForegroundColor Gray
}
Write-Host "App name         : $AppRegistrationName" -ForegroundColor Gray
Write-Host "Output path      : $OutputPath" -ForegroundColor Gray
Write-Host "Validity (years) : $ValidityYears" -ForegroundColor Gray
Write-Host "Key length       : $KeyLength" -ForegroundColor Gray
Write-Host "Graph connect    : $(if ($ConnectGraph) { 'Connect in script' } else { 'Use existing session' })" -ForegroundColor Gray
Write-Host ""

$certificateSubject = "CN=$AppRegistrationName"
$certBaseName = $AppRegistrationName -replace '[^a-zA-Z0-9-_]', '_'
$cerFile = "$certBaseName.cer"
$keyFile = "$certBaseName.key"
$pfxFile = "$certBaseName.pfx"
$pemFile = "$certBaseName.pem"

$cert = $null

try {
    if ($ConnectGraph) {
        Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Yellow

        $graphConnectParams = @{
            Scopes      = $GraphScopes
            ErrorAction = 'Stop'
            NoWelcome   = $true
        }

        if ($TenantId) {
            $graphConnectParams.TenantId = $TenantId
        }
        if ($UseDeviceAuthentication) {
            $graphConnectParams.UseDeviceAuthentication = $true
        }

        Connect-MgGraph @graphConnectParams
    }

    # Verify Microsoft Graph context
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context -or -not $context.TenantId) {
        throw 'No active Microsoft Graph tenant context. Run Connect-MgGraph first, or run this script with -ConnectGraph.'
    }

    # Create app registration and enterprise application
    Write-Host "Creating App Registration '$AppRegistrationName'..." -ForegroundColor Yellow
    $appParams = @{ DisplayName = $AppRegistrationName }
    if ($ServiceNowTicket) {
        $appParams.Notes = $ServiceNowTicket
    }
    $app = New-MgApplication @appParams

    Write-Host 'Creating Enterprise Application (service principal)...' -ForegroundColor Yellow
    $null = New-MgServicePrincipal -AppId $app.AppId -Tags @('WindowsAzureActiveDirectoryIntegratedApp')

    # Create certificate
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    if (-not (Test-Path $OutputPath)) {
        Write-Host "Creating output directory: $OutputPath" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $notAfter = (Get-Date).AddYears($ValidityYears)

    Write-Host 'Creating self-signed certificate...' -ForegroundColor Yellow
    $cert = New-SelfSignedCertificate `
        -Subject $certificateSubject `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyExportPolicy Exportable `
        -KeySpec Signature `
        -KeyLength $KeyLength `
        -KeyAlgorithm RSA `
        -HashAlgorithm SHA256 `
        -NotAfter $notAfter

    Write-Host "  Thumbprint : $($cert.Thumbprint)" -ForegroundColor Green
    Write-Host "  Subject    : $($cert.Subject)" -ForegroundColor Green
    Write-Host "  Valid until: $($cert.NotAfter)" -ForegroundColor Green

    # Export certificate files
    $cerPath = [System.IO.Path]::GetFullPath((Join-Path $OutputPath $cerFile))
    $pfxPath = [System.IO.Path]::GetFullPath((Join-Path $OutputPath $pfxFile))
    $keyPath = [System.IO.Path]::GetFullPath((Join-Path $OutputPath $keyFile))
    $pemPath = [System.IO.Path]::GetFullPath((Join-Path $OutputPath $pemFile))

    Write-Host 'Exporting public key (.cer)...' -ForegroundColor Yellow
    Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT | Out-Null
    Write-Host "  Saved: $cerPath" -ForegroundColor Green

    Write-Host 'Exporting private key (.pfx)...' -ForegroundColor Yellow
    $pfxPasswordSecure = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pfxPasswordSecure | Out-Null

    # Locate OpenSSL and convert PFX to plaintext key if available
    $opensslExe = $null
    $opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
    if ($opensslCmd) {
        $opensslExe = $opensslCmd.Source
    }
    else {
        $commonPaths = @(
            'C:\Program Files\OpenSSL-Win64\bin\openssl.exe',
            'C:\Program Files (x86)\OpenSSL-Win32\bin\openssl.exe',
            'C:\OpenSSL-Win64\bin\openssl.exe',
            'C:\OpenSSL-Win32\bin\openssl.exe',
            "${env:ProgramFiles}\OpenSSL-Win64\bin\openssl.exe",
            "${env:ProgramFiles(x86)}\OpenSSL-Win32\bin\openssl.exe"
        )
        foreach ($candidatePath in $commonPaths) {
            if (Test-Path $candidatePath) {
                $opensslExe = $candidatePath
                break
            }
        }
    }

    if ($opensslExe) {
        Write-Host 'Converting PFX to unencrypted private key (.key) using OpenSSL...' -ForegroundColor Yellow
        $opensslArgs = "pkcs12 -in `"$pfxPath`" -nocerts -nodes -passin pass:$PfxPassword -out `"$keyPath`""
        $proc = Start-Process -FilePath $opensslExe -ArgumentList $opensslArgs -NoNewWindow -Wait -PassThru

        if ($proc.ExitCode -eq 0 -and (Test-Path $keyPath)) {
            # Keep only PEM block in case OpenSSL writes metadata wrappers.
            $keyContent = Get-Content $keyPath -Raw
            if ($keyContent -match '(?s)(-----BEGIN[^-]+-----.*-----END[^-]+-----)') {
                Set-Content -Path $keyPath -Value $matches[1] -NoNewline
            }
            Write-Host "  Saved: $keyPath" -ForegroundColor Green
        }
        else {
            Write-Host "  WARNING: OpenSSL conversion failed (Exit: $($proc.ExitCode))." -ForegroundColor Yellow
            Write-Host "  PFX file available at: $pfxPath (Password: $PfxPassword)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '  WARNING: OpenSSL not found; .key file could not be created.' -ForegroundColor Yellow
        Write-Host "  PFX file available at: $pfxPath (Password: $PfxPassword)" -ForegroundColor Yellow
        Write-Host "  Manual conversion: openssl pkcs12 -in `"$pfxPath`" -nocerts -nodes -passin pass:$PfxPassword -out `"$keyPath`"" -ForegroundColor Yellow
        Write-Host '  Install OpenSSL: winget install OpenSSL.OpenSSL' -ForegroundColor Yellow
    }

    if (Test-Path $keyPath) {
        Write-Host 'Creating combined PEM file (.pem)...' -ForegroundColor Yellow

        # Convert DER certificate (.cer) to PEM certificate block.
        $cerBytes  = [System.IO.File]::ReadAllBytes($cerPath)
        $cerBase64 = [System.Convert]::ToBase64String($cerBytes)
        $cerPemLines = for ($i = 0; $i -lt $cerBase64.Length; $i += 64) {
            $cerBase64.Substring($i, [Math]::Min(64, $cerBase64.Length - $i))
        }
        $certPemBlock = "-----BEGIN CERTIFICATE-----`n" +
                        ($cerPemLines -join "`n") +
                        "`n-----END CERTIFICATE-----"

        $keyContent = (Get-Content -LiteralPath $keyPath -Raw).Trim()
        $pemContent = $keyContent + "`n`n" + $certPemBlock + "`n"
        Set-Content -LiteralPath $pemPath -Value $pemContent -NoNewline

        Write-Host "  Saved: $pemPath" -ForegroundColor Green
    }
    else {
        Write-Host '  WARNING: .pem file could not be created because no .key file is available.' -ForegroundColor Yellow
    }

    # Upload certificate as key credential
    Write-Host 'Uploading certificate to App Registration...' -ForegroundColor Yellow

    $keyCredential = @{
        Type          = 'AsymmetricX509Cert'
        Usage         = 'Verify'
        Key           = $cert.RawData
        DisplayName   = $certificateSubject
        EndDateTime   = $cert.NotAfter
        StartDateTime = $cert.NotBefore
    }

    Update-MgApplication -ApplicationId $app.Id -KeyCredentials @($keyCredential)
    Write-Host '  Certificate uploaded successfully.' -ForegroundColor Green

    # Remove temporary certificate from local store
    Write-Host 'Cleaning local certificate store...' -ForegroundColor Yellow
    Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force
    Write-Host '  Certificate removed from local store.' -ForegroundColor Green

    # Output result and copy summary to clipboard
    $result = [PSCustomObject]@{
        AppName                = $app.DisplayName
        ClientId               = $app.AppId
        TenantId               = $context.TenantId
        CertificateThumbprint  = $cert.Thumbprint
        CertificateExpires     = $cert.NotAfter
        CertPublicKey          = $cerPath
        CertPrivateKey         = if (Test-Path $keyPath) { $keyPath } else { "$pfxPath (PFX, Password: $PfxPassword)" }
        CertPem                = if (Test-Path $pemPath) { $pemPath } else { 'Not created' }
    }

    Write-Host "`nResult:" -ForegroundColor Cyan
    $result | Format-List

    $clipboardText = @(
        "$($result.AppName)",
        "Client ID   : $($result.ClientId)",
        "Tenant ID   : $($result.TenantId)",
        "Thumbprint  : $($result.CertificateThumbprint)",
        "Expires     : $($result.CertificateExpires)",
        "Public Key  : $($result.CertPublicKey)",
        "Private Key : $($result.CertPrivateKey)",
        "PEM         : $($result.CertPem)"
    ) -join [Environment]::NewLine

    Set-Clipboard -Value $clipboardText
    Write-Host 'Copied summary to clipboard.' -ForegroundColor Green

    Write-Host ''
    Write-Host 'IMPORTANT SECURITY NOTICE:' -ForegroundColor Red
    Write-Host '  The private key and PEM file are stored unencrypted.' -ForegroundColor Red
    Write-Host '  Store it securely and NEVER commit it to source control.' -ForegroundColor Red
    Write-Host '  Use Azure Key Vault for production environments.' -ForegroundColor Red
}
catch {
    Write-Host 'ERROR: Failed to create App Registration with certificate.' -ForegroundColor Red
    Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Red

    if ($cert) {
        try {
            Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }

    exit 1
}

Write-Host ''
Write-Host 'Script completed successfully.' -ForegroundColor Green
