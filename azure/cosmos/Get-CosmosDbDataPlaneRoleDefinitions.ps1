<#
.SYNOPSIS
    Reads Azure Cosmos DB SQL data-plane role definitions.

.DESCRIPTION
    Retrieves SQL role definitions for a Cosmos DB account via
    Get-AzCosmosDBSqlRoleDefinition and prints a compact summary of
    effective data-plane permissions.

    In addition, the script loads current SQL role assignments via
    Get-AzCosmosDBSqlRoleAssignment and prints active assignments
    (principal, scope, role definition).

    Principal object IDs in assignments are resolved to display names
    (user, service principal, or group) by default.

    Authentication must be explicit. Run Connect-AzToolkit.ps1 or
    Connect-AzAccount before executing this script.

.EXAMPLE
    .\azure\cosmos\Get-CosmosDbDataPlaneRoleDefinitions.ps1 `
        -AccountName 'cosmos-prod-001' `
        -ResourceGroupName 'rg-data'

.EXAMPLE
    .\azure\cosmos\Get-CosmosDbDataPlaneRoleDefinitions.ps1 `
        -SubscriptionId '<subscription-guid>' `
        -AccountName 'cosmos-prod-001' `
        -ResourceGroupName 'rg-data' `
        -RoleDefinitionId '00000000-0000-0000-0000-000000000001'

.NOTES
    Required PowerShell module: Az.CosmosDB
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$AccountName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$RoleDefinitionId,

    # Disable principal name resolution and print principal IDs only.
    [Parameter(Mandatory = $false)]
    [switch]$SkipPrincipalNameResolution
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    return $Id.Trim().ToLowerInvariant().TrimEnd('/')
}

function Resolve-RoleName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RoleDefinitionId,

        [Parameter(Mandatory = $true)]
        [hashtable]$RoleMap
    )

    $normalized = Get-NormalizedId -Id $RoleDefinitionId
    if ($RoleMap.ContainsKey($normalized)) {
        return $RoleMap[$normalized]
    }

    return $RoleDefinitionId
}

function Resolve-PrincipalDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrincipalId
    )

    try {
        $user = Get-AzADUser -ObjectId $PrincipalId -ErrorAction SilentlyContinue
        if ($user) {
            return "$($user.DisplayName) [$($user.UserPrincipalName)]"
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
        $group = Get-AzADGroup -ObjectId $PrincipalId -ErrorAction SilentlyContinue
        if ($group) {
            return "$($group.DisplayName) [Group]"
        }
    }
    catch { }

    return $PrincipalId
}

if (-not (Get-Module -ListAvailable -Name Az.CosmosDB)) {
    Write-Host 'Missing module Az.CosmosDB. Install it first: Install-Module Az.CosmosDB -Scope CurrentUser' -ForegroundColor Red
    exit 1
}

Write-Host '=== Get-CosmosDbDataPlaneRoleDefinitions ===' -ForegroundColor Cyan
Write-Host "Account        : $AccountName" -ForegroundColor Gray
Write-Host "Resource Group : $ResourceGroupName" -ForegroundColor Gray
if ($SubscriptionId) {
    Write-Host "Subscription   : $SubscriptionId" -ForegroundColor Gray
}
if ($RoleDefinitionId) {
    Write-Host "Role ID Filter : $RoleDefinitionId" -ForegroundColor Gray
}
Write-Host "Resolve Names  : $(-not $SkipPrincipalNameResolution)" -ForegroundColor Gray
Write-Host ''

try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) {
        throw 'No context'
    }
}
catch {
    Write-Host 'No active Az PowerShell context. Run Connect-AzToolkit.ps1 or Connect-AzAccount first.' -ForegroundColor Red
    exit 1
}

if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
    Write-Host "Switching Az subscription context to: $SubscriptionId" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
}

Write-Host 'Loading Cosmos DB account settings...' -ForegroundColor Yellow
try {
    $cosmosAccount = Get-AzCosmosDBAccount `
        -Name $AccountName `
        -ResourceGroupName $ResourceGroupName `
        -ErrorAction Stop
}
catch {
    Write-Host "Failed to load Cosmos DB account settings: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$disableLocalAuth = $null

# Az.CosmosDB object shape differs across module versions.
$disableLocalAuthProperty = $cosmosAccount.PSObject.Properties['DisableLocalAuth']
if ($null -ne $disableLocalAuthProperty -and $null -ne $disableLocalAuthProperty.Value) {
    $disableLocalAuth = [bool]$disableLocalAuthProperty.Value
}

# Fallback: read raw ARM properties where disableLocalAuth is usually present.
if ($null -eq $disableLocalAuth) {
    try {
        $resource = Get-AzResource `
            -ResourceGroupName $ResourceGroupName `
            -ResourceType 'Microsoft.DocumentDB/databaseAccounts' `
            -Name $AccountName `
            -ErrorAction Stop

        $armDisableLocalAuth = $resource.Properties.PSObject.Properties['disableLocalAuth']
        if ($null -ne $armDisableLocalAuth -and $null -ne $armDisableLocalAuth.Value) {
            $disableLocalAuth = [bool]$armDisableLocalAuth.Value
        }
    }
    catch { }
}

$disableLocalAuthDisplay = if ($null -eq $disableLocalAuth) { 'Unknown (not exposed by installed Az modules/API response)' } else { [string]$disableLocalAuth }

Write-Host "Disable Local Auth : $disableLocalAuthDisplay" -ForegroundColor Gray
Write-Host ''

$accountSettingsResult = [PSCustomObject]@{
    AccountName       = $AccountName
    ResourceGroupName = $ResourceGroupName
    DisableLocalAuth  = $disableLocalAuth
}

Write-Host 'Account security settings:' -ForegroundColor Green
$accountSettingsResult
Write-Host ''

Write-Host 'Loading Cosmos DB SQL role definitions...' -ForegroundColor Yellow
try {
    $roleDefinitions = @(Get-AzCosmosDBSqlRoleDefinition `
        -AccountName $AccountName `
        -ResourceGroupName $ResourceGroupName `
        -ErrorAction Stop)
}
catch {
    Write-Host "Failed to load role definitions: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if ($RoleDefinitionId) {
    $targetId = Get-NormalizedId -Id $RoleDefinitionId
    $roleDefinitions = @(
        $roleDefinitions | Where-Object {
            $normalized = Get-NormalizedId -Id $_.Id
            $byFullId = $normalized -eq $targetId
            $byGuid = (($_.Id -split '/')[-1]).ToLowerInvariant() -eq $targetId
            $byFullId -or $byGuid
        }
    )
}

if (-not $roleDefinitions -or $roleDefinitions.Count -eq 0) {
    Write-Host 'No SQL role definitions found for the given filters.' -ForegroundColor Yellow
    exit 0
}

$result = foreach ($role in ($roleDefinitions | Sort-Object RoleName, Type)) {
    $dataActions = @($role.Permissions | ForEach-Object { $_.DataActions } | Where-Object { $_ })
    $notDataActions = @($role.Permissions | ForEach-Object { $_.NotDataActions } | Where-Object { $_ })

    [PSCustomObject]@{
        RoleName         = $role.RoleName
        Type             = $role.Type
        Id               = $role.Id
        AssignableScopes = ($role.AssignableScopes -join '; ')
        DataActions      = ($dataActions -join '; ')
        NotDataActions   = ($notDataActions -join '; ')
    }
}

Write-Host "Found $($result.Count) SQL role definition(s)." -ForegroundColor Green
$result

# Build lookup map for role names used by assignments output.
$roleMap = @{}
foreach ($role in $roleDefinitions) {
    $roleMap[(Get-NormalizedId -Id $role.Id)] = if ($role.RoleName) { $role.RoleName } else { $role.Id }
}

Write-Host ''
Write-Host 'Loading Cosmos DB SQL role assignments...' -ForegroundColor Yellow
try {
    $assignments = @(Get-AzCosmosDBSqlRoleAssignment `
        -AccountName $AccountName `
        -ResourceGroupName $ResourceGroupName `
        -ErrorAction Stop)
}
catch {
    Write-Host "Failed to load role assignments: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if ($RoleDefinitionId) {
    $targetId = Get-NormalizedId -Id $RoleDefinitionId
    $assignments = @(
        $assignments | Where-Object {
            $normalized = Get-NormalizedId -Id $_.RoleDefinitionId
            $byFullId = $normalized -eq $targetId
            $byGuid = (($_.RoleDefinitionId -split '/')[-1]).ToLowerInvariant() -eq $targetId
            $byFullId -or $byGuid
        }
    )
}

if (-not $assignments -or $assignments.Count -eq 0) {
    Write-Host 'No active SQL role assignments found for the given filters.' -ForegroundColor Yellow
    exit 0
}

$principalNameCache = @{}

$assignmentResult = foreach ($assignment in ($assignments | Sort-Object Scope, PrincipalId)) {
    $principalDisplayName = $assignment.PrincipalId
    if (-not $SkipPrincipalNameResolution) {
        if (-not $principalNameCache.ContainsKey($assignment.PrincipalId)) {
            $principalNameCache[$assignment.PrincipalId] = Resolve-PrincipalDisplayName -PrincipalId $assignment.PrincipalId
        }
        $principalDisplayName = $principalNameCache[$assignment.PrincipalId]
    }

    [PSCustomObject]@{
        RoleName         = Resolve-RoleName -RoleDefinitionId $assignment.RoleDefinitionId -RoleMap $roleMap
        RoleDefinitionId = $assignment.RoleDefinitionId
        Principal        = $principalDisplayName
        PrincipalId      = $assignment.PrincipalId
        Scope            = $assignment.Scope
        AssignmentId     = $assignment.Id
    }
}

Write-Host "Found $($assignmentResult.Count) active SQL role assignment(s)." -ForegroundColor Green
$assignmentResult
