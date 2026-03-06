<#
.SYNOPSIS
    Lists all direct Azure RBAC role assignments for one or more user accounts.

.DESCRIPTION
    Resolves a user by UPN, object ID, or short name ("Kürzel") and queries
    role assignments across all accessible subscriptions (or a filtered subset).

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Get-UserRoleAssignments.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

.EXAMPLE
    .\Get-UserRoleAssignments.ps1 -ConfigName contoso

.EXAMPLE
    .\Get-UserRoleAssignments.ps1 -Upn 'user@contoso.com'

.EXAMPLE
    .\Get-UserRoleAssignments.ps1 -UserKuerzel 'mmm99' -ExportCsv

.NOTES
    Required Azure role (minimum): Reader on each subscription
    Required Azure permissions:
      Microsoft.Authorization/roleAssignments/read  (Get-AzRoleAssignment)
    Required Microsoft Entra permission (principal lookup):
      User.Read.All  (Get-AzADUser)
    Prerequisites:
      Az.Resources module (run .\shared\Install-Prerequisites.ps1)
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

    # UPN of the user (e.g. user@contoso.com).
    [Parameter(Mandatory = $false)]
    [string]$Upn,

    # Short name / "Kürzel" – resolved against primaryDomain and secondaryDomain.
    [Parameter(Mandatory = $false)]
    [string]$UserKuerzel,

    # Object ID of the principal. Bypasses the Entra lookup when provided.
    [Parameter(Mandatory = $false)]
    [string]$ObjectId,

    # Limit the search to specific subscription IDs (comma-separated or array).
    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    # Primary domain used for Kürzel resolution (e.g. contoso.com).
    [Parameter(Mandatory = $false)]
    [string]$PrimaryDomain,

    # Secondary / on-premises sync domain (e.g. contoso.onmicrosoft.com).
    [Parameter(Mandatory = $false)]
    [string]$SecondaryDomain,

    # Export results to a CSV file in the script directory (or export.outputDir).
    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\AzToolkit.Config.psm1') -Force

# ============================================================================
# Load config file and merge parameters
# ============================================================================

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name        $ConfigName `
    -ConfigDir   $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix      'Get-UserRoleAssignments'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

if ($null -ne $config) {
    $principalCfg = $config.PSObject.Properties['principal']?.Value
    $searchCfg    = $config.PSObject.Properties['search']?.Value
    $exportCfg    = $config.PSObject.Properties['export']?.Value

    if ($null -ne $principalCfg) {
        if (-not $Upn)         { $Upn         = $principalCfg.PSObject.Properties['upn']?.Value }
        if (-not $UserKuerzel) { $UserKuerzel = $principalCfg.PSObject.Properties['userKuerzel']?.Value }
        if (-not $ObjectId)    { $ObjectId    = $principalCfg.PSObject.Properties['objectId']?.Value }
    }

    if ($null -ne $searchCfg) {
        if (-not $SubscriptionIds) {
            $subIdsCfg = $searchCfg.PSObject.Properties['subscriptionIds']?.Value
            if ($subIdsCfg) { $SubscriptionIds = @($subIdsCfg) }
        }
        if (-not $PrimaryDomain)   { $PrimaryDomain   = $searchCfg.PSObject.Properties['primaryDomain']?.Value }
        if (-not $SecondaryDomain) { $SecondaryDomain = $searchCfg.PSObject.Properties['secondaryDomain']?.Value }
    }

    if ($null -ne $exportCfg -and -not $ExportCsv) {
        $csvFlag = $exportCfg.PSObject.Properties['csv']?.Value
        if ($csvFlag -eq $true) { $ExportCsv = $true }
    }
}

# ============================================================================
# Validation
# ============================================================================

if (-not $Upn -and -not $UserKuerzel -and -not $ObjectId) {
    throw 'Provide at least one of the following parameters: -Upn, -UserKuerzel, or -ObjectId.'
}

if ($UserKuerzel -and (-not $PrimaryDomain)) {
    throw '-PrimaryDomain is required when using -UserKuerzel (or set search.primaryDomain in the config file).'
}

# ============================================================================
# Verify Azure context
# ============================================================================

try {
    $azContext = Get-AzContext -ErrorAction Stop
    if (-not $azContext) { throw 'No context' }
    Write-Host "Azure connection active: $($azContext.Account.Id)" -ForegroundColor DarkGray
}
catch {
    Write-Host 'Connecting to Azure...' -ForegroundColor Yellow
    $null = Connect-AzAccount
}

# ============================================================================
# Resolve user objects via Entra
# ============================================================================

$resolvedUsers = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($ObjectId -and -not $Upn -and -not $UserKuerzel) {
    # Only ObjectId provided – no Entra lookup needed
    $resolvedUsers.Add([PSCustomObject]@{
        Id                = $ObjectId
        DisplayName       = $ObjectId
        UserPrincipalName = $null
    })
}
elseif ($Upn) {
    Write-Host "Looking up user '$Upn' via Entra..." -ForegroundColor Cyan
    try {
        $adUser = Get-AzADUser -UserPrincipalName $Upn -ErrorAction Stop
        if ($adUser) {
            $resolvedUsers.Add([PSCustomObject]@{
                Id                = $adUser.Id
                DisplayName       = $adUser.DisplayName
                UserPrincipalName = $adUser.UserPrincipalName
            })
        }
    }
    catch {
        Write-Warning "Could not resolve user '$Upn': $($_.Exception.Message)"
        Write-Warning 'Fallback: using UPN directly for RBAC lookup.'
        $resolvedUsers.Add([PSCustomObject]@{
            Id                = $null
            DisplayName       = $Upn
            UserPrincipalName = $Upn
        })
    }
}
elseif ($UserKuerzel) {
    Write-Host "Looking up user with short name '$UserKuerzel' via Entra..." -ForegroundColor Cyan

    # Primary account
    $primaryUpn = "$UserKuerzel@$PrimaryDomain"
    try {
        $primaryUser = Get-AzADUser -UserPrincipalName $primaryUpn -ErrorAction Stop
        if ($primaryUser) {
            $resolvedUsers.Add([PSCustomObject]@{
                Id                = $primaryUser.Id
                DisplayName       = $primaryUser.DisplayName
                UserPrincipalName = $primaryUser.UserPrincipalName
            })
            Write-Host "  Primary account: $($primaryUser.DisplayName) ($($primaryUser.UserPrincipalName))" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "  No match for primary account '$primaryUpn'." -ForegroundColor DarkGray
    }

    # Additional accounts in the secondary domain (if configured)
    if ($SecondaryDomain) {
        try {
            $secondaryUsers = Get-AzADUser -Filter "startsWith(userPrincipalName,'$UserKuerzel') and endsWith(userPrincipalName,'@$SecondaryDomain')" -ErrorAction Stop
            foreach ($su in $secondaryUsers) {
                if (-not ($resolvedUsers | Where-Object { $_.Id -eq $su.Id })) {
                    $resolvedUsers.Add([PSCustomObject]@{
                        Id                = $su.Id
                        DisplayName       = $su.DisplayName
                        UserPrincipalName = $su.UserPrincipalName
                    })
                    Write-Host "  Additional account: $($su.DisplayName) ($($su.UserPrincipalName))" -ForegroundColor DarkGray
                }
            }
        }
        catch {
            Write-Warning "Error searching secondary domain '$SecondaryDomain': $($_.Exception.Message)"
        }
    }
}

if ($resolvedUsers.Count -eq 0) {
    throw 'No user account found – aborting.'
}

Write-Host ''
Write-Host "Resolved user accounts ($($resolvedUsers.Count)):" -ForegroundColor Cyan
foreach ($u in $resolvedUsers) {
    $label = if ($u.UserPrincipalName) { "$($u.DisplayName) | $($u.UserPrincipalName)" } else { "ObjectId: $($u.Id)" }
    Write-Host "  - $label" -ForegroundColor White
}
Write-Host ''

# ============================================================================
# Retrieve subscriptions
# ============================================================================

Write-Host 'Loading subscriptions...' -ForegroundColor Cyan
$allSubscriptions = Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' }

if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
    $allSubscriptions = $allSubscriptions | Where-Object { $SubscriptionIds -contains $_.Id }
    Write-Host "  Filtered to $($allSubscriptions.Count) subscription(s)." -ForegroundColor DarkGray
}
else {
    Write-Host "  $($allSubscriptions.Count) subscription(s) found." -ForegroundColor DarkGray
}
Write-Host ''

# ============================================================================
# Retrieve RBAC assignments across all subscriptions
# ============================================================================

$allAssignments = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($sub in $allSubscriptions) {
    Write-Host "Scanning subscription: $($sub.Name) ($($sub.Id)) ..." -ForegroundColor Cyan

    try {
        $null = Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop
    }
    catch {
        Write-Warning "  Could not switch to subscription '$($sub.Name)': $($_.Exception.Message)"
        continue
    }

    foreach ($user in $resolvedUsers) {
        try {
            $raParams = @{ ErrorAction = 'SilentlyContinue' }
            if ($user.Id) {
                $raParams['ObjectId']   = $user.Id
            }
            else {
                $raParams['SignInName'] = $user.UserPrincipalName
            }

            $assignments = Get-AzRoleAssignment @raParams |
                Where-Object { $_.ObjectType -eq 'User' }

            if ($assignments) {
                foreach ($a in $assignments) {
                    $allAssignments.Add([PSCustomObject]@{
                        User           = if ($user.UserPrincipalName) { $user.UserPrincipalName } else { $user.Id }
                        DisplayName    = $user.DisplayName
                        Role           = $a.RoleDefinitionName
                        Scope          = $a.Scope
                        ScopeType      = switch -Regex ($a.Scope) {
                            '^/subscriptions/[^/]+$'                   { 'Subscription'   }
                            '^/subscriptions/.+/resourceGroups/[^/]+$' { 'ResourceGroup'  }
                            '^/subscriptions/.+/resourceGroups/.+/.+'  { 'Resource'       }
                            '^/providers/Microsoft\.Management'        { 'ManagementGroup' }
                            default                                    { 'Unknown'        }
                        }
                        Subscription   = $sub.Name
                        SubscriptionId = $sub.Id
                    })
                }
                Write-Host "  $($assignments.Count) assignment(s) found for $($user.UserPrincipalName ?? $user.Id)" -ForegroundColor Green
            }
            else {
                Write-Host "  No direct assignments for $($user.UserPrincipalName ?? $user.Id)" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Warning "  Error processing $($user.UserPrincipalName ?? $user.Id): $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# Output results
# ============================================================================

Write-Host ''
Write-Host ('=' * 64) -ForegroundColor Magenta
    Write-Host "  Direct RBAC assignments: $($allAssignments.Count) found" -ForegroundColor Magenta
Write-Host ('=' * 64) -ForegroundColor Magenta
Write-Host ''

if ($allAssignments.Count -gt 0) {
    $allAssignments |
        Sort-Object Subscription, User, Role |
        Format-Table -AutoSize -Property User, Role, ScopeType, Scope, Subscription

    if ($ExportCsv) {
        $outputDir = $PSScriptRoot
        if ($null -ne $config) {
            $exportCfg = $config.PSObject.Properties['export']?.Value
            if ($exportCfg) {
                $cfgOutputDir = $exportCfg.PSObject.Properties['outputDir']?.Value
                if ($cfgOutputDir) { $outputDir = $cfgOutputDir }
            }
        }
        $timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $exportPath = Join-Path $outputDir "UserRoleAssignments_$timestamp.csv"
        $allAssignments | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Write-Host "Export saved: $exportPath" -ForegroundColor Yellow
    }
}
else {
    Write-Host 'No direct RBAC assignments found.' -ForegroundColor Yellow
}
