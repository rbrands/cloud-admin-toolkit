# azure/billing

Scripts for Azure billing and cost management.

Uses the **Az.Billing** PowerShell module (`Get-AzBillingAccount`, `Get-AzConsumptionUsageDetail`, etc.).

---

## Prerequisites

Run `shared/Install-Prerequisites.ps1` to install the required modules, including `Az.Billing`.

Authentication is handled via `shared/Connect-AzToolkit.ps1`.

---

## Scripts

### `Get-BillingAccounts.ps1` – List all Billing Accounts

Retrieves all Azure Billing Accounts accessible to the current user and displays
account name, display name, agreement type, and account status.

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Get-BillingAccounts.<Name>.json` from the script directory. |
| `-ConfigDir` | Override the directory to search for the config file. Defaults to the script directory. |
| `-DisplayNameFilter` | Optional. Only show accounts whose display name contains this string. |

#### Config file

Copy `Get-BillingAccounts.template.json`, rename it to `Get-BillingAccounts.<Name>.json`
and fill in your values. Config files matching `**/*.json` are excluded from source control.

```json
{
  "filter": {
    "displayNameFilter": ""
  }
}
```

#### Required permissions

- `Microsoft.Billing/billingAccounts/read` on the target Billing Account(s)

#### Usage

```powershell
# List all billing accounts
.\Get-BillingAccounts.ps1

# Filter by display name
.\Get-BillingAccounts.ps1 -DisplayNameFilter "Contoso"

# Using a config file
.\Get-BillingAccounts.ps1 -ConfigName prod
```
