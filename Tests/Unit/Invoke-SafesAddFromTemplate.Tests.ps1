#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Safes\Invoke-SafesAddFromTemplate.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafesAddFromTemplateInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesAddFromTemplate.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-SafesAddFromTemplate into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafesAddFromTemplateTests' -MinLevel 'ERROR'

    # Minimal token stub
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    $script:ValidInput = @{
        SafeName    = 'NewSafe'
        Description = 'Stamped from template'
    }

    # Sample template safe settings (GET /API/Safes/TemplateSafe response shape - camelCase)
    $script:TemplateSafeResponse = [PSCustomObject]@{
        safeName                  = 'TemplateSafe'
        description               = 'The standard template'
        location                  = '\Templates'
        managingCPM              = 'PasswordManager'
        numberOfVersionsRetention = 7
        numberOfDaysRetention     = 0
        autoPurgeEnabled          = $true
        olacEnabled               = $true
    }

    # Sample template safe member list (GET /API/Safes/TemplateSafe/Members response shape).
    # One role group (excluded by prefix), one non-role group, one user (both copied).
    $script:TemplateMembersResponse = [PSCustomObject]@{
        value = @(
            [PSCustomObject]@{
                memberName = 'CyberArk_TemplateSafe_Admins'
                memberType = 'Group'
                membershipExpirationDate = '2026-01-01'
                permissions = [PSCustomObject]@{ manageSafe = $true; manageSafeMembers = $true }
            },
            [PSCustomObject]@{
                memberName = 'AdminGroup'
                memberType = 'Group'
                membershipExpirationDate = $null
                permissions = [PSCustomObject]@{ useAccounts = $true; listAccounts = $true }
            },
            [PSCustomObject]@{
                memberName = 'jdoe'
                memberType = 'User'
                membershipExpirationDate = $null
                permissions = [PSCustomObject]@{ useAccounts = $true; retrieveAccounts = $true; listAccounts = $true }
            }
        )
    }

    $script:CreatedSafeResponse = [PSCustomObject]@{
        safeName                  = 'NewSafe'
        description               = 'Stamped from template'
        location                  = '\Templates'
        managingCPM              = 'PasswordManager'
        numberOfVersionsRetention = 7
        numberOfDaysRetention     = 0
        autoPurgeEnabled          = $true
        olacEnabled               = $true
    }

    # Factory: standard success envelope
    function script:New-OkResponse {
        param([object]$Data, [int]$StatusCode = 200)
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = $StatusCode
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $Data
        }
    }

    # Factory: standard failure envelope
    function script:New-ErrResponse {
        param([int]$StatusCode = 403, [string]$ErrorMessage = 'Forbidden')
        return [PSCustomObject]@{
            IsSuccess     = $false
            StatusCode    = $StatusCode
            StatusMessage = "HTTP $StatusCode"
            ErrorMessage  = $ErrorMessage
            ErrorDetails  = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $ErrorMessage; Details = $null }
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $null
        }
    }

    # Routes the single Invoke-CyberArkAPI mock to the right canned response by Method/Endpoint.
    # Member-add POSTs echo back the submitted memberName/memberType, like the real API does.
    function script:Invoke-DefaultRouting {
        param($Method, $Endpoint, $Body)
        if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe') {
            return script:New-OkResponse -Data $script:TemplateSafeResponse
        }
        if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe/Members') {
            return script:New-OkResponse -Data $script:TemplateMembersResponse
        }
        if ($Method -eq 'POST' -and $Endpoint -eq '/API/Safes') {
            return script:New-OkResponse -Data $script:CreatedSafeResponse -StatusCode 201
        }
        if ($Method -eq 'POST' -and $Endpoint -like '/API/Safes/NewSafe/Members') {
            return script:New-OkResponse -Data ([PSCustomObject]@{ safeName = 'NewSafe'; memberName = $Body.memberName; memberType = $Body.memberType }) -StatusCode 201
        }
        return script:New-ErrResponse -StatusCode 500 -ErrorMessage 'Unrouted mock call'
    }

    function script:Reset-MockActiveProfile {
        $script:ActiveProfile = [PSCustomObject]@{
            Role_Template_Safe = 'TemplateSafe'
            Role_Group_Prefix  = 'CyberArk_'
            IgnoreSSL          = $false
        }
        # Manage-Privilege.ps1 defines this as a script:-scoped constant, dot-sourced into every
        # module's effective scope. Tests dot-source only the module file, so it must be
        # set explicitly here - same reason $script:ActiveProfile is faked above.
        $script:ExcludedTemplateMemberNames = @()
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
    Remove-Variable -Name ActiveProfile -Scope Script -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'T01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'T02 - Category is Safes and Action is AddFromTemplate' {
        $ModuleMeta.Category | Should -Be 'Safes'
        $ModuleMeta.Action   | Should -Be 'AddFromTemplate'
    }

    It 'T03 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'T04 - SupportedSystems contains ISPSS and SelfHosted' {
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
    }

    It 'T05 - InputSchema contains SafeName with Required=$true' {
        $safeNameField = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'SafeName' }
        $safeNameField          | Should -Not -BeNullOrEmpty
        $safeNameField.Required | Should -BeTrue
    }

    It 'T06 - InputSchema contains Description with Required=$false' {
        $descField = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'Description' }
        $descField          | Should -Not -BeNullOrEmpty
        $descField.Required | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAddFromTemplate - success' {

    BeforeEach {
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint -Body $Body }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'T07 - IsFatal is $false' {
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'T08 - creates the safe: one Results row with ItemType=Safe' {
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        ($r.Results | Where-Object { $_.ItemType -eq 'Safe' }).Count | Should -Be 1
    }

    It 'T09 - copies only the two non-role members (excludes the CyberArk_ group)' {
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $memberRows = @($r.Results | Where-Object { $_.ItemType -eq 'Member' })
        $memberRows.Count            | Should -Be 2
        $memberRows.MemberName       | Should -Not -Contain 'CyberArk_TemplateSafe_Admins'
        $memberRows.MemberName       | Should -Contain 'AdminGroup'
    }

    It 'T09a - global $script:ExcludedTemplateMemberNames also excludes a member, regardless of type' {
        $script:ExcludedTemplateMemberNames = @('jdoe')
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $memberRows = @($r.Results | Where-Object { $_.ItemType -eq 'Member' })
        $memberRows.Count      | Should -Be 1
        $memberRows.MemberName | Should -Not -Contain 'jdoe'
        $memberRows.MemberName | Should -Contain 'AdminGroup'
    }

    It 'T09b - exclusion match is case-insensitive and exact (not a prefix match)' {
        $script:ExcludedTemplateMemberNames = @('JDOE', 'AdminGroupExtra')
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $memberRows = @($r.Results | Where-Object { $_.ItemType -eq 'Member' })
        $memberRows.MemberName | Should -Not -Contain 'jdoe'
        $memberRows.MemberName | Should -Contain 'AdminGroup'
    }

    It 'T10 - Successes=3 (1 safe + 2 members), Failures=0' {
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes | Should -Be 3
        $r.Failures  | Should -Be 0
    }

    It 'T11 - safe creation POST body copies template settings' {
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes' -and
            $Body.SafeName -eq 'NewSafe' -and
            $Body.Description -eq 'Stamped from template' -and
            $Body.Location -eq '\Templates' -and
            $Body.ManagingCPM -eq 'PasswordManager' -and
            $Body.AutoPurgeEnabled -eq $true
        } -Times 1
    }

    It 'T11a - OLACEnabled is never included in the safe creation body' {
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes' -and
            -not $Body.ContainsKey('OLACEnabled')
        } -Times 1
    }

    It 'T11b - template has NumberOfDaysRetention=0: only NumberOfVersionsRetention is sent' {
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes' -and
            $Body.NumberOfVersionsRetention -eq 7 -and
            (-not $Body.ContainsKey('NumberOfDaysRetention'))
        } -Times 1
    }

    It 'T11c - template has NumberOfDaysRetention>0: only NumberOfDaysRetention is sent' {
        $script:TemplateSafeResponse.numberOfDaysRetention = 90
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes' -and
            $Body.NumberOfDaysRetention -eq 90 -and
            (-not $Body.ContainsKey('NumberOfVersionsRetention'))
        } -Times 1
        $script:TemplateSafeResponse.numberOfDaysRetention = 0
    }

    It 'T12 - member copy POST omits membershipExpirationDate (always null)' {
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes/NewSafe/Members' -and
            $null -eq $Body.membershipExpirationDate
        } -Times 2
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAddFromTemplate - WhatIf' {

    BeforeEach {
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET') { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint }
            else { script:New-OkResponse -Data $null }
        }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'T13 - WhatIf: no POST call is made' {
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } -Times 0
    }

    It 'T14 - WhatIf: still reads the template safe and its members (GET calls happen)' {
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } -Times 2
    }

    It 'T15 - WhatIf: synthetic Results contain 1 safe row + 2 member rows' {
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Results.Count | Should -Be 3
        $r.IsFatal        | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAddFromTemplate - validation' {

    BeforeEach {
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI { }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'T16 - empty SafeName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = ''
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'T17 - Role_Template_Safe blank on profile: Failures=1, no API call' {
        $script:ActiveProfile.Role_Template_Safe = ''
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'T18 - Role_Group_Prefix blank on profile: Failures=1, no API call' {
        $script:ActiveProfile.Role_Group_Prefix = ''
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAddFromTemplate - errors' {

    BeforeEach {
        script:Reset-MockActiveProfile
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'T19 - template safe not found (404): IsFatal=$false, error added, no safe created' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -ErrorMessage 'Safe not found' }
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Errors.Count | Should -Be 1
        $r.Results.Count | Should -Be 0
    }

    It 'T20 - template safe read returns 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'T21 - template members read fails (403): IsFatal=$false, safe not created' {
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe') {
                script:New-OkResponse -Data $script:TemplateSafeResponse
            } else {
                script:New-ErrResponse -StatusCode 403 -ErrorMessage 'Forbidden'
            }
        }
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal        | Should -BeFalse
        $r.Errors.Count   | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } -Times 0
    }

    It 'T22 - safe creation POST fails (409): IsFatal=$false, no member POSTs attempted' {
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe') {
                script:New-OkResponse -Data $script:TemplateSafeResponse
            } elseif ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe/Members') {
                script:New-OkResponse -Data $script:TemplateMembersResponse
            } else {
                script:New-ErrResponse -StatusCode 409 -ErrorMessage 'Safe already exists'
            }
        }
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal        | Should -BeFalse
        $r.Errors.Count   | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' -and $Endpoint -like '*Members*' } -Times 0
    }

    It 'T23 - one member POST fails (403): loop continues, other member still copied' {
        $callCount = 0
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe') {
                return script:New-OkResponse -Data $script:TemplateSafeResponse
            }
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe/Members') {
                return script:New-OkResponse -Data $script:TemplateMembersResponse
            }
            if ($Method -eq 'POST' -and $Endpoint -eq '/API/Safes') {
                return script:New-OkResponse -Data $script:CreatedSafeResponse -StatusCode 201
            }
            $script:callCount++
            if ($script:callCount -eq 1) {
                return script:New-ErrResponse -StatusCode 403 -ErrorMessage 'Forbidden'
            }
            return script:New-OkResponse -Data ([PSCustomObject]@{ safeName = 'NewSafe'; memberName = 'member'; memberType = 'Group' }) -StatusCode 201
        }
        $script:callCount = 0
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal        | Should -BeFalse
        $r.Failures       | Should -Be 1
        ($r.Results | Where-Object { $_.ItemType -eq 'Member' }).Count | Should -Be 1
    }

    It 'T24 - member POST returns 401: IsFatal=$true, loop stops' {
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe') {
                return script:New-OkResponse -Data $script:TemplateSafeResponse
            }
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe/Members') {
                return script:New-OkResponse -Data $script:TemplateMembersResponse
            }
            if ($Method -eq 'POST' -and $Endpoint -eq '/API/Safes') {
                return script:New-OkResponse -Data $script:CreatedSafeResponse -StatusCode 201
            }
            return script:New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized'
        }
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}
