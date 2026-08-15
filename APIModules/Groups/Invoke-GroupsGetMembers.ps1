#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Group Members'
    Category         = 'Groups'
    Action           = 'GetMembers'
    Description      = 'Retrieve all members of a user group.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'GroupID'; Required = $true; Description = 'Numeric ID of the group.' }
    )
    Priority         = 64
    Version          = '1.0.0'
}

function Get-GroupsGetMembersInput {
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

    Write-Host '  Get Group Members Criteria' -ForegroundColor DarkGray
    Write-Host ''

    $groupId = Show-FieldPrompt -Label 'GroupID' `
        -Default $(if ($Defaults.GroupID) { $Defaults.GroupID } else { '' }) `
        -Description 'Numeric ID of the group to retrieve members for. (Required)' `
        -Required $true

    return @{
        GroupID = $groupId
    }
}

function Invoke-GroupsGetMembers {
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
        $msg = 'InputData is null or missing. GroupID is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $null
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $groupId = if ($InputData['GroupID']) { "$($InputData['GroupID'])".Trim() } else { '' }

    if ([string]::IsNullOrEmpty($groupId)) {
        $msg = 'GroupID is required and must not be empty.'
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

    Write-CyberArkLog -Level 'INFO'  -Message "Starting group members retrieval for group ID: $groupId"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/UserGroups/$encodedId/Members"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/UserGroups/$encodedId/Members" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Get group members failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $members = if ($response.Data -and $response.Data.PSObject.Properties['value']) {
        @($response.Data.value)
    } else { @() }

    if ((-not $members) -or $members.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No members found in group.'
        # Not a failure — a valid empty result
        return $result
    }

    foreach ($m in $members) {
        $result.Results.Add([PSCustomObject]@{
            MemberID      = $m.id
            Username      = $m.username
            UserType      = $m.userType
            ComponentUser = $m.componentUser
        })
        $result.Successes++
        $result.ItemsProcessed++
    }

    Write-CyberArkLog -Level 'INFO' -Message "Group members retrieval complete. Members retrieved: $($result.Successes)."
    return $result
}
