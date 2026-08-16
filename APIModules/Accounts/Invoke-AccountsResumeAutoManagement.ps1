#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Resume Auto Management'
    Category         = 'Accounts'
    Action           = 'ResumeAutoManagement'
    Description      = 'Resume automatic CPM management for an account that was manually disabled.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountID'; Required = $true; Description = 'Account ID, or leave blank to search.' }
        @{ Column = 'Reason'; Required = $false; Description = 'Optional reason for resuming automatic management.' }
    )
    Priority         = 41
    Version          = '1.0.0'
}

function Get-AccountsResumeAutoManagementInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt and Invoke-EntitySearch are available because this module is dot-sourced into the driver scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Resume Auto Management  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $accountID = Show-FieldPrompt -Label 'Account ID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'Account ID, or leave blank to search by name/username/address.'

    if (-not $accountID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Name, username, or address to find the account.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $accountID = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Accounts' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'value' `
                -IdProperty 'id' `
                -DisplayProperties @('name', 'userName', 'address', 'safeName') `
                -EntityLabel 'account' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $accountID) { return $null }
    }

    $reason = Show-FieldPrompt -Label 'Reason' `
        -Default $(if ($Defaults['Reason']) { $Defaults['Reason'] } else { '' }) `
        -Description 'Optional reason for resuming automatic management.'

    return @{
        AccountID = $accountID
        Reason = $reason
    }
}

function Invoke-AccountsResumeAutoManagement {
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

    $accountId = if ($InputData['AccountID']) { "$($InputData['AccountID'])".Trim() } else { '' }

    if (-not $accountId) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-AccountsResumeAutoManagement: AccountID is required.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'AccountID is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.IsFatal = $false
        return $result
    }

    $encodedId = [Uri]::EscapeDataString($accountId)
    $reason = if ($InputData['Reason']) { "$($InputData['Reason'])".Trim() } else { '' }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting resume auto management for account ID: $accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Accounts/$accountId/ResumeAutoManagement"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST /API/Accounts/$accountId/ResumeAutoManagement would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $body = @{}
    if ($reason) { $body['Reason'] = $reason }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint "/API/Accounts/$encodedId/ResumeAutoManagement" `
        -Body     $body `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Resume Auto Management failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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
        AccountID = $accountId
        Status    = 'Success'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Resume Auto Management complete for account ID: $accountId."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
