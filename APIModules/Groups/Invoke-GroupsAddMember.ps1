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
        @{ Column = 'MemberType'; Required = $false; Description = 'ISPSS: EPVUser or Group (default EPVUser). Self-Hosted: Domain or Vault (default Vault).' }
        @{ Column = 'DomainName'; Required = $false; Description = 'FQDN for domain users.' }
    )
    Priority         = 65
    Version          = '1.1.0'
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

    $groupId = Show-FieldPrompt -Label 'Group ID' `
        -Default $(if ($Defaults['GroupID']) { $Defaults['GroupID'] } else { '' }) `
        -Description 'Numeric group ID, or leave blank to search by name.'

    if (-not $groupId) {
        $searchTerm = Show-FieldPrompt -Label 'Search Group' `
            -Description 'Group name to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $groupId = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/UserGroups' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'value' `
                -IdProperty 'id' `
                -DisplayProperties @('groupName', 'groupType', 'description') `
                -EntityLabel 'group' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $groupId) { return $null }
    }

    $memberId = Show-FieldPrompt -Label 'Member ID' `
        -Default $(if ($Defaults['MemberID']) { $Defaults['MemberID'] } else { '' }) `
        -Description 'Numeric user ID to add, or leave blank to search by username.'

    if (-not $memberId) {
        $searchTerm = Show-FieldPrompt -Label 'Search User' `
            -Description 'Username to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $memberId = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Users' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'Users' `
                -IdProperty 'id' `
                -DisplayProperties @('username', 'userType') `
                -EntityLabel 'user' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $memberId) { return $null }
    }

    $isSelfHosted      = ($Token.PSObject.Properties['SystemType'] -and $Token.SystemType -eq 'SelfHosted')
    $defaultMemberType = if ($isSelfHosted) { 'Vault' } else { 'EPVUser' }
    $memberTypeHint    = if ($isSelfHosted) { "Domain or Vault (default $defaultMemberType)." } else { "EPVUser or Group (default $defaultMemberType)." }

    $memberType = Show-FieldPrompt -Label 'MemberType' `
        -Default $(if ($Defaults['MemberType']) { $Defaults['MemberType'] } else { $defaultMemberType }) `
        -Description $memberTypeHint

    $domainName = Show-FieldPrompt -Label 'DomainName' `
        -Default $(if ($Defaults['DomainName']) { $Defaults['DomainName'] } else { '' }) `
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

    $encodedId = [Uri]::EscapeDataString($groupId)

    # MemberType's valid values differ by platform: ISPSS uses EPVUser/Group, Self-Hosted uses
    # Domain/Vault, for the identical POST /API/UserGroups/{id}/Members endpoint.
    $tokenSystemType   = if ($Token.PSObject.Properties['SystemType']) { $Token.SystemType } else { '' }
    $isSelfHosted      = ($tokenSystemType -eq 'SelfHosted')
    $validMemberTypes  = if ($isSelfHosted) { @('Domain', 'Vault') } else { @('EPVUser', 'Group') }
    $defaultMemberType = if ($isSelfHosted) { 'Vault' } else { 'EPVUser' }

    $memberType = if ($InputData['MemberType']) { "$($InputData['MemberType'])".Trim() } else { $defaultMemberType }
    if ($memberType -notin $validMemberTypes) {
        $msg = "MemberType '$memberType' is not valid for $tokenSystemType. Valid values: $($validMemberTypes -join ', ')."
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

    $body = @{ memberId = [int]$memberId; memberType = $memberType }

    $domainName = if ($InputData['DomainName']) { "$($InputData['DomainName'])".Trim() } else { '' }
    if (-not [string]::IsNullOrEmpty($domainName)) {
        $body['domainName'] = $domainName
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Adding member ID '$memberId' to group ID '$groupId'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/UserGroups/$encodedId/Members | MemberID='$memberId'"

    # WhatIf check BEFORE API call
    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: would POST /API/UserGroups/$encodedId/Members for member ID '$memberId'."
        $result.Results.Add([PSCustomObject]@{
            GroupID  = $groupId
            MemberID = $memberId
            Added    = $true
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
        GroupID  = $groupId
        MemberID = $memberId
        Added    = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Member ID '$memberId' added to group ID '$groupId' successfully."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
