#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Export All'
    Category         = 'Custom'
    Action           = 'ExportAll'
    Description      = 'Run the List action for every loaded module and offer to save each result as a separate CSV file.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $false
    InputSchema      = @()
    Priority         = 80
    Version          = '1.0.0'
}

function Invoke-CustomExportAll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$InputData,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $result = [PSCustomObject]@{
        ModuleName     = $ModuleMeta.Name
        Category       = $ModuleMeta.Category
        Action         = $ModuleMeta.Action
        ItemsProcessed = 0
        Successes      = 0
        Failures       = 0
        IsFatal        = $false
        Results        = [System.Collections.Generic.List[PSCustomObject]]::new()
        Errors         = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    # Enumerate list modules - skip other Custom modules to avoid recursion
    $listModules = @()
    if ($null -ne $script:LoadedModules) {
        $listModules = @($script:LoadedModules | Where-Object {
            $_.Meta.Action -eq 'List' -and
            $_.Meta.ProducesOutput -eq $true -and
            $_.Meta.Category -ne 'Custom'
        } | Sort-Object { [int]$_.Meta.Priority })
    }

    if ($listModules.Count -eq 0) {
        Write-Host '  No list modules found to export.' -ForegroundColor Yellow
        Write-CyberArkLog -Level 'WARN' -Message 'Export All: no list modules available.'
        return $result
    }

    Write-Host ''
    Write-Host "  Found $($listModules.Count) list module$(if ($listModules.Count -ne 1) { 's' }) to export." -ForegroundColor Cyan
    Write-Host ''

    $defaultFolder = if ($script:ActiveProfile -and $script:ActiveProfile.OutputFolder) {
        $script:ActiveProfile.OutputFolder
    } else { (Get-Location).Path }

    foreach ($module in $listModules) {
        $fnName  = "Invoke-$($module.Meta.Category)$($module.Meta.Action)"
        $modName = $module.Meta.Name

        Write-Host "  [$($result.ItemsProcessed + 1)/$($listModules.Count)] $modName" -ForegroundColor White -NoNewline

        try {
            $moduleResult = & $fnName -Token $Token -InputData @{}

            $recordCount = 0
            if ($null -ne $moduleResult -and $null -ne $moduleResult.Results) {
                $recordCount = $moduleResult.Results.Count
            }

            if ($recordCount -gt 0) {
                Write-Host " - $recordCount record$(if ($recordCount -ne 1) { 's' })" -ForegroundColor Green

                $csvPath = Get-CsvSavePath -DefaultFolder $defaultFolder -ModuleName $modName
                if ($csvPath) {
                    $moduleResult.Results | Export-Csv -Path $csvPath -NoTypeInformation -Force
                    Write-Host "    Saved: $csvPath" -ForegroundColor DarkGreen
                    $result.Results.Add([PSCustomObject]@{
                        Module    = $modName
                        Records   = $recordCount
                        Status    = 'Saved'
                        SavedPath = $csvPath
                    })
                } else {
                    Write-Host '    Skipped (no save path).' -ForegroundColor DarkGray
                    $result.Results.Add([PSCustomObject]@{
                        Module    = $modName
                        Records   = $recordCount
                        Status    = 'Skipped'
                        SavedPath = ''
                    })
                }
            } else {
                Write-Host ' - no records returned.' -ForegroundColor DarkGray
                $result.Results.Add([PSCustomObject]@{
                    Module    = $modName
                    Records   = 0
                    Status    = 'Empty'
                    SavedPath = ''
                })
            }
            $result.Successes++
        } catch {
            Write-Host " - ERROR: $_" -ForegroundColor Red
            $msg = "Export All failed for module '$modName': $_"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = @{ Module = $modName }
                ErrorMessage = $msg
                ErrorDetails = $null
            })
            $result.Failures++
        }
        $result.ItemsProcessed++
        Write-Host ''
    }

    Write-CyberArkLog -Level 'INFO' -Message "Export All complete. Modules: $($result.ItemsProcessed), Success: $($result.Successes), Failures: $($result.Failures)."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
