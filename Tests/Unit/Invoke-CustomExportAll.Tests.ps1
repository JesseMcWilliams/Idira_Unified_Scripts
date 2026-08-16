#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-CustomExportAll.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Custom\Invoke-CustomExportAll.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'CustomExportAllTests' -MinLevel 'ERROR'

    # Stub for Driver helper — not available outside Driver.ps1
    function global:Get-CsvSavePath { param([string]$DefaultFolder, [string]$ModuleName) return $null }
}

Describe 'Invoke-CustomExportAll' {

    BeforeEach {
        $script:LoadedModules = $null
        $script:ActiveProfile = $null
    }

    Context 'No loaded modules' {
        It 'returns empty result when LoadedModules is null' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.ItemsProcessed | Should -Be 0
            $result.Successes      | Should -Be 0
            $result.Failures       | Should -Be 0
        }

        It 'returns empty result when no list modules exist' {
            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Delete Something'; Category = 'Accounts'; Action = 'Delete'; ProducesOutput = $false; Priority = 10 }
            })
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.ItemsProcessed | Should -Be 0
        }

        It 'skips Custom category modules to prevent recursion' {
            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Export All'; Category = 'Custom'; Action = 'List'; ProducesOutput = $true; Priority = 80 }
            })
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.ItemsProcessed | Should -Be 0
        }
    }

    Context 'Module function throws' {
        It 'records error and continues when a list module throws' {
            # Set up a stub function that throws
            function Invoke-TestCategoryList {
                param($Token, $InputData, [switch]$WhatIf)
                throw 'Simulated module failure'
            }

            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Test List'; Category = 'TestCategory'; Action = 'List'; ProducesOutput = $true; Priority = 10 }
            })

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.Failures      | Should -BeGreaterThan 0
            $result.Errors.Count  | Should -BeGreaterThan 0
        }
    }

    Context 'List module returns no results' {
        It 'adds Empty status row when module returns 0 records' {
            function Invoke-EmptyCategoryList {
                param($Token, $InputData, [switch]$WhatIf)
                return [PSCustomObject]@{
                    Results = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Errors  = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Successes = 0; Failures = 0
                }
            }

            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Empty List'; Category = 'EmptyCategory'; Action = 'List'; ProducesOutput = $true; Priority = 10 }
            })

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.Successes          | Should -BeGreaterThan 0
            $result.Results.Count      | Should -BeGreaterThan 0
            $result.Results[0].Status  | Should -Be 'Empty'
            $result.Results[0].Records | Should -Be 0
        }
    }

    Context 'List module returns results' {
        It 'adds result rows with correct Module name when module returns data' {
            $mockResults = [System.Collections.Generic.List[PSCustomObject]]::new()
            $mockResults.Add([PSCustomObject]@{ Name = 'Item1' })

            function Invoke-DataCategoryList {
                param($Token, $InputData, [switch]$WhatIf)
                $r = [System.Collections.Generic.List[PSCustomObject]]::new()
                $r.Add([PSCustomObject]@{ Name = 'Item1' })
                return [PSCustomObject]@{
                    Results = $r
                    Errors  = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Successes = 1; Failures = 0
                }
            }

            # Mock Get-CsvSavePath to return empty (simulate cancel)
            Mock Get-CsvSavePath { return $null }

            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Data List'; Category = 'DataCategory'; Action = 'List'; ProducesOutput = $true; Priority = 10 }
            })

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.Successes         | Should -BeGreaterThan 0
            $result.Results.Count     | Should -BeGreaterThan 0
            $result.Results[0].Module | Should -Be 'Data List'
        }
    }

}
