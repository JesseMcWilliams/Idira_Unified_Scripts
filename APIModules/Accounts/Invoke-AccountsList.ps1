#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Accounts'
    Category         = 'Accounts'
    Action           = 'List'
    Description      = 'Retrieve accounts with optional search/filter, or iterate by safe to bypass the 20,000-account API limit.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    Priority         = 30
    Version          = '1.1.0'
}

# Maps one raw account API object onto the result list.
# Returns the number of accounts added (1 on success, 0 on error).
function script:Add-AccountToResult {
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$Result,
        [Parameter(Mandatory = $true)] [object]$Account,
        [Parameter(Mandatory = $false)][hashtable]$ErrorInputData
    )
    try {
        $createdDate = if ($Account.PSObject.Properties['createdTime'] -and $Account.createdTime) {
            try { [DateTimeOffset]::FromUnixTimeSeconds($Account.createdTime).LocalDateTime.ToString('yyyy-MM-dd') }
            catch { '' }
        } else { '' }

        $autoManaged = if ($Account.PSObject.Properties['secretManagement'] -and $Account.secretManagement) {
            $Account.secretManagement.automaticManagementEnabled
        } else { $false }

        $cpmStatus = if ($Account.PSObject.Properties['secretManagement'] -and $Account.secretManagement -and
                        $Account.secretManagement.PSObject.Properties['status']) {
            $Account.secretManagement.status
        } else { '' }

        $Result.Results.Add([PSCustomObject]@{
            AccountID   = if ($Account.PSObject.Properties['id'])         { $Account.id }         else { '' }
            AccountName = if ($Account.PSObject.Properties['name'])       { $Account.name }       else { '' }
            Address     = if ($Account.PSObject.Properties['address'])    { $Account.address }    else { '' }
            UserName    = if ($Account.PSObject.Properties['userName'])   { $Account.userName }   else { '' }
            PlatformID  = if ($Account.PSObject.Properties['platformId']) { $Account.platformId } else { '' }
            SafeName    = if ($Account.PSObject.Properties['safeName'])   { $Account.safeName }   else { '' }
            SecretType  = if ($Account.PSObject.Properties['secretType']) { $Account.secretType } else { '' }
            AutoManaged = $autoManaged
            CPMStatus   = $cpmStatus
            Created     = $createdDate
        })
        $Result.Successes++
        $Result.ItemsProcessed++
    } catch {
        $acctId = try { "$($Account.id)" } catch { '(unknown)' }
        $msg = "Unexpected error mapping account '$acctId': $_"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $Result.Errors.Add([PSCustomObject]@{
            InputData    = if ($ErrorInputData) { $ErrorInputData } else { @{ AccountID = $acctId } }
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $Result.Failures++
        $Result.ItemsProcessed++
    }
}

function Get-AccountsListInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt / Read-MenuChoice are available because this module
        is dot-sourced into the driver scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Retrieval Mode:' -ForegroundColor DarkGray
    Write-Host '    1 = Normal     - search / filter all accounts (API cap: ~20,000)'
    Write-Host '    2 = By Safe    - iterate each safe; no account count limit'
    Write-Host ''

    $modeChoice = Read-Host '  Select mode (1-2, default=1)'

    if ($modeChoice -eq '2') {
        Write-Host ''
        $safeSearch = Show-FieldPrompt -Label 'Safe Search' `
            -Default $(if ($Defaults['SafeSearch']) { $Defaults['SafeSearch'] } else { '' }) `
            -Description 'Optional: free-text search to narrow which safes are iterated (e.g. "Prod"). Leave blank to iterate all accessible safes.'

        return @{
            IterateBySafe = $true
            SafeSearch    = $safeSearch
        }
    }

    # Normal mode
    Write-Host ''
    $search = Show-FieldPrompt -Label 'Search' `
        -Default $(if ($Defaults['Search']) { $Defaults['Search'] } else { '' }) `
        -Description 'Free-text search across account name, address, and username. Leave blank for all accounts.'

    $safe = Show-FieldPrompt -Label 'Safe' `
        -Default $(if ($Defaults['Safe']) { $Defaults['Safe'] } else { '' }) `
        -Description 'Filter by safe name (e.g. "MySafe"). Leave blank to skip.'

    $filter = Show-FieldPrompt -Label 'Filter' `
        -Default $(if ($Defaults['Filter']) { $Defaults['Filter'] } else { '' }) `
        -Description 'OData filter expression (e.g. "safeName eq MySafe"). Leave blank for no filter. Overridden by Safe if both are set.'

    if ($safe -and -not $filter) {
        $filter = "safeName eq $safe"
    }

    return @{
        IterateBySafe = $false
        Search        = $search
        Filter        = $filter
    }
}

function Invoke-AccountsList {
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

    $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }

    # --- By-Safe iteration path ---
    if ($InputData['IterateBySafe']) {
        $safeSearch = if ($InputData['SafeSearch']) { "$($InputData['SafeSearch'])".Trim() } else { $null }

        Write-Host '  Retrieving safe list...' -ForegroundColor Cyan
        Write-CyberArkLog -Level 'INFO' -Message 'Account list by safe: retrieving safe list.'

        $safeQP = @{}
        if ($safeSearch) { $safeQP['search'] = $safeSearch }

        $safesResp = Invoke-CyberArkAPI `
            -Token       $Token `
            -Method      'GET' `
            -Endpoint    '/API/Safes' `
            -QueryParams $safeQP `
            -IgnoreSSL:  $ignoreSSL

        if (-not $safesResp.IsSuccess) {
            $msg = "Safe list failed (HTTP $($safesResp.StatusCode)): $($safesResp.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = $InputData
                ErrorMessage = $safesResp.ErrorMessage
                ErrorDetails = $safesResp.ErrorDetails
            })
            $result.Failures++
            $result.ItemsProcessed++
            $result.IsFatal = ($safesResp.StatusCode -in @(401, 0))
            return $result
        }

        [array]$allSafes = if ($safesResp.Data -and $safesResp.Data.PSObject.Properties['value']) {
            @($safesResp.Data.value)
        } else { @() }

        if ((-not $allSafes) -or $allSafes.Count -eq 0) {
            Write-Host '  No accessible safes found.' -ForegroundColor Yellow
            Write-CyberArkLog -Level 'WARN' -Message 'Account list by safe: no safes returned.'
            return $result
        }

        Write-Host "  Found $($allSafes.Count) safe$(if ($allSafes.Count -ne 1) { 's' }). Retrieving accounts per safe..." -ForegroundColor Cyan
        Write-Host ''

        $safeIdx = 0
        foreach ($safe in $allSafes) {
            $safeIdx++
            $safeName = if ($safe.PSObject.Properties['safeName'] -and $safe.safeName) { "$($safe.safeName)" } else { continue }

            Write-Host "  [$safeIdx/$($allSafes.Count)] $safeName" -ForegroundColor White -NoNewline

            # Single-quote the safe name in the filter to handle names with spaces
            $safeFilter = "safeName eq '$($safeName -replace "'", "''")'"

            $acctResp = Invoke-CyberArkAPI `
                -Token       $Token `
                -Method      'GET' `
                -Endpoint    '/API/Accounts' `
                -QueryParams @{ filter = $safeFilter } `
                -IgnoreSSL:  $ignoreSSL

            if (-not $acctResp.IsSuccess) {
                Write-Host " - failed (HTTP $($acctResp.StatusCode))" -ForegroundColor Red
                Write-CyberArkLog -Level 'WARN' -Message "Account list for safe '$safeName' failed (HTTP $($acctResp.StatusCode)): $($acctResp.ErrorMessage)"
                $result.Errors.Add([PSCustomObject]@{
                    InputData    = @{ SafeName = $safeName }
                    ErrorMessage = $acctResp.ErrorMessage
                    ErrorDetails = $acctResp.ErrorDetails
                })
                $result.Failures++
                $result.ItemsProcessed++
                if ($acctResp.StatusCode -in @(401, 0)) {
                    $result.IsFatal = $true
                    return $result
                }
                continue
            }

            [array]$safeAccounts = if ($acctResp.Data -and $acctResp.Data.PSObject.Properties['value']) {
                @($acctResp.Data.value)
            } else { @() }

            $beforeCount = $result.Successes
            foreach ($acct in $safeAccounts) {
                script:Add-AccountToResult -Result $result -Account $acct -ErrorInputData @{ SafeName = $safeName }
            }
            $added = $result.Successes - $beforeCount

            Write-Host " - $added account$(if ($added -ne 1) { 's' })" -ForegroundColor Green
            $result.ItemsProcessed++
        }

        Write-Host ''
        Write-CyberArkLog -Level 'INFO' -Message "Account list by safe complete. Safes: $safeIdx, Accounts: $($result.Successes)."
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # --- Normal path ---
    $search = if ($InputData['Search']) { "$($InputData['Search'])".Trim() } else { $null }
    $filter = if ($InputData['Filter']) { "$($InputData['Filter'])".Trim() } else { $null }

    $queryParams = @{}
    if ($search) { $queryParams['search'] = $search }
    if ($filter) { $queryParams['filter'] = $filter }

    $criteriaLog = $(
        $parts = @()
        if ($search) { $parts += "Search='$search'" }
        if ($filter) { $parts += "Filter='$filter'" }
        if ($parts)  { $parts -join '  ' } else { '(all accounts)' }
    )

    Write-CyberArkLog -Level 'INFO'  -Message 'Starting account list retrieval.'
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Accounts | $criteriaLog"

    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/Accounts' `
        -QueryParams $queryParams `
        -IgnoreSSL:  $ignoreSSL `
        -WhatIf:     $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Account list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    [array]$accounts = if ($response.Data -and $response.Data.PSObject.Properties['value']) {
        @($response.Data.value)
    } else { @() }

    if ((-not $accounts) -or $accounts.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No accounts returned for the given criteria.'
        return $result
    }

    foreach ($acct in $accounts) {
        script:Add-AccountToResult -Result $result -Account $acct -ErrorInputData $InputData
    }

    Write-CyberArkLog -Level 'INFO' -Message "Account list complete. Accounts retrieved: $($result.Successes)."
    return $result
}
