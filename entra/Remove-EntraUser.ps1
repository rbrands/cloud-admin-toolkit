<#
.SYNOPSIS
    Removes Entra ID user accounts for a list of users.

.DESCRIPTION
    Reads a list of user principal names from a JSON config file or from the
    -UserPrincipalNames parameter and removes each user account from Entra ID
    via Microsoft Graph.

    By default the user is soft-deleted (recoverable from the recycling bin
    for 30 days). Use -PermanentlyDelete to immediately hard-delete the user
    from the recycling bin as well.

    Side effects of deleting a user:
      - Exchange Online: mailbox becomes disconnected; soft-deleted for 30 days.
        Use Remove-Mailbox -PermanentlyDelete afterwards (requires Exchange sync,
        which may take several minutes to hours).
      - OneDrive for Business: content is preserved for the retention period
        configured in the SharePoint admin center (default: 30 days, max: 180 days).
        The user's manager receives access to the OneDrive content if configured.
      - Teams: the user is removed from all teams and channels.
      - Licenses: assigned licenses are released automatically after deletion.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Remove-EntraUser.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

    IMPORTANT: Run Connect-MgGraph with the required scopes before executing
    this script.

.EXAMPLE
    .\Remove-EntraUser.ps1 -ConfigName prod

.EXAMPLE
    .\Remove-EntraUser.ps1 -UserPrincipalNames 'alice@contoso.com','bob@contoso.com'

.EXAMPLE
    .\Remove-EntraUser.ps1 -ConfigName prod -WhatIf

.EXAMPLE
    .\Remove-EntraUser.ps1 -ConfigName prod -PermanentlyDelete

.NOTES
    Required Microsoft Graph scopes:
      User.ReadWrite.All

    Additional scope required for -PermanentlyDelete:
      Directory.ReadWrite.All

    Prerequisites:
      Microsoft.Graph module (run .\shared\Install-Prerequisites.ps1)
      Connect-MgGraph must be called before running this script.
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

    # List of user principal names to remove.
    # Overrides the userPrincipalNames array in the config file.
    [Parameter(Mandatory = $false)]
    [string[]]$UserPrincipalNames,

    # When set, the user is also permanently deleted from the Entra ID recycling bin.
    # Default: soft-delete only (recoverable for 30 days).
    # NOTE: permanent deletion of the associated Exchange mailbox requires a
    # separate step after Exchange Online has re-synced (may take minutes to hours).
    [Parameter(Mandatory = $false)]
    [switch]$PermanentlyDelete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\shared\AzToolkit.Config.psm1') -Force

# ── Config loading ─────────────────────────────────────────────────────────────

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Remove-EntraUser'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# Merge: direct parameter wins over config file
if (-not $UserPrincipalNames -and $null -ne $config -and $config.userPrincipalNames) {
    $UserPrincipalNames = [string[]]$config.userPrincipalNames
}

if (-not $PermanentlyDelete -and $null -ne $config -and $config.permanentlyDelete -eq $true) {
    $PermanentlyDelete = $true
}

# ── Validation ─────────────────────────────────────────────────────────────────

if (-not $UserPrincipalNames -or $UserPrincipalNames.Count -eq 0) {
    Write-Host "No user principal names provided. Specify -UserPrincipalNames or set userPrincipalNames in the config file." -ForegroundColor Red
    exit 1
}

# Verify Microsoft Graph session is available
try {
    $null = Get-MgContext -ErrorAction Stop
    if (-not (Get-MgContext)) {
        throw "No active context."
    }
}
catch {
    Write-Host "Microsoft Graph session not found. Run Connect-MgGraph before executing this script." -ForegroundColor Red
    exit 1
}

# ── Main ───────────────────────────────────────────────────────────────────────

Write-Host "=== Remove-EntraUser ===" -ForegroundColor Cyan
Write-Host "Users     : $($UserPrincipalNames.Count)" -ForegroundColor Cyan
Write-Host "Mode      : $(if ($PermanentlyDelete) { 'Permanently delete (soft-delete + purge from recycling bin)' } else { 'Soft-delete (recoverable 30 days)' })" -ForegroundColor Cyan
Write-Host ""

if ($PermanentlyDelete) {
    Write-Host "NOTE: Exchange Online mailbox permanent deletion requires a separate" -ForegroundColor Yellow
    Write-Host "      Remove-Mailbox -PermanentlyDelete step after Exchange has synced" -ForegroundColor Yellow
    Write-Host "      (may take several minutes to hours)." -ForegroundColor Yellow
    Write-Host "NOTE: OneDrive content is preserved for the SharePoint retention period" -ForegroundColor Yellow
    Write-Host "      (default 30 days) regardless of this setting." -ForegroundColor Yellow
    Write-Host ""
}

$successCount = 0
$skipCount    = 0
$errorCount   = 0

foreach ($upn in $UserPrincipalNames) {

    Write-Host "Processing: $upn" -ForegroundColor Yellow

    # Check whether the user exists
    $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
    $deletedUser = $null

    if (-not $user) {
        $deletedUser = Get-MgDirectoryDeletedItemAsUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue

        if ($deletedUser) {
            Write-Host "  - User already soft-deleted." -ForegroundColor Yellow

            if ($PermanentlyDelete) {
                if ($PSCmdlet.ShouldProcess($upn, "Permanently delete already soft-deleted Entra ID user")) {
                    try {
                        Remove-MgDirectoryDeletedItem -DirectoryObjectId $deletedUser.Id -ErrorAction Stop
                        Write-Host "  - Permanently deleted from recycling bin." -ForegroundColor Green
                        $successCount++
                    }
                    catch {
                        Write-Host "  X Failed: $($_.Exception.Message)" -ForegroundColor Red
                        $errorCount++
                    }
                }
            }
            else {
                Write-Host "  - Skipping. Use -PermanentlyDelete to purge from recycling bin." -ForegroundColor Gray
                $skipCount++
            }

            Write-Host ""
            continue
        }

        Write-Host "  - User not found (active or deleted) – skipping." -ForegroundColor Gray
        $skipCount++
        continue
    }

    Write-Host "  User     : $($user.DisplayName)" -ForegroundColor Gray
    Write-Host "  Object ID: $($user.Id)" -ForegroundColor Gray

    if ($PSCmdlet.ShouldProcess($upn, "Remove Entra ID user")) {
        try {
            # Step 1: soft-delete the user
            Remove-MgUser -UserId $user.Id -ErrorAction Stop
            Write-Host "  - Soft-deleted from Entra ID." -ForegroundColor Green

            # Step 2 (optional): purge from recycling bin
            if ($PermanentlyDelete) {
                Remove-MgDirectoryDeletedItem -DirectoryObjectId $user.Id -ErrorAction Stop
                Write-Host "  - Permanently deleted from recycling bin." -ForegroundColor Green
            }

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

if ($PermanentlyDelete -and $successCount -gt 0) {
    Write-Host "" 
    Write-Host "Next step (Exchange Online):" -ForegroundColor Cyan
    Write-Host "  After Exchange has synced, run:" -ForegroundColor White
    Write-Host "  .\m365\Remove-Mailbox.ps1 -UserPrincipalNames <upn> -PermanentlyDelete" -ForegroundColor White
}

if ($errorCount -gt 0) {
    exit 1
}
