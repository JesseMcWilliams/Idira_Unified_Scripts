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
        @{ Column = 'PermissionRole'; Required = $false; Description = 'Role or Specified. Role values: ReadOnly / EndUser / PowerUser / SafeManager. Use Specified to set individual permissions.' }
        @{ Column = 'ExpirationDate'; Required = $false; Description = 'Membership expiration date (yyyy-MM-dd) or blank.' }
        @{ Column = 'UseAccounts';                            Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'RetrieveAccounts';                       Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'ListAccounts';                           Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'AddAccounts';                            Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'UpdateAccountContent';                   Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'UpdateAccountProperties';                Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'InitiateCPMAccountManagementOperations'; Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'SpecifyNextAccountContent';              Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'RenameAccounts';                         Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'DeleteAccounts';                         Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'UnlockAccounts';                         Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'ManageSafe';                             Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'ManageSafeMembers';                      Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'BackupSafe';                             Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'ViewAuditLog';                           Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'ViewSafeMembers';                        Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'AccessWithoutConfirmation';              Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'CreateFolders';                          Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'DeleteFolders';                          Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'MoveAccountsAndFolders';                 Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
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
        default {
            # Default to ReadOnly for unrecognised / blank roles
            $p.ListAccounts = $true
            $p.ViewAuditLog = $true
        }
    }

    return $p
}

$script:PermissionColumns = @(
    'UseAccounts', 'RetrieveAccounts', 'ListAccounts', 'AddAccounts',
    'UpdateAccountContent', 'UpdateAccountProperties',
    'InitiateCPMAccountManagementOperations', 'SpecifyNextAccountContent',
    'RenameAccounts', 'DeleteAccounts', 'UnlockAccounts',
    'ManageSafe', 'ManageSafeMembers', 'BackupSafe',
    'ViewAuditLog', 'ViewSafeMembers', 'AccessWithoutConfirmation',
    'CreateFolders', 'DeleteFolders', 'MoveAccountsAndFolders'
)

function script:Get-SpecifiedPermissions {
    param([hashtable]$Data)
    $perms = @{}
    foreach ($col in $script:PermissionColumns) {
        $raw = if ($Data.ContainsKey($col)) { "$($Data[$col])".Trim() } else { '' }
        $perms[$col] = ($raw -match '^(true|yes|1|y)$')
    }
    return $perms
}

function script:Test-HasSpecifiedColumns {
    param([hashtable]$Data)
    foreach ($col in $script:PermissionColumns) {
        if ($Data.ContainsKey($col)) { return $true }
    }
    return $false
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
    Write-Host '  Permission Mode:' -ForegroundColor DarkGray
    Write-Host '    1 = Role       (named permission preset)' -ForegroundColor DarkGray
    Write-Host '    2 = Specified  (enter each permission individually)' -ForegroundColor DarkGray
    Write-Host ''

    $modeChoice = Show-FieldPrompt -Label 'PermissionMode' `
        -Default '1' `
        -Description 'Select 1 for Role or 2 for Specified.'

    $permissionRole = 'ReadOnly'
    $specifiedPerms = $null

    if ($modeChoice.Trim() -eq '2') {
        $permissionRole = 'Specified'
        Write-Host ''
        Write-Host '  Enter Y or N for each permission (default=N):' -ForegroundColor DarkGray
        Write-Host ''
        $specifiedPerms = @{}
        foreach ($col in $script:PermissionColumns) {
            $answer = Show-FieldPrompt -Label $col -Default 'N' -Description "Grant $col permission? (Y/N)"
            $specifiedPerms[$col] = ($answer -match '^[Yy]$')
        }
    } else {
        Write-Host ''
        Write-Host '  Permission Role:' -ForegroundColor DarkGray
        Write-Host '    1 = ReadOnly' -ForegroundColor DarkGray
        Write-Host '    2 = EndUser' -ForegroundColor DarkGray
        Write-Host '    3 = PowerUser' -ForegroundColor DarkGray
        Write-Host '    4 = SafeManager' -ForegroundColor DarkGray
        Write-Host ''
        $roleChoice = Show-FieldPrompt -Label 'PermissionRole' `
            -Default $(if ($Defaults['PermissionRole']) { $Defaults['PermissionRole'] } else { '1' }) `
            -Description 'Enter role number (1-4) or role name (ReadOnly/EndUser/PowerUser/SafeManager).'
        $permissionRole = switch ($roleChoice.Trim()) {
            '1'           { 'ReadOnly'    }
            '2'           { 'EndUser'     }
            '3'           { 'PowerUser'   }
            '4'           { 'SafeManager' }
            'ReadOnly'    { 'ReadOnly'    }
            'EndUser'     { 'EndUser'     }
            'PowerUser'   { 'PowerUser'   }
            'SafeManager' { 'SafeManager' }
            default       { 'ReadOnly'    }
        }
    }

    $expirationDate = Show-FieldPrompt -Label 'ExpirationDate' `
        -Default $(if ($Defaults['ExpirationDate']) { $Defaults['ExpirationDate'] } else { '' }) `
        -Description 'Membership expiration date (yyyy-MM-dd). Leave blank for no expiration.'

    $inputData = @{
        SafeName       = $safeName
        MemberName     = $memberName
        PermissionRole = $permissionRole
        ExpirationDate = $expirationDate
    }

    if ($null -ne $specifiedPerms) {
        $inputData.Permissions = $specifiedPerms
    }

    return $inputData
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

    # Resolve permissions: interactive Specified > CSV Specified columns > named role
    $permissions = if ($InputData['Permissions'] -and $InputData['Permissions'] -is [hashtable]) {
        $InputData['Permissions']
    } elseif ((script:Test-HasSpecifiedColumns -Data $InputData) -or $InputData['PermissionRole'] -eq 'Specified') {
        script:Get-SpecifiedPermissions -Data $InputData
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
