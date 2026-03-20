<#
.SYNOPSIS
    Removes OneDrive for Business sites for a list of users.

.DESCRIPTION
    Reads a list of user principal names from a JSON config file or from the
    -UserPrincipalNames parameter and removes each user's OneDrive for Business
    site via PnP PowerShell against the SharePoint Online admin center.

    By default the site is soft-deleted (recoverable from the SharePoint
    admin recycle bin). Use -SkipRecycleBin to permanently delete the site
    without any recovery window.

    The OneDrive URL is resolved automatically from the user's profile
    (Get-PnPUserProfileProperty). A tenant admin URL (-TenantAdminUrl) is
    required to connect to the SharePoint admin center.

    NOTE: OneDrive deletion is independent of the Entra ID user account.
    The user account does not need to be deleted first. However, if the user
    is still active, the site will be re-provisioned on next login.
    Delete the Entra ID user first (Remove-EntraUser.ps1) to prevent this.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Remove-OneDrive.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

    IMPORTANT: Run Connect-PnPOnline against the SharePoint admin center
    before executing this script, or supply -TenantAdminUrl to let the
    script connect interactively.

.EXAMPLE
    .\Remove-OneDrive.ps1 -ConfigName prod

.EXAMPLE
    .\Remove-OneDrive.ps1 -UserPrincipalNames 'alice@contoso.com' -TenantAdminUrl 'https://contoso-admin.sharepoint.com'

.EXAMPLE
    .\Remove-OneDrive.ps1 -ConfigName prod -WhatIf

.EXAMPLE
    .\Remove-OneDrive.ps1 -ConfigName prod -SkipRecycleBin

.NOTES
    Required SharePoint / PnP permissions:
      SharePoint Administrator role  -or-  Site Collection Administrator

    Prerequisites:
      PnP.PowerShell module (run .\shared\Install-Prerequisites.ps1)
      Connect-PnPOnline to the tenant admin URL must be called before running
      this script, or provide -TenantAdminUrl for interactive sign-in.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$ConfigName,

    # Directory to search for the config file. Defaults to the script directory.
    [Parameter(Mandatory = $false)]
    [string]$ConfigDir,

    # List of user principal names whose OneDrive sites will be removed.
    # Overrides the userPrincipalNames array in the config file.
    [Parameter(Mandatory = $false)]
    [string[]]$UserPrincipalNames,

    # SharePoint Online tenant admin URL, e.g. https://contoso-admin.sharepoint.com
    # Required when no active PnP connection to the admin center exists.
    # Overrides tenantAdminUrl in the config file.
    [Parameter(Mandatory = $false)]
    [string]$TenantAdminUrl,

    # When set, the OneDrive site is permanently deleted (bypasses the recycle bin).
    # Default: soft-delete (recoverable from SharePoint admin recycle bin).
    [Parameter(Mandatory = $false)]
    [switch]$SkipRecycleBin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\shared\AzToolkit.Config.psm1') -Force

# ── Config loading ─────────────────────────────────────────────────────────────

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Remove-OneDrive'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# Merge: direct parameter wins over config file
if (-not $UserPrincipalNames -and $null -ne $config -and $config.userPrincipalNames) {
    $UserPrincipalNames = [string[]]$config.userPrincipalNames
}

if (-not $TenantAdminUrl -and $null -ne $config -and $config.tenantAdminUrl) {
    $TenantAdminUrl = $config.tenantAdminUrl
}

if (-not $SkipRecycleBin -and $null -ne $config -and $config.skipRecycleBin -eq $true) {
    $SkipRecycleBin = $true
}

# ── Validation ─────────────────────────────────────────────────────────────────

if (-not $UserPrincipalNames -or $UserPrincipalNames.Count -eq 0) {
    Write-Host "No user principal names provided. Specify -UserPrincipalNames or set userPrincipalNames in the config file." -ForegroundColor Red
    exit 1
}

# Ensure PnP connection to admin center
try {
    $pnpConn = Get-PnPConnection -ErrorAction Stop
    if ($pnpConn.Url -notmatch '-admin\.sharepoint\.com') {
        if (-not $TenantAdminUrl) {
            Write-Host "Active PnP connection is not to the SharePoint admin center and no TenantAdminUrl was provided." -ForegroundColor Red
            Write-Host "Specify -TenantAdminUrl (or tenantAdminUrl in config) or connect to the admin center first:" -ForegroundColor Red
            Write-Host "Connect-PnPOnline -Url https://<tenant>-admin.sharepoint.com -Interactive" -ForegroundColor Red
            exit 1
        }

        Write-Host "Active PnP connection is not to the SharePoint admin center. Reconnecting to $TenantAdminUrl ..." -ForegroundColor Yellow
        Connect-PnPOnline -Url $TenantAdminUrl -Interactive
    }
}
catch {
    if (-not $TenantAdminUrl) {
        Write-Host "No active PnP connection found and no TenantAdminUrl was provided." -ForegroundColor Red
        Write-Host "Specify -TenantAdminUrl (or tenantAdminUrl in config) or connect first:" -ForegroundColor Red
        Write-Host "Connect-PnPOnline -Url https://<tenant>-admin.sharepoint.com -Interactive" -ForegroundColor Red
        exit 1
    }

    Write-Host "No active PnP connection found. Connecting to $TenantAdminUrl ..." -ForegroundColor Yellow
    Connect-PnPOnline -Url $TenantAdminUrl -Interactive
}

# ── Main ───────────────────────────────────────────────────────────────────────

Write-Host "=== Remove-OneDrive ===" -ForegroundColor Cyan
Write-Host "Users     : $($UserPrincipalNames.Count)" -ForegroundColor Cyan
Write-Host "Mode      : $(if ($SkipRecycleBin) { 'Permanently delete (bypass recycle bin)' } else { 'Soft-delete (recoverable via SharePoint admin recycle bin)' })" -ForegroundColor Cyan
Write-Host ""

$successCount = 0
$skipCount    = 0
$errorCount   = 0

foreach ($upn in $UserPrincipalNames) {

    Write-Host "Processing: $upn" -ForegroundColor Yellow

    # Resolve the OneDrive URL from the user profile
    $oneDriveUrl = $null
    try {
        $profile     = Get-PnPUserProfileProperty -Account $upn -ErrorAction Stop
        $oneDriveUrl = $profile.PersonalUrl
    }
    catch {
        Write-Host "  - Could not retrieve user profile: $($_.Exception.Message)" -ForegroundColor Red
        $errorCount++
        continue
    }

    if ([string]::IsNullOrWhiteSpace($oneDriveUrl)) {
        Write-Host "  - No OneDrive site found for this user – skipping." -ForegroundColor Gray
        $skipCount++
        continue
    }

    # Normalize URL (remove trailing slash)
    $oneDriveUrl = $oneDriveUrl.TrimEnd('/')

    Write-Host "  OneDrive : $oneDriveUrl" -ForegroundColor Gray

    if ($PSCmdlet.ShouldProcess($oneDriveUrl, "Remove OneDrive site")) {
        try {
            Remove-PnPTenantSite `
                -Url            $oneDriveUrl `
                -SkipRecycleBin:$SkipRecycleBin `
                -Force `
                -ErrorAction    Stop

            Write-Host "  - Removed successfully." -ForegroundColor Green
            $successCount++
        }
        catch {
            Write-Host "  X Failed: $($_.Exception.Message)" -ForegroundColor Red
            $errorCount++
        }
    }

    Write-Host ""
}

# ── Summary ────────────────────────────────────────────────────────────────────

Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "  Removed : $successCount" -ForegroundColor Green
Write-Host "  Skipped : $skipCount"    -ForegroundColor Gray
Write-Host "  Errors  : $errorCount"   -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } else { 'Gray' })

if (-not $SkipRecycleBin -and $successCount -gt 0) {
    Write-Host ""
    Write-Host "NOTE: Sites are in the SharePoint admin recycle bin and can be restored." -ForegroundColor Yellow
    Write-Host "      To permanently purge: Remove-PnPTenantRecycleBinItem -Url <url> -Force" -ForegroundColor Yellow
}

if ($errorCount -gt 0) {
    exit 1
}
