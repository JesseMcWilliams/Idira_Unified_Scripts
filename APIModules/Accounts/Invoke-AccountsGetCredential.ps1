#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Account Credential'
    Category         = 'Accounts'
    Action           = 'GetCredential'
    Description      = 'Retrieve the current credential value for an account. Requires appropriate safe permissions.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountID'; Required = $true;  Description = 'Account ID.' }
        @{ Column = 'Reason';    Required = $false; Description = 'Reason for retrieval (required by some platforms).' }
    )
    Priority         = 35
    Version          = '1.0.0'
}

function Get-AccountsGetCredentialInput {
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

    Write-Host '  Account Credential Retrieval  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $accountID = Show-FieldPrompt -Label 'AccountID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'The CyberArk Account ID to retrieve the credential for. (Required)'

    $reason = Show-FieldPrompt -Label 'Reason' `
        -Default $(if ($Defaults['Reason']) { $Defaults['Reason'] } else { '' }) `
        -Description 'Reason for credential retrieval. Required by some platforms. Leave blank if not needed.'

    return @{
        AccountID = $accountID
        Reason    = $reason
    }
}

function Invoke-AccountsGetCredential {
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

    # Validate InputData
    if (-not $InputData) {
        Write-CyberArkLog -Level 'ERROR' -Message 'InputData is null. AccountID is required.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $null
            ErrorMessage = 'InputData is null. AccountID is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $accountID = if ($InputData.AccountID) { "$($InputData.AccountID)".Trim() } else { '' }

    # Validate AccountID
    if (-not $accountID) {
        Write-CyberArkLog -Level 'ERROR' -Message 'AccountID is required and was not provided.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'AccountID is required and was not provided.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # IMPORTANT SECURITY: Log that a credential retrieval was requested but NEVER log the actual credential value.
    Write-CyberArkLog -Level 'WARN' -Message "Credential retrieval requested for AccountID=$accountID"

    $reason = if ($InputData.Reason) { "$($InputData.Reason)" } else { '' }

    $body = @{
        reason              = $reason
        TicketingSystemName = $null
        TicketId            = $null
        Version             = 0
        actionType          = $null
        isUse               = $false
        Machine             = ''
    }

    $endpoint = "/API/Accounts/$([Uri]::EscapeDataString($accountID))/Password/Retrieve"

    Write-CyberArkLog -Level 'DEBUG' -Message "POST $endpoint"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint $endpoint `
        -Body     $body `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Credential retrieval failed for AccountID=$accountID (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # CRITICAL: The response is a raw string (the password), NOT JSON.
    # response.Data will be the raw string (or null). Use response.RawResponse if Data is null.
    $credential = if ($response.Data) { "$($response.Data)" } else { $response.RawResponse }

    # IMPORTANT SECURITY: Log success without exposing the credential value.
    Write-CyberArkLog -Level 'INFO' -Message "Credential retrieved successfully for AccountID=$accountID. Value masked in logs."

    # NOTE: This module intentionally returns the credential in Results.Credential for display to the user.
    # The driver is responsible for displaying it securely. The credential MUST NOT be logged.
    $result.Results.Add([PSCustomObject]@{
        AccountID  = $InputData.AccountID
        Credential = $credential
        Retrieved  = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
