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
        @{ Column = 'AccountID';          Required = $true;  Description = 'Account ID to link to, or leave blank to search.' }
        @{ Column = 'ExtraPasswordIndex'; Required = $true;  Description = '1 = logon, 2 = enable, 3 = reconcile.' }
        @{ Column = 'Name';               Required = $true;  Description = 'Name of the linked account.' }
        @{ Column = 'Folder';             Required = $false; Description = 'Folder of the linked account (default: Root).' }
        @{ Column = 'Safe';               Required = $true;  Description = 'Safe containing the linked account.' }
    )
    Priority         = 36
    Version          = '1.1.0'
}

function script:Search-LinkedAccount {
    <#
        Prompts the user to search for the account to link and returns a hashtable
        with Name, Safe, and Folder pre-populated from the selected account.
        Returns $null if the user skips the search.
    #>
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [bool]$IgnoreSSL = $false
    )

    $searchTerm = Show-FieldPrompt -Label 'Search Linked Account' `
        -Default '' `
        -Description 'Search by account name, username, or address to find the account to link. Leave blank to enter details manually.'

    if (-not $searchTerm) { return $null }

    $searchResp = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/Accounts' `
        -QueryParams @{ search = $searchTerm } `
        -IgnoreSSL:  $IgnoreSSL

    if (-not $searchResp.IsSuccess) {
        Write-Host "  Search failed (HTTP $($searchResp.StatusCode)). Enter details manually." -ForegroundColor Yellow
        return $null
    }

    [array]$accounts = if ($searchResp.Data -and $searchResp.Data.PSObject.Properties['value']) {
        @($searchResp.Data.value)
    } else { @() }

    if (-not $accounts -or $accounts.Count -eq 0) {
        Write-Host '  No accounts found. Enter details manually.' -ForegroundColor Yellow
        return $null
    }

    $selected = $null
    if ($accounts.Count -eq 1) {
        $selected = $accounts[0]
        $nm = if ($selected.PSObject.Properties['name'])     { $selected.name }     else { '' }
        $sf = if ($selected.PSObject.Properties['safeName']) { $selected.safeName } else { '' }
        Write-Host "  Found: $nm  (Safe: $sf)" -ForegroundColor Green
    } else {
        Write-Host ''
        Write-Host "  $($accounts.Count) accounts found. Select one:" -ForegroundColor DarkGray
        Write-Host ''
        for ($i = 0; $i -lt $accounts.Count; $i++) {
            $a  = $accounts[$i]
            $nm = if ($a.PSObject.Properties['name'])     { $a.name }     else { '' }
            $un = if ($a.PSObject.Properties['userName']) { $a.userName } else { '' }
            $ad = if ($a.PSObject.Properties['address'])  { $a.address }  else { '' }
            $sf = if ($a.PSObject.Properties['safeName']) { $a.safeName } else { '' }
            Write-Host "    $($i+1)) $nm  [$un @ $ad]  Safe: $sf" -ForegroundColor White
        }
        Write-Host ''
        $choice = Read-Host "  Select (1-$($accounts.Count), or Enter to skip)"
        if ($choice -match '^\d+$') {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $accounts.Count) { $selected = $accounts[$idx] }
        }
    }

    if (-not $selected) { return $null }

    return @{
        Name   = if ($selected.PSObject.Properties['name'])     { $selected.name }     else { '' }
        Safe   = if ($selected.PSObject.Properties['safeName']) { $selected.safeName } else { '' }
        Folder = 'Root'
    }
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

    $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }

    # ── Target account (the account being linked TO) ──────────────────────────
    Write-Host '  Target Account  (the account that will have a linked credential)' -ForegroundColor DarkGray
    Write-Host ''

    $accountID = Show-FieldPrompt -Label 'Account ID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'Account ID, or leave blank to search.'

    if (-not $accountID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Name, username, or address to find the target account.'
        if ($searchTerm) {
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

    # ── Link type ────────────────────────────────────────────────────────────
    Write-Host ''
    Write-Host '  Link Type:' -ForegroundColor DarkGray
    Write-Host '    1 = Logon Account   (ExtraPasswordIndex 1)'
    Write-Host '    2 = Enable Account  (ExtraPasswordIndex 2)'
    Write-Host '    3 = Reconcile       (ExtraPasswordIndex 3)'
    Write-Host ''

    $defaultIdx = if ($Defaults['ExtraPasswordIndex']) { $Defaults['ExtraPasswordIndex'] } else { '1' }
    $idxChoice  = Read-Host "  Select link type (1-3, default=$defaultIdx)"
    $extraPasswordIndex = switch ($idxChoice) {
        '1' { 1 }
        '2' { 2 }
        '3' { 3 }
        default { if ($defaultIdx -match '^[123]$') { [int]$defaultIdx } else { 1 } }
    }

    # ── Linked account search ─────────────────────────────────────────────────
    Write-Host ''
    Write-Host '  Linked Account  (the credential being attached)' -ForegroundColor DarkGray
    Write-Host ''

    $linkedDefaults = script:Search-LinkedAccount -Token $Token -IgnoreSSL $ignoreSSL

    $defaultName   = if ($linkedDefaults -and $linkedDefaults['Name'])   { $linkedDefaults['Name']   }
                     elseif ($Defaults['Name'])                           { $Defaults['Name']         }
                     else { '' }
    $defaultSafe   = if ($linkedDefaults -and $linkedDefaults['Safe'])   { $linkedDefaults['Safe']   }
                     elseif ($Defaults['Safe'])                           { $Defaults['Safe']         }
                     else { '' }
    $defaultFolder = if ($linkedDefaults -and $linkedDefaults['Folder']) { $linkedDefaults['Folder'] }
                     elseif ($Defaults['Folder'])                         { $Defaults['Folder']       }
                     else { 'Root' }

    $name = Show-FieldPrompt -Label 'Name' `
        -Default $defaultName `
        -Required $true `
        -Description 'Name of the linked account (auto-populated if found by search).'

    $safe = Show-FieldPrompt -Label 'Safe' `
        -Default $defaultSafe `
        -Required $true `
        -Description 'Safe containing the linked account (auto-populated if found by search).'

    $folder = Show-FieldPrompt -Label 'Folder' `
        -Default $defaultFolder `
        -Description 'Folder within the safe (default: Root).'

    return @{
        AccountID          = $accountID
        ExtraPasswordIndex = $extraPasswordIndex
        Name               = $name
        Safe               = $safe
        Folder             = $folder
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
        $msg = 'AccountID is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        return $result
    }

    $extraPasswordIndex = 0
    try { $extraPasswordIndex = [int]"$($InputData['ExtraPasswordIndex'])".Trim() } catch {}
    if ($extraPasswordIndex -lt 1) {
        $msg = 'ExtraPasswordIndex is required and must be a positive integer (1=logon, 2=enable, 3=reconcile).'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        return $result
    }

    $name = if ($InputData['Name']) { "$($InputData['Name'])".Trim() } else { '' }
    if (-not $name) {
        $msg = 'Name is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        return $result
    }

    $safe = if ($InputData['Safe']) { "$($InputData['Safe'])".Trim() } else { '' }
    if (-not $safe) {
        $msg = 'Safe is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        return $result
    }

    $folder = if ($InputData['Folder']) { "$($InputData['Folder'])".Trim() } else { 'Root' }

    $encodedId = [Uri]::EscapeDataString($accountId)

    Write-CyberArkLog -Level 'INFO'  -Message "Linking account '$name' (index $extraPasswordIndex) to account ID $accountId."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Accounts/$accountId/LinkAccount | name='$name' safe='$safe' folder='$folder'"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: would POST /API/Accounts/$accountId/LinkAccount."
        $result.Results.Add([PSCustomObject]@{
            AccountID          = $accountId
            ExtraPasswordIndex = $extraPasswordIndex
            LinkedName         = $name
            LinkedSafe         = $safe
            LinkedFolder       = $folder
            Status             = 'WhatIf'
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $body = @{
        extraPasswordIndex = $extraPasswordIndex
        name               = $name
        folder             = $folder
        safe               = $safe
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint "/API/Accounts/$encodedId/LinkAccount" `
        -Body     $body `
        -WhatIf:  $false

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
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $result.Results.Add([PSCustomObject]@{
        AccountID          = $accountId
        ExtraPasswordIndex = $extraPasswordIndex
        LinkedName         = $name
        LinkedSafe         = $safe
        LinkedFolder       = $folder
        Status             = 'Linked'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Link Account complete for account ID: $accountId."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
