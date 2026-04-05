<#
.SYNOPSIS
    Assigns an Azure RBAC role on a Key Vault to a service principal.

.DESCRIPTION
    Resolves the target Key Vault and service principal, then creates an Azure RBAC
    role assignment at Key Vault scope. The default role is "Key Vault Secrets User".

    The script is idempotent: if the same assignment already exists, no changes are made.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Assign-KeyVaultRoleToServicePrincipal.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

.EXAMPLE
    .\Assign-KeyVaultRoleToServicePrincipal.ps1 -ConfigName prod

.EXAMPLE
    .\Assign-KeyVaultRoleToServicePrincipal.ps1 -KeyVaultName 'kv-prod-001' -AppId '<client-id>'

.EXAMPLE
    .\Assign-KeyVaultRoleToServicePrincipal.ps1 -KeyVaultName 'kv-prod-001' -ObjectId '<sp-object-id>' -Role 'Key Vault Secrets Officer'

.NOTES
    Required Azure role (minimum):
      User Access Administrator or Owner on the target Key Vault scope.

    Required Azure permissions:
      Microsoft.Authorization/roleAssignments/read
      Microsoft.Authorization/roleAssignments/write
      Microsoft.KeyVault/vaults/read

    Required Microsoft Entra permission (when resolving by AppId):
      Application.Read.All (Get-AzADServicePrincipal)

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

    # RBAC role to assign. Default: 'Key Vault Secrets User'.
    [Parameter(Mandatory = $false)]
    [string]$Role = 'Key Vault Secrets User',

    # Display name of the service principal (e.g. 'sp-myapp-github'). Resolved via Get-AzADServicePrincipal.
    [Parameter(Mandatory = $false)]
    [string]$DisplayName,

    # Application (client) ID of the service principal.
    [Parameter(Mandatory = $false)]
    [string]$AppId,

    # Object ID of the service principal. Takes precedence over AppId and DisplayName.
    [Parameter(Mandatory = $false)]
    [string]$ObjectId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\AzToolkit.Config.psm1') -Force

# ── Config loading ─────────────────────────────────────────────────────────────

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Assign-KeyVaultRoleToServicePrincipal'

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
        if (-not $DisplayName) { $DisplayName = $principalCfg.PSObject.Properties['displayName']?.Value }
        if (-not $AppId)       { $AppId       = $principalCfg.PSObject.Properties['appId']?.Value }
        if (-not $ObjectId)    { $ObjectId    = $principalCfg.PSObject.Properties['objectId']?.Value }
    }

    if (-not $PSBoundParameters.ContainsKey('Role') -and $null -ne $config -and
        $config.PSObject.Properties['role']) {
        $Role = [string]$config.role
    }
}

# Fall back to the current Az context subscription if not explicitly configured.
if (-not $SubscriptionId) {
    $azCtx = Get-AzContext -ErrorAction SilentlyContinue
    if ($azCtx -and $azCtx.Subscription.Id) {
        $SubscriptionId = $azCtx.Subscription.Id
        Write-Host "SubscriptionId not configured – using current Az context: $SubscriptionId" -ForegroundColor Yellow
    }
}

# ── Validation ─────────────────────────────────────────────────────────────────

if (-not $KeyVaultName) {
    Write-Host 'KeyVaultName is required.' -ForegroundColor Red
    exit 1
}

if (-not $DisplayName -and -not $AppId -and -not $ObjectId) {
    Write-Host 'Either DisplayName, AppId, or ObjectId is required.' -ForegroundColor Red
    exit 1
}

# ── Header ─────────────────────────────────────────────────────────────────────

Write-Host '=== Assign-KeyVaultRoleToServicePrincipal ===' -ForegroundColor Cyan
if ($resolvedConfigPath) {
    Write-Host "Config       : $resolvedConfigPath" -ForegroundColor Gray
}
Write-Host "Key Vault    : $KeyVaultName" -ForegroundColor Gray
Write-Host "Role         : $Role" -ForegroundColor Gray
if ($ObjectId) {
    Write-Host "Principal    : $ObjectId (ObjectId)" -ForegroundColor Gray
} elseif ($AppId) {
    Write-Host "Principal    : $AppId (AppId)" -ForegroundColor Gray
} else {
    Write-Host "Principal    : $DisplayName (DisplayName)" -ForegroundColor Gray
}
Write-Host ''

# ── Set subscription context ───────────────────────────────────────────────────

if ($SubscriptionId) {
    Write-Host "Setting subscription context: $SubscriptionId" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
}

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

# ── Resolve service principal ──────────────────────────────────────────────────

$assigneeObjectId = $ObjectId
$assigneeDisplay  = $null

if (-not $assigneeObjectId -and $AppId) {
    Write-Host "Resolving service principal for AppId '$AppId'..." -ForegroundColor Yellow
    try {
        $sp = Get-AzADServicePrincipal -ApplicationId $AppId -ErrorAction Stop
    }
    catch {
        Write-Host "Failed to resolve service principal by AppId: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    if (-not $sp) {
        Write-Host "Service principal not found for AppId: $AppId" -ForegroundColor Red
        exit 1
    }

    $assigneeObjectId = $sp.Id
    $assigneeDisplay  = "$($sp.DisplayName) (AppId: $AppId)"
}
elseif (-not $assigneeObjectId -and $DisplayName) {
    Write-Host "Resolving service principal by display name '$DisplayName'..." -ForegroundColor Yellow
    try {
        $spList = @(Get-AzADServicePrincipal -DisplayName $DisplayName -ErrorAction Stop)
    }
    catch {
        Write-Host "Failed to resolve service principal by display name: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    if ($spList.Count -eq 0) {
        Write-Host "Service principal not found: '$DisplayName'" -ForegroundColor Red
        exit 1
    }
    if ($spList.Count -gt 1) {
        Write-Host "Multiple service principals found for '$DisplayName'. Use -AppId or -ObjectId to disambiguate." -ForegroundColor Red
        foreach ($s in $spList) {
            Write-Host "  - $($s.DisplayName)  AppId: $($s.AppId)  ObjectId: $($s.Id)" -ForegroundColor Yellow
        }
        exit 1
    }

    $assigneeObjectId = $spList[0].Id
    $assigneeDisplay  = "$($spList[0].DisplayName) (ObjectId: $assigneeObjectId)"
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
    -RoleDefinitionName $Role `
    -ErrorAction        SilentlyContinue |
    Where-Object { $_.Scope -eq $scope }

if ($existingAssignment) {
    Write-Host 'Role assignment already exists. No change required.' -ForegroundColor Green
}
else {
    if ($PSCmdlet.ShouldProcess($scope, "Assign '$Role' to '$assigneeDisplay'")) {
        try {
            $null = New-AzRoleAssignment `
                -ObjectId           $assigneeObjectId `
                -Scope              $scope `
                -RoleDefinitionName $Role `
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
    Role              = $Role
    Principal         = $assigneeDisplay
    PrincipalObjectId = $assigneeObjectId
    AssignmentState   = if ($existingAssignment) { 'AlreadyAssigned' } else { 'Assigned' }
}

Write-Host ''
Write-Host 'Result:' -ForegroundColor Cyan
$result | Format-List

Write-Host ''
Write-Host 'Script completed successfully.' -ForegroundColor Green
