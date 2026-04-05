# Azure

Scripts related to Azure infrastructure operations, governance,
RBAC, Policy, Arc and Update Manager.

---

## Scripts

### `web-platform/Set-AzureFunctionAppHostKey.ps1` – Set a Function App host key

Creates or updates a named host key on an Azure Function App using the Azure CLI.  
If no key value is provided, Azure auto-generates one.

The script uses the **current Azure CLI subscription context** set by `Connect-AzToolkit.ps1`.  
A `subscriptionId` in the config file is optional and only needed to override the current context.

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Set-AzureFunctionAppHostKey.<Name>.json` from the script directory. |
| `-ConfigDir` | Override the directory to search for the config file. Defaults to the script directory. |
| `-SubscriptionId` | Optional. Overrides the current Azure CLI context subscription. |
| `-ResourceGroupName` | Resource group containing the Function App. Overrides `functionApp.resourceGroupName` from config. |
| `-FunctionAppName` | Name of the Function App. Overrides `functionApp.name` from config. |
| `-HostKeyName` | Name of the host key to create or update. Overrides `hostKey.name` from config. |
| `-HostKeyValue` | Optional key value. If omitted, Azure auto-generates the key. Overrides `hostKey.value` from config. |

#### Config file

Copy `Set-AzureFunctionAppHostKey.template.json` from the same directory, rename it to  
`Set-AzureFunctionAppHostKey.<Name>.json` and fill in your values.  
Config files matching `**/*.json` are excluded from source control via `.gitignore`.

```json
{
  "context": {
    "subscriptionId": ""
  },
  "functionApp": {
    "resourceGroupName": "<resource-group-name>",
    "name": "<function-app-name>"
  },
  "hostKey": {
    "name": "<key-name>",
    "value": ""
  }
}
```

`context.subscriptionId` is optional. Leave it empty to use the subscription set by `Connect-AzToolkit.ps1`.

#### Examples

```powershell
# Recommended workflow: authenticate first, then run the script
.\shared\Connect-AzToolkit.ps1 -ConfigName mytenant
.\azure\web-platform\Set-AzureFunctionAppHostKey.ps1 -ConfigName meetupplanner

# Pass parameters directly (overrides current context)
.\azure\web-platform\Set-AzureFunctionAppHostKey.ps1 `
    -SubscriptionId '<guid>' `
    -ResourceGroupName 'my-rg' `
    -FunctionAppName 'my-func' `
    -HostKeyName 'server'
```

---

### `iam/Get-AzRoleAssignmentsForPrincipalOnResource.ps1` – List role assignments for a principal on a resource

Looks up all Azure role assignments for a user or service principal on a specific resource.
The resource is resolved by name using **Azure Resource Graph** (`Search-AzGraph`), with optional
filters for resource type and resource group to disambiguate when multiple resources share the same name.

Both direct and inherited assignments are shown. Inherited assignments are reported with their actual scope.

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Get-AzRoleAssignmentsForPrincipalOnResource.<Name>.json` from the script directory. |
| `-ConfigDir` | Override the directory to search for the config file. Defaults to the script directory. |
| `-SubscriptionId` | Optional. Scopes the Resource Graph query to a specific subscription. |
| `-ResourceName` | Name of the Azure resource to check. **Required.** |
| `-ResourceType` | Optional. Narrows the lookup when multiple resources share the same name (e.g. `microsoft.storage/storageaccounts`). |
| `-ResourceGroup` | Optional. Narrows the lookup to a specific resource group. |
| `-Upn` | UPN of the user (e.g. `user@contoso.com`). Either `-Upn` or `-ObjectId` is required. |
| `-ObjectId` | Object ID of the principal. Takes precedence over `-Upn` for the role assignment query. |

#### Config file

Copy `Get-AzRoleAssignmentsForPrincipalOnResource.template.json` from the same directory, rename it to
`Get-AzRoleAssignmentsForPrincipalOnResource.<Name>.json` and fill in your values.
Config files matching `**/*.json` are excluded from source control via `.gitignore`.

```json
{
  "context": {
    "subscriptionId": "<optional-subscription-guid>"
  },
  "lookup": {
    "resourceName": "<resource-name>",
    "resourceType": "<optional-resource-type>",
    "resourceGroup": "<optional-rg-name>"
  },
  "principal": {
    "upn": "<user-upn-or-empty>",
    "objectId": "<optional-object-id>"
  }
}
```

#### Prerequisites

Requires the `Az.ResourceGraph` module (part of the `Az` suite):

```powershell
.\shared\Install-Prerequisites.ps1
```

#### Required permissions (minimum)

| Permission | Purpose |
|---|---|
| `Microsoft.ResourceGraph/resources/read` | Resource lookup via `Search-AzGraph` |
| `Microsoft.Authorization/roleAssignments/read` | Listing role assignments via `Get-AzRoleAssignment` |

Minimum built-in role: **Reader** scoped to the target resource or its resource group.

#### Examples

```powershell
# Using a config file
.\azure\iam\Get-AzRoleAssignmentsForPrincipalOnResource.ps1 -ConfigName prod

# Pass parameters directly
.\azure\iam\Get-AzRoleAssignmentsForPrincipalOnResource.ps1 `
    -ResourceName 'my-storage' `
    -Upn 'user@contoso.com'

# Narrow by resource type and resource group
.\azure\iam\Get-AzRoleAssignmentsForPrincipalOnResource.ps1 `
    -ResourceName 'my-storage' `
    -ResourceType 'microsoft.storage/storageaccounts' `
    -ResourceGroup 'my-rg' `
    -ObjectId '<principal-object-id>'
```

---

### `iam/Get-UserRoleAssignments.ps1` – List all role assignments for a user

Lists all direct Azure RBAC role assignments for a user across all accessible (enabled) subscriptions.
The user is resolved via Microsoft Entra using UPN, object ID, or a short name ("Kürzel").

When a Kürzel is provided, both the primary and (optionally) the secondary domain are searched,
so accounts in synced on-premises domains are covered as well.
Results can optionally be exported to a CSV file.

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Get-UserRoleAssignments.<Name>.json` from the script directory. |
| `-ConfigDir` | Override the directory to search for the config file. Defaults to the script directory. |
| `-Upn` | UPN of the user (e.g. `user@contoso.com`). |
| `-UserKuerzel` | Short name / Kürzel – resolved against `-PrimaryDomain` and optionally `-SecondaryDomain`. |
| `-ObjectId` | Object ID of the principal. Bypasses the Entra lookup when provided. |
| `-SubscriptionIds` | Optional. Limits the search to specific subscription IDs (array or comma-separated). |
| `-PrimaryDomain` | Primary domain used for Kürzel resolution (e.g. `contoso.com`). Required with `-UserKuerzel`. |
| `-SecondaryDomain` | Optional secondary / on-premises sync domain (e.g. `contoso.onmicrosoft.com`). |
| `-ExportCsv` | Switch. Exports results to a CSV file in the script directory (or `export.outputDir` from config). |

At least one of `-Upn`, `-UserKuerzel`, or `-ObjectId` must be supplied.

#### Config file

Copy `Get-UserRoleAssignments.template.json` from the same directory, rename it to
`Get-UserRoleAssignments.<Name>.json` and fill in your values.
Config files matching `**/*.json` are excluded from source control via `.gitignore`.

```json
{
  "principal": {
    "upn": "<user-upn-or-empty>",
    "userKuerzel": "<optional-kuerzel>",
    "objectId": "<optional-object-id>"
  },
  "search": {
    "subscriptionIds": ["<optional-sub-id-1>", "<optional-sub-id-2>"],
    "primaryDomain": "<primary-domain>",
    "secondaryDomain": "<optional-secondary-domain>"
  },
  "export": {
    "csv": false,
    "outputDir": "<optional-output-directory>"
  }
}
```

#### Prerequisites

Requires the `Az.Resources` module (part of the `Az` suite):

```powershell
.\shared\Install-Prerequisites.ps1
```

#### Required permissions (minimum)

| Permission | Purpose |
|---|---|
| `Microsoft.Authorization/roleAssignments/read` | Listing role assignments via `Get-AzRoleAssignment` |
| `User.Read.All` (Microsoft Entra) | Resolving users by UPN or Kürzel via `Get-AzADUser` |

Minimum built-in role: **Reader** scoped to each subscription that should be queried.

#### Examples

```powershell
# Using a config file
.\azure\iam\Get-UserRoleAssignments.ps1 -ConfigName contoso

# Pass parameters directly
.\azure\iam\Get-UserRoleAssignments.ps1 -Upn 'user@contoso.com'

# Resolve by Kürzel and export to CSV
.\azure\iam\Get-UserRoleAssignments.ps1 `
    -UserKuerzel 'mmm99' `
    -PrimaryDomain 'contoso.com' `
    -SecondaryDomain 'contoso.onmicrosoft.com' `
    -ExportCsv

# Limit to specific subscriptions
.\azure\iam\Get-UserRoleAssignments.ps1 `
    -Upn 'user@contoso.com' `
    -SubscriptionIds '<sub-guid-1>', '<sub-guid-2>'
```

---

### `iam/Assign-KeyVaultCertificatesOfficerToUser.ps1` – Assign Key Vault Certificates Officer to a user

Assigns the built-in Azure RBAC role **Key Vault Certificates Officer** to a user on a specific Key Vault scope.
The script is idempotent: existing assignments are detected and not duplicated.

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Assign-KeyVaultCertificatesOfficerToUser.<Name>.json` from the script directory. |
| `-ConfigDir` | Override the directory to search for the config file. Defaults to the script directory. |
| `-SubscriptionId` | Optional. Sets the Azure subscription context before lookup/assignment. |
| `-KeyVaultName` | Name of the target Key Vault. **Required.** |
| `-ResourceGroup` | Optional. Disambiguates Key Vault lookup when needed. |
| `-Upn` | UPN of the user (e.g. `user@contoso.com`). Either `-Upn` or `-ObjectId` is required. |
| `-ObjectId` | Object ID of the user. Takes precedence over `-Upn`. |

#### Config file

Copy `Assign-KeyVaultCertificatesOfficerToUser.template.json` from the same directory, rename it to
`Assign-KeyVaultCertificatesOfficerToUser.<Name>.json` and fill in your values.
Config files matching `**/*.json` are excluded from source control via `.gitignore`.

```json
{
  "context": {
    "subscriptionId": ""
  },
  "target": {
    "keyVaultName": "kv-prod-001",
    "resourceGroup": ""
  },
  "principal": {
    "upn": "user@contoso.com",
    "objectId": ""
  }
}
```

#### Required permissions (minimum)

| Permission | Purpose |
|---|---|
| `Microsoft.Authorization/roleAssignments/read` | Check existing assignment |
| `Microsoft.Authorization/roleAssignments/write` | Create assignment |
| `Microsoft.KeyVault/vaults/read` | Resolve target Key Vault |

Minimum built-in role: **User Access Administrator** or **Owner** on the target Key Vault scope.

#### Examples

```powershell
# Using a config file
.\azure\iam\Assign-KeyVaultCertificatesOfficerToUser.ps1 -ConfigName prod

# Pass parameters directly
.\azure\iam\Assign-KeyVaultCertificatesOfficerToUser.ps1 `
    -KeyVaultName 'kv-prod-001' `
    -Upn 'user@contoso.com'

# Explicit subscription and object ID
.\azure\iam\Assign-KeyVaultCertificatesOfficerToUser.ps1 `
    -SubscriptionId '<sub-guid>' `
    -KeyVaultName 'kv-prod-001' `
    -ResourceGroup 'rg-security' `
    -ObjectId '<user-object-id>'
```

---

### `iam/Assign-CosmosDbAccess.ps1` - Assign Cosmos DB SQL data-plane access to a user

Creates a Cosmos DB SQL role assignment for a user on a target Cosmos DB account and scope.

The script is idempotent: existing assignments are detected and not duplicated.

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Assign-CosmosDbAccess.<Name>.json` from the script directory. |
| `-ConfigDir` | Override the directory to search for the config file. Defaults to the script directory. |
| `-SubscriptionId` | Optional. Sets the Azure subscription context before assignment. |
| `-AccountName` | Cosmos DB account name. **Required.** |
| `-ResourceGroupName` | Resource group of the Cosmos DB account. **Required.** |
| `-Scope` | Optional data-plane scope. Defaults to `/` (account-wide). Examples: `/dbs/mydb`, `/dbs/mydb/colls/mycontainer`. |
| `-RoleName` | Optional role name. Default is `Cosmos DB Built-in Data Contributor`. Ignored when `-RoleDefinitionId` is provided. |
| `-RoleDefinitionId` | Optional role definition id (guid or full id). Takes precedence over `-RoleName`. |
| `-Upn` | UPN of the user (e.g. `user@contoso.com`). Either `-Upn` or `-ObjectId` is required. |
| `-ObjectId` | Object ID of the principal. Takes precedence over `-Upn`. |

#### Config file

Copy `Assign-CosmosDbAccess.template.json` from the same directory, rename it to
`Assign-CosmosDbAccess.<Name>.json` and fill in your values.
Config files matching `**/*.json` are excluded from source control via `.gitignore`.

```json
{
  "context": {
    "subscriptionId": ""
  },
  "target": {
    "accountName": "cosmos-brands-advisory",
    "resourceGroupName": "rg-brands-advisory"
  },
  "principal": {
    "upn": "user@contoso.com",
    "objectId": ""
  },
  "access": {
    "scope": "/",
    "roleName": "Cosmos DB Built-in Data Contributor",
    "roleDefinitionId": ""
  }
}
```

#### Required permissions (minimum)

| Permission | Purpose |
|---|---|
| `Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments/read` | Check existing assignments |
| `Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments/write` | Create role assignment |
| `Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions/read` | Resolve role definitions |

Required module: `Az.CosmosDB`

#### Examples

```powershell
# Using a config file
.\azure\iam\Assign-CosmosDbAccess.ps1 -ConfigName prod

# Assign account-wide data contributor access to a user
.\azure\iam\Assign-CosmosDbAccess.ps1 `
    -AccountName 'cosmos-brands-advisory' `
    -ResourceGroupName 'rg-brands-advisory' `
    -Upn 'user@contoso.com'

# Assign read access on a specific database scope
.\azure\iam\Assign-CosmosDbAccess.ps1 `
    -AccountName 'cosmos-brands-advisory' `
    -ResourceGroupName 'rg-brands-advisory' `
    -ObjectId '<principal-object-id>' `
    -RoleName 'Cosmos DB Built-in Data Reader' `
    -Scope '/dbs/appdb'
```

---

### `iam/Assign-KeyVaultRoleToServicePrincipal.ps1` – Assign an Azure RBAC role on a Key Vault to a service principal

Assigns an Azure RBAC role at Key Vault scope to a service principal.
The default role is **Key Vault Secrets User**.
The script is idempotent: existing assignments are detected and not duplicated.

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Assign-KeyVaultRoleToServicePrincipal.<Name>.json` from the script directory. |
| `-ConfigDir` | Override the directory to search for the config file. Defaults to the script directory. |
| `-SubscriptionId` | Optional. Sets the Azure subscription context. Falls back to active Az context. |
| `-KeyVaultName` | Name of the target Key Vault. **Required.** |
| `-ResourceGroup` | Optional. Disambiguates Key Vault lookup when multiple vaults share the same name. |
| `-Role` | RBAC role to assign. Default: `Key Vault Secrets User`. |
| `-DisplayName` | Display name of the service principal (e.g. `sp-myapp-github`). |
| `-AppId` | Application (client) ID of the service principal. |
| `-ObjectId` | Object ID of the service principal. Takes precedence over `-AppId` and `-DisplayName`. |

At least one of `-DisplayName`, `-AppId`, or `-ObjectId` is required.

#### Config file

Copy `Assign-KeyVaultRoleToServicePrincipal.template.json`, rename to
`Assign-KeyVaultRoleToServicePrincipal.<Name>.json` and fill in your values.

```json
{
  "context": {
    "subscriptionId": ""
  },
  "target": {
    "keyVaultName": "kv-prod-001",
    "resourceGroup": ""
  },
  "principal": {
    "displayName": "sp-myapp-github",
    "appId": "",
    "objectId": ""
  },
  "role": "Key Vault Secrets User"
}
```

`context.subscriptionId` is optional when already connected via `Connect-AzToolkit.ps1`.

#### Required permissions (minimum)

| Permission | Purpose |
|---|---|
| `Microsoft.Authorization/roleAssignments/read` | Check existing assignment |
| `Microsoft.Authorization/roleAssignments/write` | Create assignment |
| `Microsoft.KeyVault/vaults/read` | Resolve target Key Vault |

Minimum built-in role: **User Access Administrator** or **Owner** on the target Key Vault scope.

#### Examples

```powershell
# Using a config file (recommended)
.\azure\iam\Assign-KeyVaultRoleToServicePrincipal.ps1 -ConfigName prod

# Resolve by display name
.\azure\iam\Assign-KeyVaultRoleToServicePrincipal.ps1 `
    -KeyVaultName 'kv-prod-001' `
    -DisplayName 'sp-myapp-github'

# Assign a different role
.\azure\iam\Assign-KeyVaultRoleToServicePrincipal.ps1 `
    -KeyVaultName 'kv-prod-001' `
    -AppId '<client-id>' `
    -Role 'Key Vault Secrets Officer'
```

---

### `iam/Assign-ResourceGroupRoleToServicePrincipal.ps1` – Assign an Azure RBAC role on a resource group to a service principal

Assigns an Azure RBAC role on a resource group to a service principal.
The default role is `Contributor`.

The script is idempotent: if the same assignment already exists it is reported and skipped.
The service principal can be identified by ObjectId, AppId, or display name.

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Assign-ResourceGroupRoleToServicePrincipal.<Name>.json` from the script directory. |
| `-ConfigDir` | Override the directory to search for the config file. Defaults to the script directory. |
| `-SubscriptionId` | Optional. Switches the Az PowerShell subscription context. Falls back to current Az context. |
| `-ResourceGroupName` | Name of the resource group. **Required.** |
| `-Role` | RBAC role to assign. Default: `Contributor`. |
| `-DisplayName` | Display name of the service principal. Resolved via `Get-AzADServicePrincipal`. |
| `-AppId` | Application (client) ID of the service principal. |
| `-ObjectId` | Object ID of the service principal. Takes precedence over AppId and DisplayName. |

At least one of `-DisplayName`, `-AppId`, or `-ObjectId` is required.

#### Config file

Copy `Assign-ResourceGroupRoleToServicePrincipal.template.json`, rename to
`Assign-ResourceGroupRoleToServicePrincipal.<Name>.json` and fill in your values.

```json
{
  "context": {
    "subscriptionId": ""
  },
  "target": {
    "resourceGroupName": "rg-myapp"
  },
  "principal": {
    "displayName": "sp-myapp-github",
    "appId": "",
    "objectId": ""
  },
  "role": "Contributor"
}
```

`subscriptionId` is optional when already connected via `Connect-AzToolkit.ps1`.

#### Required permissions

- `User Access Administrator` or `Owner` at resource group scope
- `Microsoft.Authorization/roleAssignments/read`
- `Microsoft.Authorization/roleAssignments/write`
- `Application.Read.All` (when resolving by AppId or DisplayName)

#### Examples

```powershell
# Using a config file (recommended)
.\azure\iam\Assign-ResourceGroupRoleToServicePrincipal.ps1 -ConfigName myapp

# Resolve by display name
.\azure\iam\Assign-ResourceGroupRoleToServicePrincipal.ps1 `
    -ResourceGroupName 'rg-myapp' `
    -DisplayName 'sp-myapp-github'

# Assign a different role
.\azure\iam\Assign-ResourceGroupRoleToServicePrincipal.ps1 `
    -ResourceGroupName 'rg-myapp' `
    -AppId '<client-id>' `
    -Role 'Reader'
```

---

### `iam/List-CosmosDbRBAC.ps1` – List Cosmos DB SQL RBAC assignments with resolved names

Lists Cosmos DB SQL data-plane RBAC assignments using the `Az.CosmosDB` PowerShell module and resolves:

- Role definition IDs to role names
- Principal IDs to readable Entra identities (user, service principal, or group)

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `List-CosmosDbRBAC.<Name>.json` from the script directory. |
| `-ConfigDir` | Override the directory to search for the config file. Defaults to the script directory. |
| `-SubscriptionId` | Optional. Switches the Az PowerShell subscription context before querying assignments. |
| `-AccountName` | Cosmos DB account name. **Required.** |
| `-ResourceGroupName` | Resource group of the Cosmos DB account. **Required.** |
| `-ResolvePrincipalNames` | Optional bool. Defaults to `true`. Set to `$false` to skip Entra name resolution and show only object IDs. |

#### Config file

Copy `List-CosmosDbRBAC.template.json` from the same directory, rename it to
`List-CosmosDbRBAC.<Name>.json` and fill in your values.
Config files matching `**/*.json` are excluded from source control via `.gitignore`.

```json
{
  "context": {
    "subscriptionId": ""
  },
  "target": {
    "accountName": "cosmos-brands-advisory",
    "resourceGroupName": "rg-brands-advisory"
  },
  "view": {
    "resolvePrincipalNames": true
  }
}
```

#### Required permissions (minimum)

| Permission | Purpose |
|---|---|
| `Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments/read` | List Cosmos DB SQL role assignments |
| `Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions/read` | Resolve role definition names |
| `User.Read.All` (Entra, optional) | Resolve principal IDs to readable names |

#### Examples

```powershell
# Using a config file
.\azure\iam\List-CosmosDbRBAC.ps1 -ConfigName prod

# With readable role and principal names
.\azure\iam\List-CosmosDbRBAC.ps1 `
    -AccountName 'cosmos-brands-advisory' `
    -ResourceGroupName 'rg-brands-advisory'

# Skip principal name resolution
.\azure\iam\List-CosmosDbRBAC.ps1 `
    -AccountName 'cosmos-brands-advisory' `
    -ResourceGroupName 'rg-brands-advisory' `
    -ResolvePrincipalNames $false
```