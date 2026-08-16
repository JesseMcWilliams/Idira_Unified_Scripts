#Requires -Version 5.1
<#
.SYNOPSIS
    Runs all Pester v5 unit tests for the Idira Unified Scripts project.

.PARAMETER Path
    Specific test file or folder to run. Defaults to all files under Tests\Unit\.

.PARAMETER Verbosity
    Pester output detail level. Default: Normal.
    Values: None, Normal, Detailed, Diagnostic.

.PARAMETER OutputFile
    Path to write a JUnit XML report (for CI pipelines). Optional.

.EXAMPLE
    # Run all unit tests
    .\Tests\Run-Tests.ps1

.EXAMPLE
    # Run one file with detailed output
    .\Tests\Run-Tests.ps1 -Path .\Tests\Unit\CyberArkLogging.Tests.ps1 -Verbosity Detailed

.EXAMPLE
    # Run with CI XML report
    .\Tests\Run-Tests.ps1 -OutputFile .\Tests\TestResults.xml
#>
[CmdletBinding()]
param(
    [string]$Path       = '',
    [ValidateSet('None','Normal','Detailed','Diagnostic')]
    [string]$Verbosity  = 'Normal',
    [string]$OutputFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Pester version check ---

$pesterModule = Get-Module -ListAvailable -Name Pester |
                Where-Object { $_.Version.Major -ge 5 } |
                Sort-Object Version -Descending |
                Select-Object -First 1

if (-not $pesterModule) {
    Write-Host ''
    Write-Host '  Pester v5 is not installed.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Install it with:' -ForegroundColor Yellow
    Write-Host '    Install-Module -Name Pester -MinimumVersion 5.0 -Force -Scope CurrentUser' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  If the gallery is not accessible, download from: https://github.com/pester/Pester/releases' -ForegroundColor Yellow
    exit 1
}

Import-Module Pester -MinimumVersion 5.0 -Force
Write-Host "  Using Pester $((Get-Module Pester).Version)" -ForegroundColor DarkGray

#endregion

#region --- Resolve test path ---

$scriptRoot = $PSScriptRoot
$unitDir    = Join-Path $scriptRoot 'Unit'

if ($Path) {
    $testPath = $Path
} else {
    $testPath = $unitDir
}

if (-not (Test-Path -LiteralPath $testPath)) {
    Write-Host "  Test path not found: $testPath" -ForegroundColor Red
    exit 1
}

#endregion

#region --- Configure and run Pester ---

$config = New-PesterConfiguration

$config.Run.Path         = $testPath
$config.Output.Verbosity = $Verbosity
$config.Run.Exit         = $false    # We handle exit code ourselves

if ($OutputFile) {
    $config.TestResult.Enabled    = $true
    $config.TestResult.OutputPath = $OutputFile
    $config.TestResult.OutputFormat = 'JUnitXml'
    Write-Host "  JUnit report will be written to: $OutputFile" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host '  Idira Unified Scripts - Unit Test Run' -ForegroundColor White
Write-Host "  Path: $testPath" -ForegroundColor DarkGray
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host ''

$result = Invoke-Pester -Configuration $config

#endregion

#region --- Summary ---

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host '  Test Results' -ForegroundColor White
Write-Host ('=' * 60) -ForegroundColor Cyan

$passColor = if ($result.FailedCount -eq 0) { 'Green' } else { 'Red' }

Write-Host ("  Passed  : {0}" -f $result.PassedCount)  -ForegroundColor Green
Write-Host ("  Failed  : {0}" -f $result.FailedCount)  -ForegroundColor $passColor
Write-Host ("  Skipped : {0}" -f $result.SkippedCount) -ForegroundColor DarkGray
Write-Host ("  Total   : {0}" -f $result.TotalCount)   -ForegroundColor White
Write-Host ("  Duration: {0:N1}s" -f $result.Duration.TotalSeconds) -ForegroundColor DarkGray
Write-Host ''

if ($result.FailedCount -gt 0) {
    Write-Host '  FAILED TESTS:' -ForegroundColor Red
    foreach ($test in $result.Failed) {
        Write-Host "    - $($test.Name)" -ForegroundColor Yellow
        if ($test.ErrorRecord) {
            Write-Host "      $($test.ErrorRecord.Exception.Message)" -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    exit 1
}

Write-Host '  All tests passed.' -ForegroundColor Green
Write-Host ''
exit 0

#endregion
