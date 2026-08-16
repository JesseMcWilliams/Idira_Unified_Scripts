#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Update Safe Member'
    Category         = 'SafeMembers'
    Action           = 'Update'
    Description      = 'Update the permissions or expiration date of an existing safe member.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';       Required = $true;  Description = 'Name of the safe.' }
        @{ Column = 'MemberName';     Required = $true;  Description = 'Username, group, or role to update.' }
        @{ Column = 'PermissionRole'; Required = $false; Description = 'ReadOnly / EndUser / PowerUser / SafeManager / Custom.' }
        @{ Column = 'ExpirationDate'; Required = $false; Description = 'Membership expiration date (yyyy-MM-dd) or blank.' }
    )
    Priority         = 22
    Version          = '1.0.0'
}

function Get-PermissionSet {
    <#
        Internal helper. Returns a hashtable of all CyberArk safe member permission booleans
        based on the supplied role name, or prompts for each permission when role is 'Custom'.

        Parameters:
            Role  - one of: ReadOnly, EndUser, PowerUser, SafeManager, Custom
                    Any other / blank value defaults to ReadOnly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Role
    )

    # Base: all permissions off
    $p = @{
        UseAccounts                            = $false
        RetrieveAccounts                       = $false
        ListAccounts                           = $false
        AddAccounts                            = $false
        UpdateAccountContent                   = $false
        UpdateAccountProperties                = $false
        InitiateCPMAccountManagementOperations = $false
        SpecifyNextAccountContent              = $false
        RenameAccounts                         = $false
        DeleteAccounts                         = $false
        UnlockAccounts                         = $false
        ManageSafe                             = $false
        ManageSafeMembers                      = $false
        BackupSafe                             = $false
        ViewAuditLog                           = $false
        ViewSafeMembers                        = $false
        AccessWithoutConfirmation              = $false
        CreateFolders                          = $false
        DeleteFolders                          = $false
        MoveAccountsAndFolders                 = $false
    }

    switch ($Role) {
        'ReadOnly' {
            $p.ListAccounts  = $true
            $p.ViewAuditLog  = $true
        }
        'EndUser' {
            $p.UseAccounts       = $true
            $p.RetrieveAccounts  = $true
            $p.ListAccounts      = $true
        }
        'PowerUser' {
            $p.UseAccounts                            = $true
            $p.RetrieveAccounts                       = $true
            $p.ListAccounts                           = $true
            $p.AddAccounts                            = $true
            $p.UpdateAccountContent                   = $true
            $p.UpdateAccountProperties                = $true
            $p.RenameAccounts                         = $true
            $p.DeleteAccounts                         = $true
            $p.UnlockAccounts                         = $true
        }
        'SafeManager' {
            $p.UseAccounts                            = $true
            $p.RetrieveAccounts                       = $true
            $p.ListAccounts                           = $true
            $p.AddAccounts                            = $true
            $p.UpdateAccountContent                   = $true
            $p.UpdateAccountProperties                = $true
            $p.RenameAccounts                         = $true
            $p.DeleteAccounts                         = $true
            $p.UnlockAccounts                         = $true
            $p.ManageSafe                             = $true
            $p.ManageSafeMembers                      = $true
            $p.BackupSafe                             = $true
            $p.ViewAuditLog                           = $true
            $p.ViewSafeMembers                        = $true
            $p.CreateFolders                          = $true
            $p.DeleteFolders                          = $true
            $p.MoveAccountsAndFolders                 = $true
        }
        'Custom' {
            Write-Host ''
            Write-Host '  Custom Permissions  (Y=true, N=false for each field)' -ForegroundColor DarkGray
            Write-Host ''
            foreach ($key in ($p.Keys | Sort-Object)) {
                $answer = Show-FieldPrompt -Label $key -Default 'N' -Description "Grant $key permission? (Y/N)"
                $p[$key] = ($answer -match '^[Yy]$')
            }
        }
        default {
            # Default to ReadOnly for unrecognised / blank roles
            $p.ListAccounts = $true
            $p.ViewAuditLog = $true
        }
    }

    return $p
}

function Get-SafeMembersUpdateInput {
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

    Write-Host '  Update Safe Member  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Name of the safe containing the member to update. (Required)'

    $memberName = Show-FieldPrompt -Label 'MemberName' `
        -Default $(if ($Defaults['MemberName']) { $Defaults['MemberName'] } else { '' }) `
        -Required $true `
        -Description 'Username, group name, or role to update. (Required)'

    Write-Host ''
    Write-Host '  Permission Role:' -ForegroundColor DarkGray
    Write-Host '    1 = ReadOnly' -ForegroundColor DarkGray
    Write-Host '    2 = EndUser' -ForegroundColor DarkGray
    Write-Host '    3 = PowerUser' -ForegroundColor DarkGray
    Write-Host '    4 = SafeManager' -ForegroundColor DarkGray
    Write-Host '    5 = Custom' -ForegroundColor DarkGray
    Write-Host ''

    $roleChoice = Show-FieldPrompt -Label 'PermissionRole' `
        -Default $(if ($Defaults['PermissionRole']) { $Defaults['PermissionRole'] } else { '1' }) `
        -Description 'Enter role number (1-5) or role name (ReadOnly/EndUser/PowerUser/SafeManager/Custom).'

    $permissionRole = switch ($roleChoice.Trim()) {
        '1'            { 'ReadOnly'    }
        '2'            { 'EndUser'     }
        '3'            { 'PowerUser'   }
        '4'            { 'SafeManager' }
        '5'            { 'Custom'      }
        'ReadOnly'     { 'ReadOnly'    }
        'EndUser'      { 'EndUser'     }
        'PowerUser'    { 'PowerUser'   }
        'SafeManager'  { 'SafeManager' }
        'Custom'       { 'Custom'      }
        default        { 'ReadOnly'    }
    }

    $expirationDate = Show-FieldPrompt -Label 'ExpirationDate' `
        -Default $(if ($Defaults['ExpirationDate']) { $Defaults['ExpirationDate'] } else { '' }) `
        -Description 'Membership expiration date (yyyy-MM-dd). Leave blank for no expiration.'

    return @{
        SafeName       = $safeName
        MemberName     = $memberName
        PermissionRole = $permissionRole
        ExpirationDate = $expirationDate
    }
}

function Invoke-SafeMembersUpdate {
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

    # Validate SafeName
    $safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }
    if (-not $safeName) {
        $msg = 'SafeName is required and cannot be empty.'
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

    # Validate MemberName
    $memberName = if ($InputData['MemberName']) { "$($InputData['MemberName'])".Trim() } else { '' }
    if (-not $memberName) {
        $msg = 'MemberName is required and cannot be empty.'
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

    $encodedSafe   = [System.Uri]::EscapeDataString($safeName)
    $encodedMember = [System.Uri]::EscapeDataString($memberName)

    # Resolve permissions - InputData.Permissions (hashtable) takes priority over PermissionRole
    $permissions = if ($InputData['Permissions'] -and $InputData['Permissions'] -is [hashtable]) {
        $InputData['Permissions']
    } else {
        $role = if ($InputData['PermissionRole']) { "$($InputData['PermissionRole'])".Trim() } else { 'ReadOnly' }
        Get-PermissionSet -Role $role
    }

    # Resolve expiration date - null when blank (API expects null for no expiration)
    $expirationDate = if ($InputData['ExpirationDate'] -and "$($InputData['ExpirationDate'])".Trim() -ne '') {
        "$($InputData['ExpirationDate'])".Trim()
    } else {
        $null
    }

    # Build PUT body (MemberName is in the URL, not the body)
    $body = @{
        MembershipExpirationDate = $expirationDate
        Permissions              = $permissions
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Updating safe member '$memberName' in safe '$safeName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "PUT /API/Safes/$encodedSafe/Members/$encodedMember"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: Safe member update suppressed for '$memberName' in '$safeName'."
        $result.Results.Add([PSCustomObject]@{
            SafeName                 = $safeName
            MemberName               = $memberName
            MemberType               = ''
            MembershipExpirationDate = $expirationDate
            IsPredefinedUser         = $false
            Permissions              = $permissions
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'PUT' `
        -Endpoint "/API/Safes/$encodedSafe/Members/$encodedMember" `
        -Body     $body

    if (-not $response.IsSuccess) {
        $msg = "Safe member update failed for '$memberName' in '$safeName' (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Map response
    $member = if ($response.Data) { $response.Data } else { $null }

    $result.Results.Add([PSCustomObject]@{
        SafeName                 = if ($member -and $member.safeName)   { $member.safeName }   else { $safeName }
        MemberName               = if ($member -and $member.memberName) { $member.memberName } else { $memberName }
        MemberType               = if ($member -and $member.memberType) { $member.memberType } else { '' }
        MembershipExpirationDate = if ($member)                         { $member.membershipExpirationDate } else { $expirationDate }
        IsPredefinedUser         = if ($member)                         { [bool]$member.isPredefinedUser }   else { $false }
        Permissions              = if ($member -and $member.permissions) { $member.permissions } else { $permissions }
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe member '$memberName' updated successfully in safe '$safeName'."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
