#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Account Activity'
    Category         = 'Accounts'
    Action           = 'GetActivity'
    Description      = 'Retrieve the activity log for an account.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountID'; Required = $true; Description = 'Account ID, or leave blank to search.' }
    )
    Priority         = 38
    Version          = '1.0.0'
}

function Get-AccountsGetActivityInput {
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

    return @{
        AccountID = $accountID
    }
}

function Invoke-AccountsGetActivity {
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
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-AccountsGetActivity: AccountID is required.'
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

    Write-CyberArkLog -Level 'INFO'  -Message "Starting get account activity for account ID: $accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Accounts/$accountId/Activities"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Accounts/$encodedId/Activities" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Get Account Activity failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $activities = if ($response.Data -and $response.Data.PSObject.Properties['Activities']) {
        @($response.Data.Activities)
    } elseif ($response.Data -and $response.Data.PSObject.Properties['value']) {
        @($response.Data.value)
    } else { @() }

    foreach ($a in $activities) {
        try {
            $result.Results.Add([PSCustomObject]@{
                AccountID = $accountId
                Time      = if ($a.PSObject.Properties['time'])        { $a.time        } else { '' }
                Action    = if ($a.PSObject.Properties['action'])      { $a.action      } else { '' }
                Reason    = if ($a.PSObject.Properties['reason'])      { $a.reason      } else { '' }
                User      = if ($a.PSObject.Properties['User'])        { $a.User        } else { '' }
            })
            $result.Successes++
            $result.ItemsProcessed++
        } catch {
            $msg = "Unexpected error mapping activity: $_"
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

    Write-CyberArkLog -Level 'INFO' -Message "Get Account Activity complete for account ID: $accountId."

    return $result
}
