#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Accounts\Invoke-AccountsUpdate.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-AccountsUpdateInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Driver.ps1. That function is covered by manual integration
    tests (Driver.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsUpdate.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-AccountsUpdate into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsUpdateTests' -MinLevel 'ERROR'

    # Minimal token stub (ISPSS)
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'ISPSS'
        AuthMethod = 'ClientCredentials'
        BaseURL    = 'https://test.privilegecloud.cyberark.cloud'
    }

    # Standard valid input - Address updated; other optional fields blank (fall back to current)
    $script:ValidInput = @{
        AccountID  = '123_456'
        Name       = ''
        Address    = '10.0.0.99'
        UserName   = ''
        PlatformID = ''
        SafeName   = ''
        AutoManaged= ''
    }

    # Current account state returned by the GET call
    $script:CurrentAccount = [PSCustomObject]@{
        id          = '123_456'
        name        = 'acct-original'
        address     = '10.0.0.1'
        userName    = 'svcuser'
        platformId  = 'WinServerLocal'
        safeName    = 'TestSafe'
        secretType  = 'password'
        createdTime = 1700000000
        secretManagement = [PSCustomObject]@{
            automaticManagementEnabled = $true
            manualManagementReason     = ''
            status                     = 'success'
        }
    }

    # Updated account state returned by the PUT call
    $script:UpdatedAccount = [PSCustomObject]@{
        id          = '123_456'
        name        = 'acct-original'
        address     = '10.0.0.99'
        userName    = 'svcuser'
        platformId  = 'WinServerLocal'
        safeName    = 'TestSafe'
        secretType  = 'password'
        createdTime = 1700000000
        secretManagement = [PSCustomObject]@{
            automaticManagementEnabled = $true
            manualManagementReason     = ''
            status                     = 'success'
        }
    }

    # Factory: build a mock API success response for a single account object
    function script:New-AccountApiResponse {
        param(
            [Parameter(Mandatory = $true)] [PSCustomObject]$Account,
            [int]$StatusCode = 200
        )
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = $StatusCode
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $Account
        }
    }

    # Factory: build a mock API failure response
    function script:New-ApiErrorResponse {
        param(
            [int]$StatusCode      = 403,
            [string]$ErrorMessage = 'Forbidden'
        )
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

    It 'AU01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'AU02 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'AU03 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'AU04 - Category is Accounts and Action is Update' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'Update'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsUpdate - success' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }

        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                # GET - return current account
                script:New-AccountApiResponse -Account $script:CurrentAccount
            } else {
                # PUT - return updated account
                script:New-AccountApiResponse -Account $script:UpdatedAccount -StatusCode 200
            }
        }
    }

    It 'AU05 - two API calls made total (GET then PUT)' {
        Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 2 -Exactly
    }

    It 'AU06 - second API call uses PUT method' {
        $capturedCalls = [System.Collections.Generic.List[hashtable]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters)
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-AccountApiResponse -Account $script:CurrentAccount
            } else {
                script:New-AccountApiResponse -Account $script:UpdatedAccount -StatusCode 200
            }
        }
        $script:CallCount = 0
        Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $capturedCalls[1].Method | Should -Be 'PUT'
    }

    It 'AU07 - Successes=1 and Failures=0' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes | Should -Be 1
        $r.Failures  | Should -Be 0
    }

    It 'AU08 - IsFatal is $false on success' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'AU09 - result entry AccountID matches input' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].AccountID | Should -Be '123_456'
    }

    It 'AU10 - result entry Address reflects the updated value from PUT response' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].Address | Should -Be '10.0.0.99'
    }

    It 'AU11 - result entry has all expected fields' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'AccountID'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'AccountName'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'Address'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'UserName'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'PlatformID'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'SafeName'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'SecretType'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'AutoManaged'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'CPMStatus'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'Created'
    }

    It 'AU12 - createdTime epoch is converted to a yyyy-MM-dd string' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].Created | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }

    It 'AU13 - blank optional field falls back to current account value (UserName)' {
        $capturedCalls = [System.Collections.Generic.List[hashtable]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters)
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-AccountApiResponse -Account $script:CurrentAccount
            } else {
                script:New-AccountApiResponse -Account $script:UpdatedAccount -StatusCode 200
            }
        }
        $script:CallCount = 0
        Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        # UserName was blank in input - should have been carried forward from CurrentAccount
        $capturedCalls[1].Body.userName | Should -Be 'svcuser'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsUpdate - WhatIf' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }

        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            # Both GET and WhatIf PUT return success; WhatIf flag is passed to Invoke-CyberArkAPI
            script:New-AccountApiResponse -Account $script:CurrentAccount
        }
    }

    It 'AU14 - WhatIf: Successes=1 and IsFatal=$false' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
        $r.IsFatal   | Should -BeFalse
    }

    It 'AU15 - WhatIf: result entry exists in Results' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Results.Count | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsUpdate - validation' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { }
    }

    It 'AU16 - empty AccountID: Failures=1 and no API call made' {
        $testInput = $script:ValidInput.Clone()
        $testInput.AccountID = ''
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'AU17 - null InputData: Failures=1' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsUpdate - GET phase errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AU18 - GET 401: IsFatal=$true and no PUT attempted' {
        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized'
        }
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
        # Only the GET call should have been made
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsUpdate - PUT phase errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AU19 - PUT 400 Bad Request: IsFatal=$false and Failures=1' {
        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-AccountApiResponse -Account $script:CurrentAccount
            } else {
                script:New-ApiErrorResponse -StatusCode 400 -ErrorMessage 'Bad Request'
            }
        }
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal  | Should -BeFalse
        $r.Failures | Should -Be 1
    }

    It 'AU20 - PUT 401 Unauthorized: IsFatal=$true' {
        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-AccountApiResponse -Account $script:CurrentAccount
            } else {
                script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized'
            }
        }
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}
