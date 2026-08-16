#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Application'
    Category         = 'Applications'
    Action           = 'Add'
    Description      = 'Create a new CyberArk application. Self-Hosted only.'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AppID';               Required = $true;  Description = 'Unique Application ID.' }
        @{ Column = 'Description';         Required = $false; Description = 'Application description.' }
        @{ Column = 'Location';            Required = $false; Description = 'Location in the vault (e.g. \Applications).' }
        @{ Column = 'AccessPermittedFrom'; Required = $false; Description = 'Start hour for permitted access (0-23).' }
        @{ Column = 'AccessPermittedTo';   Required = $false; Description = 'End hour for permitted access (0-23).' }
        @{ Column = 'ExpirationDate';      Required = $false; Description = 'Expiration date in MM/DD/YYYY format.' }
        @{ Column = 'Disabled';            Required = $false; Description = 'Set to true to create the application as disabled.' }
        @{ Column = 'BusinessOwnerFName';  Required = $false; Description = 'Business owner first name.' }
        @{ Column = 'BusinessOwnerLName';  Required = $false; Description = 'Business owner last name.' }
        @{ Column = 'BusinessOwnerEmail';  Required = $false; Description = 'Business owner email.' }
        @{ Column = 'BusinessOwnerPhone';  Required = $false; Description = 'Business owner phone.' }
    )
    Priority         = 87
    Version          = '1.0.0'
}

function Get-ApplicationsAddInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Add Application  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $appId = Show-FieldPrompt -Label 'App ID' `
        -Default $(if ($Defaults['AppID']) { $Defaults['AppID'] } else { '' }) `
        -Required $true `
        -Description 'Unique Application ID (required).'

    $description = Show-FieldPrompt -Label 'Description' `
        -Default $(if ($Defaults['Description']) { $Defaults['Description'] } else { '' }) `
        -Description 'Application description.'

    $location = Show-FieldPrompt -Label 'Location' `
        -Default $(if ($Defaults['Location']) { $Defaults['Location'] } else { '' }) `
        -Description 'Vault location (e.g. \Applications). Leave blank for root.'

    $accessFrom = Show-FieldPrompt -Label 'Access Permitted From' `
        -Default $(if ($Defaults['AccessPermittedFrom']) { $Defaults['AccessPermittedFrom'] } else { '' }) `
        -Description 'Start hour for permitted access (0-23). Leave blank for unrestricted.'

    $accessTo = Show-FieldPrompt -Label 'Access Permitted To' `
        -Default $(if ($Defaults['AccessPermittedTo']) { $Defaults['AccessPermittedTo'] } else { '' }) `
        -Description 'End hour for permitted access (0-23). Leave blank for unrestricted.'

    $expirationDate = Show-FieldPrompt -Label 'Expiration Date' `
        -Default $(if ($Defaults['ExpirationDate']) { $Defaults['ExpirationDate'] } else { '' }) `
        -Description 'Expiration date (MM/DD/YYYY). Leave blank for no expiration.'

    $disabledStr = Show-FieldPrompt -Label 'Disabled' `
        -Default $(if ($Defaults['Disabled']) { 'Y' } else { 'N' }) `
        -Description 'Create application as disabled? (Y/N)'

    $ownerFName = Show-FieldPrompt -Label 'Owner First Name' `
        -Default $(if ($Defaults['BusinessOwnerFName']) { $Defaults['BusinessOwnerFName'] } else { '' }) `
        -Description 'Business owner first name.'

    $ownerLName = Show-FieldPrompt -Label 'Owner Last Name' `
        -Default $(if ($Defaults['BusinessOwnerLName']) { $Defaults['BusinessOwnerLName'] } else { '' }) `
        -Description 'Business owner last name.'

    $ownerEmail = Show-FieldPrompt -Label 'Owner Email' `
        -Default $(if ($Defaults['BusinessOwnerEmail']) { $Defaults['BusinessOwnerEmail'] } else { '' }) `
        -Description 'Business owner email address.'

    $ownerPhone = Show-FieldPrompt -Label 'Owner Phone' `
        -Default $(if ($Defaults['BusinessOwnerPhone']) { $Defaults['BusinessOwnerPhone'] } else { '' }) `
        -Description 'Business owner phone number.'

    return @{
        AppID               = $appId
        Description         = $description
        Location            = $location
        AccessPermittedFrom = $accessFrom
        AccessPermittedTo   = $accessTo
        ExpirationDate      = $expirationDate
        Disabled            = ($disabledStr -match '^[Yy]$')
        BusinessOwnerFName  = $ownerFName
        BusinessOwnerLName  = $ownerLName
        BusinessOwnerEmail  = $ownerEmail
        BusinessOwnerPhone  = $ownerPhone
    }
}

function Invoke-ApplicationsAdd {
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
        $msg = 'Invoke-ApplicationsAdd: AppID is required.'
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

    $description  = if ($InputData['Description'])         { "$($InputData['Description'])".Trim()         } else { '' }
    $location     = if ($InputData['Location'])            { "$($InputData['Location'])".Trim()            } else { '' }
    $accessFrom   = if ($InputData['AccessPermittedFrom']) { "$($InputData['AccessPermittedFrom'])".Trim() } else { '' }
    $accessTo     = if ($InputData['AccessPermittedTo'])   { "$($InputData['AccessPermittedTo'])".Trim()   } else { '' }
    $expDate      = if ($InputData['ExpirationDate'])      { "$($InputData['ExpirationDate'])".Trim()      } else { '' }
    $disabled     = [bool]$InputData['Disabled']
    $ownerFName   = if ($InputData['BusinessOwnerFName'])  { "$($InputData['BusinessOwnerFName'])".Trim()  } else { '' }
    $ownerLName   = if ($InputData['BusinessOwnerLName'])  { "$($InputData['BusinessOwnerLName'])".Trim()  } else { '' }
    $ownerEmail   = if ($InputData['BusinessOwnerEmail'])  { "$($InputData['BusinessOwnerEmail'])".Trim()  } else { '' }
    $ownerPhone   = if ($InputData['BusinessOwnerPhone'])  { "$($InputData['BusinessOwnerPhone'])".Trim()  } else { '' }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting add application for App ID: $appId"
    Write-CyberArkLog -Level 'DEBUG' -Message 'POST /WebServices/PIMServices.svc/Applications'

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST /WebServices/PIMServices.svc/Applications '$appId' would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $appBody = @{ AppID = $appId }
    if ($description) { $appBody['Description']         = $description }
    if ($location)    { $appBody['Location']            = $location    }
    if ($accessFrom)  { $appBody['AccessPermittedFrom'] = [int]$accessFrom }
    if ($accessTo)    { $appBody['AccessPermittedTo']   = [int]$accessTo   }
    if ($expDate)     { $appBody['ExpirationDate']      = $expDate     }
    $appBody['Disabled'] = $disabled
    if ($ownerFName)  { $appBody['BusinessOwnerFName']  = $ownerFName  }
    if ($ownerLName)  { $appBody['BusinessOwnerLName']  = $ownerLName  }
    if ($ownerEmail)  { $appBody['BusinessOwnerEmail']  = $ownerEmail  }
    if ($ownerPhone)  { $appBody['BusinessOwnerPhone']  = $ownerPhone  }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint '/WebServices/PIMServices.svc/Applications/' `
        -Body     @{ application = $appBody } `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Add Application failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $result.Results.Add([PSCustomObject]@{
        AppID  = $appId
        Status = 'Created'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Add Application complete for App ID: $appId."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
