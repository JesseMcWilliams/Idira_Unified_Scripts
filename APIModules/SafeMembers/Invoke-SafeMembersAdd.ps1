#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Safe Member'
    Category         = 'SafeMembers'
    Action           = 'Add'
    Description      = 'Add a user, group, or role as a member of a safe with defined permissions.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';       Required = $true;  Description = 'Name of the safe.' }
        @{ Column = 'MemberName';     Required = $true;  Description = 'Username, group name, or role name to add.' }
        @{ Column = 'SearchIn';       Required = $false; Description = 'Where to search: Vault, or domain FQDN.' }
        @{ Column = 'MemberType';     Required = $false; Description = 'User / Group / Role (default: User).' }
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
    Priority         = 21
    Version          = '1.0.0'
}

function script:Get-PermissionSet {
    <#
        Returns a hashtable of all 20 CyberArk safe member permission fields
        set to the values appropriate for the requested role.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$Role
    )

    # Base: all permissions off
    $perms = @{
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
        'EndUser' {
            $perms.UseAccounts      = $true
            $perms.RetrieveAccounts = $true
            $perms.ListAccounts     = $true
        }
        'PowerUser' {
            $perms.UseAccounts             = $true
            $perms.RetrieveAccounts        = $true
            $perms.ListAccounts            = $true
            $perms.AddAccounts             = $true
            $perms.UpdateAccountContent    = $true
            $perms.UpdateAccountProperties = $true
            $perms.RenameAccounts          = $true
            $perms.DeleteAccounts          = $true
            $perms.UnlockAccounts          = $true
        }
        'SafeManager' {
            $perms.UseAccounts                            = $true
            $perms.RetrieveAccounts                       = $true
            $perms.ListAccounts                           = $true
            $perms.AddAccounts                            = $true
            $perms.UpdateAccountContent                   = $true
            $perms.UpdateAccountProperties                = $true
            $perms.InitiateCPMAccountManagementOperations = $true
            $perms.RenameAccounts                         = $true
            $perms.DeleteAccounts                         = $true
            $perms.UnlockAccounts                         = $true
            $perms.ManageSafe                             = $true
            $perms.ManageSafeMembers                      = $true
            $perms.BackupSafe                             = $true
            $perms.ViewAuditLog                           = $true
            $perms.ViewSafeMembers                        = $true
            $perms.CreateFolders                          = $true
            $perms.DeleteFolders                          = $true
            $perms.MoveAccountsAndFolders                 = $true
        }
        default {
            # ReadOnly (and unknown roles)
            $perms.ListAccounts     = $true
            $perms.ViewAuditLog     = $true
            $perms.ViewSafeMembers  = $true
        }
    }

    return $perms
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

function Get-SafeMembersAddInput {
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

    Write-Host '  New Safe Member Details  (press Enter to accept each default)' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Name of the safe.'

    $memberName = Show-FieldPrompt -Label 'MemberName' `
        -Default $(if ($Defaults['MemberName']) { $Defaults['MemberName'] } else { '' }) `
        -Required $true `
        -Description 'Username, group name, or role name to add.'

    $searchIn = Show-FieldPrompt -Label 'SearchIn' `
        -Default $(if ($Defaults['SearchIn']) { $Defaults['SearchIn'] } else { 'Vault' }) `
        -Description 'Vault for local users; domain FQDN for AD users (e.g. domain.com).'

    $memberType = Show-FieldPrompt -Label 'MemberType' `
        -Default $(if ($Defaults['MemberType']) { $Defaults['MemberType'] } else { 'User' }) `
        -Description 'User / Group / Role'

    $expirationDate = Show-FieldPrompt -Label 'ExpirationDate' `
        -Default $(if ($Defaults['ExpirationDate']) { $Defaults['ExpirationDate'] } else { '' }) `
        -Description 'Membership expiration date (yyyy-MM-dd), or leave blank for no expiry.'

    Write-Host ''
    Write-Host '  Permission Mode:' -ForegroundColor DarkGray
    Write-Host '    1 = Role       (named permission preset)'
    Write-Host '    2 = Specified  (enter each permission individually)'
    Write-Host ''

    $modeChoice = Read-Host '  Select mode (1-2, default=1)'

    $permissionRole = 'ReadOnly'
    $specifiedPerms = $null

    if ($modeChoice -eq '2') {
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
        Write-Host '    1 = ReadOnly'
        Write-Host '    2 = EndUser'
        Write-Host '    3 = PowerUser'
        Write-Host '    4 = SafeManager'
        Write-Host ''
        $roleChoice = Read-Host '  Select role (1-4, default=1)'
        $permissionRole = switch ($roleChoice) {
            '2' { 'EndUser' }
            '3' { 'PowerUser' }
            '4' { 'SafeManager' }
            default { 'ReadOnly' }
        }
    }

    $inputData = @{
        SafeName       = $safeName
        MemberName     = $memberName
        SearchIn       = $searchIn
        MemberType     = $memberType
        PermissionRole = $permissionRole
        ExpirationDate = $expirationDate
    }

    if ($null -ne $specifiedPerms) {
        $inputData.Permissions = $specifiedPerms
    }

    return $inputData
}

function Invoke-SafeMembersAdd {
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

    # Validate required field SafeName
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

    # Validate required field MemberName
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

    $encodedSafe    = [Uri]::EscapeDataString($safeName)
    $permissionRole = if ($InputData['PermissionRole']) { $InputData['PermissionRole'] } else { 'ReadOnly' }

    # Resolve permissions: interactive Specified > CSV Specified columns > named role
    $permissions = if ($InputData['Permissions'] -and $InputData['Permissions'] -is [hashtable]) {
        $InputData['Permissions']
    } elseif ((script:Test-HasSpecifiedColumns -Data $InputData) -or $permissionRole -eq 'Specified') {
        script:Get-SpecifiedPermissions -Data $InputData
    } else {
        script:Get-PermissionSet -Role $permissionRole
    }

    $body = @{
        MemberName               = $memberName
        SearchIn                 = if ($InputData['SearchIn']) { $InputData['SearchIn'] } else { 'Vault' }
        MembershipExpirationDate = if ($InputData['ExpirationDate']) { $InputData['ExpirationDate'] } else { $null }
        Permissions              = $permissions
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Adding member '$memberName' to safe '$safeName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Safes/$encodedSafe/Members | MemberName='$memberName' Role='$permissionRole'"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: would POST /API/Safes/$encodedSafe/Members for member '$memberName'."
        $result.Results.Add([PSCustomObject]@{
            SafeName       = $safeName
            MemberName     = $memberName
            MemberType     = if ($InputData['MemberType']) { $InputData['MemberType'] } else { 'User' }
            PermissionRole = $permissionRole
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint "/API/Safes/$encodedSafe/Members" `
        -Body     $body `
        -WhatIf:  $false

    if (-not $response.IsSuccess) {
        $msg = "Add safe member failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $member = if ($response.Data) { $response.Data } else { $null }

    $result.Results.Add([PSCustomObject]@{
        SafeName       = if ($member -and $member.safeName)    { $member.safeName }    else { $safeName }
        MemberName     = if ($member -and $member.memberName)  { $member.memberName }  else { $memberName }
        MemberType     = if ($member -and $member.memberType)  { $member.memberType }  else { if ($InputData['MemberType']) { $InputData['MemberType'] } else { 'User' } }
        PermissionRole = $permissionRole
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Member '$memberName' added to safe '$safeName' successfully."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
