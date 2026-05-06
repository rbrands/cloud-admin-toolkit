<#
.SYNOPSIS
    Checks whether anonymous join is allowed in the global Teams Meeting Policy.

.DESCRIPTION
    Retrieves the global Teams Meeting Policy and reports whether anonymous
    users are permitted to join meetings via the AllowAnonymousUsersToJoinMeeting
    setting.

    A value of $true means anonymous join is enabled – this may pose a
    security risk in regulated environments and should be reviewed.

    IMPORTANT: Run Connect-MicrosoftTeams before executing this script.

.EXAMPLE
    .\Check-TeamsMeetingPolicyAllowAnonymousJoin.ps1

.NOTES
    Required Teams permission:
      Teams Administrator  (or Global Reader / Global Administrator)

    Prerequisites:
      MicrosoftTeams module  (run .\shared\Install-Prerequisites.ps1)
      Connect-MicrosoftTeams must be called before running this script.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module MicrosoftTeams -ErrorAction Stop

Write-Host '=== Check-TeamsMeetingPolicyAllowAnonymousJoin ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Retrieving global Teams Meeting Policy...' -ForegroundColor Yellow

$policy = Get-CsTeamsMeetingPolicy -Identity Global

$allowAnonymous = $policy.AllowAnonymousUsersToJoinMeeting

Write-Host ''
Write-Host "Policy  : Global" -ForegroundColor Cyan
Write-Host "Setting : AllowAnonymousUsersToJoinMeeting = $allowAnonymous" -ForegroundColor $(if ($allowAnonymous) { 'Red' } else { 'Green' })
Write-Host ''

if ($allowAnonymous) {
    Write-Host 'WARNING: Anonymous join is ENABLED in the global meeting policy.' -ForegroundColor Red
    Write-Host '         Anonymous users can join meetings without authentication.' -ForegroundColor Red
    Write-Host '         Consider disabling this setting if not required:' -ForegroundColor Yellow
    Write-Host '         Set-CsTeamsMeetingPolicy -Identity Global -AllowAnonymousUsersToJoinMeeting $false' -ForegroundColor Yellow
}
else {
    Write-Host 'OK: Anonymous join is DISABLED in the global meeting policy.' -ForegroundColor Green
}
