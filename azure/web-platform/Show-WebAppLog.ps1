<#
.SYNOPSIS
    Streams live log output from an Azure Web App using 'az webapp log tail'.

.DESCRIPTION
    Connects to the log stream of an Azure Web App and outputs log entries in real time.
    Requires the Azure CLI ('az') to be installed and the user to be authenticated via 'az login'.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Show-WebAppLog.<Name>.json from script directory)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

.EXAMPLE
    .\Show-WebAppLog.ps1 -ConfigName ta-intervals-mcp

.EXAMPLE
    .\Show-WebAppLog.ps1 -WebAppName 'ta-intervals-mcp' -ResourceGroupName 'rg-brands-advisory-central'

.EXAMPLE
    .\Show-WebAppLog.ps1 -WebAppName 'my-app' -ResourceGroupName 'my-rg' -Slot 'staging'

.NOTES
    Prerequisites:
      - Azure CLI installed (winget install --id Microsoft.AzureCLI)
      - Authenticated via: az login
    Required Azure role (minimum): Website Contributor or Reader (for log access)
    Required permission: Microsoft.Web/sites/logs/read
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

    [Parameter(Mandatory = $false)]
    [string]$WebAppName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    # Optional: deployment slot name (e.g. 'staging'). Defaults to production slot.
    [Parameter(Mandatory = $false)]
    [string]$Slot,

    # Optional: filter log output by provider.
    # Valid values: application, http, platform, kudu
    [Parameter(Mandatory = $false)]
    [ValidateSet('application', 'http', 'platform', 'kudu')]
    [string]$Provider
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\AzToolkit.Config.psm1') -Force

# --- Resolve config file ---
$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name $ConfigName `
    -ConfigDir $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix 'Show-WebAppLog'
$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# --- Merge config + parameters ---
if ($null -ne $config) {
    $webAppValue = $config.PSObject.Properties['webApp']?.Value

    if (-not $WebAppName -and $null -ne $webAppValue) {
        $WebAppName = $webAppValue.PSObject.Properties['name']?.Value
    }
    if (-not $ResourceGroupName -and $null -ne $webAppValue) {
        $ResourceGroupName = $webAppValue.PSObject.Properties['resourceGroupName']?.Value
    }
    if (-not $Slot -and $null -ne $webAppValue) {
        $Slot = $webAppValue.PSObject.Properties['slot']?.Value
    }
    if (-not $Provider -and $null -ne $config) {
        $providerValue = $config.PSObject.Properties['provider']?.Value
        if (-not [string]::IsNullOrWhiteSpace($providerValue)) {
            $Provider = $providerValue
        }
    }
}

# --- Validate required parameters ---
if (-not $WebAppName)        { throw 'WebAppName is required.' }
if (-not $ResourceGroupName) { throw 'ResourceGroupName is required.' }

Write-Host '=== Show-WebAppLog ===' -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Using config: $resolvedConfigPath" -ForegroundColor Gray
}
Write-Host ''

# --- Verify Azure CLI is available ---
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') is not installed or not in PATH. Install it via: winget install --id Microsoft.AzureCLI"
}

# --- Verify az login ---
Write-Host 'Verifying Azure CLI authentication...' -ForegroundColor Gray
$azAccount = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Not authenticated to Azure CLI. Run 'az login' first."
}
$accountInfo = $azAccount | ConvertFrom-Json
Write-Host "Subscription: $($accountInfo.name) ($($accountInfo.id))" -ForegroundColor Cyan
Write-Host "Web App:      $WebAppName"        -ForegroundColor Cyan
Write-Host "Resource Grp: $ResourceGroupName" -ForegroundColor Cyan
if ($Slot) {
    Write-Host "Slot:         $Slot" -ForegroundColor Cyan
}
if ($Provider) {
    Write-Host "Provider:     $Provider" -ForegroundColor Cyan
}
Write-Host ''
Write-Host 'Streaming log output (press Ctrl+C to stop)...' -ForegroundColor Yellow
Write-Host ''

# --- Build az command arguments ---
$azArgs = @(
    'webapp', 'log', 'tail'
    '--name',           $WebAppName
    '--resource-group', $ResourceGroupName
)

if ($Slot) {
    $azArgs += '--slot', $Slot
}
if ($Provider) {
    $azArgs += '--provider', $Provider
}

# --- Stream logs ---
az @azArgs

if ($LASTEXITCODE -ne 0) {
    Write-Host "Log stream ended with exit code $LASTEXITCODE." -ForegroundColor Red
}
