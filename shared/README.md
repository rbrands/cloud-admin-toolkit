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
    Resolve-ToolkitConfigPath -Name 'prod' -ScriptRoot $PSScriptRoot -Prefix 'MyScript'
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
| `config.template.json` | Generic config template for scripts that only need a subscription context. |