# Entra ID

Scripts related to identity management, role assignments, 
governance, and cross-tenant scenarios.

---

## Scripts

| File | Description |
|---|---|
| `Create-AppRegistrationWithCertificate.ps1` | Creates an Entra ID App Registration with a self-signed certificate credential and exports certificate files. |
| `Create-AppRegistrationWithClientSecret.ps1` | Creates an Entra ID App Registration with a client secret. |
| `Create-ServicePrincipalForDeployment.ps1` | Creates an App Registration with a client secret, assigns an Azure RBAC role on a resource group, and exports GitHub Actions credentials JSON. |
| `Add-FederatedCredentialForGitHub.ps1` | Adds an OIDC federated identity credential to an existing App Registration for passwordless GitHub Actions authentication. |
| `Create-PemFromCerAndKey.ps1` | Creates a PEM file from `<CertificateBaseName>.key` and `<CertificateBaseName>.cer`. |
| `Get-ClientSecretsAndCertificatesExpirationDate.ps1` | Lists expiration dates of client secrets and certificates for App Registrations. |
| `Remove-EntraUser.ps1` | Removes Entra ID users (soft-delete and optional permanent delete). |

---

## Configuration Pattern

Scripts in this folder support:

- `-ConfigPath` (explicit path to JSON config file)
- `-ConfigName` (loads `<ScriptName>.<Name>.json` from the script directory)

Direct command-line parameters always override values from the JSON config file.

---

## Create-AppRegistrationWithCertificate

Examples:

```powershell
.\Create-AppRegistrationWithCertificate.ps1 -ConfigName prod
.\Create-AppRegistrationWithCertificate.ps1 -ConfigName prod -ConnectGraph
.\Create-AppRegistrationWithCertificate.ps1 -AppRegistrationName 'my-app-prd' -ServiceNowTicket 'RITM1234567'
```

Security guidance:

- Generated certificate files are intentionally ignored by Git (`Certificates/`, `*.cer`, `*.key`, `*.pfx`, etc.)
- Private keys must never be committed to source control
- Use Azure Key Vault for production-grade certificate and key storage

---

## Create-AppRegistrationWithClientSecret

Creates an App Registration and matching Enterprise Application, generates a client secret,
and outputs the credentials to the console and clipboard.

The client secret value is shown **only once** after creation.

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Create-AppRegistrationWithClientSecret.<Name>.json` from the script directory. |
| `-AppRegistrationName` | Display name for the new App Registration. **Required.** |
| `-ServiceNowTicket` | Optional notes field for ticket references. |
| `-SecretDisplayName` | Display name for the secret. Default: `client-secret`. |
| `-ValidityYears` | Secret validity in years. Default: `1`. |
| `-ConnectGraph` | Connect to Microsoft Graph from within this script. |
| `-TenantId` | Optional. Tenant ID for `Connect-MgGraph`. Falls back to active Az context. |
| `-UseDeviceAuthentication` | Use device code flow for `Connect-MgGraph`. |

#### Config file

Copy `Create-AppRegistrationWithClientSecret.template.json`, rename to
`Create-AppRegistrationWithClientSecret.<Name>.json` and fill in your values.

```json
{
  "appRegistrationName": "my-app-prd",
  "serviceNowTicket": "RITM0000000",
  "tenantId": "",
  "secretDisplayName": "client-secret",
  "validityYears": 1,
  "auth": {
    "connectGraph": false,
    "useDeviceAuthentication": false
  }
}
```

#### Examples

```powershell
.\Create-AppRegistrationWithClientSecret.ps1 -ConfigName prod
.\Create-AppRegistrationWithClientSecret.ps1 -AppRegistrationName 'my-app-prd' -ConnectGraph
```

Security guidance:

- The client secret value is shown only once and cannot be retrieved again
- Store it immediately in Azure Key Vault or a secrets manager
- Never commit secrets to source control

---

## Create-ServicePrincipalForDeployment

Creates an App Registration and Enterprise Application, generates a client secret,
assigns an Azure RBAC role on a resource group, and exports a credentials JSON file
ready for use as a GitHub Actions secret (`azure/login@v2`).

Add the following to your `.gitignore`:
```
Credentials/*.github-credentials.json
```

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Create-ServicePrincipalForDeployment.<Name>.json` from the script directory. |
| `-AppRegistrationName` | Display name, e.g. `sp-myapp-github`. **Required.** |
| `-ServiceNowTicket` | Optional notes field for ticket references. |
| `-SubscriptionId` | Azure Subscription ID. Optional – falls back to active Az context. |
| `-ResourceGroupName` | Resource group to assign the role on. **Required.** |
| `-Role` | RBAC role to assign. Default: `Contributor`. |
| `-SecretValidityMonths` | Secret validity in months. Default: `24`. |
| `-OutputPath` | Output directory for the credentials file. Default: `.\Credentials`. |
| `-ConnectGraph` | Connect to Microsoft Graph from within this script. |
| `-ConnectAzure` | Run `Connect-AzAccount` from within this script. |
| `-TenantId` | Optional. Falls back to active Az context. |
| `-UseDeviceAuthentication` | Use device code flow for `Connect-MgGraph`. |

#### Config file

Copy `Create-ServicePrincipalForDeployment.template.json`, rename to
`Create-ServicePrincipalForDeployment.<Name>.json` and fill in your values.

```json
{
  "appRegistrationName": "sp-myapp-github",
  "resourceGroupName": "rg-myapp",
  "role": "Contributor",
  "secretValidityMonths": 24,
  "outputPath": ".\\Credentials",
  "auth": {
    "connectGraph": true,
    "connectAzure": true,
    "useDeviceAuthentication": false
  }
}
```

`subscriptionId` and `tenantId` are optional when already connected via `Connect-AzToolkit.ps1`.

#### Recommended workflow

```powershell
# 1. Authenticate
.\shared\Connect-AzToolkit.ps1 -ConfigName mytenant

# 2. Create service principal and credentials file
.\entra\Create-ServicePrincipalForDeployment.ps1 -ConfigName myapp

# 3. Optionally assign Key Vault access
.\azure\iam\Assign-KeyVaultRoleToServicePrincipal.ps1 -ConfigName myapp
```

#### Examples

```powershell
.\Create-ServicePrincipalForDeployment.ps1 -ConfigName brands-advisory-cms
.\Create-ServicePrincipalForDeployment.ps1 -AppRegistrationName 'sp-myapp-github' -ResourceGroupName 'rg-myapp'
```

Security guidance:

- The credentials JSON contains a client secret in plaintext – never commit it to source control
- Add `Credentials/*.github-credentials.json` to `.gitignore`
- Store the JSON value as a GitHub Actions secret (`AZURE_CREDENTIALS`)
- Rotate the secret before it expires

---

## Add-FederatedCredentialForGitHub

Adds an OIDC federated identity credential to an **existing** App Registration,
enabling passwordless GitHub Actions authentication via `azure/login@v2`.

This is the recommended upgrade path from client-secret-based service principals:
once the federated credential is in place, no `AZURE_CLIENT_SECRET` is needed.

The operation is idempotent – if a credential with the same name already exists it is reported and skipped.

#### Parameters

| Parameter | Description |
|---|---|
| `-ConfigPath` | Explicit path to a JSON config file. |
| `-ConfigName` | Loads `Add-FederatedCredentialForGitHub.<Name>.json` from the script directory. |
| `-AppRegistrationName` | Display name of the existing App Registration. **Required.** |
| `-AppId` | App (client) ID for disambiguation when multiple registrations share the same name. |
| `-GitHubOrganization` | GitHub organisation or user account name. **Required.** |
| `-GitHubRepository` | GitHub repository name (without owner). **Required.** |
| `-GitHubEntity` | Trigger scope: `branch`, `tag`, `environment`, or `pull_request`. **Required.** |
| `-GitHubEntityValue` | Branch name, tag, or environment name. Required for all entity types except `pull_request`. |
| `-CredentialName` | Display name for the federated credential. Auto-generated when omitted. |
| `-ConnectGraph` | Connect to Microsoft Graph from within this script. |
| `-TenantId` | Optional. Tenant ID for `Connect-MgGraph`. |
| `-UseDeviceAuthentication` | Use device code flow for `Connect-MgGraph`. |

#### Subject claim formats

| `GitHubEntity` | Generated subject claim |
|---|---|
| `branch` | `repo:{org}/{repo}:ref:refs/heads/{value}` |
| `tag` | `repo:{org}/{repo}:ref:refs/tags/{value}` |
| `environment` | `repo:{org}/{repo}:environment:{value}` |
| `pull_request` | `repo:{org}/{repo}:pull_request` |

#### Config file

Copy `Add-FederatedCredentialForGitHub.template.json`, rename to
`Add-FederatedCredentialForGitHub.<Name>.json` and fill in your values.

```json
{
  "appRegistrationName": "sp-myapp-github",
  "gitHubOrganization": "my-org",
  "gitHubRepository": "my-repo",
  "gitHubEntity": "branch",
  "gitHubEntityValue": "main",
  "auth": {
    "connectGraph": true,
    "useDeviceAuthentication": false
  }
}
```

#### Examples

```powershell
# Add a branch-scoped credential using a config file
.\Add-FederatedCredentialForGitHub.ps1 -ConfigName brands-advisory-cms

# Add an environment-scoped credential via parameters
.\Add-FederatedCredentialForGitHub.ps1 `
    -AppRegistrationName 'sp-myapp-github' `
    -GitHubOrganization 'my-org' `
    -GitHubRepository 'my-repo' `
    -GitHubEntity environment `
    -GitHubEntityValue production

# Add a pull-request-scoped credential
.\Add-FederatedCredentialForGitHub.ps1 `
    -AppRegistrationName 'sp-myapp-github' `
    -GitHubOrganization 'my-org' `
    -GitHubRepository 'my-repo' `
    -GitHubEntity pull_request
```

#### Recommended upgrade workflow

```powershell
# 1. Create the service principal (client-secret based)
.\entra\Create-ServicePrincipalForDeployment.ps1 -ConfigName myapp

# 2. Add OIDC federated credential for the main branch
.\entra\Add-FederatedCredentialForGitHub.ps1 -ConfigName myapp

# 3. In GitHub repository settings add secrets:
#    AZURE_CLIENT_ID  = <appId from step 1>
#    AZURE_TENANT_ID  = <tenantId from step 1>
#    AZURE_SUBSCRIPTION_ID = <subscriptionId>
#
# 4. Update the GitHub Actions workflow (no AZURE_CLIENT_SECRET needed):
#    - uses: azure/login@v2
#      with:
#        client-id: ${{ secrets.AZURE_CLIENT_ID }}
#        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
#        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

Security guidance:

- Federated credentials are scoped to a specific repository, entity type and value – grant only what is needed
- No secrets are created or transmitted; authentication relies on GitHub's OIDC token
- Multiple credentials can be added for different branches or environments on the same App Registration

---

## Create-PemFromCerAndKey

Examples:

```powershell
.\Create-PemFromCerAndKey.ps1 -CertificateBaseName 'my-app-prd'
.\Create-PemFromCerAndKey.ps1 -ConfigName prod
```

Notes:

- `CertificateBaseName` must be provided without extension.
- The script expects `<CertificateBaseName>.cer` and `<CertificateBaseName>.key` in the certificates directory.
- The generated PEM file contains an unencrypted private key and must be handled securely.