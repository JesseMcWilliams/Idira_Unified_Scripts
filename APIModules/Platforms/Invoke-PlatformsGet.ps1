#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Platform'
    Category         = 'Platforms'
    Action           = 'Get'
    Description      = 'Retrieve details of a single platform by ID.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'PlatformID'; Required = $true; Description = 'Platform ID (e.g. WinServerLocal).' }
    )
    Priority         = 41
    Version          = '1.0.0'
}

function Get-PlatformsGetInput {
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

    $platformID = Show-FieldPrompt -Label 'Platform ID' `
        -Default $(if ($Defaults['PlatformID']) { $Defaults['PlatformID'] } else { '' }) `
        -Description 'Platform ID (e.g. WinServerLocal), or leave blank to search by name.'

    if (-not $platformID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Platform name to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $platformID = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Platforms' `
                -SearchTerm $searchTerm `
                -SearchParam 'Search' `
                -ResponseProperty 'Platforms' `
                -IdProperty 'id' `
                -DisplayProperties @('id', 'name', 'description') `
                -EntityLabel 'platform' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $platformID) { return $null }
    }

    return @{
        PlatformID = $platformID
    }
}

function Invoke-PlatformsGet {
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

    $platformID = if ($InputData['PlatformID']) { "$($InputData['PlatformID'])".Trim() } else { '' }

    if (-not $platformID) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-PlatformsGet: PlatformID is required but was not provided.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'PlatformID is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.IsFatal = $false
        return $result
    }

    $encodedPlatformID = [Uri]::EscapeDataString($platformID)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting platform retrieval for: $platformID"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Platforms/$encodedPlatformID"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Platforms/$encodedPlatformID" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Platform get failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $platform = $response.Data

    # CyberArk v12+ nests platform detail inside 'general'; single-GET may have fields at root level.
    # Check both the 'general' sub-object and the root object so either response shape works.
    $gen = if ($platform.PSObject.Properties['general'] -and $platform.general) { $platform.general } else { $platform }
    $result.Results.Add([PSCustomObject]@{
        PlatformID   = if ($gen.PSObject.Properties['id'])              { $gen.id              }
                       elseif ($platform.PSObject.Properties['id'])     { $platform.id         } else { '' }
        Name         = if ($gen.PSObject.Properties['name'])            { $gen.name            }
                       elseif ($platform.PSObject.Properties['name'])   { $platform.name       } else { '' }
        Description  = if ($gen.PSObject.Properties['description'])     { $gen.description     }
                       elseif ($platform.PSObject.Properties['description']) { $platform.description } else { '' }
        Active       = if ($gen.PSObject.Properties['active'])          { $gen.active          }
                       elseif ($platform.PSObject.Properties['active']) { $platform.active     } else { $false }
        PlatformType = if ($gen.PSObject.Properties['platformType'])    { $gen.platformType    }
                       elseif ($platform.PSObject.Properties['platformType']) { $platform.platformType } else { '' }
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Platform get complete. Platform retrieved: $platformID."
    return $result
}
