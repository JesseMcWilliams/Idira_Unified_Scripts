#Requires -Version 5.1
<#
.SYNOPSIS
    Retrieves authentication tokens from CyberArk ISPSS (Privilege Cloud) or Self-Hosted PAM.

.DESCRIPTION
    Supports multiple authentication methods for both CyberArk ISPSS and Self-Hosted PAM.
    ISPSS methods: ClientCredentials, Interactive, SSO
    Self-Hosted methods: CyberArk, LDAP, RADIUS, SAML, OIDC, Shared, PKI, PKIPN

    Returns a rich object containing the token, headers, expiry, and a _RefreshContext that
    can be passed back as -TokenToRefresh for renewal.

.PARAMETER SystemType
    Required. Either 'ISPSS' or 'SelfHosted'.

.PARAMETER AuthMethod
    Authentication method.
    ISPSS:      ClientCredentials | Interactive | SSO
    SelfHosted: CyberArk | LDAP | RADIUS | SAML | OIDC | Shared | PKI | PKIPN

.PARAMETER PCloudSubdomain
    ISPSS only. The subdomain portion of your Privilege Cloud URL.
    Example: for 'acme.privilegecloud.cyberark.cloud', provide 'acme'.

.PARAMETER IdentityTenantURL
    ISPSS only. Overrides the auto-discovered Identity tenant URL.

.PARAMETER ClientId
    ISPSS ClientCredentials: OAuth2 client ID.
    ISPSS Interactive: CyberArk Identity username (optional; prompted if omitted).

.PARAMETER ClientSecret
    ISPSS ClientCredentials: OAuth2 client secret as a SecureString.

.PARAMETER PVWAUrl
    Self-Hosted PVWA base URL. Example: 'https://pvwa.company.com'.

.PARAMETER ConcurrentSession
    Self-Hosted only. Allow concurrent sessions for this logon.

.PARAMETER Credential
    PSCredential for password-based auth methods (CyberArk, LDAP, RADIUS, Interactive).

.PARAMETER Certificate
    X509Certificate2 object for PKI or PKIPN authentication.

.PARAMETER CertificateThumbprint
    Thumbprint of a certificate in the local store for PKI or PKIPN.
    If neither -Certificate nor -CertificateThumbprint is provided, the user is prompted
    with a filtered list of eligible certificates.

.PARAMETER IgnoreSSL
    Bypass SSL certificate validation. Not recommended for production.

.PARAMETER WebView2AssemblyPath
    Full path to Microsoft.Web.WebView2.WinForms.dll. Auto-discovered if not specified.

.PARAMETER TokenToRefresh
    An existing token object returned by a previous Get-AuthToken call. When provided,
    the script attempts to refresh or re-authenticate and returns a new token object.

.OUTPUTS
    [PSCustomObject] with properties:
        Token, TokenType, Headers, Expiry, RefreshToken,
        SystemType, AuthMethod, BaseURL, IdentityURL, TenantId, _RefreshContext

.LINK
    WebView2 Download: https://developer.microsoft.com/en-us/microsoft-edge/webview2/?form=MA13LH&cs=1182422673

.EXTERNALHELP
    https://github.com/
#>

[CmdletBinding()]
param(
    [Parameter(
        Mandatory = $false
        )]
    [ValidateSet('ISPSS', 'SelfHosted')]
    [string]$SystemType,

    [Parameter(
        Mandatory = $false
        )]
    [string]$AuthMethod,

    [Parameter(
        Mandatory = $false
        )]
    [string]$PCloudSubdomain,

    [Parameter(
        Mandatory = $false
        )]
    [string]$IdentityTenantURL,

    [Parameter(
        Mandatory = $false
        )]
    [string]$ClientId,

    [Parameter(
        Mandatory = $false
        )]
    [System.Security.SecureString]$ClientSecret,

    [Parameter(
        Mandatory = $false
        )]
    [string]$PVWAUrl,

    [Parameter(
        Mandatory = $false
        )]
    [switch]$ConcurrentSession,

    [Parameter(
        Mandatory = $false
        )]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(
        Mandatory = $false
        )]
    [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,

    [Parameter(
        Mandatory = $false
        )]
    [string]$CertificateThumbprint,

    [Parameter(
        Mandatory = $false
        )]
    [switch]$IgnoreSSL,

    [Parameter(
        Mandatory = $false
        )]
    [string]$WebView2AssemblyPath,

    [Parameter(
        Mandatory = $false
        )]
    [PSCustomObject]$TokenToRefresh
)

#region Constants

$script:CLIENT_AUTH_OID         = '1.3.6.1.5.5.7.3.2'
$script:PVWA_SESSION_EXPIRY_MIN = 20
$script:WEBVIEW2_TIMEOUT_SEC    = 300
$script:PCLOUD_BASE_TEMPLATE    = 'https://{0}.privilegecloud.cyberark.cloud'
$script:_WebView2AssemblyPath   = $null

$script:PVWA_LOGON_PATHS = @{
    CyberArk = '/API/auth/CyberArk/Logon'
    LDAP     = '/API/auth/LDAP/Logon'
    RADIUS   = '/API/auth/RADIUS/Logon'
    Shared   = '/API/auth/Shared/Logon'
    PKI      = '/API/auth/PKI/Logon'
    PKIPN    = '/API/auth/PKIPN/Logon'
}

$script:VALID_AUTH_METHODS = @{
    ISPSS      = @('ClientCredentials', 'Interactive', 'SSO')
    SelfHosted = @('CyberArk', 'LDAP', 'RADIUS', 'SAML', 'OIDC', 'Shared', 'PKI', 'PKIPN')
}

#endregion

#region Helpers

function ConvertTo-PlainText {
    param([System.Security.SecureString]$SecureString)
    if ($null -eq $SecureString) { return $null }
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr)
    }
}

function New-AuthTokenObject {
    param(
        [string]$Token,
        [string]$TokenType,
        [hashtable]$Headers,
        [DateTime]$Expiry,
        [string]$RefreshToken,
        [string]$SystemType,
        [string]$AuthMethod,
        [string]$BaseURL,
        [string]$IdentityURL,
        [string]$TenantId,
        [hashtable]$RefreshContext
    )
    [PSCustomObject]@{
        Token           = $Token
        TokenType       = $TokenType
        Headers         = $Headers
        Expiry          = $Expiry
        RefreshToken    = $RefreshToken
        SystemType      = $SystemType
        AuthMethod      = $AuthMethod
        BaseURL         = $BaseURL
        IdentityURL     = $IdentityURL
        TenantId        = $TenantId
        _RefreshContext = $RefreshContext
    }
}

function Resolve-IdentityTenantURL {
    param([string]$PCloudSubdomain)
    # Privilege Cloud Identity tenant URLs always follow the pattern
    # https://{subdomain}.id.cyberark.cloud — redirect-following is unreliable
    # because the portal login page uses JavaScript redirects that HttpWebRequest
    # cannot follow, causing it to return the portal host instead of the Identity host.
    $url = "https://$PCloudSubdomain.id.cyberark.cloud"
    Write-Verbose "Identity tenant URL: $url"
    return $url
}

function Get-FilteredClientCertificate {
    param([string]$Thumbprint)

    $now      = [DateTime]::UtcNow
    $allCerts = [System.Collections.Generic.List[System.Security.Cryptography.X509Certificates.X509Certificate2]]::new()
    $locations = @(
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )

    foreach ($loc in $locations) {
        $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
            [System.Security.Cryptography.X509Certificates.StoreName]::My, $loc)
        try {
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            foreach ($cert in $store.Certificates) {
                if ($cert.NotAfter.ToUniversalTime() -lt $now) { continue }
                if (-not $cert.HasPrivateKey) { continue }
                $hasClientAuth = $cert.EnhancedKeyUsageList |
                    Where-Object { $_.ObjectId -eq $script:CLIENT_AUTH_OID }
                if (-not $hasClientAuth) { continue }
                if ($Thumbprint) {
                    $clean = $Thumbprint -replace '\s', ''
                    if ($cert.Thumbprint -ne $clean.ToUpper()) { continue }
                }
                $allCerts.Add($cert)
            }
        } finally {
            $store.Close()
        }
    }

    if ($allCerts.Count -eq 0) {
        if ($Thumbprint) {
            throw "No valid client authentication certificate found with thumbprint '$Thumbprint'."
        }
        throw "No valid client authentication certificates found in the certificate store."
    }

    if ($Thumbprint -or $allCerts.Count -eq 1) {
        Write-Verbose "Selected certificate: $($allCerts[0].Subject)"
        return $allCerts[0]
    }

    Write-Host "`nAvailable client authentication certificates:"
    for ($i = 0; $i -lt $allCerts.Count; $i++) {
        $c = $allCerts[$i]
        Write-Host ("  [{0}] Subject:    {1}" -f ($i + 1), $c.Subject)
        Write-Host ("       Thumbprint: {0}" -f $c.Thumbprint)
        Write-Host ("       Expires:    {0}" -f $c.NotAfter.ToString('yyyy-MM-dd'))
    }
    $idx = 0
    do {
        $sel   = Read-Host "`nSelect certificate number (1-$($allCerts.Count))"
        $valid = [int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $allCerts.Count
    } while (-not $valid)
    return $allCerts[$idx - 1]
}

function Import-WebView2Assembly {
    param([string]$AssemblyPath)

    if ($script:_WebView2AssemblyPath) { return }

    $candidates = [System.Collections.Generic.List[string]]::new()

    if ($AssemblyPath) { $candidates.Add($AssemblyPath) }
    $candidates.Add((Join-Path $PSScriptRoot 'Microsoft.Web.WebView2.WinForms.dll'))
    $candidates.Add((Join-Path $PSScriptRoot 'WebView2\Microsoft.Web.WebView2.WinForms.dll'))

    $nugetRoot = Join-Path $env:USERPROFILE '.nuget\packages\microsoft.web.webview2'
    if (Test-Path $nugetRoot) {
        $found = Get-ChildItem -Path $nugetRoot -Filter 'Microsoft.Web.WebView2.WinForms.dll' `
            -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($found) { $candidates.Add($found.FullName) }
    }

    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path)) {
            try {
                Add-Type -Path $path -ErrorAction Stop
                $script:_WebView2AssemblyPath = $path
                Write-Verbose "Loaded WebView2 from: $path"
                return
            } catch {
                Write-Verbose "Could not load WebView2 from '$path': $_"
            }
        }
    }

    throw ("Microsoft.Web.WebView2.WinForms.dll not found. " +
           "Install via NuGet (Install-Package Microsoft.Web.WebView2) " +
           "or specify -WebView2AssemblyPath.")
}

#endregion

#region WebView2 Window

function Invoke-WebView2Window {
    <#
    .SYNOPSIS
        Opens an embedded WebView2 browser and captures a CyberArk authentication token.
    .PARAMETER NavigateUrl
        URL to open initially.
    .PARAMETER CookieName
        Cookie name prefix to watch. When a matching cookie appears its value is returned
        as the token. Used for ISPSS SSO (cookie prefix: 'idToken').
    .PARAMETER TargetHost
        FQDN to watch. When WebView2 lands on this host, document.body.innerText is
        captured as the session token. Used for Self-Hosted SAML and OIDC.
    .PARAMETER Title
        Browser window title shown to the user.
    #>
    param(
        [string]$NavigateUrl,
        [string]$CookieName,
        [string]$TargetHost,
        [string]$Title = 'CyberArk Authentication'
    )

    $wv2Path    = $script:_WebView2AssemblyPath
    $timeoutSec = $script:WEBVIEW2_TIMEOUT_SEC

    $wv2Script = {
        param($NavigateUrl, $CookieName, $TargetHost, $Title, $TimeoutSec, $Wv2Path)

        if ($Wv2Path) { Add-Type -Path $Wv2Path }
        Add-Type -AssemblyName System.Windows.Forms

        $state = @{
            Result      = $null
            TimedOut    = $false
            Initialized = $false
            StartTime   = [DateTime]::UtcNow
        }

        $form = [System.Windows.Forms.Form]::new()
        $form.Text          = $Title
        $form.Width         = 820
        $form.Height        = 680
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen

        $wv = [Microsoft.Web.WebView2.WinForms.WebView2]::new()
        $wv.Dock = [System.Windows.Forms.DockStyle]::Fill
        $form.Controls.Add($wv)

        $timer          = [System.Windows.Forms.Timer]::new()
        $timer.Interval = 750

        $timer.Add_Tick({
            if (-not $state.Initialized) { return }

            if (([DateTime]::UtcNow - $state.StartTime).TotalSeconds -gt $TimeoutSec) {
                $state.TimedOut = $true
                $timer.Stop()
                $form.Close()
                return
            }

            try {
                if ($CookieName) {
                    $task = $wv.CoreWebView2.CookieManager.GetCookiesAsync($wv.CoreWebView2.Source)
                    if (-not $task.Wait(1000)) { return }
                    $match = $task.Result |
                        Where-Object { $_.Name -like "$CookieName*" } |
                        Select-Object -First 1
                    if ($match) {
                        $state.Result = @{ Token = $match.Value; TokenType = 'Bearer' }
                        $timer.Stop()
                        $form.Close()
                    }
                } elseif ($TargetHost) {
                    $srcUri = [Uri]$wv.CoreWebView2.Source
                    if ($srcUri.Host -eq $TargetHost) {
                        $task = $wv.CoreWebView2.ExecuteScriptAsync('document.body.innerText')
                        if (-not $task.Wait(1000)) { return }
                        $raw   = $task.Result -replace '^"', '' -replace '"$', ''
                        $token = $raw.Trim()
                        if ($token -and $token.Length -lt 4096 -and $token -notmatch '[\r\n\t ]') {
                            $state.Result = @{ Token = $token; TokenType = 'CyberArkSession' }
                            $timer.Stop()
                            $form.Close()
                        }
                    }
                }
            } catch { }
        })

        $wv.Add_CoreWebView2InitializationCompleted({
            $state.Initialized = $true
            $wv.CoreWebView2.Navigate($NavigateUrl)
        })

        [void]$wv.EnsureCoreWebView2Async($null)
        $timer.Start()
        [System.Windows.Forms.Application]::Run($form)

        $timer.Dispose()
        $wv.Dispose()
        $form.Dispose()

        if ($state.TimedOut) { return $null }
        return $state.Result
    }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $runspace.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($wv2Script).AddParameters(@{
        NavigateUrl = $NavigateUrl
        CookieName  = $CookieName
        TargetHost  = $TargetHost
        Title       = $Title
        TimeoutSec  = $timeoutSec
        Wv2Path     = $wv2Path
    })

    try {
        $output = $ps.Invoke()
    } finally {
        $runspace.Close()
        $ps.Dispose()
        $runspace.Dispose()
    }

    if ($ps.HadErrors) {
        throw "WebView2 window error: $($ps.Streams.Error[0].Exception.Message)"
    }

    $captured = $output | Where-Object { $null -ne $_ } | Select-Object -First 1
    if (-not $captured) {
        throw "Authentication timed out or was cancelled in the browser window."
    }
    return $captured
}

#endregion

#region ISPSS Authentication

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
                Write-Host "Waiting for out-of-band approval..."
                do {
                    Start-Sleep -Seconds 3
                    $resp = Invoke-IdentityAdvancedAuth -IdentityURL $IdentityURL -TenantId $TenantId `
                        -SessionId $SessionId -MechanismId $selectedMech.MechanismId -Action 'Poll'
                } while ($resp.Result -is [string] -and $resp.Result -eq 'OobPending')
            }
            default {
                # OATH (TOTP) and any other text-entry mechanism
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

        # Final success: Result is an object (not a plain string) containing the token
        if ($resp -and ($resp.Result -isnot [string]) -and $resp.Result.Token) {
            return $resp.Result.Token
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

    $tenantId  = $startResp.Result.TenantId
    $sessionId = $startResp.Result.SessionId
    $challenges = $startResp.Result.Challenges
    $token      = $null

    if ($startResp.Result.IdpRedirectShortUrl) {
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

#region Self-Hosted Authentication

function Invoke-PVWALogon {
    param(
        [string]$Url,
        [string]$Body,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [switch]$IgnoreSSL
    )
    $params = @{
        Uri         = $Url
        Method      = 'POST'
        Headers     = @{ 'Content-Type' = 'application/json' }
        Body        = $Body
        ErrorAction = 'Stop'
    }
    if ($Certificate) { $params.Certificate = $Certificate }
    if ($IgnoreSSL) {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $params.SkipCertificateCheck = $true
        } else {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
    }
    $result = Invoke-RestMethod @params
    return $result.ToString().Trim('"')
}

function Invoke-SelfHostedPasswordAuth {
    param(
        [string]$PVWAUrl,
        [string]$AuthMethod,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$Username,
        [switch]$ConcurrentSession,
        [switch]$IgnoreSSL
    )

    if (-not $Credential) {
        $credParams = @{ Message = "Enter credentials for CyberArk $AuthMethod authentication" }
        if ($Username) { $credParams['UserName'] = $Username }
        $Credential = Get-Credential @credParams
    }

    $body = @{
        username          = $Credential.UserName
        password          = $Credential.GetNetworkCredential().Password
        concurrentSession = $ConcurrentSession.IsPresent
    } | ConvertTo-Json

    $logonUrl = "$PVWAUrl$($script:PVWA_LOGON_PATHS[$AuthMethod])"
    Write-Verbose "Authenticating via $AuthMethod at: $logonUrl"
    try {
        $token = Invoke-PVWALogon -Url $logonUrl -Body $body -IgnoreSSL:$IgnoreSSL
    } catch {
        throw "$AuthMethod authentication failed at '$logonUrl': $_"
    }

    New-AuthTokenObject `
        -Token        $token `
        -TokenType    'CyberArkSession' `
        -Headers      @{ Authorization = $token; 'Content-Type' = 'application/json' } `
        -Expiry       ([DateTime]::UtcNow.AddMinutes($script:PVWA_SESSION_EXPIRY_MIN)) `
        -RefreshToken $null `
        -SystemType   'SelfHosted' `
        -AuthMethod   $AuthMethod `
        -BaseURL      $PVWAUrl `
        -IdentityURL  $null `
        -TenantId     $null `
        -RefreshContext @{
            Method            = $AuthMethod
            PVWAUrl           = $PVWAUrl
            Credential        = $Credential
            ConcurrentSession = $ConcurrentSession.IsPresent
            IgnoreSSL         = $IgnoreSSL.IsPresent
        }
}

function Invoke-SelfHostedShared {
    param(
        [string]$PVWAUrl,
        [switch]$ConcurrentSession,
        [switch]$IgnoreSSL
    )

    $body     = @{ concurrentSession = $ConcurrentSession.IsPresent } | ConvertTo-Json
    $logonUrl = "$PVWAUrl$($script:PVWA_LOGON_PATHS['Shared'])"
    Write-Verbose "Authenticating via Shared at: $logonUrl"
    try {
        $token = Invoke-PVWALogon -Url $logonUrl -Body $body -IgnoreSSL:$IgnoreSSL
    } catch {
        throw "Shared authentication failed at '$logonUrl': $_"
    }

    New-AuthTokenObject `
        -Token        $token `
        -TokenType    'CyberArkSession' `
        -Headers      @{ Authorization = $token; 'Content-Type' = 'application/json' } `
        -Expiry       ([DateTime]::UtcNow.AddMinutes($script:PVWA_SESSION_EXPIRY_MIN)) `
        -RefreshToken $null `
        -SystemType   'SelfHosted' `
        -AuthMethod   'Shared' `
        -BaseURL      $PVWAUrl `
        -IdentityURL  $null `
        -TenantId     $null `
        -RefreshContext @{
            Method            = 'Shared'
            PVWAUrl           = $PVWAUrl
            ConcurrentSession = $ConcurrentSession.IsPresent
            IgnoreSSL         = $IgnoreSSL.IsPresent
        }
}

function Invoke-SelfHostedPKI {
    param(
        [string]$PVWAUrl,
        [string]$AuthMethod,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [switch]$ConcurrentSession,
        [switch]$IgnoreSSL
    )

    $body     = @{ concurrentSession = $ConcurrentSession.IsPresent } | ConvertTo-Json
    $logonUrl = "$PVWAUrl$($script:PVWA_LOGON_PATHS[$AuthMethod])"
    Write-Verbose "Authenticating via $AuthMethod at: $logonUrl"
    try {
        $token = Invoke-PVWALogon -Url $logonUrl -Body $body -Certificate $Certificate -IgnoreSSL:$IgnoreSSL
    } catch {
        throw "$AuthMethod authentication failed at '$logonUrl': $_"
    }

    New-AuthTokenObject `
        -Token        $token `
        -TokenType    'CyberArkSession' `
        -Headers      @{ Authorization = $token; 'Content-Type' = 'application/json' } `
        -Expiry       ([DateTime]::UtcNow.AddMinutes($script:PVWA_SESSION_EXPIRY_MIN)) `
        -RefreshToken $null `
        -SystemType   'SelfHosted' `
        -AuthMethod   $AuthMethod `
        -BaseURL      $PVWAUrl `
        -IdentityURL  $null `
        -TenantId     $null `
        -RefreshContext @{
            Method            = $AuthMethod
            PVWAUrl           = $PVWAUrl
            Certificate       = $Certificate
            ConcurrentSession = $ConcurrentSession.IsPresent
            IgnoreSSL         = $IgnoreSSL.IsPresent
        }
}

function Invoke-SelfHostedSAML {
    param(
        [string]$PVWAUrl,
        [string]$WebView2AssemblyPath,
        [switch]$IgnoreSSL
    )

    Import-WebView2Assembly -AssemblyPath $WebView2AssemblyPath

    $samlUrl  = "$PVWAUrl/API/auth/SAML/Logon"
    $pvwaHost = ([Uri]$PVWAUrl).Host
    Write-Verbose "Opening WebView2 for PVWA SAML login, monitoring host: $pvwaHost"

    $captured = Invoke-WebView2Window -NavigateUrl $samlUrl -TargetHost $pvwaHost `
        -Title 'CyberArk PVWA SAML Login'

    New-AuthTokenObject `
        -Token        $captured.Token `
        -TokenType    'CyberArkSession' `
        -Headers      @{ Authorization = $captured.Token; 'Content-Type' = 'application/json' } `
        -Expiry       ([DateTime]::UtcNow.AddMinutes($script:PVWA_SESSION_EXPIRY_MIN)) `
        -RefreshToken $null `
        -SystemType   'SelfHosted' `
        -AuthMethod   'SAML' `
        -BaseURL      $PVWAUrl `
        -IdentityURL  $null `
        -TenantId     $null `
        -RefreshContext @{
            Method               = 'SAML'
            PVWAUrl              = $PVWAUrl
            WebView2AssemblyPath = $WebView2AssemblyPath
            IgnoreSSL            = $IgnoreSSL.IsPresent
        }
}

function Invoke-SelfHostedOIDC {
    param(
        [string]$PVWAUrl,
        [string]$WebView2AssemblyPath,
        [switch]$IgnoreSSL
    )

    Import-WebView2Assembly -AssemblyPath $WebView2AssemblyPath

    $oidcUrl  = "$PVWAUrl/API/auth/OIDC/Logon"
    $pvwaHost = ([Uri]$PVWAUrl).Host
    Write-Verbose "Opening WebView2 for PVWA OIDC login, monitoring host: $pvwaHost"

    $captured = Invoke-WebView2Window -NavigateUrl $oidcUrl -TargetHost $pvwaHost `
        -Title 'CyberArk PVWA OIDC Login'

    New-AuthTokenObject `
        -Token        $captured.Token `
        -TokenType    'CyberArkSession' `
        -Headers      @{ Authorization = $captured.Token; 'Content-Type' = 'application/json' } `
        -Expiry       ([DateTime]::UtcNow.AddMinutes($script:PVWA_SESSION_EXPIRY_MIN)) `
        -RefreshToken $null `
        -SystemType   'SelfHosted' `
        -AuthMethod   'OIDC' `
        -BaseURL      $PVWAUrl `
        -IdentityURL  $null `
        -TenantId     $null `
        -RefreshContext @{
            Method               = 'OIDC'
            PVWAUrl              = $PVWAUrl
            WebView2AssemblyPath = $WebView2AssemblyPath
            IgnoreSSL            = $IgnoreSSL.IsPresent
        }
}

#endregion

#region Public Functions

function Get-AuthToken {
    [CmdletBinding()]
    param(
        [ValidateSet('ISPSS', 'SelfHosted')]
        [string]$SystemType,
        [string]$AuthMethod,
        [string]$PCloudSubdomain,
        [string]$IdentityTenantURL,
        [string]$ClientId,
        [System.Security.SecureString]$ClientSecret,
        [string]$PVWAUrl,
        [switch]$ConcurrentSession,
        [System.Management.Automation.PSCredential]$Credential,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$CertificateThumbprint,
        [string]$Username,
        [switch]$IgnoreSSL,
        [string]$WebView2AssemblyPath,
        [PSCustomObject]$TokenToRefresh
    )

    if ($TokenToRefresh) {
        return Update-AuthToken -TokenObject $TokenToRefresh
    }

    if (-not $SystemType) {
        do {
            $SystemType = Read-Host "System type [ISPSS / SelfHosted]"
        } while ($SystemType -notin @('ISPSS', 'SelfHosted'))
    }

    $validMethods = $script:VALID_AUTH_METHODS[$SystemType]
    if (-not $AuthMethod -or $AuthMethod -notin $validMethods) {
        Write-Host ''
        Write-Host "  Authentication Method ($SystemType):" -ForegroundColor White
        for ($i = 0; $i -lt $validMethods.Count; $i++) {
            Write-Host ("    [$($i+1)] $($validMethods[$i])") -ForegroundColor Gray
        }
        do {
            $authChoice = Read-Host "Select method (1-$($validMethods.Count))"
            $authIdx = 0
            $authValid = [int]::TryParse($authChoice, [ref]$authIdx) -and $authIdx -ge 1 -and $authIdx -le $validMethods.Count
            if (-not $authValid) {
                Write-Host "  Enter a number between 1 and $($validMethods.Count)." -ForegroundColor Yellow
            }
        } while (-not $authValid)
        $AuthMethod = $validMethods[$authIdx - 1]
    }

    if ($IgnoreSSL -and $PSVersionTable.PSVersion.Major -lt 6) {
        Write-Warning "SSL certificate verification is disabled."
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }

    switch ($SystemType) {
        'ISPSS' {
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
                    $usernameToUse = if ($ClientId)      { $ClientId }
                                     elseif ($Username)   { $Username }
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
        }

        'SelfHosted' {
            if (-not $PVWAUrl) {
                $PVWAUrl = Read-Host "PVWA base URL (e.g. https://pvwa.company.com)"
            }
            $PVWAUrl = $PVWAUrl.TrimEnd('/')

            switch ($AuthMethod) {
                { $_ -in @('CyberArk', 'LDAP', 'RADIUS') } {
                    return Invoke-SelfHostedPasswordAuth -PVWAUrl $PVWAUrl -AuthMethod $AuthMethod `
                        -Credential $Credential -Username $Username -ConcurrentSession:$ConcurrentSession -IgnoreSSL:$IgnoreSSL
                }
                'Shared' {
                    return Invoke-SelfHostedShared -PVWAUrl $PVWAUrl `
                        -ConcurrentSession:$ConcurrentSession -IgnoreSSL:$IgnoreSSL
                }
                { $_ -in @('PKI', 'PKIPN') } {
                    if (-not $Certificate) {
                        $Certificate = Get-FilteredClientCertificate -Thumbprint $CertificateThumbprint
                    }
                    return Invoke-SelfHostedPKI -PVWAUrl $PVWAUrl -AuthMethod $AuthMethod `
                        -Certificate $Certificate -ConcurrentSession:$ConcurrentSession -IgnoreSSL:$IgnoreSSL
                }
                'SAML' {
                    return Invoke-SelfHostedSAML -PVWAUrl $PVWAUrl `
                        -WebView2AssemblyPath $WebView2AssemblyPath -IgnoreSSL:$IgnoreSSL
                }
                'OIDC' {
                    return Invoke-SelfHostedOIDC -PVWAUrl $PVWAUrl `
                        -WebView2AssemblyPath $WebView2AssemblyPath -IgnoreSSL:$IgnoreSSL
                }
            }
        }
    }

    throw "Unhandled combination: SystemType='$SystemType' AuthMethod='$AuthMethod'"
}

function Update-AuthToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$TokenObject
    )

    $ctx = $TokenObject._RefreshContext
    if (-not $ctx) { throw "Token object missing _RefreshContext - cannot refresh." }

    switch ($ctx.Method) {
        'ClientCredentials' {
            if ($TokenObject.RefreshToken) {
                Write-Verbose "Attempting refresh_token grant."
                try {
                    $body = ("grant_type=refresh_token" +
                             "&refresh_token=$([Uri]::EscapeDataString($TokenObject.RefreshToken))" +
                             "&client_id=$([Uri]::EscapeDataString($ctx.ClientId))")
                    $resp = Invoke-RestMethod -Uri "$($ctx.IdentityURL)/oauth2/platformtoken" `
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
                        -BaseURL      $ctx.BaseURL `
                        -IdentityURL  $ctx.IdentityURL `
                        -TenantId     '' `
                        -RefreshContext @{
                            Method       = 'ClientCredentials'
                            IdentityURL  = $ctx.IdentityURL
                            ClientId     = $ctx.ClientId
                            ClientSecret = $ctx.ClientSecret
                            BaseURL      = $ctx.BaseURL
                        }
                } catch {
                    Write-Warning "refresh_token grant failed, re-authenticating: $_"
                }
            }
            return Invoke-ISPSSClientCredentials -IdentityURL $ctx.IdentityURL `
                -ClientId $ctx.ClientId -ClientSecret $ctx.ClientSecret -BaseURL $ctx.BaseURL
        }
        'Interactive' {
            Write-Host "Interactive session expired - please re-authenticate."
            return Invoke-ISPSSInteractive -IdentityURL $ctx.IdentityURL `
                -PCloudSubdomain $ctx.PCloudSubdomain -BaseURL $ctx.BaseURL `
                -Username $ctx.Username -Credential $ctx.Credential
        }
        'SSO' {
            Write-Host "SSO session expired - please re-authenticate via browser."
            return Invoke-ISPSSSO -IdentityURL $ctx.IdentityURL `
                -PCloudSubdomain $ctx.PCloudSubdomain -BaseURL $ctx.BaseURL `
                -WebView2AssemblyPath $ctx.WebView2AssemblyPath
        }
        { $_ -in @('CyberArk', 'LDAP', 'RADIUS') } {
            return Invoke-SelfHostedPasswordAuth -PVWAUrl $ctx.PVWAUrl -AuthMethod $ctx.Method `
                -Credential $ctx.Credential `
                -ConcurrentSession:([switch]::new($ctx.ConcurrentSession)) `
                -IgnoreSSL:([switch]::new($ctx.IgnoreSSL))
        }
        'Shared' {
            return Invoke-SelfHostedShared -PVWAUrl $ctx.PVWAUrl `
                -ConcurrentSession:([switch]::new($ctx.ConcurrentSession)) `
                -IgnoreSSL:([switch]::new($ctx.IgnoreSSL))
        }
        { $_ -in @('PKI', 'PKIPN') } {
            return Invoke-SelfHostedPKI -PVWAUrl $ctx.PVWAUrl -AuthMethod $ctx.Method `
                -Certificate $ctx.Certificate `
                -ConcurrentSession:([switch]::new($ctx.ConcurrentSession)) `
                -IgnoreSSL:([switch]::new($ctx.IgnoreSSL))
        }
        'SAML' {
            Write-Host "SAML session expired - please re-authenticate via browser."
            return Invoke-SelfHostedSAML -PVWAUrl $ctx.PVWAUrl `
                -WebView2AssemblyPath $ctx.WebView2AssemblyPath `
                -IgnoreSSL:([switch]::new($ctx.IgnoreSSL))
        }
        'OIDC' {
            Write-Host "OIDC session expired - please re-authenticate via browser."
            return Invoke-SelfHostedOIDC -PVWAUrl $ctx.PVWAUrl `
                -WebView2AssemblyPath $ctx.WebView2AssemblyPath `
                -IgnoreSSL:([switch]::new($ctx.IgnoreSSL))
        }
        default {
            throw "Unknown auth method in _RefreshContext: '$($ctx.Method)'"
        }
    }
}

#endregion

#region Profile Persistence (DPAPI via Export-Clixml)

function Get-ProfileDir {
    $dir = Join-Path $env:APPDATA 'CyberArkPAS'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Resolve-ProfilePath {
    param(
        [string]$ProfileName,
        [string]$Path,
        [string]$SystemType,
        [string]$AuthMethod
    )
    if ($Path) { return $Path }
    $dir = Get-ProfileDir
    if ($ProfileName) {
        $safe = $ProfileName -replace '[\\/:*?"<>|]', '_'
        return Join-Path $dir "$safe.cred"
    }
    if ($SystemType -and $AuthMethod) {
        $safe = ($SystemType + '_' + $AuthMethod) -replace '[^A-Za-z0-9_-]', '_'
        return Join-Path $dir "$safe.cred"
    }
    return $null
}

function Save-AuthToken {
    <#
    .SYNOPSIS
        Serializes an auth token object to a named profile, DPAPI-protecting all sensitive fields.

    .DESCRIPTION
        Converts Token and RefreshToken strings to SecureString so that Export-Clixml's DPAPI
        protection covers them alongside ClientSecret and Credential. The resulting file can
        only be decrypted by the same Windows user on the same machine.

        Profiles are stored in %APPDATA%\CyberArkPAS\<ProfileName>.cred.
        When no profile name or path is given the name defaults to <SystemType>_<AuthMethod>.

    .PARAMETER TokenObject
        The object returned by Get-AuthToken or Update-AuthToken.

    .PARAMETER ProfileName
        Friendly name for this profile (e.g. 'Development', 'Production').

    .PARAMETER Path
        Explicit destination path. Overrides -ProfileName and the default naming scheme.

    .OUTPUTS
        [string] The path of the saved file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSCustomObject]$TokenObject,

        [Parameter(Mandatory = $false)]
        [string]$ProfileName,

        [Parameter(Mandatory = $false)]
        [string]$Path
    )

    $resolvedPath = Resolve-ProfilePath -ProfileName $ProfileName -Path $Path `
        -SystemType $TokenObject.SystemType -AuthMethod $TokenObject.AuthMethod

    # Ensure the directory exists for explicit paths too
    $dir = Split-Path $resolvedPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $ctx = $TokenObject._RefreshContext

    $ctxSerial = @{
        Method                = $ctx['Method']
        IdentityURL           = $ctx['IdentityURL']
        PCloudSubdomain       = $ctx['PCloudSubdomain']
        Username              = $ctx['Username']
        ClientId              = $ctx['ClientId']
        ClientSecret          = $ctx['ClientSecret']       # SecureString - DPAPI via Export-Clixml
        Credential            = $ctx['Credential']         # PSCredential - DPAPI via Export-Clixml
        CertificateThumbprint = if ($ctx['Certificate']) { $ctx['Certificate'].Thumbprint }
                                else { $ctx['CertificateThumbprint'] }
        ConcurrentSession     = $ctx['ConcurrentSession']
        IgnoreSSL             = $ctx['IgnoreSSL']
        PVWAUrl               = $ctx['PVWAUrl']
        BaseURL               = $ctx['BaseURL']
        WebView2AssemblyPath  = $ctx['WebView2AssemblyPath']
    }

    [PSCustomObject]@{
        ProfileName        = if ($ProfileName) { $ProfileName } else { [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath) }
        TokenSecure        = ConvertTo-SecureString $TokenObject.Token -AsPlainText -Force
        TokenType          = $TokenObject.TokenType
        Expiry             = $TokenObject.Expiry
        RefreshTokenSecure = if ($TokenObject.RefreshToken) {
                                 ConvertTo-SecureString $TokenObject.RefreshToken -AsPlainText -Force
                             } else { $null }
        SystemType         = $TokenObject.SystemType
        AuthMethod         = $TokenObject.AuthMethod
        BaseURL            = $TokenObject.BaseURL
        IdentityURL        = $TokenObject.IdentityURL
        TenantId           = $TokenObject.TenantId
        RefreshContext     = $ctxSerial
        SavedAt            = [DateTime]::UtcNow
    } | Export-Clixml -Path $resolvedPath -Force

    Write-Verbose "Auth token saved to: $resolvedPath"
    return $resolvedPath
}

function Import-AuthToken {
    <#
    .SYNOPSIS
        Loads a DPAPI-protected auth token profile saved by Save-AuthToken.

    .DESCRIPTION
        Decrypts the profile, rebuilds the token object (reloading the certificate from the
        local store when a thumbprint is present), and optionally refreshes an expired token.

    .PARAMETER ProfileName
        Name of the profile to load (e.g. 'Development'). Resolves to
        %APPDATA%\CyberArkPAS\<ProfileName>.cred.

    .PARAMETER Path
        Explicit path to a profile file. Takes precedence over -ProfileName.

    .PARAMETER AutoRefresh
        When the token is expired, automatically call Update-AuthToken and overwrite the
        profile with the renewed token before returning.

    .PARAMETER IgnoreExpiry
        Return the token object even if expired without emitting a warning. Use when the
        caller manages its own refresh logic.

    .OUTPUTS
        [PSCustomObject] The same shape as returned by Get-AuthToken.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProfileName,

        [Parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [switch]$AutoRefresh,

        [Parameter(Mandatory = $false)]
        [switch]$IgnoreExpiry
    )

    $resolvedPath = Resolve-ProfilePath -ProfileName $ProfileName -Path $Path
    if (-not $resolvedPath) {
        throw "Provide -ProfileName or -Path to locate the saved profile."
    }
    if (-not (Test-Path $resolvedPath)) {
        $label = if ($ProfileName) { "profile '$ProfileName'" } else { "path '$resolvedPath'" }
        throw "No saved auth token found for $label."
    }

    $saved = Import-Clixml -Path $resolvedPath

    $token        = ConvertTo-PlainText $saved.TokenSecure
    $refreshToken = if ($saved.RefreshTokenSecure) { ConvertTo-PlainText $saved.RefreshTokenSecure } else { $null }

    $ctx  = $saved.RefreshContext
    $cert = $null
    if ($ctx['CertificateThumbprint']) {
        try {
            $cert = Get-FilteredClientCertificate -Thumbprint $ctx['CertificateThumbprint']
        } catch {
            Write-Warning "Could not reload certificate (thumbprint: $($ctx['CertificateThumbprint'])): $_"
        }
    }

    $refreshContext = @{
        Method                = $ctx['Method']
        IdentityURL           = $ctx['IdentityURL']
        PCloudSubdomain       = $ctx['PCloudSubdomain']
        Username              = $ctx['Username']
        ClientId              = $ctx['ClientId']
        ClientSecret          = $ctx['ClientSecret']
        Credential            = $ctx['Credential']
        Certificate           = $cert
        CertificateThumbprint = $ctx['CertificateThumbprint']
        ConcurrentSession     = $ctx['ConcurrentSession']
        IgnoreSSL             = $ctx['IgnoreSSL']
        PVWAUrl               = $ctx['PVWAUrl']
        BaseURL               = $ctx['BaseURL']
        WebView2AssemblyPath  = $ctx['WebView2AssemblyPath']
    }

    $headers = if ($saved.TokenType -eq 'Bearer') {
        if ($saved.AuthMethod -in @('Interactive', 'SSO')) {
            @{ Authorization = "Bearer $token"; 'X-IDAP-NATIVE-CLIENT' = 'true'; 'Content-Type' = 'application/json' }
        } else {
            @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
        }
    } else {
        @{ Authorization = $token; 'Content-Type' = 'application/json' }
    }

    $tokenObject = New-AuthTokenObject `
        -Token          $token `
        -TokenType      $saved.TokenType `
        -Headers        $headers `
        -Expiry         $saved.Expiry `
        -RefreshToken   $refreshToken `
        -SystemType     $saved.SystemType `
        -AuthMethod     $saved.AuthMethod `
        -BaseURL        $saved.BaseURL `
        -IdentityURL    $saved.IdentityURL `
        -TenantId       $saved.TenantId `
        -RefreshContext $refreshContext

    $isExpired = $tokenObject.Expiry -lt [DateTime]::UtcNow

    if ($isExpired -and -not $IgnoreExpiry) {
        if ($AutoRefresh) {
            Write-Verbose "Profile '$($saved.ProfileName)' token is expired. Auto-refreshing..."
            $tokenObject = Update-AuthToken -TokenObject $tokenObject
            Save-AuthToken -TokenObject $tokenObject -Path $resolvedPath | Out-Null
        } else {
            Write-Warning ("Profile '{0}' token expired at {1}. Use -AutoRefresh to renew automatically." -f
                           $saved.ProfileName, $tokenObject.Expiry.ToLocalTime())
        }
    }

    return $tokenObject
}

function Get-AuthTokenProfiles {
    <#
    .SYNOPSIS
        Lists all saved auth token profiles in the default profile directory.

    .DESCRIPTION
        Reads each profile file in %APPDATA%\CyberArkPAS\ and returns a summary object
        for each one. The returned objects can be piped directly to Import-AuthToken or
        Remove-AuthTokenProfile.

    .OUTPUTS
        [PSCustomObject[]] with properties:
            ProfileName, SystemType, AuthMethod, BaseURL, SavedAt, Expiry, IsExpired, Path
    #>
    [CmdletBinding()]
    param()

    $dir = Join-Path $env:APPDATA 'CyberArkPAS'
    if (-not (Test-Path $dir)) {
        Write-Verbose "Profile directory does not exist: $dir"
        return
    }

    $now   = [DateTime]::UtcNow
    $files = Get-ChildItem -Path $dir -Filter '*.cred' -File -ErrorAction SilentlyContinue

    foreach ($file in $files) {
        try {
            $saved = Import-Clixml -Path $file.FullName
            [PSCustomObject]@{
                ProfileName = if ($saved.ProfileName) { $saved.ProfileName }
                              else { $file.BaseName }
                SystemType  = $saved.SystemType
                AuthMethod  = $saved.AuthMethod
                BaseURL     = $saved.BaseURL
                SavedAt     = $saved.SavedAt
                Expiry      = $saved.Expiry
                IsExpired   = ($saved.Expiry -lt $now)
                Path        = $file.FullName
            }
        } catch {
            Write-Warning "Could not read profile '$($file.Name)': $_"
        }
    }
}

function Remove-AuthTokenProfile {
    <#
    .SYNOPSIS
        Deletes a saved auth token profile.

    .PARAMETER ProfileName
        Name of the profile to delete.

    .PARAMETER Path
        Explicit path to the profile file. Accepts pipeline input from Get-AuthTokenProfiles.

    .EXAMPLE
        Remove-AuthTokenProfile -ProfileName 'Development'

    .EXAMPLE
        Get-AuthTokenProfiles | Where-Object IsExpired | Remove-AuthTokenProfile
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProfileName,

        [Parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true)]
        [string]$Path
    )
    process {
        $resolvedPath = Resolve-ProfilePath -ProfileName $ProfileName -Path $Path
        if (-not $resolvedPath) {
            throw "Provide -ProfileName or -Path to identify the profile to remove."
        }
        if (-not (Test-Path $resolvedPath)) {
            $label = if ($ProfileName) { "profile '$ProfileName'" } else { $resolvedPath }
            Write-Warning "No profile file found for $label - nothing removed."
            return
        }
        $label = if ($ProfileName) { $ProfileName } else { [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath) }
        if ($PSCmdlet.ShouldProcess($resolvedPath, "Remove auth token profile '$label'")) {
            Remove-Item -Path $resolvedPath -Force
            Write-Verbose "Removed profile '$label' from: $resolvedPath"
        }
    }
}

#endregion

# Entry point: execute when invoked directly; skip when dot-sourced
if ($MyInvocation.InvocationName -ne '.') {
    Get-AuthToken @PSBoundParameters
}
