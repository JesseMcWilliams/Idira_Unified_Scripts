#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Constants

$script:CLIENT_AUTH_OID       = '1.3.6.1.5.5.7.3.2'
$script:WEBVIEW2_TIMEOUT_SEC  = 300
$script:_WebView2AssemblyPath = $null

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

#endregion

#region Certificate Picker

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

#endregion

#region WebView2

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

function Invoke-WebView2Window {
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

#region Profile Persistence (DPAPI via Export-Clixml)

function Get-ProfileDir {
    $dir = Join-Path $env:APPDATA 'IdiraUnifiedScripts\Profiles'
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
        Serializes an auth token to a DPAPI-protected .cred file.
    .PARAMETER TokenObject
        Token returned by Get-ISPSSAuthToken, Get-SelfHostedAuthToken, or Update-*AuthToken.
    .PARAMETER ProfileName
        Friendly name (resolves to %APPDATA%\IdiraUnifiedScripts\Profiles\<name>.cred).
    .PARAMETER Path
        Explicit destination path. Overrides -ProfileName.
    .OUTPUTS
        [string] Path of the saved file.
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
        Loads a DPAPI-protected auth token saved by Save-AuthToken.
    .DESCRIPTION
        Decrypts the profile and rebuilds the token object. Expired tokens are returned
        as-is with a warning; the caller is responsible for refreshing via Update-ISPSSAuthToken
        or Update-SelfHostedAuthToken when needed.
    .PARAMETER ProfileName
        Name of the profile to load.
    .PARAMETER Path
        Explicit path to a .cred file. Takes precedence over -ProfileName.
    .PARAMETER IgnoreExpiry
        Return the token even if expired without emitting a warning.
    .OUTPUTS
        [PSCustomObject] The same shape as returned by Get-ISPSSAuthToken / Get-SelfHostedAuthToken.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProfileName,

        [Parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true)]
        [string]$Path,

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
        Write-Warning ("Profile '{0}' token expired at {1}. Call Update-ISPSSAuthToken or Update-SelfHostedAuthToken to renew." -f
                       $saved.ProfileName, $tokenObject.Expiry.ToLocalTime())
    }

    return $tokenObject
}

function Get-AuthTokenProfiles {
    <#
    .SYNOPSIS
        Lists all saved auth token profiles in the default profile directory.
    .OUTPUTS
        [PSCustomObject[]] with ProfileName, SystemType, AuthMethod, BaseURL, SavedAt, Expiry, IsExpired, Path.
    #>
    [CmdletBinding()]
    param()

    $dir = Join-Path $env:APPDATA 'IdiraUnifiedScripts\Profiles'
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

Export-ModuleMember -Function @(
    'ConvertTo-PlainText',
    'New-AuthTokenObject',
    'Get-FilteredClientCertificate',
    'Import-WebView2Assembly',
    'Invoke-WebView2Window',
    'Save-AuthToken',
    'Import-AuthToken',
    'Get-AuthTokenProfiles',
    'Remove-AuthTokenProfile'
)
