#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-ApplicationsListAuthMethods.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Applications\Invoke-ApplicationsListAuthMethods.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'ApplicationsListAuthMethodsTests' -MinLevel 'ERROR'
}

Describe 'Invoke-ApplicationsListAuthMethods' {

    Context 'Missing AppID' {
        It 'returns failure when AppID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{}
            $result.Failures  | Should -Be 1
            $result.Successes | Should -Be 0
        }
    }

    Context 'API call failure' {
        It 'records error on non-success response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{ AppID = 'MyApp' }
            $result.Failures  | Should -BeGreaterThan 0
            $result.Successes | Should -Be 0
        }
    }

    Context 'No authentication methods' {
        It 'returns empty result with no errors' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $emptyData = [PSCustomObject]@{ authentication = @() }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $emptyData }
            }
            $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{ AppID = 'MyApp' }
            $result.Successes     | Should -Be 0
            $result.Results.Count | Should -Be 0
            $result.Failures      | Should -Be 0
        }
    }

    Context 'Successful retrieval' {
        It 'maps authentication method fields correctly' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $authsData = [PSCustomObject]@{
                authentication = @(
                    [PSCustomObject]@{
                        authID               = '1'
                        authType             = 'path'
                        authValue            = 'C:\Apps\MyApp'
                        isFolder             = $false
                        allowInternalScripts = $false
                        comment              = 'Test entry'
                    }
                )
            }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $authsData }
            }
            $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{ AppID = 'MyApp' }
            $result.Successes                  | Should -Be 1
            $result.Results[0].AppID           | Should -Be 'MyApp'
            $result.Results[0].AuthType        | Should -Be 'path'
            $result.Results[0].AuthValue       | Should -Be 'C:\Apps\MyApp'
        }
    }

}
