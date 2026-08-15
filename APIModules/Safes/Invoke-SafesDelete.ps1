#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Delete Safe'
    Category         = 'Safes'
    Action           = 'Delete'
    Description      = 'Permanently delete an existing safe and all its contents.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName'; Required = $true; Description = 'Name of the safe to delete.' }
    )
    Priority         = 14
    Version          = '1.0.0'
}

function Get-SafesDeleteInput {
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

    Write-Host '  Safe to Delete' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  WARNING: This operation permanently deletes the safe and all its accounts.' -ForegroundColor Red
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults.SafeName) { $Defaults.SafeName } else { '' }) `
        -Required $true `
        -Description 'Name of the safe to delete.'

    return @{
        SafeName = $safeName
    }
}

function Invoke-SafesDelete {
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

    # Validate InputData presence
    if (-not $InputData) {
        $msg = 'InputData is null or missing. SafeName is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # Validate SafeName
    $safeName = if ($InputData.SafeName) { "$($InputData.SafeName)".Trim() } else { '' }

    if (-not $safeName) {
        $msg = 'SafeName is required and must not be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $encodedSafeName = [Uri]::EscapeDataString($safeName)
    $endpoint        = "/API/Safes/$encodedSafeName"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting safe delete. SafeName='$safeName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "DELETE $endpoint"

    $response = Invoke-CyberArkAPI `
        -Token   $Token `
        -Method  'DELETE' `
        -Endpoint $endpoint `
        -WhatIf: $WhatIf.IsPresent

    # WhatIf: API returns without executing; log and count as success
    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: DELETE $endpoint would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        return $result
    }

    if (-not $response.IsSuccess) {
        $msg = "Safe delete failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Success — 204 No Content or 200 OK
    $result.Results.Add([PSCustomObject]@{
        SafeName = $safeName
        Deleted  = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe delete complete. SafeName='$safeName'."

    Add-CyberArkLogSummaryEntry `
        -ModuleName $ModuleMeta.Name `
        -Successes  $result.Successes `
        -Failures   $result.Failures

    return $result
}
