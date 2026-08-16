#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Safe'
    Category         = 'Safes'
    Action           = 'Add'
    Description      = 'Create a new CyberArk safe.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';                   Required = $true;  Description = 'Unique safe name (max 28 chars).' }
        @{ Column = 'Description';                Required = $false; Description = 'Safe description.' }
        @{ Column = 'Location';                   Required = $false; Description = 'Safe location path (default: \).' }
        @{ Column = 'ManagingCPM';               Required = $false; Description = 'CPM user managing this safe.' }
        @{ Column = 'NumberOfVersionsRetention';  Required = $false; Description = 'Password versions to retain (default: 5).' }
        @{ Column = 'NumberOfDaysRetention';      Required = $false; Description = 'Days to retain (0 = versions-based, default: 0).' }
        @{ Column = 'AutoPurgeEnabled';           Required = $false; Description = 'Auto-purge enabled: true/false (default: false).' }
        @{ Column = 'OLACEnabled';               Required = $false; Description = 'OLAC enabled: true/false (default: false).' }
    )
    Priority         = 12
    Version          = '1.0.0'
}

function Get-SafesAddInput {
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

    Write-Host '  New Safe Details  (press Enter to accept each default)' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Unique safe name (max 28 chars).'

    $description = Show-FieldPrompt -Label 'Description' `
        -Default $(if ($Defaults['Description']) { $Defaults['Description'] } else { '' }) `
        -Description 'Safe description.'

    $location = Show-FieldPrompt -Label 'Location' `
        -Default $(if ($Defaults['Location']) { $Defaults['Location'] } else { '\' }) `
        -Description 'Safe location path (default: \).'

    $managingCPM = Show-FieldPrompt -Label 'ManagingCPM' `
        -Default $(if ($Defaults['ManagingCPM']) { $Defaults['ManagingCPM'] } else { '' }) `
        -Description 'CPM user managing this safe.'

    $numberOfVersionsRetention = Show-FieldPrompt -Label 'NumberOfVersionsRetention' `
        -Default $(if ($Defaults['NumberOfVersionsRetention']) { $Defaults['NumberOfVersionsRetention'] } else { '5' }) `
        -Description 'Password versions to retain (default: 5).'

    $numberOfDaysRetention = Show-FieldPrompt -Label 'NumberOfDaysRetention' `
        -Default $(if ($Defaults['NumberOfDaysRetention']) { $Defaults['NumberOfDaysRetention'] } else { '0' }) `
        -Description 'Days to retain (0 = versions-based, default: 0).'

    $autoPurgeEnabled = Show-FieldPrompt -Label 'AutoPurgeEnabled' `
        -Default $(if ($Defaults['AutoPurgeEnabled']) { $Defaults['AutoPurgeEnabled'] } else { 'false' }) `
        -Description 'Auto-purge enabled? (true/false)'

    $olacEnabled = Show-FieldPrompt -Label 'OLACEnabled' `
        -Default $(if ($Defaults['OLACEnabled']) { $Defaults['OLACEnabled'] } else { 'false' }) `
        -Description 'OLAC enabled? (true/false)'

    return @{
        SafeName                  = $safeName
        Description               = $description
        Location                  = $location
        ManagingCPM              = $managingCPM
        NumberOfVersionsRetention = $numberOfVersionsRetention
        NumberOfDaysRetention     = $numberOfDaysRetention
        AutoPurgeEnabled          = $autoPurgeEnabled
        OLACEnabled              = $olacEnabled
    }
}

function Invoke-SafesAdd {
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

    # Validate required field SafeName
    $safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }
    if (-not $safeName) {
        $msg = 'SafeName is required and cannot be empty.'
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

    # Build request body
    $body = @{
        SafeName                  = $safeName
        Description               = if ($InputData.Description)               { $InputData.Description }               else { '' }
        Location                  = if ($InputData.Location)                  { $InputData.Location }                  else { '\' }
        ManagingCPM              = if ($InputData.ManagingCPM)              { $InputData.ManagingCPM }              else { '' }
        NumberOfVersionsRetention = if ($InputData.NumberOfVersionsRetention) { [int]$InputData.NumberOfVersionsRetention } else { 5 }
        NumberOfDaysRetention     = if ($InputData.NumberOfDaysRetention)     { [int]$InputData.NumberOfDaysRetention }     else { 0 }
        AutoPurgeEnabled          = ($InputData.AutoPurgeEnabled -match '^true$')
        OLACEnabled              = ($InputData.OLACEnabled -match '^true$')
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Adding safe '$safeName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Safes | SafeName='$safeName'"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "[WhatIf] Would POST /API/Safes for '$safeName'."
        $result.Results.Add([PSCustomObject]@{
            SafeName         = $safeName
            Description      = $body.Description
            Location         = $body.Location
            ManagingCPM      = $body.ManagingCPM
            VersionRetention = $body.NumberOfVersionsRetention
            DayRetention     = $body.NumberOfDaysRetention
            AutoPurge        = $body.AutoPurgeEnabled
            OLACEnabled      = $body.OLACEnabled
            Creator          = ''
            Created          = ''
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint '/API/Safes' `
        -Body     $body

    if (-not $response.IsSuccess) {
        $msg = "Add safe failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $response.ErrorMessage
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # Map result - WhatIf returns a synthetic success with no Data object
    $safe = if ($response.Data) { $response.Data } else { $null }

    $creationDate = if ($safe -and $safe.creationTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($safe.creationTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $result.Results.Add([PSCustomObject]@{
        SafeName         = if ($safe -and $safe.safeName)                   { $safe.safeName }                   else { $safeName }
        Description      = if ($safe -and $safe.description)                { $safe.description }                else { $body.Description }
        Location         = if ($safe -and $safe.location)                   { $safe.location }                   else { $body.Location }
        ManagingCPM      = if ($safe -and $safe.managingCPM)               { $safe.managingCPM }               else { $body.ManagingCPM }
        VersionRetention = if ($safe -and $safe.numberOfVersionsRetention)  { $safe.numberOfVersionsRetention }  else { $body.NumberOfVersionsRetention }
        DayRetention     = if ($safe -and $safe.numberOfDaysRetention)      { $safe.numberOfDaysRetention }      else { $body.NumberOfDaysRetention }
        AutoPurge        = if ($safe)                                        { $safe.autoPurgeEnabled }           else { $body.AutoPurgeEnabled }
        OLACEnabled      = if ($safe)                                        { $safe.olacEnabled }                else { $body.OLACEnabled }
        Creator          = if ($safe -and $safe.creator)                    { $safe.creator.name }               else { '' }
        Created          = $creationDate
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe '$safeName' created successfully."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
