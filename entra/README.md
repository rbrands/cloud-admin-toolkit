# Entra ID

Scripts related to identity management, role assignments, 
governance, and cross-tenant scenarios.

---

## Scripts

| File | Description |
|---|---|
| `Create-AppRegistrationWithCertificate.ps1` | Creates an Entra ID App Registration with a self-signed certificate credential and exports certificate files. |
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