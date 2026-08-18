#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CyberArk.Auth.Common.psm1') -Force

#region Constants

$script:PCLOUD_BASE_TEMPLATE = 'https://{0}.privilegecloud.cyberark.cloud/PasswordVault'

#endregion

#region Private Helpers

# Calls Write-CyberArkLog when the logging module is loaded in the session (live use).
# Falls back to Write-Verbose so the module is safe to import in test contexts.
function script:Write-ISPSSLog {
    param([string]$Message, [string]$Level = 'DEBUG', [string]$Fn)
    if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
        Write-CyberArkLog -Message $Message -Level $Level -FunctionName $Fn
    } else {
        Write-Verbose $Message
    }
}

function Get-WebResponseHost {
    param($Response)
    if (-not $Response) { return $null }
    try {
        if ($Response.BaseResponse -and $Response.BaseResponse.ResponseUri) {
            return $Response.BaseResponse.ResponseUri.Host
        }
    } catch {
        # BaseResponse may be disposed or in an invalid state; treat as no host
    }
    return $null
}

function Get-ExceptionRedirectHost {
    param($ErrorRecord)
    if (-not $ErrorRecord) { return $null }
    # Walk the exception chain to find a WebException — only WebException has .Response.
    # Under Set-StrictMode -Version Latest, accessing .Response on any other exception type
    # throws PropertyNotFoundException even inside try/catch in some PS 5.1 scenarios.
    $current = $null
    try { $current = $ErrorRecord.Exception } catch { return $null }
    while ($current) {
        if ($current -is [System.Net.WebException]) {
            try {
                if ($current.Response -and $current.Response.ResponseUri) {
                    return $current.Response.ResponseUri.Host
                }
            } catch {
                # Response may be non-null but internally invalid (SSL/TLS or connection abort)
            }
            return $null
        }
        $next = $null
        try { $next = $current.InnerException } catch { }
        $current = $next
    }
    return $null
}

#endregion

#region Identity Tenant Discovery

function Resolve-IdentityTenantURL {
    <#
    .SYNOPSIS
        Discovers the CyberArk Identity tenant URL for a given Privilege Cloud subdomain.
    .DESCRIPTION
        Probes three candidate URLs using MaximumRedirection 0 so that the first HTTP redirect
        throws an exception. The redirect target is examined for the *.id.cyberark.cloud pattern.
        Falls back to constructing {subdomain}.id.cyberark.cloud if no redirect is detected.
    .PARAMETER PCloudSubdomain
        The subdomain portion of the Privilege Cloud URL (e.g. 'acme' from acme.privilegecloud.cyberark.cloud).
    .PARAMETER ExistingIdentityHost
        When provided, the function returns immediately with this value (normalised to https://).
        Used to skip discovery when TenantAuth is already cached in the profile.
    #>
    param(
        [string]$PCloudSubdomain,
        [string]$ExistingIdentityHost
    )

    $fn = 'Resolve-IdentityTenantURL'

    if (-not [string]::IsNullOrWhiteSpace($ExistingIdentityHost)) {
        $cleaned = $ExistingIdentityHost.Trim().Replace('https://', '').TrimEnd('/')
        $url     = "https://$cleaned"
        script:Write-ISPSSLog -Message "Using cached TenantAuth: $url" -Level 'DEBUG' -Fn $fn
        return $url
    }

    script:Write-ISPSSLog -Message "Discovering Identity tenant URL for subdomain '$PCloudSubdomain'." -Level 'INFO' -Fn $fn

    $candidates = @(
        "https://$PCloudSubdomain.cyberark.cloud",
        "https://$PCloudSubdomain-userportal.cyberark.cloud",
        "https://$PCloudSubdomain.privilegecloud.cyberark.cloud"
    )

    foreach ($candidate in $candidates) {
        script:Write-ISPSSLog -Message "Probing candidate: $candidate" -Level 'DEBUG' -Fn $fn
        try {
            $resp         = Invoke-WebRequest -Uri $candidate -Method Get -MaximumRedirection 0 -TimeoutSec 20 -ErrorAction Stop -UseBasicParsing
            script:Write-ISPSSLog -Message ("Response: {0}" -f $resp) -Level 'DEBUG' -Fn $fn
            $responseHost = Get-WebResponseHost -Response $resp
            script:Write-ISPSSLog -Message "  200 OK — response host: $(if ($responseHost) { $responseHost } else { '(none)' })" -Level 'DEBUG' -Fn $fn
            if ($responseHost -match '\.id\.cyberark\.cloud$') {
                $url = "https://$responseHost"
                script:Write-ISPSSLog -Message "Identity tenant resolved via 200 response from '$candidate': $url" -Level 'INFO' -Fn $fn
                return $url
            }
            script:Write-ISPSSLog -Message "  Response host '$responseHost' is not an identity host. Trying next candidate." -Level 'DEBUG' -Fn $fn
        } catch {
            # MUST be first — ANY pipeline, function call, or inner try/catch overwrites $_ in PS 5.1
            $caughtError  = $_
            $exMessage    = 'Exception details unavailable'
            $exTypeName   = 'unknown'
            $statusCode   = 0
            $redirectHost = $null

            # Log the raw error using the captured reference (never pipe $_ directly)
            script:Write-ISPSSLog -Message ("Raw Error: `r`n`t{0}" -f $caughtError) -Level 'VERBOSE' -Fn $fn
            $errorMembers = $caughtError | Get-Member | Out-String
            script:Write-ISPSSLog -Message ("Error Members: `r`n`t{0}" -f $errorMembers) -Level 'VERBOSE' -Fn $fn

            # Each property access wrapped individually — .Exception itself can throw
            # InvalidOperationException when the underlying WebException state is invalid
            try { $exMessage  = $caughtError.Exception.Message           } catch { }
            try { $exTypeName = $caughtError.Exception.GetType().FullName } catch { }

            script:Write-ISPSSLog -Message "  Probe threw for '$candidate' [$exTypeName]: $exMessage" -Level 'DEBUG' -Fn $fn

            # Walk the exception chain for a WebException — only it has .Response/.StatusCode.
            # Accessing .Response on any other type throws PropertyNotFoundException under strict mode.
            $webExForCode = $null
            $exCurrent    = $null
            try { $exCurrent = $caughtError.Exception } catch { }
            while ($exCurrent) {
                if ($exCurrent -is [System.Net.WebException]) { $webExForCode = $exCurrent; break }
                $exNext = $null
                try { $exNext = $exCurrent.InnerException } catch { }
                $exCurrent = $exNext
            }
            if ($webExForCode) {
                try { $statusCode = [int]($webExForCode.Response.StatusCode) } catch { }
            }

            $redirectHost = Get-ExceptionRedirectHost -ErrorRecord $caughtError

            script:Write-ISPSSLog -Message "  HTTP $statusCode from '$candidate' — redirect host: $(if ($redirectHost) { $redirectHost } else { '(none)' })" -Level 'DEBUG' -Fn $fn

            if (-not $redirectHost) {
                script:Write-ISPSSLog -Message "  No redirect host detected from '$candidate'. Exception: $exMessage" -Level 'WARN' -Fn $fn
            }
            if ($redirectHost -match '\.id\.cyberark\.cloud$') {
                $url = "https://$redirectHost"
                script:Write-ISPSSLog -Message "Identity tenant resolved via redirect from '$candidate': $url" -Level 'INFO' -Fn $fn
                return $url
            }
            if ($redirectHost) {
                script:Write-ISPSSLog -Message "  Redirect host '$redirectHost' is not an identity host. Trying next candidate." -Level 'DEBUG' -Fn $fn
            }
        }
    }

    $url = "https://$PCloudSubdomain.id.cyberark.cloud"
    script:Write-ISPSSLog -Message "All candidates exhausted without detecting an identity redirect. Using constructed fallback: $url" -Level 'WARN' -Fn $fn
    return $url
}

#endregion

#region ISPSS Authentication Methods (private)

function Invoke-ISPSSClientCredentials {
    param(
        [string]$IdentityURL,
        [string]$ClientId,
        [System.Security.SecureString]$ClientSecret,
        [string]$BaseURL
    )

    $plainSecret = ConvertTo-PlainText $ClientSecret
    $body = ("grant_type=client_credentials" +
             "&client_id=$([Uri]::EscapeDataString($ClientId))" +
             "&client_secret=$([Uri]::EscapeDataString($plainSecret))")
    $plainSecret = $null

    $tokenUrl = "$IdentityURL/oauth2/platformtoken"
    Write-Verbose "Requesting client_credentials token from: $tokenUrl"
    try {
        $resp = Invoke-RestMethod -Uri $tokenUrl -Method POST `
            -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' } `
            -Body $body -ErrorAction Stop
    } catch {
        throw "ClientCredentials token request failed: $_"
    }

    $expiresIn = if ($resp.expires_in) { [int]$resp.expires_in } else { 3600 }
    $token     = $resp.access_token
    $expiry    = [DateTime]::UtcNow.AddSeconds($expiresIn)

    New-AuthTokenObject `
        -Token        $token `
        -TokenType    'Bearer' `
        -Headers      @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
        -Expiry       $expiry `
        -RefreshToken $resp.refresh_token `
        -SystemType   'ISPSS' `
        -AuthMethod   'ClientCredentials' `
        -BaseURL      $BaseURL `
        -IdentityURL  $IdentityURL `
        -TenantId     '' `
        -RefreshContext @{
            Method       = 'ClientCredentials'
            IdentityURL  = $IdentityURL
            ClientId     = $ClientId
            ClientSecret = $ClientSecret
            BaseURL      = $BaseURL
        }
}

function Invoke-IdentityAdvancedAuth {
    param(
        [string]$IdentityURL,
        [string]$TenantId,
        [string]$SessionId,
        [string]$MechanismId,
        [string]$Action,
        [string]$Answer
    )

    $body = @{
        TenantID    = $TenantId
        SessionId   = $SessionId
        MechanismId = $MechanismId
        Action      = $Action
    }
    if ($Answer) { $body.Answer = $Answer }

    Invoke-RestMethod -Uri "$IdentityURL/Security/AdvanceAuthentication" -Method POST `
        -Headers @{ 'X-IDAP-NATIVE-CLIENT' = 'true'; 'Content-Type' = 'application/json' } `
        -Body ($body | ConvertTo-Json) -ErrorAction Stop
}

function Invoke-IdentityChallengeLoop {
    param(
        [string]$IdentityURL,
        [string]$TenantId,
        [string]$SessionId,
        [array]$Challenges,
        [System.Management.Automation.PSCredential]$Credential
    )

    foreach ($challenge in $Challenges) {
        $mechanisms   = $challenge.Mechanisms
        $selectedMech = $null

        if ($mechanisms.Count -eq 1) {
            $selectedMech = $mechanisms[0]
        } elseif ($Credential) {
            $selectedMech = $mechanisms |
                Where-Object { $_.Name -eq 'UP' -and $_.AnswerType -eq 'Text' } |
                Select-Object -First 1
        }

        if (-not $selectedMech) {
            Write-Host "`nSelect an authentication mechanism:"
            for ($i = 0; $i -lt $mechanisms.Count; $i++) {
                Write-Host ("  [{0}] {1}" -f ($i + 1), $mechanisms[$i].PromptMechChosen)
            }
            $idx = 0
            do {
                $sel   = Read-Host "Choice (1-$($mechanisms.Count))"
                $valid = [int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $mechanisms.Count
            } while (-not $valid)
            $selectedMech = $mechanisms[$idx - 1]
        }

        Write-Verbose "Using mechanism: $($selectedMech.Name) / AnswerType: $($selectedMech.AnswerType)"

        $resp = $null
        switch ($selectedMech.AnswerType) {
            'Text' {
                if ($selectedMech.Name -eq 'UP' -and $Credential) {
                    $answer = $Credential.GetNetworkCredential().Password
                } else {
                    $ss     = Read-Host -Prompt $selectedMech.PromptSelectMech -AsSecureString
                    $answer = ConvertTo-PlainText $ss
                }
                $resp = Invoke-IdentityAdvancedAuth -IdentityURL $IdentityURL -TenantId $TenantId `
                    -SessionId $SessionId -MechanismId $selectedMech.MechanismId `
                    -Action 'Answer' -Answer $answer
            }
            'StartTextOob' {
                $resp = Invoke-IdentityAdvancedAuth -IdentityURL $IdentityURL -TenantId $TenantId `
                    -SessionId $SessionId -MechanismId $selectedMech.MechanismId -Action 'StartOOB'
                Write-Host $selectedMech.PromptMechChosen
                $oobStart   = Get-Date
                $oobTimeout = 300
                $oobToken   = $null
                do {
                    $elapsed = [int]((Get-Date) - $oobStart).TotalSeconds
                    Write-Host "`r  Waiting for out-of-band approval... ($($elapsed)s)" -NoNewline
                    if ($elapsed -ge $oobTimeout) {
                        Write-Host ''
                        throw "Authentication failed: Out-of-band approval timed out after $($oobTimeout / 60) minutes."
                    }
                    Start-Sleep -Seconds 2
                    $resp = Invoke-IdentityAdvancedAuth -IdentityURL $IdentityURL -TenantId $TenantId `
                        -SessionId $SessionId -MechanismId $selectedMech.MechanismId -Action 'Poll'
                    if ($resp) {
                        if ($resp.Result -isnot [string]) {
                            if ($resp.Result.PSObject.Properties['Token'] -and $resp.Result.Token) { $oobToken = $resp.Result.Token }
                            elseif ($resp.Result.PSObject.Properties['Auth'] -and $resp.Result.Auth) { $oobToken = $resp.Result.Auth }
                        }
                        if (-not $oobToken -and $resp.PSObject.Properties['Token'] -and $resp.Token) { $oobToken = $resp.Token }
                        if (-not $oobToken -and $resp.PSObject.Properties['Auth']  -and $resp.Auth)  { $oobToken = $resp.Auth  }
                    }
                } while (-not $oobToken -and $resp -and $resp.success -ne $false)
                Write-Host ''
                if ($oobToken) { return $oobToken }
            }
            default {
                $ss     = Read-Host -Prompt $selectedMech.PromptSelectMech -AsSecureString
                $answer = ConvertTo-PlainText $ss
                $resp = Invoke-IdentityAdvancedAuth -IdentityURL $IdentityURL -TenantId $TenantId `
                    -SessionId $SessionId -MechanismId $selectedMech.MechanismId `
                    -Action 'Answer' -Answer $answer
            }
        }

        if ($resp -and $resp.success -eq $false) {
            throw "Authentication failed: $($resp.Message)"
        }

        if ($resp) {
            $authToken = $null
            if ($resp.Result -isnot [string]) {
                Write-Verbose "AdvanceAuthentication Result fields: $($resp.Result.PSObject.Properties.Name -join ', ')"
                if ($resp.Result.PSObject.Properties['Token'] -and $resp.Result.Token) {
                    $authToken = $resp.Result.Token
                } elseif ($resp.Result.PSObject.Properties['Auth'] -and $resp.Result.Auth) {
                    $authToken = $resp.Result.Auth
                }
            }
            if (-not $authToken -and $resp.PSObject.Properties['Token'] -and $resp.Token) {
                $authToken = $resp.Token
            }
            if (-not $authToken -and $resp.PSObject.Properties['Auth'] -and $resp.Auth) {
                $authToken = $resp.Auth
            }
            if ($authToken) { return $authToken }
        }
    }

    throw "Challenge loop completed without returning a token."
}

function Invoke-ISPSSInteractive {
    param(
        [string]$IdentityURL,
        [string]$PCloudSubdomain,
        [string]$BaseURL,
        [string]$Username,
        [System.Management.Automation.PSCredential]$Credential
    )

    if (-not $Username -and $Credential) { $Username = $Credential.UserName }
    if (-not $Username) { $Username = Read-Host "CyberArk Identity username" }

    $startHeaders = @{
        'X-IDAP-NATIVE-CLIENT' = 'true'
        'OobIdPAuth'           = 'true'
        'Content-Type'         = 'application/json'
    }
    $startBody = @{ TenantId = ''; User = $Username; Version = '1.0' } | ConvertTo-Json

    Write-Verbose "Starting Identity authentication for: $Username"
    try {
        $startResp = Invoke-RestMethod -Uri "$IdentityURL/Security/StartAuthentication" `
            -Method POST -Headers $startHeaders -Body $startBody -ErrorAction Stop
    } catch {
        throw "StartAuthentication failed: $_"
    }

    if (-not $startResp.success) {
        throw "StartAuthentication error: $($startResp.Message)"
    }

    $tenantId   = $startResp.Result.TenantId
    $sessionId  = $startResp.Result.SessionId
    $challenges = $startResp.Result.Challenges
    $token      = $null

    if ($startResp.Result.PSObject.Properties['IdpRedirectShortUrl'] -and $startResp.Result.IdpRedirectShortUrl) {
        $redirectUrl = $startResp.Result.IdpRedirectShortUrl
        Write-Host "External IdP authentication required. Opening browser..."
        Start-Process $redirectUrl
        $pin    = Read-Host "Enter the PIN shown after completing external IdP login"
        $mechId = $challenges[0].Mechanisms[0].MechanismId
        $resp   = Invoke-IdentityAdvancedAuth -IdentityURL $IdentityURL -TenantId $tenantId `
            -SessionId $sessionId -MechanismId $mechId -Action 'Answer' -Answer $pin
        if ($resp.success -eq $false) {
            throw "External IdP PIN authentication failed: $($resp.Message)"
        }
        $token = $resp.Result.Token
    } else {
        $token = Invoke-IdentityChallengeLoop -IdentityURL $IdentityURL -TenantId $tenantId `
            -SessionId $sessionId -Challenges $challenges -Credential $Credential
    }

    if (-not $token) { throw "Interactive authentication did not return a token." }

    New-AuthTokenObject `
        -Token        $token `
        -TokenType    'Bearer' `
        -Headers      @{
            Authorization          = "Bearer $token"
            'X-IDAP-NATIVE-CLIENT' = 'true'
            'Content-Type'         = 'application/json'
        } `
        -Expiry       ([DateTime]::UtcNow.AddHours(4)) `
        -RefreshToken $null `
        -SystemType   'ISPSS' `
        -AuthMethod   'Interactive' `
        -BaseURL      $BaseURL `
        -IdentityURL  $IdentityURL `
        -TenantId     $tenantId `
        -RefreshContext @{
            Method          = 'Interactive'
            IdentityURL     = $IdentityURL
            PCloudSubdomain = $PCloudSubdomain
            Username        = $Username
            Credential      = $Credential
            BaseURL         = $BaseURL
        }
}

function Invoke-ISPSSSO {
    param(
        [string]$IdentityURL,
        [string]$PCloudSubdomain,
        [string]$BaseURL,
        [string]$WebView2AssemblyPath
    )

    Import-WebView2Assembly -AssemblyPath $WebView2AssemblyPath

    $loginUrl = "$IdentityURL/login?redirectUrl=$([Uri]::EscapeDataString($BaseURL))"
    Write-Verbose "Opening WebView2 for ISPSS SSO: $loginUrl"

    $captured = Invoke-WebView2Window -NavigateUrl $loginUrl -CookieName 'idToken' `
        -Title 'CyberArk Identity SSO Login'

    New-AuthTokenObject `
        -Token        $captured.Token `
        -TokenType    'Bearer' `
        -Headers      @{
            Authorization          = "Bearer $($captured.Token)"
            'X-IDAP-NATIVE-CLIENT' = 'true'
            'Content-Type'         = 'application/json'
        } `
        -Expiry       ([DateTime]::UtcNow.AddHours(4)) `
        -RefreshToken $null `
        -SystemType   'ISPSS' `
        -AuthMethod   'SSO' `
        -BaseURL      $BaseURL `
        -IdentityURL  $IdentityURL `
        -TenantId     '' `
        -RefreshContext @{
            Method               = 'SSO'
            IdentityURL          = $IdentityURL
            PCloudSubdomain      = $PCloudSubdomain
            BaseURL              = $BaseURL
            WebView2AssemblyPath = $WebView2AssemblyPath
        }
}

#endregion

#region Public Functions

function Get-ISPSSAuthToken {
    <#
    .SYNOPSIS
        Authenticates to CyberArk Privilege Cloud and returns a token object.
    .PARAMETER AuthMethod
        ClientCredentials | Interactive | SSO
    .PARAMETER PCloudSubdomain
        Subdomain of the Privilege Cloud tenant (e.g. 'acme' from acme.privilegecloud.cyberark.cloud).
    .PARAMETER IdentityTenantURL
        Overrides identity URL discovery. Use the TenantAuth profile field when available.
    .PARAMETER ClientId
        OAuth2 client ID (ClientCredentials method).
    .PARAMETER ClientSecret
        OAuth2 client secret as SecureString (ClientCredentials method).
    .PARAMETER Username
        CyberArk Identity username to pre-fill the prompt (Interactive method).
    .PARAMETER Credential
        PSCredential used for Interactive password pre-fill (optional).
    .PARAMETER WebView2AssemblyPath
        Path to Microsoft.Web.WebView2.WinForms.dll (SSO method).
    .OUTPUTS
        [PSCustomObject] Token object: Token, TokenType, Headers, Expiry, RefreshToken,
        SystemType, AuthMethod, BaseURL, IdentityURL, TenantId, _RefreshContext
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('ClientCredentials', 'Interactive', 'SSO')]
        [string]$AuthMethod,

        [string]$PCloudSubdomain,
        [string]$IdentityTenantURL,
        [string]$ClientId,
        [System.Security.SecureString]$ClientSecret,
        [string]$Username,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$WebView2AssemblyPath
    )

    $validMethods = @('ClientCredentials', 'Interactive', 'SSO')

    if (-not $AuthMethod -or $AuthMethod -notin $validMethods) {
        Write-Host ''
        Write-Host '  Authentication Method (Privilege Cloud):' -ForegroundColor White
        for ($i = 0; $i -lt $validMethods.Count; $i++) {
            Write-Host ("    [$($i+1)] $($validMethods[$i])") -ForegroundColor Gray
        }
        do {
            $sel   = Read-Host "Select method (1-$($validMethods.Count))"
            $idx   = 0
            $valid = [int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $validMethods.Count
            if (-not $valid) { Write-Host "  Enter a number between 1 and $($validMethods.Count)." -ForegroundColor Yellow }
        } while (-not $valid)
        $AuthMethod = $validMethods[$idx - 1]
    }

    if (-not $PCloudSubdomain) {
        $PCloudSubdomain = Read-Host "Privilege Cloud subdomain (e.g. 'acme' from acme.privilegecloud.cyberark.cloud)"
    }

    $baseURL = $script:PCLOUD_BASE_TEMPLATE -f $PCloudSubdomain

    if (-not $IdentityTenantURL) {
        $IdentityTenantURL = Resolve-IdentityTenantURL -PCloudSubdomain $PCloudSubdomain
    }

    switch ($AuthMethod) {
        'ClientCredentials' {
            if (-not $ClientId)     { $ClientId     = Read-Host "OAuth2 Client ID" }
            if (-not $ClientSecret) { $ClientSecret = Read-Host "OAuth2 Client Secret" -AsSecureString }
            return Invoke-ISPSSClientCredentials -IdentityURL $IdentityTenantURL `
                -ClientId $ClientId -ClientSecret $ClientSecret -BaseURL $baseURL
        }
        'Interactive' {
            $usernameToUse = if ($Username)      { $Username }
                             elseif ($Credential) { $Credential.UserName }
                             else                 { $null }
            return Invoke-ISPSSInteractive -IdentityURL $IdentityTenantURL `
                -PCloudSubdomain $PCloudSubdomain -BaseURL $baseURL `
                -Username $usernameToUse -Credential $Credential
        }
        'SSO' {
            return Invoke-ISPSSSO -IdentityURL $IdentityTenantURL `
                -PCloudSubdomain $PCloudSubdomain -BaseURL $baseURL `
                -WebView2AssemblyPath $WebView2AssemblyPath
        }
    }

    throw "Unhandled ISPSS auth method: '$AuthMethod'"
}

function Update-ISPSSAuthToken {
    <#
    .SYNOPSIS
        Refreshes or re-authenticates an existing ISPSS token using its stored _RefreshContext.
    .DESCRIPTION
        ClientCredentials: attempts refresh_token grant first; falls back to full client_credentials.
        Interactive: re-runs the MFA challenge flow.
        SSO: re-opens the WebView2 browser window.
    .PARAMETER TokenObject
        An existing ISPSS token returned by Get-ISPSSAuthToken or a previous Update-ISPSSAuthToken call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$TokenObject
    )

    $ctx = $TokenObject._RefreshContext
    if (-not $ctx) { throw "Token object missing _RefreshContext — cannot refresh." }

    switch ($ctx['Method']) {
        'ClientCredentials' {
            if ($TokenObject.RefreshToken) {
                Write-Verbose "Attempting refresh_token grant."
                try {
                    $body = ("grant_type=refresh_token" +
                             "&refresh_token=$([Uri]::EscapeDataString($TokenObject.RefreshToken))" +
                             "&client_id=$([Uri]::EscapeDataString($ctx['ClientId']))")
                    $resp = Invoke-RestMethod -Uri "$($ctx['IdentityURL'])/oauth2/platformtoken" `
                        -Method POST `
                        -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' } `
                        -Body $body -ErrorAction Stop
                    $expiresIn  = if ($resp.expires_in) { [int]$resp.expires_in } else { 3600 }
                    $newRefresh = if ($resp.refresh_token) { $resp.refresh_token } else { $TokenObject.RefreshToken }
                    return New-AuthTokenObject `
                        -Token        $resp.access_token `
                        -TokenType    'Bearer' `
                        -Headers      @{ Authorization = "Bearer $($resp.access_token)"; 'Content-Type' = 'application/json' } `
                        -Expiry       ([DateTime]::UtcNow.AddSeconds($expiresIn)) `
                        -RefreshToken $newRefresh `
                        -SystemType   'ISPSS' `
                        -AuthMethod   'ClientCredentials' `
                        -BaseURL      $ctx['BaseURL'] `
                        -IdentityURL  $ctx['IdentityURL'] `
                        -TenantId     '' `
                        -RefreshContext @{
                            Method       = 'ClientCredentials'
                            IdentityURL  = $ctx['IdentityURL']
                            ClientId     = $ctx['ClientId']
                            ClientSecret = $ctx['ClientSecret']
                            BaseURL      = $ctx['BaseURL']
                        }
                } catch {
                    Write-Warning "refresh_token grant failed, re-authenticating: $_"
                }
            }
            return Invoke-ISPSSClientCredentials -IdentityURL $ctx['IdentityURL'] `
                -ClientId $ctx['ClientId'] -ClientSecret $ctx['ClientSecret'] -BaseURL $ctx['BaseURL']
        }
        'Interactive' {
            return Invoke-ISPSSInteractive -IdentityURL $ctx['IdentityURL'] `
                -PCloudSubdomain $ctx['PCloudSubdomain'] -BaseURL $ctx['BaseURL'] `
                -Username $ctx['Username'] -Credential $ctx['Credential']
        }
        'SSO' {
            return Invoke-ISPSSSO -IdentityURL $ctx['IdentityURL'] `
                -PCloudSubdomain $ctx['PCloudSubdomain'] -BaseURL $ctx['BaseURL'] `
                -WebView2AssemblyPath $ctx['WebView2AssemblyPath']
        }
        default {
            throw "Update-ISPSSAuthToken: unknown method '$($ctx['Method'])'. Use Update-SelfHostedAuthToken for Self-Hosted tokens."
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Resolve-IdentityTenantURL',
    'Get-ISPSSAuthToken',
    'Update-ISPSSAuthToken'
)
