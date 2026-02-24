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
- Safe by default where possible  
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

## Disclaimer

Scripts are provided **as-is** without warranty of any kind.

Always validate and test in non-production environments before applying  
to production systems.

---

Maintained by  
**Robert Brands**  
Freelance IT Consultant | Solution Architect | Cloud Adoption & GenAI
