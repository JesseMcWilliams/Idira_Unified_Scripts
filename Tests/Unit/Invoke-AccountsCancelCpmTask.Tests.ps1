#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsCancelCpmTask.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsCancelCpmTask.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsCancelCpmTaskTests' -MinLevel 'ERROR'
}

Describe 'Invoke-AccountsCancelCpmTask' {

    Context 'Missing AccountID' {
        It 'returns failure when AccountID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-AccountsCancelCpmTask -Token $token -InputData @{}
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
            $result = Invoke-AccountsCancelCpmTask -Token $token -InputData @{ AccountID = 'acc123' }
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
            $result = Invoke-AccountsCancelCpmTask -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Successes   | Should -BeGreaterThan 0
            $result.Failures    | Should -Be 0
        }
    }

    Context 'WhatIf mode' {
        It 'does not call the API when WhatIf is set' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
            Mock Add-CyberArkLogSummaryEntry {}
            { Invoke-AccountsCancelCpmTask -Token $token -InputData @{ AccountID = 'acc123' } -WhatIf } | Should -Not -Throw
        }
    }

    Context 'Safe name with spaces (AccountName+Safe lookup)' {
        It 'quotes the safe name in the filter expression, matching psPAS''s ConvertTo-FilterString behavior' {
            # Regression test: a raw "safeName eq $targetSafe" string interpolation (this
            # module's original implementation) sends an unquoted value for a multi-word safe
            # name, which CyberArk's filter grammar requires to be wrapped in double quotes
            # (URL-encoded to %22) - confirmed against psPAS's own ConvertTo-FilterString.ps1.
            # Fixed by routing through the shared, already-tested New-CyberArkSearchFilter
            # helper instead of building the filter string inline.
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $capturedQueryParams = $null
            Mock Invoke-CyberArkAPI {
                param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
                if ($Method -eq 'GET') {
                    Set-Variable -Name capturedQueryParams -Value $QueryParams -Scope Script
                    [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ value = @() } }
                } else {
                    [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
                }
            }
            Invoke-AccountsCancelCpmTask -Token $token -InputData @{ AccountName = 'svc-account'; Safe = 'My Safe' } | Out-Null
            $script:capturedQueryParams['filter'] | Should -Be 'safeName eq "My Safe"'
        }
    }

}
