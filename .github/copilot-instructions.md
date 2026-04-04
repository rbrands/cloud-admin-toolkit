# Copilot Instructions – Cloud Admin Toolkit

This repository is a reusable PowerShell toolkit for enterprise Microsoft Cloud administration
(Azure, Entra ID, Microsoft 365). Apply the following conventions to all code suggestions.

---

## Language

- All script comments, documentation, and output messages must be written in **English**.

---

## PowerShell conventions

- **PowerShell 7+** is required. Do not use syntax or cmdlets exclusive to Windows PowerShell 5.
- Always use `[CmdletBinding()]` and a `param()` block, even for simple scripts.
- Follow the **Verb-Noun** naming convention (e.g. `Get-AzRoleAssignments`, `Set-FunctionAppKey`).
- Use `Write-Host` with `-ForegroundColor` for status output (Cyan for headers, Yellow for progress, Green for success, Red for errors).
- Scripts must be **idempotent** where feasible.

## Authentication

- Authentication must always be **explicit**. Never add implicit auto-connect logic.
- Use `Connect-AzAccount` for Azure, `Connect-MgGraph` for Microsoft Graph.
- Use `Connect-AzToolkit.ps1` / `shared/AzToolkit.Config.psm1` for scripts that require an Azure subscription context.

## Configuration

- Use the shared `AzToolkit.Config.psm1` module for config loading and Azure context management.
- Config files follow the `<ScriptBaseName>.<Name>.json` convention (e.g. `Get-Report.prod.json`).
- Every script that accepts external configuration must ship a `*.template.json` as a starting point.

## Security

- **No hardcoded** tenant IDs, subscription IDs, resource names, or secrets.
- No environment-specific defaults.
- No embedded credentials.

## Structure

- Place scripts in the appropriate domain folder: `azure/`, `entra/`, `m365/`, or `shared/`.
- Import `AzToolkit.Config.psm1` using a path relative to `$PSScriptRoot`.
- Software prerequisites are managed via `.config/prerequisites.dsc.yaml` (winget DSC)
  and `shared/Install-Prerequisites.ps1` (PowerShell modules).

## Documentation
- Document all scripts with comment-based help (using `Get-Help` syntax).
- Use the `README.md` to provide an overview of the repository, design principles, and detailed documentation for each script, including usage examples and security guidance.
- Use the `copilot-instructions.md` file to specify coding conventions and guidelines for AI-generated code suggestions.
- Keep global documentation in `README.md` and implementation details in individual README.md in subfolders if necessary.

