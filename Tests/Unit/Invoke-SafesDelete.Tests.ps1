#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Safes\Invoke-SafesDelete.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafesDeleteInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Driver.ps1. That function is covered by manual integration
    tests (Driver.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesDelete.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-SafesDelete into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafesDeleteTests' -MinLevel 'ERROR'

    # Minimal token stub (SelfHosted)
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://test.cyberark.local'
    }

    $script:ValidInput = @{ SafeName = 'TestSafe' }

    # Factory: build a mock API success response for a delete (204 No Content)
    function script:New-DeleteApiResponse {
        param([bool]$IsSuccess = $true, [int]$StatusCode = 204)
        return [PSCustomObject]@{
            IsSuccess     = $IsSuccess
            StatusCode    = $StatusCode
            StatusMessage = if ($StatusCode -eq 204) { 'No Content' } else { 'OK' }
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

    It 'D01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'D02 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'D03 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'D04 - ProducesOutput is $false' {
        $ModuleMeta.ProducesOutput | Should -BeFalse
    }

    It 'D05 - Category=Safes and Action=Delete' {
        $ModuleMeta.Category | Should -Be 'Safes'
        $ModuleMeta.Action   | Should -Be 'Delete'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesDelete - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'D06 - Successes=1, Failures=0, ItemsProcessed=1' {
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 1
        $r.Failures       | Should -Be 0
        $r.ItemsProcessed | Should -Be 1
    }

    It 'D07 - IsFatal=$false on success' {
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'D08 - DELETE method is used' {
        Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'D09 - endpoint contains SafeName' {
        Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Endpoint -like '*TestSafe*' }
    }

    It 'D10 - result entry has Deleted=$true' {
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Results.Count       | Should -Be 1
        $r.Results[0].Deleted  | Should -BeTrue
        $r.Results[0].SafeName | Should -Be 'TestSafe'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesDelete - WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'D11 - WhatIf: API is NOT called' {
        Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'D12 - WhatIf: Successes=1' {
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesDelete - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'D13 - empty SafeName: Failures=1 and API not called' {
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData @{ SafeName = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'D14 - null InputData: Failures=1' {
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesDelete - errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'D15 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'D16 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'D17 - 403 Forbidden: IsFatal=$false and error added' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Errors.Count | Should -Be 1
    }

    It 'D18 - 404 Not Found: IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }
}
