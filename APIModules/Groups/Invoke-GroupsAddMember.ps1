#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Group Member'
    Category         = 'Groups'
    Action           = 'AddMember'
    Description      = 'Add a user to a user group by numeric member ID.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'GroupID';    Required = $true;  Description = 'Numeric ID of the group.' }
        @{ Column = 'MemberID';   Required = $true;  Description = 'Numeric user ID to add.' }
        @{ Column = 'MemberType'; Required = $false; Description = 'EPVUser or Group, default EPVUser.' }
        @{ Column = 'DomainName'; Required = $false; Description = 'FQDN for domain users.' }
    )
    Priority         = 65
    Version          = '1.0.0'
}

function Get-GroupsAddMemberInput {
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

    Write-Host '  Add Group Member Details  (press Enter to accept each default)' -ForegroundColor DarkGray
    Write-Host ''

    $groupId = Show-FieldPrompt -Label 'GroupID' `
        -Default $(if ($Defaults.GroupID) { $Defaults.GroupID } else { '' }) `
        -Required $true `
        -Description 'Numeric ID of the group.'

    $memberId = Show-FieldPrompt -Label 'MemberID' `
        -Default $(if ($Defaults.MemberID) { $Defaults.MemberID } else { '' }) `
        -Required $true `
        -Description 'Numeric user ID to add.'

    $memberType = Show-FieldPrompt -Label 'MemberType' `
        -Default $(if ($Defaults.MemberType) { $Defaults.MemberType } else { 'EPVUser' }) `
        -Description 'EPVUser or Group (default EPVUser).'

    $domainName = Show-FieldPrompt -Label 'DomainName' `
        -Default $(if ($Defaults.DomainName) { $Defaults.DomainName } else { '' }) `
        -Description 'FQDN for domain users (leave blank for local users).'

    return @{
        GroupID    = $groupId
        MemberID   = $memberId
        MemberType = $memberType
        DomainName = $domainName
    }
}

function Invoke-GroupsAddMember {
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

    # Validate required field GroupID
    $groupId = if ($InputData['GroupID']) { "$($InputData['GroupID'])".Trim() } else { '' }
    if (-not $groupId) {
        $msg = 'GroupID is required and cannot be empty.'
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

    # Validate required field MemberID
    $memberId = if ($InputData['MemberID']) { "$($InputData['MemberID'])".Trim() } else { '' }
    if (-not $memberId) {
        $msg = 'MemberID is required and cannot be empty.'
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

    $encodedId  = [Uri]::EscapeDataString($groupId)
    $memberType = if ($InputData['MemberType']) { $InputData['MemberType'] } else { 'EPVUser' }

    $body = @{
        memberId   = [int]$memberId
        memberType = $memberType
    }

    $domainName = if ($InputData['DomainName']) { "$($InputData['DomainName'])".Trim() } else { '' }
    if (-not [string]::IsNullOrEmpty($domainName)) {
        $body.domainName = $domainName
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Adding member ID '$memberId' to group ID '$groupId'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/UserGroups/$encodedId/Members | MemberID='$memberId' MemberType='$memberType'"

    # WhatIf check BEFORE API call
    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: would POST /API/UserGroups/$encodedId/Members for member ID '$memberId'."
        $result.Results.Add([PSCustomObject]@{
            GroupID    = $groupId
            MemberID   = $memberId
            MemberType = $memberType
            Added      = $true
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint "/API/UserGroups/$encodedId/Members" `
        -Body     $body `
        -WhatIf:  $false

    if (-not $response.IsSuccess) {
        $msg = "Add group member failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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
        GroupID    = $groupId
        MemberID   = $memberId
        MemberType = $memberType
        Added      = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Member ID '$memberId' added to group ID '$groupId' successfully."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
