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

    # Stubs for Driver helpers - not available outside Manage-Privilege.ps1
    function global:Get-CsvSavePath { param([string]$DefaultFolder, [string]$ModuleName) return $null }
    # Invoke-FileWriteWithRetry's real implementation prompts interactively (via Confirm-Action)
    # on failure - this stub just runs Action once and surfaces whether it threw, which is all
    # these tests need.
    function global:Invoke-FileWriteWithRetry {
        param([scriptblock]$Action, [string]$Path)
        try { & $Action; return $true } catch { return $false }
    }
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

        It 'records a SaveFailed row (not Saved) when Invoke-FileWriteWithRetry reports failure' {
            # e.g. the file was locked and the user declined to retry when prompted.
            Mock Invoke-FileWriteWithRetry { return $false }

            function Invoke-LockedCategoryList {
                param($Token, $InputData, [switch]$WhatIf)
                $r = [System.Collections.Generic.List[PSCustomObject]]::new()
                $r.Add([PSCustomObject]@{ Name = 'Item1' })
                return [PSCustomObject]@{
                    Results   = $r
                    Errors    = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Successes = 1; Failures = 0
                }
            }

            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Locked List'; Category = 'LockedCategory'; Action = 'List'; ProducesOutput = $true; Priority = 10 }
            })

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.Results[0].Status    | Should -Be 'SaveFailed'
            $result.Results[0].SavedPath | Should -Be ''
        }
    }

    Context 'Relative OutputFolder resolution' {
        BeforeEach {
            # $PSScriptRoot inside Invoke-CustomExportAll.ps1 is this file's own directory
            # (APIModules\Custom), not the project root - even though Manage-Privilege.ps1
            # dot-sources it into its own scope. A relative profile OutputFolder must resolve
            # against $script:APIModulesPath's parent (set by Manage-Privilege.ps1), the same
            # project root every other save-to-CSV path uses - not against this file's own
            # location.
            $script:TempProjectRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ExportAllTest_$([System.Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $script:TempProjectRoot -Force | Out-Null
            $script:APIModulesPath = Join-Path $script:TempProjectRoot 'APIModules'
            $script:ActiveProfile  = [PSCustomObject]@{ OutputFolder = 'Output' }
        }

        AfterEach {
            $script:APIModulesPath = $null
            if (Test-Path -LiteralPath $script:TempProjectRoot) {
                Remove-Item -LiteralPath $script:TempProjectRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'saves the CSV under the project root OutputFolder, not under APIModules\Custom' {
            function Invoke-RelPathCategoryList {
                param($Token, $InputData, [switch]$WhatIf)
                $r = [System.Collections.Generic.List[PSCustomObject]]::new()
                $r.Add([PSCustomObject]@{ Name = 'Item1' })
                return [PSCustomObject]@{
                    Results   = $r
                    Errors    = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Successes = 1; Failures = 0
                }
            }

            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'RelPath List'; Category = 'RelPathCategory'; Action = 'List'; ProducesOutput = $true; Priority = 10 }
            })

            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}

            $expectedPath = Join-Path $script:TempProjectRoot 'Output\Export_RelPathCategoryList.csv'
            $result.Results[0].SavedPath | Should -Be $expectedPath
            Test-Path -LiteralPath $expectedPath | Should -BeTrue
            $result.Results[0].SavedPath | Should -Not -Match ([regex]::Escape('APIModules'))
        }
    }

}
