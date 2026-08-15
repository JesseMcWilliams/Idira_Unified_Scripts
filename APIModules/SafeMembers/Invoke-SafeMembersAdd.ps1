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
        @{ Column = 'PermissionRole'; Required = $false; Description = 'ReadOnly / EndUser / PowerUser / SafeManager / Custom (default: ReadOnly).' }
        @{ Column = 'ExpirationDate'; Required = $false; Description = 'Membership expiration date (yyyy-MM-dd) or blank.' }
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
        -Default $(if ($Defaults.SafeName) { $Defaults.SafeName } else { '' }) `
        -Required $true `
        -Description 'Name of the safe.'

    $memberName = Show-FieldPrompt -Label 'MemberName' `
        -Default $(if ($Defaults.MemberName) { $Defaults.MemberName } else { '' }) `
        -Required $true `
        -Description 'Username, group name, or role name to add.'

    $searchIn = Show-FieldPrompt -Label 'SearchIn' `
        -Default $(if ($Defaults.SearchIn) { $Defaults.SearchIn } else { 'Vault' }) `
        -Description 'Vault for local users; domain FQDN for AD users (e.g. domain.com).'

    $memberType = Show-FieldPrompt -Label 'MemberType' `
        -Default $(if ($Defaults.MemberType) { $Defaults.MemberType } else { 'User' }) `
        -Description 'User / Group / Role'

    $expirationDate = Show-FieldPrompt -Label 'ExpirationDate' `
        -Default $(if ($Defaults.ExpirationDate) { $Defaults.ExpirationDate } else { '' }) `
        -Description 'Membership expiration date (yyyy-MM-dd), or leave blank for no expiry.'

    Write-Host ''
    Write-Host '  Permission Role:' -ForegroundColor DarkGray
    Write-Host '    1 = ReadOnly'
    Write-Host '    2 = EndUser'
    Write-Host '    3 = PowerUser'
    Write-Host '    4 = SafeManager'
    Write-Host '    5 = Custom'

    $roleChoice = Read-Host '  Select role (1-5, default=1)'

    $permissionRole = 'ReadOnly'
    $customPermissions = $null

    switch ($roleChoice) {
        '2' { $permissionRole = 'EndUser' }
        '3' { $permissionRole = 'PowerUser' }
        '4' { $permissionRole = 'SafeManager' }
        '5' {
            $permissionRole = 'Custom'
            $customPermissions = @{
                UseAccounts                            = (Read-Host '    UseAccounts (Y/N)') -match '^[Yy]$'
                RetrieveAccounts                       = (Read-Host '    RetrieveAccounts (Y/N)') -match '^[Yy]$'
                ListAccounts                           = (Read-Host '    ListAccounts (Y/N)') -match '^[Yy]$'
                AddAccounts                            = (Read-Host '    AddAccounts (Y/N)') -match '^[Yy]$'
                UpdateAccountContent                   = (Read-Host '    UpdateAccountContent (Y/N)') -match '^[Yy]$'
                UpdateAccountProperties                = (Read-Host '    UpdateAccountProperties (Y/N)') -match '^[Yy]$'
                InitiateCPMAccountManagementOperations = (Read-Host '    InitiateCPMAccountManagementOperations (Y/N)') -match '^[Yy]$'
                SpecifyNextAccountContent              = (Read-Host '    SpecifyNextAccountContent (Y/N)') -match '^[Yy]$'
                RenameAccounts                         = (Read-Host '    RenameAccounts (Y/N)') -match '^[Yy]$'
                DeleteAccounts                         = (Read-Host '    DeleteAccounts (Y/N)') -match '^[Yy]$'
                UnlockAccounts                         = (Read-Host '    UnlockAccounts (Y/N)') -match '^[Yy]$'
                ManageSafe                             = (Read-Host '    ManageSafe (Y/N)') -match '^[Yy]$'
                ManageSafeMembers                      = (Read-Host '    ManageSafeMembers (Y/N)') -match '^[Yy]$'
                BackupSafe                             = (Read-Host '    BackupSafe (Y/N)') -match '^[Yy]$'
                ViewAuditLog                           = (Read-Host '    ViewAuditLog (Y/N)') -match '^[Yy]$'
                ViewSafeMembers                        = (Read-Host '    ViewSafeMembers (Y/N)') -match '^[Yy]$'
                AccessWithoutConfirmation              = (Read-Host '    AccessWithoutConfirmation (Y/N)') -match '^[Yy]$'
                CreateFolders                          = (Read-Host '    CreateFolders (Y/N)') -match '^[Yy]$'
                DeleteFolders                          = (Read-Host '    DeleteFolders (Y/N)') -match '^[Yy]$'
                MoveAccountsAndFolders                 = (Read-Host '    MoveAccountsAndFolders (Y/N)') -match '^[Yy]$'
            }
        }
        default { $permissionRole = 'ReadOnly' }
    }

    $inputData = @{
        SafeName       = $safeName
        MemberName     = $memberName
        SearchIn       = $searchIn
        MemberType     = $memberType
        PermissionRole = $permissionRole
        ExpirationDate = $expirationDate
    }

    if ($null -ne $customPermissions) {
        $inputData.Permissions = $customPermissions
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

    $encodedSafe   = [Uri]::EscapeDataString($safeName)
    $permissionRole = if ($InputData['PermissionRole']) { $InputData['PermissionRole'] } else { 'ReadOnly' }

    # Resolve permissions: use explicit Custom hashtable if provided, otherwise use preset
    $permissions = if ($InputData['Permissions'] -and $InputData['PermissionRole'] -eq 'Custom') {
        $InputData['Permissions']
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
