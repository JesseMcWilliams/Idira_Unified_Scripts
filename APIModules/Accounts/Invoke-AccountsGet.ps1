#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Account'
    Category         = 'Accounts'
    Action           = 'Get'
    Description      = 'Retrieve full details of a single account by ID.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountName'; Required = $true;  Description = 'Account name or username. Matched locally against name and userName fields within the specified Safe.' }
        @{ Column = 'Safe';        Required = $true;  Description = 'Safe containing the account.' }
    )
    Priority         = 31
    Version          = '1.1.0'
}

function Get-AccountsGetInput {
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

    $id = Show-FieldPrompt -Label 'Account ID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'Account ID from List Accounts, or leave blank to search by name/username/address.'

    if (-not $id) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Name, username, or address to find the account.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $id = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Accounts' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'value' `
                -IdProperty 'id' `
                -DisplayProperties @('name', 'userName', 'address', 'safeName') `
                -EntityLabel 'account' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $id) { return $null }
    }

    return @{
        AccountID = $id
    }
}

function Invoke-AccountsGet {
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

    $encodedId = [Uri]::EscapeDataString($accountId)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting account retrieval for ID: $accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Accounts/$encodedId"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Accounts/$encodedId" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Account get failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $acct = $response.Data

    $createdDate = if ($acct.PSObject.Properties['createdTime'] -and $acct.createdTime) {
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
        AutoManaged  = if ($acct.PSObject.Properties['secretManagement'] -and $acct.secretManagement -and
                          $acct.secretManagement.PSObject.Properties['automaticManagementEnabled']) {
                            $acct.secretManagement.automaticManagementEnabled } else { $false }
        CPMStatus    = if ($acct.PSObject.Properties['secretManagement'] -and $acct.secretManagement -and
                          $acct.secretManagement.PSObject.Properties['status']) {
                            $acct.secretManagement.status } else { '' }
        ManualReason = if ($acct.PSObject.Properties['secretManagement'] -and $acct.secretManagement -and
                          $acct.secretManagement.PSObject.Properties['manualManagementReason']) {
                            $acct.secretManagement.manualManagementReason } else { '' }
        Created     = $createdDate
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Account get complete. Account retrieved: $accountId."
    return $result
}
