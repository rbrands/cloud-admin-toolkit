# Cloud Admin Toolkit

Reusable PowerShell toolkit for enterprise Microsoft Cloud operations  
(Azure, Entra ID, Microsoft 365).

This repository contains reusable administrative and operational scripts 
used in real-world Microsoft Cloud environments.  
The focus is on practical automation, governance support, and operational consistency.

---

## Scope

The toolkit is structured by Microsoft Cloud domains:

- **Azure** – Infrastructure operations, RBAC, Policy, Arc, Update Manager  
- **Entra ID** – Identity governance, role management, cross-tenant scenarios  
- **Microsoft 365** – Exchange, Teams, SharePoint, compliance  
- **Shared** – Reusable helpers and environment bootstrap scripts  

Scripts are designed to be:

- Modular  
- Reusable  
- Explicit in permissions  
- Enterprise-oriented  

---

## Getting Started

Requirements:

- PowerShell 7+
- Required modules (Az, Microsoft.Graph, ExchangeOnlineManagement, etc.)

Install required modules:

```powershell
./shared/Install-Prerequisites.ps1
```

Authenticate explicitly as needed:

```powershell
Connect-AzAccount
Connect-MgGraph
```

---

## Design Principles

- Domain-oriented structure (not API-driven)
- Clear Verb-Noun naming convention
- No hidden side effects
- Explicit authentication
- Enterprise-ready operational patterns

---

## Repository Guidelines

To ensure reusability and neutrality:

- No hardcoded tenant IDs, subscription IDs or resource names
- No environment-specific defaults
- No embedded secrets or credentials
- Scripts should be idempotent where feasible
- Authentication must be explicit (no implicit auto-connect logic)

This repository is designed for reusable enterprise scenarios,  
not for single-tenant or project-specific implementations.

---

## Scripts and Functions

### `shared/`

| File | Type | Description |
|---|---|---|
| `Install-Prerequisites.ps1` | Script | Installs all required PowerShell modules. |
| `Connect-AzToolkit.ps1` | Script | Connects to Azure with deterministic subscription context, config-file driven. |
| `AzToolkit.Config.psm1` | Module | Shared config-loading and Azure context helpers – imported by all scripts. |
| `Connect-AzToolkit.template.json` | Template | Config template for `Connect-AzToolkit.ps1`. |

**Exported module functions (`AzToolkit.Config.psm1`)**

| Function | Description |
|---|---|
| `Resolve-ToolkitConfigPath` | Resolves a JSON config path by explicit path or by `<Prefix>.<Name>.json` convention. |
| `Read-ToolkitJsonConfig` | Reads and parses a JSON config file. Returns `$null` when no path is given. |
| `Set-ToolkitAzContext` | Sets the Azure subscription context from a config object or an explicit subscription ID. |

### `azure/`

> Scripts will be listed here as they are added.

### `azure/web-platform/`

| File | Type | Description |
|---|---|---|
| `Set-AzureFunctionAppHostKey.ps1` | Script | Creates or updates a host key on an Azure Function App via Azure CLI. Uses the current subscription context set by `Connect-AzToolkit.ps1`; `subscriptionId` in config is optional. |
| `Set-AzureFunctionAppHostKey.template.json` | Template | Config template for `Set-AzureFunctionAppHostKey.ps1`. |

### `azure/iam/`

| File | Type | Description |
|---|---|---|
| `Get-AzRoleAssignmentsForPrincipalOnResource.ps1` | Script | Lists all role assignments (direct and inherited) for a principal on a specific Azure resource. Resolves the resource via Azure Resource Graph. |
| `Get-AzRoleAssignmentsForPrincipalOnResource.template.json` | Template | Config template for `Get-AzRoleAssignmentsForPrincipalOnResource.ps1`. |

### `entra/`

> Scripts will be listed here as they are added.

### `m365/`

> Scripts will be listed here as they are added.

---

## Disclaimer

Scripts are provided **as-is** without warranty of any kind.

Always validate and test in non-production environments before applying  
to production systems.

---

Maintained by  
**Robert Brands**  
Freelance IT Consultant | Solution Architect | Cloud Adoption & GenAI
