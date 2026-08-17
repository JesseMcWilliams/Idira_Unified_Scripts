#Requires -Version 5.1
<#
.SYNOPSIS
    Idira Unified Scripts - CyberArk PAS interactive driver.

.DESCRIPTION
    Profile-managed, authenticated sessions for CyberArk ISPSS (Privilege Cloud SaaS)
    and Self-Hosted PAM. Provides profile management, categorized API action menus,
    CSV bulk processing, and robust session logging.

.PARAMETER StartProfile
    Pre-select a profile by name. Used internally by the Restart flow.

.PARAMETER WhatIf
    Enable WhatIf mode for the session (suppresses all write/modify/delete API calls).
#>
[CmdletBinding()]
param(
    [string]$StartProfile,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Configuration ---

$script:AppName              = 'Idira Unified Scripts - CyberArk PAS Driver'
$script:Version              = '1.0.0'
$script:AuthScriptPath       = Join-Path $PSScriptRoot 'Auth\Get-AuthToken.ps1'
$script:LoggingModulePath    = Join-Path $PSScriptRoot 'Modules\CyberArkLogging.psm1'
$script:CommsModulePath      = Join-Path $PSScriptRoot 'Modules\CyberArkComms.psm1'
$script:APIModulesPath       = Join-Path $PSScriptRoot 'APIModules'
$script:DefaultProfileDir    = Join-Path $env:APPDATA 'CyberArkPAS'
$script:ProfileDir           = $script:DefaultProfileDir
$script:InactivityTimeoutMin = 10
$script:TokenExpiryWarnMin   = 5
$script:WhatIfMode           = $WhatIf.IsPresent
$script:ScreenWidth          = 80
$script:SessionToken         = $null   # Active token object - set after successful auth
$script:ActiveProfile        = $null   # Active driver profile JSON object

#endregion

#region --- Startup Checks ---

function Assert-Prerequisites {
    $missing = @()
    if (-not (Test-Path -LiteralPath $script:AuthScriptPath)) {
        $missing += "Auth script not found: $($script:AuthScriptPath)"
    }
    if (-not (Test-Path -LiteralPath $script:LoggingModulePath)) {
        $missing += "Logging module not found: $($script:LoggingModulePath)"
    }
    if (-not (Test-Path -LiteralPath $script:CommsModulePath)) {
        $missing += "Comms module not found: $($script:CommsModulePath)"
    }
    if ($missing) {
        Write-Host "`nPrerequisite check failed:" -ForegroundColor Red
        $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        Write-Host "`nEnsure all modules are present alongside Driver.ps1." -ForegroundColor Red
        exit 1
    }

    Import-Module $script:LoggingModulePath   -Force -ErrorAction Stop
    Import-Module $script:CommsModulePath     -Force -ErrorAction Stop
}

#endregion

#region --- Display Helpers ---

function Show-Header {
    param([string[]]$Breadcrumbs = @())
    Clear-Host
    $bar = '=' * $script:ScreenWidth
    Write-Host $bar -ForegroundColor Cyan
    $title = "  $($script:AppName)  v$($script:Version)"
    Write-Host $title -ForegroundColor White
    if ($Breadcrumbs) {
        $crumb = '  ' + ($Breadcrumbs -join ' > ')
        Write-Host $crumb -ForegroundColor DarkCyan
    }
    if ($script:WhatIfMode) {
        Write-Host '  [WhatIf Mode ON - no changes will be made]' -ForegroundColor Yellow
    }
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ''
}

function Show-Divider {
    Write-Host ('-' * $script:ScreenWidth) -ForegroundColor DarkGray
}

function Read-MenuChoice {
    param([string]$Prompt = 'Choice')
    Write-Host ''
    Write-Host "  $Prompt" -ForegroundColor White -NoNewline
    Write-Host ': ' -NoNewline
    return (Read-Host).Trim()
}

function Confirm-Action {
    param([string]$Message)
    Write-Host "`n  $Message" -ForegroundColor Yellow -NoNewline
    Write-Host ' [Y/N]: ' -NoNewline
    $answer = (Read-Host).Trim()
    return $answer -match '^[Yy]$'
}

function Show-FieldPrompt {
    param(
        [string]$Label,
        [string]$Default = '',
        [string]$Description = '',
        [switch]$Required,
        [switch]$IsSecret
    )
    if ($Description) {
        Write-Host "    $Description" -ForegroundColor DarkGray
    }
    $defaultHint = if ($Default) {
        if ($IsSecret) { '  [current: ***]' } else { "  [default: $Default]" }
    } else { '' }

    Write-Host "    $Label$defaultHint" -ForegroundColor White -NoNewline
    Write-Host ': ' -NoNewline

    $value = if ($IsSecret) {
        $ss = Read-Host -AsSecureString
        if ($ss.Length -gt 0) {
            [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
        } else { $null }
    } else {
        Read-Host
    }

    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Get-CsvSavePath {
    param(
        [string]$DefaultFolder,
        [string]$ModuleName
    )
    $safeName    = ($ModuleName -replace '[\\/:*?"<>|]', '_').Trim()
    $defaultName = "$safeName $(Get-Date -Format 'yyyy-MM-dd').csv"
    $defaultDir  = if ($DefaultFolder -and (Test-Path -LiteralPath $DefaultFolder)) {
        $DefaultFolder
    } else {
        (Get-Location).Path
    }
    $defaultPath = Join-Path $defaultDir $defaultName

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog                  = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Title            = 'Save Results to CSV'
        $dialog.Filter           = 'CSV Files (*.csv)|*.csv|All Files (*.*)|*.*'
        $dialog.DefaultExt       = 'csv'
        $dialog.FileName         = $defaultName
        $dialog.InitialDirectory = $defaultDir
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
        return $null
    } catch {
        $path = Show-FieldPrompt -Label 'CSV save path' -Default $defaultPath `
            -Description 'Full path for the output CSV file. Leave blank to cancel.'
        if ($path) { return $path } else { return $null }
    }
}

function Invoke-EntitySearch {
    # Searches a list endpoint and lets the user pick from numbered results.
    # Returns the selected entity ID string, or $null if cancelled or nothing found.
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $true)]  [string]$Endpoint,
        [Parameter(Mandatory = $true)]  [string]$SearchTerm,
        [Parameter(Mandatory = $false)] [string]$SearchParam        = 'search',
        [Parameter(Mandatory = $false)] [string]$ResponseProperty   = 'value',
        [Parameter(Mandatory = $false)] [string]$IdProperty         = 'id',
        [Parameter(Mandatory = $false)] [string[]]$DisplayProperties = @('id', 'name'),
        [Parameter(Mandatory = $false)] [string]$EntityLabel        = 'item',
        [Parameter(Mandatory = $false)] [bool]$IgnoreSSL            = $false,
        # When set, fetches all results from the API without a server-side search filter
        # and performs a case-insensitive contains match on DisplayProperties client-side.
        # Use for APIs (e.g. PIMServices) that do not support partial-match search params.
        [Parameter(Mandatory = $false)] [switch]$ClientSideFilter
    )

    $response = $null
    try {
        $qParams = if ($ClientSideFilter) { @{} } else { @{ $SearchParam = $SearchTerm; limit = '25' } }
        $response = Invoke-CyberArkAPI -Token $Token -Method 'GET' `
            -Endpoint $Endpoint `
            -QueryParams $qParams `
            -IgnoreSSL:$IgnoreSSL
    } catch {
        Write-Host "    Search error: $_" -ForegroundColor Red
        return $null
    }

    if (-not $response -or -not $response.IsSuccess) {
        $errMsg = if ($response) { $response.ErrorMessage } else { '(no response)' }
        Write-Host "    Search failed: $errMsg" -ForegroundColor Red
        return $null
    }

    $items = @()
    if ($response.Data -and $response.Data.PSObject.Properties[$ResponseProperty]) {
        $items = @($response.Data.$ResponseProperty)
    }

    if ($ClientSideFilter -and $SearchTerm -and $items.Count -gt 0) {
        $lowerTerm = $SearchTerm.ToLower()
        $items = @($items | Where-Object {
            $item = $_
            $found = $false
            foreach ($p in $DisplayProperties) {
                if (-not $found -and $item.PSObject.Properties[$p] -and "$($item.$p)".ToLower().Contains($lowerTerm)) {
                    $found = $true
                }
            }
            $found
        })
    }

    if ($items.Count -eq 0) {
        Write-Host "    No ${EntityLabel}s found matching '$SearchTerm'." -ForegroundColor Yellow
        return $null
    }

    $displayCount = [Math]::Min($items.Count, 25)
    Write-Host ''
    Write-Host "    Found $($items.Count) ${EntityLabel}$(if ($items.Count -ne 1) { 's' }):" -ForegroundColor Cyan
    Write-Host ''

    for ($i = 0; $i -lt $displayCount; $i++) {
        $item = $items[$i]
        $parts = @(foreach ($prop in $DisplayProperties) {
            if ($item.PSObject.Properties[$prop] -and ($null -ne $item.$prop) -and ("$($item.$prop)" -ne '')) {
                "$($item.$prop)"
            }
        })
        Write-Host "    [$($i + 1)]  $($parts -join '  |  ')" -ForegroundColor White
    }

    Write-Host ''
    $sel = Read-MenuChoice -Prompt "Select $EntityLabel [1-$displayCount] or B to cancel"

    if ($sel -match '^\d+$') {
        $idx = [int]$sel - 1
        if ($idx -ge 0 -and $idx -lt $displayCount) {
            $item = $items[$idx]
            if ($item.PSObject.Properties[$IdProperty] -and ($null -ne $item.$IdProperty)) {
                return "$($item.$IdProperty)"
            }
        }
    }
    return $null
}

#endregion

#region --- currentProfile Directory ---

function Initialize-ProfileDirectory {
    param([string]$Path = $script:DefaultProfileDir)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $script:ProfileDir = $Path
}

function Get-ProfileJsonPath  { param([string]$Name) Join-Path $script:ProfileDir "$Name.json" }
function Get-ProfileTokenPath { param([string]$Name) Join-Path $script:ProfileDir "$Name.cred" }

#endregion

#region --- currentProfile CRUD ---

function Get-AllDriverProfiles {
    $jsonFiles = Get-ChildItem -LiteralPath $script:ProfileDir -Filter '*.json' -File -ErrorAction SilentlyContinue
    $selectedProfiles  = foreach ($f in $jsonFiles) {
        try {
            $p        = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            # Normalize: add any fields introduced after this profile was saved
            foreach ($field in @('SystemType', 'AppName', 'AuthMethod', 'Username', 'BaseURL', 'LogFolder', 'InputFolder', 'OutputFolder')) {
                $defaultVal = if ($field -eq 'AppName') { 'PasswordVault' } else { '' }
                if (-not $p.PSObject.Properties[$field]) {
                    $p | Add-Member -NotePropertyName $field -NotePropertyValue $defaultVal -Force
                }
            }
            foreach ($field in @('IgnoreSSL', 'WhatIfDefault')) {
                if (-not $p.PSObject.Properties[$field]) {
                    $p | Add-Member -NotePropertyName $field -NotePropertyValue $false -Force
                }
            }
            $xmlPath  = Get-ProfileTokenPath -Name $p.AuthTokenProfile
            $hasToken = Test-Path -LiteralPath $xmlPath

            $tokenStatus = 'No Token'
            $expiry      = $null
            $systemType  = ''
            $authMethod  = ''
            $baseURL     = ''

            if ($hasToken) {
                try {
                    $xml        = Import-Clixml -LiteralPath $xmlPath
                    $expiry     = $xml.Expiry
                    $systemType = $xml.SystemType
                    $authMethod = $xml.AuthMethod
                    $baseURL    = $xml.BaseURL
                    $tokenStatus = if ($expiry -and $expiry -lt (Get-Date).ToUniversalTime()) {
                        'Expired'
                    } else { 'Valid' }
                } catch {
                    $tokenStatus = 'Unreadable'
                }
            }

            # Profile's SystemType takes precedence; map legacy token values to display labels
            $displaySystemType = if ($p.SystemType) { $p.SystemType }
                                 elseif ($systemType -eq 'ISPSS')      { 'Privilege Cloud' }
                                 elseif ($systemType -eq 'SelfHosted') { 'Self-Hosted' }
                                 else                                   { $systemType }

            [PSCustomObject]@{
                ProfileName  = $p.ProfileName
                SystemType   = $displaySystemType
                AuthMethod   = if ($authMethod) { $authMethod } elseif ($p.AuthMethod) { $p.AuthMethod } else { '' }
                BaseURL      = $baseURL
                TokenStatus  = $tokenStatus
                Expiry       = $expiry
                LastUsed     = $p.LastUsed
                JsonPath     = $f.FullName
                currentProfile      = $p
            }
        } catch {
            Write-CyberArkLog -Message "Failed to read profile '$($f.Name)': $_" -Level 'WARN'
        }
    }
    return @($selectedProfiles | Sort-Object ProfileName)
}

function Read-DriverProfile {
    param([string]$Name)
    $path = Get-ProfileJsonPath -Name $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Save-DriverProfile {
    param([PSCustomObject]$currentProfile)
    $currentProfile.Modified = (Get-Date).ToUniversalTime().ToString('o')
    $path = Get-ProfileJsonPath -Name $currentProfile.ProfileName
    $currentProfile | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
}

function New-BlankProfile {
    param([string]$Name)
    return [PSCustomObject]@{
        ProfileName      = $Name
        AuthTokenProfile = $Name
        SystemType       = ''
        AppName          = 'PasswordVault'
        AuthMethod       = ''
        Username         = ''
        BaseURL          = ''
        LogFolder        = ''
        InputFolder      = ''
        OutputFolder     = ''
        IgnoreSSL        = $false
        WhatIfDefault    = $false
        LastUsed         = $null
        Created          = (Get-Date).ToUniversalTime().ToString('o')
        Modified         = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Remove-DriverProfile {
    param([string]$Name)
    $jsonPath = Get-ProfileJsonPath  -Name $Name
    $xmlPath  = Get-ProfileTokenPath -Name $Name
    if (Test-Path -LiteralPath $jsonPath) { Remove-Item -LiteralPath $jsonPath -Force }
    if (Test-Path -LiteralPath $xmlPath)  { Remove-Item -LiteralPath $xmlPath  -Force }
}

#endregion

#region --- currentProfile Display ---

function Show-ProfileList {
    param([PSCustomObject[]]$selectedProfiles, [string[]]$Breadcrumbs)
    Show-Header -Breadcrumbs $Breadcrumbs

    if (-not $selectedProfiles -or $selectedProfiles.Count -eq 0) {
        Write-Host '  No profiles found.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [N] New Profile    [Q] Quit' -ForegroundColor White
        return
    }

    # Column widths
    $numW  = 3
    $nameW = [Math]::Max(16, ($selectedProfiles | ForEach-Object { $_.ProfileName.Length } | Measure-Object -Maximum).Maximum + 2)
    $sysW  = 15
    $authW = 20
    $useW  = 17
    $statW = 10

    $hdr = "  {0,-$numW}  {1,-$nameW}  {2,-$sysW}  {3,-$authW}  {4,-$useW}  {5,-$statW}" -f '#', 'Profile Name', 'System', 'Auth Method', 'Last Used', 'Token'
    Write-Host $hdr -ForegroundColor DarkCyan
    Write-Host ('  ' + ('-' * ($hdr.Length - 2))) -ForegroundColor DarkGray

    $i = 1
    foreach ($p in $selectedProfiles) {
        $lastUsed = if ($p.LastUsed) {
            try { ([datetime]$p.LastUsed).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { '?' }
        } else { 'Never' }

        $statusColor = switch ($p.TokenStatus) {
            'Valid'       { 'Green' }
            'Expired'     { 'Yellow' }
            'Unreadable'  { 'Red' }
            default       { 'DarkGray' }
        }

        $row = "  {0,-$numW}  {1,-$nameW}  {2,-$sysW}  {3,-$authW}  {4,-$useW}" -f $i, $p.ProfileName, $p.SystemType, $p.AuthMethod, $lastUsed
        Write-Host $row -NoNewline
        Write-Host ("  {0,-$statW}" -f $p.TokenStatus) -ForegroundColor $statusColor
        $i++
    }

    Write-Host ''
    Show-Divider
    Write-Host '  Enter a number to view details, or:' -ForegroundColor DarkGray
    Write-Host '  [N] New Profile    [Q] Quit' -ForegroundColor White
}

function Show-ProfileDetail {
    param([PSCustomObject]$Summary, [string[]]$Breadcrumbs)
    Show-Header -Breadcrumbs $Breadcrumbs

    $p = $Summary.currentProfile

    function Field([string]$label, [string]$value, [string]$color = 'Gray') {
        Write-Host ("    {0,-22}" -f $label) -NoNewline -ForegroundColor DarkGray
        Write-Host $value -ForegroundColor $color
    }

    Write-Host '  Profile Settings' -ForegroundColor White
    Show-Divider
    Field 'Profile Name'    $p.ProfileName    'Cyan'
    Field 'Auth Profile'    $p.AuthTokenProfile
    Field 'System Type'     $(if ($p.SystemType)  { $p.SystemType }  else { '(Not Set)' }) $(if ($p.SystemType) { 'Cyan' } else { 'Yellow' })
    Field 'Auth Method'     $(if ($p.AuthMethod)  { $p.AuthMethod }  else { '(Not Set)' }) $(if ($p.AuthMethod) { 'Cyan' } else { 'Yellow' })
    Field 'Username'        $(if ($p.Username)     { $p.Username }   else { '(Not Set)' }) $(if ($p.Username)   { 'Cyan' } else { 'Yellow' })
    Field 'Base URL'        $(if ($p.BaseURL)      { $p.BaseURL } else { '(Not Set)' })
    Field 'Application'     $(if ($p.AppName)      { $p.AppName } else { 'PasswordVault' })
    Field 'Log Folder'      $(if ($p.LogFolder)    { $p.LogFolder    } else { '(launch directory)' })
    Field 'Input Folder'    $(if ($p.InputFolder)  { $p.InputFolder  } else { '(launch directory)' })
    Field 'Output Folder'   $(if ($p.OutputFolder) { $p.OutputFolder } else { '(launch directory)' })
    Field 'Ignore SSL'      $p.IgnoreSSL     $(if ($p.IgnoreSSL)     { 'Yellow' } else { 'Gray' })
    Field 'WhatIf Default'  $p.WhatIfDefault $(if ($p.WhatIfDefault) { 'Yellow' } else { 'Gray' })
    $created  = try { ([datetime]$p.Created).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }  catch { $p.Created }
    $modified = try { ([datetime]$p.Modified).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { $p.Modified }
    Field 'Created'         $created
    Field 'Modified'        $modified

    Write-Host ''
    Write-Host '  Authentication Token' -ForegroundColor White
    Show-Divider

    if ($Summary.TokenStatus -eq 'No Token') {
        Write-Host '    No token file found.' -ForegroundColor DarkGray
    } else {
        $expiryStr = if ($Summary.Expiry) {
            $local = try { ([datetime]$Summary.Expiry).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { '?' }
            "$local ($($Summary.TokenStatus))"
        } else { 'Unknown' }

        $expiryColor = switch ($Summary.TokenStatus) {
            'Valid'      { 'Green' }
            'Expired'    { 'Yellow' }
            default      { 'Red' }
        }

        Field 'System Type'     $Summary.SystemType
        Field 'Auth Method'     $Summary.AuthMethod
        Field 'Base URL'        $Summary.BaseURL
        Field 'Token Expiry'    $expiryStr $expiryColor
        Field 'Token Value'     '***'
    }

    Write-Host ''
    Show-Divider
    Write-Host '  [C] Continue    [E] Edit    [P] Copy    [D] Delete    [T] Test Connection    [L] Log Out    [B] Back' -ForegroundColor White
}

#endregion

#region --- currentProfile Edit Flow ---

function Invoke-ProfileEditFlow {
    param(
        [PSCustomObject]$currentProfile,
        [string[]]$Breadcrumbs,
        [switch]$IsNew
    )

    Show-Header -Breadcrumbs $Breadcrumbs
    Write-Host '  Profile Settings' -ForegroundColor White
    Write-Host '  (Press Enter to keep the current value)' -ForegroundColor DarkGray
    Write-Host ''

    # currentProfile Name - only editable on new profiles; for copy the name is already set
    if ($IsNew) {
        while ($true) {
            $name = Show-FieldPrompt -Label 'Profile Name' -Default $currentProfile.ProfileName -Required `
                -Description 'Unique name for this profile (e.g. Development, Production)'
            if (-not $name) {
                Write-Host '    Profile Name is required.' -ForegroundColor Red
                continue
            }
            $existingPath = Get-ProfileJsonPath -Name $name
            if ((Test-Path -LiteralPath $existingPath) -and $name -ne $currentProfile.ProfileName) {
                Write-Host "    A profile named '$name' already exists." -ForegroundColor Red
                continue
            }
            $currentProfile.ProfileName      = $name
            $currentProfile.AuthTokenProfile = $name
            break
        }
    } else {
        Write-Host "    Profile Name     : $($currentProfile.ProfileName)  (not editable)" -ForegroundColor DarkGray
    }

    Write-Host ''
    # System Type - numbered choice so the user only has to type one key
    $sysTypeMap = @{ '1' = 'Privilege Cloud'; '2' = 'Self-Hosted' }
    Write-Host '  System Type:' -ForegroundColor White
    Write-Host '    [1] Privilege Cloud   - SaaS / ISPSS  (*.privilegecloud.cyberark.cloud)' -ForegroundColor Gray
    Write-Host '    [2] Self-Hosted       - On-premises PVWA' -ForegroundColor Gray
    if ($currentProfile.SystemType) {
        Write-Host ("    Current: $($currentProfile.SystemType)") -ForegroundColor DarkCyan
    }
    $sysChoice = ''
    do {
        $sysChoice = Read-MenuChoice -Prompt '1 / 2'
        if ($sysChoice -notin @('1', '2')) {
            Write-Host '    Invalid - enter 1 or 2.' -ForegroundColor Red
        }
    } while ($sysChoice -notin @('1', '2'))
    $currentProfile.SystemType = $sysTypeMap[$sysChoice]

    # Auth Method - numbered choice, depends on SystemType
    Write-Host ''
    $ispssAuthMethods      = @('ClientCredentials', 'Interactive', 'SSO')
    $selfHostedAuthMethods = @('CyberArk', 'LDAP', 'RADIUS', 'SAML', 'OIDC', 'Shared', 'PKI', 'PKIPN')
    $authMethods = if ($currentProfile.SystemType -eq 'Privilege Cloud') { $ispssAuthMethods } else { $selfHostedAuthMethods }
    Write-Host '  Auth Method:' -ForegroundColor White
    for ($i = 0; $i -lt $authMethods.Count; $i++) {
        Write-Host ("    [$($i+1)] $($authMethods[$i])") -ForegroundColor Gray
    }
    if ($currentProfile.AuthMethod -and $currentProfile.AuthMethod -in $authMethods) {
        Write-Host ("    Current: $($currentProfile.AuthMethod)") -ForegroundColor DarkCyan
    }
    $methodChoice = ''
    do {
        $methodChoice = Read-MenuChoice -Prompt "1 - $($authMethods.Count)"
        $methodIdx = 0
        $methodValid = [int]::TryParse($methodChoice, [ref]$methodIdx) -and $methodIdx -ge 1 -and $methodIdx -le $authMethods.Count
        if (-not $methodValid) {
            Write-Host "    Invalid - enter 1 through $($authMethods.Count)." -ForegroundColor Red
        }
    } while (-not $methodValid)
    $currentProfile.AuthMethod = $authMethods[$methodIdx - 1]

    # Base URL - prompt depends on SystemType
    Write-Host ''
    $pcloudTemplate = 'https://{0}.privilegecloud.cyberark.cloud'
    switch ($currentProfile.SystemType) {
        'Privilege Cloud' {
            $subdomain = ''
            if ($currentProfile.BaseURL -match '^https://(.+)\.privilegecloud\.cyberark\.cloud/?$') {
                $subdomain = $Matches[1]
            }
            $subdomain = Show-FieldPrompt -Label 'Privilege Cloud Subdomain' -Default $subdomain `
                -Description 'Subdomain of your tenant URL. For acme.privilegecloud.cyberark.cloud, enter: acme'
            if ($subdomain) {
                $currentProfile.BaseURL = $pcloudTemplate -f $subdomain.Trim()
            }
        }
        'Self-Hosted' {
            $currentProfile.BaseURL = Show-FieldPrompt -Label 'PVWA Base URL' -Default $currentProfile.BaseURL `
                -Description 'Base URL of your PVWA server. Example: https://pvwa.company.com'
            if ($currentProfile.BaseURL) {
                $currentProfile.BaseURL = $currentProfile.BaseURL.TrimEnd('/')
            }
        }
    }

    Write-Host ''
    $appNameDefault = if ($currentProfile.AppName) { $currentProfile.AppName } else { 'PasswordVault' }
    $enteredAppName = Show-FieldPrompt -Label 'Application Name' -Default $appNameDefault `
        -Description 'CyberArk application name in the URL path (e.g. PasswordVault). Joined with Base URL for API calls.'
    $currentProfile.AppName = if ($enteredAppName) { $enteredAppName } else { 'PasswordVault' }

    $currentProfile.Username = Show-FieldPrompt -Label 'Username' -Default $currentProfile.Username `
        -Description 'Default username pre-filled in the credential prompt at login. Leave blank to always be prompted.'

    $currentProfile.LogFolder = Show-FieldPrompt -Label 'Log Folder' -Default $currentProfile.LogFolder `
        -Description 'Absolute path for log files. Leave blank to use the script launch directory.'

    $currentProfile.InputFolder = Show-FieldPrompt -Label 'Input Folder' -Default $currentProfile.InputFolder `
        -Description 'Default folder for CSV input file pickers. Leave blank for launch directory.'

    $currentProfile.OutputFolder = Show-FieldPrompt -Label 'Output Folder' -Default $currentProfile.OutputFolder `
        -Description 'Destination for output CSV files. Leave blank for launch directory.'

    Write-Host ''
    $sslStr = Show-FieldPrompt -Label 'Ignore SSL Errors' -Default $(if ($currentProfile.IgnoreSSL) { 'Y' } else { 'N' }) `
        -Description 'Bypass SSL certificate validation? (Y/N) - Use only for lab/dev environments.'
    $currentProfile.IgnoreSSL = $sslStr -match '^[Yy]$'

    $wiStr = Show-FieldPrompt -Label 'WhatIf Default' -Default $(if ($currentProfile.WhatIfDefault) { 'Y' } else { 'N' }) `
        -Description 'Default to WhatIf mode for this profile? (Y/N) - Recommended for production.'
    $currentProfile.WhatIfDefault = $wiStr -match '^[Yy]$'

    Write-Host ''
    Save-DriverProfile -currentProfile $currentProfile
    Write-Host "  Profile '$($currentProfile.ProfileName)' saved." -ForegroundColor Green

    if ($currentProfile.IgnoreSSL) {
        Write-CyberArkLog -Message "Profile '$($currentProfile.ProfileName)' has IgnoreSSL enabled - use only in lab/dev." -Level 'WARN'
    }

    return $currentProfile
}

#endregion

#region --- currentProfile Test Connection ---

function Invoke-ProfileTestConnection {
    param([PSCustomObject]$Summary, [string[]]$Breadcrumbs)
    Show-Header -Breadcrumbs $Breadcrumbs
    Write-Host '  Test Connection' -ForegroundColor White
    Write-Host ''

    $tokenPath = Get-ProfileTokenPath -Name $Summary.currentProfile.AuthTokenProfile

    # If a saved token exists, show its status first
    if (Test-Path -LiteralPath $tokenPath) {
        try {
            $existing = Import-AuthToken -Path $tokenPath -IgnoreExpiry
            if ($existing -and $existing.Token) {
                $isExpired = $existing.Expiry -lt [DateTime]::UtcNow
                $statusLabel = if ($isExpired) { 'Expired' } else { 'Valid' }
                $statusColor = if ($isExpired) { 'Yellow'  } else { 'Green'  }
                Write-Host "  Saved token: $statusLabel" -ForegroundColor $statusColor
                Write-Host "    System  : $($existing.SystemType)"  -ForegroundColor Gray
                Write-Host "    Method  : $($existing.AuthMethod)"  -ForegroundColor Gray
                Write-Host "    Base URL: $($existing.BaseURL)"     -ForegroundColor Gray
                Write-Host "    Expires : $($existing.Expiry.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Gray
                Write-Host ''
                if (-not $isExpired) {
                    if ($existing.SystemType -eq 'ISPSS') {
                        Write-Host '  Privilege Cloud: no server validation endpoint.' -ForegroundColor DarkGray
                        Write-Host '  Token accepted based on local expiry.' -ForegroundColor DarkGray
                        Write-Host ''
                        Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
                        Read-Host | Out-Null
                        return
                    }
                    Write-Host '  Verifying with server...' -ForegroundColor DarkGray
                    $valResp = Invoke-TokenValidate -Token $existing -IgnoreSSL:$Summary.currentProfile.IgnoreSSL
                    if ($valResp -and $valResp.IsSuccess) {
                        $logonUser = if ($valResp.Data -and $valResp.Data.PSObject.Properties['username']) {
                            " - logged on as $($valResp.Data.username)"
                        } else { '' }
                        Write-Host "  Token verified$logonUser." -ForegroundColor Green
                        Write-Host ''
                        Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
                        Read-Host | Out-Null
                        return
                    } elseif ($valResp -and $valResp.StatusCode -eq 401) {
                        Write-Host '  Server rejected token (401). Clearing saved token.' -ForegroundColor Red
                        Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
                        Write-Host '  Re-authenticating...' -ForegroundColor Yellow
                        Write-Host ''
                        # Fall through to the re-auth block below
                    } else {
                        $errDetail = if ($valResp) { " ($($valResp.StatusCode): $($valResp.ErrorMessage))" } else { ' (server unreachable)' }
                        Write-Host "  Could not verify with server$errDetail." -ForegroundColor Yellow
                        Write-Host '  Proceeding with locally-valid token.' -ForegroundColor DarkGray
                        Write-Host ''
                        Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
                        Read-Host | Out-Null
                        return
                    }
                }
                Write-Host '  Token is expired. Re-authenticating...' -ForegroundColor Yellow
                Write-Host ''
            }
        } catch {
            Write-Host '  Saved token could not be read. Re-authenticating...' -ForegroundColor Yellow
            Write-Host ''
        }
    } else {
        Write-Host '  No saved token found. A new authentication is required.' -ForegroundColor Yellow
        Write-Host ''
    }

    # Token missing or expired - authenticate
    Write-Host '  Calling Get-AuthToken...' -ForegroundColor DarkGray
    Write-Host ''

    try {
        $params = @{ IgnoreSSL = $Summary.currentProfile.IgnoreSSL }
        if (Test-Path -LiteralPath $tokenPath) {
            $saved = Import-AuthToken -Path $tokenPath -IgnoreExpiry
            if ($saved) {
                $params['SystemType']  = $saved.SystemType
                $params['AuthMethod']  = $saved.AuthMethod
                $params['PVWAUrl']     = if ($saved.SystemType -eq 'SelfHosted') { $saved.BaseURL } else { $null }
                $params['PCloudSubdomain'] = if ($saved.SystemType -eq 'ISPSS' -and $saved.BaseURL -match 'https://([^.]+)\.') {
                    $Matches[1]
                } else { $null }
            }
        }
        $token = Get-AuthToken @params
        if ($token -and $token.Token) {
            Write-Host '  Connection successful.' -ForegroundColor Green
            Write-Host "    System  : $($token.SystemType)"   -ForegroundColor Gray
            Write-Host "    Method  : $($token.AuthMethod)"   -ForegroundColor Gray
            Write-Host "    Base URL: $($token.BaseURL)"      -ForegroundColor Gray
            Write-Host "    Expires : $($token.Expiry.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Gray

            if (Confirm-Action 'Save this token to the profile?') {
                $null = Save-AuthToken -TokenObject $token -ProfileName $Summary.currentProfile.AuthTokenProfile
                Write-Host '  Token saved.' -ForegroundColor Green
            }
        } else {
            Write-Host '  Authentication returned no token.' -ForegroundColor Red
        }
    } catch {
        Write-Host "  Authentication failed: $_" -ForegroundColor Red
        Write-CyberArkLog -Message "Test connection failed for profile '$($Summary.currentProfile.ProfileName)': $_" -Level 'WARN'
    }

    Write-Host ''
    Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
    Read-Host | Out-Null
}

#endregion

#region --- Main currentProfile Management Loop ---

function Invoke-ProfileManagementLoop {
    param([string]$DefaultProfileName = '')

    Initialize-ProfileDirectory

    $breadcrumbRoot = @('Profile Selection')
    $selected       = $null   # initialize so StrictMode doesn't throw if a branch skips setting it

    while ($true) {

        # --- currentProfile List ---
        $selectedProfiles = @(Get-AllDriverProfiles)
        Show-ProfileList -selectedProfiles $selectedProfiles -Breadcrumbs $breadcrumbRoot

        if (-not $selectedProfiles -or $selectedProfiles.Count -eq 0) {
            $choice = Read-MenuChoice -Prompt '[N] New    [Q] Quit'
        } else {
            $defaultHint = if ($DefaultProfileName) { " (default: $DefaultProfileName)" } else { ' (default: 1)' }
            $choice = Read-MenuChoice -Prompt "Number / [N]ew / [Q]uit$defaultHint"
            if (-not $choice) {
                $choice = if ($DefaultProfileName) { $DefaultProfileName } else { '1' }
            }
        }

        switch -Regex ($choice.ToUpper()) {

            '^Q$' {
                Write-Host "`n  Goodbye.`n" -ForegroundColor DarkGray
                return $null   # Signal: exit
            }

            '^N$' {
                # --- Create new profile ---
                $blank = New-BlankProfile -Name ''
                $edited = Invoke-ProfileEditFlow -currentProfile $blank -Breadcrumbs ($breadcrumbRoot + @('New Profile')) -IsNew
                if ($edited) { $DefaultProfileName = $edited.ProfileName }
                continue
            }

            '^\d+$' {
                $idx = [int]$choice - 1
                if ($idx -lt 0 -or $idx -ge $selectedProfiles.Count) {
                    Write-Host '  Invalid selection.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    continue
                }
                $selected = $selectedProfiles[$idx]
                $DefaultProfileName = $selected.ProfileName
            }

            default {
                # Try matching by profile name (for Restart flow passing a name)
                $byName = $selectedProfiles | Where-Object { $_.ProfileName -ieq $choice }
                if ($byName) {
                    $selected = $byName[0]
                    $DefaultProfileName = $selected.ProfileName
                } else {
                    Write-Host '  Invalid input.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    continue
                }
            }
        }

        # --- currentProfile Detail Loop ---
        if (-not $selected) { continue }   # guard: switch branch skipped assignment (StrictMode safety)
        $selectedProfileName = $selected.ProfileName
        $detailCrumbs        = $breadcrumbRoot + @($selectedProfileName)

        while ($true) {
            $selected = @(Get-AllDriverProfiles) | Where-Object { $_.ProfileName -eq $selectedProfileName }
            if (-not $selected) { break }   # currentProfile was deleted

            Show-ProfileDetail -Summary $selected -Breadcrumbs $detailCrumbs

            $missingSystemType = [string]::IsNullOrWhiteSpace($selected.currentProfile.SystemType)
            $missingBaseURL    = [string]::IsNullOrWhiteSpace($selected.currentProfile.BaseURL)
            $isIncomplete      = $missingSystemType -or $missingBaseURL
            if ($isIncomplete) {
                $missingFields = @()
                if ($missingSystemType) { $missingFields += 'System Type' }
                if ($missingBaseURL)    { $missingFields += 'Base URL' }
                Write-Host ''
                Write-Host ("  WARNING: Profile incomplete - missing: $($missingFields -join ', ').") -ForegroundColor Yellow
                Write-Host '  Choose E to edit it or D to delete this profile.' -ForegroundColor Yellow
            }

            $action = Read-MenuChoice -Prompt 'C / E / P / D / T / L / B / Q (default: C)'
            if (-not $action) { $action = 'C' }

            switch ($action.ToUpper()) {

                'C' {
                    if ($isIncomplete) {
                        Write-Host '  Cannot connect: Base URL is required. Use [E]dit to add it first.' -ForegroundColor Red
                        Start-Sleep -Seconds 2
                        break
                    }
                    # Continue to session - authenticate and return token
                    $selectedProfile = $selected.currentProfile
                    $selectedProfile.LastUsed = (Get-Date).ToUniversalTime().ToString('o')
                    Save-DriverProfile -currentProfile $selectedProfile

                    $xmlPath = Get-ProfileTokenPath -Name $selectedProfile.AuthTokenProfile
                    $token   = $null

                    if (Test-Path -LiteralPath $xmlPath) {
                        try {
                            if ($selected.TokenStatus -eq 'Valid') {
                                # Token known-good - load directly, no refresh needed
                                $token = Import-AuthToken -Path $xmlPath
                            } elseif ($selected.TokenStatus -eq 'Expired') {
                                # Attempt silent refresh (succeeds for ClientCredentials; falls through for others)
                                $token = Import-AuthToken -Path $xmlPath -AutoRefresh
                            }
                            # No Token / Unreadable: skip Import-AuthToken, go straight to Get-AuthToken
                        } catch {
                            Write-CyberArkLog -Message "Failed to load saved token: $_" -Level 'WARN'
                        }

                        # Validate the loaded token against the server before trusting it
                        if ($token) {
                            if ($token.SystemType -eq 'ISPSS') {
                                Write-Host '  Privilege Cloud: token accepted based on local expiry.' -ForegroundColor DarkGray
                            } else {
                                Write-Host '  Validating token...' -ForegroundColor DarkGray
                                $valResp = Invoke-TokenValidate -Token $token -IgnoreSSL:$selectedProfile.IgnoreSSL
                                if ($valResp -and $valResp.IsSuccess) {
                                    $logonUser = if ($valResp.Data -and $valResp.Data.PSObject.Properties['username']) {
                                        " (as $($valResp.Data.username))"
                                    } else { '' }
                                    Write-Host "  Token verified$logonUser." -ForegroundColor Green
                                } elseif ($valResp -and $valResp.StatusCode -eq 401) {
                                    Write-Host '  Server rejected saved token (401). Please re-authenticate.' -ForegroundColor Yellow
                                    Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
                                    $token = $null
                                }
                                # Non-401 errors (network unreachable, etc.) - proceed with the loaded token
                            }
                        }
                    }

                    if (-not $token) {
                        Show-Header -Breadcrumbs ($detailCrumbs + @('Authenticate'))
                        $authStatusMsg = switch ($selected.TokenStatus) {
                            'Expired'    { 'Saved token has expired. Please re-authenticate.' }
                            'Unreadable' { 'Could not read saved token. Please re-authenticate.' }
                            default      { 'No saved token found. Please authenticate.' }
                        }
                        Write-Host "  $authStatusMsg" -ForegroundColor Yellow
                        Write-Host ''
                        try {
                            $authParams = @{ IgnoreSSL = $selectedProfile.IgnoreSSL }
                            if ($selectedProfile.AuthMethod) { $authParams['AuthMethod'] = $selectedProfile.AuthMethod }
                            if ($selectedProfile.Username)   { $authParams['Username']   = $selectedProfile.Username }
                            $appName = if ($selectedProfile.AppName) { $selectedProfile.AppName.Trim('/') } else { 'PasswordVault' }
                            # Map profile SystemType to the auth script's expected values
                            if ($selectedProfile.SystemType -eq 'Privilege Cloud') {
                                $authParams['SystemType'] = 'ISPSS'
                                if ($selectedProfile.BaseURL -match '^https://(.+)\.privilegecloud\.cyberark\.cloud') {
                                    $authParams['PCloudSubdomain'] = $Matches[1]
                                }
                            } elseif ($selectedProfile.SystemType -eq 'Self-Hosted') {
                                $authParams['SystemType'] = 'SelfHosted'
                                if ($selectedProfile.BaseURL) {
                                    $authParams['PVWAUrl'] = "$($selectedProfile.BaseURL.TrimEnd('/'))/$appName"
                                }
                            }
                            $token = Get-AuthToken @authParams
                            # For Privilege Cloud, patch token.BaseURL to include AppName for subsequent API calls
                            if ($token -and $selectedProfile.SystemType -eq 'Privilege Cloud' -and $token.BaseURL) {
                                $token.BaseURL = "$($token.BaseURL.TrimEnd('/'))/$appName"
                            }
                            # If user entered credentials, save username back to profile for next-login pre-fill
                            if ($token -and $token._RefreshContext -and $token._RefreshContext['Credential']) {
                                $enteredUser = $token._RefreshContext['Credential'].UserName
                                if ($enteredUser -and $enteredUser -ne $selectedProfile.Username) {
                                    $selectedProfile.Username = $enteredUser
                                    Save-DriverProfile -currentProfile $selectedProfile
                                }
                            }
                        } catch {
                            $urlInfo = if ($selectedProfile.SystemType -eq 'Self-Hosted' -and $selectedProfile.BaseURL) {
                                $an = if ($selectedProfile.AppName) { $selectedProfile.AppName.Trim('/') } else { 'PasswordVault' }
                                " [URL: $($selectedProfile.BaseURL.TrimEnd('/'))/$an]"
                            } else { '' }
                            Write-Host "  Authentication failed$($urlInfo): $_" -ForegroundColor Red
                            Write-CyberArkLog -Message "Authentication failed for profile '$($selectedProfile.ProfileName)'$($urlInfo): $_" -Level 'ERROR'
                            Write-Host '  Press Enter to return to profile selection.' -ForegroundColor DarkGray
                            Read-Host | Out-Null
                            break
                        }
                    }

                    if ($token -and $token.Token) {
                        # Persist the (possibly refreshed) token
                        try {
                            $null = Save-AuthToken -TokenObject $token -ProfileName $selectedProfile.AuthTokenProfile
                        } catch {
                            Write-CyberArkLog -Message "Could not save refreshed token: $_" -Level 'WARN'
                        }

                        # Display token details as informational output before entering session
                        Write-Host ''
                        $tokenUsername = ''
                        if ($token.PSObject.Properties['_RefreshContext'] -and $token._RefreshContext) {
                            $rc = $token._RefreshContext
                            if ($rc.PSObject.Properties['Credential'] -and $rc.Credential) {
                                $tokenUsername = $rc.Credential.UserName
                            }
                        }
                        if (-not $tokenUsername -and $selectedProfile.Username) {
                            $tokenUsername = $selectedProfile.Username
                        }
                        if ($tokenUsername) {
                            Write-Host ("    Signed in as : $tokenUsername") -ForegroundColor Cyan
                        }
                        $sysLabel = switch ($token.SystemType) {
                            'ISPSS'      { 'Privilege Cloud' }
                            'SelfHosted' { 'Self-Hosted' }
                            default      { if ($token.PSObject.Properties['SystemType']) { $token.SystemType } else { '' } }
                        }
                        if ($sysLabel) { Write-Host ("    System       : $sysLabel") -ForegroundColor Cyan }
                        if ($token.PSObject.Properties['AuthMethod'] -and $token.AuthMethod) {
                            Write-Host ("    Auth Method  : $($token.AuthMethod)") -ForegroundColor Cyan
                        }
                        if ($token.PSObject.Properties['BaseURL'] -and $token.BaseURL) {
                            Write-Host ("    Base URL     : $($token.BaseURL)") -ForegroundColor Cyan
                        }
                        if ($token.PSObject.Properties['Expiry'] -and $token.Expiry) {
                            $expiryStr = try {
                                ([datetime]$token.Expiry).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
                            } catch { "$($token.Expiry)" }
                            Write-Host ("    Token Expiry : $expiryStr") -ForegroundColor Cyan
                        }
                        Write-Host ''

                        $script:SessionToken  = $token
                        $script:ActiveProfile = $selectedProfile
                        $script:WhatIfMode    = $selectedProfile.WhatIfDefault -or $script:WhatIfMode

                        # Return the profile name - caller starts the session loop
                        return $selectedProfile.ProfileName
                    }

                    Write-Host '  Authentication returned no token.' -ForegroundColor Red
                    Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
                    Read-Host | Out-Null
                }

                'E' {
                    # Edit profile
                    Invoke-ProfileEditFlow -currentProfile $selected.currentProfile `
                        -Breadcrumbs ($detailCrumbs + @('Edit'))
                }

                'P' {
                    # Copy profile - prompt for new name first
                    Show-Header -Breadcrumbs ($detailCrumbs + @('Copy'))
                    Write-Host '  Copy Profile' -ForegroundColor White
                    Write-Host ''
                    $newName = ''
                    while (-not $newName) {
                        $newName = Show-FieldPrompt -Label 'New Profile Name' -Required `
                            -Description 'Name for the copied profile.'
                        if (-not $newName) {
                            Write-Host '    Name is required.' -ForegroundColor Red
                        } elseif (Test-Path -LiteralPath (Get-ProfileJsonPath -Name $newName)) {
                            Write-Host "    A profile named '$newName' already exists." -ForegroundColor Red
                            $newName = ''
                        }
                    }
                    # Clone the profile object and give it the new name
                    $copy = $selected.currentProfile | ConvertTo-Json -Depth 5 | ConvertFrom-Json
                    $copy.ProfileName      = $newName
                    $copy.AuthTokenProfile = $newName
                    $copy.Created          = (Get-Date).ToUniversalTime().ToString('o')
                    $copy.LastUsed         = $null
                    # Save draft first so edit flow can check for existing file
                    Save-DriverProfile -currentProfile $copy
                    Invoke-ProfileEditFlow -currentProfile $copy -Breadcrumbs ($detailCrumbs + @("Copy to $newName"))
                    $DefaultProfileName = $newName
                }

                'D' {
                    # Delete profile
                    if (Confirm-Action "Delete profile '$($selected.ProfileName)' and its token file? This cannot be undone.") {
                        Remove-DriverProfile -Name $selected.ProfileName
                        Write-CyberArkLog -Message "Profile '$($selected.ProfileName)' deleted." -Level 'INFO'
                        Write-Host "  Profile deleted." -ForegroundColor Green
                        Start-Sleep -Seconds 1
                        break   # Back to profile list
                    }
                }

                'T' {
                    # Test connection
                    Invoke-ProfileTestConnection -Summary $selected `
                        -Breadcrumbs ($detailCrumbs + @('Test Connection'))
                }

                'L' {
                    # Log out - call server logoff and delete local token file
                    if ($selected.TokenStatus -notin @('Valid', 'Expired')) {
                        Write-Host '  No saved session token to log out.' -ForegroundColor DarkGray
                        Start-Sleep -Seconds 1
                    } else {
                        if (Confirm-Action "Log out '$($selected.ProfileName)' - end server session and delete saved token?") {
                            $tokenPath   = Get-ProfileTokenPath -Name $selected.currentProfile.AuthTokenProfile
                            $logoutToken = $null
                            try { $logoutToken = Import-AuthToken -Path $tokenPath } catch {}
                            if ($logoutToken -and $logoutToken.SystemType -eq 'SelfHosted') {
                                Write-Host '  Ending server session...' -ForegroundColor DarkGray
                                try {
                                    Invoke-CyberArkAPI -Token $logoutToken -Method 'POST' `
                                        -Endpoint '/API/auth/Logoff' `
                                        -IgnoreSSL:$selected.currentProfile.IgnoreSSL | Out-Null
                                } catch {
                                    Write-CyberArkLog -Message "Logoff request failed: $_" -Level 'WARN'
                                }
                            }
                            Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
                            Write-CyberArkLog -Message "Logged out profile '$($selected.ProfileName)'. Token cleared." -Level 'INFO'
                            Write-Host '  Logged out. Token cleared.' -ForegroundColor Green
                            Start-Sleep -Seconds 1
                        }
                    }
                }

                { $_ -match '^B\d*$' } {
                    # B# navigation - B = back 1, B2 = back 2, etc.
                    $levels = if ($_ -eq 'B') { 1 } else { [int]($_ -replace '^B', '') }
                    if ($levels -ge 1) { break }   # Back to profile list
                }

                'Q' {
                    if ($selected.TokenStatus -eq 'Valid') {
                        if (Confirm-Action "Valid saved token for '$($selected.ProfileName)' exists. Clear it before quitting?") {
                            $tokenPath = Get-ProfileTokenPath -Name $selected.currentProfile.AuthTokenProfile
                            Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
                            Write-CyberArkLog -Message "Token cleared for '$($selected.ProfileName)' on quit." -Level 'INFO'
                            Write-Host '  Token cleared.' -ForegroundColor Green
                            Start-Sleep -Seconds 1
                        }
                    }
                    return $null
                }

                default {
                    Write-Host '  Invalid option.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                }
            }

            # If we broke out of the inner switch (Delete or Back), exit detail loop
            if ($action.ToUpper() -in 'D' -or $action.ToUpper() -match '^B\d*$') { break }
        }

    }   # while profile list loop
}

#endregion

#region --- Module Discovery ---

$script:LoadedModules    = @()
$script:LastActivityTime = $null

function Import-APIModules {
    $script:LoadedModules = @()
    if (-not (Test-Path -LiteralPath $script:APIModulesPath)) {
        Write-CyberArkLog -Message "APIModules folder not found: $($script:APIModulesPath)" -Level 'WARN'
        return
    }

    $files = Get-ChildItem -LiteralPath $script:APIModulesPath -Filter '*.ps1' -Recurse -File |
             Sort-Object { $_.Directory.Name }, Name

    $num = 1
    foreach ($file in $files) {
        try {
            $ModuleMeta = $null
            . $file.FullName

            if (-not $ModuleMeta) { continue }
            if ($ModuleMeta.SupportedSystems -notcontains $script:SessionToken.SystemType) { continue }

            $script:LoadedModules += [PSCustomObject]@{
                Number   = $num
                Meta     = $ModuleMeta
                FilePath = $file.FullName
            }
            $num++
            Write-CyberArkLog -Message "Loaded module: $($ModuleMeta.Name) v$($ModuleMeta.Version)" -Level 'DEBUG'
        } catch {
            $loadErr = "$_"
            Write-Host "  [Module Load Error] $($file.Name): $loadErr" -ForegroundColor Red
            Write-CyberArkLog -Message "Failed to load module '$($file.Name)': $loadErr" -Level 'WARN'
            $script:LoadedModules += [PSCustomObject]@{
                Number    = $num
                Meta      = @{
                    Name             = $file.BaseName
                    Category         = 'Errors'
                    Action           = 'LoadFailed'
                    Description      = $loadErr
                    SupportedSystems = @('ISPSS', 'SelfHosted')
                    SupportsWhatIf   = $false
                    AcceptsInputFile = $false
                    ProducesOutput   = $false
                    HasCustomInput   = $false
                    Priority         = 999
                }
                FilePath  = $file.FullName
                Failed    = $true
                FailError = $loadErr
            }
            $num++
        }
    }

    Write-CyberArkLog -Message "Module discovery complete: $($script:LoadedModules.Count) module(s) for $($script:SessionToken.SystemType)." -Level 'INFO'
}

#endregion

#region --- Token Lifecycle ---

function Get-TokenRemainingMinutes {
    if (-not $script:SessionToken -or -not $script:SessionToken.Expiry) { return 0 }
    return ($script:SessionToken.Expiry - (Get-Date).ToUniversalTime()).TotalMinutes
}

function Test-TokenExpiry {
    $remaining = Get-TokenRemainingMinutes
    if ($remaining -le 0)                         { return 'Expired' }
    if ($remaining -le $script:TokenExpiryWarnMin) { return 'Warning' }
    return 'Valid'
}

function Invoke-TokenRefresh {
    $status = Test-TokenExpiry
    if ($status -eq 'Valid') { return $true }

    $method = $script:SessionToken.AuthMethod
    $type   = $script:SessionToken.SystemType

    # ISPSS ClientCredentials - silent refresh via refresh_token grant
    if ($type -eq 'ISPSS' -and $method -eq 'ClientCredentials') {
        Write-CyberArkLog -Message 'Silently refreshing ISPSS ClientCredentials token.' -Level 'INFO'
        try {
            $refreshed = Get-AuthToken -TokenToRefresh $script:SessionToken `
                -IgnoreSSL:$script:ActiveProfile.IgnoreSSL
            if ($refreshed -and $refreshed.Token) {
                $script:SessionToken = $refreshed
                $null = Save-AuthToken -TokenObject $refreshed -ProfileName $script:ActiveProfile.AuthTokenProfile
                Write-CyberArkLog -Message 'Token refreshed successfully.' -Level 'INFO'
                return $true
            }
        } catch {
            Write-CyberArkLog -Message "Silent token refresh failed: $_" -Level 'ERROR'
        }
        return $false
    }

    # SelfHosted password-based methods - prompt for password only (pre-fill URL and username)
    if ($type -eq 'SelfHosted' -and $method -in @('CyberArk', 'LDAP', 'RADIUS')) {
        $ctx      = if ($script:SessionToken.PSObject.Properties['_RefreshContext']) { $script:SessionToken._RefreshContext } else { $null }
        $pvwaUrl  = if ($ctx -and $ctx['PVWAUrl']) { $ctx['PVWAUrl'] } else { $script:SessionToken.BaseURL }
        $username = if ($ctx -and $ctx['Credential']) { $ctx['Credential'].UserName } else { '' }

        Write-Host ''
        Write-Host '  Your session token has expired. Re-authentication required.' -ForegroundColor Yellow
        if ($username) { Write-Host "  Signing in as: $username" -ForegroundColor Cyan }
        Write-Host '  Press Enter to enter your password, or X to exit: ' -ForegroundColor White -NoNewline
        $r = (Read-Host).Trim()
        if ($r -match '^[Xx]$') { return $false }

        try {
            $securePassword = Read-Host -AsSecureString "  Password$(if ($username) { " for $username" })"
            $uname      = if ($username) { $username } else { (Read-Host '  Username').Trim() }
            $newCred    = [System.Management.Automation.PSCredential]::new($uname, $securePassword)
            $concurrent = if ($ctx -and $ctx.ContainsKey('ConcurrentSession')) { $ctx['ConcurrentSession'] } else { $false }
            $newToken = Get-AuthToken `
                -SystemType         $type `
                -AuthMethod         $method `
                -PVWAUrl            $pvwaUrl `
                -Credential         $newCred `
                -ConcurrentSession: ([switch]::new($concurrent)) `
                -IgnoreSSL:         $script:ActiveProfile.IgnoreSSL
            if ($newToken -and $newToken.Token) {
                $script:SessionToken = $newToken
                $null = Save-AuthToken -TokenObject $newToken -ProfileName $script:ActiveProfile.AuthTokenProfile
                Write-CyberArkLog -Message 'Re-authentication successful.' -Level 'INFO'
                return $true
            }
        } catch {
            Write-CyberArkLog -Message "Re-authentication failed: $_" -Level 'ERROR'
            Write-Host "  Authentication failed: $_" -ForegroundColor Red
        }
        return $false
    }

    # All other methods (SAML, OIDC, Shared, PKI, ISPSS Interactive/SSO) - use stored context
    Write-Host ''
    Write-Host '  Your session token has expired. Re-authentication required.' -ForegroundColor Yellow
    Write-Host '  Press Enter to re-authenticate, or X to exit: ' -ForegroundColor White -NoNewline
    $r = (Read-Host).Trim()
    if ($r -match '^[Xx]$') { return $false }

    try {
        $newToken = Get-AuthToken -TokenToRefresh $script:SessionToken -IgnoreSSL:$script:ActiveProfile.IgnoreSSL
        if ($newToken -and $newToken.Token) {
            $script:SessionToken = $newToken
            $null = Save-AuthToken -TokenObject $newToken -ProfileName $script:ActiveProfile.AuthTokenProfile
            Write-CyberArkLog -Message 'Re-authentication successful.' -Level 'INFO'
            return $true
        }
    } catch {
        Write-CyberArkLog -Message "Re-authentication failed: $_" -Level 'ERROR'
        Write-Host "  Authentication failed: $_" -ForegroundColor Red
    }
    return $false
}

function Invoke-SelfHostedKeepalive {
    if ($script:SessionToken.SystemType -ne 'SelfHosted') { return }
    $remaining = Get-TokenRemainingMinutes
    if ($remaining -gt 2) { return }

    Write-CyberArkLog -Message 'SelfHosted token near expiry - attempting keepalive via Get Logged On User.' -Level 'INFO'
    try {
        $resp = Invoke-CyberArkAPI -Token $script:SessionToken -Method 'GET' `
            -Endpoint '/API/LoggedOnUser' -IgnoreSSL:$script:ActiveProfile.IgnoreSSL
        if ($resp.IsSuccess) {
            $script:SessionToken.Expiry = (Get-Date).ToUniversalTime().AddMinutes($script:PVWA_SESSION_EXPIRY_MIN)
            Write-CyberArkLog -Message 'Keepalive succeeded. Token expiry extended.' -Level 'INFO'
        } else {
            Write-CyberArkLog -Message "Keepalive call failed ($($resp.StatusCode)): $($resp.ErrorMessage)" -Level 'WARN'
        }
    } catch {
        Write-CyberArkLog -Message "Keepalive error: $_" -Level 'WARN'
    }
}

function Invoke-SessionLogoff {
    if (-not $script:SessionToken) { return }
    if ($script:SessionToken.SystemType -eq 'SelfHosted') {
        Write-CyberArkLog -Message 'Logging off Self-Hosted PVWA session.' -Level 'INFO'
        try {
            Invoke-CyberArkAPI -Token $script:SessionToken -Method 'POST' `
                -Endpoint '/API/auth/Logoff' -IgnoreSSL:$script:ActiveProfile.IgnoreSSL | Out-Null
        } catch {
            Write-CyberArkLog -Message "Logoff request failed (session may already be expired): $_" -Level 'WARN'
        }
    }
    $script:SessionToken = $null
}

function Invoke-TokenValidate {
    # Calls GET /API/LoggedOnUser to confirm the server still accepts the token.
    # Returns the API response object, or $null if the call throws or is unsupported.
    # Privilege Cloud (ISPSS) does not expose a token validation endpoint — returns $null immediately.
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [bool]$IgnoreSSL = $false
    )
    if ($Token.SystemType -eq 'ISPSS') { return $null }
    try {
        return Invoke-CyberArkAPI -Token $Token -Method 'GET' `
            -Endpoint '/API/LoggedOnUser' -IgnoreSSL:$IgnoreSSL
    } catch {
        Write-CyberArkLog -Message "Token validation call failed: $_" -Level 'WARN'
        return $null
    }
}

function Invoke-TokenInvalidate {
    # Deletes the saved .cred file and force-expires the in-memory token so the
    # session loop immediately triggers re-authentication on its next iteration.
    if ($script:ActiveProfile) {
        $tokenPath = Get-ProfileTokenPath -Name $script:ActiveProfile.AuthTokenProfile
        if (Test-Path -LiteralPath $tokenPath) {
            Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($script:SessionToken) {
        $script:SessionToken.Expiry = [DateTime]::UtcNow.AddHours(-1)
    }
    Write-CyberArkLog -Message '401 Unauthorized - session token invalidated and file removed.' -Level 'WARN'
}

#endregion

#region --- Input and CSV Processing ---

function Select-InputFiles {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Title       = 'Select Input CSV File(s)'
    $dialog.Filter      = 'CSV Files (*.csv)|*.csv|All Files (*.*)|*.*'
    $dialog.Multiselect = $true
    $dialog.InitialDirectory = if ($script:ActiveProfile.InputFolder -and
            (Test-Path -LiteralPath $script:ActiveProfile.InputFolder)) {
        $script:ActiveProfile.InputFolder
    } else { $PSScriptRoot }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileNames
    }
    return @()
}

function Get-OutputCsvPath {
    param([string]$InputPath)
    $folder = if ($script:ActiveProfile.OutputFolder -and
            (Test-Path -LiteralPath $script:ActiveProfile.OutputFolder)) {
        $script:ActiveProfile.OutputFolder
    } else { Split-Path $InputPath }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    return Join-Path $folder "$($base)_$((Get-Date).ToString('yyyy-MM-dd'))_output.csv"
}

function Test-CsvSchema {
    param([string[]]$Headers, [hashtable[]]$Schema)
    return @($Schema | Where-Object { $_.Required -and ($_.Column -cnotin $Headers) })
}

function Invoke-InteractiveInput {
    param([hashtable[]]$Schema)
    $data = @{}
    foreach ($field in $Schema) {
        $value = Show-FieldPrompt -Label $field.Column -Description $field.Description `
            -Required:($field.Required)
        $data[$field.Column] = $value
    }
    return $data
}

function Invoke-CsvProcessing {
    param([PSCustomObject]$ModuleEntry)
    $meta   = $ModuleEntry.Meta
    $fnName = "Invoke-$($meta.Category)$($meta.Action)"

    $files = Select-InputFiles
    if (-not $files) {
        Write-Host '  No files selected.' -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
        return
    }

    foreach ($filePath in $files) {
        $fileName = [System.IO.Path]::GetFileName($filePath)
        Write-CyberArkLog -Message "Starting CSV: $filePath" -Level 'INFO'

        try { $rows = @(Import-Csv -LiteralPath $filePath) } catch {
            Write-Host "  Could not read '$fileName': $_" -ForegroundColor Red
            Write-CyberArkLog -Message "Failed to read CSV '$filePath': $_" -Level 'WARN'
            continue
        }

        if (-not $rows) {
            Write-Host "  '$fileName' is empty - skipped." -ForegroundColor Yellow
            continue
        }

        if ($meta.InputSchema) {
            $missing = Test-CsvSchema -Headers $rows[0].PSObject.Properties.Name -Schema $meta.InputSchema
            if ($missing) {
                $cols = ($missing | ForEach-Object { $_.Column }) -join ', '
                Write-Host "  '$fileName' missing required columns: $cols - skipped." -ForegroundColor Red
                Write-CyberArkLog -Message "CSV schema validation failed for '$fileName'. Missing: $cols" -Level 'WARN'
                continue
            }
        }

        $outputPath = Get-OutputCsvPath -InputPath $filePath
        $outputRows = [System.Collections.Generic.List[PSCustomObject]]::new()
        $okCount    = 0
        $failCount  = 0
        $fatal      = $false
        $total      = $rows.Count

        Write-Host "  Processing '$fileName' ($total rows)..." -ForegroundColor DarkGray

        foreach ($row in $rows) {
            # Token health before each row
            switch (Test-TokenExpiry) {
                'Warning' { Invoke-SelfHostedKeepalive; Invoke-TokenRefresh | Out-Null }
                'Expired' {
                    if (-not (Invoke-TokenRefresh)) {
                        Write-CyberArkLog -Message 'Auth failure mid-CSV - aborting.' -Level 'ERROR'
                        $fatal = $true
                    }
                }
            }
            if ($fatal) { break }

            $inputData = @{}
            foreach ($col in $row.PSObject.Properties) { $inputData[$col.Name] = $col.Value }

            $result    = & $fnName -Token $script:SessionToken -InputData $inputData -WhatIf:$script:WhatIfMode
            $isSuccess = ($result.Failures -eq 0 -and $result.ItemsProcessed -gt 0) -or
                         ($result.Successes -gt 0)
            $summary   = if ($isSuccess) {
                if ($result.Results.Count -gt 0 -and $result.Results[0].PSObject.Properties['Summary']) {
                    $result.Results[0].Summary
                } else { 'OK' }
            } else {
                if ($result.Errors.Count -gt 0) { $result.Errors[0].ErrorMessage } else { 'Failed' }
            }

            if ($isSuccess) { $okCount++ } else { $failCount++ }

            $outRow = [ordered]@{}
            foreach ($col in $row.PSObject.Properties) { $outRow[$col.Name] = $col.Value }
            $outRow['IsSuccess'] = $isSuccess
            $outRow['Summary']   = $summary
            $outputRows.Add([PSCustomObject]$outRow)

            if ($result.IsFatal) {
                Write-CyberArkLog -Message "IsFatal returned by module - aborting CSV loop." -Level 'ERROR'
                $errText = ($result.Errors | ForEach-Object { $_.ErrorMessage }) -join ' '
                if ($errText -match '\b401\b' -or $errText -match 'Unauthorized') {
                    Write-Host '  Session rejected by server (401 Unauthorized) - token invalidated.' -ForegroundColor Red
                    Invoke-TokenInvalidate
                }
                $fatal = $true
                break
            }
        }

        if ($outputRows.Count -gt 0) {
            $outputRows | Export-Csv -LiteralPath $outputPath -NoTypeInformation -Encoding UTF8
            Write-Host "  Output: $outputPath" -ForegroundColor Green
        }

        $msg = "'$fileName': $($outputRows.Count) processed - $okCount OK, $failCount failed."
        Write-Host "  $msg" -ForegroundColor $(if ($failCount -gt 0) { 'Yellow' } else { 'White' })
        Write-CyberArkLog -Message $msg -Level 'INFO'

        if ($meta.Action -notin @('List','Get')) {
            Add-CyberArkLogSummaryEntry -ModuleName $meta.Name `
                -ItemsProcessed $outputRows.Count -Successes $okCount -Failures $failCount
        }

        if ($fatal) { break }
    }

    Write-Host ''
    Write-Host '  Press Enter to return to the menu.' -ForegroundColor DarkGray
    Read-Host | Out-Null
}

#endregion

#region --- Action Menu ---

function Show-CategoryMenu {
    param([string[]]$Breadcrumbs, [object[]]$Categories)
    Show-Header -Breadcrumbs $Breadcrumbs

    if (-not $Categories -or $Categories.Count -eq 0) {
        Write-Host '  No API modules loaded for this system type.' -ForegroundColor DarkGray
        Write-Host "  Add .ps1 files to: $($script:APIModulesPath)" -ForegroundColor DarkGray
        Write-Host ''
    } else {
        $i = 1
        foreach ($cat in $Categories) {
            $n    = $cat.Count
            $noun = if ($n -eq 1) { 'action' } else { 'actions' }
            Write-Host ("  [{0,2}]  {1,-20}  ({2} {3})" -f $i, $cat.Name, $n, $noun) -ForegroundColor White
            $i++
        }
        Write-Host ''
    }

    Show-Divider
    $remaining = [Math]::Round((Get-TokenRemainingMinutes), 1)
    $expColor  = if ($remaining -le $script:TokenExpiryWarnMin) { 'Yellow' } else { 'DarkGray' }
    $idleMin   = if ($script:LastActivityTime) {
        [Math]::Round(((Get-Date) - $script:LastActivityTime).TotalMinutes, 1)
    } else { 0 }
    Write-Host ("  Token: {0} min remaining    Idle: {1} min" -f $remaining, $idleMin) -ForegroundColor $expColor
    if ($script:WhatIfMode) {
        Write-Host '  WhatIf mode is ON - write operations will be suppressed.' -ForegroundColor Yellow
    }
    Write-Host '  [R] Restart to profile selection    [X] Exit' -ForegroundColor White
}

function Show-ActionMenu {
    param([string[]]$Breadcrumbs, [PSCustomObject[]]$CategoryModules)
    Show-Header -Breadcrumbs $Breadcrumbs

    $i = 1
    foreach ($entry in $CategoryModules) {
        if ($entry.PSObject.Properties['Failed'] -and $entry.Failed) {
            Write-Host ("    {0,3}.  {1}  [Load Failed]" -f $i, $entry.Meta.Name) -ForegroundColor Red
            Write-Host ("           $($entry.Meta.Description)") -ForegroundColor DarkRed
        } else {
            $tags = @()
            if ($entry.Meta.AcceptsInputFile)                       { $tags += 'CSV' }
            if ($entry.Meta.SupportsWhatIf -and $script:WhatIfMode) { $tags += 'WhatIf' }
            $tagStr = if ($tags) { "  [$($tags -join ', ')]" } else { '' }
            Write-Host ("    {0,3}.  {1}{2}" -f $i, $entry.Meta.Name, $tagStr) -ForegroundColor White
            Write-Host ("           {0}" -f $entry.Meta.Description) -ForegroundColor DarkGray
        }
        $i++
    }
    Write-Host ''

    Show-Divider
    $remaining = [Math]::Round((Get-TokenRemainingMinutes), 1)
    $expColor  = if ($remaining -le $script:TokenExpiryWarnMin) { 'Yellow' } else { 'DarkGray' }
    Write-Host ("  Token: {0} min remaining" -f $remaining) -ForegroundColor $expColor
    if ($script:WhatIfMode) {
        Write-Host '  WhatIf mode is ON - write operations will be suppressed.' -ForegroundColor Yellow
    }
    Write-Host '  [B] Back to categories    [R] Restart    [X] Exit' -ForegroundColor White
}

function Invoke-ActionModule {
    param(
        [PSCustomObject]$ModuleEntry,
        [hashtable]$Defaults = $null
    )

    if ($ModuleEntry.PSObject.Properties['Failed'] -and $ModuleEntry.Failed) {
        Show-Header -Breadcrumbs @($script:ActiveProfile.ProfileName, $ModuleEntry.Meta.Category, $ModuleEntry.Meta.Name)
        Write-Host "  $($ModuleEntry.Meta.Name)" -ForegroundColor Red
        Write-Host '  This module failed to load and cannot be executed.' -ForegroundColor Red
        Write-Host ''
        Write-Host "  Error: $($ModuleEntry.FailError)" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
        Read-Host | Out-Null
        return
    }

    $meta   = $ModuleEntry.Meta
    $fnName = "Invoke-$($meta.Category)$($meta.Action)"

    if ($meta.AcceptsInputFile) {
        Show-Header -Breadcrumbs @($script:ActiveProfile.ProfileName, $meta.Category, $meta.Name)
        Write-Host "  $($meta.Name)" -ForegroundColor White
        Write-Host "  $($meta.Description)" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [1] Process CSV file(s)    [2] Enter values interactively    [3] Generate Template    [B] Back' -ForegroundColor White
        $mode = Read-MenuChoice -Prompt '[1] / [2] / [3] / [B]ack (default: B)'
        if (-not $mode) { $mode = 'B' }
        switch ($mode.ToUpper()) {
            '1' { Invoke-CsvProcessing -ModuleEntry $ModuleEntry; return }
            '2' { <# fall through to interactive input below #> }
            '3' {
                $cols = @($meta.InputSchema | ForEach-Object { $_.Column })
                if ($cols.Count -eq 0) {
                    Write-Host '  This module has no input schema; no template to generate.' -ForegroundColor Yellow
                } else {
                    $csvPath = Get-CsvSavePath -DefaultFolder $script:ActiveProfile.OutputFolder `
                        -ModuleName "$($meta.Name) Template"
                    if ($csvPath) {
                        $header = ($cols | ForEach-Object { "`"$_`"" }) -join ','
                        [System.IO.File]::WriteAllLines($csvPath, [string[]]@($header), [System.Text.Encoding]::UTF8)
                        Write-Host "  Template saved: $csvPath" -ForegroundColor Green
                    }
                }
                return
            }
            { $_ -match '^B\d*$' } { return }
            default { return }
        }
    }

    Show-Header -Breadcrumbs @($script:ActiveProfile.ProfileName, $meta.Category, $meta.Name)
    Write-Host "  $($meta.Name)" -ForegroundColor White
    Write-Host "  $($meta.Description)" -ForegroundColor DarkGray
    Write-Host ''

    $inputData = if ($meta.HasCustomInput) {
        if ($Defaults) {
            & "Get-$($meta.Category)$($meta.Action)Input" -Token $script:SessionToken -Defaults $Defaults
        } else {
            & "Get-$($meta.Category)$($meta.Action)Input" -Token $script:SessionToken
        }
    } elseif ($meta.InputSchema) {
        Invoke-InteractiveInput -Schema $meta.InputSchema
    } else { @{} }

    if ($null -eq $inputData) { return }   # User cancelled in custom input function

    Write-Host ''
    Write-CyberArkLog -Message "Invoking $fnName" -Level 'DEBUG'

    $result = & $fnName -Token $script:SessionToken -InputData $inputData -WhatIf:$script:WhatIfMode

    Write-Host ''
    if ($result.Successes -gt 0 -or ($result.ItemsProcessed -eq 0 -and $result.Errors.Count -eq 0)) {
        Write-Host "  Result: $($result.Successes) succeeded, $($result.Failures) failed." -ForegroundColor Green
        if ($result.Results.Count -gt 0) {
            $tableData = if ($meta.Action -eq 'List') {
                $n = 1
                $result.Results | ForEach-Object {
                    $props = [ordered]@{ '#' = $n++ }
                    foreach ($p in $_.PSObject.Properties) { $props[$p.Name] = $p.Value }
                    [PSCustomObject]$props
                }
            } else { $result.Results }
            $tableData | Format-Table -AutoSize | Out-String |
                Where-Object { $_.Trim() } |
                ForEach-Object { Write-Host "  $_" }
        }
    } else {
        Write-Host "  Result: $($result.Failures) failed." -ForegroundColor Red
        foreach ($err in $result.Errors) {
            Write-Host "    Error: $($err.ErrorMessage)" -ForegroundColor Yellow
            if ($err.ErrorDetails -and $err.ErrorDetails.ErrorCode) {
                Write-Host "    Code:  $($err.ErrorDetails.ErrorCode)" -ForegroundColor DarkGray
            }
        }
    }

    if ($result.IsFatal) {
        $errText = ($result.Errors | ForEach-Object { $_.ErrorMessage }) -join ' '
        if ($errText -match '\b401\b' -or $errText -match 'Unauthorized') {
            Write-Host ''
            Write-Host '  Session rejected by server (401 Unauthorized) - token invalidated.' -ForegroundColor Red
            Invoke-TokenInvalidate
        }
        return
    }

    if ($meta.ProducesOutput -and $result.Results.Count -gt 0) {
        $saveCsv = Read-MenuChoice -Prompt 'Save results to CSV? [y/N]'
        if ($saveCsv -match '^[Yy]') {
            $csvPath = Get-CsvSavePath -DefaultFolder $script:ActiveProfile.OutputFolder -ModuleName $meta.Name
            if ($csvPath) {
                try {
                    $result.Results | Export-Csv -Path $csvPath -NoTypeInformation -Force
                    Write-Host "  Saved: $csvPath" -ForegroundColor Green
                    Write-CyberArkLog -Message "Results saved to CSV: $csvPath" -Level 'INFO'
                } catch {
                    Write-Host "  Failed to save CSV: $_" -ForegroundColor Red
                    Write-CyberArkLog -Message "Failed to save CSV to '$csvPath': $_" -Level 'ERROR'
                }
            }
        }
    }

    if ($meta.Action -notin @('List','Get')) {
        Add-CyberArkLogSummaryEntry -ModuleName $meta.Name `
            -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    }

    # For List actions: offer line-number drill-down to the corresponding Get module
    if ($meta.Action -eq 'List' -and $result.Results.Count -gt 0) {
        $getModule = $script:LoadedModules | Where-Object {
            -not ($_.PSObject.Properties['Failed'] -and $_.Failed) -and
            $_.Meta.Category -eq $meta.Category -and $_.Meta.Action -eq 'Get'
        } | Select-Object -First 1
        if ($getModule) {
            Write-Host ''
            Write-Host '  Enter a line number to view details, or press Enter to return.' -ForegroundColor DarkGray
            $lineInput = (Read-Host '  #').Trim()
            if ($lineInput -match '^\d+$') {
                $lineNum = [int]$lineInput
                if ($lineNum -ge 1 -and $lineNum -le $result.Results.Count) {
                    $selectedRow = $result.Results[$lineNum - 1]
                    $rowDefaults = @{}
                    foreach ($prop in $selectedRow.PSObject.Properties) {
                        $rowDefaults[$prop.Name] = $prop.Value
                    }
                    Invoke-ActionModule -ModuleEntry $getModule -Defaults $rowDefaults
                }
            }
            return
        }
    }

    Write-Host ''
    Write-Host '  Press Enter to return to the menu.' -ForegroundColor DarkGray
    Read-Host | Out-Null
}

#endregion

#region --- Session Loop ---

function Invoke-SessionLoop {
    $script:LastActivityTime = Get-Date
    $warnShown = $false

    Import-APIModules
    # Re-dot-source each module file into this scope so child functions (Invoke-ActionModule)
    # can call both entry points and custom-input functions by name.
    foreach ($m in $script:LoadedModules) {
        if ($m.PSObject.Properties['Failed'] -and $m.Failed) { continue }
        . $m.FilePath
    }

    $crumbs = @($script:ActiveProfile.ProfileName)

    while ($true) {

        # --- Inactivity check ---
        $idleSec      = ((Get-Date) - $script:LastActivityTime).TotalSeconds
        $timeoutSec   = $script:InactivityTimeoutMin * 60
        $warnAtSec    = $timeoutSec * 0.9

        if ($idleSec -ge $timeoutSec) {
            Write-CyberArkLog -Message "Inactivity timeout ($($script:InactivityTimeoutMin) min). Ending session." -Level 'INFO'
            return 'Exit'
        }

        if ($idleSec -ge $warnAtSec -and -not $warnShown) {
            $remainSec = [int]($timeoutSec - $idleSec)
            Write-Host ''
            Write-Host "  Inactivity warning: session will end in ~$remainSec seconds due to inactivity." -ForegroundColor Yellow
            $warnShown = $true
        }

        # --- Token health ---
        switch (Test-TokenExpiry) {
            'Expired' {
                if (-not (Invoke-TokenRefresh)) {
                    Write-CyberArkLog -Message 'Session ended - could not renew token.' -Level 'ERROR'
                    return 'Exit'
                }
                $warnShown = $false
            }
            'Warning' {
                Invoke-SelfHostedKeepalive
                Invoke-TokenRefresh | Out-Null
            }
        }

        # --- Category selection ---
        $categories = @($script:LoadedModules | Group-Object { $_.Meta.Category } | Sort-Object Name)
        Show-CategoryMenu -Breadcrumbs $crumbs -Categories $categories
        $catChoice = Read-MenuChoice -Prompt 'Category / [R]estart / [X]it'
        $script:LastActivityTime = Get-Date
        $warnShown = $false

        switch -Regex ($catChoice.ToUpper()) {

            '^X$' {
                if (Confirm-Action 'End this session and exit the script?') { return 'Exit' }
            }

            '^R$' {
                if (Confirm-Action 'Return to profile selection?') { return 'Restart' }
            }

            '^\d+$' {
                $catNum = [int]$catChoice
                if ($catNum -lt 1 -or $catNum -gt $categories.Count) {
                    Write-Host '  Invalid selection.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                } else {
                    $selectedCat = $categories[$catNum - 1]
                    $catName     = $selectedCat.Name
                    $catModules  = @($selectedCat.Group |
                        Sort-Object { if ($_.Meta.PSObject.Properties['Priority']) { $_.Meta.Priority } else { 99 } },
                                    { $_.Meta.Action })
                    $catCrumbs   = $crumbs + @($catName)

                    # --- Action loop for this category ---
                    while ($true) {
                        Show-ActionMenu -Breadcrumbs $catCrumbs -CategoryModules $catModules
                        $actChoice = Read-MenuChoice -Prompt 'Action / [B]ack (default: B)'
                        if (-not $actChoice) { $actChoice = 'B' }
                        $script:LastActivityTime = Get-Date

                        switch -Regex ($actChoice.ToUpper()) {
                            '^X$' {
                                if (Confirm-Action 'End this session and exit the script?') { return 'Exit' }
                            }
                            '^R$' {
                                if (Confirm-Action 'Return to profile selection?') { return 'Restart' }
                            }
                            '^\d+$' {
                                $actNum = [int]$actChoice
                                if ($actNum -lt 1 -or $actNum -gt $catModules.Count) {
                                    Write-Host '  Invalid selection.' -ForegroundColor Red
                                    Start-Sleep -Seconds 1
                                } else {
                                    Invoke-ActionModule -ModuleEntry $catModules[$actNum - 1]
                                    # A 401 during the module call force-expires the token via
                                    # Invoke-TokenInvalidate. Re-check immediately so the re-auth
                                    # prompt appears now, not only after the user presses [B].
                                    if ((Test-TokenExpiry) -eq 'Expired' -and -not (Invoke-TokenRefresh)) {
                                        return 'Exit'
                                    }
                                }
                            }
                            { $_ -match '^B\d*$' } { break }
                            default {
                                if ($actChoice) {
                                    Write-Host '  Invalid input.' -ForegroundColor Red
                                    Start-Sleep -Seconds 1
                                }
                            }
                        }

                        if ($actChoice.ToUpper() -match '^B\d*$') { break }
                    }   # end action loop
                }
            }

            default {
                if ($catChoice) {
                    Write-Host '  Invalid input.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                }
            }
        }

    }   # while session loop
}

#endregion

#region --- Entry Point ---

# Guard: skip the interactive entry point when this script is dot-sourced (e.g. in Pester tests).
if ($MyInvocation.InvocationName -eq '.') { return }

try {

Assert-Prerequisites
. $script:AuthScriptPath   # dot-source at script scope so Get-AuthToken is available everywhere

Initialize-CyberArkLog -ProfileName 'Startup' -Destination 'Console' -MinLevel 'INFO'
Write-CyberArkLog -Message "$($script:AppName) v$($script:Version) starting. PID: $PID" -Level 'INFO'

# --- Outer restart loop ---
$nextDefaultProfile = $StartProfile

while ($true) {
    $selectedProfile = Invoke-ProfileManagementLoop -DefaultProfileName $nextDefaultProfile

    if (-not $selectedProfile) {
        # User chose Quit at profile selection
        Write-CyberArkLog -Message 'User exited at profile selection.' -Level 'INFO'
        Close-CyberArkLog
        exit 0
    }

    # Create log and output folders if configured but not yet present
    foreach ($folderProp in @('LogFolder', 'OutputFolder')) {
        $folderPath = $script:ActiveProfile.$folderProp
        if ($folderPath -and -not (Test-Path -LiteralPath $folderPath)) {
            try {
                New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
            } catch {
                Write-CyberArkLog -Message "Could not create folder '$folderPath': $_" -Level 'WARN'
            }
        }
    }

    # Re-initialize log with the active profile's folder and metadata
    $logFolder = if ($script:ActiveProfile.LogFolder -and (Test-Path -LiteralPath $script:ActiveProfile.LogFolder)) {
        $script:ActiveProfile.LogFolder
    } else { $PSScriptRoot }

    Initialize-CyberArkLog `
        -LogFolder   $logFolder `
        -ProfileName $script:ActiveProfile.ProfileName `
        -MinLevel    'INFO' `
        -Destination 'Both' `
        -SystemType  $script:SessionToken.SystemType `
        -AuthMethod  $script:SessionToken.AuthMethod `
        -BaseURL     $script:SessionToken.BaseURL `
        -WhatIfMode  $script:WhatIfMode

    Write-CyberArkLog -Message "Session started. Profile: $selectedProfile  WhatIf: $($script:WhatIfMode)" -Level 'INFO'

    if ($script:ActiveProfile.IgnoreSSL) {
        Write-CyberArkLog -Message 'IgnoreSSL is enabled for this profile.' -Level 'WARN'
    }

    # --- Run the session ---
    $outcome = Invoke-SessionLoop

    # --- Session ended ---
    Invoke-SessionLogoff
    Close-CyberArkLog

    if ($outcome -eq 'Restart') {
        # Return to profile selection with the current profile as default
        $nextDefaultProfile = $selectedProfile
        # Re-initialize a minimal console log for the profile selection screen
        Initialize-CyberArkLog -ProfileName 'Startup' -Destination 'Console' -MinLevel 'INFO'
        continue
    }

    # Exit
    break
}

} catch {
    Write-Host "`n[FATAL] Unhandled error at Driver.ps1:$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Write-Host "  $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Stack trace:" -ForegroundColor DarkGray
    $_.ScriptStackTrace -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    exit 1
}

exit 0

#endregion
