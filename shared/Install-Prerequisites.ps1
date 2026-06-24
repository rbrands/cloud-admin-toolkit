<#
.SYNOPSIS
    Installs required PowerShell modules for the Cloud Admin Toolkit.

.DESCRIPTION
    This script checks for and installs the necessary PowerShell modules 
    used across Azure, Entra ID and Microsoft 365 administration scenarios.

    No tenant-specific configuration is applied.
    The script is safe to run multiple times (idempotent).

.EXAMPLE
    .\Install-Prerequisites.ps1
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$InstallMacTools
)

Write-Host "=== Cloud Admin Toolkit - Module Bootstrap ===" -ForegroundColor Cyan
Write-Host ""

$isWindowsPlatform = $IsWindows -or ($PSVersionTable.Platform -eq 'Win32NT')
$isMacOSPlatform = $IsMacOS -or ($PSVersionTable.Platform -eq 'Unix' -and $PSVersionTable.OS -match 'Darwin')

if ($isMacOSPlatform -and $InstallMacTools) {
    Write-Host "macOS detected. Installing system prerequisites via Homebrew..." -ForegroundColor Yellow

    $brew = Get-Command brew -ErrorAction SilentlyContinue
    if (-not $brew) {
        Write-Host "  X Homebrew is not installed. Install it first: https://brew.sh" -ForegroundColor Red
        throw "Homebrew is required for -InstallMacTools on macOS."
    }

    $brewPackages = @(
        @{ Name = "git"; Description = "Git" }
        @{ Name = "azure-cli"; Description = "Azure CLI" }
        @{ Name = "powershell"; Description = "PowerShell 7" }
    )

    $brewCasks = @(
        @{ Name = "visual-studio-code"; Description = "Visual Studio Code" }
    )

    foreach ($pkg in $brewPackages) {
        Write-Host "Checking brew package: $($pkg.Name)..." -ForegroundColor Yellow
        $installed = & brew list --formula --versions $pkg.Name 2>$null
        if ($LASTEXITCODE -eq 0 -and $installed) {
            Write-Host "  - Already installed" -ForegroundColor Green
        }
        else {
            Write-Host "  -> Installing $($pkg.Description)..." -ForegroundColor Yellow
            & brew install $pkg.Name
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  - Installation successful" -ForegroundColor Green
            }
            else {
                Write-Host "  X Installation failed" -ForegroundColor Red
            }
        }
    }

    foreach ($cask in $brewCasks) {
        Write-Host "Checking brew cask: $($cask.Name)..." -ForegroundColor Yellow
        $installed = & brew list --cask --versions $cask.Name 2>$null
        if ($LASTEXITCODE -eq 0 -and $installed) {
            Write-Host "  - Already installed" -ForegroundColor Green
        }
        else {
            Write-Host "  -> Installing $($cask.Description)..." -ForegroundColor Yellow
            & brew install --cask $cask.Name
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  - Installation successful" -ForegroundColor Green
            }
            else {
                Write-Host "  X Installation failed" -ForegroundColor Red
            }
        }
    }

    Write-Host ""
}

# Optional PowerShell version check
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "PowerShell 7 or higher is recommended." -ForegroundColor Yellow
    Write-Host ""
}

# Use a custom module path to keep bootstrap idempotent and isolated.
if ($isWindowsPlatform) {
    $customModuleRoot = Join-Path $env:LOCALAPPDATA "PSModules"
}
else {
    $customModuleRoot = Join-Path $HOME ".local/share/powershell/Modules"
}

if (-not (Test-Path $customModuleRoot)) {
    New-Item -ItemType Directory -Path $customModuleRoot | Out-Null
}

$pathSeparator = [System.IO.Path]::PathSeparator
$psModulePathParts = $env:PSModulePath -split [regex]::Escape($pathSeparator)
if ($psModulePathParts -notcontains $customModuleRoot) {
    $env:PSModulePath = "$customModuleRoot$pathSeparator$env:PSModulePath"
    if ($isWindowsPlatform) {
        [Environment]::SetEnvironmentVariable("PSModulePath", $env:PSModulePath, "User")
    }
}

Write-Host "Using module path: $customModuleRoot" -ForegroundColor Gray
Write-Host ""

$requiredModules = @(
    @{ Name = "Az";                  MinVersion = "10.0.0"; Description = "Azure PowerShell modules" }
    @{ Name = "Az.Billing";          MinVersion = "2.0.0";  Description = "Azure Billing (Get-AzBillingAccount, Get-AzConsumptionUsageDetail, etc.) – included in Az, listed explicitly to ensure availability" }
    @{ Name = "Az.CosmosDB";         MinVersion = "1.16.0"; Description = "Azure Cosmos DB SQL/Data Plane cmdlets (Get-AzCosmosDBSqlRoleDefinition, Get-AzCosmosDBSqlRoleAssignment, etc.) – included in Az, listed explicitly to ensure availability" }
    @{ Name = "Az.ResourceGraph";    MinVersion = "0.13.0"; Description = "Azure Resource Graph (Search-AzGraph) – included in Az, listed explicitly to ensure availability" }
    @{ Name = "Microsoft.Graph";     MinVersion = "2.0.0";  Description = "Microsoft Graph PowerShell SDK" }
    @{ Name = "MicrosoftTeams";      MinVersion = "5.0.0";  Description = "Microsoft Teams PowerShell" }
    @{ Name = "ExchangeOnlineManagement"; MinVersion = "3.0.0"; Description = "Exchange Online PowerShell" }
    @{ Name = "PnP.PowerShell";      MinVersion = "2.0.0";  Description = "SharePoint PnP PowerShell" }
    @{ Name = "ImportExcel";         MinVersion = "7.0.0";  Description = "Excel export functionality" }
)

foreach ($module in $requiredModules) {

    Write-Host "Checking module: $($module.Name)..." -ForegroundColor Yellow

    $installed = Get-Module -ListAvailable -Name $module.Name |
        Where-Object { $_.Version -ge [Version]$module.MinVersion } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($installed) {
        Write-Host "  - Already installed (Version: $($installed.Version))" -ForegroundColor Green
    }
    else {
        Write-Host "  -> Installing $($module.Name)..." -ForegroundColor Yellow
        try {
            $saveModuleParams = @{
                Name                = $module.Name
                Path                = $customModuleRoot
                Force               = $true
                MinimumVersion      = $module.MinVersion
            }

            if ((Get-Command Save-Module).Parameters.ContainsKey('IncludeDependencies')) {
                $saveModuleParams.IncludeDependencies = $true
            }

            if ((Get-Command Save-Module).Parameters.ContainsKey('AllowClobber')) {
                $saveModuleParams.AllowClobber = $true
            }

            Save-Module @saveModuleParams

            Write-Host "  - Installation successful" -ForegroundColor Green
        }
        catch {
            Write-Host "  X Installation failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host "    Description: $($module.Description)" -ForegroundColor Gray
    Write-Host ""
}

Write-Host "Module bootstrap completed." -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
if ($isMacOSPlatform -and -not $InstallMacTools) {
    Write-Host "  - Optional: install macOS tools via brew with -InstallMacTools" -ForegroundColor White
}
Write-Host "  - Import required modules (Import-Module ...)" -ForegroundColor White
Write-Host "  - Authenticate using Connect-AzAccount or Connect-MgGraph as needed" -ForegroundColor White
