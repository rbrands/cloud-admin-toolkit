# Microsoft 365

Scripts for administrative and operational tasks 
across Exchange, Teams, SharePoint and compliance.

## Check-TeamsMeetingPolicyAllowAnonymousJoin.ps1

Reads the global Teams Meeting Policy and reports whether anonymous users
are allowed to join meetings (`AllowAnonymousUsersToJoinMeeting`).

The script outputs the current value with color-coded status:

- **Green** – anonymous join is disabled (recommended for regulated environments).
- **Red** – anonymous join is enabled; the output includes the remediation command.

Prerequisites: `Connect-MicrosoftTeams` must be called first.

```powershell
# Connect to Teams, then run the check
.\shared\Connect-M365.ps1 -ConfigName prod -Teams
.\m365\Check-TeamsMeetingPolicyAllowAnonymousJoin.ps1
```

Required permission: **Teams Administrator** (or Global Reader / Global Administrator).

To remediate a finding, use `Disable-TeamsMeetingPolicyAnonymousJoin.ps1` (see below).

## Disable-TeamsMeetingPolicyAnonymousJoin.ps1

Sets `AllowAnonymousUsersToJoinMeeting = $false` in the global Teams Meeting Policy.
The script is **idempotent**: if the setting is already disabled, no change is made.

Supports `-WhatIf` to preview the change without applying it.

Prerequisites: `Connect-MicrosoftTeams` must be called first.

```powershell
# Preview
.\m365\Disable-TeamsMeetingPolicyAnonymousJoin.ps1 -WhatIf

# Apply
.\m365\Disable-TeamsMeetingPolicyAnonymousJoin.ps1
```

Required permission: **Teams Administrator** (or Global Administrator).

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