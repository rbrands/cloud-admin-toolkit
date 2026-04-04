<#
.SYNOPSIS
    Assigns Cosmos DB SQL data-plane access to a user.

.DESCRIPTION
    Creates a Cosmos DB SQL role assignment for a user (Microsoft Entra identity)
    on a target Cosmos DB account and scope.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Assign-CosmosDbAccess.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    The script is idempotent: if the same principal/role/scope assignment already
    exists, no duplicate assignment is created.

.EXAMPLE
    .\Assign-CosmosDbAccess.ps1 -ConfigName prod

.EXAMPLE
    .\Assign-CosmosDbAccess.ps1 -AccountName 'cosmos-prod-001' -ResourceGroupName 'rg-data' -Upn 'user@contoso.com'

.NOTES
    Required PowerShell module: Az.CosmosDB

    Required Azure permissions (minimum):
      Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments/read
      Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments/write
      Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions/read

    Required Microsoft Entra permission (when resolving by UPN):
      User.Read.All (Get-AzADUser)

    Authentication must be explicit. Run Connect-AzToolkit.ps1 or Connect-AzAccount
    before executing this script.
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

    # Optional subscription context override.
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    # Cosmos DB account name.
    [Parameter(Mandatory = $false)]
    [string]$AccountName,

    # Resource group of the Cosmos DB account.
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    # Data-plane scope. Use '/' for account-wide access.
    [Parameter(Mandatory = $false)]
    [string]$Scope,

    # Preferred role name. Ignored when RoleDefinitionId is supplied.
    [Parameter(Mandatory = $false)]
    [string]$RoleName,

    # Role definition id (guid or full resource id). Takes precedence over RoleName.
    [Parameter(Mandatory = $false)]
    [string]$RoleDefinitionId,

    # User principal name (e.g. user@contoso.com). Either Upn or ObjectId is required.
    [Parameter(Mandatory = $false)]
    [string]$Upn,

    # Object ID of the principal. Takes precedence over Upn.
    [Parameter(Mandatory = $false)]
    [string]$ObjectId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\AzToolkit.Config.psm1') -Force

function Get-NormalizedId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    return $Id.Trim().ToLowerInvariant().TrimEnd('/')
}

# ── Config loading ─────────────────────────────────────────────────────────────

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Assign-CosmosDbAccess'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

if ($null -ne $config) {
    $ctxCfg       = $config.PSObject.Properties['context']?.Value
    $targetCfg    = $config.PSObject.Properties['target']?.Value
    $principalCfg = $config.PSObject.Properties['principal']?.Value
    $accessCfg    = $config.PSObject.Properties['access']?.Value

    if (-not $SubscriptionId -and $null -ne $ctxCfg) {
        $SubscriptionId = $ctxCfg.PSObject.Properties['subscriptionId']?.Value
    }

    if ($null -ne $targetCfg) {
        if (-not $AccountName) { $AccountName = $targetCfg.PSObject.Properties['accountName']?.Value }
        if (-not $ResourceGroupName) { $ResourceGroupName = $targetCfg.PSObject.Properties['resourceGroupName']?.Value }
    }

    if ($null -ne $principalCfg) {
        if (-not $Upn) { $Upn = $principalCfg.PSObject.Properties['upn']?.Value }
        if (-not $ObjectId) { $ObjectId = $principalCfg.PSObject.Properties['objectId']?.Value }
    }

    if ($null -ne $accessCfg) {
        if (-not $Scope) { $Scope = $accessCfg.PSObject.Properties['scope']?.Value }
        if (-not $RoleName) { $RoleName = $accessCfg.PSObject.Properties['roleName']?.Value }
        if (-not $RoleDefinitionId) { $RoleDefinitionId = $accessCfg.PSObject.Properties['roleDefinitionId']?.Value }
    }
}

if (-not $Scope) {
    $Scope = '/'
}

if (-not $RoleName -and -not $RoleDefinitionId) {
    $RoleName = 'Cosmos DB Built-in Data Contributor'
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

if (-not $Upn -and -not $ObjectId) {
    Write-Host 'Either Upn or ObjectId is required.' -ForegroundColor Red
    exit 1
}

if (-not $Scope.StartsWith('/')) {
    Write-Host "Scope must start with '/'. Example: '/', '/dbs/mydb', '/dbs/mydb/colls/mycontainer'." -ForegroundColor Red
    exit 1
}

# ── Context and prerequisites ──────────────────────────────────────────────────

Write-Host '=== Assign-CosmosDbAccess ===' -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Config         : $resolvedConfigPath" -ForegroundColor Gray
}
Write-Host "Account        : $AccountName" -ForegroundColor Gray
Write-Host "Resource Group : $ResourceGroupName" -ForegroundColor Gray
Write-Host "Scope          : $Scope" -ForegroundColor Gray
Write-Host "Role           : $(if ($RoleDefinitionId) { $RoleDefinitionId } else { $RoleName })" -ForegroundColor Gray
Write-Host "Principal      : $(if ($ObjectId) { $ObjectId } else { $Upn })" -ForegroundColor Gray
Write-Host ''

if (-not (Get-Module -ListAvailable -Name Az.CosmosDB)) {
    Write-Host 'Missing module Az.CosmosDB. Install it first: Install-Module Az.CosmosDB -Scope CurrentUser' -ForegroundColor Red
    exit 1
}

try {
    $currentContext = Get-AzContext -ErrorAction Stop
    if (-not $currentContext) { throw 'No context' }
}
catch {
    Write-Host 'No active Azure context found. Run Connect-AzToolkit.ps1 or Connect-AzAccount first.' -ForegroundColor Red
    exit 1
}

if ($SubscriptionId -and $currentContext.Subscription.Id -ne $SubscriptionId) {
    Write-Host "Setting subscription context: $SubscriptionId" -ForegroundColor Cyan
    try {
        $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }
    catch {
        Write-Host "Failed to set subscription context: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# ── Resolve principal ──────────────────────────────────────────────────────────

$assigneeObjectId = $ObjectId
$assigneeDisplay = $ObjectId

if (-not $assigneeObjectId) {
    Write-Host "Resolving user '$Upn'..." -ForegroundColor Yellow
    try {
        $user = Get-AzADUser -UserPrincipalName $Upn -ErrorAction Stop
    }
    catch {
        Write-Host "Failed to resolve user by UPN: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    if (-not $user) {
        Write-Host "User not found: $Upn" -ForegroundColor Red
        exit 1
    }

    $assigneeObjectId = $user.Id
    $assigneeDisplay = "$($user.DisplayName) [$($user.UserPrincipalName)]"
}

Write-Host "Resolved principal: $assigneeDisplay" -ForegroundColor Green

# ── Resolve role definition ────────────────────────────────────────────────────

Write-Host 'Loading Cosmos DB SQL role definitions...' -ForegroundColor Yellow
try {
    $roleDefinitions = @(Get-AzCosmosDBSqlRoleDefinition `
        -AccountName       $AccountName `
        -ResourceGroupName $ResourceGroupName `
        -ErrorAction       Stop)
}
catch {
    Write-Host "Failed to load role definitions: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$resolvedRoleDefinitionId = $null
$resolvedRoleName = $null

if ($RoleDefinitionId) {
    $targetRoleId = Get-NormalizedId -Id $RoleDefinitionId
    $matchingRole = $roleDefinitions | Where-Object { (Get-NormalizedId -Id $_.Id) -eq $targetRoleId } | Select-Object -First 1

    if (-not $matchingRole) {
        # Support short GUID input by matching on last path segment.
        $matchingRole = $roleDefinitions | Where-Object {
            $roleGuid = ($_.Id -split '/')[-1]
            $roleGuid -and $roleGuid.ToLowerInvariant() -eq $targetRoleId
        } | Select-Object -First 1
    }

    if (-not $matchingRole) {
        Write-Host "RoleDefinitionId not found on account: $RoleDefinitionId" -ForegroundColor Red
        exit 1
    }

    $resolvedRoleDefinitionId = $matchingRole.Id
    $resolvedRoleName = $matchingRole.RoleName
}
else {
    $matchingRole = $roleDefinitions | Where-Object { $_.RoleName -eq $RoleName } | Select-Object -First 1
    if (-not $matchingRole) {
        Write-Host "RoleName not found on account: $RoleName" -ForegroundColor Red
        Write-Host 'Available role names:' -ForegroundColor Yellow
        $roleDefinitions | Sort-Object RoleName | ForEach-Object { Write-Host "  - $($_.RoleName)" -ForegroundColor Yellow }
        exit 1
    }

    $resolvedRoleDefinitionId = $matchingRole.Id
    $resolvedRoleName = $matchingRole.RoleName
}

Write-Host "Resolved role: $resolvedRoleName" -ForegroundColor Green

# ── Check existing assignments (idempotent) ────────────────────────────────────

Write-Host 'Loading existing Cosmos DB SQL role assignments...' -ForegroundColor Yellow
try {
    $existingAssignments = @(Get-AzCosmosDBSqlRoleAssignment `
        -AccountName       $AccountName `
        -ResourceGroupName $ResourceGroupName `
        -ErrorAction       Stop)
}
catch {
    Write-Host "Failed to load role assignments: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$existingAssignment = $existingAssignments | Where-Object {
    $_.PrincipalId -eq $assigneeObjectId -and
    (Get-NormalizedId -Id $_.RoleDefinitionId) -eq (Get-NormalizedId -Id $resolvedRoleDefinitionId) -and
    $_.Scope -eq $Scope
} | Select-Object -First 1

if ($existingAssignment) {
    Write-Host 'Matching role assignment already exists. No change required.' -ForegroundColor Green
    $assignmentState = 'AlreadyAssigned'
    $assignmentId = $existingAssignment.Id
}
else {
    $assignmentId = [Guid]::NewGuid().Guid

    if ($PSCmdlet.ShouldProcess($AccountName, "Assign '$resolvedRoleName' on '$Scope' to '$assigneeDisplay'")) {
        try {
            $created = New-AzCosmosDBSqlRoleAssignment `
                -ResourceGroupName $ResourceGroupName `
                -AccountName $AccountName `
                -RoleDefinitionId $resolvedRoleDefinitionId `
                -Scope $Scope `
                -PrincipalId $assigneeObjectId `
                -Id $assignmentId `
                -ErrorAction Stop

            $assignmentId = $created.Id
            Write-Host 'Role assignment created successfully.' -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to create role assignment: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    }

    $assignmentState = 'Assigned'
}

$result = [PSCustomObject]@{
    AccountName       = $AccountName
    ResourceGroupName = $ResourceGroupName
    Scope             = $Scope
    RoleName          = $resolvedRoleName
    RoleDefinitionId  = $resolvedRoleDefinitionId
    Principal         = $assigneeDisplay
    PrincipalObjectId = $assigneeObjectId
    AssignmentId      = $assignmentId
    AssignmentState   = $assignmentState
}

Write-Host ''
Write-Host 'Result:' -ForegroundColor Cyan
$result | Format-List
