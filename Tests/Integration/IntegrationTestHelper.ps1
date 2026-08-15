#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helper for CyberArk PAS integration test scripts.

.DESCRIPTION
    This file is dot-sourced by integration test scripts at the top of each file:
        . "$PSScriptRoot\IntegrationTestHelper.ps1"

    Credentials are collected at runtime via Read-Host — never stored in files.
    Tests create and delete the safe named in Config.psd1 (TestSafeName).
    The safe named in Config.psd1 (ExcludedSafe) is NEVER touched by any test operation.

    Functions provided:
        Get-IntegrationConfig       - Reads Config.psd1 and returns the hashtable
        Get-IntegrationToken        - Authenticates to CyberArk and returns a token object
        Assert-SafeNotExcluded      - Safety guard used before any write operation
        Invoke-LogoffIfToken        - Logs off from CyberArk at end of test (cleanup)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Module Imports ---

Import-Module -Name (Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1')   -Force

Initialize-CyberArkLog -Destination 'Console' -MinLevel 'INFO' -ProfileName 'IntegrationTests'

#endregion

#region --- Script-Level Token Storage ---

$script:TestToken = $null

#endregion

#region --- Functions ---

function Get-IntegrationConfig {
    <#
    .SYNOPSIS
        Reads Config.psd1 from the Integration test directory and returns the config hashtable.
    .OUTPUTS
        Hashtable — the contents of Config.psd1.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $configPath = Join-Path $PSScriptRoot 'Config.psd1'

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Integration config not found at: $configPath"
    }

    $config = Import-PowerShellDataFile -LiteralPath $configPath
    return $config
}

function Get-IntegrationToken {
    <#
    .SYNOPSIS
        Authenticates to CyberArk and returns a token object compatible with Invoke-CyberArkAPI.

    .DESCRIPTION
        If $Credential is not supplied, prompts for the password via Read-Host.
        The password is converted from SecureString inline in the request body and is
        never stored as plaintext in a variable beyond the scope of this function.

        For CyberArk self-hosted, the API returns a bare token string. That string is
        placed directly in the Authorization header — it is NOT prefixed with "Bearer".

    .PARAMETER Config
        The config hashtable returned by Get-IntegrationConfig.

    .PARAMETER Credential
        Optional PSCredential. If omitted, the user is prompted for the password.

    .OUTPUTS
        PSCustomObject — token object stored in $script:TestToken and returned to the caller.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    # Resolve the SecureString password
    if ($Credential) {
        $securePassword = $Credential.Password
    } else {
        $securePassword = Read-Host -Prompt "Password for $($Config.Username)" -AsSecureString
    }

    # Build PSCredential (kept in scope for potential future use; password stays secure)
    $cred = [System.Management.Automation.PSCredential]::new($Config.Username, $securePassword)

    # Convert SecureString to plaintext inline for the request body only
    $bstr          = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

    $logonBody = @{
        username          = $Config.Username
        password          = $plainPassword
        concurrentSession = $true
    }

    $logonUrl = "$($Config.PVWABaseURL)/API/auth/CyberArk/Logon"

    Write-CyberArkLog -Message "Authenticating as '$($Config.Username)' to $logonUrl" `
                      -Level 'INFO' -FunctionName 'Get-IntegrationToken'

    try {
        $response = Invoke-WebRequest `
            -Uri             $logonUrl `
            -Method          'POST' `
            -Body            ($logonBody | ConvertTo-Json -Compress) `
            -ContentType     'application/json' `
            -UseBasicParsing `
            -ErrorAction     'Stop'
    } catch {
        throw "Logon request failed: $_"
    } finally {
        # Zero out the BSTR immediately after use
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        Remove-Variable -Name plainPassword -ErrorAction SilentlyContinue
    }

    # CyberArk self-hosted returns the token as a JSON-quoted string; strip the quotes.
    $tokenString = ($response.Content | ConvertFrom-Json)

    if (-not $tokenString) {
        throw "Logon response did not contain a token. Response: $($response.Content)"
    }

    Write-CyberArkLog -Message 'Logon successful. Token received.' `
                      -Level 'INFO' -FunctionName 'Get-IntegrationToken'

    # Build the token object matching the shape expected by Invoke-CyberArkAPI.
    # Self-hosted CyberArk tokens are passed as-is in the Authorization header (no "Bearer" prefix).
    $script:TestToken = [PSCustomObject]@{
        Token      = $tokenString
        TokenType  = 'CyberArk'
        Headers    = @{
            Authorization  = $tokenString
            'Content-Type' = 'application/json'
        }
        Expiry     = (Get-Date).AddMinutes(20).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = $Config.PVWABaseURL
    }

    return $script:TestToken
}

function Assert-SafeNotExcluded {
    <#
    .SYNOPSIS
        Safety guard that prevents any test operation from touching the excluded safe.

    .DESCRIPTION
        Call this before every write operation (create, update, delete, add member, etc.)
        that involves a safe name. If the target safe matches the excluded safe, the
        function throws immediately and halts the test.

    .PARAMETER SafeName
        The name of the safe that is about to be operated on.

    .PARAMETER ExcludedSafe
        The safe name that must never be modified. Typically Config.ExcludedSafe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SafeName,

        [Parameter(Mandatory = $true)]
        [string]$ExcludedSafe
    )

    if ($SafeName -eq $ExcludedSafe) {
        throw "SAFETY ABORT: Cannot operate on excluded safe '$ExcludedSafe'"
    }
}

function Invoke-LogoffIfToken {
    <#
    .SYNOPSIS
        Logs off from CyberArk if a token is present. Used in finally blocks for cleanup.

    .DESCRIPTION
        Calls POST /API/auth/Logoff with the token headers. Errors are suppressed so
        that a failed logoff does not mask test failures or errors in finally blocks.

    .PARAMETER Config
        The config hashtable returned by Get-IntegrationConfig.

    .PARAMETER Token
        The token object returned by Get-IntegrationToken. If null, the function is a no-op.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$Token
    )

    if ($null -eq $Token) {
        return
    }

    try {
        $logoffUrl = "$($Config.PVWABaseURL)/API/auth/Logoff"

        Invoke-WebRequest `
            -Uri             $logoffUrl `
            -Method          'POST' `
            -Headers         $Token.Headers `
            -UseBasicParsing `
            -ErrorAction     'Stop' | Out-Null

        Write-CyberArkLog -Message 'Logoff successful.' `
                          -Level 'INFO' -FunctionName 'Invoke-LogoffIfToken'
    } catch {
        # Suppress errors — this is a cleanup function called in finally blocks.
        # A failed logoff must not mask test results.
        Write-CyberArkLog -Message "Logoff failed (suppressed): $_" `
                          -Level 'WARN' -FunctionName 'Invoke-LogoffIfToken'
    }
}

#endregion
