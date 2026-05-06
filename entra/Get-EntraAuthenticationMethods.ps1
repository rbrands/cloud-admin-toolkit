<#
.SYNOPSIS
    Lists all configured Authentication Methods in the Entra ID tenant.

.DESCRIPTION
    Retrieves all Authentication Method policies from Microsoft Graph and
    displays each method with its enabled state and (where available) the
    list of included/excluded groups.

    EmailOTP (Email one-time passcode) is highlighted explicitly because
    it is REQUIRED for external guests when anonymous meeting join is
    disabled (AllowAnonymousUsersToJoinMeeting = $false). Without EmailOTP
    enabled, guests without an Entra ID account cannot authenticate and
    will be unable to join meetings.

    IMPORTANT: Run Connect-MgGraph with the required scope before executing
    this script.

.EXAMPLE
    .\Get-EntraAuthenticationMethods.ps1

.NOTES
    Required Microsoft Graph scope:
      Policy.Read.All

    Prerequisites:
      Microsoft.Graph.Authentication module
      (run .\shared\Install-Prerequisites.ps1)
      Connect-MgGraph -Scopes 'Policy.Read.All' must be called before
      running this script.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '=== Get-EntraAuthenticationMethods ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Retrieving authentication method policies...' -ForegroundColor Yellow

$response = Invoke-MgGraphRequest -Method GET `
    -Uri 'https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy' `
    -OutputType PSObject

$methods = $response.authenticationMethodConfigurations

if (-not $methods -or $methods.Count -eq 0) {
    Write-Host 'No authentication method configurations found.' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host ('Found {0} authentication method(s):' -f $methods.Count) -ForegroundColor Cyan
Write-Host ''

$emailOtpEnabled = $false

foreach ($method in ($methods | Sort-Object -Property '@odata.type')) {
    $type    = $method.'@odata.type' -replace '#microsoft.graph.', ''
    $state   = $method.state          # 'enabled' or 'disabled'
    $isEmail = $type -eq 'emailAuthenticationMethodConfiguration'

    $stateColor = if ($state -eq 'enabled') { 'Green' } else { 'DarkGray' }

    if ($isEmail -and $state -ne 'enabled') {
        $stateColor = 'Red'
    }

    if ($isEmail -and $state -eq 'enabled') {
        $emailOtpEnabled = $true
        # EmailOTP enabled is desired when anonymous join is disabled – keep Green
    }

    Write-Host ("  {0,-55} State: " -f $type) -NoNewline -ForegroundColor $(if ($isEmail) { 'White' } else { 'Gray' })
    Write-Host $state -ForegroundColor $stateColor

    # Show include/exclude targets if present
    if ($method.includeTargets -and $method.includeTargets.Count -gt 0) {
        foreach ($target in $method.includeTargets) {
            $targetId = $target.id ?? '(all users)'
            Write-Host ("    Include: {0}  (type: {1})" -f $targetId, $target.targetType) -ForegroundColor DarkGray
        }
    }
    if ($method.excludeTargets -and $method.excludeTargets.Count -gt 0) {
        foreach ($target in $method.excludeTargets) {
            Write-Host ("    Exclude: {0}  (type: {1})" -f $target.id, $target.targetType) -ForegroundColor DarkGray
        }
    }
}

Write-Host ''

if ($emailOtpEnabled) {
    Write-Host 'OK: EmailOTP (emailAuthenticationMethodConfiguration) is ENABLED.' -ForegroundColor Green
    Write-Host '    External guests without an Entra ID account can authenticate via' -ForegroundColor Green
    Write-Host '    one-time passcode. Required when anonymous meeting join is disabled.' -ForegroundColor Green
}
else {
    Write-Host 'WARNING: EmailOTP (emailAuthenticationMethodConfiguration) is DISABLED.' -ForegroundColor Yellow
    Write-Host '         External guests without an Entra ID account cannot authenticate.' -ForegroundColor Yellow
    Write-Host '         If anonymous meeting join is disabled, those guests will be' -ForegroundColor Yellow
    Write-Host '         unable to join meetings. Enable EmailOTP to allow guest access:' -ForegroundColor Yellow
    Write-Host '         Update-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration' -ForegroundColor Yellow
    Write-Host '           -AuthenticationMethodConfigurationId emailOtp -State enabled' -ForegroundColor Yellow
}
