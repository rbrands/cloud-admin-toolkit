<#
.SYNOPSIS
    Lists Azure Cosmos DB SQL RBAC role assignments with human-readable names.

.DESCRIPTION
    Retrieves SQL data-plane role assignments for a Cosmos DB account and resolves:

    - Role definition IDs to role names
    - Principal object IDs to display names (user, service principal, or group)

    Uses the Az.CosmosDB PowerShell module exclusively (no Azure CLI dependency).

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads List-CosmosDbRBAC.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

.EXAMPLE
    .\List-CosmosDbRBAC.ps1 -ConfigName prod

.EXAMPLE
    .\List-CosmosDbRBAC.ps1 -AccountName 'cosmos-brands-advisory' -ResourceGroupName 'rg-brands-advisory'

.NOTES
    Required PowerShell module: Az.CosmosDB

    Required Azure permissions (minimum):
      Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments/read
      Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions/read

    Required Microsoft Entra permission for principal name resolution:
      User.Read.All (for user lookup via Get-AzADUser)

    Authentication must be explicit. Run Connect-AzToolkit.ps1 or Connect-AzAccount
    before executing this script.
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
    [string]$SubscriptionId,

    # Cosmos DB account name.
    [Parameter(Mandatory = $false)]
    [string]$AccountName,

    # Resource group of the Cosmos DB account.
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    # Resolve principal IDs to human-readable names.
    [Parameter(Mandatory = $false)]
    [Nullable[bool]]$ResolvePrincipalNames
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\AzToolkit.Config.psm1') -Force

function Get-NormalizedRoleDefinitionId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RoleDefinitionId
    )

    # Normalize for reliable dictionary lookup across id formats.
    return $RoleDefinitionId.Trim().ToLowerInvariant().TrimEnd('/')
}

function Resolve-PrincipalDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrincipalId
    )

    # Try user, then service principal, then group.
    try {
        $u = Get-AzADUser -ObjectId $PrincipalId -ErrorAction SilentlyContinue
        if ($u) {
            return "$($u.DisplayName) [$($u.UserPrincipalName)]"
        }
    }
    catch { }

    try {
        $sp = Get-AzADServicePrincipal -ObjectId $PrincipalId -ErrorAction SilentlyContinue
        if ($sp) {
            return "$($sp.DisplayName) [ServicePrincipal]"
        }
    }
    catch { }

    try {
        $g = Get-AzADGroup -ObjectId $PrincipalId -ErrorAction SilentlyContinue
        if ($g) {
            return "$($g.DisplayName) [Group]"
        }
    }
    catch { }

    return $PrincipalId
}

# ── Config loading ─────────────────────────────────────────────────────────────

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'List-CosmosDbRBAC'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

if ($null -ne $config) {
    $ctxCfg    = $config.PSObject.Properties['context']?.Value
    $targetCfg = $config.PSObject.Properties['target']?.Value
    $viewCfg   = $config.PSObject.Properties['view']?.Value

    if (-not $SubscriptionId -and $null -ne $ctxCfg) {
        $SubscriptionId = $ctxCfg.PSObject.Properties['subscriptionId']?.Value
    }

    if ($null -ne $targetCfg) {
        if (-not $AccountName) { $AccountName = $targetCfg.PSObject.Properties['accountName']?.Value }
        if (-not $ResourceGroupName) { $ResourceGroupName = $targetCfg.PSObject.Properties['resourceGroupName']?.Value }
    }

    if (-not $PSBoundParameters.ContainsKey('ResolvePrincipalNames') -and $null -ne $viewCfg -and
        $viewCfg.PSObject.Properties['resolvePrincipalNames']) {
        $ResolvePrincipalNames = [bool]$viewCfg.resolvePrincipalNames
    }
}

if ($null -eq $ResolvePrincipalNames) {
    $ResolvePrincipalNames = $true
}

# ── Validation ─────────────────────────────────────────────────────────────────

if (-not $AccountName) {
    Write-Host 'AccountName is required.' -ForegroundColor Red
    exit 1
}

if (-not $ResourceGroupName) {
    Write-Host 'ResourceGroupName is required.' -ForegroundColor Red
    exit 1
}

# ── Prerequisites and context ──────────────────────────────────────────────────

Write-Host '=== List-CosmosDbRBAC ===' -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Config         : $resolvedConfigPath" -ForegroundColor Gray
}
Write-Host "Account        : $AccountName" -ForegroundColor Gray
Write-Host "Resource Group : $ResourceGroupName" -ForegroundColor Gray
Write-Host "Resolve names  : $ResolvePrincipalNames" -ForegroundColor Gray
Write-Host ''

# Ensure Az PowerShell context is available.
try {
    $azContext = Get-AzContext -ErrorAction Stop
    if (-not $azContext) { throw 'No context' }
}
catch {
    Write-Host 'No active Az PowerShell context. Run Connect-AzToolkit.ps1 or Connect-AzAccount first.' -ForegroundColor Red
    exit 1
}

# Switch subscription if specified.
if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
    Write-Host "Switching Az subscription context to: $SubscriptionId" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
}

if (-not $ResolvePrincipalNames) {
    Write-Host 'Note: Principal name resolution is disabled. Object IDs will be shown.' -ForegroundColor Yellow
}

# ── Load Cosmos role assignments and role definitions ──────────────────────────

Write-Host 'Loading Cosmos DB SQL role assignments...' -ForegroundColor Cyan
try {
    $assignments = @(Get-AzCosmosDBSqlRoleAssignment `
        -AccountName       $AccountName `
        -ResourceGroupName $ResourceGroupName `
        -ErrorAction       Stop)
}
catch {
    Write-Host 'Failed to load role assignments.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Write-Host 'Loading Cosmos DB SQL role definitions...' -ForegroundColor Cyan
try {
    $roleDefinitions = @(Get-AzCosmosDBSqlRoleDefinition `
        -AccountName       $AccountName `
        -ResourceGroupName $ResourceGroupName `
        -ErrorAction       Stop)
}
catch {
    Write-Host 'Failed to load role definitions.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# Build role definition map by normalized id.
$roleMap = @{}
foreach ($rd in $roleDefinitions) {
    $rdId = Get-NormalizedRoleDefinitionId -RoleDefinitionId $rd.Id
    $roleMap[$rdId] = if ($rd.RoleName) { $rd.RoleName } else { $rd.Id }
}

# Cache principal lookups to avoid repeated Entra calls.
$principalNameCache = @{}

$rows = foreach ($assignment in $assignments) {
    $normalizedRoleId = Get-NormalizedRoleDefinitionId -RoleDefinitionId $assignment.RoleDefinitionId
    $roleName = if ($roleMap.ContainsKey($normalizedRoleId)) {
        $roleMap[$normalizedRoleId]
    }
    else {
        $assignment.RoleDefinitionId
    }

    $principalDisplay = $assignment.PrincipalId
    if ($ResolvePrincipalNames) {
        if (-not $principalNameCache.ContainsKey($assignment.PrincipalId)) {
            $principalNameCache[$assignment.PrincipalId] = Resolve-PrincipalDisplayName -PrincipalId $assignment.PrincipalId
        }
        $principalDisplay = $principalNameCache[$assignment.PrincipalId]
    }

    [PSCustomObject]@{
        RoleName      = $roleName
        Principal     = $principalDisplay
        PrincipalId   = $assignment.PrincipalId
        Scope         = $assignment.Scope
        AssignmentId  = $assignment.Id
    }
}

Write-Host ''
if ($rows.Count -eq 0) {
    Write-Host 'No Cosmos DB SQL role assignments found.' -ForegroundColor Yellow
    return
}

Write-Host "Found $($rows.Count) Cosmos DB SQL role assignment(s)." -ForegroundColor Green
Write-Host ''

$rows |
    Sort-Object RoleName, Principal |
    Format-Table -AutoSize -Property RoleName, Principal, Scope
