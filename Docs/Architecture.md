# CyberArk PAS Scripts — Architecture Overview

## Purpose

A PowerShell-based driver for interacting with CyberArk Privilege Access Security (PAS) REST APIs
across both ISPSS (Privilege Cloud SaaS) and Self-Hosted PAM deployments. The system provides
profile-managed, authenticated sessions, a categorized interactive action menu, robust logging,
and a pluggable API module system that allows new API operations to be added without modifying
the driver.

---

## Build Status

| Component | Status |
|---|---|
| `Get-AuthToken.ps1` | Complete |
| `CyberArkLogging.psm1` | Planned |
| `CyberArkComms.psm1` | Planned |
| `Driver.ps1` | Planned |
| API Modules | Planned |

---

## Component Diagram

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                          Driver.ps1                               │
  │                                                                   │
  │  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────┐  │
  │  │    Profile      │  │    Session       │  │  Module Loader  │  │
  │  │   Management   │  │    Lifecycle     │  │  Action Menu    │  │
  │  └────────┬────────┘  └────────┬─────────┘  └────────┬────────┘  │
  └───────────┼────────────────────┼────────────────────┼────────────┘
              │                    │                     │
              ▼                    ▼                     ▼
  ┌───────────────────┐  ┌─────────────────┐  ┌─────────────────────┐
  │   Profile Files   │  │ Get-AuthToken   │  │    API Modules      │
  │  <Name>.json      │  │     .ps1        │  │  APIModules\<Cat>\  │
  │  <Name>.xml       │  │                 │  │  Invoke-<Cat><Act>  │
  └───────────────────┘  └─────────────────┘  └──────────┬──────────┘
                                                           │
                    ┌──────────────────────────────────────┘
                    ▼
       ┌────────────────────────┐     ┌──────────────────────────┐
       │   CyberArkComms.psm1  │     │  CyberArkLogging.psm1    │
       │   (Shared Comms)      │     │  (Logging)               │
       └────────────┬───────────┘     └──────────────────────────┘
                    │                         ▲
                    │            used by all components
                    ▼
       ┌────────────────────────┐
       │   CyberArk REST API   │
       │  ISPSS / Self-Hosted  │
       └────────────────────────┘
```

---

## Folder Structure

```
PowerShell\
├── Driver.ps1                          # Interactive driver script
├── ISPSS Scripts\
│   └── Get-AuthToken.ps1               # Authentication — ISPSS and Self-Hosted
├── Modules\
│   ├── CyberArkComms.psm1              # Shared REST communications module
│   ├── CyberArkLogging.psm1            # Logging module
│   ├── CyberArk_Driver_REST.psm1       # Legacy — superseded by CyberArkComms
│   └── Credential.psm1                 # Existing credential helper
├── APIModules\
│   ├── Accounts\
│   │   ├── Invoke-AccountsList.ps1
│   │   ├── Invoke-AccountsGet.ps1
│   │   ├── Invoke-AccountsAdd.ps1
│   │   ├── Invoke-AccountsUpdate.ps1
│   │   ├── Invoke-AccountsDelete.ps1
│   │   └── Invoke-AccountsGetCredential.ps1
│   ├── Safes\
│   │   ├── Invoke-SafesList.ps1
│   │   ├── Invoke-SafesGet.ps1
│   │   ├── Invoke-SafesAdd.ps1
│   │   ├── Invoke-SafesUpdate.ps1
│   │   └── Invoke-SafesDelete.ps1
│   ├── SafeMembers\
│   │   ├── Invoke-SafeMembersList.ps1
│   │   ├── Invoke-SafeMembersAdd.ps1
│   │   ├── Invoke-SafeMembersUpdate.ps1
│   │   └── Invoke-SafeMembersRemove.ps1
│   ├── Platforms\
│   │   ├── Invoke-PlatformsList.ps1
│   │   └── Invoke-PlatformsGet.ps1
│   └── Users\
│       ├── Invoke-UsersList.ps1
│       └── Invoke-UsersGet.ps1
├── Profiles\                           # Created at runtime (default: %APPDATA%\CyberArkPAS\)
│   ├── Production.json
│   ├── Production.xml
│   ├── Development.json
│   └── Development.xml
└── Docs\
    ├── Architecture.md                 # This document
    ├── Interfaces.md
    ├── API-Module-Development-Guide.md
    ├── SharedComms-Reference.md
    ├── Logging-Reference.md
    ├── Profile-Schema.md
    ├── Driver-Reference.md
    ├── Installation.md
    ├── Troubleshooting.md
    ├── API-Coverage-Matrix.md
    └── Documentation-Tracker.md
```

---

## Data Flow

### 1. Startup

```
Driver.ps1 launched
  └─ Check prerequisites (PS version, WebView2 if needed)
  └─ Import CyberArkLogging.psm1
  └─ Import CyberArkComms.psm1
  └─ Initialize log (PID assigned, file created with 40-star header)
  └─ Scan profile directory → display profile summary
```

### 2. Profile Selection and Authentication

```
User selects / creates / edits profile
  └─ Load <ProfileName>.json (driver settings)
  └─ Validate profile (folders accessible, auth file present)
  └─ Load <ProfileName>.xml via Import-AuthToken (DPAPI decrypt)
  └─ Check token expiry
       ├─ Valid         → proceed to session
       ├─ Expiring soon → ask user: refresh now or proceed?
       └─ Expired       → auto-refresh (ClientCredentials)
                          or prompt re-auth (Interactive / SSO / SAML / OIDC)
  └─ Re-initialize log with profile name in filename
  └─ Log session start: profile, SystemType, AuthMethod, BaseURL, WhatIf mode
```

### 3. Main Action Loop

```
Display breadcrumb header  (e.g.  [Production] > Accounts)
Display categorized action menu
User enters choice (number) or navigation (B / B2 / B3)
  ├─ Navigation → update breadcrumb, redisplay menu
  └─ Action selected
       └─ Check token expiry (warn if < TokenExpiryWarningMinutes remaining)
       └─ Collect input
            ├─ Interactive  → driver prompts from InputSchema
            │                  or calls Get-<Category><Action>Input if HasCustomInput
            └─ CSV file(s)  → user selects via open-file dialog
                              driver validates schema against InputSchema
       └─ Invoke-<Category><Action> -Token $token -InputData $row -WhatIf:$mode
       └─ Display results (table)
       └─ Offer save to file (default: No)
            └─ Yes → save-file dialog → output folder default → write CSV
       └─ Return to menu
```

### 4. CSV Processing (driver loop)

```
For each selected input CSV file:
  └─ Validate columns against module InputSchema
       └─ Missing required column → skip file with WARN log
  └─ Prepare output CSV path: <OutputFolder>\<original>_<yyyy-MM-dd>_output.csv
  └─ For each row in CSV:
       └─ Check token expiry
       └─ Call module entry point with row as InputData
       └─ Append IsSuccess, Summary columns to output CSV
       └─ If result.IsFatal → break loop, return to menu
  └─ Log per-file summary (ItemsProcessed / Successes / Failures)
```

### 5. Session End

```
User selects Exit or Restart
  └─ Self-Hosted: POST /API/auth/Logoff
  └─ Log session summary (all write/modify operations: total / success / failures)
  └─ Save refreshed token back to profile (if token was renewed during session)
  └─ Restart → return to profile selection with current profile as default
     Exit    → script terminates
```

---

## Component Descriptions

### Driver.ps1

The top-level interactive script. Owns:
- Profile management (create, edit, copy, delete, use, detail view, test connection)
- Session lifecycle (auth, token expiry monitoring, Self-Hosted keepalive, logoff)
- Module discovery (scans `APIModules\` at session start, builds action menu)
- CSV looping (driver loops over rows; modules handle one row at a time)
- Output file handling (save dialogs, output CSV column appending)
- Session summary logging at exit

### Get-AuthToken.ps1

Standalone authentication script. Called by the driver to obtain or refresh tokens. Returns a rich
token object with everything needed for subsequent API calls. Also exports `Save-AuthToken`,
`Import-AuthToken`, `Get-AuthTokenProfiles`, and `Remove-AuthTokenProfile` for profile management.
See [Interfaces.md](Interfaces.md) for the token object shape.

### CyberArkComms.psm1

The shared REST communications layer. All API calls from the driver and every API module go
through this module. Responsibilities:
- Building and executing HTTP requests against ISPSS or Self-Hosted endpoints
- Transparent pagination (fetches all pages, returns combined result)
- Rate limiting with exponential backoff (logs WARN; fails after `$script:MaxRateLimitRetries`)
- WhatIf blocking (suppresses POST/PUT/PATCH/DELETE; returns synthetic success response)
- Normalizing all responses into the standard response object
- URL joining and query string building helpers

### CyberArkLogging.psm1

Logging module used by all components. Responsibilities:
- Writing formatted log entries to file and/or console
- Enforcing the log format: `PID | yyyy-MM-dd HH:mm:ss | LEVEL   | FunctionName | Message`
- Supporting log levels: VERBOSE, DEBUG, INFO, WARN, ERROR
- Bare mode (message only, no prefix)
- Startup block (40-star line + session header)
- Sensitive data masking
- Log file cleanup by age

### API Modules (`APIModules\<Category>\Invoke-<Category><Action>.ps1`)

Each file implements one CyberArk API action. Auto-discovered by the driver at session start.
Every module declares a `$ModuleMeta` hashtable and exports one entry-point function
(`Invoke-<Category><Action>`). The driver calls the entry point; the module returns a standard
result object. See [API-Module-Development-Guide.md](API-Module-Development-Guide.md).

---

## Design Decisions

| Decision | Choice | Reason |
|---|---|---|
| Profile storage | Two files: JSON + DPAPI XML | JSON for non-sensitive settings (readable without decryption); XML for credentials (DPAPI-protected). Keeps profile listing fast. |
| Credential protection | `Export-Clixml` (DPAPI) | Native PowerShell, no external dependencies. User+machine locked — deliberate trade-off for security over portability. |
| Token string protection | Convert to `SecureString` before `Export-Clixml` | Ensures the bearer token is DPAPI-encrypted in the XML, not stored as plaintext. |
| Browser-based auth | WebView2 over IE `WebBrowser` | IE-based `Windows.Forms.WebBrowser` is deprecated. WebView2 uses the Edge engine, supports modern auth flows, and provides `CookieManager` API. |
| WebView2 token capture | Timer polling (750 ms) over async callbacks | Avoids deadlocks that arise from awaiting Tasks inside `CoreWebView2` async event handlers. |
| WebView2 threading | PowerShell runspace with STA apartment | WinForms requires STA. A dedicated runspace with `ApartmentState = STA` avoids requiring the host process to be STA. |
| CSV looping | Driver loops; module handles one item | Modules stay simple and testable. All file I/O and progress tracking is centralized in the driver. |
| Module discovery | Folder scan + metadata block | Adding a module requires no driver changes. The driver builds the menu from what it finds. |
| Pagination | Handled in shared comms | Modules never need to page. The comms module fetches all pages and returns a combined collection. |
| Rate limiting | Handled in shared comms with backoff | Consistent behavior across all modules. Logged at WARN; fails gracefully after configurable retry limit. |
| WhatIf | Enforced in shared comms layer | Modules forward `$WhatIf.IsPresent` to `Invoke-CyberArkAPI`. No per-module branching needed. |
| Log correlation | PID (not GUID) | Shorter and immediately recognizable. Unique per script session. Filename includes timestamp for uniqueness across sessions with recycled PIDs. |
| Parallel processing | Skipped (sequential only) | Simplicity and PS 5.1 compatibility. Runspace complexity not justified for current use cases. |
| Self-Hosted keepalive | Get Logged On User Details ~2 min before expiry | Attempts to extend the 20-minute PVWA session without requiring re-authentication. |
| ISPSS token expiry | Warn user; prompt re-auth for Interactive/SSO | `ClientCredentials` silently refreshes via `refresh_token`. Interactive/SSO cannot refresh silently. |
| Navigation | `B` = back 1, `B2` = back 2, etc. | Unambiguous — `B` prefix cannot conflict with numeric menu options. |
| Default folders | Launch directory when profile has empty strings | Predictable fallback that works without any profile configuration. |

---

## Security Considerations

- **DPAPI scope**: Profile XML files are encrypted to the current Windows user and machine. They
  cannot be decrypted on a different machine or by a different user account. This is intentional.
- **Token in memory**: Tokens are held as plain strings in memory during a session. This is
  unavoidable for making HTTP calls. Tokens are never written to disk as plaintext.
- **Logging**: Sensitive data (tokens, passwords, secrets) must never appear in log output. The
  logging module masks known patterns. Module authors are responsible for not passing sensitive
  values to `Write-CyberArkLog`.
- **IgnoreSSL**: Stored per profile. When enabled, a warning is logged at session start. Only
  appropriate for lab or development environments.
- **WhatIf mode**: Can be defaulted to `$true` in the profile (`WhatIfDefault`). Recommended for
  production profiles to prevent accidental writes.

---

## Technology Stack

| Technology | Version | Usage |
|---|---|---|
| PowerShell | 5.1+ | Runtime |
| .NET Framework | 4.x (PS 5.1) / .NET 6+ (PS 7) | Base framework |
| Microsoft.Web.WebView2 | Latest NuGet | Browser-based auth (SSO, SAML, OIDC) |
| System.Windows.Forms | Built-in | WebView2 host, file dialogs |
| System.Net.Http | Built-in | Identity tenant URL discovery |
| DPAPI (via Export-Clixml) | Built-in | Profile credential encryption |
| Windows Certificate Store | Built-in | PKI/PKIPN certificate selection |
