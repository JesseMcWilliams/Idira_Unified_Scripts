#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsChangeInVault.
#>

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath  = Join-Path (Split-Path (Split-Path $here)) 'APIModules\Accounts\Invoke-AccountsChangeInVault.ps1'
$commsPath   = Join-Path (Split-Path (Split-Path $here)) 'Modules\CyberArkComms.psm1'
$loggingPath = Join-Path (Split-Path (Split-Path $here)) 'Modules\CyberArkLogging.psm1'

Describe 'Invoke-AccountsChangeInVault' {

    BeforeAll {
        Import-Module $loggingPath -Force
        Import-Module $commsPath   -Force
        . $modulePath
    }

    Context 'Missing AccountID' {
        It 'returns failure when AccountID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-AccountsChangeInVault -Token $token -InputData @{}
            $result.Failures    | Should -Be 1
            $result.Successes   | Should -Be 0
            $result.IsFatal     | Should -Be $false
        }
    }

    Context 'API call failure' {
        It 'records error on non-success response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-AccountsChangeInVault -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Failures    | Should -BeGreaterThan 0
            $result.IsFatal     | Should -Be $false
        }
    }

    Context 'Successful operation' {
        It 'records success on 200/204 response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
            }
            $result = Invoke-AccountsChangeInVault -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Successes   | Should -BeGreaterThan 0
            $result.Failures    | Should -Be 0
        }
    }

    Context 'WhatIf mode' {
        It 'does not call the API when WhatIf is set' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
            Mock Add-CyberArkLogSummaryEntry {}
            { Invoke-AccountsChangeInVault -Token $token -InputData @{ AccountID = 'acc123' } -WhatIf } | Should -Not -Throw
        }
    }

}
