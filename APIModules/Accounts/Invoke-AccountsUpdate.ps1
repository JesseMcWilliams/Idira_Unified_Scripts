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
        @{ Column = 'AccountName'; Required = $true;  Description = 'Account name or username. Matched locally against name and userName fields within the specified Safe.' }
        @{ Column = 'Safe';        Required = $true;  Description = 'Safe containing the account.' }
        @{ Column = 'Name';        Required = $false; Description = 'New account name.' }
        @{ Column = 'Address';     Required = $false; Description = 'New target address.' }
        @{ Column = 'UserName';    Required = $false; Description = 'New username.' }
        @{ Column = 'PlatformID';  Required = $false; Description = 'New platform ID.' }
        @{ Column = 'SafeName';    Required = $false; Description = 'New safe (moves account).' }
        @{ Column = 'AutoManaged'; Required = $false; Description = 'Enable automatic management: true/false.' }
    )
    Priority         = 33
    Version          = '1.1.0'
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

    $accountId   = if ($InputData['AccountID'])   { "$($InputData['AccountID'])".Trim()   } else { '' }
    $accountName = if ($InputData['AccountName']) { "$($InputData['AccountName'])".Trim() } else { '' }
    $targetSafe  = if ($InputData['Safe'])        { "$($InputData['Safe'])".Trim()        } else { '' }

    if (-not $accountId) {
        if (-not $accountName) {
            $msg = 'AccountName is required when AccountID is not provided.'
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }
        if (-not $targetSafe) {
            $msg = 'Safe is required to locate the account.'
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        Write-CyberArkLog -Level 'DEBUG' -Message "Fetching accounts in safe '$targetSafe' to locate '$accountName'."

        $lookupResp = Invoke-CyberArkAPI `
            -Token       $Token `
            -Method      'GET' `
            -Endpoint    '/API/Accounts' `
            -QueryParams @{ filter = "safeName eq $targetSafe"; limit = 1000 }

        if (-not $lookupResp.IsSuccess) {
            $msg = "Account lookup failed (HTTP $($lookupResp.StatusCode)): $($lookupResp.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $lookupResp.ErrorDetails })
            $result.Failures++
            $result.ItemsProcessed++
            $result.IsFatal = ($lookupResp.StatusCode -in @(401, 0))
            return $result
        }

        [array]$acctList = if ($lookupResp.Data -and
                               $lookupResp.Data.PSObject.Properties['value'] -and
                               $null -ne $lookupResp.Data.value) {
            @($lookupResp.Data.value)
        } else { @() }

        $acctMatch = $acctList | Where-Object {
            $_ -and
            (($_.PSObject.Properties['name']     -and $_.name     -eq $accountName) -or
             ($_.PSObject.Properties['userName'] -and $_.userName -eq $accountName))
        }
        [array]$acctMatches = @($acctMatch)

        if (-not $acctMatches -or $acctMatches.Count -eq 0) {
            $msg = "Account '$accountName' not found in safe '$targetSafe'."
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        if ($acctMatches.Count -gt 1) {
            Write-CyberArkLog -Level 'WARN' -Message "Multiple accounts matched '$accountName' in safe '$targetSafe' - using first match."
        }

        $accountId = if ($acctMatches[0].PSObject.Properties['id']) { $acctMatches[0].id } else { '' }
        if (-not $accountId) {
            $msg = "Account '$accountName' found in safe '$targetSafe' but has no ID."
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        Write-CyberArkLog -Level 'DEBUG' -Message "Resolved account ID: $accountId"
    }

    $encodedId = [System.Uri]::EscapeDataString($accountId)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting account update for ID: $accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Accounts/$encodedId"

    # Step 1: GET current account to retrieve values for fields not being updated
    $getResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Accounts/$encodedId"

    if (-not $getResponse.IsSuccess) {
        $msg = "Failed to retrieve account '$accountId' before update (HTTP $($getResponse.StatusCode)): $($getResponse.ErrorMessage)"
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

    $mergedName = if ($InputData.ContainsKey('Name') -and "$($InputData['Name'])".Trim() -ne '') {
        "$($InputData['Name'])".Trim()
    } else {
        if ($currentAccount.name) { $currentAccount.name } else { '' }
    }

    $mergedAddress = if ($InputData.ContainsKey('Address') -and "$($InputData['Address'])".Trim() -ne '') {
        "$($InputData['Address'])".Trim()
    } else {
        if ($currentAccount.address) { $currentAccount.address } else { '' }
    }

    $mergedUserName = if ($InputData.ContainsKey('UserName') -and "$($InputData['UserName'])".Trim() -ne '') {
        "$($InputData['UserName'])".Trim()
    } else {
        if ($currentAccount.userName) { $currentAccount.userName } else { '' }
    }

    $mergedPlatformID = if ($InputData.ContainsKey('PlatformID') -and "$($InputData['PlatformID'])".Trim() -ne '') {
        "$($InputData['PlatformID'])".Trim()
    } else {
        if ($currentAccount.platformId) { $currentAccount.platformId } else { '' }
    }

    $mergedSafeName = if ($InputData.ContainsKey('SafeName') -and "$($InputData['SafeName'])".Trim() -ne '') {
        "$($InputData['SafeName'])".Trim()
    } else {
        if ($currentAccount.safeName) { $currentAccount.safeName } else { '' }
    }

    $mergedAutoManaged = if ($InputData.ContainsKey('AutoManaged') -and "$($InputData['AutoManaged'])".Trim() -ne '') {
        "$($InputData['AutoManaged'])".Trim() -eq 'true'
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

    Write-CyberArkLog -Level 'DEBUG' -Message "PUT /API/Accounts/$encodedId"

    # Step 4: PUT updated account
    $putResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'PUT' `
        -Endpoint "/API/Accounts/$encodedId" `
        -Body     $body `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $putResponse.IsSuccess) {
        $msg = "Account update failed for '$accountId' (HTTP $($putResponse.StatusCode)): $($putResponse.ErrorMessage)"
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
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: Account update suppressed for '$accountId'."
        $result.Results.Add([PSCustomObject]@{
            AccountID   = $accountId
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

    Write-CyberArkLog -Level 'INFO' -Message "Account update complete for '$accountId'."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
