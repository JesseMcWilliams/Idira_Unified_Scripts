#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Platforms'
    Category         = 'Platforms'
    Action           = 'List'
    Description      = 'Retrieve all available CyberArk platforms.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    Priority         = 40
    Version          = '1.0.0'
}

function Get-PlatformsListInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt is available because this module is dot-sourced into the driver scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Search Criteria  (press Enter to skip each field)' -ForegroundColor DarkGray
    Write-Host ''

    $search = Show-FieldPrompt -Label 'Search' `
        -Default $(if ($Defaults['Search']) { $Defaults['Search'] } else { '' }) `
        -Description 'Free-text search across platform name and description. Leave blank for all platforms.'

    $activeOnlyStr = Show-FieldPrompt -Label 'Active Only' `
        -Default $(if ($Defaults['ActiveOnly']) { 'Y' } else { 'N' }) `
        -Description 'Return only active platforms? (Y/N)'

    return @{
        Search     = $search
        ActiveOnly = ($activeOnlyStr -match '^[Yy]$')
    }
}

function Invoke-PlatformsList {
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

    $search     = if ($InputData['Search'])     { "$($InputData['Search'])".Trim() } else { $null }
    $activeOnly = [bool]$InputData['ActiveOnly']

    # Build query parameters — only include keys that have a value
    $queryParams = @{}
    if ($search)     { $queryParams['Search'] = $search  }
    if ($activeOnly) { $queryParams['Active'] = 'true'   }

    $criteriaLog = $(
        $parts = @()
        if ($search)     { $parts += "Search='$search'" }
        if ($activeOnly) { $parts += 'Active=true' }
        if ($parts)      { $parts -join '  ' } else { '(all platforms)' }
    )

    Write-CyberArkLog -Level 'INFO'  -Message 'Starting platform list retrieval.'
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Platforms | $criteriaLog"

    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/Platforms' `
        -QueryParams $queryParams `
        -WhatIf:     $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Platform list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Platforms API uses 'Platforms' property, not 'value'
    $platforms = if ($response.Data -and $response.Data.PSObject.Properties['Platforms']) {
        @($response.Data.Platforms)
    } else { @() }

    if ((-not $platforms) -or $platforms.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No platforms returned for the given criteria.'
        # Not a failure — a valid empty result
        return $result
    }

    foreach ($platform in $platforms) {
        $result.Results.Add([PSCustomObject]@{
            PlatformID   = $platform.id
            Name         = $platform.name
            Description  = $platform.description
            Active       = $platform.active
            PlatformType = $platform.platformType
        })
        $result.Successes++
        $result.ItemsProcessed++
    }

    Write-CyberArkLog -Level 'INFO' -Message "Platform list complete. Platforms retrieved: $($result.Successes)."
    return $result
}
