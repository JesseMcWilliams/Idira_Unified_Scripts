#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Safe'
    Category         = 'Safes'
    Action           = 'Get'
    Description      = 'Retrieve details of a single safe by name.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName'; Required = $true; Description = 'Name of the safe to retrieve.' }
    )
    Priority         = 11
    Version          = '1.0.0'
}

function Get-SafesGetInput {
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

    $safeName = Show-FieldPrompt -Label 'Safe Name' `
        -Default $(if ($Defaults.SafeName) { $Defaults.SafeName } else { '' }) `
        -Required $true `
        -Description 'Name of the safe to retrieve.'

    return @{
        SafeName = $safeName
    }
}

function Invoke-SafesGet {
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

    $safeName = if ($InputData.SafeName) { "$($InputData.SafeName)".Trim() } else { '' }

    if (-not $safeName) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-SafesGet: SafeName is required but was not provided.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'SafeName is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.IsFatal = $false
        return $result
    }

    $encodedSafeName = [Uri]::EscapeDataString($safeName)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting safe retrieval for: $safeName"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedSafeName"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Safes/$encodedSafeName" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Safe get failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $safe = $response.Data

    $creationDate = if ($safe.creationTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($safe.creationTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $result.Results.Add([PSCustomObject]@{
        SafeName         = $safe.safeName
        Description      = $safe.description
        Location         = $safe.location
        ManagingCPM      = $safe.managingCPM
        VersionRetention = $safe.numberOfVersionsRetention
        DayRetention     = $safe.numberOfDaysRetention
        AutoPurge        = $safe.autoPurgeEnabled
        OLACEnabled      = $safe.olacEnabled
        Creator          = if ($safe.creator) { $safe.creator.name } else { '' }
        Created          = $creationDate
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe get complete. Safe retrieved: $safeName."
    return $result
}
