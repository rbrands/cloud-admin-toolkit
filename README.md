
# Cloud Admin Toolkit

Reusable PowerShell toolkit for enterprise Microsoft Cloud operations  
(Azure, Entra ID, Microsoft 365).

This repository contains reusable administrative and operational scripts 
used in real-world Microsoft Cloud environments.  
The focus is on practical automation, governance support, and operational consistency.

---

## Scope

The toolkit is structured by Microsoft Cloud domains:

- **Azure** – VM operations, Update Manager, Arc, Policy, RBAC
- **Entra ID** – identity governance, roles, cross-tenant scenarios
- **Microsoft 365** – Exchange, Teams, SharePoint, compliance
- **Shared** – authentication helpers, bootstrap scripts, reusable utilities

Scripts are designed to be:
- Modular
- Reusable
- Explicit in permissions
- Safe by default where possible

---

## Getting Started

Ensure you have:

- PowerShell 7+
- Required modules (Az, Microsoft.Graph, ExchangeOnlineManagement, etc.)

You can use the bootstrap script:

```powershell
./shared/bootstrap/Install-Prerequisites.ps1
