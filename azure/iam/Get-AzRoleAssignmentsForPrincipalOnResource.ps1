<#
.SYNOPSIS
    Lists all Azure role assignments for a principal on a specific resource.

.DESCRIPTION
    Looks up role assignments for a user or service principal (identified by UPN or
    object ID) on a specific Azure resource. The resource is identified by name, with
    optional resource type and resource group filters to disambiguate.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Get-AzRoleAssignmentsForPrincipalOnResource.<Name>.json)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

.EXAMPLE
    .\Get-AzRoleAssignmentsForPrincipalOnResource.ps1 -ConfigName prod

.EXAMPLE
    .\Get-AzRoleAssignmentsForPrincipalOnResource.ps1 -ResourceName 'my-storage' -Upn 'user@contoso.com'

.NOTES
    Required Azure role (minimum): Reader
    Scope: the target resource or its Resource Group
    Required permissions:
      Microsoft.ResourceGraph/resources/read        (for resource lookup via Search-AzGraph)
      Microsoft.Authorization/roleAssignments/read  (for listing assignments via Get-AzRoleAssignment)
    Prerequisites:
      Az.ResourceGraph module  (Install-Module Az.ResourceGraph)
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

    [Parameter(Mandatory = $false)]
    [string]$ResourceName,

    # Optional: narrows the resource lookup when multiple resources share the same name.
    [Parameter(Mandatory = $false)]
    [string]$ResourceType,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    # UPN of the user (e.g. user@contoso.com). Either Upn or ObjectId is required.
    [Parameter(Mandatory = $false)]
    [string]$Upn,

    # Object ID of the principal. Takes precedence over Upn for the assignee lookup.
    [Parameter(Mandatory = $false)]
    [string]$ObjectId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\AzToolkit.Config.psm1') -Force

# --- Resolve config file ---
$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name $ConfigName `
    -ConfigDir $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix 'Get-AzRoleAssignmentsForPrincipalOnResource'
$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# --- Merge config + parameters ---
if ($null -ne $config) {
    $ctxValue       = $config.PSObject.Properties['context']?.Value
    $lookupValue    = $config.PSObject.Properties['lookup']?.Value
    $principalValue = $config.PSObject.Properties['principal']?.Value

    if (-not $SubscriptionId -and $null -ne $ctxValue) {
        $SubscriptionId = $ctxValue.PSObject.Properties['subscriptionId']?.Value
    }
    if ($null -ne $lookupValue) {
        if (-not $ResourceName)  { $ResourceName  = $lookupValue.PSObject.Properties['resourceName']?.Value }
        if (-not $ResourceType)  { $ResourceType  = $lookupValue.PSObject.Properties['resourceType']?.Value }
        if (-not $ResourceGroup) { $ResourceGroup = $lookupValue.PSObject.Properties['resourceGroup']?.Value }
    }
    if ($null -ne $principalValue) {
        if (-not $Upn)      { $Upn      = $principalValue.PSObject.Properties['upn']?.Value }
        if (-not $ObjectId) { $ObjectId = $principalValue.PSObject.Properties['objectId']?.Value }
    }
}

# --- Validate ---
if (-not $ResourceName)            { throw 'ResourceName is required.' }
if (-not $Upn -and -not $ObjectId) { throw 'Either Upn or ObjectId is required.' }

# --- Set subscription context ---
if ($SubscriptionId) {
    Write-Host "Setting subscription context: $SubscriptionId" -ForegroundColor Cyan
    $null = Set-AzContext -SubscriptionId $SubscriptionId
}

# --- Resolve resource via Resource Graph (KQL) ---
Write-Host "Looking up resource '$ResourceName' via Resource Graph..." -ForegroundColor Cyan

$kql = "Resources | where name =~ '$ResourceName'"
if ($ResourceType)  { $kql += " | where type =~ '$ResourceType'" }
if ($ResourceGroup) { $kql += " | where resourceGroup =~ '$ResourceGroup'" }

$graphParams = @{ Query = $kql; First = 100 }
if ($SubscriptionId) { $graphParams['Subscription'] = @($SubscriptionId) }

$resources = Search-AzGraph @graphParams
if ($null -eq $resources -or $resources.Count -eq 0) {
    $filter = @()
    if ($ResourceType)  { $filter += "type: $ResourceType" }
    if ($ResourceGroup) { $filter += "resource group: $ResourceGroup" }
    $filterStr = if ($filter.Count -gt 0) { " ($($filter -join ', '))" } else { '' }
    throw "No resource found with name '$ResourceName'$filterStr."
}
if ($resources.Count -gt 1) {
    Write-Host "WARNING: Multiple resources found with name '$ResourceName'. Showing assignments for all of them." -ForegroundColor Yellow
    $resources | ForEach-Object { Write-Host "  - $($_.id)" -ForegroundColor Yellow }
}

# --- Resolve principal ---
$principalDisplayName = if ($Upn) { $Upn } else { $ObjectId }

if ($Upn -and -not $ObjectId) {
    Write-Host "Resolving principal '$Upn'..." -ForegroundColor Cyan
    $adUser = Get-AzADUser -UserPrincipalName $Upn -ErrorAction SilentlyContinue
    if ($null -ne $adUser) {
        $ObjectId             = $adUser.Id
        $principalDisplayName = "$($adUser.DisplayName) ($Upn)"
    } else {
        Write-Host 'Note: Could not resolve UPN via Microsoft Graph. Passing UPN directly to Get-AzRoleAssignment.' -ForegroundColor Gray
    }
}

# --- Query and display role assignments ---
Write-Host ''
Write-Host "Role assignments for: $principalDisplayName" -ForegroundColor White
Write-Host ('-' * 70) -ForegroundColor DarkGray

$totalAssignments = 0

foreach ($resource in $resources) {
    $rid = $resource.id
    $rn  = $resource.name
    $rt  = $resource.type

    Write-Host ''
    Write-Host "Resource : $rn" -ForegroundColor Cyan
    Write-Host "  Type   : $rt" -ForegroundColor DarkGray
    Write-Host "  Scope  : $rid" -ForegroundColor DarkGray
    Write-Host ''

    # Get-AzRoleAssignment with -Scope returns direct and inherited assignments.
    $raParams = @{ Scope = $rid }
    if ($ObjectId) { $raParams['ObjectId']     = $ObjectId }
    else           { $raParams['SignInName']   = $Upn }

    $assignments = Get-AzRoleAssignment @raParams

    if ($null -eq $assignments -or $assignments.Count -eq 0) {
        Write-Host '  (no role assignments found)' -ForegroundColor Gray
    } else {
        $totalAssignments += $assignments.Count
        foreach ($a in $assignments) {
            $inherited = $a.Scope -ne $rid
            $marker    = if ($inherited) { '[inherited]' } else { '[direct]   ' }
            $color     = if ($inherited) { 'Gray'        } else { 'Green'       }
            Write-Host "  $marker $($a.RoleDefinitionName)" -ForegroundColor $color
            Write-Host "             Scope: $($a.Scope)"    -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
Write-Host ('-' * 70) -ForegroundColor DarkGray
Write-Host "Total assignments found: $totalAssignments" -ForegroundColor White
