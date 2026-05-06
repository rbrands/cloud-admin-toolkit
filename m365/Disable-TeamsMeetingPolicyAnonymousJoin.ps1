<#
.SYNOPSIS
    Disables anonymous join in the global Teams Meeting Policy.

.DESCRIPTION
    Sets AllowAnonymousUsersToJoinMeeting to $false in the global Teams
    Meeting Policy, preventing unauthenticated users from joining meetings.

    The script first reads the current value and skips the change if
    anonymous join is already disabled (idempotent).

    Supports -WhatIf to preview the change without applying it.

    IMPORTANT: Run Connect-MicrosoftTeams before executing this script.

.EXAMPLE
    .\Disable-TeamsMeetingPolicyAnonymousJoin.ps1

.EXAMPLE
    .\Disable-TeamsMeetingPolicyAnonymousJoin.ps1 -WhatIf

.NOTES
    Required Teams permission:
      Teams Administrator  (or Global Administrator)

    Prerequisites:
      MicrosoftTeams module  (run .\shared\Install-Prerequisites.ps1)
      Connect-MicrosoftTeams must be called before running this script.
#>

[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module MicrosoftTeams -ErrorAction Stop

Write-Host '=== Disable-TeamsMeetingPolicyAnonymousJoin ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Retrieving global Teams Meeting Policy...' -ForegroundColor Yellow

$policy = Get-CsTeamsMeetingPolicy -Identity Global

$allowAnonymous = $policy.AllowAnonymousUsersToJoinMeeting

Write-Host ''
Write-Host "Current value: AllowAnonymousUsersToJoinMeeting = $allowAnonymous" -ForegroundColor $(if ($allowAnonymous) { 'Red' } else { 'Green' })
Write-Host ''

if (-not $allowAnonymous) {
    Write-Host 'OK: Anonymous join is already disabled. No change required.' -ForegroundColor Green
    return
}

if ($PSCmdlet.ShouldProcess('Global Teams Meeting Policy', 'Set AllowAnonymousUsersToJoinMeeting = $false')) {
    Write-Host 'Disabling anonymous join in the global meeting policy...' -ForegroundColor Yellow
    Set-CsTeamsMeetingPolicy -Identity Global -AllowAnonymousUsersToJoinMeeting $false
    Write-Host 'Done: Anonymous join has been DISABLED.' -ForegroundColor Green
}
