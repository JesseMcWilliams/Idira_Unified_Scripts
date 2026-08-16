#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Safe Members'
    Category         = 'SafeMembers'
    Action           = 'List'
    Description      = 'Retrieve all members of a safe with their permissions.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName'; Required = $true; Description = 'Name of the safe.' }
    )
    Priority         = 20
    Version          = '1.0.0'
}

function Get-SafeMembersListInput {
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

    Write-Host '  Safe Member List Criteria' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Description 'Name of the safe to list members for. (Required)' `
        -Required $true

    return @{
        SafeName = $safeName
    }
}

function Invoke-SafeMembersList {
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
        $msg = 'InputData is null or missing. SafeName is required.'
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

    $safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }

    if ([string]::IsNullOrEmpty($safeName)) {
        $msg = 'SafeName is required and must not be empty.'
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

    $encodedSafe = [Uri]::EscapeDataString($safeName)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting safe members list retrieval for safe: $safeName"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedSafe/Members"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Safes/$encodedSafe/Members" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Safe members list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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
        Write-CyberArkLog -Level 'WARN' -Message "No members returned for safe: $safeName"
        # Not a failure - a valid empty result
        return $result
    }

    foreach ($member in $members) {
        try {
            $expirationDate = if ($member.PSObject.Properties['membershipExpirationDate'] -and $member.membershipExpirationDate) {
                $member.membershipExpirationDate
            } else { '' }
            $perms = if ($member.PSObject.Properties['permissions'] -and $member.permissions) { $member.permissions } else { $null }

            $result.Results.Add([PSCustomObject]@{
                SafeName          = $member.safeName
                MemberName        = $member.memberName
                MemberType        = if ($member.PSObject.Properties['memberType'])       { $member.memberType }       else { '' }
                SearchIn          = ''
                IsPredefined      = if ($member.PSObject.Properties['isPredefinedUser']) { $member.isPredefinedUser } else { $false }
                IsMemberOfSafe    = if ($member.PSObject.Properties['isMemberOfSafe'])   { $member.isMemberOfSafe }   else { $false }
                ExpirationDate    = $expirationDate
                UseAccounts       = if ($perms -and $perms.PSObject.Properties['UseAccounts'])       { $perms.UseAccounts }       else { $false }
                RetrieveAccounts  = if ($perms -and $perms.PSObject.Properties['RetrieveAccounts'])  { $perms.RetrieveAccounts }  else { $false }
                ListAccounts      = if ($perms -and $perms.PSObject.Properties['ListAccounts'])      { $perms.ListAccounts }      else { $false }
                AddAccounts       = if ($perms -and $perms.PSObject.Properties['AddAccounts'])       { $perms.AddAccounts }       else { $false }
                ManageSafe        = if ($perms -and $perms.PSObject.Properties['ManageSafe'])        { $perms.ManageSafe }        else { $false }
                ManageSafeMembers = if ($perms -and $perms.PSObject.Properties['ManageSafeMembers']) { $perms.ManageSafeMembers } else { $false }
                ViewAuditLog      = if ($perms -and $perms.PSObject.Properties['ViewAuditLog'])      { $perms.ViewAuditLog }      else { $false }
            })
            $result.Successes++
            $result.ItemsProcessed++
        } catch {
            $memberName = try { "$($member.memberName)" } catch { '(unknown)' }
            $msg = "Unexpected error mapping member '$memberName': $_"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = @{ MemberName = $memberName }
                ErrorMessage = $msg
                ErrorDetails = $null
            })
            $result.Failures++
            $result.ItemsProcessed++
        }
    }

    Write-CyberArkLog -Level 'INFO' -Message "Safe members list complete. Members retrieved: $($result.Successes)."
    return $result
}
