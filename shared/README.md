# Shared

Reusable helper scripts, authentication utilities, and environment bootstrap components.

---

## Scripts and Modules

### `AzToolkit.Config.psm1` – Config helper module

A shared PowerShell module that provides config-file loading and Azure context management.  
Import it at the top of any script:

```powershell
Import-Module (Join-Path $PSScriptRoot '..\shared\AzToolkit.Config.psm1') -Force
```

#### Exported functions

| Function | Description |
|---|---|
| `Resolve-ToolkitConfigPath` | Resolves the path to a JSON config file from an explicit path or by convention (`<Prefix>.<Name>.json` in the script's directory). |
| `Read-ToolkitJsonConfig` | Reads and parses a UTF-8 JSON config file. Returns `$null` when no path is provided. |
| `Set-ToolkitAzContext` | Sets the Azure subscription context from a config object or an explicit subscription ID. |

#### Config file convention

Each script can have a companion JSON config file named `<ScriptBaseName>.<Name>.json`  
(e.g. `Get-ResourceReport.prod.json`). Use `config.template.json` as a starting point:

```json
{
  "context": {
    "subscriptionId": "<subscription-guid>"
  }
}
```

The `context` section is optional. Scripts work correctly when it is absent.

#### Typical usage pattern

```powershell
Import-Module (Join-Path $PSScriptRoot '..\shared\AzToolkit.Config.psm1') -Force

$config = Read-ToolkitJsonConfig -Path (
    Resolve-ToolkitConfigPath -Name 'prod' -ConfigDir $PSScriptRoot -Prefix 'MyScript'
)
Set-ToolkitAzContext -Config $config
```

---

### `Connect-AzToolkit.ps1` – Azure authentication

Connects to Azure with a deterministic subscription context.  
Parameters can be passed directly or loaded from a JSON config file.

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Connect-AzToolkit.<Name>.json` from the script directory. |
| `-TenantId` | Overrides `context.tenantId` from config. |
| `-DefaultSubscriptionId` | Overrides `context.subscriptionId` from config. |
| `-UseDeviceAuthentication` | Forces device-code login flow. |

#### Config file

Copy `Connect-AzToolkit.template.json`, rename it to `Connect-AzToolkit.<Name>.json`  
(e.g. `Connect-AzToolkit.prod.json`) and fill in your values.  
Config files matching `**/*.json` are excluded from source control via `.gitignore`.

```json
{
  "context": {
    "tenantId": "<tenant-guid>",
    "subscriptionId": "<subscription-guid>"
  },
  "auth": {
    "useDeviceAuthentication": false
  }
}
```

#### Examples

```powershell
# Load config by name
.\shared\Connect-AzToolkit.ps1 -ConfigName prod

# Pass parameters directly
.\shared\Connect-AzToolkit.ps1 -TenantId '<guid>' -DefaultSubscriptionId '<guid>'
```

---

### `Connect-M365.ps1` – Microsoft 365 authentication

Connects interactively to Microsoft Graph, Teams, SharePoint Online (PnP), and Exchange Online.
By default, all four services are connected.

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Connect-M365.<Name>.json` from the script directory. |
| `-TenantId` | Overrides `tenantId` from config. |
| `-TenantAdminUrl` | Overrides `tenantAdminUrl` from config. Required for SharePoint. |
| `-PnpClientId` | Overrides `pnpClientId` from config. |
| `-GraphScopes` | Overrides `graphScopes` from config. |
| `-UseDeviceAuthentication` | Enables device-code flow for supported services. |
| `-ExchangeUseDeviceAuthentication` | Enables device-code flow specifically for Exchange Online. |
| `-ExchangeDisableWAM` | Disables WAM for Exchange Online interactive login. |
| `-Graph`, `-Teams`, `-SharePoint`, `-Exchange` | Connect only selected services. |

#### Config file

Copy `Connect-M365.template.json`, rename it to `Connect-M365.<Name>.json`
(for example `Connect-M365.prod.json`) and fill in your values.

```json
{
  "tenantId": "<tenant-guid>",
  "tenantAdminUrl": "https://contoso-admin.sharepoint.com",
  "graphScopes": [
    "User.ReadWrite.All",
    "Group.ReadWrite.All",
    "Directory.ReadWrite.All",
    "Sites.ReadWrite.All",
    "Mail.ReadWrite"
  ],
  "pnpClientId": "<entra-app-registration-client-id>",
  "auth": {
    "useDeviceAuthentication": false,
    "exchangeUseDeviceAuthentication": false,
    "exchangeDisableWAM": false
  }
}
```

#### Examples

```powershell
# Connect to all M365 services
.\shared\Connect-M365.ps1 -ConfigName prod

# Connect only Graph and Exchange
.\shared\Connect-M365.ps1 -ConfigName prod -Graph -Exchange
```

#### Troubleshooting: Exchange interactive login fails with broker/WAM errors

If Exchange login fails with errors mentioning `CreateBroker`, `MSAL`,
or `Object reference not set to an instance of an object`, disable WAM for Exchange.

Set this in your `Connect-M365.<Name>.json`:

```json
{
  "auth": {
    "exchangeDisableWAM": true
  }
}
```

Or run once with a parameter:

```powershell
.\shared\Connect-M365.ps1 -ConfigName prod -ExchangeDisableWAM
```

---

### `Install-Prerequisites.ps1` – Module bootstrap

Installs all required PowerShell modules (Az, Microsoft.Graph, ExchangeOnlineManagement, etc.).  
Run once on a new machine or after a fresh PowerShell installation.

```powershell
.\shared\Install-Prerequisites.ps1
```

---

## Templates

| File | Description |
|---|---|
| `Connect-AzToolkit.template.json` | Config template for `Connect-AzToolkit.ps1`. |