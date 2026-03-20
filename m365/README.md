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