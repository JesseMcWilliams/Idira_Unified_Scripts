#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Link Account'
    Category         = 'Accounts'
    Action           = 'LinkAccount'
    Description      = 'Link an extra credential (reconcile or logon account) to an existing account.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountID'; Required = $true; Description = 'Account ID to link to, or leave blank to search.' }
        @{ Column = 'ExtraPasswordIndex'; Required = $true; Description = '1 = logon, 2 = reconcile, 3 = link3.' }
        @{ Column = 'Name'; Required = $true; Description = 'Name of the linked account.' }
        @{ Column = 'Folder'; Required = $false; Description = 'Folder of the linked account (leave blank for Root).' }
        @{ Column = 'Safe'; Required = $true; Description = 'Safe containing the linked account.' }
    )
    Priority         = 36
    Version          = '1.0.0'
}

function Get-AccountsLinkAccountInput {
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

    Write-Host '  Link Account  (press Enter to skip optional fields)' -ForegroundColor DarkGray
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

    $extraPasswordIndex = Show-FieldPrompt -Label 'Extra Password Index' `
        -Default $(if ($Defaults['ExtraPasswordIndex']) { $Defaults['ExtraPasswordIndex'] } else { '' }) `
        -Required $true `
        -Description '1 = logon, 2 = reconcile, 3 = link3.'

    $name = Show-FieldPrompt -Label 'Name' `
        -Default $(if ($Defaults['Name']) { $Defaults['Name'] } else { '' }) `
        -Required $true `
        -Description 'Name of the linked account.'

    $folder = Show-FieldPrompt -Label 'Folder' `
        -Default $(if ($Defaults['Folder']) { $Defaults['Folder'] } else { '' }) `
        -Description 'Folder of the linked account (leave blank for Root).'

    $safe = Show-FieldPrompt -Label 'Safe' `
        -Default $(if ($Defaults['Safe']) { $Defaults['Safe'] } else { '' }) `
        -Required $true `
        -Description 'Safe containing the linked account.'

    return @{
        AccountID = $accountID
        ExtraPasswordIndex = $extraPasswordIndex
        Name = $name
        Folder = $folder
        Safe = $safe
    }
}

function Invoke-AccountsLinkAccount {
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
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-AccountsLinkAccount: AccountID is required.'
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
    $extraPasswordIndex = if ($InputData['ExtraPasswordIndex']) { "$($InputData['ExtraPasswordIndex'])".Trim() } else { '' }
    if (-not $extraPasswordIndex) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-AccountsLinkAccount: ExtraPasswordIndex is required.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'ExtraPasswordIndex is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        return $result
    }
    $name = if ($InputData['Name']) { "$($InputData['Name'])".Trim() } else { '' }
    if (-not $name) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-AccountsLinkAccount: Name is required.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'Name is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        return $result
    }
    $safe = if ($InputData['Safe']) { "$($InputData['Safe'])".Trim() } else { '' }
    if (-not $safe) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-AccountsLinkAccount: Safe is required.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'Safe is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        return $result
    }
    $folder = if ($InputData['Folder']) { "$($InputData['Folder'])".Trim() } else { '' }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting link account for account ID: $accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Accounts/$accountId/LinkAccount"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST /API/Accounts/$accountId/LinkAccount would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $body = @{}
    $body['ExtraPasswordIndex'] = $extraPasswordIndex
    $body['Name'] = $name
    if ($folder) { $body['Folder'] = $folder }
    $body['Safe'] = $safe

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint "/API/Accounts/$encodedId/LinkAccount" `
        -Body     $body `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Link Account failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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
        AccountID          = $accountId
        ExtraPasswordIndex = $extraPasswordIndex
        LinkedName         = $name
        LinkedSafe         = $safe
        Status             = 'Linked'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Link Account complete for account ID: $accountId."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
