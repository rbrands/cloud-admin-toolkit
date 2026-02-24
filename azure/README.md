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