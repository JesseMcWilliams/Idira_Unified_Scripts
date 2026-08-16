#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Update Account'
    Category         = 'Accounts'
    Action           = 'Update'
    Description      = 'Update properties of an existing account. Does not change the stored credential.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountID';  Required = $true;  Description = 'Account ID to update.' }
        @{ Column = 'Name';       Required = $false; Description = 'New account name.' }
        @{ Column = 'Address';    Required = $false; Description = 'New target address.' }
        @{ Column = 'UserName';   Required = $false; Description = 'New username.' }
        @{ Column = 'PlatformID'; Required = $false; Description = 'New platform ID.' }
        @{ Column = 'SafeName';   Required = $false; Description = 'New safe (moves account).' }
        @{ Column = 'AutoManaged';Required = $false; Description = 'Enable automatic management: true/false.' }
    )
    Priority         = 33
    Version          = '1.0.0'
}

function Get-AccountsUpdateInput {
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

    Write-Host '  Account Update  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $accountID = Show-FieldPrompt -Label 'Account ID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'Account ID to update, or leave blank to search by name/username/address.'

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

    $name = Show-FieldPrompt -Label 'Name' `
        -Default $(if ($Defaults['Name']) { $Defaults['Name'] } else { '' }) `
        -Description 'New account name. Leave blank to keep the current value.'

    $address = Show-FieldPrompt -Label 'Address' `
        -Default $(if ($Defaults['Address']) { $Defaults['Address'] } else { '' }) `
        -Description 'New target address. Leave blank to keep the current value.'

    $userName = Show-FieldPrompt -Label 'UserName' `
        -Default $(if ($Defaults['UserName']) { $Defaults['UserName'] } else { '' }) `
        -Description 'New username. Leave blank to keep the current value.'

    $platformID = Show-FieldPrompt -Label 'PlatformID' `
        -Default $(if ($Defaults['PlatformID']) { $Defaults['PlatformID'] } else { '' }) `
        -Description 'New platform ID. Leave blank to keep the current value.'

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Description 'New safe name (moves account). Leave blank to keep the current value.'

    $autoManaged = Show-FieldPrompt -Label 'AutoManaged' `
        -Default $(if ($Defaults['AutoManaged']) { $Defaults['AutoManaged'] } else { '' }) `
        -Description 'Enable automatic management: true/false. Leave blank to keep the current value.'

    return @{
        AccountID  = $accountID
        Name       = $name
        Address    = $address
        UserName   = $userName
        PlatformID = $platformID
        SafeName   = $safeName
        AutoManaged= $autoManaged
    }
}

function Invoke-AccountsUpdate {
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
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-AccountsUpdate: InputData is null or missing.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $null
            ErrorMessage = 'InputData is null or missing.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # Validate AccountID
    $accountID = if ($InputData.AccountID) { "$($InputData.AccountID)".Trim() } else { '' }

    if (-not $accountID) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-AccountsUpdate: AccountID is required but was empty.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'AccountID is required but was empty.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $encodedID = [System.Uri]::EscapeDataString($accountID)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting account update for ID: $accountID"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Accounts/$encodedID"

    # Step 1: GET current account to retrieve values for fields not being updated
    $getResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Accounts/$encodedID"

    if (-not $getResponse.IsSuccess) {
        $msg = "Failed to retrieve account '$accountID' before update (HTTP $($getResponse.StatusCode)): $($getResponse.ErrorMessage)"
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

    $currentAccount = $getResponse.Data

    # Step 2: Merge - use input value when provided/non-empty, otherwise fall back to current account value

    $mergedName = if ($InputData.ContainsKey('Name') -and "$($InputData.Name)".Trim() -ne '') {
        "$($InputData.Name)".Trim()
    } else {
        if ($currentAccount.name) { $currentAccount.name } else { '' }
    }

    $mergedAddress = if ($InputData.ContainsKey('Address') -and "$($InputData.Address)".Trim() -ne '') {
        "$($InputData.Address)".Trim()
    } else {
        if ($currentAccount.address) { $currentAccount.address } else { '' }
    }

    $mergedUserName = if ($InputData.ContainsKey('UserName') -and "$($InputData.UserName)".Trim() -ne '') {
        "$($InputData.UserName)".Trim()
    } else {
        if ($currentAccount.userName) { $currentAccount.userName } else { '' }
    }

    $mergedPlatformID = if ($InputData.ContainsKey('PlatformID') -and "$($InputData.PlatformID)".Trim() -ne '') {
        "$($InputData.PlatformID)".Trim()
    } else {
        if ($currentAccount.platformId) { $currentAccount.platformId } else { '' }
    }

    $mergedSafeName = if ($InputData.ContainsKey('SafeName') -and "$($InputData.SafeName)".Trim() -ne '') {
        "$($InputData.SafeName)".Trim()
    } else {
        if ($currentAccount.safeName) { $currentAccount.safeName } else { '' }
    }

    $mergedAutoManaged = if ($InputData.ContainsKey('AutoManaged') -and "$($InputData.AutoManaged)".Trim() -ne '') {
        "$($InputData.AutoManaged)".Trim() -eq 'true'
    } else {
        if ($currentAccount.secretManagement) { [bool]$currentAccount.secretManagement.automaticManagementEnabled } else { $false }
    }

    # secretType is not updatable via this module - keep current value
    $currentSecretType = if ($currentAccount.secretType) { $currentAccount.secretType } else { 'password' }

    # Step 3: Build PUT body (id is in the URL, not the body; secret field excluded)
    $body = @{
        name                     = $mergedName
        address                  = $mergedAddress
        userName                 = $mergedUserName
        platformId               = $mergedPlatformID
        safeName                 = $mergedSafeName
        secretType               = $currentSecretType
        platformAccountProperties = @{}
        secretManagement         = @{
            automaticManagementEnabled = $mergedAutoManaged
            manualManagementReason     = ''
        }
    }

    Write-CyberArkLog -Level 'DEBUG' -Message "PUT /API/Accounts/$encodedID"

    # Step 4: PUT updated account
    $putResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'PUT' `
        -Endpoint "/API/Accounts/$encodedID" `
        -Body     $body `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $putResponse.IsSuccess) {
        $msg = "Account update failed for '$accountID' (HTTP $($putResponse.StatusCode)): $($putResponse.ErrorMessage)"
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

    # WhatIf: Invoke-CyberArkAPI returns IsSuccess=$true without actually calling the API
    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: Account update suppressed for '$accountID'."
        $result.Results.Add([PSCustomObject]@{
            AccountID   = $accountID
            AccountName = $mergedName
            Address     = $mergedAddress
            UserName    = $mergedUserName
            PlatformID  = $mergedPlatformID
            SafeName    = $mergedSafeName
            SecretType  = $currentSecretType
            AutoManaged = $mergedAutoManaged
            CPMStatus   = ''
            Created     = ''
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # Map response fields
    $acct = $putResponse.Data

    $createdDate = if ($acct.createdTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($acct.createdTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $result.Results.Add([PSCustomObject]@{
        AccountID   = $acct.id
        AccountName = $acct.name
        Address     = $acct.address
        UserName    = $acct.userName
        PlatformID  = $acct.platformId
        SafeName    = $acct.safeName
        SecretType  = $acct.secretType
        AutoManaged = if ($acct.PSObject.Properties['secretManagement'] -and $acct.secretManagement -and
                          $acct.secretManagement.PSObject.Properties['automaticManagementEnabled']) {
                            $acct.secretManagement.automaticManagementEnabled } else { $false }
        CPMStatus   = if ($acct.PSObject.Properties['secretManagement'] -and $acct.secretManagement -and
                          $acct.secretManagement.PSObject.Properties['status']) {
                            $acct.secretManagement.status } else { '' }
        Created     = $createdDate
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Account update complete for '$accountID'."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
