#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Accounts'
    Category         = 'Accounts'
    Action           = 'List'
    Description      = 'Retrieve all accessible accounts with optional search and filter.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    Priority         = 30
    Version          = '1.0.0'
}

function Get-AccountsListInput {
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

    Write-Host '  Search Criteria  (press Enter to skip each field)' -ForegroundColor DarkGray
    Write-Host ''

    $search = Show-FieldPrompt -Label 'Search' `
        -Default $(if ($Defaults.Search) { $Defaults.Search } else { '' }) `
        -Description 'Free-text search across account name, address, and username. Leave blank for all accounts.'

    $safe = Show-FieldPrompt -Label 'Safe' `
        -Default $(if ($Defaults.Safe) { $Defaults.Safe } else { '' }) `
        -Description 'Shortcut: filter by safe name (e.g. "MySafe"). Leave blank to skip.'

    $filter = Show-FieldPrompt -Label 'Filter' `
        -Default $(if ($Defaults.Filter) { $Defaults.Filter } else { '' }) `
        -Description 'OData filter expression (e.g. "safeName eq MySafe"). Leave blank for no filter. Overridden by Safe if both are provided.'

    # Safe shortcut: if Safe is provided and Filter is empty, build the filter automatically
    if ($safe -and -not $filter) {
        $filter = "safeName eq $safe"
    }

    return @{
        Search = $search
        Filter = $filter
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

    $search = if ($InputData['Search']) { "$($InputData['Search'])".Trim() } else { $null }
    $filter = if ($InputData['Filter']) { "$($InputData['Filter'])".Trim() } else { $null }

    # Build query parameters — only include keys that have a value
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

    $accounts = if ($response.Data -and $response.Data.PSObject.Properties['value']) {
        @($response.Data.value)
    } else { @() }

    if ((-not $accounts) -or $accounts.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No accounts returned for the given criteria.'
        # Not a failure — a valid empty result
        return $result
    }

    foreach ($acct in $accounts) {
        $createdDate = if ($acct.createdTime) {
            try { [DateTimeOffset]::FromUnixTimeSeconds($acct.createdTime).LocalDateTime.ToString('yyyy-MM-dd') }
            catch { '' }
        } else { '' }

        $autoManaged = if ($acct.secretManagement) { $acct.secretManagement.automaticManagementEnabled } else { $false }
        $cpmStatus   = if ($acct.secretManagement) { $acct.secretManagement.status } else { '' }

        $result.Results.Add([PSCustomObject]@{
            AccountID   = $acct.id
            AccountName = $acct.name
            Address     = $acct.address
            UserName    = $acct.userName
            PlatformID  = $acct.platformId
            SafeName    = $acct.safeName
            SecretType  = $acct.secretType
            AutoManaged = $autoManaged
            CPMStatus   = $cpmStatus
            Created     = $createdDate
        })
        $result.Successes++
        $result.ItemsProcessed++
    }

    Write-CyberArkLog -Level 'INFO' -Message "Account list complete. Accounts retrieved: $($result.Successes)."
    return $result
}
