#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Application Authentication Methods'
    Category         = 'Applications'
    Action           = 'ListAuthMethods'
    Description      = 'Retrieve all authentication methods configured for a CyberArk application. Self-Hosted only.'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AppID'; Required = $true; Description = 'Application ID, or leave blank to search.' }
    )
    Priority         = 89
    Version          = '1.0.0'
}

function Get-ApplicationsListAuthMethodsInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  List Application Authentication Methods' -ForegroundColor DarkGray
    Write-Host ''

    $appId = Show-FieldPrompt -Label 'App ID' `
        -Default $(if ($Defaults['AppID']) { $Defaults['AppID'] } else { '' }) `
        -Description 'Application ID, or leave blank to search by name.'

    if (-not $appId) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Partial Application ID to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $appId = Invoke-EntitySearch -Token $Token `
                -Endpoint           '/WebServices/PIMServices.svc/Applications/' `
                -SearchTerm         $searchTerm `
                -SearchParam        'AppID' `
                -ResponseProperty   'application' `
                -IdProperty         'AppID' `
                -DisplayProperties  @('AppID', 'Description', 'Location') `
                -EntityLabel        'application' `
                -IgnoreSSL          $ignoreSSL
        }
        if (-not $appId) { return $null }
    }

    return @{ AppID = $appId }
}

function Invoke-ApplicationsListAuthMethods {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$InputData,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $result = [PSCustomObject]@{
        ModuleName     = $ModuleMeta.Name
        Category       = $ModuleMeta.Category
        Action         = $ModuleMeta.Action
        ItemsProcessed = 0
        Successes      = 0
        Failures       = 0
        IsFatal        = $false
        Results        = [System.Collections.Generic.List[PSCustomObject]]::new()
        Errors         = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    if (-not $InputData) { $InputData = @{} }

    $appId = if ($InputData['AppID']) { "$($InputData['AppID'])".Trim() } else { '' }

    if (-not $appId) {
        $msg = 'Invoke-ApplicationsListAuthMethods: AppID is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'AppID is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $encodedId = [Uri]::EscapeDataString($appId)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting auth methods retrieval for App ID: $appId"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /WebServices/PIMServices.svc/Applications/$appId/Authentications"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/WebServices/PIMServices.svc/Applications/$encodedId/Authentications/" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "List Auth Methods failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $response.ErrorMessage
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        return $result
    }

    # Response: { "authentication": [ {...}, ... ] }
    $auths = @()
    if ($response.Data -and $response.Data.PSObject.Properties['authentication']) {
        $raw = $response.Data.authentication
        if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) {
            $auths = @($raw)
        } elseif ($raw) {
            $auths = @($raw)
        }
    }

    if ($auths.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message "No authentication methods found for App ID: $appId"
        return $result
    }

    foreach ($auth in $auths) {
        try {
            $result.Results.Add([PSCustomObject]@{
                AppID                = $appId
                AuthID               = if ($auth.PSObject.Properties['authID'])               { $auth.authID }               else { '' }
                AuthType             = if ($auth.PSObject.Properties['authType'])              { $auth.authType }             else { '' }
                AuthValue            = if ($auth.PSObject.Properties['authValue'])             { $auth.authValue }            else { '' }
                IsFolder             = if ($auth.PSObject.Properties['isFolder'])              { $auth.isFolder }             else { $false }
                AllowInternalScripts = if ($auth.PSObject.Properties['allowInternalScripts'])  { $auth.allowInternalScripts } else { $false }
                Comment              = if ($auth.PSObject.Properties['comment'])               { $auth.comment }              else { '' }
            })
            $result.Successes++
            $result.ItemsProcessed++
        } catch {
            $authId = try { "$($auth.authID)" } catch { '(unknown)' }
            $msg = "Unexpected error mapping auth method '$authId': $_"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = $InputData
                ErrorMessage = $msg
                ErrorDetails = $null
            })
            $result.Failures++
            $result.ItemsProcessed++
        }
    }

    Write-CyberArkLog -Level 'INFO' -Message "List Auth Methods complete for App ID: $appId. Methods retrieved: $($result.Successes)."
    return $result
}
