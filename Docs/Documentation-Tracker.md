# Documentation Tracker

Tracks the status of all design and reference documents for the CyberArk PAS Scripts project.
Update the Status column as documents are created or revised.

## Status Key

| Symbol | Meaning |
|---|---|
| ✅ | Complete |
| 🔄 | In Progress |
| 📋 | Planned |

---

## Documents

### Architecture and Design

| Document | File | Status | Priority | Description |
|---|---|---|---|---|
| Architecture Overview | [Architecture.md](Architecture.md) | ✅ | High | System components, folder structure, data flow, design decisions, technology stack |
| Interface Definitions | [Interfaces.md](Interfaces.md) | ✅ | High | All shared data contracts: token object, result object, module metadata, profile schema, response object, log format |
| API Module Development Guide | [API-Module-Development-Guide.md](API-Module-Development-Guide.md) | ✅ | High | Step-by-step guide for creating new API modules, metadata contract, entry point signature, complete example, checklist |
| Auth Module Rework Design | [Auth-Module-Rework-Design.md](Auth-Module-Rework-Design.md) | ✅ | High | Design plan for splitting Get-AuthToken.ps1 into CyberArk.Auth.Common/ISPSS/SelfHosted.psm1; public API surfaces, driver changes, refresh improvements, open decisions |
| Documentation Tracker | [Documentation-Tracker.md](Documentation-Tracker.md) | ✅ | High | This file |

### Module References

| Document | File | Status | Priority | Description |
|---|---|---|---|---|
| Shared Comms Module Reference | [SharedComms-Reference.md](SharedComms-Reference.md) | 📋 | High | Complete function reference for `CyberArkComms.psm1`: `Invoke-CyberArkAPI`, query helpers, URL helpers, response object, WhatIf behavior, pagination, rate limiting |
| Logging Module Reference | [Logging-Reference.md](Logging-Reference.md) | 📋 | High | `Write-CyberArkLog` signature, all log levels with examples, log file format spec, startup/shutdown blocks, bare mode, sensitive data masking, log cleanup |
| Driver Script Reference | [Driver-Reference.md](Driver-Reference.md) | 📋 | Medium | Driver navigation system (B# breadcrumbs), session lifecycle, profile management flow, CSV processing loop, token expiry handling, module discovery |

### Configuration and Schema

| Document | File | Status | Priority | Description |
|---|---|---|---|---|
| Profile Schema Reference | [Profile-Schema.md](Profile-Schema.md) | 📋 | Medium | Both profile files fully documented: JSON field descriptions and validation rules, DPAPI XML field table, field resolution order, example profiles |

### Testing

| Document | File | Status | Priority | Description |
|---|---|---|---|---|
| Testing Plan | [Testing-Plan.md](Testing-Plan.md) | ✅ | High | Full test matrix: unit test IDs (L/C/S/A/D series), integration test procedures, Pester v5 patterns, known limitations |

### Operations

| Document | File | Status | Priority | Description |
|---|---|---|---|---|
| Installation and Prerequisites | [Installation.md](Installation.md) | 📋 | Medium | Requirements (PS version, WebView2, .NET), setup steps, folder layout, first-run walkthrough, module installation |
| Troubleshooting Guide | [Troubleshooting.md](Troubleshooting.md) | 📋 | Low | Common failures with resolution steps: WebView2 not found, certificate not in store, SSL errors, rate limiting, token refresh failure, profile decryption on wrong machine |

### Living Documents (update as modules are added)

| Document | File | Status | Priority | Description |
|---|---|---|---|---|
| API Coverage Matrix | [API-Coverage-Matrix.md](API-Coverage-Matrix.md) | 📋 | Medium | Tracks every planned and implemented API module: Name, Category, SupportedSystems, endpoint, module version, status (Planned / In Progress / Complete) |
| Lessons Learned | [Lessons-Learned-PowerShell-Pester.md](Lessons-Learned-PowerShell-Pester.md) | ✅ | Medium | PS 5.1 compatibility, Pester v6 mock patterns, API module conventions — bugs found during unit test development |

---

## Creation Order

Build documents in this sequence to support the implementation phases:

1. ✅ `Architecture.md` — foundation reference
2. ✅ `Interfaces.md` — contracts needed before writing any code
3. ✅ `API-Module-Development-Guide.md` — module authors need this before first module
4. ✅ `Documentation-Tracker.md` — this file
5. 📋 `Logging-Reference.md` — write alongside `CyberArkLogging.psm1`
6. 📋 `SharedComms-Reference.md` — write alongside `CyberArkComms.psm1`
7. 📋 `Profile-Schema.md` — write alongside Driver profile management code
8. 📋 `Driver-Reference.md` — write alongside Driver action menu and navigation
9. ✅ `Testing-Plan.md` — created alongside first module
10. 📋 `API-Coverage-Matrix.md` — create when first module is built; update continuously
11. 📋 `Installation.md` — write when system is functionally complete
12. 📋 `Troubleshooting.md` — write after first full end-to-end test run

---

## Revision Log

| Date | Document | Change |
|---|---|---|
| 2026-08-14 | Architecture.md | Created |
| 2026-08-14 | Interfaces.md | Created |
| 2026-08-14 | API-Module-Development-Guide.md | Created |
| 2026-08-14 | Documentation-Tracker.md | Created |
| 2026-08-15 | Lessons-Learned-PowerShell-Pester.md | Created — PS 5.1 / Pester v6 patterns |
| 2026-08-15 | Architecture.md | Added Groups category (7 modules) |
| 2026-08-15 | Groups modules | Created 7 APIModules\Groups\Invoke-Groups*.ps1 + 7 test files — 103 new tests, all passing |
| 2026-08-15 | Reports module | Created APIModules\Reports\Invoke-ReportsList.ps1 (SelfHosted only, Priority=70) + 15 unit tests (RL01–RL15) |
| 2026-08-15 | Architecture.md | Added Reports category (Invoke-ReportsList.ps1) to folder structure |
| 2026-08-15 | Lessons-Learned-PowerShell-Pester.md | Added Section 4 — PS 5.1 strict-mode patterns: hashtable dot notation, PSCustomObject optional properties, null-safe Count, Pester Should-Not-Throw scope |
| 2026-08-15 | API-Module-Development-Guide.md | Fixed dot-notation examples to bracket notation; added strict-mode safety checklist items |
| 2026-08-15 | 10+ API modules | Fixed PS 5.1 strict-mode bugs: $InputData bracket notation, PSObject.Properties guards, null-safe Count — all 583 unit tests passing |
| 2026-08-15 | Driver.ps1 | Added SystemType field (Privilege Cloud / Self-Hosted) to profile; branched BaseURL prompt in edit flow; passes SystemType + URL pre-populated to Get-AuthToken |
| 2026-08-15 | Interfaces.md | Updated Driver Profile JSON schema: added SystemType and BaseURL fields, field reference table, and SystemType→BaseURL prompt mapping table |
| 2026-08-15 | Architecture.md | Added Design Decisions rows for SystemType labelling and branched BaseURL collection |
| 2026-08-15 | Driver.ps1 | Added AppName field (default PasswordVault) and AuthMethod field to profile; numbered auth method selection in edit flow; fixed Self-Hosted PVWAUrl to join BaseURL+AppName; Privilege Cloud token.BaseURL patched post-auth; LogFolder/OutputFolder auto-created; URL shown in auth error messages |
| 2026-08-15 | Get-AuthToken.ps1 | Replaced auth method text prompt with numbered list selection; logon URL included in authentication failure error messages |
| 2026-08-15 | Interfaces.md | Updated Driver Profile JSON schema: added AppName and AuthMethod fields; updated Get-AuthToken call mapping to include AppName in PVWAUrl construction |
| 2026-08-15 | Driver.ps1 | Bug fixes: AuthMethod column now falls back to profile JSON when no token exists; Enter defaults to C (Connect) on profile detail screen; username captured from Get-Credential and saved back to profile; module functions re-dot-sourced in Invoke-SessionLoop scope so Invoke-ActionModule can resolve them |
| 2026-08-15 | 27 API modules | Fixed $Defaults.Key dot notation → $Defaults['Key'] bracket notation in all Get-*Input custom input functions — PS 5.1 strict-mode throws PropertyNotFoundException on missing hashtable keys accessed via dot notation |
| 2026-08-15 | Lessons-Learned-PowerShell-Pester.md | Added Section 4.5 ($Defaults bracket notation in custom input functions) and Section 6.1 (function scope lost when dot-source runs inside a returned function) |
| 2026-08-15 | API-Module-Development-Guide.md | Fixed $Defaults example code to use bracket notation; added $Defaults['Key'] checklist item under custom input section |
| 2026-08-15 | Driver.ps1 | Added Get-CsvSavePath (Windows Forms SaveFileDialog + console fallback); Invoke-ActionModule now offers CSV save after any ProducesOutput=true module returns results |
| 2026-08-15 | Driver.ps1 | Changed Get-ProfileTokenPath: token file extension .xml → .cred |
| 2026-08-15 | Get-AuthToken.ps1 | Changed Resolve-ProfilePath (2 paths) and Get-AuthTokenProfiles filter: .xml → .cred |
| 2026-08-15 | Interfaces.md | Updated Auth Token File section and Driver Profile field reference: .xml → .cred |
| 2026-08-16 | Driver.ps1 | Added Invoke-EntitySearch helper; updated 10 Get-*Input functions (Accounts, Users, Platforms, Groups) to allow ID or name/search with numbered pick list |
| 2026-08-16 | Driver.ps1 | Changed CSV save prompt to default N ([y/N]) |
| 2026-08-16 | Invoke-PlatformsList.ps1 | Fixed PropertyNotFoundException: added PSObject.Properties guards for id/name/description/active/platformType |
| 2026-08-16 | Invoke-UsersGet.ps1 | Fixed PropertyNotFoundException: added nested PSObject.Properties guards for personalDetails.email/firstName/lastName |
| 2026-08-16 | Invoke-AccountsGet.ps1 | Fixed PropertyNotFoundException: added nested PSObject.Properties guards for secretManagement sub-fields |
| 2026-08-16 | Invoke-AccountsUpdate.ps1 | Fixed PropertyNotFoundException: added nested PSObject.Properties guards for secretManagement sub-fields in result mapping |
| 2026-08-16 | Invoke-PlatformsGet.ps1 | Fixed PropertyNotFoundException: added PSObject.Properties guards for all platform result fields |
| 2026-08-16 | Accounts modules (11 new) | Added Invoke-AccountsGetActivity, LinkAccount, UnlinkAccount, Unlock, CheckIn, ResumeAutoManagement, CancelCpmTask, Verify, ChangeInVault, ChangeImmediate, Reconcile — each with AcceptsInputFile=true, SupportsWhatIf=true, entity search input, Pester test file |
| 2026-08-16 | Lessons-Learned-PowerShell-Pester.md | Added Section 7 — custom input function cancellation ($null return) and nested PSObject.Properties guard pattern |
| 2026-08-16 | Architecture.md | Added 11 new Account modules to folder structure; updated .xml → .cred in profile files; updated Data Flow to mention ID-to-name lookup |
| 2026-08-16 | Custom modules (4 new) | Added Invoke-CustomExportAll, ExportEntitlements, ExportGroupMembersLocal, ExportGroupMembersLDAP — orchestration modules with recursive group traversal and ADSI support |
| 2026-08-16 | Applications modules (7 new) | Added Invoke-ApplicationsList/Get/Add/Delete, ListAuthMethods, AddAuthMethod, DeleteAuthMethod — SelfHosted only, legacy PIMServices.svc endpoint, nested body wrapper pattern |
| 2026-08-16 | Tests (11 new) | Added Pester test files for all 4 Custom export and 7 Applications modules |
| 2026-08-16 | Architecture.md | Added Custom and Applications categories to folder structure |
| 2026-08-16 | Lessons-Learned-PowerShell-Pester.md | Added Section 8 — orchestration module pattern, ADSI vs AD module, stack-based traversal, Applications API body/response shape |
| 2026-08-16 | 22 test files (Tests\Unit\) | Fixed Pester v6.1 regression: moved BeforeAll to file level (before Describe) in all new-style test files; added Initialize-CyberArkLog calls; added Get-CsvSavePath global stub; fixed mock data for GetActivity, ChangeInVault, LinkAccount, UnlinkAccount; removed invalid WhatIf test from GetActivity — 697 tests passing, 0 failures |
| 2026-08-16 | Lessons-Learned-PowerShell-Pester.md | Added Section 9 — Pester v6 BeforeAll scoping (9.1), Initialize-CyberArkLog requirement (9.2), Driver-scope helper stubs (9.3), success test required field completeness (9.4), WhatIf only suppresses mutating methods (9.5) |
| 2026-08-16 | CyberArkComms.psm1 | Fixed Join-CyberArkUrl: changed Trim('/') → TrimStart('/') to preserve trailing slashes; appended [Method URL] to all HTTP 400/500 error messages |
| 2026-08-16 | Driver.ps1 | Added Logout option [L] to profile detail screen; failed modules shown in red in action menu and show error on invoke; Join-CyberArkUrl trailing slash fix enables Applications List |
| 2026-08-16 | Driver.ps1 | List actions display numbered table and offer line-number drill-down to corresponding Get module after results; Invoke-ActionModule accepts $Defaults for pre-populated input |
| 2026-08-16 | Driver.ps1 | Back [B] is now the default on profile detail, action menu, and module mode selection screens — pressing Enter goes back |
| 2026-08-16 | Driver.ps1 | Continue [C] now shows auth token details (signed-in user, system type, auth method, base URL, expiry) before entering session loop |
| 2026-08-16 | Invoke-PlatformsGet.ps1 | Added root-level fallback for id/name/description/platformType/active — handles CyberArk single-GET responses where fields are at root instead of under general |
| 2026-08-16 | Invoke-PlatformsList.ps1 | Same dual-fallback applied for consistency |
| 2026-08-16 | 9 API modules + Run-Tests.ps1 + CyberArkComms.psm1 | Fixed 62 test regressions from commit 5edf0c8: applied [array] type constraint to 7 list modules (AccountsList, SafesList, PlatformsList, UsersList, SafeMembersList, ReportsList, ExportGroupMembersLocal); added (-not $col) or null guard to ExportEntitlements and ExportGroupMembersLocal empty-list checks; reverted GroupsGetMembers to /Members endpoint + value property; restored memberType in GroupsAddMember body; fixed CyberArkComms Join-CyberArkUrl TrimStart→Trim (was breaking C12); added PassThru=true to Run-Tests.ps1 Pester config — all 697 tests passing |
| 2026-08-16 | Lessons-Learned-PowerShell-Pester.md | Added Section 4.6 — PS 5.1 empty @() in script block outputs nothing (not an empty array), so [array] alone does not prevent null when API returns 0 items; added Section 9.6 — Invoke-Pester requires PassThru=true to return the result object; without it $result is null |
| 2026-08-16 | Invoke-GroupsGetMembers.ps1 + Invoke-CustomExportGroupMembersLocal.ps1 | Fixed runtime HTTP 405: reverted from /Members sub-resource to bare group GET (/API/UserGroups/{id}) with -PageSize 0; added multi-property fallback probe (members/Members/groupMembers/value) for PVWA version compatibility |
| 2026-08-16 | Invoke-GroupsGetMembers.Tests.ps1 + Invoke-CustomExportGroupMembersLocal.Tests.ps1 | Updated mock data from value= to members= property; updated endpoint filters from */Members to bare group path — 697 tests passing |
| 2026-08-16 | Lessons-Learned-PowerShell-Pester.md | Added Section 8.5 — CyberArk Groups /Members sub-resource returns 405 on many PVWA versions; correct pattern is bare group GET with multi-property member extraction |
| 2026-08-16 | Invoke-CustomExportEntitlements.ps1 | Fixed PropertyNotFoundException on $members.Count when a safe returns an empty members array (PS 5.1 @() from if-expression = null; added $memberCount null guard) |
| 2026-08-16 | Driver.ps1 Invoke-EntitySearch | Added -ClientSideFilter switch: fetches all results without server-side search param, then applies case-insensitive contains filter client-side across DisplayProperties |
| 2026-08-16 | 5 Applications input functions | Removed SearchParam='AppID' from Invoke-EntitySearch calls (PIMServices does exact match only); switched to -ClientSideFilter for proper partial search behaviour |
| 2026-08-16 | Get-AuthToken.ps1 | Fixed Privilege Cloud Interactive auth: (1) Username from profile was dropped by local variable overwrite in Interactive dispatch — fixed fallback chain to include $Username param; (2) Resolve-IdentityTenantURL used HTTP redirect-follow which fails when portal uses JavaScript redirects — replaced with direct {subdomain}.id.cyberark.cloud construction |
| 2026-08-17 | Get-AuthToken.ps1 | Replaced static Resolve-IdentityTenantURL with multi-candidate Invoke-WebRequest redirect-discovery approach (3 candidate URLs, up to 8 HTTP redirects, detects *.id.cyberark.cloud in final response host or exception redirect host) |
| 2026-08-17 | Get-AuthToken.ps1 | Fixed StrictMode crash: PSObject.Properties['IdpRedirectShortUrl'] guard added — field absent on non-IdP tenants |
| 2026-08-17 | Get-AuthToken.ps1 | Fixed StrictMode crash: PSObject.Properties['Token'] and ['Auth'] guards added in AdvanceAuthentication result extraction; added root-level $resp.Token/$resp.Auth fallback for OOB LoginSuccess string result |
| 2026-08-17 | Get-AuthToken.ps1 | Improved OOB poll loop: 2s interval (was 3s), in-place elapsed timer, case-insensitive OobPending comparison |
| 2026-08-17 | Invoke-AccountsList.ps1 | Fixed StrictMode crash: PSObject.Properties guards added for all flat account fields (id, name, address, userName, platformId, safeName, secretType) |
| 2026-08-17 | Driver.ps1 | Fixed 401 re-auth: added immediate Test-TokenExpiry + Invoke-TokenRefresh check after each Invoke-ActionModule call in inner action loop — prompt appears immediately, not after user presses [B] |
| 2026-08-17 | Invoke-CustomExportAll.ps1 | Fixed ExcludeFromExportAll filtering: changed $_.Meta.PSObject.Properties['ExcludeFromExportAll'] to $_.Meta['ExcludeFromExportAll'] — PSObject.Properties on a hashtable never finds key-value entries |
| 2026-08-17 | Driver.ps1 | Fixed SaveFileDialog ignoring OutputFolder: added RestoreDirectory = $true to Get-CsvSavePath dialog — required for InitialDirectory to be honoured |
| 2026-08-17 | Invoke-PlatformsGet.ps1 | Fixed Platform GET showing only Active field: added dual-location fallback (general sub-object + root) and alternate field name support (PlatformID/SystemType vs id/platformType); added DEBUG logging of actual response field names |
| 2026-08-17 | Lessons-Learned-PowerShell-Pester.md | Added Section 4.7 — PSObject.Properties on hashtable finds object members not key-value entries; use $ht['Key'] for hashtable, PSObject.Properties only for PSCustomObject |
| 2026-08-17 | Lessons-Learned-PowerShell-Pester.md | Added Section 11 — CyberArk Identity/Privilege Cloud: Identity tenant URL multi-candidate discovery (11.1), AdvanceAuthentication dual-field + root-level token extraction + OOB patterns (11.2), immediate re-auth after 401 (11.3) |
| 2026-08-17 | Lessons-Learned-PowerShell-Pester.md | Added Section 12 — CyberArk Platform GET response field name variations by PVWA version (general sub-object vs root, id/platformType vs PlatformID/SystemType) |
| 2026-08-17 | Lessons-Learned-PowerShell-Pester.md | Added Section 13 — Windows Forms: SaveFileDialog.RestoreDirectory must be $true to honor InitialDirectory |
| 2026-08-17 | Get-AuthToken.ps1 | Fixed ISPSS BaseURL missing /PasswordVault: PCLOUD_BASE_TEMPLATE now includes /PasswordVault so all token paths (fresh auth, refresh, AutoRefresh) produce the correct URL without Driver-side patching |
| 2026-08-17 | Driver.ps1 | Added Driver-side BaseURL safety patches (Test Connection, Connect load-from-disk, Connect fresh-auth) to fix old saved tokens lacking /PasswordVault |
| 2026-08-17 | Driver.ps1 + Get-AuthToken.ps1 | Renamed profile storage folder: %APPDATA%\CyberArkPAS → %APPDATA%\IdiraUnifiedScripts\Profiles (aligns code with README and all documentation) |
| 2026-08-17 | Driver.ps1 | Added three ISPSS-only profile fields: TenantPortal ({sub}.cyberark.com), TenantVault (vault-{sub}.privilegecloud.cyberark.com), TenantAuth (discovered identity URL). Auto-computed at profile edit; TenantAuth passed to Get-AuthToken to skip per-login HTTP probe; written back after each successful login |
| 2026-08-17 | Interfaces.md | Updated Driver Profile JSON schema: added TenantPortal, TenantVault, TenantAuth fields; updated AppName description (ISPSS vs Self-Hosted distinction); corrected BaseURL-to-API-URL note (now baked into PCLOUD_BASE_TEMPLATE); added auto-computed fields table |
| 2026-08-17 | Lessons-Learned-PowerShell-Pester.md | Updated Section 11.1 rule: IdentityHost → TenantAuth field name; added post-login write-back pattern. Added Section 11.4: fix URL constants at the source not in downstream callers. Updated Section 13.1: added known trade-off note that XP-style dialog was rejected and InitialDirectory remains unresolved |
| 2026-08-17 | Get-AuthToken.ps1 | Changed Resolve-IdentityTenantURL MaximumRedirection from 8 to 0 — intentionally causes first redirect to throw so catch block captures redirect target URL via exception.Response.ResponseUri |
| 2026-08-17 | Lessons-Learned-PowerShell-Pester.md | Updated Section 11.1 — corrected code example to MaximumRedirection 0 and explained why 0 is correct (captures redirect URL in exception vs silently following chain to JavaScript portal) |
| 2026-08-17 | Auth-Module-Rework-Design.md | Created — design document for splitting Get-AuthToken.ps1 into three psm1 modules (Common/ISPSS/SelfHosted); covers public API surfaces, driver changes, refresh improvements (proactive refresh, 401 vs 403, transient retry, context clearing), and 7 open decisions |
| 2026-08-17 | Auth\CyberArk.Auth.Common.psm1 | Created — shared auth utilities: New-AuthTokenObject, ConvertTo-PlainText, Get-FilteredClientCertificate, Import-WebView2Assembly, Invoke-WebView2Window, Save-AuthToken, Import-AuthToken (no AutoRefresh), Get-AuthTokenProfiles, Remove-AuthTokenProfile |
| 2026-08-17 | Auth\CyberArk.Auth.ISPSS.psm1 | Created — ISPSS auth module: exports Get-ISPSSAuthToken (7 params, no SystemType routing), Update-ISPSSAuthToken (refresh_token grant + fallback re-auth), Resolve-IdentityTenantURL; all Identity challenge/OOB logic private |
| 2026-08-17 | Auth\CyberArk.Auth.SelfHosted.psm1 | Created — SelfHosted auth module: exports Get-SelfHostedAuthToken (8 params), Update-SelfHostedAuthToken; all PVWA logon helpers private |
| 2026-08-17 | Driver.ps1 | Replaced dot-source of Get-AuthToken.ps1 with Import-Module for three new auth modules; updated Assert-Prerequisites; replaced Get-AuthToken calls in Connect and Test Connection with Get-ISPSSAuthToken/Get-SelfHostedAuthToken; rewrote Invoke-TokenRefresh to use Update-ISPSSAuthToken/Update-SelfHostedAuthToken; added Invoke-ProactiveRefresh (silent CC refresh 10 min before expiry) and Invoke-ClearNonRefreshableContext (removes stored credentials for Interactive/SSO/SAML/OIDC after login); added ProactiveRefreshThresholdMin and PVWA_SESSION_EXPIRY_MIN constants |
| 2026-08-17 | Auth-Module-Rework-Design.md | Updated status to reflect implementation complete; decisions D1-D6 resolved |
| 2026-08-17 | Architecture.md | Updated Build Status table, Component Diagram, Folder Structure, Startup data flow, Component Descriptions, and Design Decisions to reflect three-module auth split (Common/ISPSS/SelfHosted); removed Get-AuthToken.ps1 references; added Auth module isolation, proactive refresh, and credential scrubbing design decisions |
| 2026-08-17 | Interfaces.md | Updated token object source reference; renamed `_RefreshContext` Update-AuthToken note; added Auth Module Public Functions section with full signatures for Get-ISPSSAuthToken, Update-ISPSSAuthToken, Resolve-IdentityTenantURL, Get-SelfHostedAuthToken, Update-SelfHostedAuthToken, and CyberArk.Auth.Common.psm1 function table; updated SystemType call-site mapping; added ProactiveRefreshThresholdMin to config variables table |
| 2026-08-17 | CyberArkLogging.psm1 | Added -OverwriteFile switch to Initialize-CyberArkLog: uses fixed 'startup.log' filename and truncates file at init; timestamped log files unchanged when switch is absent |
| 2026-08-17 | Driver.ps1 | Added -LogLevel and -LogFolder parameters; Initialize-CyberArkLog moved to immediately after Assert-Prerequisites so startup log captures module load sequence; startup log uses -OverwriteFile (overwritten on each launch); added PS version, platform, and per-module DEBUG log lines at startup; Get-AllDriverProfiles now logs profile count and per-profile name/type/token-status/expiry at DEBUG level |
| 2026-08-17 | CyberArk.Auth.ISPSS.psm1 | Added private script:Write-ISPSSLog wrapper (calls Write-CyberArkLog when available, falls back to Write-Verbose); replaced all Write-Verbose in Resolve-IdentityTenantURL with structured log entries (INFO for discovery start/result, DEBUG for per-candidate probe detail, WARN for fallback and no-redirect cases) |
| 2026-08-17 | CyberArk.Auth.ISPSS.psm1 | Fixed three InvalidOperationException sources in Resolve-IdentityTenantURL: (1) Get-WebResponseHost and Get-ExceptionRedirectHost — wrapped .ResponseUri access in try/catch since non-null WebException.Response can be in an invalid state on SSL/TLS failures; (2) catch block — captured $_ as $caughtError immediately (any pipeline or inner try/catch overwrites $_ in PS 5.1); (3) StatusCode access wrapped in try/catch; each Exception property access wrapped individually |
| 2026-08-17 | Lessons-Learned-PowerShell-Pester.md | Updated Section 11.1 — updated Get-WebResponseHost and Get-ExceptionRedirectHost code examples to show try/catch guards; added note explaining why null-check alone is insufficient for invalid-state WebException.Response objects |
| 2026-08-17 | Lessons-Learned-PowerShell-Pester.md | Added Section 6.2 — cross-module logging: private script: wrapper pattern with Get-Command guard; why -FunctionName must be passed explicitly through the wrapper; rule against calling session-level functions directly from .psm1 |
| 2026-08-17 | Lessons-Learned-PowerShell-Pester.md | Added Section 14 — PS 5.1 catch block safety: Section 14.1 ($_ overwritten by any pipeline or inner try/catch — always capture as $caughtError = $_ first); Section 14.2 (WebException response properties throw InvalidOperationException on non-null invalid-state objects — wrap each property access in its own try/catch; includes table of which network conditions produce invalid-state response objects) |
| 2026-08-17 | Driver.ps1 | Fixed token refresh exit bug: removed `Invoke-TokenRefresh | Out-Null` from Warning branch (failures silently discarded caused premature expiry detection); added 'Warning' to Invoke-TokenRefresh early-return guard so valid-but-expiring tokens never trigger re-auth |
| 2026-08-17 | Driver.ps1 | Added Set-SessionToken helper: copies all NoteProperties (including MaxResults) from old token to new before assigning $script:SessionToken; replaced all direct $script:SessionToken assignments in refresh paths |
| 2026-08-17 | Driver.ps1 | Export Entitlements display truncation: generalized existing SafeMembers truncation flag to also cover Custom/ExportEntitlements; both limited to first 10 records on screen |
| 2026-08-17 | Invoke-SafeMembersAdd.ps1 | Added Role/Specified permission mode: 1=Role (named preset: ReadOnly/EndUser/PowerUser/SafeManager); 2=Specified (enter each of 20 permissions as Y/N or supply per-column CSV values from Entitlements report export); $script:PermissionColumns and helper functions scoped with script: prefix |
| 2026-08-17 | Invoke-SafeMembersUpdate.ps1 | Same Role/Specified permission mode as Add; three-tier permission resolution: (1) InputData['Permissions'] hashtable, (2) individual permission CSV columns, (3) named role preset |
| 2026-08-17 | Invoke-CustomExportGroupMembersLDAP.ps1 | Pre-skipped Vault-type groups before AD lookup; broadened LDAP detection regex to include 'directory', 'ldap', 'external', 'activedirectory', 'microsoftad'; improved not-found message to include groupType and directoryType hints |
| 2026-08-18 | Driver.ps1 | Action menu sort: List module now explicitly sorted first within each category using [int]($_.Meta.Action -ne 'List') as primary sort key; secondary sort by Priority unchanged |
| 2026-08-18 | Driver.ps1 | Added Role_Template_Safe and Role_Group_Prefix profile fields: New-BlankProfile, normalization loop, Show-ProfileDetail, Invoke-ProfileEditFlow |
| 2026-08-18 | Driver.ps1 | Added TenantPortal, TenantVault, TenantAuth to profile normalization loop (were missing from Get-AllDriverProfiles string-field normalization) |
| 2026-08-18 | Driver.ps1 | Added DisplayLimit profile field (default 20, 0=show all): stored in profile, editable in edit flow; generalised list truncation from hardcoded 10-row cap (SafeMembers + ExportEntitlements only) to all List actions across all categories plus ExportEntitlements; limit driven by profile setting at render time; hint pointing to Profile Settings shown when truncated |
| 2026-08-18 | Invoke-CustomExportGroupMembersLDAP.ps1 | Removed client-side groupType/directoryType filter entirely (ISPSS now returns all groups with groupType='Vault' regardless of actual directory source); AD lookup is now the sole filter; not-found changed from WARN/Failure to DEBUG/skip (expected for Vault-only groups) |
| 2026-08-18 | Invoke-AccountsList.ps1 | Added By-Safe retrieval mode: fetches safe list first, queries accounts per safe with OData filter (single-quoted safe name for space safety), bypasses ~20K API count cap; script:Add-AccountToResult helper eliminates duplicated mapping block; normal mode unchanged |
| 2026-08-18 | Interfaces.md | Updated Driver Profile JSON schema: added Username, Limit, DisplayLimit, Role_Template_Safe, Role_Group_Prefix; removed ParallelThreads (never implemented); updated field reference table accordingly |
| 2026-08-18 | Architecture.md | Updated Build Status table (all components Complete); added four Design Decision rows: List-first sort, DisplayLimit, By-Safe accounts mode, Role profile fields |
| 2026-08-18 | Lessons-Learned-PowerShell-Pester.md | Added Section 15 — session token NoteProperty preservation (15.1 copy-before-replace pattern; 15.2 Warning branch must not call Invoke-TokenRefresh); Section 16 — ISPSS runtime behaviors (16.1 groupType='Vault' on all groups, 16.2 20K account cap and per-safe workaround, 16.3 OData filter single-quoting for names with spaces); Section 17 — script-scoped helper functions in dot-sourced modules |
