#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-ApplicationsAdd.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Applications\Invoke-ApplicationsAdd.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'ApplicationsAddTests' -MinLevel 'ERROR'
}

Describe 'Invoke-ApplicationsAdd' {

    Context 'Missing AppID' {
        It 'returns failure when AppID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-ApplicationsAdd -Token $token -InputData @{}
            $result.Failures  | Should -Be 1
            $result.Successes | Should -Be 0
            $result.IsFatal   | Should -Be $false
        }
    }

    Context 'API call failure' {
        It 'records error on non-success response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 409; ErrorMessage = 'Conflict'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-ApplicationsAdd -Token $token -InputData @{ AppID = 'NewApp' }
            $result.Failures  | Should -BeGreaterThan 0
            $result.IsFatal   | Should -Be $false
        }
    }

    Context 'Successful creation' {
        It 'records success and returns Created status' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 201; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
            }
            Mock Add-CyberArkLogSummaryEntry {}
            $result = Invoke-ApplicationsAdd -Token $token -InputData @{ AppID = 'NewApp'; Description = 'A new application' }
            $result.Successes          | Should -Be 1
            $result.Failures           | Should -Be 0
            $result.Results[0].AppID   | Should -Be 'NewApp'
            $result.Results[0].Status  | Should -Be 'Created'
        }
    }

    Context 'WhatIf mode' {
        It 'does not call API when WhatIf is set' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
            Mock Add-CyberArkLogSummaryEntry {}
            { Invoke-ApplicationsAdd -Token $token -InputData @{ AppID = 'WhatIfApp' } -WhatIf } | Should -Not -Throw
        }
    }

}
