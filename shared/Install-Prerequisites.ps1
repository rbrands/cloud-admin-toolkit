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
param()

Write-Host "=== Cloud Admin Toolkit - Module Bootstrap ===" -ForegroundColor Cyan
Write-Host ""

# Optional PowerShell version check
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "PowerShell 7 or higher is recommended." -ForegroundColor Yellow
    Write-Host ""
}

# Use custom module path to avoid Controlled Folder Access issues
$customModuleRoot = Join-Path $env:LOCALAPPDATA "PSModules"

if (-not (Test-Path $customModuleRoot)) {
    New-Item -ItemType Directory -Path $customModuleRoot | Out-Null
}

$psModulePathParts = $env:PSModulePath -split ';'
if ($psModulePathParts -notcontains $customModuleRoot) {
    $env:PSModulePath = "$customModuleRoot;$env:PSModulePath"
    [Environment]::SetEnvironmentVariable("PSModulePath", $env:PSModulePath, "User")
}

Write-Host "Using module path: $customModuleRoot" -ForegroundColor Gray
Write-Host ""

$requiredModules = @(
    @{ Name = "Az"; MinVersion = "10.0.0"; Description = "Azure PowerShell modules" }
    @{ Name = "Microsoft.Graph"; MinVersion = "2.0.0"; Description = "Microsoft Graph PowerShell SDK" }
    @{ Name = "MicrosoftTeams"; MinVersion = "5.0.0"; Description = "Microsoft Teams PowerShell" }
    @{ Name = "ExchangeOnlineManagement"; MinVersion = "3.0.0"; Description = "Exchange Online PowerShell" }
    @{ Name = "PnP.PowerShell"; MinVersion = "2.0.0"; Description = "SharePoint PnP PowerShell" }
    @{ Name = "ImportExcel"; MinVersion = "7.0.0"; Description = "Excel export functionality" }
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
            Save-Module `
                -Name $module.Name `
                -Path $customModuleRoot `
                -Force `
                -AllowClobber `
                -IncludeDependencies `
                -MinimumVersion $module.MinVersion

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
Write-Host "  - Import required modules (Import-Module ...)" -ForegroundColor White
Write-Host "  - Authenticate using Connect-AzAccount or Connect-MgGraph as needed" -ForegroundColor White
