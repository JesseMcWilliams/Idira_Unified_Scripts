#Requires -Version 5.1
<#
.SYNOPSIS
    Idira Unified Scripts — CyberArk PAS interactive driver.

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

$script:AppName              = 'Idira Unified Scripts — CyberArk PAS Driver'
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
$script:SessionToken         = $null   # Active token object — set after successful auth
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
        Write-Host '  [WhatIf Mode ON — no changes will be made]' -ForegroundColor Yellow
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
function Get-ProfileTokenPath { param([string]$Name) Join-Path $script:ProfileDir "$Name.xml"  }

#endregion

#region --- currentProfile CRUD ---

function Get-AllDriverProfiles {
    $jsonFiles = Get-ChildItem -LiteralPath $script:ProfileDir -Filter '*.json' -File -ErrorAction SilentlyContinue
    $selectedProfiles  = foreach ($f in $jsonFiles) {
        try {
            $p        = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            # Normalize: add any fields introduced after this profile was saved
            foreach ($field in @('SystemType', 'BaseURL', 'LogFolder', 'InputFolder', 'OutputFolder')) {
                if (-not $p.PSObject.Properties[$field]) {
                    $p | Add-Member -NotePropertyName $field -NotePropertyValue '' -Force
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
                AuthMethod   = $authMethod
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
        Write-Host '  [N] New currentProfile    [Q] Quit' -ForegroundColor White
        return
    }

    # Column widths
    $numW  = 3
    $nameW = [Math]::Max(16, ($selectedProfiles | ForEach-Object { $_.ProfileName.Length } | Measure-Object -Maximum).Maximum + 2)
    $sysW  = 15
    $authW = 20
    $useW  = 17
    $statW = 10

    $hdr = "  {0,-$numW}  {1,-$nameW}  {2,-$sysW}  {3,-$authW}  {4,-$useW}  {5,-$statW}" -f '#', 'currentProfile Name', 'System', 'Auth Method', 'Last Used', 'Token'
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
    Write-Host '  [N] New currentProfile    [Q] Quit' -ForegroundColor White
}

function Show-ProfileDetail {
    param([PSCustomObject]$Summary, [string[]]$Breadcrumbs)
    Show-Header -Breadcrumbs $Breadcrumbs

    $p = $Summary.currentProfile

    function Field([string]$label, [string]$value, [string]$color = 'Gray') {
        Write-Host ("    {0,-22}" -f $label) -NoNewline -ForegroundColor DarkGray
        Write-Host $value -ForegroundColor $color
    }

    Write-Host '  currentProfile Settings' -ForegroundColor White
    Show-Divider
    Field 'currentProfile Name'    $p.ProfileName    'Cyan'
    Field 'Auth currentProfile'    $p.AuthTokenProfile
    Field 'System Type'     $(if ($p.SystemType)  { $p.SystemType }  else { '(Not Set)' }) $(if ($p.SystemType) { 'Cyan' } else { 'Yellow' })
    Field 'Base URL'        $(if ($p.BaseURL)      {$p.BaseURL} else { '(Not Set)' })
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
    Write-Host '  [C] Continue    [E] Edit    [P] Copy    [D] Delete    [T] Test Connection    [B] Back' -ForegroundColor White
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
    Write-Host '  currentProfile Settings' -ForegroundColor White
    Write-Host '  (Press Enter to keep the current value)' -ForegroundColor DarkGray
    Write-Host ''

    # currentProfile Name — only editable on new profiles; for copy the name is already set
    if ($IsNew) {
        while ($true) {
            $name = Show-FieldPrompt -Label 'currentProfile Name' -Default $currentProfile.ProfileName -Required `
                -Description 'Unique name for this profile (e.g. Development, Production)'
            if (-not $name) {
                Write-Host '    currentProfile Name is required.' -ForegroundColor Red
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
        Write-Host "    currentProfile Name     : $($currentProfile.ProfileName)  (not editable)" -ForegroundColor DarkGray
    }

    Write-Host ''
    # System Type — numbered choice so the user only has to type one key
    $sysTypeMap = @{ '1' = 'Privilege Cloud'; '2' = 'Self-Hosted' }
    Write-Host '  System Type:' -ForegroundColor White
    Write-Host '    [1] Privilege Cloud   — SaaS / ISPSS  (*.privilegecloud.cyberark.cloud)' -ForegroundColor Gray
    Write-Host '    [2] Self-Hosted       — On-premises PVWA' -ForegroundColor Gray
    if ($currentProfile.SystemType) {
        Write-Host ("    Current: $($currentProfile.SystemType)") -ForegroundColor DarkCyan
    }
    $sysChoice = ''
    do {
        $sysChoice = Read-MenuChoice -Prompt '1 / 2'
        if ($sysChoice -notin @('1', '2')) {
            Write-Host '    Invalid — enter 1 or 2.' -ForegroundColor Red
        }
    } while ($sysChoice -notin @('1', '2'))
    $currentProfile.SystemType = $sysTypeMap[$sysChoice]

    # Base URL — prompt depends on SystemType
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

    $currentProfile.LogFolder = Show-FieldPrompt -Label 'Log Folder' -Default $currentProfile.LogFolder `
        -Description 'Absolute path for log files. Leave blank to use the script launch directory.'

    $currentProfile.InputFolder = Show-FieldPrompt -Label 'Input Folder' -Default $currentProfile.InputFolder `
        -Description 'Default folder for CSV input file pickers. Leave blank for launch directory.'

    $currentProfile.OutputFolder = Show-FieldPrompt -Label 'Output Folder' -Default $currentProfile.OutputFolder `
        -Description 'Destination for output CSV files. Leave blank for launch directory.'

    Write-Host ''
    $sslStr = Show-FieldPrompt -Label 'Ignore SSL Errors' -Default $(if ($currentProfile.IgnoreSSL) { 'Y' } else { 'N' }) `
        -Description 'Bypass SSL certificate validation? (Y/N) — Use only for lab/dev environments.'
    $currentProfile.IgnoreSSL = $sslStr -match '^[Yy]$'

    $wiStr = Show-FieldPrompt -Label 'WhatIf Default' -Default $(if ($currentProfile.WhatIfDefault) { 'Y' } else { 'N' }) `
        -Description 'Default to WhatIf mode for this profile? (Y/N) — Recommended for production.'
    $currentProfile.WhatIfDefault = $wiStr -match '^[Yy]$'

    Write-Host ''
    Save-DriverProfile -currentProfile $currentProfile
    Write-Host "  currentProfile '$($currentProfile.ProfileName)' saved." -ForegroundColor Green

    if ($currentProfile.IgnoreSSL) {
        Write-CyberArkLog -Message "currentProfile '$($currentProfile.ProfileName)' has IgnoreSSL enabled — use only in lab/dev." -Level 'WARN'
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

    $xmlPath = Get-ProfileTokenPath -Name $Summary.currentProfile.AuthTokenProfile
    if (-not (Test-Path -LiteralPath $xmlPath)) {
        Write-Host '  No saved token found. A new authentication is required.' -ForegroundColor Yellow
    }

    Write-Host '  Calling Get-AuthToken...' -ForegroundColor DarkGray
    Write-Host ''

    try {
        $params = @{ IgnoreSSL = $Summary.currentProfile.IgnoreSSL }
        if (Test-Path -LiteralPath $xmlPath) {
            $saved = Import-AuthToken -Path $xmlPath -IgnoreExpiry
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
                Save-AuthToken -TokenObject $token -ProfileName $Summary.currentProfile.AuthTokenProfile
                Write-Host '  Token saved.' -ForegroundColor Green
            }
        } else {
            Write-Host '  Authentication returned no token.' -ForegroundColor Red
        }
    } catch {
        Write-Host "  Authentication failed: $_" -ForegroundColor Red
        Write-CyberArkLog -Message "Test connection failed for profile '$($Summary.ProfileName)': $_" -Level 'WARN'
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

    $breadcrumbRoot = @('currentProfile Selection')
    $selected       = $null   # initialize so StrictMode doesn't throw if a branch skips setting it

    while ($true) {

        # --- currentProfile List ---
        $selectedProfiles = @(Get-AllDriverProfiles)
        Show-ProfileList -selectedProfiles $selectedProfiles -Breadcrumbs $breadcrumbRoot

        if (-not $selectedProfiles -or $selectedProfiles.Count -eq 0) {
            $choice = Read-MenuChoice -Prompt '[N] New    [Q] Quit'
        } else {
            $defaultHint = if ($DefaultProfileName) { " (default: $DefaultProfileName)" } else { '' }
            $choice = Read-MenuChoice -Prompt "Number / [N]ew / [Q]uit$defaultHint"
            if (-not $choice -and $DefaultProfileName) { $choice = $DefaultProfileName }
        }

        switch -Regex ($choice.ToUpper()) {

            '^Q$' {
                Write-Host "`n  Goodbye.`n" -ForegroundColor DarkGray
                return $null   # Signal: exit
            }

            '^N$' {
                # --- Create new profile ---
                $blank = New-BlankProfile -Name ''
                $edited = Invoke-ProfileEditFlow -currentProfile $blank -Breadcrumbs ($breadcrumbRoot + @('New currentProfile')) -IsNew
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
                Write-Host ("  WARNING: Profile incomplete — missing: $($missingFields -join ', ').") -ForegroundColor Yellow
                Write-Host '  Choose E to edit it or D to delete this profile.' -ForegroundColor Yellow
            }

            $action = Read-MenuChoice -Prompt 'C / E / P / D / T / B / Q'

            switch ($action.ToUpper()) {

                'C' {
                    if ($isIncomplete) {
                        Write-Host '  Cannot connect: Base URL is required. Use [E]dit to add it first.' -ForegroundColor Red
                        Start-Sleep -Seconds 2
                        break
                    }
                    # Continue to session — authenticate and return token
                    $selectedProfile = $selected.currentProfile
                    $selectedProfile.LastUsed = (Get-Date).ToUniversalTime().ToString('o')
                    Save-DriverProfile -currentProfile $selectedProfile

                    $xmlPath = Get-ProfileTokenPath -Name $selectedProfile.AuthTokenProfile
                    $token   = $null

                    if (Test-Path -LiteralPath $xmlPath) {
                        try {
                            $token = Import-AuthToken -Path $xmlPath -AutoRefresh
                        } catch {
                            Write-CyberArkLog -Message "Failed to load saved token: $_" -Level 'WARN'
                        }
                    }

                    if (-not $token) {
                        Show-Header -Breadcrumbs ($detailCrumbs + @('Authenticate'))
                        Write-Host '  No valid token found. Please authenticate.' -ForegroundColor Yellow
                        Write-Host ''
                        try {
                            $authParams = @{ IgnoreSSL = $selectedProfile.IgnoreSSL }
                            # Map profile SystemType to the auth script's expected values
                            if ($selectedProfile.SystemType -eq 'Privilege Cloud') {
                                $authParams['SystemType'] = 'ISPSS'
                                if ($selectedProfile.BaseURL -match '^https://(.+)\.privilegecloud\.cyberark\.cloud') {
                                    $authParams['PCloudSubdomain'] = $Matches[1]
                                }
                            } elseif ($selectedProfile.SystemType -eq 'Self-Hosted') {
                                $authParams['SystemType'] = 'SelfHosted'
                                if ($selectedProfile.BaseURL) { $authParams['PVWAUrl'] = $selectedProfile.BaseURL }
                            }
                            $token = Get-AuthToken @authParams
                        } catch {
                            Write-Host "  Authentication failed: $_" -ForegroundColor Red
                            Write-CyberArkLog -Message "Authentication failed for profile '$($selectedProfile.ProfileName)': $_" -Level 'ERROR'
                            Write-Host '  Press Enter to return to profile selection.' -ForegroundColor DarkGray
                            Read-Host | Out-Null
                            break
                        }
                    }

                    if ($token -and $token.Token) {
                        # Persist the (possibly refreshed) token
                        try {
                            Save-AuthToken -TokenObject $token -ProfileName $selectedProfile.AuthTokenProfile
                        } catch {
                            Write-CyberArkLog -Message "Could not save refreshed token: $_" -Level 'WARN'
                        }

                        $script:SessionToken  = $token
                        $script:ActiveProfile = $selectedProfile
                        $script:WhatIfMode    = $selectedProfile.WhatIfDefault -or $script:WhatIfMode

                        # Return the profile name — caller starts the session loop
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
                    # Copy profile — prompt for new name first
                    Show-Header -Breadcrumbs ($detailCrumbs + @('Copy'))
                    Write-Host '  Copy currentProfile' -ForegroundColor White
                    Write-Host ''
                    $newName = ''
                    while (-not $newName) {
                        $newName = Show-FieldPrompt -Label 'New currentProfile Name' -Required `
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
                        Write-CyberArkLog -Message "currentProfile '$($selected.ProfileName)' deleted." -Level 'INFO'
                        Write-Host "  currentProfile deleted." -ForegroundColor Green
                        Start-Sleep -Seconds 1
                        break   # Back to profile list
                    }
                }

                'T' {
                    # Test connection
                    Invoke-ProfileTestConnection -Summary $selected `
                        -Breadcrumbs ($detailCrumbs + @('Test Connection'))
                }

                { $_ -match '^B\d*$' } {
                    # B# navigation — B = back 1, B2 = back 2, etc.
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
            Write-CyberArkLog -Message "Failed to load module '$($file.Name)': $_" -Level 'WARN'
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

    # ISPSS ClientCredentials — silent refresh via refresh_token grant
    if ($type -eq 'ISPSS' -and $method -eq 'ClientCredentials') {
        Write-CyberArkLog -Message 'Silently refreshing ISPSS ClientCredentials token.' -Level 'INFO'
        try {
            $refreshed = Get-AuthToken -TokenToRefresh $script:SessionToken `
                -IgnoreSSL:$script:ActiveProfile.IgnoreSSL
            if ($refreshed -and $refreshed.Token) {
                $script:SessionToken = $refreshed
                Save-AuthToken -TokenObject $refreshed -ProfileName $script:ActiveProfile.AuthTokenProfile
                Write-CyberArkLog -Message 'Token refreshed successfully.' -Level 'INFO'
                return $true
            }
        } catch {
            Write-CyberArkLog -Message "Silent token refresh failed: $_" -Level 'ERROR'
        }
        return $false
    }

    # All other methods — must prompt the user to re-authenticate
    Write-Host ''
    Write-Host '  Your session token has expired. Re-authentication required.' -ForegroundColor Yellow
    Write-Host '  Press Enter to open the authentication prompt, or X to exit: ' -ForegroundColor White -NoNewline
    $r = (Read-Host).Trim()
    if ($r -match '^[Xx]$') { return $false }

    try {
        $newToken = Get-AuthToken -IgnoreSSL:$script:ActiveProfile.IgnoreSSL
        if ($newToken -and $newToken.Token) {
            $script:SessionToken = $newToken
            Save-AuthToken -TokenObject $newToken -ProfileName $script:ActiveProfile.AuthTokenProfile
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

    Write-CyberArkLog -Message 'SelfHosted token near expiry — attempting keepalive via Get Logged On User.' -Level 'INFO'
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
            Write-Host "  '$fileName' is empty — skipped." -ForegroundColor Yellow
            continue
        }

        if ($meta.InputSchema) {
            $missing = Test-CsvSchema -Headers $rows[0].PSObject.Properties.Name -Schema $meta.InputSchema
            if ($missing) {
                $cols = ($missing | ForEach-Object { $_.Column }) -join ', '
                Write-Host "  '$fileName' missing required columns: $cols — skipped." -ForegroundColor Red
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
                        Write-CyberArkLog -Message 'Auth failure mid-CSV — aborting.' -Level 'ERROR'
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
                Write-CyberArkLog -Message "IsFatal returned by module — aborting CSV loop." -Level 'ERROR'
                $fatal = $true
                break
            }
        }

        if ($outputRows.Count -gt 0) {
            $outputRows | Export-Csv -LiteralPath $outputPath -NoTypeInformation -Encoding UTF8
            Write-Host "  Output: $outputPath" -ForegroundColor Green
        }

        $msg = "'$fileName': $($outputRows.Count) processed — $okCount OK, $failCount failed."
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

function Show-ActionMenu {
    param([string[]]$Breadcrumbs)
    Show-Header -Breadcrumbs $Breadcrumbs

    if (-not $script:LoadedModules -or $script:LoadedModules.Count -eq 0) {
        Write-Host '  No API modules are loaded for this system type.' -ForegroundColor DarkGray
        Write-Host "  Add .ps1 files to: $($script:APIModulesPath)" -ForegroundColor DarkGray
        Write-Host ''
    } else {
        $groups = $script:LoadedModules |
                  Sort-Object { if ($_.Meta.PSObject.Properties['Priority']) { $_.Meta.Priority } else { 99 } },
                               { $_.Meta.Category }, { $_.Meta.Action } |
                  Group-Object { $_.Meta.Category }

        foreach ($group in $groups) {
            Write-Host "  $($group.Name)" -ForegroundColor Cyan
            foreach ($entry in $group.Group) {
                $tags = @()
                if ($entry.Meta.AcceptsInputFile)                    { $tags += 'CSV' }
                if ($entry.Meta.SupportsWhatIf -and $script:WhatIfMode) { $tags += 'WhatIf' }
                $tagStr = if ($tags) { "  [$($tags -join ', ')]" } else { '' }
                Write-Host ("    {0,3}.  {1}{2}" -f $entry.Number, $entry.Meta.Name, $tagStr) -ForegroundColor White
            }
            Write-Host ''
        }
    }

    Show-Divider
    $remaining = [Math]::Round((Get-TokenRemainingMinutes), 1)
    $expColor  = if ($remaining -le $script:TokenExpiryWarnMin) { 'Yellow' } else { 'DarkGray' }
    $idleMin   = if ($script:LastActivityTime) {
        [Math]::Round(((Get-Date) - $script:LastActivityTime).TotalMinutes, 1)
    } else { 0 }

    Write-Host ("  Token: {0} min remaining    Idle: {1} min" -f $remaining, $idleMin) -ForegroundColor $expColor
    if ($script:WhatIfMode) {
        Write-Host '  WhatIf mode is ON — write operations will be suppressed.' -ForegroundColor Yellow
    }
    Write-Host '  [R] Restart to profile selection    [X] Exit' -ForegroundColor White
}

function Invoke-ActionModule {
    param([PSCustomObject]$ModuleEntry)
    $meta   = $ModuleEntry.Meta
    $fnName = "Invoke-$($meta.Category)$($meta.Action)"

    if ($meta.AcceptsInputFile) {
        Show-Header -Breadcrumbs @($script:ActiveProfile.ProfileName, $meta.Category, $meta.Name)
        Write-Host "  $($meta.Name)" -ForegroundColor White
        Write-Host "  $($meta.Description)" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [1] Process CSV file(s)    [2] Enter values interactively    [B] Back' -ForegroundColor White
        $mode = Read-MenuChoice -Prompt 'Mode'
        switch ($mode.ToUpper()) {
            '1' { Invoke-CsvProcessing -ModuleEntry $ModuleEntry; return }
            '2' { <# fall through to interactive input below #> }
            { $_ -match '^B\d*$' } { return }
            default { return }
        }
    }

    Show-Header -Breadcrumbs @($script:ActiveProfile.ProfileName, $meta.Category, $meta.Name)
    Write-Host "  $($meta.Name)" -ForegroundColor White
    Write-Host "  $($meta.Description)" -ForegroundColor DarkGray
    Write-Host ''

    $inputData = if ($meta.HasCustomInput) {
        & "Get-$($meta.Category)$($meta.Action)Input" -Token $script:SessionToken
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
            $result.Results | Format-Table -AutoSize | Out-String |
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

    if ($meta.Action -notin @('List','Get')) {
        Add-CyberArkLogSummaryEntry -ModuleName $meta.Name `
            -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
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
                    Write-CyberArkLog -Message 'Session ended — could not renew token.' -Level 'ERROR'
                    return 'Exit'
                }
                $warnShown = $false
            }
            'Warning' {
                Invoke-SelfHostedKeepalive
                Invoke-TokenRefresh | Out-Null
            }
        }

        # --- Render menu and read input ---
        Show-ActionMenu -Breadcrumbs $crumbs
        $choice = Read-MenuChoice -Prompt 'Number / [R]estart / [X]it'
        $script:LastActivityTime = Get-Date
        $warnShown = $false

        switch -Regex ($choice.ToUpper()) {

            '^X$' {
                if (Confirm-Action 'End this session and exit the script?') { return 'Exit' }
            }

            '^R$' {
                if (Confirm-Action 'Return to profile selection?') { return 'Restart' }
            }

            { $_ -match '^B\d*$' } {
                # B at the top action menu = back to profile selection
                if (Confirm-Action 'Return to profile selection?') { return 'Restart' }
            }

            '^\d+$' {
                $num   = [int]$choice
                $entry = $script:LoadedModules | Where-Object { $_.Number -eq $num } | Select-Object -First 1
                if (-not $entry) {
                    Write-Host '  Invalid selection.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                } else {
                    Invoke-ActionModule -ModuleEntry $entry
                }
            }

            default {
                if ($choice) {
                    Write-Host '  Invalid input.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                }
                # Empty input (Enter) — redraw the menu, don't reset idle timer
                $script:LastActivityTime = $script:LastActivityTime   # no-op to keep original time
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

    Write-CyberArkLog -Message "Session started. currentProfile: $selectedProfile  WhatIf: $($script:WhatIfMode)" -Level 'INFO'

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
