#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Accounts\Invoke-AccountsGet.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-AccountsGetInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Driver.ps1. That function is covered by manual integration
    tests (Driver.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsGet.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-AccountsGet into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsGetTests' -MinLevel 'ERROR'

    # Minimal token stub
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'ISPSS'
        AuthMethod = 'ClientCredentials'
        BaseURL    = 'https://test.privilegecloud.cyberark.cloud'
    }

    # Factory: build a mock API success response containing a single account object
    function script:New-AccountApiResponse {
        param([PSCustomObject]$Account)
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
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

    # A sample account object matching the CyberArk API shape (single object, not wrapped in value array)
    $script:SampleAccount = [PSCustomObject]@{
        id                = '123_456'
        name              = 'svc-account@domain.com'
        address           = 'domain.com'
        userName          = 'svc-account'
        platformId        = 'WinDomain'
        safeName          = 'TestSafe'
        secretType        = 'password'
        createdTime       = 1700000000   # 2023-11-14 (UTC)
        secretManagement  = [PSCustomObject]@{
            automaticManagementEnabled = $true
            manualManagementReason     = ''
            lastModifiedTime           = 1700000000
            lastReconciledTime         = 1700000000
            lastVerifiedTime           = 1700000000
            status                     = 'success'
        }
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'AG01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'AG02 - required fields are all present' {
        $ModuleMeta.Name             | Should -Not -BeNullOrEmpty
        $ModuleMeta.Category         | Should -Not -BeNullOrEmpty
        $ModuleMeta.Action           | Should -Not -BeNullOrEmpty
        $ModuleMeta.SupportedSystems | Should -Not -BeNullOrEmpty
        $ModuleMeta.Version          | Should -Not -BeNullOrEmpty
    }

    It 'AG03 - Category is Accounts and Action is Get' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'Get'
    }

    It 'AG04 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'AG05 - SupportsWhatIf is $false' {
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }

    It 'AG06 - InputSchema contains AccountID column marked Required' {
        $col = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'AccountID' }
        $col           | Should -Not -BeNullOrEmpty
        $col.Required  | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsGet - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-AccountApiResponse -Account $script:SampleAccount
        }
        Mock Write-CyberArkLog { }
    }

    It 'AG07 - returns result object with all 9 required fields' {
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.PSObject.Properties.Name | Should -Contain 'ModuleName'
        $r.PSObject.Properties.Name | Should -Contain 'Category'
        $r.PSObject.Properties.Name | Should -Contain 'Action'
        $r.PSObject.Properties.Name | Should -Contain 'ItemsProcessed'
        $r.PSObject.Properties.Name | Should -Contain 'Successes'
        $r.PSObject.Properties.Name | Should -Contain 'Failures'
        $r.PSObject.Properties.Name | Should -Contain 'IsFatal'
        $r.PSObject.Properties.Name | Should -Contain 'Results'
        $r.PSObject.Properties.Name | Should -Contain 'Errors'
    }

    It 'AG08 - Successes=1, ItemsProcessed=1, Failures=0' {
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
        $r.Failures       | Should -Be 0
    }

    It 'AG09 - id is mapped to AccountID' {
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.Results[0].AccountID | Should -Be '123_456'
    }

    It 'AG10 - userName is mapped to UserName' {
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.Results[0].UserName | Should -Be 'svc-account'
    }

    It 'AG11 - safeName is mapped to SafeName' {
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.Results[0].SafeName | Should -Be 'TestSafe'
    }

    It 'AG12 - automaticManagementEnabled is mapped to AutoManaged' {
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.Results[0].AutoManaged | Should -BeTrue
    }

    It 'AG13 - status is mapped to CPMStatus' {
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.Results[0].CPMStatus | Should -Be 'success'
    }

    It 'AG14 - manualManagementReason is mapped to ManualReason' {
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.Results[0].ManualReason | Should -Be ''
    }

    It 'AG15 - createdTime epoch is converted to a yyyy-MM-dd string' {
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.Results[0].Created | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }

    It 'AG16 - missing createdTime does not throw and returns empty string' {
        $acctNoTime = [PSCustomObject]@{
            id               = '999'
            name             = 'no-time@domain.com'
            address          = 'domain.com'
            userName         = 'no-time'
            platformId       = 'WinDomain'
            safeName         = 'TestSafe'
            secretType       = 'password'
            # createdTime deliberately absent
            secretManagement = $null
        }
        Mock Invoke-CyberArkAPI { script:New-AccountApiResponse -Account $acctNoTime }
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '999' }
        $r.Results[0].Created | Should -Be ''
    }

    It 'AG17 - null secretManagement returns $false for AutoManaged and empty string for CPMStatus and ManualReason' {
        $acctNoMgmt = [PSCustomObject]@{
            id               = '777'
            name             = 'no-mgmt@domain.com'
            address          = 'domain.com'
            userName         = 'no-mgmt'
            platformId       = 'WinDomain'
            safeName         = 'TestSafe'
            secretType       = 'password'
            createdTime      = 1700000000
            secretManagement = $null
        }
        Mock Invoke-CyberArkAPI { script:New-AccountApiResponse -Account $acctNoMgmt }
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '777' }
        $r.Results[0].AutoManaged  | Should -BeFalse
        $r.Results[0].CPMStatus    | Should -Be ''
        $r.Results[0].ManualReason | Should -Be ''
    }

    It 'AG18 - IsFatal is $false on success' {
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.IsFatal | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsGet - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-AccountApiResponse -Account $script:SampleAccount }
        Mock Write-CyberArkLog { }
    }

    It 'AG19 - empty AccountID: Failures=1 and no API call made' {
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'AG20 - null InputData: Failures=1 and no API call made' {
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsGet - API errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'AG21 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.IsFatal | Should -BeTrue
    }

    It 'AG22 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.IsFatal | Should -BeTrue
    }

    It 'AG23 - 403 Forbidden: IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.IsFatal | Should -BeFalse
    }

    It 'AG24 - 404 Not Found: IsFatal=$false and error added' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.IsFatal      | Should -BeFalse
        $r.Failures     | Should -Be 1
        $r.Errors.Count | Should -Be 1
    }

    It 'AG25 - error entry ErrorMessage is not null or empty' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.Errors[0].ErrorMessage | Should -Not -BeNullOrEmpty
    }

    It 'AG26 - ItemsProcessed incremented on API failure' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 500 -ErrorMessage 'Server Error' }
        $r = Invoke-AccountsGet -Token $script:MockToken -InputData @{ AccountID = '123_456' }
        $r.ItemsProcessed | Should -Be 1
    }
}
