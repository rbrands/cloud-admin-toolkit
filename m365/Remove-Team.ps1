<#
.SYNOPSIS
    Removes Microsoft Teams teams as completely as possible.

.DESCRIPTION
    Removes one or more Teams by Group ID (AAD Object ID of the underlying
    Microsoft 365 Group) or by Team display name.

    What is removed (depending on flags):

      1. The Team and its Microsoft 365 Group are soft-deleted (recoverable
         for 30 days from the Entra ID recycle bin) – always performed.
      2. [-PermanentlyDelete]  Purges the M365 group from the Entra ID recycle
         bin so it cannot be restored.
      3. [-DeleteSharePointSite]  Removes the associated SharePoint Online team
         site. Default: soft-delete into SP admin recycle bin.
         Add [-SkipRecycleBin] to bypass the SP recycle bin entirely.

    Channel messages, chats, recordings in Stream, and Planner plans are
    removed automatically when the M365 group is purged.

    Supports:
    - -ConfigPath  (explicit path to JSON config file)
    - -ConfigName  (loads Remove-Team.<Name>.json from the script dir)

    All parameters can be provided directly or read from a JSON config file.
    Direct parameters always take precedence over config file values.

    Concrete config files must not be committed to the repository.

    IMPORTANT – required connections before running:
      Always            : Connect-MicrosoftTeams
      -PermanentlyDelete: Connect-MgGraph -Scopes 'Group.ReadWrite.All','Directory.ReadWrite.All'
      -DeleteSharePointSite: Connect-PnPOnline to the tenant admin URL, or supply -TenantAdminUrl

.EXAMPLE
    .\Remove-Team.ps1 -ConfigName prod

.EXAMPLE
    .\Remove-Team.ps1 -TeamIds '00000000-0000-0000-0000-000000000001'

.EXAMPLE
    .\Remove-Team.ps1 -TeamNames 'Project Phoenix'

.EXAMPLE
    .\Remove-Team.ps1 -ConfigName prod -WhatIf

.EXAMPLE
    .\Remove-Team.ps1 -ConfigName prod -PermanentlyDelete -DeleteSharePointSite -SkipRecycleBin

.NOTES
    Required permissions:
      Teams Administrator  (or Global Administrator)
      -PermanentlyDelete       : Group.ReadWrite.All, Directory.ReadWrite.All (Graph)
      -DeleteSharePointSite    : SharePoint Administrator (or Global Administrator)

    Prerequisites:
      MicrosoftTeams module
      Microsoft.Graph.Groups + Microsoft.Graph.Identity.DirectoryManagement  (for -PermanentlyDelete / SP site URL)
      PnP.PowerShell module  (for -DeleteSharePointSite)
      Run .\shared\Install-Prerequisites.ps1 to install all modules.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$ConfigName,

    # Directory to search for the config file. Defaults to the script directory.
    [Parameter(Mandatory = $false)]
    [string]$ConfigDir,

    # AAD Object IDs (GroupIds) of the Teams to remove.
    # Overrides the teamIds array in the config file.
    [Parameter(Mandatory = $false)]
    [string[]]$TeamIds,

    # Display names of Teams to remove.
    # Overrides the teamNames array in the config file.
    [Parameter(Mandatory = $false)]
    [string[]]$TeamNames,

    # SharePoint Online tenant admin URL, e.g. https://contoso-admin.sharepoint.com
    # Required when -DeleteSharePointSite is used and no active PnP admin connection exists.
    # Overrides tenantAdminUrl in the config file.
    [Parameter(Mandatory = $false)]
    [string]$TenantAdminUrl,

    # Also delete the associated SharePoint Online team site.
    # Default: soft-delete into SP admin recycle bin (recoverable).
    [Parameter(Mandatory = $false)]
    [switch]$DeleteSharePointSite,

    # When combined with -DeleteSharePointSite, permanently deletes the SP site
    # by bypassing the SP admin recycle bin.
    [Parameter(Mandatory = $false)]
    [switch]$SkipRecycleBin,

    # Permanently purge the M365 group from the Entra ID recycle bin.
    # Without this flag the group is soft-deleted and recoverable for 30 days.
    # Requires Microsoft Graph connection with Group.ReadWrite.All scope.
    [Parameter(Mandatory = $false)]
    [switch]$PermanentlyDelete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\shared\AzToolkit.Config.psm1') -Force

# ── Config loading ─────────────────────────────────────────────────────────────

$resolvedConfigPath = Resolve-ToolkitConfigPath `
    -ExplicitPath $ConfigPath `
    -Name         $ConfigName `
    -ConfigDir    $(if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }) `
    -Prefix       'Remove-Team'

$config = Read-ToolkitJsonConfig -Path $resolvedConfigPath

# Merge: direct parameter wins over config file
if (-not $TeamIds -and $null -ne $config -and $config.teamIds) {
    $TeamIds = [string[]]$config.teamIds
}

if (-not $TeamNames -and $null -ne $config -and $config.teamNames) {
    $TeamNames = [string[]]$config.teamNames
}

if (-not $TenantAdminUrl -and $null -ne $config -and $config.tenantAdminUrl) {
    $TenantAdminUrl = $config.tenantAdminUrl
}

if (-not $DeleteSharePointSite -and $null -ne $config -and $config.deleteSharePointSite -eq $true) {
    $DeleteSharePointSite = $true
}

if (-not $SkipRecycleBin -and $null -ne $config -and $config.skipRecycleBin -eq $true) {
    $SkipRecycleBin = $true
}

if (-not $PermanentlyDelete -and $null -ne $config -and $config.permanentlyDelete -eq $true) {
    $PermanentlyDelete = $true
}

$purgeMaxAttempts  = 5
$purgeInitialDelay = 15
$purgeMaxDelay     = 90
$spDeleteMaxAttempts  = 6
$spDeleteInitialDelay = 30
$spDeleteMaxDelay     = 300

function Get-SharePointAdminUrlFromUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {
        $uri = [uri]$Url
        $host = $uri.Host.ToLowerInvariant()
        if ($host -match '^(?<tenant>[^.]+?)(?:-admin|-my)?\.sharepoint\.com$') {
            return "https://$($Matches['tenant'])-admin.sharepoint.com"
        }
    }
    catch {
        return $null
    }

    return $null
}

function Resolve-TeamSharePointUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupId
    )

    $result = [ordered]@{
        Url       = $null
        Source    = $null
        ErrorText = $null
    }

    # Primary path: Microsoft Graph
    try {
        $siteInfo = Invoke-MgGraphRequest -Method GET `
            -Uri         "https://graph.microsoft.com/v1.0/groups/$GroupId/sites/root" `
            -ErrorAction Stop
        if ($siteInfo -and $siteInfo.webUrl) {
            $result.Url = $siteInfo.webUrl
            $result.Source = 'Graph'
            return [PSCustomObject]$result
        }
    }
    catch {
        $result.ErrorText = $_.Exception.Message
    }

    # Fallback path: SharePoint admin center (PnP), no Graph sites scope required.
    try {
        $tenantSite = $null

        try {
            $tenantSites = @(Get-PnPTenantSite -Filter "GroupId -eq '$GroupId'" -ErrorAction Stop)
            if ($tenantSites.Count -gt 0) {
                $tenantSite = $tenantSites[0]
            }
        }
        catch {
            # Fallback for tenants where the server-side filter is unavailable.
            $tenantSite = Get-PnPTenantSite -Detailed -ErrorAction Stop | Where-Object { $_.GroupId -eq $GroupId } | Select-Object -First 1
        }

        if ($tenantSite -and $tenantSite.Url) {
            $result.Url = $tenantSite.Url
            $result.Source = 'PnP'
            return [PSCustomObject]$result
        }
    }
    catch {
        if (-not $result.ErrorText) {
            $result.ErrorText = $_.Exception.Message
        }
        else {
            $result.ErrorText = "$($result.ErrorText) | PnP lookup failed: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]$result
}

function Test-SharePointSiteStillGroupConnected {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedGroupId
    )

    try {
        $tenantSite = Get-PnPTenantSite -Identity $Url -Detailed -ErrorAction Stop
        if (-not $tenantSite) {
            return $false
        }

        if (-not $tenantSite.GroupId) {
            return $false
        }

        return ($tenantSite.GroupId.ToString() -eq $ExpectedGroupId)
    }
    catch {
        # If the site cannot be queried anymore, treat it as not group-connected here.
        return $false
    }
}

# ── Validation ─────────────────────────────────────────────────────────────────

if ((-not $TeamIds -or $TeamIds.Count -eq 0) -and (-not $TeamNames -or $TeamNames.Count -eq 0)) {
    Write-Host "No team targets provided. Specify -TeamIds and/or -TeamNames, or set teamIds/teamNames in the config file." -ForegroundColor Red
    exit 1
}

# Verify MicrosoftTeams session
try {
    $null = Get-CsTenant -ErrorAction Stop
}
catch {
    Write-Host "MicrosoftTeams session not found. Run Connect-MicrosoftTeams before executing this script." -ForegroundColor Red
    exit 1
}

# Verify Microsoft.Graph connection when permanent delete or SP URL resolution is needed
if ($PermanentlyDelete -or $DeleteSharePointSite) {
    $mgContext = Get-MgContext
    if (-not $mgContext) {
        $requiredFor = if ($PermanentlyDelete -and $DeleteSharePointSite) { '-PermanentlyDelete and -DeleteSharePointSite' }
                       elseif ($PermanentlyDelete)       { '-PermanentlyDelete' }
                       else                               { '-DeleteSharePointSite (SharePoint URL lookup)' }
        Write-Host "Microsoft Graph session not found ($requiredFor)." -ForegroundColor Red
        Write-Host "Run: Connect-MgGraph -Scopes 'Group.ReadWrite.All','Directory.ReadWrite.All'" -ForegroundColor Red
        exit 1
    }
}

# Verify PnP connection to SharePoint admin center when site deletion is requested
if ($DeleteSharePointSite) {
    try {
        $pnpConn = Get-PnPConnection -ErrorAction Stop
        if (-not $TenantAdminUrl) {
            $TenantAdminUrl = Get-SharePointAdminUrlFromUrl -Url $pnpConn.Url
        }

        if ($pnpConn.Url -notmatch '-admin\.sharepoint\.com') {
            if (-not $TenantAdminUrl) {
                Write-Host "Active PnP connection is not to the SharePoint admin center and tenant admin URL could not be derived automatically." -ForegroundColor Red
                Write-Host "Specify -TenantAdminUrl (or tenantAdminUrl in config) or connect to the admin center first:" -ForegroundColor Red
                Write-Host "Connect-PnPOnline -Url https://<tenant>-admin.sharepoint.com -Interactive" -ForegroundColor Red
                exit 1
            }

            Write-Host "Active PnP connection is not to the SharePoint admin center. Reconnecting to $TenantAdminUrl ..." -ForegroundColor Yellow
            Connect-PnPOnline -Url $TenantAdminUrl -Interactive
        }
    }
    catch {
        if (-not $TenantAdminUrl) {
            Write-Host "No active PnP connection found and no TenantAdminUrl was provided." -ForegroundColor Red
            Write-Host "Specify -TenantAdminUrl (or tenantAdminUrl in config) or connect first:" -ForegroundColor Red
            Write-Host "Connect-PnPOnline -Url https://<tenant>-admin.sharepoint.com -Interactive" -ForegroundColor Red
            exit 1
        }

        Write-Host "No active PnP connection found. Connecting to $TenantAdminUrl ..." -ForegroundColor Yellow
        Connect-PnPOnline -Url $TenantAdminUrl -Interactive
    }
}

# ── Main ───────────────────────────────────────────────────────────────────────

Write-Host "=== Remove-Team ===" -ForegroundColor Cyan
Write-Host "Team IDs          : $(if ($TeamIds) { $TeamIds.Count } else { 0 })" -ForegroundColor Cyan
Write-Host "Team names        : $(if ($TeamNames) { $TeamNames.Count } else { 0 })" -ForegroundColor Cyan
Write-Host "Permanently delete: $(if ($PermanentlyDelete) { 'Yes – purge M365 group from Entra recycle bin' } else { 'No  – soft-delete (recoverable 30 days)' })" -ForegroundColor Cyan
Write-Host "Delete SP site    : $(if ($DeleteSharePointSite) { if ($SkipRecycleBin) { 'Yes – bypass SP recycle bin (permanent)' } else { 'Yes – SP admin recycle bin (recoverable)' } } else { 'No' })" -ForegroundColor Cyan
Write-Host ""

$successCount = 0
$skipCount    = 0
$errorCount   = 0
$processedGroupIds = @{}

$teamTargets = @()
if ($TeamIds) {
    foreach ($teamId in $TeamIds) {
        $teamTargets += [PSCustomObject]@{
            Type  = 'GroupId'
            Value = $teamId
        }
    }
}
if ($TeamNames) {
    foreach ($teamName in $TeamNames) {
        $teamTargets += [PSCustomObject]@{
            Type  = 'DisplayName'
            Value = $teamName
        }
    }
}

foreach ($target in $teamTargets) {

    Write-Host "Processing ($($target.Type)): $($target.Value)" -ForegroundColor Yellow

    # ── Resolve team ───────────────────────────────────────────────────────────

    $team = $null
    if ($target.Type -eq 'GroupId') {
        try {
            $team = Get-Team -GroupId $target.Value -ErrorAction Stop
        }
        catch {
            Write-Host "  - Team not found for GroupId '$($target.Value)' – skipping." -ForegroundColor Gray
            $skipCount++
            continue
        }
    }
    else {
        $matchedTeams = @(Get-Team -DisplayName $target.Value -ErrorAction SilentlyContinue)
        if ($matchedTeams.Count -eq 0) {
            Write-Host "  - No team found for display name '$($target.Value)' – skipping." -ForegroundColor Gray
            $skipCount++
            continue
        }

        $exactMatches = @($matchedTeams | Where-Object { $_.DisplayName -eq $target.Value })
        if ($exactMatches.Count -eq 1) {
            $team = $exactMatches[0]
        }
        elseif ($exactMatches.Count -gt 1) {
            Write-Host "  - Multiple teams with exact display name '$($target.Value)' found – skipping." -ForegroundColor Red
            foreach ($candidate in $exactMatches) {
                Write-Host "    Candidate: $($candidate.DisplayName)  |  GroupId: $($candidate.GroupId)" -ForegroundColor Yellow
            }
            $skipCount++
            continue
        }
        elseif ($matchedTeams.Count -eq 1) {
            $team = $matchedTeams[0]
        }
        else {
            Write-Host "  - Multiple teams matched '$($target.Value)' – skipping." -ForegroundColor Red
            foreach ($candidate in $matchedTeams) {
                Write-Host "    Candidate: $($candidate.DisplayName)  |  GroupId: $($candidate.GroupId)" -ForegroundColor Yellow
            }
            $skipCount++
            continue
        }
    }

    if ($processedGroupIds.ContainsKey($team.GroupId)) {
        Write-Host "  - Team '$($team.DisplayName)' (GroupId: $($team.GroupId)) already processed – skipping duplicate target." -ForegroundColor Gray
        $skipCount++
        continue
    }
    $processedGroupIds[$team.GroupId] = $true

    Write-Host "  DisplayName : $($team.DisplayName)" -ForegroundColor Gray
    Write-Host "  GroupId     : $($team.GroupId)" -ForegroundColor Gray
    Write-Host "  Visibility  : $($team.Visibility)  |  Archived: $($team.Archived)" -ForegroundColor Gray

    # ── Resolve SharePoint site URL before the team is deleted ─────────────────

    $sharePointUrl = $null
    if ($DeleteSharePointSite) {
        $spResolution = Resolve-TeamSharePointUrl -GroupId $team.GroupId
        if ($spResolution.Url) {
            $sharePointUrl = $spResolution.Url
            Write-Host "  SP site     : $sharePointUrl (resolved via $($spResolution.Source))" -ForegroundColor Gray
        }
        else {
            Write-Host "  ! Could not resolve SharePoint site URL: $($spResolution.ErrorText)" -ForegroundColor Yellow
            Write-Host "    The SharePoint site will NOT be deleted for this team." -ForegroundColor Yellow
        }
    }

    if (-not $PSCmdlet.ShouldProcess($team.DisplayName, "Remove Team '$($team.DisplayName)' (GroupId: $($team.GroupId))")) {
        continue
    }

    # ── Step 1: Remove the Team (soft-deletes the underlying M365 group) ───────

    try {
        Remove-Team -GroupId $team.GroupId -ErrorAction Stop
        Write-Host "  - Team removed; M365 group is soft-deleted." -ForegroundColor Green
        $successCount++
    }
    catch {
        Write-Host "  X Failed to remove team: $($_.Exception.Message)" -ForegroundColor Red
        $errorCount++
        Write-Host ""
        continue
    }

    # ── Step 2: Permanently purge M365 group from Entra ID recycle bin ─────────

    if ($PermanentlyDelete) {
        # Give Entra a short head start before first purge attempt.
        Start-Sleep -Seconds 10

        $purged = $false
        $purgeFailureRecorded = $false
        for ($attempt = 1; $attempt -le $purgeMaxAttempts; $attempt++) {
            try {
                Remove-MgDirectoryDeletedItem -DirectoryObjectId $team.GroupId -ErrorAction Stop
                Write-Host "  - M365 group permanently purged from Entra ID recycle bin." -ForegroundColor Green
                $purged = $true
                break
            }
            catch {
                $message = $_.Exception.Message
                $isRetryableNotFound = ($message -match 'Request_ResourceNotFound|NotFound|does not exist|queried reference-property objects are not present')

                if ($attempt -lt $purgeMaxAttempts -and $isRetryableNotFound) {
                    $delay = [int][Math]::Min($purgeInitialDelay * [Math]::Pow(2, $attempt - 1), $purgeMaxDelay)
                    Write-Host "  ! Purge not ready yet (attempt $attempt/$purgeMaxAttempts): $message" -ForegroundColor Yellow
                    Write-Host "    Waiting $delay seconds before retry..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $delay
                    continue
                }

                Write-Host "  X Failed to purge group from Entra recycle bin: $message" -ForegroundColor Red
                Write-Host "    Manual retry command:" -ForegroundColor Yellow
                Write-Host "    Remove-MgDirectoryDeletedItem -DirectoryObjectId $($team.GroupId)" -ForegroundColor Yellow
                $errorCount++
                $purgeFailureRecorded = $true
                break
            }
        }

        if (-not $purged -and -not $purgeFailureRecorded) {
            Write-Host "  X Failed to purge group from Entra recycle bin after $purgeMaxAttempts attempts." -ForegroundColor Red
            Write-Host "    Manual retry command:" -ForegroundColor Yellow
            Write-Host "    Remove-MgDirectoryDeletedItem -DirectoryObjectId $($team.GroupId)" -ForegroundColor Yellow
            $errorCount++
        }
    }

    # ── Step 3: Delete the associated SharePoint Online site ───────────────────

    if ($DeleteSharePointSite -and $sharePointUrl) {
        $spDeleted = $false
        for ($attempt = 1; $attempt -le $spDeleteMaxAttempts; $attempt++) {
            try {
                Remove-PnPTenantSite `
                    -Url            $sharePointUrl `
                    -SkipRecycleBin:$SkipRecycleBin `
                    -Force `
                    -ErrorAction    Stop
                $spMode = if ($SkipRecycleBin) { 'permanently' } else { 'into SP admin recycle bin' }
                Write-Host "  - SharePoint site removed ($spMode)." -ForegroundColor Green
                $spDeleted = $true
                break
            }
            catch {
                $message = $_.Exception.Message
                $isRetryableGroupBinding = ($message -match 'belongs to a Microsoft 365 group|must delete the group')
                $isAlreadyGone = ($message -match 'File Not Found|cannot find|does not exist|not found')

                if ($isAlreadyGone) {
                    Write-Host "  - SharePoint site '$sharePointUrl' is already deleted or no longer available." -ForegroundColor Green
                    $spDeleted = $true
                    break
                }

                if ($attempt -lt $spDeleteMaxAttempts -and $isRetryableGroupBinding) {
                    $stillGroupConnected = Test-SharePointSiteStillGroupConnected -Url $sharePointUrl -ExpectedGroupId $team.GroupId
                    $delay = [int][Math]::Min($spDeleteInitialDelay * [Math]::Pow(2, $attempt - 1), $spDeleteMaxDelay)
                    if ($stillGroupConnected) {
                        Write-Host "  ! SharePoint still reports the site as connected to GroupId $($team.GroupId) (attempt $attempt/$spDeleteMaxAttempts)." -ForegroundColor Yellow
                    }
                    else {
                        Write-Host "  ! SharePoint site deletion not ready yet (attempt $attempt/$spDeleteMaxAttempts): $message" -ForegroundColor Yellow
                    }
                    Write-Host "    Waiting $delay seconds before retry..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $delay
                    continue
                }

                Write-Host "  X Failed to remove SharePoint site '$sharePointUrl': $message" -ForegroundColor Red
                $errorCount++
                break
            }
        }

        if (-not $spDeleted) {
            Write-Host "  ! SharePoint site could not be deleted in this run. Retry command:" -ForegroundColor Yellow
            Write-Host "    Remove-PnPTenantSite -Url '$sharePointUrl' -SkipRecycleBin:$SkipRecycleBin -Force" -ForegroundColor Yellow
        }
    }

    Write-Host ""
}

# ── Summary ────────────────────────────────────────────────────────────────────

Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "  Removed : $successCount" -ForegroundColor Green
Write-Host "  Skipped : $skipCount"    -ForegroundColor Gray
Write-Host "  Errors  : $errorCount"   -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } else { 'Gray' })

if (-not $PermanentlyDelete -and $successCount -gt 0) {
    Write-Host ""
    Write-Host "NOTE: M365 groups are in the Entra ID recycle bin and can be restored for 30 days." -ForegroundColor Yellow
    Write-Host "      To permanently purge a group:" -ForegroundColor Yellow
    Write-Host "      Remove-MgDirectoryDeletedItem -DirectoryObjectId <GroupId>" -ForegroundColor Yellow
}

if ($DeleteSharePointSite -and -not $SkipRecycleBin -and $successCount -gt 0) {
    Write-Host ""
    Write-Host "NOTE: SharePoint sites are in the SP admin recycle bin and can be restored." -ForegroundColor Yellow
    Write-Host "      To permanently purge: Remove-PnPTenantRecycleBinItem -Url <url> -Force" -ForegroundColor Yellow
}

if ($errorCount -gt 0) {
    exit 1
}
