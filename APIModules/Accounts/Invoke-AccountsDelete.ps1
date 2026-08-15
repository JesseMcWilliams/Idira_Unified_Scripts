#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Delete Account'
    Category         = 'Accounts'
    Action           = 'Delete'
    Description      = 'Permanently delete an account from CyberArk.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountID'; Required = $true; Description = 'Account ID to delete.' }
    )
    Priority         = 34
    Version          = '1.0.0'
}

function Get-AccountsDeleteInput {
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

    Write-Host '  Account to Delete' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  WARNING: This operation permanently deletes the account and cannot be undone.' -ForegroundColor Red
    Write-Host ''

    $accountId = Show-FieldPrompt -Label 'AccountID' `
        -Default $(if ($Defaults.AccountID) { $Defaults.AccountID } else { '' }) `
        -Required $true `
        -Description 'Account ID to delete.'

    return @{
        AccountID = $accountId
    }
}

function Invoke-AccountsDelete {
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
        $msg = 'InputData is null or missing. AccountID is required.'
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

    # Validate AccountID
    $accountId = if ($InputData.AccountID) { "$($InputData.AccountID)".Trim() } else { '' }

    if (-not $accountId) {
        $msg = 'AccountID is required and must not be empty.'
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

    $encodedId = [Uri]::EscapeDataString($accountId)
    $endpoint  = "/API/Accounts/$encodedId"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting account delete. AccountID='$accountId'."
    Write-CyberArkLog -Level 'DEBUG' -Message "DELETE $endpoint"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'DELETE' `
        -Endpoint $endpoint `
        -WhatIf:  $WhatIf.IsPresent

    # WhatIf: API returns without executing; log and count as success
    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: DELETE $endpoint would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        return $result
    }

    if (-not $response.IsSuccess) {
        $msg = "Account delete failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Success — 204 No Content
    $result.Results.Add([PSCustomObject]@{
        AccountID = $accountId
        Deleted   = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Account delete complete. AccountID='$accountId'."

    Add-CyberArkLogSummaryEntry `
        -ModuleName $ModuleMeta.Name `
        -Successes  $result.Successes `
        -Failures   $result.Failures

    return $result
}
