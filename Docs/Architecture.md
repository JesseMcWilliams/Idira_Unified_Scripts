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
| `Auth\CyberArk.Auth.Common.psm1` | Complete |
| `Auth\CyberArk.Auth.ISPSS.psm1` | Complete |
| `Auth\CyberArk.Auth.SelfHosted.psm1` | Complete |
| `Modules\CyberArkLogging.psm1` | Complete |
| `Modules\CyberArkComms.psm1` | Complete |
| `Manage-Privilege.ps1` | Complete |
| API Modules (40+ modules across 9 categories) | Complete |

---

## Component Diagram

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                       Manage-Privilege.ps1                        │
  │                                                                   │
  │  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────┐  │
  │  │    Profile      │  │    Session       │  │  Module Loader  │  │
  │  │   Management   │  │    Lifecycle     │  │  Action Menu    │  │
  │  └────────┬────────┘  └────────┬─────────┘  └────────┬────────┘  │
  └───────────┼────────────────────┼────────────────────┼────────────┘
              │                    │                     │
              ▼                    ▼                     ▼
  ┌───────────────────┐  ┌─────────────────────────────────┐  ┌─────────────────────┐
  │   Profile Files   │  │         Auth Modules            │  │    API Modules      │
  │  <Name>.json      │  │  CyberArk.Auth.Common.psm1      │  │  APIModules\<Cat>\  │
  │  <Name>.cred      │  │  CyberArk.Auth.ISPSS.psm1       │  │  Invoke-<Cat><Act>  │
  └───────────────────┘  │  CyberArk.Auth.SelfHosted.psm1  │  └──────────┬──────────┘
                         └─────────────────────────────────┘
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
├── Manage-Privilege.ps1                # Interactive driver script
├── Auth\
│   ├── CyberArk.Auth.Common.psm1       # Shared auth utilities: token object, WebView2, profile persistence
│   ├── CyberArk.Auth.ISPSS.psm1        # Privilege Cloud / CyberArk Identity authentication
│   └── CyberArk.Auth.SelfHosted.psm1   # Self-Hosted PVWA authentication
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
│   │   ├── Invoke-AccountsGetCredential.ps1
│   │   ├── Invoke-AccountsGetActivity.ps1
│   │   ├── Invoke-AccountsLinkAccount.ps1
│   │   ├── Invoke-AccountsUnlinkAccount.ps1
│   │   ├── Invoke-AccountsUnlock.ps1
│   │   ├── Invoke-AccountsCheckIn.ps1
│   │   ├── Invoke-AccountsResumeAutoManagement.ps1
│   │   ├── Invoke-AccountsCancelCpmTask.ps1
│   │   ├── Invoke-AccountsVerify.ps1
│   │   ├── Invoke-AccountsChangeInVault.ps1
│   │   ├── Invoke-AccountsChangeImmediate.ps1
│   │   └── Invoke-AccountsReconcile.ps1
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
│   ├── Users\
│   │   ├── Invoke-UsersList.ps1
│   │   └── Invoke-UsersGet.ps1
│   ├── Groups\
│   │   ├── Invoke-GroupsList.ps1
│   │   ├── Invoke-GroupsAdd.ps1
│   │   ├── Invoke-GroupsUpdate.ps1
│   │   ├── Invoke-GroupsDelete.ps1
│   │   ├── Invoke-GroupsGetMembers.ps1
│   │   ├── Invoke-GroupsAddMember.ps1
│   │   └── Invoke-GroupsRemoveMember.ps1
│   ├── Reports\
│   │   └── Invoke-ReportsList.ps1          # SelfHosted only (GET /API/Reports)
│   ├── Custom\
│   │   ├── Invoke-CustomExportAll.ps1               # Export all list-module results to CSV
│   │   ├── Invoke-CustomExportEntitlements.ps1      # All safes + members → single CSV
│   │   ├── Invoke-CustomExportGroupMembersLocal.ps1 # Local group members with nesting
│   │   ├── Invoke-CustomExportGroupMembersLDAP.ps1  # LDAP/Directory group members via ADSI (@ groups only)
│   │   └── Invoke-CustomTestApi.ps1                 # Interactive raw API tester
│   └── Applications\
│       ├── Invoke-ApplicationsList.ps1             # SelfHosted only (GET /WebServices/PIMServices.svc/Applications)
│       ├── Invoke-ApplicationsGet.ps1              # SelfHosted only
│       ├── Invoke-ApplicationsAdd.ps1              # SelfHosted only
│       ├── Invoke-ApplicationsDelete.ps1           # SelfHosted only
│       ├── Invoke-ApplicationsListAuthMethods.ps1  # SelfHosted only
│       ├── Invoke-ApplicationsAddAuthMethod.ps1    # SelfHosted only
│       └── Invoke-ApplicationsDeleteAuthMethod.ps1 # SelfHosted only
├── Profiles\                           # Created at runtime (default: %APPDATA%\IdiraUnifiedScripts\Profiles\)
│   ├── Production.json
│   ├── Production.cred          # DPAPI-encrypted token (was .xml)
│   ├── Development.json
│   └── Development.cred
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
Manage-Privilege.ps1 launched
  └─ Check prerequisites (PS version, WebView2 if needed)
  └─ Import CyberArkLogging.psm1
  └─ Import CyberArkComms.psm1
  └─ Import CyberArk.Auth.Common.psm1
  └─ Import CyberArk.Auth.ISPSS.psm1
  └─ Import CyberArk.Auth.SelfHosted.psm1
  └─ Initialize log (PID assigned, file created with 40-star header)
  └─ Scan profile directory → display profile summary
```

### 2. Profile Selection and Authentication

```
User selects / creates / edits profile
  └─ Load <ProfileName>.json (driver settings)
  └─ Validate profile (folders accessible, auth file present)
  └─ Load <ProfileName>.cred via Import-AuthToken (DPAPI decrypt)
  └─ Check token expiry
       ├─ Valid         → proceed to session
       ├─ Expiring soon → ask user: refresh now or proceed?
       └─ Expired       → Update-ISPSSAuthToken (ISPSS: silent refresh_token or re-auth)
                          or Update-SelfHostedAuthToken (Self-Hosted: re-auth)
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
            │                  ID-based modules: blank ID → search by name via Invoke-EntitySearch
            └─ CSV file(s)  → user selects via open-file dialog
                              driver validates schema against InputSchema
       └─ Invoke-<Category><Action> -Token $token -InputData $row -WhatIf:$mode
       └─ Display results (table)
       └─ Offer save to file (prompt defaults to N)
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

### Manage-Privilege.ps1

The top-level interactive script. Owns:
- Profile management (create, edit, copy, delete, use, detail view, test connection)
- Session lifecycle (auth, token expiry monitoring, Self-Hosted keepalive, logoff)
- Module discovery (scans `APIModules\` at session start, builds action menu)
- CSV looping (driver loops over rows; modules handle one row at a time)
- Output file handling (save dialogs, output CSV column appending)
- Session summary logging at exit

### Auth Modules

Three focused `.psm1` modules replace the former `Get-AuthToken.ps1` monolith. Imported by Driver
at startup via `Import-Module`. All functions run in module scope — internal helpers are private.

**`CyberArk.Auth.Common.psm1`** — Shared utilities used by both auth modules and the driver:
- `New-AuthTokenObject` — creates the standard token PSCustomObject (the shared return contract)
- `ConvertTo-PlainText` — SecureString to plain string, zeroes unmanaged memory after use
- `Import-WebView2Assembly` / `Invoke-WebView2Window` — browser-based auth (SSO, SAML, OIDC)
- `Get-FilteredClientCertificate` — certificate store picker (PKI / PKIPN)
- `Save-AuthToken` / `Import-AuthToken` — DPAPI profile persistence (`.cred` files)
- `Get-AuthTokenProfiles` / `Remove-AuthTokenProfile` — profile listing and deletion

**`CyberArk.Auth.ISPSS.psm1`** — Privilege Cloud / CyberArk Identity authentication:
- `Get-ISPSSAuthToken` — fresh auth: `ClientCredentials`, `Interactive`, or `SSO`
- `Update-ISPSSAuthToken` — refresh: silent `refresh_token` grant (CC) or re-auth
- `Resolve-IdentityTenantURL` — discovers the `*.id.cyberark.cloud` tenant URL via HTTP probe

**`CyberArk.Auth.SelfHosted.psm1`** — Self-Hosted PVWA authentication:
- `Get-SelfHostedAuthToken` — fresh auth: `CyberArk`, `LDAP`, `RADIUS`, `Shared`, `PKI`, `PKIPN`, `SAML`, `OIDC`
- `Update-SelfHostedAuthToken` — re-authenticates using stored `_RefreshContext`

See [Interfaces.md](Interfaces.md) for token object shape and public function signatures.
See [Auth-Module-Rework-Design.md](Auth-Module-Rework-Design.md) for the design rationale.

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
| SystemType in profile | `'Privilege Cloud'` / `'Self-Hosted'` (user-facing labels) | Maps to auth script values `'ISPSS'`/`'SelfHosted'` at call time. User-facing labels are more descriptive than the internal values. Stored in JSON so the edit flow can tailor the Base URL prompt without loading the XML token. |
| Base URL collection | Branched by SystemType | Privilege Cloud: user enters subdomain only; `PCLOUD_BASE_TEMPLATE` in `CyberArk.Auth.ISPSS.psm1` constructs the full URL. Self-Hosted: user enters the full PVWA URL, joined with `AppName`. |
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
| ISPSS token expiry | Proactive silent refresh (CC); prompt re-auth for Interactive/SSO | `ClientCredentials` tokens are silently refreshed via `Update-ISPSSAuthToken` when < 10 minutes remain (`ProactiveRefreshThresholdMin`). Interactive/SSO cannot refresh silently — user is prompted. |
| Auth module isolation | Three `.psm1` modules instead of one dot-sourced script | Proper private scope, explicit `Export-ModuleMember` surfaces, testable in isolation, no `SystemType` routing inside auth code. Driver branches externally by `SystemType`. |
| Credential scrubbing | `Invoke-ClearNonRefreshableContext` called after Connect | For Interactive/SSO/SAML/OIDC sessions, `Credential` and `ClientSecret` are removed from `_RefreshContext` in memory after the session token is set. Reduces in-memory credential exposure for methods that cannot silently refresh. |
| Navigation | `B` = back 1, `B2` = back 2, etc. | Unambiguous — `B` prefix cannot conflict with numeric menu options. |
| Default folders | Launch directory when profile has empty strings | Predictable fallback that works without any profile configuration. |
| Action menu ordering | `List` always first within each category; remaining actions sorted by `Priority` | Users almost always want to list before acting. Explicit sort key overrides the numeric Priority so any future re-numbering does not change the visual order. |
| Table display truncation | Driver truncates List actions and all Custom export operations to `DisplayLimit` rows (default 20); full data still exported to CSV | Avoids flooding the terminal with hundreds of rows while keeping the full dataset available for downstream processing. Condition is `Action -eq 'List'` OR `Category -eq 'Custom' -and ProducesOutput`. Configurable per-profile. 0 = show all. |
| Accounts List — By-Safe mode | Optional mode fetches accounts per-safe rather than a single global query | CyberArk's `/API/Accounts` endpoint caps returns at ~20,000 accounts without a safe filter. Per-safe iteration bypasses this limit while remaining within the existing pagination infrastructure. |
| Role profile fields | `Role_Template_Safe` and `Role_Group_Prefix` stored in the profile, not hardcoded | These values are environment-specific (safe naming conventions, group prefix conventions differ per tenant). Storing them in the profile makes modules portable across environments. First consumed by `Safes/AddFromTemplate` (see `Docs\Add-Safe-From-Template-Design.md`). |
| Add Safe From Template — role-group exclusion | Exclude any template member (any `memberType`) whose name starts with `Role_Group_Prefix`, case-insensitive; every other member is copied | Both fields are required on the active profile — a blank prefix fails fast rather than silently copying role groups. Filtering by name prefix (not `memberType`) matches how `Role_Group_Prefix` was already documented in `Interfaces.md` before this feature existed. |
| Add Safe From Template — settings vs. identity fields | `SafeName` and `Description` are always fresh input; `Location`, `ManagingCPM`, and `AutoPurgeEnabled` are copied from the template safe; member `membershipExpirationDate` is never copied | Description and expiration are contextual to the specific safe/membership being created, not properties of the "shape" a template is meant to standardize. |
| Safe retention fields are mutually exclusive | `NumberOfVersionsRetention` and `NumberOfDaysRetention` are never both sent on `POST`/`PUT /API/Safes` — `NumberOfDaysRetention` is sent only when greater than 0, otherwise `NumberOfVersionsRetention` is sent | The API treats these as a single choice of retention mode, not two independent settings. Applies to `Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1`, and `Invoke-SafesAddFromTemplate.ps1`. |
| `OLACEnabled` is not a supported field | Never read, prompted for, or sent by any Safes write module | Confirmed not a valid input for this API; removed from `Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1`, and `Invoke-SafesAddFromTemplate.ps1` after initial implementations mistakenly included it. |
| Add Safe From Template — global member exclusion list | `$script:ExcludedTemplateMemberNames` defined once in `Manage-Privilege.ps1` (dot-sourced into every module's scope, same mechanism as `$script:ActiveProfile`), not a profile field | This is an environment-wide policy ("never copy these specific members from any template safe"), not a per-tenant setting like `Role_Group_Prefix` — a single hardcoded list, editable directly in `Manage-Privilege.ps1`, is simpler than adding a new profile field and keeps the door open for other Safes/SafeMembers modules to reuse the same constant. |
| Request body and error logging | POST/PUT/PATCH bodies and HTTP 4xx/5xx response bodies logged at DEBUG level with `-FileOnly` | Large structured content would flood the terminal at DEBUG. Writing to the log file only preserves the diagnostic data for post-session review without cluttering the console. Sensitive fields are masked by `Mask-SensitiveData` before the entry is written. |
| HTTP 504 retry (`Invoke-CyberArkAPI`) | Fixed 5-second delay (`$script:GatewayTimeoutDelaySec`), up to `$script:MaxGatewayTimeoutRetries` (default 2) retries; if pagination is in use, the page size is reduced by 25% before each retry | A 504 usually means the request itself was too expensive for the server to finish within its own timeout window (unlike 429, which is unrelated to request size) — a fixed delay (not exponential backoff) plus a smaller page size directly addresses the likely cause rather than just waiting longer. Same `$offset` is retried, so no items are skipped or duplicated. |
| Add Safe Member — interactive SearchIn picker | Numbered menu (Vault always first, plus directories from `GET /API/Configuration/LDAP/Directories`) replaces free-text entry, interactive mode only; CSV/bulk input via `InputSchema` is unchanged | Free-text UUID entry was error-prone; a picker removes the need to already know the directory ID. Falls back to Vault-only (never blocks the flow) if the directory lookup fails — the exact response field names for that endpoint are unconfirmed against a live system as of this writing (see `Docs\Lessons-Learned-PowerShell-Pester.md` Section 12.2), so the mapping defensively probes several plausible field names rather than assuming one. |
| SafeMembers — AddFromTemplateRole / UpdateFromTemplateRole | New actions that resolve permissions from a "role" — a member of `Role_Template_Safe` whose name starts with `Role_Group_Prefix` — instead of the ReadOnly/EndUser/PowerUser/SafeManager presets or manual per-permission entry. The role is picked from a numbered Index/Name menu (interactive) or supplied as an exact `RoleName` (CSV/bulk); permissions are copied verbatim from the matched role member, same as `Safes/AddFromTemplate`'s member-copy approach | Lets an admin grant "the same access as role X" without re-deriving or duplicating that role's exact permission set by hand. Uses the same `Role_Template_Safe`/`Role_Group_Prefix` fields already established for `Safes/AddFromTemplate`, but filters for role-prefixed members instead of excluding them — the opposite side of that same filter. `RoleName` match is exact and case-insensitive, not a prefix match (consistent with how `$script:ExcludedTemplateMemberNames` matches). The global `$script:ExcludedTemplateMemberNames` list does NOT apply here — that list governs which members are copied when stamping a new safe, a different concern from which role a member's permissions are drawn from. |
| 401 handling always invalidates the session | `Invoke-TokenInvalidate` is called unconditionally whenever a module returns `IsFatal = $true`, rather than pattern-matching the error message text for "401"/"Unauthorized" | `IsFatal` is only ever set for HTTP 401 or a network-level failure (`StatusCode 0`) — every module follows `IsFatal = ($response.StatusCode -in @(401, 0))`. The prior text-match could silently miss a genuine 401 whose message happened not to contain those exact words, leaving a rejected token in place. Invalidating on any `IsFatal` closes that gap; the only side effect is also invalidating on a transient network error, which is a safe, minor inconvenience (forces one extra re-auth prompt), not a correctness issue. |
| Logon-phase token age check | `Token.Created` (new field, carried forward from the persisted `SavedAt` timestamp by `Import-AuthToken`, not reset on load) is checked against `$script:LogonTokenMaxAgeMin` (15 min) when a saved-but-still-valid token is loaded at logon; if older, it's refreshed via `Update-ISPSSAuthToken`/`Update-SelfHostedAuthToken` before the session starts | A token can sit unused for hours while still inside its expiry window. `Invoke-ProactiveRefresh` only guards against near-expiry (and only for `ClientCredentials`), so a long-idle-but-valid token could otherwise start a whole session already partway through its life. Checking at logon, once, is cheaper and simpler than extending the mid-session proactive-refresh logic to cover every `AuthMethod`. Older `.cred` files saved before `Created` existed fall back to "age unknown" (not force-refreshed) rather than assuming staleness. |

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
