#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-ApplicationsAddAuthMethod.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Applications\Invoke-ApplicationsAddAuthMethod.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'ApplicationsAddAuthMethodTests' -MinLevel 'ERROR'
}

Describe 'Invoke-ApplicationsAddAuthMethod' {

    Context 'Missing required inputs' {
        It 'returns failure when AppID is missing' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-ApplicationsAddAuthMethod -Token $token -InputData @{ AuthType = 'path'; AuthValue = 'C:\App' }
            $result.Failures  | Should -Be 1
            $result.Successes | Should -Be 0
        }

        It 'returns failure when AuthType is missing' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-ApplicationsAddAuthMethod -Token $token -InputData @{ AppID = 'MyApp'; AuthValue = 'C:\App' }
            $result.Failures  | Should -Be 1
            $result.Successes | Should -Be 0
        }

        It 'returns failure when AuthValue is missing' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-ApplicationsAddAuthMethod -Token $token -InputData @{ AppID = 'MyApp'; AuthType = 'path' }
            $result.Failures  | Should -Be 1
            $result.Successes | Should -Be 0
        }
    }

    Context 'API call failure' {
        It 'records error on non-success response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 400; ErrorMessage = 'Bad Request'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-ApplicationsAddAuthMethod -Token $token -InputData @{ AppID = 'MyApp'; AuthType = 'path'; AuthValue = 'C:\App' }
            $result.Failures  | Should -BeGreaterThan 0
            $result.IsFatal   | Should -Be $false
        }
    }

    Context 'Successful addition' {
        It 'records success and returns Added status' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 201; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
            }
            Mock Add-CyberArkLogSummaryEntry {}
            $result = Invoke-ApplicationsAddAuthMethod -Token $token -InputData @{
                AppID     = 'MyApp'
                AuthType  = 'path'
                AuthValue = 'C:\Program Files\MyApp'
            }
            $result.Successes          | Should -Be 1
            $result.Results[0].AppID   | Should -Be 'MyApp'
            $result.Results[0].AuthType| Should -Be 'path'
            $result.Results[0].Status  | Should -Be 'Added'
        }
    }

    Context 'WhatIf mode' {
        It 'does not call API when WhatIf is set' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
            Mock Add-CyberArkLogSummaryEntry {}
            { Invoke-ApplicationsAddAuthMethod -Token $token -InputData @{ AppID = 'MyApp'; AuthType = 'hash'; AuthValue = 'abc123' } -WhatIf } | Should -Not -Throw
        }
    }

}
