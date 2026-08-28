#Requires -Version 5.1
<#
.SYNOPSIS
    Counts how many accounts are assigned to each CyberArk platform, from already-exported CSVs.

.DESCRIPTION
    Standalone utility - does not connect to CyberArk and does not depend on Manage-Privilege.ps1
    or any APIModules file. It reads two CSV files already produced by this project's Platforms/
    List and Accounts/List modules (e.g. via the "Export All" action, which names them
    Export_PlatformsList.csv and Export_AccountsList.csv), joins them on PlatformID, and writes a
    new CSV listing every platform alongside a count of accounts assigned to it.

    Platforms with zero matching accounts are still included (Count = 0). Accounts whose
    PlatformID does not match any row in the platforms CSV are counted separately under a
    "(Not Found)" placeholder row rather than silently dropped, since that gap usually means a
    platform was deleted or renamed after accounts were already assigned to it. Accounts with a
    blank PlatformID are counted under a "(No Platform Assigned)" placeholder row.

.PARAMETER PlatformsCsvPath
    Path to the exported platforms CSV (must have PlatformID and Name columns - the shape
    produced by Invoke-PlatformsList.ps1). Defaults to .\Export_PlatformsList.csv.

.PARAMETER AccountsCsvPath
    Path to the exported accounts CSV (must have a PlatformID column - the shape produced by
    Invoke-AccountsList.ps1). Defaults to .\Export_AccountsList.csv.

.PARAMETER OutputCsvPath
    Path to write the resulting CSV. Defaults to Count-AccountsPerPlatform_<yyyy-MM-dd>.csv in
    the same folder as PlatformsCsvPath.

.EXAMPLE
    .\Count-AccountsPerPlatform.ps1
    Reads Export_PlatformsList.csv and Export_AccountsList.csv from the current directory and
    writes Count-AccountsPerPlatform_<today>.csv alongside them.

.EXAMPLE
    .\Count-AccountsPerPlatform.ps1 -PlatformsCsvPath 'Output\Export_PlatformsList.csv' -AccountsCsvPath 'Output\Export_AccountsList.csv' -OutputCsvPath 'Output\PlatformUsage.csv'
    Reads both exports from the Output folder and writes the result to an explicit path.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$PlatformsCsvPath = '.\Export_PlatformsList.csv',

    [Parameter(Mandatory = $false)]
    [string]$AccountsCsvPath = '.\Export_AccountsList.csv',

    [Parameter(Mandatory = $false)]
    [string]$OutputCsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NotFoundLabel    = '(Not Found)'
$NoPlatformLabel  = '(No Platform Assigned)'

if (-not (Test-Path -LiteralPath $PlatformsCsvPath -PathType Leaf)) {
    Write-Error "Platforms CSV not found: $PlatformsCsvPath"
    exit 1
}
if (-not (Test-Path -LiteralPath $AccountsCsvPath -PathType Leaf)) {
    Write-Error "Accounts CSV not found: $AccountsCsvPath"
    exit 1
}

if (-not $OutputCsvPath) {
    $platformsFullPath = (Resolve-Path -LiteralPath $PlatformsCsvPath).Path
    $outputFolder       = Split-Path -Path $platformsFullPath -Parent
    $OutputCsvPath       = Join-Path $outputFolder "Count-AccountsPerPlatform_$((Get-Date).ToString('yyyy-MM-dd')).csv"
}

Write-Host "Platforms CSV : $PlatformsCsvPath" -ForegroundColor DarkGray
Write-Host "Accounts CSV  : $AccountsCsvPath" -ForegroundColor DarkGray
Write-Host "Output CSV    : $OutputCsvPath" -ForegroundColor DarkGray
Write-Host ''

try {
    [array]$platforms = @(Import-Csv -LiteralPath $PlatformsCsvPath)
} catch {
    Write-Error "Failed to read platforms CSV '$PlatformsCsvPath': $_"
    exit 1
}
try {
    [array]$accounts = @(Import-Csv -LiteralPath $AccountsCsvPath)
} catch {
    Write-Error "Failed to read accounts CSV '$AccountsCsvPath': $_"
    exit 1
}

if ($platforms.Count -eq 0) {
    Write-Warning "'$PlatformsCsvPath' contains no platform rows."
}
if ($platforms.Count -gt 0 -and -not $platforms[0].PSObject.Properties['PlatformID']) {
    Write-Error "'$PlatformsCsvPath' has no PlatformID column - is this the correct file?"
    exit 1
}
if ($accounts.Count -gt 0 -and -not $accounts[0].PSObject.Properties['PlatformID']) {
    Write-Error "'$AccountsCsvPath' has no PlatformID column - is this the correct file?"
    exit 1
}

# Count accounts per PlatformID. PowerShell hashtables are case-insensitive for string keys by
# default, matching how CyberArk platform IDs are compared elsewhere in this project.
$countsByPlatform = @{}
foreach ($account in $accounts) {
    $platformId = if ($account.PSObject.Properties['PlatformID']) { "$($account.PlatformID)".Trim() } else { '' }
    $key = if ($platformId) { $platformId } else { $NoPlatformLabel }
    if ($countsByPlatform.ContainsKey($key)) {
        $countsByPlatform[$key]++
    } else {
        $countsByPlatform[$key] = 1
    }
}

$rows = [System.Collections.Generic.List[PSCustomObject]]::new()
$matchedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

foreach ($platform in $platforms) {
    $platformId = if ($platform.PSObject.Properties['PlatformID']) { "$($platform.PlatformID)".Trim() } else { '' }
    $name       = if ($platform.PSObject.Properties['Name'])       { $platform.Name }                  else { '' }
    $count      = if ($platformId -and $countsByPlatform.ContainsKey($platformId)) { $countsByPlatform[$platformId] } else { 0 }
    if ($platformId) { [void]$matchedKeys.Add($platformId) }

    $rows.Add([PSCustomObject]@{
        PlatformID   = $platformId
        PlatformName = $name
        AccountCount = $count
    })
}

# Any PlatformID seen in the accounts CSV that never matched a platform row (deleted/renamed
# platform, or the "no platform assigned" bucket) - surfaced rather than silently dropped, so
# the sum of AccountCount across every row always equals the total account count.
foreach ($key in $countsByPlatform.Keys) {
    if ($key -eq $NoPlatformLabel -or -not $matchedKeys.Contains($key)) {
        $rows.Add([PSCustomObject]@{
            PlatformID   = if ($key -eq $NoPlatformLabel) { '' } else { $key }
            PlatformName = if ($key -eq $NoPlatformLabel) { $NoPlatformLabel } else { $NotFoundLabel }
            AccountCount = $countsByPlatform[$key]
        })
    }
}

$sortedRows = $rows | Sort-Object -Property @{ Expression = 'AccountCount'; Descending = $true }, @{ Expression = 'PlatformName'; Descending = $false }

try {
    $sortedRows | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Encoding UTF8 -Force
} catch {
    Write-Error "Failed to write output CSV '$OutputCsvPath': $_"
    exit 1
}

$totalAccounts  = ($sortedRows | Measure-Object -Property AccountCount -Sum).Sum
$platformsUsed  = @($sortedRows | Where-Object {
    $_.AccountCount -gt 0 -and $_.PlatformName -ne $NotFoundLabel -and $_.PlatformName -ne $NoPlatformLabel
}).Count

Write-Host "Platforms listed : $($sortedRows.Count)" -ForegroundColor Green
Write-Host "Platforms in use : $platformsUsed" -ForegroundColor Green
Write-Host "Accounts totaled : $totalAccounts" -ForegroundColor Green
Write-Host "Saved: $OutputCsvPath" -ForegroundColor Green
