#Requires -Version 5.1
<#
.SYNOPSIS
    Shared REST communications module for CyberArk PAS Scripts.

.DESCRIPTION
    Provides Invoke-CyberArkAPI and supporting helpers used by all API modules and the driver.
    Handles:
      - HTTP request execution with proper headers from the token object
      - Transparent pagination (all pages fetched and combined)
      - Rate limiting with exponential backoff (HTTP 429)
      - WhatIf blocking (POST/PUT/PATCH/DELETE suppressed; synthetic success returned)
      - Response normalization into a standard API response object
      - URL joining and CyberArk query string building
      - IgnoreSSL bypass (scoped to the call; set per profile)
#>

Set-StrictMode -Version Latest

#region --- Module State ---

$script:MaxRateLimitRetries  = 5
$script:RateLimitBaseDelaySec = 2

# HTTP 504 Gateway Timeout retry - fixed delay (not exponential backoff like 429),
# and the page size is reduced by 25% on each retry when pagination is in use.
$script:MaxGatewayTimeoutRetries = 2
$script:GatewayTimeoutDelaySec   = 5

#endregion

#region --- Internal Helpers ---

function script:Get-StatusMessage {
    param([int]$Code)
    $map = @{
        200 = 'OK'; 201 = 'Created'; 202 = 'Accepted'; 204 = 'No Content'
        400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'
        404 = 'Not Found'; 405 = 'Method Not Allowed'; 408 = 'Request Timeout'
        409 = 'Conflict'; 429 = 'Too Many Requests'
        500 = 'Internal Server Error'; 502 = 'Bad Gateway'; 503 = 'Service Unavailable'
        504 = 'Gateway Timeout'
    }
    if ($map.ContainsKey($Code)) { return $map[$Code] } else { return "HTTP $Code" }
}

function script:New-ApiResponse {
    param(
        [bool]  $IsSuccess,
        [int]   $StatusCode,
        [string]$RawResponse  = '',
        [object]$Data         = $null,
        [string]$DataType     = 'Empty',
        [string]$ErrorMessage = $null,
        [object]$ErrorDetails = $null
    )
    return [PSCustomObject]@{
        IsSuccess     = $IsSuccess
        StatusCode    = $StatusCode
        StatusMessage = script:Get-StatusMessage -Code $StatusCode
        ErrorMessage  = $ErrorMessage
        ErrorDetails  = $ErrorDetails
        Data          = $Data
        RawResponse   = $RawResponse
        DataType      = $DataType
    }
}

function script:Parse-CyberArkError {
    param([string]$Body)
    if (-not $Body) { return $null }
    try {
        $parsed = $Body | ConvertFrom-Json
        return [PSCustomObject]@{
            ErrorCode    = $parsed.ErrorCode
            ErrorMessage = $parsed.ErrorMessage
            Details      = $parsed
        }
    } catch {
        return $null
    }
}

function script:New-WhatIfResponse {
    param([string]$Method, [string]$Uri)
    $msg = "[WhatIf] $Method $Uri - request suppressed, no changes made."
    if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
        Write-CyberArkLog -Message $msg -Level 'INFO' -FunctionName 'Invoke-CyberArkAPI'
    }
    return script:New-ApiResponse -IsSuccess $true -StatusCode 200 -DataType 'Empty' `
        -RawResponse '' -Data $null
}

function script:Disable-SSLValidation {
    # Only effective within the current AppDomain. Cannot be undone per-call cleanly in PS 5.1;
    # IgnoreSSL is therefore session-wide once set (matching profile-level scoping intent).
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
        Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint sp, X509Certificate cert,
        WebRequest req, int error) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
    [System.Net.ServicePointManager]::SecurityProtocol  =
        [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
}

#endregion

#region --- Query Helpers ---

function New-CyberArkQuery {
    <#
    .SYNOPSIS
        Builds a URL query string from a hashtable of CyberArk query parameters.
    .PARAMETER Params
        Hashtable of parameter names and values. Null/empty values are omitted.
    .OUTPUTS
        String - a query string including the leading '?' or empty string if no params.
    .EXAMPLE
        New-CyberArkQuery @{ search = 'vault'; filter = 'safeName eq MyVault'; limit = 25 }
        # Returns: ?search=vault&filter=safeName+eq+MyVault&limit=25
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Params
    )

    $parts = foreach ($key in $Params.Keys) {
        $val = $Params[$key]
        if ($null -ne $val -and "$val" -ne '') {
            "$([Uri]::EscapeDataString($key))=$([Uri]::EscapeDataString("$val"))"
        }
    }

    $joined = $parts -join '&'
    if ($joined) { return "?$joined" } else { return '' }
}

function Join-CyberArkUrl {
    <#
    .SYNOPSIS
        Joins a base URL and one or more path segments with correct slash handling.
    .PARAMETER Base
        The base URL (e.g. 'https://cyberark.example.com').
    .PARAMETER Segments
        One or more path segments to append (leading and trailing slashes are trimmed).
    .EXAMPLE
        Join-CyberArkUrl -Base 'https://host.example.com/' -Segments '/API/', '/Safes'
        # Returns: https://host.example.com/API/Safes
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Base,

        [Parameter(Mandatory = $true)]
        [string[]]$Segments
    )

    $result = $Base.TrimEnd('/')
    foreach ($seg in $Segments) {
        $result = $result.TrimEnd('/') + '/' + $seg.Trim('/')
    }
    # A dot in the last path segment is misread as a file extension by some proxies/servers.
    # Appending a trailing slash signals it is a path, not a file.
    if ($result.Split('/')[-1] -match '\.') { $result += '/' }
    return $result
}

function New-CyberArkSearchFilter {
    <#
    .SYNOPSIS
        Builds a CyberArk filter expression string from simple key=value pairs.
    .PARAMETER Criteria
        Hashtable of field names and values. Values containing spaces are quoted.
    .PARAMETER Operator
        Logical operator joining multiple criteria. Default: 'AND'.
    .EXAMPLE
        New-CyberArkSearchFilter @{ safeName = 'MyVault'; userName = 'svc-account' }
        # Returns: safeName eq MyVault AND userName eq svc-account
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Criteria,

        [string]$Operator = 'AND'
    )

    $parts = foreach ($key in $Criteria.Keys) {
        $val = $Criteria[$key]
        if ($val -match '\s') { $val = "`"$val`"" }
        "$key eq $val"
    }
    return $parts -join " $Operator "
}

#endregion

#region --- Core API Function ---

function Invoke-CyberArkAPI {
    <#
    .SYNOPSIS
        Executes a CyberArk REST API call and returns a normalized response object.

    .DESCRIPTION
        Handles:
          - Header injection from the Token object
          - JSON body serialization
          - WhatIf suppression (POST/PUT/PATCH/DELETE)
          - Transparent pagination (fetches all pages, returns combined value array)
          - Rate limiting with exponential backoff
          - IgnoreSSL bypass
          - Response normalization into the standard API response shape

    .PARAMETER Token
        The token object from Get-AuthToken. Provides Headers and BaseURL.

    .PARAMETER Method
        HTTP method: GET, POST, PUT, PATCH, DELETE. Default: GET.

    .PARAMETER Endpoint
        Relative path from BaseURL (e.g. '/API/Safes'). Leading slash is optional.

    .PARAMETER Uri
        Full absolute URI. Use instead of Endpoint when the URL is already fully built.

    .PARAMETER Body
        Request body. Hashtable/PSCustomObject is serialized to JSON automatically.
        String values are sent as-is.

    .PARAMETER QueryParams
        Hashtable of query parameters. Appended to the URL.

    .PARAMETER WhatIf
        Suppresses POST/PUT/PATCH/DELETE calls. Returns a synthetic 200 success response.

    .PARAMETER IgnoreSSL
        Bypasses SSL certificate validation. Should match the profile setting.

    .PARAMETER PageSizeParam
        Query parameter name used to set the page size (e.g. 'limit'). Default: 'limit'.

    .PARAMETER PageOffsetParam
        Query parameter name used to set the page offset (e.g. 'offset'). Default: 'offset'.

    .PARAMETER PageSize
        Number of items per page. Default: 1000. Set to 0 to disable pagination.

    .OUTPUTS
        PSCustomObject - standard API response object (see Interfaces.md).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [ValidateSet('GET','POST','PUT','PATCH','DELETE')]
        [string]$Method = 'GET',

        [string]$Endpoint,
        [string]$Uri,

        [object]$Body,

        [hashtable]$QueryParams,

        [switch]$WhatIf,

        [switch]$IgnoreSSL,

        [string]$PageSizeParam   = 'limit',
        [string]$PageOffsetParam = 'offset',
        [int]   $PageSize        = 1000
    )

    # --- Resolve full URI ---
    if (-not $Uri) {
        if (-not $Endpoint) { throw "Either -Endpoint or -Uri must be supplied." }
        $Uri = Join-CyberArkUrl -Base $Token.BaseURL -Segments @($Endpoint)
        # Join-CyberArkUrl always trims a trailing slash off the joined result (by design -
        # see CyberArkComms.Tests.ps1 C12). Some endpoints require the trailing slash to be
        # preserved (the legacy PIMServices.svc WCF REST service used by every Applications
        # module rejects/misroutes requests without it - see Lessons-Learned-PowerShell-Pester.md
        # Section 28/Documentation-Tracker.md 2026-08-16 for the history of this exact endpoint
        # losing its trailing slash). Restore it here, at the call site, based on the caller's
        # own explicit -Endpoint string, rather than changing Join-CyberArkUrl's generic contract.
        if ($Endpoint.EndsWith('/') -and -not $Uri.EndsWith('/')) { $Uri += '/' }
    }

    # --- WhatIf blocking ---
    if ($WhatIf -and $Method -in 'POST','PUT','PATCH','DELETE') {
        return script:New-WhatIfResponse -Method $Method -Uri $Uri
    }

    # --- SSL bypass (session-wide once applied) ---
    if ($IgnoreSSL) { script:Disable-SSLValidation }

    # --- Build headers ---
    $headers = @{}
    foreach ($key in $Token.Headers.Keys) { $headers[$key] = $Token.Headers[$key] }

    # --- Serialize body ---
    # ConvertTo-Json must receive $Body via -InputObject, not the pipeline: piping a single-
    # element array unrolls it to its lone element first, so ConvertTo-Json serializes that
    # element bare instead of wrapping it in `[ ]` - silently corrupting single-op JSON Patch
    # bodies (and any other single-element array body) into a bare object.
    $bodyString = $null
    if ($Body) {
        $bodyString = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
    }

    # --- Profile page size override (PageSize on token, 0 = use parameter default) ---
    # Controls records requested per paginated call only — does not cap total results.
    $profilePageSize   = 0
    if ($Token.PSObject.Properties['PageSize']) {
        try { $profilePageSize = [int]$Token.PageSize } catch { }
    }
    $effectivePageSize = if ($profilePageSize -gt 0) { $profilePageSize } else { $PageSize }

    # --- Pagination state ---
    $allItems      = [System.Collections.Generic.List[object]]::new()
    # PIMServices.svc (legacy WCF REST) does not accept offset/limit pagination params
    $paginate      = ($Method -eq 'GET' -and $effectivePageSize -gt 0 -and $Uri -notlike '*/PIMServices.svc/*')
    $offset        = 0
    $firstPage     = $true
    $lastResponse  = $null
    $pageNum       = 1
    $progressShown = $false

    # --- Rate limit / retry state ---
    $retryCount             = 0
    $gatewayTimeoutRetryCount = 0

    do {
        # Build query string for this page
        $qParams = if ($QueryParams) { [hashtable]$QueryParams.Clone() } else { @{} }
        if ($paginate) {
            $qParams[$PageSizeParam]   = $effectivePageSize
            $qParams[$PageOffsetParam] = $offset
        }
        $query   = New-CyberArkQuery -Params $qParams
        $fullUri = "$Uri$query"

        if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
            Write-CyberArkLog -Message "$Method $fullUri" -Level 'DEBUG' -FunctionName 'Invoke-CyberArkAPI'
            if ($bodyString -and $Method -in 'POST','PUT','PATCH') {
                Write-CyberArkLog -Message "Request body: $bodyString" -Level 'DEBUG' -FunctionName 'Invoke-CyberArkAPI' -FileOnly
            }
        }

        # --- Execute request ---
        try {
            $iwrParams = @{
                Uri             = $fullUri
                Method          = $Method
                Headers         = $headers
                UseBasicParsing = $true
                ErrorAction     = 'Stop'
            }
            if ($bodyString) {
                $iwrParams['Body']        = $bodyString
                $iwrParams['ContentType'] = 'application/json'
            }

            $response    = Invoke-WebRequest @iwrParams
            $retryCount  = 0   # reset on success
            $gatewayTimeoutRetryCount = 0
            $statusCode  = [int]$response.StatusCode
            $rawBody     = $response.Content

        } catch [System.Net.WebException] {
            $webEx      = $_.Exception
            $webResp    = $webEx.Response -as [System.Net.HttpWebResponse]
            $statusCode = if ($webResp) { [int]$webResp.StatusCode } else { 0 }
            $rawBody    = ''
            if ($webResp) {
                try {
                    $reader  = [System.IO.StreamReader]::new($webResp.GetResponseStream())
                    $rawBody = $reader.ReadToEnd()
                    $reader.Dispose()
                } catch {}
            }

            # --- Rate limiting ---
            if ($statusCode -eq 429) {
                $retryCount++
                if ($retryCount -gt $script:MaxRateLimitRetries) {
                    $msg = "Rate limit exceeded after $($script:MaxRateLimitRetries) retries. Giving up."
                    if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
                        Write-CyberArkLog -Message $msg -Level 'ERROR' -FunctionName 'Invoke-CyberArkAPI'
                    }
                    if ($progressShown) { Write-Progress -Activity 'Fetching results' -Completed -Id 1 }
                    return script:New-ApiResponse -IsSuccess $false -StatusCode 429 `
                        -RawResponse $rawBody -ErrorMessage $msg
                }

                $delaySec = $script:RateLimitBaseDelaySec * [Math]::Pow(2, $retryCount - 1)
                $warnMsg  = "HTTP 429 rate limit (attempt $retryCount/$($script:MaxRateLimitRetries)). Backing off $([int]$delaySec)s..."
                if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
                    Write-CyberArkLog -Message $warnMsg -Level 'WARN' -FunctionName 'Invoke-CyberArkAPI'
                }
                Start-Sleep -Seconds ([int]$delaySec)
                continue
            }

            # --- Gateway timeout retry ---
            if ($statusCode -eq 504) {
                $gatewayTimeoutRetryCount++
                if ($gatewayTimeoutRetryCount -gt $script:MaxGatewayTimeoutRetries) {
                    $msg = "Gateway timeout (504) persisted after $($script:MaxGatewayTimeoutRetries) retries. Giving up."
                    if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
                        Write-CyberArkLog -Message $msg -Level 'ERROR' -FunctionName 'Invoke-CyberArkAPI'
                    }
                    if ($progressShown) { Write-Progress -Activity 'Fetching results' -Completed -Id 1 }
                    return script:New-ApiResponse -IsSuccess $false -StatusCode 504 `
                        -RawResponse $rawBody -ErrorMessage $msg
                }

                # If a page-size limit is in use for this call, reduce it by 25% before retrying -
                # a smaller page is less likely to time out again. Same $offset is retried (this
                # page never succeeded), so no items are skipped or duplicated.
                if ($paginate -and $effectivePageSize -gt 1) {
                    $reducedPageSize = [int][Math]::Floor($effectivePageSize * 0.75)
                    if ($reducedPageSize -lt 1) { $reducedPageSize = 1 }
                    $warnMsg = "HTTP 504 gateway timeout (attempt $gatewayTimeoutRetryCount/$($script:MaxGatewayTimeoutRetries)). Reducing page size $effectivePageSize -> $reducedPageSize and retrying in $($script:GatewayTimeoutDelaySec)s..."
                    $effectivePageSize = $reducedPageSize
                } else {
                    $warnMsg = "HTTP 504 gateway timeout (attempt $gatewayTimeoutRetryCount/$($script:MaxGatewayTimeoutRetries)). Retrying in $($script:GatewayTimeoutDelaySec)s..."
                }
                if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
                    Write-CyberArkLog -Message $warnMsg -Level 'WARN' -FunctionName 'Invoke-CyberArkAPI'
                }
                Start-Sleep -Seconds $script:GatewayTimeoutDelaySec
                continue
            }

            # Non-429/504 HTTP error - fall through to response building below
            $errDetails = script:Parse-CyberArkError -Body $rawBody
            $errMsg     = if ($errDetails) { $errDetails.ErrorMessage } else { "HTTP $statusCode $($webEx.Message)" }
            if ($statusCode -ge 400) { $errMsg = "$errMsg  [$Method $fullUri]" }
            if ($rawBody -and (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue)) {
                Write-CyberArkLog -Message "HTTP $statusCode response body: $rawBody" -Level 'DEBUG' -FunctionName 'Invoke-CyberArkAPI' -FileOnly
            }
            if ($progressShown) { Write-Progress -Activity 'Fetching results' -Completed -Id 1 }
            return script:New-ApiResponse -IsSuccess $false -StatusCode $statusCode `
                -RawResponse $rawBody -ErrorMessage $errMsg -ErrorDetails $errDetails

        } catch {
            $caughtErr = $_
            $msg = "Unexpected error calling $fullUri : $caughtErr"
            if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
                Write-CyberArkLog -Message $msg -Level 'ERROR' -FunctionName 'Invoke-CyberArkAPI'
            }
            if ($progressShown) { Write-Progress -Activity 'Fetching results' -Completed -Id 1 }
            return script:New-ApiResponse -IsSuccess $false -StatusCode 0 -ErrorMessage $msg
        }

        # --- Parse response body ---
        $dataType = 'Empty'
        $data     = $null

        if ($rawBody) {
            try {
                $data     = $rawBody | ConvertFrom-Json
                $dataType = 'JSON'
            } catch {
                # Not JSON - treat as binary/file content
                $data     = $rawBody
                $dataType = 'Binary'
            }
        }

        $isSuccess = ($statusCode -ge 200 -and $statusCode -le 299)

        # --- Accumulate paginated items ---
        if ($paginate -and $isSuccess -and $data) {
            # CyberArk typically returns { value: [...], count: N, nextLink: "..." }
            # or { Safes: [...] } etc. Try common collection property names.
            $collection = $null
            foreach ($prop in @('value','Safes','Members','Accounts','Users','Platforms','Groups')) {
                if ($data.PSObject.Properties[$prop]) {
                    $collection = $data.$prop
                    break
                }
            }

            if ($null -ne $collection) {
                foreach ($item in $collection) { $allItems.Add($item) }

                # Check for nextLink (ISPSS uses OData-style pagination)
                $hasNextLink    = $data.PSObject.Properties['nextLink'] -and $data.nextLink
                # Also check count-based: if we got a full page, there may be more
                $hasMoreByCount = ($collection.Count -eq $effectivePageSize)

                if ($hasNextLink -or $hasMoreByCount) {
                    $offset   += $effectivePageSize
                    $firstPage = $false
                    $pageNum++
                    Write-Progress -Activity 'Fetching results' -Status "Page $pageNum — $($allItems.Count) items retrieved" -Id 1
                    $progressShown = $true
                    $lastResponse = [PSCustomObject]@{
                        IsSuccess = $isSuccess; StatusCode = $statusCode; RawResponse = $rawBody
                        Data = $data; DataType = $dataType
                    }
                    continue
                }
            }
        }

        # --- Single-page or final page - build the response ---
        if ($paginate -and $allItems.Count -gt 0) {
            # Merge all accumulated items back onto the last data object
            # Use the first property that held the collection
            $mergedData = if ($null -ne $data) { $data } else { [PSCustomObject]@{} }
            foreach ($prop in @('value','Safes','Members','Accounts','Users','Platforms','Groups')) {
                if ($mergedData.PSObject.Properties[$prop]) {
                    $mergedData.$prop = $allItems.ToArray()
                    break
                }
            }
            $data = $mergedData
        }

        if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
            $itemsNote = if ($allItems.Count -gt 0) { "$($allItems.Count) total items (paginated)" } else { $dataType }
            $logMsg = "Response $statusCode - $itemsNote"
            Write-CyberArkLog -Message $logMsg -Level 'DEBUG' -FunctionName 'Invoke-CyberArkAPI'
        }

        $errDetails = $null
        $errMsg     = $null
        if (-not $isSuccess) {
            $errDetails = script:Parse-CyberArkError -Body $rawBody
            $errMsg     = if ($errDetails) { $errDetails.ErrorMessage } else { "HTTP $statusCode" }
        }

        if ($progressShown) { Write-Progress -Activity 'Fetching results' -Completed -Id 1 }
        return script:New-ApiResponse -IsSuccess $isSuccess -StatusCode $statusCode `
            -RawResponse $rawBody -Data $data -DataType $dataType `
            -ErrorMessage $errMsg -ErrorDetails $errDetails

    } while ($true)
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-CyberArkAPI'
    'New-CyberArkQuery'
    'Join-CyberArkUrl'
    'New-CyberArkSearchFilter'
)
