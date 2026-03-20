# Microsoft 365

Scripts for administrative and operational tasks 
across Exchange, Teams, SharePoint and compliance.

## Remove-Team.ps1

`Remove-Team.ps1` supports both direct IDs and display-name lookup:

- `-TeamIds` / `teamIds`: delete by GroupId.
- `-TeamNames` / `teamNames`: resolve display names to GroupIds and delete.

Examples:

```powershell
# By display name
.\m365\Remove-Team.ps1 -TeamNames "Project Phoenix"

# By ID
.\m365\Remove-Team.ps1 -TeamIds "00000000-0000-0000-0000-000000000001"

# Optional: list IDs manually
Get-Team | Select-Object DisplayName, GroupId
```

If multiple teams match a provided name, the script prints all candidates and skips that entry to avoid accidental deletion.

For SharePoint site deletion, `tenantAdminUrl` is optional when an active PnP connection exists. The script derives the admin URL from the current connection and reconnects automatically if needed.
SharePoint site URL resolution first uses Graph and automatically falls back to PnP tenant lookup by GroupId when Graph returns `Forbidden`.

When `-PermanentlyDelete` is used, the script automatically retries Entra recycle-bin purge with backoff to handle directory replication delay.
SharePoint site deletion retries with longer backoff and checks whether SharePoint still sees the site as group-connected. In some tenants this propagation can take several minutes.
If SharePoint returns "File Not Found" during deletion, the script treats it as already removed.