# CyberArk PAS Scripts — Interface Definitions

This document is the single source of truth for all shared data contracts. Any component that
produces or consumes one of these objects must match the shape defined here exactly.

---

## Token Object

Returned by `Get-AuthToken` and accepted by every API module as the `$Token` parameter.

```powershell
[PSCustomObject]@{
    Token           = [string]              # Raw bearer token or PVWA session token
    TokenType       = [string]              # 'Bearer' | 'CyberArkSession'
    Headers         = [hashtable]           # Ready-to-use HTTP headers (includes Authorization)
    Expiry          = [DateTime]            # UTC expiry time
    RefreshToken    = [string]              # OAuth2 refresh token — $null if not applicable
    SystemType      = [string]              # 'ISPSS' | 'SelfHosted'
    AuthMethod      = [string]              # 'ClientCredentials' | 'Interactive' | 'SSO' |
                                            # 'CyberArk' | 'LDAP' | 'RADIUS' | 'SAML' |
                                            # 'OIDC' | 'Shared' | 'PKI' | 'PKIPN'
    BaseURL         = [string]              # PVWA or PCloud base URL (no trailing slash)
    IdentityURL     = [string]              # ISPSS: Identity tenant URL. SelfHosted: $null
    TenantId        = [string]              # ISPSS: Identity tenant ID. SelfHosted: $null
    _RefreshContext = [hashtable]           # Internal — used by Update-AuthToken (see below)
}
```

### Headers shape by TokenType

| TokenType | Headers content |
|---|---|
| `Bearer` (ClientCredentials) | `Authorization: Bearer <token>`, `Content-Type: application/json` |
| `Bearer` (Interactive / SSO) | `Authorization: Bearer <token>`, `X-IDAP-NATIVE-CLIENT: true`, `Content-Type: application/json` |
| `CyberArkSession` | `Authorization: <token>`, `Content-Type: application/json` |

### _RefreshContext shape

All fields are optional depending on `AuthMethod`. Only fields relevant to the method are populated.

```powershell
@{
    Method                = [string]              # Same as Token.AuthMethod
    IdentityURL           = [string]
    PCloudSubdomain       = [string]
    Username              = [string]
    ClientId              = [string]
    ClientSecret          = [SecureString]        # DPAPI-protected when saved to disk
    Credential            = [PSCredential]        # DPAPI-protected when saved to disk
    Certificate           = [X509Certificate2]    # Not serialized — reloaded from store by thumbprint
    CertificateThumbprint = [string]
    ConcurrentSession     = [bool]
    IgnoreSSL             = [bool]
    PVWAUrl               = [string]
    BaseURL               = [string]
    WebView2AssemblyPath  = [string]
}
```

---

## Standard Result Object

Returned by every API module entry point (`Invoke-<Category><Action>`).
The driver reads this object to display results, write output CSVs, and update the session summary.

```powershell
[PSCustomObject]@{
    ModuleName     = [string]                                    # From $ModuleMeta.Name
    Category       = [string]                                    # From $ModuleMeta.Category
    Action         = [string]                                    # From $ModuleMeta.Action
    ItemsProcessed = [int]                                       # Total rows attempted
    Successes      = [int]                                       # Rows that succeeded
    Failures       = [int]                                       # Rows that failed
    IsFatal        = [bool]                                      # $true = abort CSV loop, return to menu
    Results        = [System.Collections.Generic.List[PSCustomObject]]  # Success items
    Errors         = [System.Collections.Generic.List[PSCustomObject]]  # Failure items
}
```

### Error item shape (added to `$result.Errors`)

```powershell
[PSCustomObject]@{
    InputData    = [hashtable]    # The input row that caused the failure
    ErrorMessage = [string]       # Human-readable summary
    ErrorDetails = [object]       # Parsed CyberArk error object, or $null
}
```

### Invariants

- `ItemsProcessed` must equal `Successes + Failures` at every return path.
- Every code path must return `$result` — including early returns on validation failure.
- `IsFatal = $true` causes the driver to break the CSV loop immediately and return to the menu.
- `Results` and `Errors` are typed lists — use `.Add()`, not `+=`.

### IsFatal conditions

| Condition | IsFatal |
|---|---|
| HTTP 401 Unauthorized | `$true` |
| Network unreachable | `$true` |
| Token refresh failed | `$true` |
| CSV schema validation failure | `$true` (set before processing begins) |
| HTTP 403 Forbidden | `$false` |
| HTTP 404 Not Found | `$false` |
| HTTP 409 Conflict | `$false` |
| Single-item validation failure | `$false` |

---

## Module Metadata Contract

Declared as `$ModuleMeta` — the first statement in every module file.
The driver reads this block during module discovery.

```powershell
$ModuleMeta = @{
    Name             = [string]     # Display name in the action menu
    Category         = [string]     # Must match the folder name under APIModules\
    Action           = [string]     # Short verb: List | Get | Add | Update | Delete | etc.
    Description      = [string]     # One-sentence description shown in the menu
    SupportedSystems = [string[]]   # @('ISPSS') | @('SelfHosted') | @('ISPSS','SelfHosted')
    SupportsWhatIf   = [bool]       # $true for any write, modify, or delete operation
    AcceptsInputFile = [bool]       # $true if the module processes CSV row input
    ProducesOutput   = [bool]       # $true if results should be offered for save-to-file
    HasCustomInput   = [bool]       # $true if Get-<Category><Action>Input is defined
    InputSchema      = [hashtable[]] # Required when AcceptsInputFile = $true (see below)
    Version          = [string]     # Semantic version: '1.0.0'
}
```

### InputSchema row shape

```powershell
@{
    Column      = [string]   # Exact CSV column header name (case-sensitive)
    Required    = [bool]     # $true = driver rejects the file if this column is absent
    Description = [string]   # Shown to the user during schema validation errors
}
```

---

## Module Entry Point Contract

### Signature

```powershell
function Invoke-<Category><Action> {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$InputData,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )
}
```

### Custom Input Function Signature (when `HasCustomInput = $true`)

```powershell
function Get-<Category><Action>Input {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$Defaults    # Pre-filled values for Copy / Edit context; may be $null
    )
    # Returns: [hashtable] with keys matching InputSchema column names
}
```

### How the driver calls a module

```powershell
# Interactive single-item mode
$inputData = if ($meta.HasCustomInput) {
    & "Get-$($meta.Category)$($meta.Action)Input" -Token $token
} else {
    Invoke-InteractiveInput -Schema $meta.InputSchema
}
$result = & "Invoke-$($meta.Category)$($meta.Action)" -Token $token -InputData $inputData -WhatIf:$whatIfMode

# CSV mode (driver loops; module called once per row)
foreach ($row in $csvRows) {
    $inputData = @{}
    foreach ($col in $row.PSObject.Properties) { $inputData[$col.Name] = $col.Value }
    $result = & "Invoke-$($meta.Category)$($meta.Action)" -Token $token -InputData $inputData -WhatIf:$whatIfMode
    if ($result.IsFatal) { break }
}
```

---

## API Response Object

Returned by `Invoke-CyberArkAPI` (from `CyberArkComms.psm1`).
Every module must check `IsSuccess` before accessing `Data`.

```powershell
[PSCustomObject]@{
    IsSuccess     = [bool]      # $true for HTTP 200-299; $false for all other codes
    StatusCode    = [int]       # Actual HTTP status code (200, 201, 400, 401, 404, 429, etc.)
    StatusMessage = [string]    # Plain-language description (e.g., 'OK', 'Not Found')
    ErrorMessage  = [string]    # $null on success; human-readable error summary on failure
    ErrorDetails  = [object]    # $null on success; parsed CyberArk error body on failure
    Data          = [object]    # Parsed response body — PSCustomObject for JSON, byte[] for Binary
    RawResponse   = [string]    # Raw response body string (always populated)
    DataType      = [string]    # 'JSON' | 'Binary' | 'File' | 'Empty'
}
```

### CyberArk error body shape (ErrorDetails)

When CyberArk returns a structured error, `ErrorDetails` contains the parsed object:

```powershell
[PSCustomObject]@{
    ErrorCode    = [string]   # CyberArk error code (e.g., 'PASWS041E')
    ErrorMessage = [string]   # Human-readable message from CyberArk
    Details      = [object]   # Additional detail fields (varies by API and error type)
}
```

---

## Driver Profile — JSON Schema

Stored at `%APPDATA%\CyberArkPAS\<ProfileName>.json` (default location).
Non-sensitive settings only. Human-readable without decryption.

```json
{
    "ProfileName":      "Production",
    "AuthTokenProfile": "Production",
    "SystemType":       "Privilege Cloud",
    "AppName":          "PasswordVault",
    "AuthMethod":       "ClientCredentials",
    "BaseURL":          "https://acme.privilegecloud.cyberark.cloud",
    "LogFolder":        "",
    "InputFolder":      "",
    "OutputFolder":     "",
    "IgnoreSSL":        false,
    "ParallelThreads":  1,
    "WhatIfDefault":    false,
    "LastUsed":         "2026-01-15T14:32:01Z",
    "Created":          "2026-01-01T09:00:00Z",
    "Modified":         "2026-01-15T14:32:01Z"
}
```

### Field reference

| Field | Type | Description |
|---|---|---|
| `ProfileName` | string | Display name. Also used to derive file names. |
| `AuthTokenProfile` | string | Name portion of the corresponding `.cred` auth token file. Usually identical to `ProfileName`. |
| `SystemType` | string | `Privilege Cloud` (SaaS / ISPSS) or `Self-Hosted` (on-premises PVWA). Drives the Base URL prompt and maps to the auth script's `ISPSS` / `SelfHosted` parameter values. |
| `AppName` | string | CyberArk application name used in the URL path. Default: `PasswordVault`. Joined with `BaseURL` when making API calls: `https://pvwa.company.com/PasswordVault`. |
| `AuthMethod` | string | Preferred authentication method for this profile. Set during profile creation; passed directly to `Get-AuthToken` to skip the interactive method prompt. |
| `BaseURL` | string | Base URL without application path. For Privilege Cloud: `https://<subdomain>.privilegecloud.cyberark.cloud`. For Self-Hosted: `https://pvwa.company.com`. No trailing slash. |
| `LogFolder` | string | Absolute path. Empty string resolves to the script launch directory at runtime. |
| `InputFolder` | string | Default folder for open-file dialogs. Empty = launch directory. |
| `OutputFolder` | string | Destination for output CSVs and save-file dialogs. Empty = launch directory. |
| `IgnoreSSL` | bool | Bypasses SSL certificate validation for all API calls in this profile. |
| `ParallelThreads` | int | Reserved. Currently always 1 (sequential processing). |
| `WhatIfDefault` | bool | When `true`, WhatIf mode is active by default for this profile. |
| `LastUsed` | ISO 8601 UTC | Updated each time the profile is selected. |
| `Created` | ISO 8601 UTC | Set once at profile creation. |
| `Modified` | ISO 8601 UTC | Updated whenever any profile field changes. |

### SystemType → BaseURL prompt mapping

| `SystemType` value | Edit-flow prompt | `BaseURL` format stored |
|---|---|---|
| `Privilege Cloud` | Asks for the tenant **subdomain** (e.g. `acme`). URL is constructed automatically. | `https://<subdomain>.privilegecloud.cyberark.cloud` |
| `Self-Hosted` | Asks for the full **PVWA base URL** directly. Trailing slash is stripped on save. | `https://pvwa.company.com` |

When calling `Get-AuthToken`, the driver maps these values back to the auth script's parameter set:
- `Privilege Cloud` → `-SystemType ISPSS -PCloudSubdomain <subdomain> [-AuthMethod <method>]`
- `Self-Hosted` → `-SystemType SelfHosted -PVWAUrl <BaseURL>/<AppName> [-AuthMethod <method>]`

`AppName` is always joined to `BaseURL` when constructing `PVWAUrl` for Self-Hosted calls (e.g. `https://pvwa.company.com/PasswordVault`). For Privilege Cloud, the driver patches `token.BaseURL` after auth to include `AppName` for downstream API calls.

---

## Auth Token File — Serialized Shape

Stored at `%APPDATA%\CyberArkPAS\<ProfileName>.cred` by `Save-AuthToken` via `Export-Clixml`.
DPAPI-encrypted fields are marked below.

| Field | Type | DPAPI? | Description |
|---|---|---|---|
| `ProfileName` | string | No | Profile display name |
| `TokenSecure` | SecureString | **Yes** | The bearer / session token |
| `TokenType` | string | No | `Bearer` or `CyberArkSession` |
| `Expiry` | DateTime | No | UTC token expiry |
| `RefreshTokenSecure` | SecureString | **Yes** | OAuth2 refresh token (`$null` if none) |
| `SystemType` | string | No | `ISPSS` or `SelfHosted` |
| `AuthMethod` | string | No | Auth method used |
| `BaseURL` | string | No | PVWA or PCloud base URL |
| `IdentityURL` | string | No | Identity tenant URL (ISPSS only) |
| `TenantId` | string | No | Identity tenant ID (ISPSS only) |
| `SavedAt` | DateTime | No | UTC timestamp when file was written |
| `RefreshContext.ClientSecret` | SecureString | **Yes** | OAuth2 client secret |
| `RefreshContext.Credential` | PSCredential | **Yes** | Username + password |
| `RefreshContext.CertificateThumbprint` | string | No | Cert thumbprint (cert reloaded from store on import) |
| All other RefreshContext fields | string / bool | No | Connection parameters |

---

## Output CSV — Appended Columns

When the driver writes an output CSV from a module run, it copies all original input columns and
appends two new columns at the right.

| Column | Type | Description |
|---|---|---|
| `IsSuccess` | bool (`True` / `False`) | Whether the operation succeeded for this row |
| `Summary` | string | Success: brief description of what was created/changed. Failure: `ErrorMessage` value. |

**File naming:** `<OriginalFileName>_<yyyy-MM-dd>_output.csv`
**Location:** Profile `OutputFolder` (or launch directory if not configured).

---

## Log Entry Format

```
PID   | yyyy-MM-dd HH:mm:ss | LEVEL   | FunctionName         | Message
```

- All fields left-padded / centered to constant width before the pipe separator.
- `PID` field width: 7 characters, right-aligned.
- `Timestamp` field width: 19 characters.
- `LEVEL` field width: 7 characters, centered: `VERBOSE`, ` DEBUG `, ` INFO  `, ` WARN  `, ` ERROR `.
- `FunctionName` field width: 24 characters, left-aligned, truncated with `…` if longer.
- `Message`: remainder of line, no width limit.

**Startup block:**
```
****************************************
  PID 12345 | 2026-01-15 09:00:00 | Profile: Production | ISPSS | ClientCredentials
```

**Session summary block (end of session, write/modify ops only):**
```
----------------------------------------
  Session Summary
  Operations logged: 3
  Total items:       150
  Successes:         148
  Failures:          2
----------------------------------------
```

**Bare mode:** Message only — no PID, timestamp, level, or function name prefix.

---

## Script-Level Configuration Variables

Defined in the driver or shared modules. Override before launching for non-default behavior.

| Variable | Default | Description |
|---|---|---|
| `$script:TokenExpiryWarningMinutes` | `5` | Minutes remaining before prompting user to re-authenticate |
| `$script:MaxRateLimitRetries` | `5` | Max consecutive 429 responses before failing the call |
| `$script:RateLimitBaseDelaySec` | `2` | Initial backoff delay in seconds (doubles each retry) |
| `$script:PVWA_SESSION_EXPIRY_MIN` | `20` | Expected Self-Hosted session lifetime in minutes |
| `$script:WEBVIEW2_TIMEOUT_SEC` | `300` | Max seconds to wait for browser-based auth completion |
| `$script:CLIENT_AUTH_OID` | `1.3.6.1.5.5.7.3.2` | OID for Client Authentication EKU (PKI cert filtering) |
