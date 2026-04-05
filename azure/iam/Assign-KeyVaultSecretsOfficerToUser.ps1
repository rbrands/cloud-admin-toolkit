<#
.SYNOPSIS
    Assigns the "Key Vault Secrets Officer" role to a user on a specific Key Vault.

.DESCRIPTION
    Resolves a target Key Vault and user, then creates an Azure RBAC role assignment
    for the built-in role "Key Vault Secrets Officer" at Key Vault scope.

    The script is idempotent: if the same assignment already exists at Key Vault scope,
    no changes are made.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Assign-KeyVaultSecretsOfficerToUser.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

.EXAMPLE
    .\Assign-KeyVaultSecretsOfficerToUser.ps1 -ConfigName prod

.EXAMPLE
    .\Assign-KeyVaultSecretsOfficerToUser.ps1 -KeyVaultName 'kv-prod-001' -Upn 'user@contoso.com'

.NOTES
    Required Azure role (minimum):
      User Access Administrator or Owner on the target Key Vault scope.

    Required Azure permissions:
      Microsoft.Authorization/roleAssignments/read
      Microsoft.Authorization/roleAssignments/write
      Microsoft.KeyVault/vaults/read

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

    # Target Key Vault name.
    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName,

    # Optional resource group to disambiguate Key Vault lookup.
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    # User principal name (e.g. user@contoso.com). Either Upn or ObjectId is required.
    [Parameter(Mandatory = $false)]
    [string]$Upn,

    # Object ID of the assignee. Takes precedence over Upn.
    [Parameter(Mandatory = $false)]
    [string]$ObjectId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\AzToolkit.Config.psm1') -Force

$roleName = 'Key Vault Secrets Officer'

# ── Config loading ─────────────────────────────────────────────────────────────

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Assign-KeyVaultSecretsOfficerToUser'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

if ($null -ne $config) {
    $ctxCfg       = $config.PSObject.Properties['context']?.Value
    $targetCfg    = $config.PSObject.Properties['target']?.Value
    $principalCfg = $config.PSObject.Properties['principal']?.Value

    if (-not $SubscriptionId -and $null -ne $ctxCfg) {
        $SubscriptionId = $ctxCfg.PSObject.Properties['subscriptionId']?.Value
    }

    if ($null -ne $targetCfg) {
        if (-not $KeyVaultName) { $KeyVaultName = $targetCfg.PSObject.Properties['keyVaultName']?.Value }
        if (-not $ResourceGroup) { $ResourceGroup = $targetCfg.PSObject.Properties['resourceGroup']?.Value }
    }

    if ($null -ne $principalCfg) {
        if (-not $Upn)      { $Upn      = $principalCfg.PSObject.Properties['upn']?.Value }
        if (-not $ObjectId) { $ObjectId = $principalCfg.PSObject.Properties['objectId']?.Value }
    }
}

# ── Validation ─────────────────────────────────────────────────────────────────

if (-not $KeyVaultName) {
    Write-Host 'KeyVaultName is required.' -ForegroundColor Red
    exit 1
}

if (-not $Upn -and -not $ObjectId) {
    Write-Host 'Either Upn or ObjectId is required.' -ForegroundColor Red
    exit 1
}

# ── Context ────────────────────────────────────────────────────────────────────

try {
    $currentContext = Get-AzContext -ErrorAction Stop
    if (-not $currentContext) { throw 'No active context.' }
}
catch {
    Write-Host 'No active Azure context found. Run Connect-AzToolkit.ps1 or Connect-AzAccount first.' -ForegroundColor Red
    exit 1
}

if ($SubscriptionId) {
    Write-Host "Setting subscription context: $SubscriptionId" -ForegroundColor Cyan
    try {
        $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }
    catch {
        Write-Host "Failed to set subscription context: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# ── Header ─────────────────────────────────────────────────────────────────────

Write-Host '=== Assign-KeyVaultSecretsOfficerToUser ===' -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Config         : $resolvedConfigPath" -ForegroundColor Gray
}
Write-Host "Key Vault      : $KeyVaultName" -ForegroundColor Gray
if ($ResourceGroup) {
    Write-Host "Resource Group : $ResourceGroup" -ForegroundColor Gray
}
Write-Host "Role           : $roleName" -ForegroundColor Gray
Write-Host "Principal      : $(if ($ObjectId) { $ObjectId } else { $Upn })" -ForegroundColor Gray
Write-Host ''

# ── Resolve Key Vault ──────────────────────────────────────────────────────────

Write-Host "Resolving Key Vault '$KeyVaultName'..." -ForegroundColor Yellow

$kvLookupParams = @{
    ResourceType = 'Microsoft.KeyVault/vaults'
    Name         = $KeyVaultName
    ErrorAction  = 'Stop'
}
if ($ResourceGroup) {
    $kvLookupParams.ResourceGroupName = $ResourceGroup
}

$vaults = @(Get-AzResource @kvLookupParams)

if ($vaults.Count -eq 0) {
    Write-Host "Key Vault '$KeyVaultName' not found." -ForegroundColor Red
    exit 1
}

if ($vaults.Count -gt 1) {
    Write-Host "Multiple Key Vaults named '$KeyVaultName' were found. Specify -ResourceGroup to disambiguate." -ForegroundColor Red
    foreach ($v in $vaults) {
        Write-Host "  - $($v.ResourceId)" -ForegroundColor Yellow
    }
    exit 1
}

$vault = $vaults[0]
$scope = $vault.ResourceId

Write-Host "Resolved Key Vault scope: $scope" -ForegroundColor Green

# ── Resolve assignee ───────────────────────────────────────────────────────────

$assigneeObjectId = $ObjectId
$assigneeDisplay  = $null

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
    $assigneeDisplay  = "$($user.DisplayName) ($($user.UserPrincipalName))"
}
else {
    $assigneeDisplay = $assigneeObjectId
}

Write-Host "Resolved principal: $assigneeDisplay" -ForegroundColor Green

# ── Check existing assignment (idempotent) ─────────────────────────────────────

Write-Host 'Checking existing role assignment...' -ForegroundColor Yellow

$existingAssignment = Get-AzRoleAssignment `
    -ObjectId           $assigneeObjectId `
    -Scope              $scope `
    -RoleDefinitionName $roleName `
    -ErrorAction        SilentlyContinue |
    Where-Object { $_.Scope -eq $scope }

if ($existingAssignment) {
    Write-Host 'Role assignment already exists. No change required.' -ForegroundColor Green
}
else {
    if ($PSCmdlet.ShouldProcess($scope, "Assign '$roleName' to '$assigneeDisplay'")) {
        try {
            $null = New-AzRoleAssignment `
                -ObjectId           $assigneeObjectId `
                -Scope              $scope `
                -RoleDefinitionName $roleName `
                -ErrorAction        Stop

            Write-Host 'Role assignment created successfully.' -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to create role assignment: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    }
}

# ── Result ─────────────────────────────────────────────────────────────────────

$result = [PSCustomObject]@{
    KeyVaultName      = $vault.Name
    KeyVaultScope     = $scope
    Role              = $roleName
    Principal         = $assigneeDisplay
    PrincipalObjectId = $assigneeObjectId
    AssignmentState   = if ($existingAssignment) { 'AlreadyAssigned' } else { 'Assigned' }
}

Write-Host ''
Write-Host 'Result:' -ForegroundColor Cyan
$result | Format-List

Write-Host ''
Write-Host 'Script completed successfully.' -ForegroundColor Green
