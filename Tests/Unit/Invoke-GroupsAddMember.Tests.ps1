#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Groups\Invoke-GroupsAddMember.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-GroupsAddMemberInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Groups\Invoke-GroupsAddMember.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-GroupsAddMember into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'GroupsAddMemberTests' -MinLevel 'ERROR'

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

    $script:ValidInput = @{ GroupID = '42'; MemberID = '7'; MemberType = 'EPVUser' }

    # Factory: build a mock API success response for member POST
    function script:New-AddMemberApiResponse {
        param([int]$StatusCode = 201)
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = $StatusCode
            StatusMessage = 'Created'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $null
        }
    }

    # Factory: build a mock API failure response
    function script:New-ApiErrorResponse {
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
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'GAM01 - ModuleMeta.Name = Add Group Member' {
        $ModuleMeta.Name | Should -Be 'Add Group Member'
    }

    It 'GAM02 - ModuleMeta.SupportsWhatIf = $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsAddMember - success (201)' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-AddMemberApiResponse -StatusCode 201 }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GAM03 - Successes=1, ItemsProcessed=1 on success' {
        $r = Invoke-GroupsAddMember -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
    }

    It 'GAM04 - IsFatal=$false on success' {
        $r = Invoke-GroupsAddMember -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'GAM05 - POST method used' {
        Invoke-GroupsAddMember -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'POST' }
    }

    It 'GAM06 - endpoint = /API/UserGroups/42/Members' {
        Invoke-GroupsAddMember -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Endpoint -eq '/API/UserGroups/42/Members' }
    }

    It 'GAM07 - result entry has Added=$true, MemberID=7' {
        $r = Invoke-GroupsAddMember -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].Added    | Should -BeTrue
        $r.Results[0].MemberID | Should -Be '7'
    }

    It 'GAM08 - body contains memberId=7 as integer' {
        $capturedBody = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedBody -Value $PSBoundParameters.Body -Scope Script
            script:New-AddMemberApiResponse -StatusCode 201
        }
        Invoke-GroupsAddMember -Token $script:MockToken -InputData $script:ValidInput
        $script:capturedBody.memberId        | Should -Be 7
        $script:capturedBody.memberId.GetType().Name | Should -Be 'Int32'
    }

    It 'GAM09 - body contains memberType=EPVUser' {
        $capturedBody = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedBody -Value $PSBoundParameters.Body -Scope Script
            script:New-AddMemberApiResponse -StatusCode 201
        }
        Invoke-GroupsAddMember -Token $script:MockToken -InputData $script:ValidInput
        $script:capturedBody.memberType | Should -Be 'EPVUser'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsAddMember - WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GAM10 - WhatIf - API NOT called (Times=0)' {
        Invoke-GroupsAddMember -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'GAM11 - WhatIf - Successes=1' {
        $r = Invoke-GroupsAddMember -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsAddMember - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GAM12 - empty GroupID - Failures=1' {
        $testInput = $script:ValidInput.Clone()
        $testInput.GroupID = ''
        $r = Invoke-GroupsAddMember -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'GAM13 - empty MemberID - Failures=1' {
        $testInput = $script:ValidInput.Clone()
        $testInput.MemberID = ''
        $r = Invoke-GroupsAddMember -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsAddMember - API errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GAM14 - 401 - IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-GroupsAddMember -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsAddMember - DomainName' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GAM15 - domainName included in body when provided' {
        $capturedBody = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedBody -Value $PSBoundParameters.Body -Scope Script
            script:New-AddMemberApiResponse -StatusCode 201
        }
        $domainInput = $script:ValidInput.Clone()
        $domainInput.DomainName = 'corp.example.com'
        Invoke-GroupsAddMember -Token $script:MockToken -InputData $domainInput
        $script:capturedBody.domainName | Should -Be 'corp.example.com'
    }
}
