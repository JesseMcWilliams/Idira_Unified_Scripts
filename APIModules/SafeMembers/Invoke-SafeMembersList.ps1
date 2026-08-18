#Requires -Version 5.1

$ModuleMeta = @{
    Name                 = 'List Safe Members'
    Category             = 'SafeMembers'
    Action               = 'List'
    Description          = 'Retrieve all members of a safe with their permissions.'
    SupportedSystems     = @('ISPSS', 'SelfHosted')
    SupportsWhatIf       = $false
    AcceptsInputFile     = $false
    ProducesOutput       = $true
    HasCustomInput       = $true
    ExcludeFromExportAll = $true
    InputSchema          = @(
        @{ Column = 'SafeName'; Required = $false; Description = 'Name of the safe. Leave blank for all safes.' }
    )
    Priority             = 20
    Version              = '1.0.0'
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
        -Description 'Name of the safe to list members for. Leave blank to retrieve members for all safes.'

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

    if (-not $InputData) { $InputData = @{} }

    $safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }

    # Determine the set of safes to query: one named safe, or all safes when blank
    [array]$safeNames = @()
    if ([string]::IsNullOrEmpty($safeName)) {
        Write-CyberArkLog -Level 'INFO' -Message 'No SafeName provided — retrieving members for all safes.'
        $safesResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/Safes' -WhatIf:$WhatIf.IsPresent
        if (-not $safesResp.IsSuccess) {
            $msg = "Safe list failed (HTTP $($safesResp.StatusCode)): $($safesResp.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $safesResp.ErrorDetails })
            $result.Failures++
            $result.ItemsProcessed++
            $result.IsFatal = ($safesResp.StatusCode -in @(401, 0))
            return $result
        }
        if ($safesResp.Data -and $safesResp.Data.PSObject.Properties['value']) {
            $safeNames = @($safesResp.Data.value | ForEach-Object { $_.safeName })
        }
        if ($safeNames.Count -eq 0) {
            Write-CyberArkLog -Level 'WARN' -Message 'No safes returned.'
            return $result
        }
        Write-CyberArkLog -Level 'INFO' -Message "Found $($safeNames.Count) safes. Retrieving members for each."
    } else {
        $safeNames = @($safeName)
    }

    foreach ($sn in $safeNames) {
        $encodedSafe = [Uri]::EscapeDataString($sn)
        Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedSafe/Members"

        $response = Invoke-CyberArkAPI `
            -Token    $Token `
            -Method   'GET' `
            -Endpoint "/API/Safes/$encodedSafe/Members" `
            -WhatIf:  $WhatIf.IsPresent

        if (-not $response.IsSuccess) {
            if ($response.StatusCode -in @(401, 0)) {
                $result.IsFatal = $true
                return $result
            }
            Write-CyberArkLog -Level 'WARN' -Message "Members unavailable for safe '$sn' (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
            continue
        }

        [array]$members = if ($response.Data -and $response.Data.PSObject.Properties['value']) {
            @($response.Data.value)
        } else { @() }

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
                $msg = "Unexpected error mapping member '$memberName' in safe '$sn': $_"
                Write-CyberArkLog -Level 'ERROR' -Message $msg
                $result.Errors.Add([PSCustomObject]@{
                    InputData    = @{ SafeName = $sn; MemberName = $memberName }
                    ErrorMessage = $msg
                    ErrorDetails = $null
                })
                $result.Failures++
                $result.ItemsProcessed++
            }
        }
    }

    Write-CyberArkLog -Level 'INFO' -Message "Safe members list complete. Members retrieved: $($result.Successes)."
    return $result
}
