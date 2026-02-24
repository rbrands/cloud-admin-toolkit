<#
.SYNOPSIS
    Shared config-loading helpers for AzToolkit scripts.

.DESCRIPTION
    Provides three exported functions:

    Resolve-ToolkitConfigPath
        Resolves the path to a JSON config file either from an explicit path
        or by convention: <Prefix>.<Name>.json in a given directory.
        Use -ConfigDir to point to a subdirectory (defaults to the calling
        script's $PSScriptRoot).

    Read-ToolkitJsonConfig
        Reads and parses a JSON config file. Returns $null when no path is given.

    Set-ToolkitAzContext
        Sets the Azure subscription context from a config object or an
        explicit subscription ID.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ToolkitConfigPath {
    <#
    .SYNOPSIS
        Resolves the path to a JSON config file.

    .PARAMETER ExplicitPath
        Directly specified path to a JSON file.

    .PARAMETER Name
        Config name. The file <Prefix>.<Name>.json is searched in ScriptRoot.

    .PARAMETER ConfigDir
        Directory where the config file must be located. Scripts pass their
        own $PSScriptRoot, so the config file is expected in the same directory
        as the script. Override only when config files live elsewhere.

    .PARAMETER Prefix
        Filename prefix used together with -Name (e.g. 'Connect-AzToolkit').
        Defaults to 'config'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()] [string]$ExplicitPath,
        [Parameter()] [string]$Name,
        [Parameter()] [string]$ConfigDir,
        [Parameter()] [string]$Prefix = 'config'
    )

    if ($ExplicitPath) {
        return $ExplicitPath
    }

    if ($Name) {
        $root        = if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }
        $fileName    = "$Prefix.$Name.json"
        $resolvedPath = Join-Path $root $fileName

        if (-not (Test-Path $resolvedPath)) {
            throw "Config file not found: $resolvedPath"
        }

        return $resolvedPath
    }

    return $null
}

function Read-ToolkitJsonConfig {
    <#
    .SYNOPSIS
        Reads and parses a JSON config file.

    .PARAMETER Path
        Absolute path to a UTF-8 encoded JSON file. Returns $null when empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$Path
    )

    if (-not $Path) { return $null }

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
               ConvertFrom-Json -Depth 50
    }
    catch {
        throw "Failed to parse JSON config '$Path': $($_.Exception.Message)"
    }
}

function Set-ToolkitAzContext {
    <#
    .SYNOPSIS
        Sets the Azure subscription context from a toolkit config object.

    .DESCRIPTION
        Reads config.context.subscriptionId (or the alias defaultSubscriptionId)
        and calls Set-AzContext. Overwrites the value with an explicit
        -SubscriptionId parameter when provided.

        Does nothing if neither the config nor the parameter contains a
        subscription ID.

    .PARAMETER Config
        Parsed JSON config object (output of Read-ToolkitJsonConfig).

    .PARAMETER SubscriptionId
        Explicit subscription ID. Takes precedence over the config value.

    .OUTPUTS
        Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [object]$Config,
        [Parameter()] [string]$SubscriptionId
    )

    # Resolve subscription ID: parameter wins, then config.context.subscriptionId,
    # then legacy alias config.context.defaultSubscriptionId
    if (-not $SubscriptionId -and $null -ne $Config) {
        $ctxValue = $Config.PSObject.Properties['context']?.Value
        if ($null -ne $ctxValue) {
            $SubscriptionId = $ctxValue.PSObject.Properties['subscriptionId']?.Value
            if (-not $SubscriptionId) {
                $SubscriptionId = $ctxValue.PSObject.Properties['defaultSubscriptionId']?.Value
            }
        }
    }

    if (-not $SubscriptionId) {
        Write-Verbose 'Set-ToolkitAzContext: no subscription ID provided, skipping.'
        return $null
    }

    $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    return Get-AzContext
}

Export-ModuleMember -Function Resolve-ToolkitConfigPath, Read-ToolkitJsonConfig, Set-ToolkitAzContext
