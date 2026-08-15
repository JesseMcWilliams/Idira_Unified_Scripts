#Requires -Version 5.1
<#
.SYNOPSIS
    Integration tests for CyberArk Safes CRUD operations against a live PVWA 14.6 instance.

.DESCRIPTION
    This is NOT a Pester test — it is a plain sequential PowerShell script that exercises
    the five Safes API modules (List, Get, Add, Update, Delete) against a real PVWA and
    reports PASS / FAIL for each test case.

    Test cases IT01–IT05 are read-only and always run.
    Test cases IT06–IT11 are write operations and are skipped when -SkipWrite is specified.

    PVWA : https://pvwa.company.com/PasswordVault
    Auth : CyberArk native, username ca_admin (password prompted at runtime)

    PROTECTED SAFE — 'Z_Template_Safe_Permissions' is NEVER touched by any test.
    TEST SAFE       — 'IDIRA_IntTest_Safes' is created and deleted during write tests.
                      The finally block guarantees cleanup even when a test fails mid-run.

.PARAMETER SkipWrite
    When specified, IT06–IT11 (Add, Update, Delete) are skipped entirely.
    Use this flag in environments where write operations are not permitted.

.EXAMPLE
    .\Test-Safes.ps1

.EXAMPLE
    .\Test-Safes.ps1 -SkipWrite
#>

[CmdletBinding()]
param(
    [switch]$SkipWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Dot-source shared integration test helper (provides Get-IntegrationConfig,
#    Get-IntegrationToken, Assert-SafeNotExcluded, Invoke-LogoffIfToken)
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot 'IntegrationTestHelper.ps1')

# ---------------------------------------------------------------------------
# 2. Dot-source the Safes API modules
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesList.ps1')
. (Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesGet.ps1')
. (Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesAdd.ps1')
. (Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesUpdate.ps1')
. (Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesDelete.ps1')

# ---------------------------------------------------------------------------
# 3. Load config and authenticate
# ---------------------------------------------------------------------------

$config = Get-IntegrationConfig
$token  = Get-IntegrationToken -Config $config   # prompts for password

# ---------------------------------------------------------------------------
# 4. Test runner state and helper
# ---------------------------------------------------------------------------

$script:PassCount = 0
$script:FailCount = 0
$script:Errors    = @()

function Test-Case {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ID,
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [scriptblock]$Block
    )
    try {
        & $Block
        Write-Host "  [PASS] $ID $Name" -ForegroundColor Green
        $script:PassCount++
    } catch {
        Write-Host "  [FAIL] $ID $Name -- $_" -ForegroundColor Red
        $script:FailCount++
        $script:Errors += "$ID $Name -- $_"
    }
}

# ---------------------------------------------------------------------------
# 5. READ-ONLY TESTS (always run)
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Read-Only Tests' -ForegroundColor Cyan
Write-Host ('-' * 60) -ForegroundColor DarkGray

# IT01 — List returns at least one safe
Test-Case -ID 'IT01' -Name 'Invoke-SafesList returns at least one safe' -Block {
    $r = Invoke-SafesList -Token $token
    if ($r.Failures -gt 0 -and $r.IsFatal) {
        throw "Fatal error from Invoke-SafesList: $($r.Errors | ForEach-Object { $_.ErrorMessage } | Out-String)"
    }
    if ($r.Successes -lt 1) {
        throw "Expected at least one safe but Successes=$($r.Successes). Errors: $($r.Errors | ForEach-Object { $_.ErrorMessage } | Out-String)"
    }
}

# IT02 — List runs without error; if ExcludedSafe is present, note it (do not fail)
Test-Case -ID 'IT02' -Name 'Invoke-SafesList completes without fatal error' -Block {
    $r = Invoke-SafesList -Token $token
    if ($r.IsFatal) {
        throw "Invoke-SafesList returned IsFatal=true. Errors: $($r.Errors | ForEach-Object { $_.ErrorMessage } | Out-String)"
    }
    $excluded = $r.Results | Where-Object { $_.SafeName -eq $config.ExcludedSafe }
    if ($excluded) {
        Write-Host "    (note: ExcludedSafe '$($config.ExcludedSafe)' is visible in the list — NOT touched by tests)" -ForegroundColor DarkGray
    }
}

# IT03 — List with Search returns filtered results
Test-Case -ID 'IT03' -Name 'Invoke-SafesList with Search filters results' -Block {
    # Retrieve first safe from a plain list to use as the search term
    $baseList = Invoke-SafesList -Token $token
    if ($baseList.Successes -lt 1) {
        throw "Cannot determine a search term — baseline list returned no safes."
    }
    $searchTerm = $baseList.Results[0].SafeName

    $r = Invoke-SafesList -Token $token -InputData @{
        Search          = $searchTerm
        Filter          = ''
        ExtendedDetails = $false
    }
    if ($r.IsFatal) {
        throw "Invoke-SafesList with Search='$searchTerm' returned IsFatal=true."
    }
    if ($r.Successes -lt 1) {
        throw "Search for '$searchTerm' returned no results (Successes=$($r.Successes))."
    }
}

# IT04 — Get retrieves a specific safe by name
Test-Case -ID 'IT04' -Name 'Invoke-SafesGet retrieves the first safe from the list' -Block {
    $list      = Invoke-SafesList -Token $token
    if ($list.Successes -lt 1) { throw "Cannot get first safe — list returned no results." }
    $firstName = $list.Results[0].SafeName

    $r = Invoke-SafesGet -Token $token -InputData @{ SafeName = $firstName }
    if ($r.Successes -ne 1) {
        throw "Expected Successes=1 for safe '$firstName', got $($r.Successes). Errors: $($r.Errors | ForEach-Object { $_.ErrorMessage } | Out-String)"
    }
    if ($r.Results[0].SafeName -ne $firstName) {
        throw "SafeName mismatch: expected '$firstName', got '$($r.Results[0].SafeName)'."
    }
}

# IT05 — Get with non-existent safe returns a non-fatal failure (404)
Test-Case -ID 'IT05' -Name 'Invoke-SafesGet with non-existent safe returns non-fatal failure' -Block {
    $r = Invoke-SafesGet -Token $token -InputData @{ SafeName = 'IDIRA_NonExistentSafe_XYZ123' }
    if ($r.Failures -ne 1) {
        throw "Expected Failures=1 for non-existent safe, got $($r.Failures)."
    }
    if ($r.IsFatal) {
        throw "Expected IsFatal=false for 404, but got IsFatal=true."
    }
}

# ---------------------------------------------------------------------------
# 6. WRITE TESTS (skipped when -SkipWrite is specified)
# ---------------------------------------------------------------------------

if ($SkipWrite) {
    Write-Host ''
    Write-Host 'Write Tests — SKIPPED (-SkipWrite specified)' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host 'Write Tests' -ForegroundColor Cyan
    Write-Host ('-' * 60) -ForegroundColor DarkGray

    # Wrap all write tests in a try/finally so the test safe is always cleaned up.
    try {

        # IT06 — Add creates the test safe
        Test-Case -ID 'IT06' -Name 'Invoke-SafesAdd creates test safe' -Block {
            Assert-SafeNotExcluded -SafeName $config.TestSafeName -ExcludedSafe $config.ExcludedSafe
            $r = Invoke-SafesAdd -Token $token -InputData @{
                SafeName                  = $config.TestSafeName
                Description               = 'Idira integration test safe - safe to delete'
                Location                  = '\'
                ManagingCPM               = ''
                NumberOfVersionsRetention = '5'
                NumberOfDaysRetention     = '0'
                AutoPurgeEnabled          = 'false'
                OLACEnabled               = 'false'
            }
            if ($r.Successes -ne 1) {
                throw "Expected Successes=1, got $($r.Successes). Errors: $($r.Errors | ForEach-Object { $_.ErrorMessage } | Out-String)"
            }
        }

        # IT07 — Get retrieves the newly created safe
        Test-Case -ID 'IT07' -Name 'Invoke-SafesGet retrieves the newly created safe' -Block {
            $r = Invoke-SafesGet -Token $token -InputData @{ SafeName = $config.TestSafeName }
            if ($r.Successes -ne 1) {
                throw "Expected Successes=1 after Add, got $($r.Successes). Errors: $($r.Errors | ForEach-Object { $_.ErrorMessage } | Out-String)"
            }
            if ($r.Results[0].SafeName -ne $config.TestSafeName) {
                throw "SafeName mismatch: expected '$($config.TestSafeName)', got '$($r.Results[0].SafeName)'."
            }
        }

        # IT08 — Update changes the description and version retention
        Test-Case -ID 'IT08' -Name 'Invoke-SafesUpdate updates the test safe description' -Block {
            $r = Invoke-SafesUpdate -Token $token -InputData @{
                SafeName                  = $config.TestSafeName
                Description               = 'Updated by integration test'
                ManagingCPM               = ''
                NumberOfVersionsRetention = '7'
                NumberOfDaysRetention     = '0'
                AutoPurgeEnabled          = 'false'
                OLACEnabled               = 'false'
            }
            if ($r.Successes -ne 1) {
                throw "Expected Successes=1, got $($r.Successes). Errors: $($r.Errors | ForEach-Object { $_.ErrorMessage } | Out-String)"
            }
        }

        # IT09 — Verify the updated values were persisted
        Test-Case -ID 'IT09' -Name 'Invoke-SafesGet confirms updated description or version retention' -Block {
            $r = Invoke-SafesGet -Token $token -InputData @{ SafeName = $config.TestSafeName }
            if ($r.Successes -ne 1) {
                throw "Get after Update returned Successes=$($r.Successes). Errors: $($r.Errors | ForEach-Object { $_.ErrorMessage } | Out-String)"
            }
            $safe = $r.Results[0]
            $descriptionOk      = $safe.Description      -eq 'Updated by integration test'
            $versionRetentionOk = $safe.VersionRetention -eq 7
            if (-not ($descriptionOk -or $versionRetentionOk)) {
                throw "Neither updated field matched. Description='$($safe.Description)', VersionRetention=$($safe.VersionRetention)."
            }
        }

        # IT10 — Delete removes the test safe
        Test-Case -ID 'IT10' -Name 'Invoke-SafesDelete deletes the test safe' -Block {
            Assert-SafeNotExcluded -SafeName $config.TestSafeName -ExcludedSafe $config.ExcludedSafe
            $r = Invoke-SafesDelete -Token $token -InputData @{ SafeName = $config.TestSafeName }
            if ($r.Successes -ne 1) {
                throw "Expected Successes=1, got $($r.Successes). Errors: $($r.Errors | ForEach-Object { $_.ErrorMessage } | Out-String)"
            }
        }

        # IT11 — Verify the deleted safe no longer exists (404, non-fatal)
        Test-Case -ID 'IT11' -Name 'Deleted safe no longer exists (non-fatal 404)' -Block {
            $r = Invoke-SafesGet -Token $token -InputData @{ SafeName = $config.TestSafeName }
            if ($r.Failures -ne 1) {
                throw "Expected Failures=1 for deleted safe, got $($r.Failures)."
            }
            if ($r.IsFatal) {
                throw "Expected IsFatal=false for 404 after delete, but got IsFatal=true."
            }
        }

    } finally {
        # Cleanup — attempt to delete the test safe if it might still exist.
        # This runs whether the tests passed, failed, or threw an unhandled exception.
        # Errors are suppressed so cleanup does not mask test results.
        try {
            $checkResult = Invoke-SafesGet -Token $token -InputData @{ SafeName = $config.TestSafeName }
            if ($checkResult.Successes -eq 1) {
                Write-Host "  [cleanup] Test safe '$($config.TestSafeName)' still exists — deleting." -ForegroundColor DarkYellow
                Invoke-SafesDelete -Token $token -InputData @{ SafeName = $config.TestSafeName } | Out-Null
                Write-Host "  [cleanup] Delete complete." -ForegroundColor DarkYellow
            }
        } catch {
            Write-Host "  [cleanup] Cleanup attempt failed (suppressed): $_" -ForegroundColor DarkYellow
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Results summary
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host ('-' * 60) -ForegroundColor DarkGray
Write-Host "Results: $($script:PassCount) passed, $($script:FailCount) failed" -ForegroundColor $(
    if ($script:FailCount -eq 0) { 'Green' } else { 'Yellow' }
)

if ($script:Errors) {
    Write-Host ''
    Write-Host 'Failed tests:' -ForegroundColor Red
    $script:Errors | ForEach-Object {
        Write-Host "  $_" -ForegroundColor Red
    }
}

Write-Host ''

# ---------------------------------------------------------------------------
# 8. Logoff
# ---------------------------------------------------------------------------

Invoke-LogoffIfToken -Config $config -Token $token
