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

### Option A – winget DSC (recommended)

Installs all software prerequisites (PowerShell 7, Git, Azure CLI, VS Code)  
using a single winget configuration file:

```powershell
winget configure --file .config\prerequisites.dsc.yaml
```

Then install the required PowerShell modules:

```powershell
./shared/Install-Prerequisites.ps1
```

### Option B – manual

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

Security note for certificate-generating scripts:

- Generated certificate artifacts are ignored via `.gitignore` (`Certificates/`, `*.cer`, `*.key`, `*.pfx`, etc.)
- Private keys must never be committed to source control
- Store production certificates and keys in Azure Key Vault

This repository is designed for reusable enterprise scenarios,  
not for single-tenant or project-specific implementations.

---

## Scripts and Functions

### `.config/`

| File | Type | Description |
|---|---|---|
| `prerequisites.dsc.yaml` | winget DSC | Installs software prerequisites (PowerShell 7, Git, Azure CLI, VS Code) via `winget configure`. |

### `shared/`

| File | Type | Description |
|---|---|---|
| `Install-Prerequisites.ps1` | Script | Installs all required PowerShell modules. |
| `Connect-AzToolkit.ps1` | Script | Connects to Azure with deterministic subscription context, config-file driven. |
| `Connect-M365.ps1` | Script | Connects to Graph, Teams, SharePoint, and Exchange with explicit, config-driven authentication options. |
| `AzToolkit.Config.psm1` | Module | Shared config-loading and Azure context helpers – imported by all scripts. |
| `Connect-AzToolkit.template.json` | Template | Config template for `Connect-AzToolkit.ps1`. |
| `Connect-M365.template.json` | Template | Config template for `Connect-M365.ps1`. |

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
| `Assign-KeyVaultCertificatesOfficerToUser.ps1` | Script | Assigns the Azure RBAC role `Key Vault Certificates Officer` to a user on a specific Key Vault. Idempotent (no duplicate assignments). |
| `Assign-KeyVaultCertificatesOfficerToUser.template.json` | Template | Config template for `Assign-KeyVaultCertificatesOfficerToUser.ps1`. |
| `Assign-CosmosDbAccess.ps1` | Script | Assigns Cosmos DB SQL data-plane access to a user (idempotent), with configurable role and scope. |
| `Assign-CosmosDbAccess.template.json` | Template | Config template for `Assign-CosmosDbAccess.ps1`. |
| `List-CosmosDbRBAC.ps1` | Script | Lists Cosmos DB SQL RBAC assignments for an account and resolves role definition IDs and principal IDs to readable names. |
| `List-CosmosDbRBAC.template.json` | Template | Config template for `List-CosmosDbRBAC.ps1`. |
| `Get-UserRoleAssignments.ps1` | Script | Lists all direct Azure RBAC role assignments for a user across all accessible subscriptions. Resolves users by UPN, object ID, or short name (Kürzel). Supports CSV export. |
| `Get-UserRoleAssignments.template.json` | Template | Config template for `Get-UserRoleAssignments.ps1`. |

### `entra/`

| File | Type | Description |
|---|---|---|
| `Get-ClientSecretsAndCertificatesExpirationDate.ps1` | Script | Lists expiration dates of client secrets and certificates for all Entra ID App Registrations. |
| `Get-ClientSecretsAndCertificatesExpirationDate.template.json` | Template | Config template for `Get-ClientSecretsAndCertificatesExpirationDate.ps1`. |
| `Create-AppRegistrationWithCertificate.ps1` | Script | Creates an Entra ID App Registration, generates a self-signed certificate, uploads it as key credential, and exports certificate files. Supports command-line parameters and JSON config. |
| `Create-AppRegistrationWithCertificate.template.json` | Template | Config template for `Create-AppRegistrationWithCertificate.ps1`. |
| `Create-PemFromCerAndKey.ps1` | Script | Creates a combined PEM file from `<CertificateBaseName>.key` and `<CertificateBaseName>.cer` in the certificates directory. |
| `Create-PemFromCerAndKey.template.json` | Template | Config template for `Create-PemFromCerAndKey.ps1`. |
| `Remove-EntraUser.ps1` | Script | Removes Entra ID user accounts for a list of users. Supports soft-delete and permanent delete (purge from recycling bin). |
| `Remove-EntraUser.template.json` | Template | Config template for `Remove-EntraUser.ps1`. |

### `m365/`

| File | Type | Description |
|---|---|---|
| `Remove-Mailbox.ps1` | Script | Removes Exchange Online mailboxes for a list of users. Supports soft-delete and permanent delete. |
| `Remove-Mailbox.template.json` | Template | Config template for `Remove-Mailbox.ps1`. |
| `Remove-OneDrive.ps1` | Script | Removes OneDrive for Business sites for a list of users via PnP PowerShell. Supports soft-delete and permanent delete. |
| `Remove-OneDrive.template.json` | Template | Config template for `Remove-OneDrive.ps1`. |

---

## Scenarios

### User Offboarding

Full removal of a user account including mailbox and OneDrive requires three steps,
because Exchange Online synchronizes with Entra ID asynchronously.

With the current scripts, OneDrive lookup is UPN/profile-based.
If you delete the Entra user first, OneDrive lookup can return "not found".
Mailbox purge can still require Exchange sync time.
Use the sequence below.

```powershell
# 1. Connect to SharePoint via toolkit script
.\shared\Connect-M365.ps1 -ConfigName offboarding -SharePoint

# 2. Delete OneDrive for Business site (while user profile lookup still works)
.\m365\Remove-OneDrive.ps1 -ConfigName offboarding -SkipRecycleBin

# 3. Soft-delete Entra ID user
.\shared\Connect-M365.ps1 -ConfigName offboarding -Graph
.\entra\Remove-EntraUser.ps1 -ConfigName offboarding

# 4. Wait for Exchange to sync (minutes to hours), then permanently delete mailbox
.\shared\Connect-M365.ps1 -ConfigName offboarding -Exchange
.\m365\Remove-Mailbox.ps1 -ConfigName offboarding -PermanentlyDelete

# 5. Permanently delete Entra ID user from recycling bin
.\shared\Connect-M365.ps1 -ConfigName offboarding -Graph
.\entra\Remove-EntraUser.ps1 -ConfigName offboarding -PermanentlyDelete
```

> **Note:** If Exchange is not synced yet, rerun `Remove-Mailbox.ps1` later.
> **Note:** If step 4 reports that the user is still soft-deleted in Entra ID, run step 5 first and retry step 4 after a short delay.
> **Note:** OneDrive content is retained for the SharePoint retention period
> (default 30 days, max 180 days) unless `-SkipRecycleBin` is used.

---

## Disclaimer

Scripts are provided **as-is** without warranty of any kind.

Always validate and test in non-production environments before applying  
to production systems.

---

Maintained by  
**Robert Brands**  
Freelance IT Consultant | Solution Architect | Cloud Adoption & GenAI
