#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Assign CPM to Safe'
    Category         = 'Safes'
    Action           = 'AssignCPM'
    Description      = 'Assign a CPM to manage an existing safe.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';    Required = $true; Description = 'Name of the safe to assign a CPM to.' }
        @{ Column = 'ManagingCPM'; Required = $true; Description = 'CPM username to assign. CSV/bulk input only - interactive mode shows a picker.' }
    )
    Priority         = 16
    Version          = '1.0.0'
}

function script:Get-SafesCPMOptions {
    <#
        Returns candidate CPM usernames for the interactive Assign CPM picker, queried from
        GET /API/Users?userType=CPM&componentUser=true. Confirmed against
        Swagger\CyberArk_PasswordVault_Swagger_14.6.v1.json: /api/Users documents both userType
        and componentUser as server-side query filters, and "CPM" is listed as one of the
        userType values considered a component user. Falls back to an empty list (picker
        skipped, free-text entry only) if the API call fails, errors, or returns nothing - it
        never blocks the Assign CPM flow.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token
    )

    $options = [System.Collections.Generic.List[string]]::new()

    try {
        $response = Invoke-CyberArkAPI `
            -Token       $Token `
            -Method      'GET' `
            -Endpoint    '/API/Users' `
            -QueryParams @{ userType = 'CPM'; componentUser = 'true' }
    } catch {
        Write-CyberArkLog -Level 'WARN' -Message "CPM user list query threw an exception: $_"
        return $options.ToArray()
    }

    if (-not $response.IsSuccess) {
        Write-CyberArkLog -Level 'WARN' -Message "CPM user list query failed (HTTP $($response.StatusCode)): $($response.ErrorMessage). Falling back to manual entry."
        return $options.ToArray()
    }

    [array]$users = if ($response.Data -and $response.Data.PSObject.Properties['Users']) {
        @($response.Data.Users)
    } else { @() }

    foreach ($user in $users) {
        if ($user.username) { $options.Add("$($user.username)") }
    }

    return $options.ToArray()
}

function Get-SafesAssignCPMInput {
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

    Write-Host '  Assign CPM to Safe' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Name of the safe to assign a CPM to.'

    # Wrap in @() - a single-item return would otherwise unwrap to a bare string on capture,
    # which has no .Count under PS 5.1 strict mode.
    [array]$cpmOptions = @(script:Get-SafesCPMOptions -Token $Token)

    $manualEntryIndex = $cpmOptions.Count + 1

    if ($cpmOptions.Count -gt 0) {
        Write-Host '  Available CPMs:' -ForegroundColor DarkGray
        for ($i = 0; $i -lt $cpmOptions.Count; $i++) {
            Write-Host "    $($i + 1) = $($cpmOptions[$i])"
        }
        Write-Host "    $manualEntryIndex = (enter manually)"
        Write-Host ''

        $defaultIndex = $manualEntryIndex
        if ($Defaults['ManagingCPM']) {
            for ($i = 0; $i -lt $cpmOptions.Count; $i++) {
                if ($cpmOptions[$i] -eq $Defaults['ManagingCPM']) { $defaultIndex = $i + 1; break }
            }
        }

        $choice = Read-Host "  Select CPM (1-$manualEntryIndex, default=$defaultIndex)"
        $index  = $defaultIndex
        $parsed = 0
        if ($choice -and [int]::TryParse($choice, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $manualEntryIndex) {
            $index = $parsed
        }

        $managingCPM = if ($index -le $cpmOptions.Count) {
            $cpmOptions[$index - 1]
        } else {
            Show-FieldPrompt -Label 'ManagingCPM' `
                -Default $(if ($Defaults['ManagingCPM']) { $Defaults['ManagingCPM'] } else { '' }) `
                -Required $true `
                -Description 'CPM username to assign to this safe.'
        }
    } else {
        Write-Host '  (Could not retrieve a CPM list - enter the username manually)' -ForegroundColor DarkGray
        $managingCPM = Show-FieldPrompt -Label 'ManagingCPM' `
            -Default $(if ($Defaults['ManagingCPM']) { $Defaults['ManagingCPM'] } else { '' }) `
            -Required $true `
            -Description 'CPM username to assign to this safe.'
    }

    return @{
        SafeName    = $safeName
        ManagingCPM = $managingCPM
    }
}

function Invoke-SafesAssignCPM {
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

    if (-not $InputData) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-SafesAssignCPM: InputData is null or missing.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $null
            ErrorMessage = 'InputData is null or missing.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $safeName    = if ($InputData.SafeName)    { "$($InputData.SafeName)".Trim() }    else { '' }
    $managingCPM = if ($InputData.ManagingCPM) { "$($InputData.ManagingCPM)".Trim() } else { '' }

    if (-not $safeName) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-SafesAssignCPM: SafeName is required but was empty.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'SafeName is required but was empty.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if (-not $managingCPM) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-SafesAssignCPM: ManagingCPM is required but was empty.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'ManagingCPM is required but was empty.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $encodedSafeName = [Uri]::EscapeDataString($safeName)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting CPM assignment for safe '$safeName': ManagingCPM='$managingCPM'."
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedSafeName"

    # GET current safe - the Safes API PUT is a full replace, so every other field must be
    # carried forward unchanged. Same pattern as Invoke-SafesUpdate.ps1.
    $getResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Safes/$encodedSafeName"

    if (-not $getResponse.IsSuccess) {
        $msg = "Failed to retrieve safe '$safeName' before CPM assignment (HTTP $($getResponse.StatusCode)): $($getResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $getResponse.ErrorMessage
            ErrorDetails = $getResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($getResponse.StatusCode -in @(401, 0))
        return $result
    }

    $currentSafe = $getResponse.Data

    $body = @{
        Description      = if ($currentSafe.description) { $currentSafe.description } else { '' }
        Location         = if ($currentSafe.location)     { $currentSafe.location }     else { '' }
        ManagingCPM      = $managingCPM
        AutoPurgeEnabled = [bool]$currentSafe.autoPurgeEnabled
    }
    if ([int]$currentSafe.numberOfDaysRetention -gt 0) {
        $body['NumberOfDaysRetention'] = [int]$currentSafe.numberOfDaysRetention
    } else {
        $body['NumberOfVersionsRetention'] = [int]$currentSafe.numberOfVersionsRetention
    }

    Write-CyberArkLog -Level 'DEBUG' -Message "PUT /API/Safes/$encodedSafeName"

    $putResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'PUT' `
        -Endpoint "/API/Safes/$encodedSafeName" `
        -Body     $body `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $putResponse.IsSuccess) {
        $msg = "CPM assignment failed for '$safeName' (HTTP $($putResponse.StatusCode)): $($putResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $putResponse.ErrorMessage
            ErrorDetails = $putResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($putResponse.StatusCode -in @(401, 0))
        return $result
    }

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: CPM assignment suppressed for '$safeName'."
        $result.Results.Add([PSCustomObject]@{
            SafeName    = $safeName
            ManagingCPM = $managingCPM
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $updatedSafe = $putResponse.Data

    $result.Results.Add([PSCustomObject]@{
        SafeName    = if ($updatedSafe -and $updatedSafe.safeName)    { $updatedSafe.safeName }    else { $safeName }
        ManagingCPM = if ($updatedSafe -and $updatedSafe.managingCPM) { $updatedSafe.managingCPM } else { $managingCPM }
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "CPM assignment complete for '$safeName': ManagingCPM='$managingCPM'."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
