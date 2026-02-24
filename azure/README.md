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