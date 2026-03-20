<#
.SYNOPSIS
    Removes Exchange Online mailboxes for a list of users.

.DESCRIPTION
    Reads a list of user principal names from a JSON config file or from the
    -UserPrincipalNames parameter and removes each user's mailbox from
    Exchange Online.

    By default the mailbox is soft-deleted (recoverable for 30 days).
    Use -PermanentlyDelete to hard-delete without any recovery window.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Remove-Mailbox.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

    IMPORTANT: Run Connect-ExchangeOnline before executing this script.

.EXAMPLE
    .\Remove-Mailbox.ps1 -ConfigName prod

.EXAMPLE
    .\Remove-Mailbox.ps1 -UserPrincipalNames 'alice@contoso.com','bob@contoso.com'

.EXAMPLE
    .\Remove-Mailbox.ps1 -ConfigName prod -WhatIf

.EXAMPLE
    .\Remove-Mailbox.ps1 -ConfigName prod -PermanentlyDelete

.NOTES
    Required Exchange Online permissions:
      Mailbox Import Export  –or–  Organization Management

    Prerequisites:
      ExchangeOnlineManagement module (run .\shared\Install-Prerequisites.ps1)
      Connect-ExchangeOnline must be called before running this script.
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

    # List of user principal names whose mailboxes will be removed.
    # Overrides the userPrincipalNames array in the config file.
    [Parameter(Mandatory = $false)]
    [string[]]$UserPrincipalNames,

    # When set, the mailbox is permanently deleted without any recovery window.
    # Default: soft-delete (recoverable for up to 30 days).
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
    -ConfigDir ($ConfigDir ? $ConfigDir : $PSScriptRoot) `
    -Prefix    'Remove-Mailbox'

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

# Verify Exchange Online session is available
try {
    $null = Get-OrganizationConfig -ErrorAction Stop
}
catch {
    Write-Host "Exchange Online session not found. Run Connect-ExchangeOnline before executing this script." -ForegroundColor Red
    exit 1
}

# ── Main ───────────────────────────────────────────────────────────────────────

Write-Host "=== Remove-Mailbox ===" -ForegroundColor Cyan
Write-Host "Users     : $($UserPrincipalNames.Count)" -ForegroundColor Cyan
Write-Host "Mode      : $(if ($PermanentlyDelete) { 'Permanently delete (no recovery)' } else { 'Soft-delete (recoverable 30 days)' })" -ForegroundColor Cyan
Write-Host ""

$supportsSoftDeletedMailboxLookup = (Get-Command Get-Mailbox -ErrorAction Stop).Parameters.ContainsKey('SoftDeletedMailbox')

$successCount = 0
$skipCount    = 0
$errorCount   = 0

foreach ($upn in $UserPrincipalNames) {

    Write-Host "Processing: $upn" -ForegroundColor Yellow

    # Check active and soft-deleted mailbox states.
    $mailbox = Get-Mailbox -Identity $upn -ErrorAction SilentlyContinue
    $softDeletedMailbox = $null
    if ($supportsSoftDeletedMailboxLookup) {
        $softDeletedMailbox = Get-Mailbox -SoftDeletedMailbox -Identity $upn -ErrorAction SilentlyContinue
    }

    if (-not $mailbox -and -not $softDeletedMailbox) {
        Write-Host "  - Mailbox not found – skipping." -ForegroundColor Gray
        $skipCount++
        continue
    }

    if ($mailbox) {
        Write-Host "  Mailbox : $($mailbox.DisplayName) ($($mailbox.RecipientTypeDetails))" -ForegroundColor Gray
    }
    else {
        Write-Host "  Mailbox : Soft-deleted ($($softDeletedMailbox.DisplayName))" -ForegroundColor Gray
        if (-not $PermanentlyDelete) {
            Write-Host "  - Mailbox is already soft-deleted. Use -PermanentlyDelete to purge it." -ForegroundColor Gray
            $skipCount++
            Write-Host ""
            continue
        }
    }

    if ($PSCmdlet.ShouldProcess($upn, "Remove mailbox")) {
        try {
            if ($PermanentlyDelete) {
                if ($mailbox) {
                    Remove-Mailbox -Identity $upn -PermanentlyDelete -Confirm:$false -ErrorAction Stop
                }
                else {
                    $removeIdentity = if ($softDeletedMailbox.ExchangeGuid) {
                        $softDeletedMailbox.ExchangeGuid.Guid
                    }
                    else {
                        $softDeletedMailbox.DistinguishedName
                    }
                    Remove-Mailbox -Identity $removeIdentity -PermanentlyDelete -Confirm:$false -ErrorAction Stop
                }
            }
            else {
                Remove-Mailbox -Identity $upn -Confirm:$false -ErrorAction Stop
            }
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

if ($errorCount -gt 0) {
    exit 1
}
