# Testing Plan

## Overview

This document describes the testing strategy for the Idira Unified Scripts project.
Tests are organized into **unit tests** (no live CyberArk connection required) and
**integration tests** (require a real CyberArk environment). All unit tests use
[Pester v5/v6](https://pester.dev) and live under `Tests\Unit\`.

**Current focus: Self-Hosted PVWA.** This revision of the plan was produced for a full
functional test pass of the **Self-Hosted** deployment path specifically. See
[Self-Hosted vs. Privilege Cloud (SaaS) Scope and Caution](#self-hosted-vs-privilege-cloud-saas-scope-and-caution)
below before relying on this document for ISPSS/Privilege Cloud testing — the SaaS path has
**not** been fully tested, and several modules that declare support for both platforms have
only ever been exercised against Self-Hosted.

**See also:** `E2E-Automation-Design.md` — a proposed (not yet built) automated layer that would
exercise this document's manual checklist items against a real tenant with only credential entry
requiring a human. This document remains the source of truth for what the current, entirely-manual
process covers; the other tracks progress toward automating it.

---

## Test Environments

| Environment | Purpose | Required For |
|---|---|---|
| Local (no network) | Unit tests, mocked API | All unit tests |
| CyberArk ISPSS (dev/lab) | Integration tests — ISPSS | Auth, API module integration |
| CyberArk SelfHosted (dev/lab) | Integration tests — SelfHosted | Auth, API module integration |

A live Self-Hosted PVWA test/lab host is available for this test pass. Configure a profile with
`SystemType = Self-Hosted`, `BaseURL` pointed at that host, and `AppName = PasswordVault` (default)
unless the environment uses a custom application name. Do not run integration tests against
production environments, and prefer a dedicated test Safe/test accounts for any write operation
(Add/Update/Delete) so real vault data is never at risk.

**Do not run integration tests against production environments.**

---

## Self-Hosted vs. Privilege Cloud (SaaS) Scope and Caution

Every API module declares `$ModuleMeta.SupportedSystems` as `@('SelfHosted')`,
`@('ISPSS')`, or `@('ISPSS', 'SelfHosted')` (dual-use). As of this revision (post Phase 0-2 of
`aPePAS-Improvement-Plan-2026-09-02.md` — see `Documentation-Tracker.md` for the full history):

- **SelfHosted-only (4 modules):** `Platforms/Invoke-PlatformsRename.ps1` (confirmed via psPAS's
  explicit version/platform assertion — a PVWA 15.0+ feature), the entire new `Policies`
  category (`GetMasterPolicy`, `SetMasterPolicy` — confirmed the same way, PVWA 14.6+), and
  `Reports/Invoke-ReportsList.ps1`. These are hidden from the menu entirely for an ISPSS profile.
  - **`Reports/Invoke-ReportsList.ps1` is Self-Hosted-only again** — Phase 1 (earlier this
    session) had expanded it to dual-use based on psPAS's own comparison review claiming ISPSS
    support from v14.6+, but the user tested it live against an ISPSS/Privilege Cloud tenant on
    2026-09-02 and got an HTTP 404 (`GET /API/Reports` does not exist there). Reverted to
    `SupportedSystems = @('SelfHosted')`.
  - **`Applications` (all 7 modules) are confirmed dual-use** — the user tested the ISPSS
    Applications menu on 2026-09-02: only `Add` was visible (it was the only one already marked
    dual-use), confirming the other 6 (`AddAuthMethod`, `Delete`, `DeleteAuthMethod`, `Get`,
    `List`, `ListAuthMethods`) had been Self-Hosted-only in error. All 7 now declare
    `SupportedSystems = @('ISPSS', 'SelfHosted')`. Only menu visibility has been confirmed on
    ISPSS for the 6 newly-expanded modules — their actual request/response behavior against a
    live ISPSS tenant remains unverified (see the checklist below).
- **Dual-use (the remaining 61 of 65 total modules, across Accounts, Safes, SafeMembers, Platforms
  (8 of its 9 actions), Applications, Users, Groups, Custom):** declared to support both
  platforms,
  but **ISPSS coverage for most of this set has not been fully tested** — most of the deep,
  iterative bug-fixing history in `Documentation-Tracker.md` was driven by Self-Hosted testing/use.
  Treat a dual-use module's ISPSS behavior as unverified until someone actually exercises it
  against a Privilege Cloud tenant, even though the code path is shared. Two specific items *were*
  confirmed live on ISPSS during Phase 0/1 (this session): `Get-PVWASessionTimeoutMinutes`
  (`/api/Settings/Timeout`) 404s on Privilege Cloud and correctly falls back to a default; and
  `Invoke-AccountsResumeAutoManagement.ps1`'s ISPSS path was deliberately left unchanged
  (unconfirmed) when its Self-Hosted endpoint was corrected, specifically to avoid guessing at
  ISPSS behavior that hadn't been verified.
- **Known, already-confirmed platform-specific traps inside dual-use modules** (background for
  anyone testing or extending these — not new findings from this pass, see
  `Lessons-Learned-PowerShell-Pester.md` Section 16 for the originals):
  - ISPSS returns `groupType='Vault'` (and no `directory.directoryType`) for **every** group,
    including LDAP/directory-backed ones. `Groups/Invoke-GroupsList.ps1`'s `GroupType` filter is
    effectively unusable on ISPSS as a result — filtering for anything but `Vault` silently
    returns zero rows with no explanation. `Custom/Invoke-CustomExportGroupMembersLDAP.ps1` and
    `Custom/Invoke-CustomExportGroupMembersLocal.ps1` both work around this with a
    groupName-contains-`@` heuristic (this session fixed the Local module, which had not received
    that fix when the LDAP module did — see the Findings section below).
  - CyberArk's `/API/Accounts` endpoint caps results at roughly 20,000 without a safe filter
    (`Invoke-AccountsList.ps1`'s "By-Safe" mode works around this) — confirm whether the same cap
    applies identically on the Self-Hosted PVWA version under test; it may differ by version.
  - Field-name/response-shape differences by PVWA version are common for Platforms (`id` vs
    `PlatformID`, `platformType` vs `SystemType`, nested under `general` or at the root) and Safe
    Members (camelCase vs PascalCase permission keys) - see Lessons-Learned Sections 12 and 19.
    These were previously fixed for `Invoke-PlatformsGet.ps1`; this session found and fixed the
    same gap in `Invoke-PlatformsList.ps1` (see Findings below). When testing against the live
    Self-Hosted host, note its exact PVWA version so a future field-shape mismatch can be
    correlated to a version boundary.
  - `SafeMembers/Invoke-SafeMembersAdd.ps1` and `SafeMembers/Invoke-SafeMembersAddFromTemplateRole.ps1`
    call `GET /API/Configuration/LDAP/Directories` for the interactive "SearchIn" directory
    picker; the exact response field names for that endpoint were unconfirmed against a live
    system when written (falls back to Vault-only, never blocks the flow, but verify the picker
    actually lists real directories against the live host).
  - `Safes/Invoke-SafesAssignCPM.ps1` queries `GET /API/Users?userType=CPM&componentUser=true`
    live for its CPM picker (deliberately different from `Safes/AddFromTemplate`'s profile-based
    `CPM_List`) — confirm this query returns the expected CPM accounts on the live host.
- **Recommendation for any module found broken specifically on ISPSS while dual-declared:**
  follow the precedent already set by `Custom/Invoke-CustomExportGroupMembersLocal.ps1` /
  `Invoke-CustomExportGroupMembersLDAP.ps1` — fix the platform-specific branch in place rather
  than forking the file, *unless* the SelfHosted and ISPSS implementations diverge so much that a
  shared function body is no longer readable/maintainable, in which case split into
  `Invoke-<Category><Action>.ps1` (SelfHosted) and a distinctly-named ISPSS counterpart, following
  the same pattern already used for the Auth layer (`CyberArk.Auth.SelfHosted.psm1` vs
  `CyberArk.Auth.ISPSS.psm1`).

---

## Running Tests

```powershell
# Run all unit tests (from the project root)
.\Tests\Run-Tests.ps1

# Run a single test file
.\Tests\Run-Tests.ps1 -Path Tests\Unit\CyberArkLogging.Tests.ps1

# Run with verbose output
.\Tests\Run-Tests.ps1 -Verbosity Detailed
```

Pester v5 is required. `Run-Tests.ps1` checks for it and prints installation
instructions if it is missing.

---

## Component Test Matrix

This table was significantly out of date relative to the actual `Tests\Unit\` folder (which
already had unit tests for every shipped module) — it listed only a handful of modules. It now
lists every component and module that exists in this project, its unit-test file, and whether it
also needs manual/live Self-Hosted integration verification per this test pass. "SH" = SupportedSystems
includes SelfHosted; "Both" = SelfHosted + ISPSS declared (see the caution section above).

### Core / Shared

| Component | Unit Tests | Test File | Live Self-Hosted Verification Needed |
|---|---|---|---|
| `CyberArkLogging.psm1` | Yes | `Unit\CyberArkLogging.Tests.ps1` | No |
| `CyberArkComms.psm1` | Partial (helpers + success path; 401/429/504 error paths need `Invoke-CyberArkAPI` mocking at the module-caller level - see Testing Boundaries) | `Unit\CyberArkComms.Tests.ps1` | Yes — 429 backoff and 504 retry/page-shrink against a real PVWA; also confirm behavior is unchanged if the driver is ever run under PowerShell 7/`pwsh` instead of Windows PowerShell 5.1 (see Known Issues) |
| `Auth\CyberArk.Auth.Common.psm1` | No (WebView2/cert-store/DPAPI all require a live Windows session) | — | Yes — `Save-AuthToken`/`Import-AuthToken` round-trip, `Get-FilteredClientCertificate` picker |
| `Auth\CyberArk.Auth.SelfHosted.psm1` | No (auth flows) | — | Yes (manual, all 8 methods — see the dedicated section below) |
| `Auth\CyberArk.Auth.ISPSS.psm1` | No (auth flows) | — | Out of scope for this pass (ISPSS) |
| `Manage-Privilege.ps1` — profile CRUD | Yes (filesystem) | `Unit\Manage-Privilege.Tests.ps1` | No |
| `Manage-Privilege.ps1` — session loop, keepalive, token refresh, CSV loop | No (UI/interactive) | — | Yes (manual — D-series below, including the new D23-D25 regression/known-gap cases) |

### APIModules — SelfHosted only (no ISPSS ambiguity)

| Module | Unit Tests | Test File | Live Self-Hosted Verification Needed |
|---|---|---|---|
| Platforms / Rename | Yes | `Unit\Invoke-PlatformsRename.Tests.ps1` | Yes — PVWA 15.0+ required, confirm against this lab host's actual version |
| Policies / GetMasterPolicy | Yes | `Unit\Invoke-PoliciesGetMasterPolicy.Tests.ps1` | Yes — PVWA 14.6+ required |
| Policies / SetMasterPolicy | Yes | `Unit\Invoke-PoliciesSetMasterPolicy.Tests.ps1` | Yes — PVWA 14.6+ required. Mutates tenant-wide config, not a scoped object — test against a dedicated lab host only, never a shared/production one |

### APIModules — dual-use (Both; ISPSS coverage unverified — see caution section)

| Module | Unit Tests | Test File | Live Self-Hosted Verification Needed |
|---|---|---|---|
| Accounts / Add | Yes | `Unit\Invoke-AccountsAdd.Tests.ps1` | Yes |
| Accounts / CancelCpmTask | Yes | `Unit\Invoke-AccountsCancelCpmTask.Tests.ps1` | Yes |
| Accounts / ChangeImmediate | Yes | `Unit\Invoke-AccountsChangeImmediate.Tests.ps1` | Yes |
| Accounts / ChangeInVault | Yes | `Unit\Invoke-AccountsChangeInVault.Tests.ps1` | Yes — confirm the corrected `Password/Update` endpoint (F12, this session — was `SetNextPassword` before) actually changes the vault password immediately; also confirm the JSON-key log-masking pattern keeps the new vault password out of the log file at DEBUG level against a real call |
| Accounts / CheckIn | Yes | `Unit\Invoke-AccountsCheckIn.Tests.ps1` | Yes |
| Accounts / Delete | Yes | `Unit\Invoke-AccountsDelete.Tests.ps1` | Yes |
| Accounts / Get | Yes | `Unit\Invoke-AccountsGet.Tests.ps1` | Yes |
| Accounts / GetActivity | Yes | `Unit\Invoke-AccountsGetActivity.Tests.ps1` | Yes |
| Accounts / GetCredential | Yes | `Unit\Invoke-AccountsGetCredential.Tests.ps1` | Yes |
| Accounts / LinkAccount | Yes | `Unit\Invoke-AccountsLinkAccount.Tests.ps1` | Yes |
| Accounts / List (incl. By-Safe mode) | Yes | `Unit\Invoke-AccountsList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted |
| Accounts / Reconcile | Yes | `Unit\Invoke-AccountsReconcile.Tests.ps1` | Yes |
| Accounts / ResumeAutoManagement | Yes | `Unit\Invoke-AccountsResumeAutoManagement.Tests.ps1` | Yes |
| Accounts / UnlinkAccount | Yes | `Unit\Invoke-AccountsUnlinkAccount.Tests.ps1` | Yes |
| Accounts / Unlock | Yes | `Unit\Invoke-AccountsUnlock.Tests.ps1` | Yes |
| Accounts / Update (JSON Patch) | Yes | `Unit\Invoke-AccountsUpdate.Tests.ps1` | Yes |
| Accounts / Verify | Yes | `Unit\Invoke-AccountsVerify.Tests.ps1` | Yes |
| Safes / Add | Yes | `Unit\Invoke-SafesAdd.Tests.ps1` | Yes |
| Safes / AddFromTemplate | Yes | `Unit\Invoke-SafesAddFromTemplate.Tests.ps1` | Yes |
| Safes / AssignCPM | Yes | `Unit\Invoke-SafesAssignCPM.Tests.ps1` | Yes — confirm the live CPM query against the real host |
| Safes / Delete | Yes | `Unit\Invoke-SafesDelete.Tests.ps1` | Yes |
| Safes / Get | Yes | `Unit\Invoke-SafesGet.Tests.ps1` | Yes |
| Safes / List | Yes | `Unit\Invoke-SafesList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted |
| Safes / UnassignCPM | Yes | `Unit\Invoke-SafesUnassignCPM.Tests.ps1` | Yes |
| Safes / Update | Yes | `Unit\Invoke-SafesUpdate.Tests.ps1` | Yes |
| SafeMembers / Add | Yes | `Unit\Invoke-SafeMembersAdd.Tests.ps1` | Yes — confirm the SearchIn directory picker lists real LDAP directories |
| SafeMembers / AddFromTemplateRole | Yes | `Unit\Invoke-SafeMembersAddFromTemplateRole.Tests.ps1` | Yes |
| SafeMembers / List | Yes | `Unit\Invoke-SafeMembersList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted |
| SafeMembers / Remove | Yes | `Unit\Invoke-SafeMembersRemove.Tests.ps1` | Yes |
| SafeMembers / Update | Yes | `Unit\Invoke-SafeMembersUpdate.Tests.ps1` | Yes |
| SafeMembers / UpdateFromTemplateRole | Yes | `Unit\Invoke-SafeMembersUpdateFromTemplateRole.Tests.ps1` | Yes |
| Platforms / Copy | Yes | `Unit\Invoke-PlatformsCopy.Tests.ps1` | Yes — Target platforms only this pass (see `E2E-Automation-Design.md`); confirmed against psPAS source + the 14.6 Swagger spec, never against a live tenant |
| Platforms / Disable | Yes | `Unit\Invoke-PlatformsDisable.Tests.ps1` | Yes — same caveat as Copy |
| Platforms / Enable | Yes | `Unit\Invoke-PlatformsEnable.Tests.ps1` | Yes — same caveat as Copy |
| Platforms / Get | Yes | `Unit\Invoke-PlatformsGet.Tests.ps1` | Yes |
| Platforms / Import | Yes | `Unit\Invoke-PlatformsImport.Tests.ps1` | Yes — the ZIP-as-byte-array request shape is unverified against a live tenant (see its own code comment and `E2E-Automation-Design.md`) |
| Platforms / List | Yes | `Unit\Invoke-PlatformsList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted (the alternate-field-name fallback and `SystemType` filter noted here are covered by that confirmation) |
| Platforms / Remove | Yes | `Unit\Invoke-PlatformsRemove.Tests.ps1` | Yes — destructive; test against a disposable sandbox platform only, same caveat as Copy otherwise |
| Platforms / SetPSMConfig | Yes | `Unit\Invoke-PlatformsSetPSMConfig.Tests.ps1` | Yes — same caveat as Copy; needs a real PSM server ID from the test tenant |
| Applications / Add | Yes | `Unit\Invoke-ApplicationsAdd.Tests.ps1` | **Confirmed (2026-09-02)** — the only Applications action the user found visible/working on the ISPSS Applications menu, confirming its earlier dual-use `SupportedSystems` |
| Applications / AddAuthMethod | Yes | `Unit\Invoke-ApplicationsAddAuthMethod.Tests.ps1` | Menu visibility only — user's 2026-09-02 ISPSS test showed this action missing from the menu (it was still Self-Hosted-only); now expanded to dual-use. Actual ISPSS request/response behavior is unverified |
| Applications / Delete | Yes | `Unit\Invoke-ApplicationsDelete.Tests.ps1` | Menu visibility only — same 2026-09-02 finding and expansion as AddAuthMethod above; ISPSS request/response behavior unverified |
| Applications / DeleteAuthMethod | Yes | `Unit\Invoke-ApplicationsDeleteAuthMethod.Tests.ps1` | Menu visibility only — same 2026-09-02 finding and expansion as AddAuthMethod above; ISPSS request/response behavior unverified |
| Applications / Get | Yes | `Unit\Invoke-ApplicationsGet.Tests.ps1` | Menu visibility only — same 2026-09-02 finding and expansion as AddAuthMethod above; ISPSS request/response behavior unverified |
| Applications / List | Yes | `Unit\Invoke-ApplicationsList.Tests.ps1` | **Confirmed (2026-09-02) on Self-Hosted** (the `Join-CyberArkUrl` trailing-slash/PIMServices.svc routing fix noted here is covered by that confirmation). On ISPSS, only menu visibility was confirmed the same day — it had been Self-Hosted-only and is now expanded to dual-use; ISPSS request/response behavior is unverified |
| Applications / ListAuthMethods | Yes | `Unit\Invoke-ApplicationsListAuthMethods.Tests.ps1` | Self-Hosted: Yes — **not** covered by the "all List actions confirmed" status below, since its `Action` is `ListAuthMethods`, not `List`. The blank-`AppID`-lists-every-application behavior (added this session, per user request) is new and unverified against a real host. On ISPSS, only menu visibility was confirmed 2026-09-02 — it had been Self-Hosted-only and is now expanded to dual-use; ISPSS request/response behavior is unverified |
| Reports / List | Yes | `Unit\Invoke-ReportsList.Tests.ps1` | **Confirmed Self-Hosted-only (2026-09-02)** — the user tested this live against an ISPSS/Privilege Cloud tenant and got an HTTP 404 (`GET /API/Reports` doesn't exist there), reversing Phase 1's dual-use expansion. `SupportedSystems` reverted to `@('SelfHosted')`; the module is now hidden from the ISPSS menu entirely |
| Users / Get | Yes | `Unit\Invoke-UsersGet.Tests.ps1` | Yes |
| Users / List | Yes | `Unit\Invoke-UsersList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted |
| Groups / Add | Yes | `Unit\Invoke-GroupsAdd.Tests.ps1` | Yes |
| Groups / AddMember | Yes | `Unit\Invoke-GroupsAddMember.Tests.ps1` | Yes |
| Groups / Delete | Yes | `Unit\Invoke-GroupsDelete.Tests.ps1` | Yes |
| Groups / GetMembers | Yes | `Unit\Invoke-GroupsGetMembers.Tests.ps1` | Yes |
| Groups / List | Yes | `Unit\Invoke-GroupsList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted (the `GroupType` filter noted here is covered by that confirmation) |
| Groups / RemoveMember | Yes | `Unit\Invoke-GroupsRemoveMember.Tests.ps1` | Yes |
| Groups / Update | Yes | `Unit\Invoke-GroupsUpdate.Tests.ps1` | Yes |
| Custom / ExportAll | Yes | `Unit\Invoke-CustomExportAll.Tests.ps1` | Yes — now also discovers and runs Applications/ListAuthMethods (added this session, per user request), not previously part of Export All. That specific addition is unverified against a real host |
| Custom / ExportEntitlements | Yes | `Unit\Invoke-CustomExportEntitlements.Tests.ps1` | Yes |
| Custom / ExportGroupMembersLDAP | Yes | `Unit\Invoke-CustomExportGroupMembersLDAP.Tests.ps1` | Yes — requires line-of-sight from wherever the script runs to the actual Active Directory (ADSI-based, not a CyberArk API call) |
| Custom / ExportGroupMembersLocal | Yes (incl. new ISPSS-groupType-quirk regression test this session) | `Unit\Invoke-CustomExportGroupMembersLocal.Tests.ps1` | Yes |
| Custom / TestApi | **No unit test file exists** (interactive raw API tester — same exemption class as other `Read-Host`-driven helpers) | — | Yes (manual smoke test only) |
| Custom / TestConnectivity | Yes (orchestration mocked; DNS/TCP helpers, `ConvertTo-Win32QuotedArgument`, and `Find-PlinkExecutable` exercised for real/mocked deterministically - no CyberArk connection needed for those) | `Unit\Invoke-CustomTestConnectivity.Tests.ps1` | Partially — confirmed live against a real test host (172.21.20.14): the `ArgumentList`-crash fix (F23), the PS7 path's unknown-host-key hang fix (F25, though the path still times out on a real password attempt - a separate, unresolved limitation), and plink failing fast rather than hanging on an unrecognized host key (F27). Not yet confirmed live: the actual SMB (`New-SmbMapping`) auth attempt, and a *successful* password auth via either plink or the PS7 path (no real target credentials were available this session). Also confirm the `Safe`/`Username`/`PasswordSource` output columns (F22) against a real vault-backed lookup, and the Address-in-filename change (F26) for a real single interactive run |

---

## Findings and Fixes — 2026-09-02 Self-Hosted Review

This full-project review (triggered by the request to produce a Self-Hosted test plan and fix
anything found broken) turned up and fixed the following. All fixes were made via careful static
code reading and cross-reference against this project's own `Documentation-Tracker.md` and
`Lessons-Learned-PowerShell-Pester.md` history; **no PowerShell interpreter was available in the
environment this review was performed in**, so none of the fixes below have been executed against
a real PVWA or run through Pester yet — see the "Yes" rows in the Component Test Matrix above and
the checklist later in this document for what still needs live confirmation.

| # | File(s) | Issue | Fix | Test(s) added |
|---|---|---|---|---|
| F01 | `Modules/CyberArkComms.psm1` | `Join-CyberArkUrl` unconditionally trims a trailing slash from the joined URI. The legacy `PIMServices.svc` WCF REST endpoint used by every `Applications` module needs that trailing slash preserved on some routes (e.g. `Applications` list) or the request is misrouted/rejected. The slash was added once (2026-08-16) to fix this, then reverted the same day to resolve an unrelated regression in test C12, and never re-fixed. | `Invoke-CyberArkAPI` now restores the trailing slash at the call site, based on the caller's own `-Endpoint` string, when present — without changing `Join-CyberArkUrl`'s generic (always-trimmed) contract. | C25b, C25c in `CyberArkComms.Tests.ps1` |
| F02 | `Modules/CyberArkLogging.psm1` | The sensitive-data log-masking regex list only matched a hardcoded set of OAuth field names (`access_token`, `refresh_token`, `id_token`). Any other secret-shaped JSON key — notably `NewCredentials` (the literal new vault password) in `Invoke-AccountsChangeInVault.ps1`'s request body — was logged in cleartext at DEBUG/`-FileOnly` level via `CyberArkComms.psm1`'s request-body logging. | Added a generic pattern matching any quoted JSON key containing `password`, `secret`, `token`, or `credential` (case-insensitive), masking the value regardless of key name. | L22a, L22b, L22c in `CyberArkLogging.Tests.ps1` |
| F03 | `APIModules/Applications/Invoke-ApplicationsAdd.ps1` | `[int]$AccessFrom` / `[int]$AccessTo` casts on CSV input throw an unhandled exception (crashing the whole batch) if the CSV cell isn't a clean integer. | Replaced with `[int]::TryParse`, returning a normal non-fatal `Failures` entry with an `ErrorMessage` instead of throwing. | New tests under "AccessPermittedFrom / AccessPermittedTo validation" in `Invoke-ApplicationsAdd.Tests.ps1` |
| F04 | `APIModules/Reports/Invoke-ReportsList.ps1` | Dot-notation access on 6 result fields (`ReportID`, `ReportName`, `Description`, `ReportType`, `RunDate`, `Aggregated`) throws `PropertyNotFoundException` under strict mode (always active via the driver) if the live PVWA response omits any of them. | Added `PSObject.Properties[...]` existence guards on all 6 fields. | RL08a (with `Set-StrictMode -Version Latest` and a sparse report object) in `Invoke-ReportsList.Tests.ps1` |
| F05 | `Invoke-ApplicationsAdd.ps1` (`Disabled`), `Invoke-ApplicationsAddAuthMethod.ps1` (`IsFolder`, `AllowInternalScripts`), `Invoke-ApplicationsList.ps1` (`IncludeSublocations`), `Invoke-PlatformsList.ps1` (`ActiveOnly`), `Invoke-SafesList.ps1` (`ExtendedDetails`) | Five separate modules cast a CSV-sourced string directly to `[bool]`. In .NET, `[bool]"false"` evaluates to `$true` (any non-empty string is truthy), so every CSV row with the literal text `false` was silently treated as `true`. | All five now use a `-match '(?i)^(true|yes|y|1)$'`-style pattern instead of a `[bool]` cast. | New CSV-string "false"/"true" tests added to each module's test file (see Component Test Matrix rows above) |
| F06 | `APIModules/Platforms/Invoke-PlatformsList.ps1` | Field-mapping only checked one shape of the platform object (`PlatformID`/`SystemType`/nested `general`), while `Invoke-PlatformsGet.ps1` already had a 4-variant fallback chain for PVWA-version differences (`id` vs `PlatformID`, `platformType` vs `SystemType`, `general` sub-object vs root). `PlatformsList` would silently return blank fields against a PVWA version whose List response used the shape `Get` already handled. | Rewrote `PlatformsList`'s mapping to mirror `PlatformsGet`'s full fallback chain. | PL12a (alt-shape object) in `Invoke-PlatformsList.Tests.ps1` |
| F07 | `APIModules/Custom/Invoke-CustomExportGroupMembersLocal.ps1` | ISPSS returns `groupType='Vault'` for every group, including LDAP-backed ones, with no `directoryType` to disambiguate. The sibling `ExportGroupMembersLDAP` module already had an `@`-in-name heuristic to detect LDAP groups despite this; `ExportGroupMembersLocal` did not, so on ISPSS it would misclassify LDAP groups as local ones. | Added the same `-or ($gname -and $gname -match '@')` condition to the `$isLdap` check. | New "ISPSS groupType quirk" context in `Invoke-CustomExportGroupMembersLocal.Tests.ps1` |
| F08 | `Manage-Privilege.ps1` — `Invoke-SelfHostedKeepalive` | The keepalive call extends the session's expiry on the PVWA side but never persisted the new expiry to the saved `.cred` file. A crash or unexpected exit shortly after a keepalive would leave the on-disk token looking expired sooner than it actually was. | Added a `Save-AuthToken` call after a successful keepalive. | Not unit-tested (see note below) |
| F09 | `Manage-Privilege.ps1` — inner category/action loop (`Invoke-SessionLoop`) | The outer (category-selection) menu loop ran inactivity-timeout, proactive-refresh, and token-expiry checks on every iteration; the **inner** (action-within-category) loop did not run any of them. A user who stayed inside one category performing many actions in a row never got a keepalive, a proactive refresh, or an inactivity timeout until they backed out to the category menu. | Duplicated the outer loop's check block (inactivity check, `Invoke-ProactiveRefresh`, `Test-TokenExpiry` handling for `Expired`/`Warning`) at the top of the inner loop. | Not unit-tested (see note below) |
| F10 | `Auth/Get-AuthToken.ps1` | Dead file — a legacy shim with zero real call sites (only referenced by an unrelated same-named Pester mock stub), left over from the Auth-module rework. `Auth-Module-Rework-Design.md` itself documents deleting this file as a never-executed final step of that rework. | Deleted. | N/A |
| F11 | `README.md`, `Docs/API-Module-Development-Guide.md`, `Docs/Interfaces.md` | Stale documentation: project-structure trees still listed the deleted `Get-AuthToken.ps1`; `Interfaces.md` described `Invoke-WebView2Window`'s actual parameters and return shape incorrectly, and showed `Get-SelfHostedAuthToken`'s `AuthMethod`/`PVWAUrl` as falsely `[Parameter(Mandatory)]` when both actually fall back to interactive `Read-Host` prompts if omitted. | Corrected all three documents to match the actual code. | N/A (documentation only) |
| F12 | `APIModules/Accounts/Invoke-AccountsChangeInVault.ps1` | Called the wrong endpoint: `POST /API/Accounts/{id}/SetNextPassword`, which per the Swagger spec (`Swagger/CyberArk_PasswordVault_Swagger_14.6.v1.json`) "gives the ability to set the account's credentials for the next CPM change" — a queued-for-CPM operation, not an immediate vault-only change. The module's own name and description ("Change Credentials In Vault"/"does not change on the target system") match `POST /API/Accounts/{id}/Password/Update` instead, confirmed both by the Swagger spec's description ("set the account's credentials and change it in the Vault. This will not affect the credentials on the target device") and by psPAS's `Invoke-PASCPMOperation.ps1`, which treats `Password/Update` and `SetNextPassword` as two distinct parameter sets. Reported directly by the user. | Changed the endpoint to `/API/Accounts/{id}/Password/Update`. The request body was already correct (`NewCredentials`) — both endpoints share that field name per the Swagger `ChangeInVaultProperties`/`SetNextCredentialsProperties` schemas. | No new test added — the existing test file mocks `Invoke-CyberArkAPI` generically and doesn't assert on the endpoint string |
| F13 | `Manage-Privilege.ps1` — `Invoke-ActionModule` (results display) | `[FATAL] PropertyNotFoundException` on `.Count`, reported directly by the user, for any `List` action that returns exactly one row. `$tableData = if ($meta.Action -eq 'List') {@(...)} else {@($result.Results)}` had no outer `@(...)` wrapping the whole `if/else` — when the branch emitted exactly one object, PowerShell auto-unrolled it onto the pipeline as a bare scalar instead of a one-element array (the single/some-item counterpart of the empty-collapses-to-`$null` bug already documented as Lessons-Learned 9.8), and `$tableData.Count` on the very next line threw under `Set-StrictMode`. A second, identical assignment two lines later (`$displayData = if (...) {...} else {$tableData}`) had the same latent bug. | Wrapped both entire `if/else` expressions in an outer `@(...)` (`$tableData = @(if (...) {...} else {...})`), matching the already-established fix pattern from 9.8. Verified directly against real `powershell.exe` (Windows PowerShell 5.1) before and after — `pwsh`/PowerShell 7 does not reproduce the exception at all, since PS7 gives every scalar object a synthetic `Count` of `1`, masking the type defect. | No automated test added — `Invoke-ActionModule` is an interactive, `Read-Host`/dynamic-dispatch-driven function outside this project's established unit-testing boundary, and `Manage-Privilege.Tests.ps1` has a documented reproducible Pester v6.1 hang risk for new `Describe` blocks in this area (see the F08/F09 note below) |
| F14 | `APIModules/Accounts/Invoke-AccountsCancelCpmTask.ps1`, `Invoke-AccountsResumeAutoManagement.ps1` | Both call an endpoint with a minimum PVWA version requirement not previously accounted for: `/Cancel/` needs 15.2+ and `/Resume/` needs 15.0+ per the user (psPAS's own `Stop-PASCPMTask.ps1`/`Resume-PASCPMAutoManagement.ps1` assert `RequiredVersion 15.2` for both — a discrepancy from the user's stated 15.0 for Resume that's noted here but doesn't affect the fix, since neither this project nor psPAS has a reliable way to query the actual PVWA version). On an older PVWA, both endpoints simply don't exist. Reported directly by the user. | Per user direction: both modules now call the newer endpoint first; on an HTTP 404 specifically (any other failure - 401/403/500/network - stays a real, non-fallback error), they retry against a version-agnostic fallback and log a `WARN` noting the fallback. `CancelCpmTask` falls back to the pre-Phase-1 `/StopImmediateAutoMgmtOperations` endpoint (recovered from git history, commit `1f06d6e`'s parent). `ResumeAutoManagement` (Self-Hosted only - ISPSS already uses the fallback shape as its primary path) falls back to the same `PATCH .../ automaticManagementEnabled` JSON Patch body already used for ISPSS. | New tests in both modules' `*.Tests.ps1` files: fallback triggers and succeeds on 404, does NOT trigger on a non-404 failure (only one API call made), and the overall result is a failure when the fallback also fails |
| F15 | `APIModules/Custom/Invoke-CustomTestApi.ps1` | Reported directly by the user: the whole script process closes immediately with no error shown when the session token expires while using Test API. Root cause: this module is the only place in the codebase that enables the IgnoreSSL bypass via `[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }` - a raw PowerShell scriptblock assigned directly to a .NET delegate. Every other module instead goes through `Invoke-CyberArkAPI`'s `Disable-SSLValidation`, which uses a compiled `ICertificatePolicy` class. Assigning a scriptblock to `ServerCertificateValidationCallback` is a known hazard: if .NET's TLS stack invokes it off the runspace's own thread - plausible for a fresh handshake, such as the one triggered by a mid-session re-authentication request - it can silently crash the whole process with no catchable PowerShell exception, matching the reported symptom exactly. Not confirmed against a live repro (the user could not attach an error, since none is shown), but this is the only IgnoreSSL-bypass code in the entire codebase that deviates from the shared, already-safe pattern. | Exported `Disable-SSLValidation` from `CyberArkComms.psm1` (previously module-private, used only internally by `Invoke-CyberArkAPI`) and switched `Invoke-CustomTestApi.ps1` to call it instead of assigning the raw callback delegate. | No automated test added - this only matters when `IgnoreSSL` is enabled on the active profile, and this module has no existing unit test file (an interactive request/response loop, untested for the same `Show-FieldPrompt`-dependency reason as other interactive-only functions in this codebase). **Needs live verification specifically with `IgnoreSSL` enabled and a token allowed to expire mid-session** — if the crash recurs after this fix, the SSL-callback hypothesis is wrong and this needs further investigation |
| F16 | `APIModules/Custom/Invoke-CustomTestApi.ps1` | Found while using Test API to diagnose a separate live 400 error: a real CyberArk error response (400, `Content-Length: 80`, `Content-Type: application/json`) came back as `ResponseBody = null` in Test API's captured output. Root cause: Windows PowerShell 5.1's `Invoke-WebRequest` already reads the error response stream once internally to populate `$_.ErrorDetails.Message` before the `catch` block runs - by the time this module's own `catch [System.Net.WebException]` block tried to read `$webResp.GetResponseStream()` a second time, the stream was already consumed and returned empty, silently discarding the server's actual error body on every 4xx/5xx response this module has ever captured. | Changed the catch block to prefer `$caughtErr.ErrorDetails.Message` (which PowerShell already populated from the same stream) when non-empty, falling back to a manual stream read only if that's unexpectedly empty. | No automated test added, for the same reason as F15 (no unit test file exists for this interactive module) - **confirmed the fix is needed live** (the null-body repro above), but the fix itself has not yet been re-verified against a real 400 response |
| F17 | `Modules/CyberArkComms.psm1` | Per user request, following the F16 investigation: the live 400 turned out to be a legitimate CyberArk error (`PASWS001W: The account is locked by: [ca_jesse].`), not a bug in `Invoke-AccountsChangeInVault.ps1` - but `Invoke-CyberArkAPI`'s `ErrorMessage` only ever surfaced the bare `ErrorMessage` field, dropping the `ErrorCode` every module's own error text is built from. Since every module already composes its displayed/logged error from `$response.ErrorMessage`, none of them (except Test API, which shows the full raw body separately) ever showed the code. Investigating this also surfaced a real latent bug in `Parse-CyberArkError`: unguarded dot access on the parsed JSON meant a body with only one of `ErrorCode`/`ErrorMessage` (e.g. `{"ErrorMessage":"Not Found"}` with no code) threw `PropertyNotFoundException` under this module's own `Set-StrictMode`, silently discarding both fields instead of just the missing one - caught by the try/catch, but downgrading to a bare `"HTTP <code>"` fallback that lost the message even though it WAS present in the body. | `Parse-CyberArkError` now uses `PSObject.Properties[...]` guards for both fields. `Invoke-CyberArkAPI`'s two error-response-building sites now format `ErrorMessage` as `"<ErrorCode>: <ErrorMessage>"` when a code is present, falling back to the bare message (or `"HTTP <code>"`) otherwise - applied once, in the shared helper, so every module's own error text picks it up automatically with no per-module changes needed. | C29-C32 in `CyberArkComms.Tests.ps1`: code+message combines correctly for both 4xx and 5xx, a body with no `ErrorCode` falls back to the bare message, and a non-JSON body falls back to `"HTTP <code>"` without throwing |
| F18 | `APIModules/Custom/Invoke-CustomTestApi.ps1` | Per user request: the "Query Params" prompt appeared for every HTTP method, even though query parameters are conventionally only meaningful for `GET`. | The prompt is now skipped (query string forced to empty) for any method other than `GET`. | No automated test added, for the same reason as F15/F16 (no unit test file exists for this interactive module) |
| F19 | `Modules/CyberArkComms.psm1` | Per user request: "Error messages for failed requests should include the body information unless it is blank or null" - the F17 fix only covered the structured `ErrorCode`/`ErrorMessage` envelope; a body in any other shape (an IIS HTML error page, or JSON without those exact fields) still fell back to a generic, information-free `"HTTP <code>"` message even though the server sent real content. | `Format-CyberArkErrorMessage` (added for F17) now has a third preference tier: the raw response body, whenever it is non-blank, before falling back to the generic HTTP-status message. | C32 (updated) and new C33 in `CyberArkComms.Tests.ps1`: a non-blank non-JSON body is now included in `ErrorMessage`; a genuinely blank body still falls back to the bare `"HTTP <code>"` message |
| F20 | `APIModules/Safes/Invoke-SafesAdd.ps1`, `Invoke-SafesAddFromTemplate.ps1`, `Invoke-SafesAssignCPM.ps1`, `Manage-Privilege.ps1` | Per user request, three related changes to "screens that ask for a CPM": (1) Add Safe no longer prompts for `Location` interactively (always uses the default `\`); (2) Add Safe's `ManagingCPM` prompt now uses the same numbered picker as Add Safe From Template instead of free text; (3) all three CPM-picker screens now share one CPM source instead of three inconsistent per-module implementations - `Invoke-SafesAddFromTemplate.ps1` previously used only the profile's `CPM_List` (never queried live) and `Invoke-SafesAssignCPM.ps1` previously used only a live query (never fell back to `CPM_List`), a split Architecture.md had recorded as "per explicit direction, not an oversight" - that direction was explicitly superseded by this request. | Added `Get-CpmOptions` to `Manage-Privilege.ps1` (alongside similar shared driver-scope helpers like `Invoke-EntitySearch`): queries live via `GET /API/Users?userType=CPM&componentUser=true`, using that result whenever the call succeeds (even if empty - a real environment state, not a failure), falling back to the profile's `CPM_List` only on failure or a thrown exception. All three modules' own per-module CPM-source functions (`script:Get-ProfileCPMOptions`, `script:Get-SafesCPMOptions`) were deleted in favor of this one shared function. | No automated test added - like `Invoke-EntitySearch`, this class of driver-scope helper has no unit test coverage in this codebase, and `Manage-Privilege.Tests.ps1` has a documented Pester v6.1 hang risk for new `Describe` blocks. Manually verified all four cases (live success with results, live success empty, live failure, live exception) via a standalone `powershell.exe` repro instead. The 7 existing unit tests for the two deleted functions (T32-T35 in `Invoke-SafesAddFromTemplate.Tests.ps1`, A15-A17 in `Invoke-SafesAssignCPM.Tests.ps1`) were removed, since the functions they tested no longer exist |
| F21 | `Modules/CyberArkComms.psm1` | Per user report, live: `?search=` values containing a period fail to match on the CyberArk API - `[Uri]::EscapeDataString` treats `.` as an unreserved character (RFC 3986) and leaves it as a literal period, but these endpoints require it percent-encoded as `%2E` to work. Affects every module that searches by a value that can contain a period - usernames like `domain.user`, addresses/IPs, email-style account names - via `Invoke-EntitySearch`'s picker, `Invoke-AccountsLinkAccount.ps1`, `Invoke-CustomTestConnectivity.ps1`'s vault lookup, the several Platforms modules' by-ID search, and `Invoke-SafesAddFromTemplate.ps1`'s role-prefix group lookup. | `New-CyberArkQuery` now replaces `.` with `%2E` in a value's already-encoded form specifically when the query key is `search` (matched case-insensitively, since `Invoke-EntitySearch`'s Platforms callers use `-SearchParam 'Search'` while most direct callers use lowercase `search`). Applied once, in the shared query-builder every module already routes through via `Invoke-CyberArkAPI`, so no per-module changes were needed. | C34-C36 in `CyberArkComms.Tests.ps1`: a period in a lowercase `search` value is encoded, a period in a capitalized `Search` value is also encoded (case-insensitive key match), and a period in a non-search value (e.g. `filter`) is left alone |
| F22 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Per user request: the output had no way to tell, after the fact, whether a connection attempt used a password supplied directly or one pulled from the vault - and if from the vault, which specific account (Safe + Username) was used. | Added three columns to the result row: `Safe` and `Username` (the vaulted account's `safeName`/`userName`, populated only when a vault lookup actually matched and retrieved a credential - blank otherwise) and `PasswordSource` (`Provided` or `Vault`, set as soon as the password's origin is known, regardless of whether a vault lookup ultimately succeeds). `Resolve-VaultPassword` now returns `SafeName`/`Username` alongside `Password` for this purpose. | Updated TC11-TC12 (`Resolve-VaultPassword`'s new return fields) and TC20, TC21, TC27-TC29 (the three new output columns across the DNS-failure, direct-password, vault-success, and vault-failure paths) in `Invoke-CustomTestConnectivity.Tests.ps1`; also manually verified the full flow end-to-end under real `powershell.exe` strict mode |
| F23 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Reported directly by the user with a full stack trace: `[FATAL] PropertyNotFoundException: The property 'ArgumentList' cannot be found on this object`, crashing every Linux SSH auth attempt. Root cause: `ProcessStartInfo.ArgumentList` (added in .NET Framework 4.6.1) is not reliably usable under PS 5.1's `Set-StrictMode` - reproduced live on this very dev machine (.NET Framework 4.8) too, but as a *different* symptom (the property is present but silently evaluates to `$null` without `Set-StrictMode`; only throws the user's exact `PropertyNotFoundException` once strict mode is active, matching real production conditions since `Manage-Privilege.ps1` always sets it). Neither failure mode can be assumed away by checking the .NET Framework version or via `.GetType().GetProperty(...)` reflection - both looked "available" here despite failing at actual use. | Added `Invoke-ExternalProcessWithTimeout` a runtime probe (a disposable `ProcessStartInfo`, never the real one in use, wrapped in `try/catch` with a null-check) that falls back to the single-string `.Arguments` property with each argument manually quoted per Win32 command-line rules (new `ConvertTo-Win32QuotedArgument` helper) whenever `ArgumentList` isn't safely usable. Probing a separate object avoids ever leaving the real `ProcessStartInfo` in a partially-populated state if usage failed partway through. | New `ConvertTo-Win32QuotedArgument` `Describe` block (TC30-TC34) covering a plain argument, one with a space, one with an embedded quote, a trailing backslash, and an empty string. The manual-quoting fallback's real-child-process behavior was verified manually (not as an automated test - see the module's own code comment) since this dev machine's execution policy blocks running a `.ps1` file from `%TEMP%`, an unrelated sandbox restriction; the actual production code path never does that (it passes an inline command string to `plink`/`pwsh`, not a script file) |
| F24 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Per user request: the interactive Server Type prompt's description said "(or type the name)", inviting the user to type "Windows"/"Linux" when the intent was to select by number. | Changed the description to "Enter 1 for Windows or 2 for Linux." and changed the displayed default to the corresponding number (translating a prior value carried forward from `$Defaults['ServerType']`, e.g. from a CSV template, back to `1`/`2` for display) so the prompt stays number-only even on a repeat prompt. The underlying switch statement still accepts a typed `Linux`/`linux` value as a harmless legacy fallback - not removed, since only the prompt wording was reported as wrong | No automated test - `Get-CustomTestConnectivityInput` is excluded from unit testing for the same `Show-FieldPrompt`-dependency reason as every other interactive-only input function in this codebase |
| F25 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Reported by the user, guessing correctly: the Linux SSH auth test failed with a timeout, suspected to be waiting on host-key confirmation. Reproduced live against a real test host (172.21.20.14, provided by the user): with that host's key removed from `known_hosts`, `Test-LinuxSshAuth`'s PowerShell 7 SSH transport path hung for the full timeout, confirmed to be the interactive "unknown host key, continue connecting?" question having no way to be answered in this non-interactive child process. Separately discovered while verifying the fix: a timeout can *still* happen even with a known host key, because this path spawns `pwsh`/`ssh` with no console at all, and native OpenSSH's password prompt (already documented in this module as unreliable non-interactively) can hang the same way rather than failing fast the way it does with a real console attached - this is a pre-existing, separate limitation, not something this fix could also resolve. | Added `-Options @{StrictHostKeyChecking='no'}` to the `New-PSSession -SSHTransport` call - an OpenSSH `ssh_config` directive that auto-accepts (and still records, for next time) an unrecognized host key instead of asking. Confirmed live: this alone reduced a hanging first-connection attempt to under a second. The timeout `ErrorMessage` was also updated to mention the remaining password-prompt limitation and recommend `plink.exe` for reliable password testing. | No automated test - this is a live-network/live-process code path already excluded from unit testing per this module's own established convention (mocked in `Invoke-CustomTestConnectivity.Tests.ps1`); verified manually against the real test host instead, including confirming the fix does not regress the already-known-host case |
| F26 | `Manage-Privilege.ps1`, `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Per user request: the single-interactive-run auto-saved CSV for Test Connectivity was always named just `"Test Connectivity <date>.csv"`, so testing several servers one at a time in the same session would silently overwrite the same file each time. | Added a new optional `ModuleMeta.CsvFilenameField` (a generic, opt-in mechanism - not hardcoded to this one module by name) naming an `InputData` column whose value, when present and non-blank, is appended to the auto-saved filename. `Invoke-ActionModule`'s CSV-save block reads it via bracket notation (most modules don't declare it) and builds e.g. `"Test Connectivity - 172.21.20.14 <date>.csv"`. Only `Invoke-CustomTestConnectivity.ps1` declares it (`CsvFilenameField = 'Address'`) - other modules with their own `Address` column (`Invoke-AccountsAdd.ps1`, `Invoke-AccountsUpdate.ps1`) are unaffected, since they don't opt in. | Manually verified the filename-building logic in isolation (including that a module without the field declared, or a blank field value, is unaffected) - `Invoke-ActionModule`'s CSV-save block is not unit-tested (interactive driver code, same as `Invoke-EntitySearch` and similar) |
| F27 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Per user report: even with F25's host-key fix, a real Linux SSH auth attempt via the PS7 SSH transport path still timed out - confirming live the CAVEAT this module already documented (native OpenSSH cannot reliably submit a password non-interactively without a console). The user installed `plink.exe` at the project root and asked for it to be found there, and (mid-fix) also asked for it to be checked in the standard PuTTY install directories. | `Test-LinuxSshAuth` now tries plink FIRST (previously it was only used as a fallback when `pwsh` wasn't found, so a present-but-untried `pwsh` always won). New `Find-PlinkExecutable` helper checks, in the order the user specified: PATH, then the project root (`..\..\plink.exe` relative to this file), then `%ProgramFiles(x86)%\PuTTY\plink.exe`, then `%ProgramFiles%\PuTTY\plink.exe` (environment variables, not hardcoded drive letters). Verified live against the real test host with plink's own host-key cache genuinely empty (no `HKCU:\Software\SimonTatham\PuTTY\SshHostKeys` existed yet): unlike the PS7 path, plink correctly fails in well under a second with a clear, actionable "host key is not cached... Connection abandoned" message rather than hanging - confirmed PuTTY has no CLI equivalent to `StrictHostKeyChecking=no` (`-hostkey` requires the exact key already known), so this module doesn't try to work around that; the message it already produces tells the user what to do. | New `Find-PlinkExecutable` `Describe` block (TC36-TC39, mocking `Get-Command`/`Test-Path`/`Resolve-Path`): found on PATH short-circuits before checking anything else, found at the project root, found in Program Files (x86), and not found anywhere returns `$null` |

> **Note on F08/F09:** `Manage-Privilege.Tests.ps1` is documented (in `Documentation-Tracker.md`) as
> having a reproducible Pester v6.1 hang risk when new `Describe` blocks are added around
> `Invoke-FileWriteWithRetry`-adjacent code. No new automated test was added for these two driver
> fixes for that reason. **These two fixes are Self-Hosted-critical and must be verified manually**
> — see D23/D24 in the Manage-Privilege.ps1 manual test section below.

---

## Known Issues / Risk Register (not fixed this session — verify manually)

These were identified during this review but are **not yet fixed**. None of them block this test
pass, but each is a real gap worth confirming (or scheduling a follow-up fix for) during live
Self-Hosted testing.

| # | Area | Risk | Recommended manual check |
|---|---|---|---|
| K01 | `CyberArkComms.psm1` error handling | Assumes Windows PowerShell 5.1's `[System.Net.WebException]` typing for HTTP error responses. Behavior if this project is ever run under PowerShell 7/`pwsh` (where the underlying exception types differ) is untested and likely broken, even though the project is documented as Windows PowerShell 5.1 only. | Confirm the driver is never launched with `pwsh.exe`; consider adding an explicit version guard at startup if this risk needs closing. |
| K02 | Profile switching + `IgnoreSSL` | The SSL certificate validation bypass this profile setting enables is applied process-globally (not scoped to a single profile/session) and is never reset when the user switches from an `IgnoreSSL=$true` profile to a different profile in the same running session. | Test switching from an IgnoreSSL lab profile to a normal profile without restarting the script; confirm whether cert validation is (incorrectly) still bypassed. |
| K03 | WebView2 + `IgnoreSSL` | The `IgnoreSSL` profile setting appears to have no effect inside the embedded WebView2 browser control used for SAML/OIDC login — certificate validation in that control is governed separately from the setting. | If SAML/OIDC is tested against a lab host with a self-signed or internal CA certificate, confirm whether the WebView2 window shows a cert warning/blocks navigation regardless of `IgnoreSSL`. |
| K04 | Profile edit vs. active token | At several call sites, a freshly-edited `PVWAUrl` on a profile is not picked up if a token object saved under the old URL is still loaded — the stale `BaseURL` on the token object is used instead of the profile's current value. | Edit a profile's URL, then reuse a still-valid saved token for that profile; confirm which URL is actually called. |
| K05 | `Groups/Invoke-GroupsList.ps1` `GroupType` filter | Works correctly on Self-Hosted but is silently unusable on ISPSS (see the groupType caution above) with no warning surfaced to the user — a filtered ISPSS query just returns zero rows. | Out of scope for this Self-Hosted pass; flag as a UX follow-up if ISPSS is tested later. |
| K06 | `Update-SelfHostedAuthToken` | Falls back to an interactive `Read-Host` prompt rather than failing loudly when an expected stored credential is missing from `_RefreshContext`. In an unattended/scheduled context this would hang indefinitely waiting for console input rather than erroring out. | Not relevant to interactive manual testing; flag if this project is ever wrapped for unattended/scheduled use. |
| K07 | `Invoke-TokenRefresh` (SelfHosted branch) | Missing a `Username` fallback that the ISPSS branch has, for one re-authentication path. | Confirm re-authentication succeeds for all 8 Self-Hosted auth methods (see the Auth manual test section below) even when `Username` isn't pre-populated on the profile. |

---

## Testing Boundaries

### What unit tests cover
- Pure logic: formatting, filtering, field mapping, error branching
- Filesystem operations: log file creation, profile CRUD (using temp directories)
- HTTP layer: mocked via `Mock Invoke-WebRequest` (success path) and
  `Mock Invoke-CyberArkAPI` (all paths for API modules)

### What unit tests do NOT cover
- Real HTTP calls to CyberArk
- Browser-based auth flows (WebView2)
- Interactive UI prompts (`Read-Host`, file dialogs)
- DPAPI encryption/decryption on a different machine

### Limitations of comms module unit tests
`Invoke-CyberArkAPI` catches `[System.Net.WebException]` and reads
`$exception.Response` as `[System.Net.HttpWebResponse]`. That class cannot be
instantiated in pure PowerShell, so the HTTP error paths (401, 429, etc.) are
tested via the API module layer by mocking `Invoke-CyberArkAPI` directly. This
also applies to the 504 retry loop (fixed delay + page-size reduction) added in
`Invoke-CyberArkAPI` — it is not covered by an automated unit test for the same
reason the 429 retry loop isn't; verify it manually against a lab environment
that can be made to return 504 (or by temporarily lowering
`$script:MaxGatewayTimeoutRetries`/`$script:GatewayTimeoutDelaySec` and forcing
a timeout).

---

## CyberArkLogging.psm1 — Test Cases

### Initialize-CyberArkLog
| # | Test Case | Expected |
|---|---|---|
| L01 | Call with a temp `LogFolder` | Log file created under that folder |
| L02 | Log filename format | `yyyy-MM-dd_HHmmss_<Profile>_<PID>.log` |
| L03 | Startup header | First line is exactly 40 `*` characters |
| L04 | Startup info line | Contains PID, timestamp, ProfileName |
| L05 | WhatIf note in header | `[WhatIf ON]` present when `WhatIfMode=$true` |
| L06 | Folder created if missing | No error; folder exists after call |
| L07 | Destination = Console | No log file created |
| L08 | Invalid MinLevel | Throws with clear message |
| L09 | Invalid Destination | Throws with clear message |

### Write-CyberArkLog
| # | Test Case | Expected |
|---|---|---|
| L10 | INFO at INFO minimum | Line written to file |
| L11 | DEBUG at INFO minimum | Line NOT written |
| L12 | VERBOSE at DEBUG minimum | Line NOT written |
| L13 | WARN always written above INFO | Written |
| L14 | ERROR always written | Written |
| L15 | Bare mode | File contains only the message — no pipe separators |
| L16 | PID field — right-aligned, width 7 | `"  12345 \|"` |
| L17 | LEVEL field — centered, width 7 | `"  INFO  \|"`, `" ERROR \|"` |
| L18 | FunctionName — left-aligned, width 24 | Padded to 24 chars |
| L19 | Long FunctionName truncated | Ends with `…` at width 24 |
| L20 | Sensitive: `Authorization: Bearer <token>` | Token replaced with `***` |
| L21 | Sensitive: `password=abc123` | Value replaced with `***` |
| L22 | Sensitive: `"access_token":"xyz"` | Value replaced with `***` |
| L23 | Non-sensitive message | Unchanged |
| L24 | Auto-detected FunctionName | Caller's function name appears in line |
| L25 | Explicit FunctionName | Supplied name appears, not caller's |

### Add-CyberArkLogSummaryEntry + Close-CyberArkLog
| # | Test Case | Expected |
|---|---|---|
| L26 | No entries added | Close writes no summary block |
| L27 | One entry added | Summary block contains that module's row |
| L28 | Multiple entries | Per-module rows + totals row both present |
| L29 | Totals calculation | Sum of all ItemsProcessed / Successes / Failures correct |
| L30 | Summary divider lines | 40 `-` characters present |

### Remove-OldCyberArkLogs
| # | Test Case | Expected |
|---|---|---|
| L31 | File older than retention days | File deleted |
| L32 | File within retention window | File kept |
| L33 | Non-existent folder | No error; WARN logged |
| L34 | `-WhatIf` | No files deleted |

### Set-CyberArkLogLevel / Set-CyberArkLogDestination
| # | Test Case | Expected |
|---|---|---|
| L35 | Set level to VERBOSE, write VERBOSE | Written |
| L36 | Set level to ERROR, write WARN | Not written |
| L37 | Set destination to File | No console output |

---

## CyberArkComms.psm1 — Test Cases

### New-CyberArkQuery
| # | Test Case | Expected |
|---|---|---|
| C01 | Empty hashtable | Returns `""` |
| C02 | Single param | `?key=value` |
| C03 | Multiple params | `?key1=v1&key2=v2` (any order) |
| C04 | Null value omitted | Null key skipped |
| C05 | Empty string value omitted | Empty-string key skipped |
| C06 | Value with spaces | URL-encoded (`+` or `%20`) |
| C07 | Special chars in key | URL-encoded |

### Join-CyberArkUrl
| # | Test Case | Expected |
|---|---|---|
| C08 | Base + one segment | `https://host/seg` |
| C09 | Trailing slash on base trimmed | No double slash |
| C10 | Leading slash on segment trimmed | No double slash |
| C11 | Multiple segments | All joined with single `/` |
| C12 | Segment with trailing slash | Trimmed |

### New-CyberArkSearchFilter
| # | Test Case | Expected |
|---|---|---|
| C13 | Single criterion | `field eq value` |
| C14 | Two criteria, default AND | `f1 eq v1 AND f2 eq v2` |
| C15 | Value with spaces | `field eq "value with spaces"` |
| C16 | Custom operator OR | `f1 eq v1 OR f2 eq v2` |

### Invoke-CyberArkAPI — success path (mocked Invoke-WebRequest)
| # | Test Case | Expected |
|---|---|---|
| C17 | GET returns 200 + JSON | `IsSuccess=$true`, `DataType='JSON'`, `Data` parsed |
| C18 | POST returns 201 | `IsSuccess=$true`, `StatusCode=201` |
| C19 | 204 No Content | `IsSuccess=$true`, `DataType='Empty'`, `Data=$null` |
| C20 | WhatIf + POST | Request suppressed; returns `IsSuccess=$true`, `StatusCode=200` |
| C21 | WhatIf + PUT | Suppressed |
| C22 | WhatIf + DELETE | Suppressed |
| C23 | WhatIf + GET | NOT suppressed; request proceeds |
| C24 | QueryParams appended to URL | Mock called with correct URI |
| C25 | Body serialized to JSON | Mock called with JSON Content-Type |

### Invoke-CyberArkAPI — pagination (mocked)
| # | Test Case | Expected |
|---|---|---|
| C26 | Two pages returned | All items combined in `Data.value` |
| C27 | Final page has fewer than PageSize items | No further request made |
| C28 | `PageSize = 0` | Pagination disabled; single request |

---

## Invoke-SafesList.ps1 — Test Cases

### Module Metadata
| # | Test Case | Expected |
|---|---|---|
| S01 | `$ModuleMeta` is defined | Not null after dot-sourcing |
| S02 | Required fields present | Name, Category, Action, SupportedSystems, Version all present |
| S03 | SupportedSystems | Contains `ISPSS` and `SelfHosted` |
| S04 | SupportsWhatIf | `$false` |
| S05 | HasCustomInput | `$true` |
| S06 | AcceptsInputFile | `$false` |

### Invoke-SafesList — successful response (mocked Invoke-CyberArkAPI)
| # | Test Case | Expected |
|---|---|---|
| S07 | Returns standard result object shape | All 9 required fields present |
| S08 | Single safe returned | `Successes=1`, `ItemsProcessed=1`, `Failures=0` |
| S09 | Multiple safes returned | Count matches `value` array length |
| S10 | `safeName` mapped to `SafeName` | Correct value |
| S11 | `description` mapped | Correct value |
| S12 | `managingCPM` mapped | Correct value |
| S13 | `creator.name` mapped to `Creator` | Correct value |
| S14 | `creationTime` epoch → local date string | `yyyy-MM-dd` format |
| S15 | `creationTime = 0` or missing | No exception; `Created = ''` |
| S16 | `IsFatal` | `$false` on success |
| S17 | Search passed | `QueryParams.search` in mock call args |
| S18 | Filter passed | `QueryParams.filter` in mock call args |
| S19 | ExtendedDetails = true | `QueryParams.extendedDetails = 'true'` |
| S20 | Empty Search string | `search` key absent from QueryParams |
| S21 | Empty Filter string | `filter` key absent from QueryParams |
| S22 | ExtendedDetails = false | `extendedDetails` key absent |
| S23 | Null InputData | No exception; no query params sent |

### Invoke-SafesList — empty result
| # | Test Case | Expected |
|---|---|---|
| S24 | `value` array is empty | `Successes=0`, `IsFatal=$false`, `Failures=0` |
| S25 | `value` property missing | No exception; 0 results |

### Invoke-SafesList — API errors
| # | Test Case | Expected |
|---|---|---|
| S26 | `IsSuccess=$false`, StatusCode 403 | Error added, `IsFatal=$false` |
| S27 | `IsSuccess=$false`, StatusCode 401 | Error added, `IsFatal=$true` |
| S28 | `IsSuccess=$false`, StatusCode 0 (network) | Error added, `IsFatal=$true` |
| S29 | `IsSuccess=$false`, StatusCode 404 | Error added, `IsFatal=$false` |
| S30 | Error includes `ErrorMessage` | Not null or empty |
| S31 | `ItemsProcessed` incremented on failure | `=1` after single failure |

---

## Invoke-SafesAddFromTemplate.ps1 — Test Cases

Design reference: `Docs\Add-Safe-From-Template-Design.md`. Test file:
`Unit\Invoke-SafesAddFromTemplate.Tests.ps1`.

### Module Metadata
| # | Test Case | Expected |
|---|---|---|
| T01 | `$ModuleMeta` is defined | Not null after dot-sourcing |
| T02 | Category / Action | `Safes` / `AddFromTemplate` |
| T03 | SupportsWhatIf | `$true` |
| T04 | SupportedSystems | Contains `ISPSS` and `SelfHosted` |
| T05 | InputSchema `SafeName` | `Required = $true` |
| T06 | InputSchema `Description` | `Required = $false` |

### Invoke-SafesAddFromTemplate — successful response (mocked Invoke-CyberArkAPI)
| # | Test Case | Expected |
|---|---|---|
| T07 | Template safe + members read, safe created, members copied | `IsFatal=$false` |
| T08 | Safe creation result row | One `Results` row with `ItemType='Safe'` |
| T09 | Role-group exclusion | Member whose name starts with `Role_Group_Prefix` is not copied; other members are |
| T09a | Global exclusion list | Member whose name is in `$script:ExcludedTemplateMemberNames` is not copied, regardless of `memberType`; other members are |
| T09b | Global exclusion match rule | Match is exact and case-insensitive - a name that only partially matches (e.g. `AdminGroupExtra` vs. `AdminGroup`) is not excluded |
| T10 | Success counts | `Successes` = 1 (safe) + copied member count; `Failures=0` |
| T11 | Safe POST body | `Location`, `ManagingCPM`, `AutoPurgeEnabled` copied from the template safe's GET response |
| T11a | OLACEnabled | Never included in the safe POST body — not read from the template, not asked, not sent |
| T11b | Template `NumberOfDaysRetention=0` | Only `NumberOfVersionsRetention` is sent; `NumberOfDaysRetention` key absent from the body |
| T11c | Template `NumberOfDaysRetention>0` | Only `NumberOfDaysRetention` is sent; `NumberOfVersionsRetention` key absent from the body |
| T12 | Member POST body | `membershipExpirationDate` always `$null`, never copied from the template member |

### Invoke-SafesAddFromTemplate — WhatIf
| # | Test Case | Expected |
|---|---|---|
| T13 | WhatIf | No `POST` call is made |
| T14 | WhatIf | Template safe and template member GET calls still happen (reads are not blocked) |
| T15 | WhatIf | Synthetic `Results` contains one `Safe` row plus one row per member that would be copied |

### Invoke-SafesAddFromTemplate — validation
| # | Test Case | Expected |
|---|---|---|
| T16 | Empty `SafeName` | `Failures=1`, no API call |
| T17 | `Role_Template_Safe` blank on active profile | `Failures=1`, `IsFatal=$false`, no API call |
| T18 | `Role_Group_Prefix` blank on active profile | `Failures=1`, `IsFatal=$false`, no API call |

### Invoke-SafesAddFromTemplate — errors
| # | Test Case | Expected |
|---|---|---|
| T19 | Template safe GET returns 404 | Error added, `IsFatal=$false`, no safe created |
| T20 | Template safe GET returns 401 | `IsFatal=$true` |
| T21 | Template members GET fails (403) | Error added, `IsFatal=$false`, safe not created |
| T22 | Safe creation POST fails (409) | Error added, `IsFatal=$false`, no member POSTs attempted |
| T23 | One member POST fails (403) | Loop continues; other members still copied; `Failures` reflects the one failure |
| T24 | A member POST returns 401 | `IsFatal=$true`; loop stops immediately |

---

## Self-Hosted Auth — Manual Integration Test Procedures

`Auth/Get-AuthToken.ps1` was a dead legacy shim (see Findings F10 above) and has been deleted; the
current auth surface for this pass is `Auth/CyberArk.Auth.SelfHosted.psm1` (plus the shared
`CyberArk.Auth.Common.psm1` for token persistence, WebView2, and profile I/O). Unit testing is not
feasible for these modules (browser auth flows, DPAPI, interactive prompts, live directory/PKI
dependencies) — run these procedures manually against the live Self-Hosted lab host for **all 8**
Self-Hosted auth methods. **SAML, OIDC, PKI, and PKIPN are the highest-risk methods** for this pass:
they depend on the WebView2 runtime, a real IdP, or a real certificate/smart-card being present in
the test environment, none of which can be simulated, and (per K03 above) `IgnoreSSL` is known not
to reliably apply inside the WebView2 control used by SAML/OIDC.

| # | Test Case | Pass Criteria |
|---|---|---|
| A01 | SelfHosted — CyberArk auth | Token returned; `SystemType=SelfHosted`; `TokenType=CyberArkSession`; `Authorization` header has no `Bearer` prefix |
| A02 | SelfHosted — LDAP auth | Token returned with `AuthMethod=LDAP` |
| A03 | SelfHosted — RADIUS auth | Token returned with `AuthMethod=RADIUS`; if the RADIUS server requires a challenge/response (e.g. a one-time passcode), confirm the prompt flow completes |
| A04 | SelfHosted — Shared auth | Token returned with `AuthMethod=Shared` |
| A05 | SelfHosted — PKI cert auth (**high risk**) | Correct cert selected via `Get-FilteredClientCertificate`; token returned; requires a real client certificate installed in the test environment's cert store |
| A06 | SelfHosted — PKIPN auth (**high risk**) | Same as A05 but via PIN-protected smart card/token; requires physical/virtual smart-card hardware |
| A07 | SelfHosted — SAML auth (**high risk**) | WebView2 window opens; IdP login completes; token captured via cookie/redirect detection; confirm behavior if the lab host uses a self-signed cert (see K03) |
| A08 | SelfHosted — OIDC auth (**high risk**) | Same as A07 but OIDC flow; confirm token exchange completes and `Token`/`TokenType` are populated correctly |
| A09 | Save-AuthToken | `.cred` file created/updated under the profile's token storage location |
| A10 | Import-AuthToken — valid token | Token object returned with all fields (`Token`, `TokenType`, `Headers`, `Expiry`, `SystemType`, `AuthMethod`, `BaseURL`, `Created`, etc.) |
| A11 | Import-AuthToken — expired token on disk | Caller correctly detects expiry (session age > `$script:PVWA_SESSION_EXPIRY_MIN`) and triggers re-authentication rather than using a dead token |
| A12 | Update-SelfHostedAuthToken — silent re-auth path | Confirm this uses the stored `_RefreshContext` credentials without prompting, for auth methods where that's expected; cross-check against K06 (Read-Host fallback if the context is missing) |
| A13 | Get-AuthTokenProfiles | All saved profiles listed |
| A14 | Remove-AuthTokenProfile | Token file removed; profile no longer resolves a stored token |
| A15 | IgnoreSSL — self-signed cert environment, non-WebView2 methods (CyberArk/LDAP/RADIUS/Shared/PKI/PKIPN) | No SSL error |
| A16 | Import-AuthToken — Created field | Returned token's `Created` equals the token file's persisted save time, not the load time; re-saving via `Save-AuthToken` after a refresh updates `Created` to the refresh time |
| A17 | `Invoke-SelfHostedKeepalive` persists extended expiry (Findings F08) | After a keepalive call (`GET /API/LoggedOnUser`), confirm the on-disk token file's expiry is updated, not just the in-memory session token |
| A18 | Logoff | `POST /API/auth/Logoff` called on exit (D12); confirm the PVWA session is actually invalidated server-side (a captured token can no longer be used) |

---

## Manage-Privilege.ps1 — Manual Integration Test Procedures

| # | Test Case | Pass Criteria |
|---|---|---|
| D01 | First launch — no profiles | "No profiles found" shown; N/Q offered |
| D02 | Create new profile | JSON file created; profile appears in list |
| D03 | Edit profile — change log folder | JSON updated; `Modified` timestamp changed |
| D04 | Copy profile | New JSON with new name; auth token file NOT copied |
| D05 | Delete profile | Both JSON and XML removed |
| D06 | Test Connection — valid token | "Connection successful" with expiry shown |
| D07 | Continue — saved valid token | Session starts without re-auth |
| D08 | Continue — expired token, ClientCredentials | Silent refresh; session starts |
| D09 | Continue — expired token, Interactive | Re-auth prompt shown |
| D10 | B navigation | Returns to profile list |
| D11 | Restart (R) | Returns to profile list; current profile is default |
| D12 | Exit (X) | Logoff called (SelfHosted); script exits cleanly |
| D13 | Inactivity timeout | Session ends after `$InactivityTimeoutMin` of no input |
| D14 | Inactivity warning | Warning shown at 90% of timeout |
| D15 | Token expiry warning in menu footer | Yellow color; correct minutes shown |
| D16 | WhatIf mode | Menu shows `[WhatIf ON]`; write calls suppressed |
| D17 | Module discovery | All `.ps1` files in `APIModules\` appear in menu |
| D18 | SelfHosted-only module hidden for ISPSS | Module absent from ISPSS session menu |
| D19 | Logon with a valid but old saved token (`Created` > 15 min ago) | "Saved token is N minute(s) old - refreshing..." shown; a fresh/refreshed token is used for the session, not the stale one |
| D20 | Logon with a valid, recently-saved token (`Created` < 15 min ago) | No refresh message; token loaded directly, unchanged from today's behavior |
| D21 | Any module call returns HTTP 401 with a message that does NOT contain the word "401" or "Unauthorized" | Session is still invalidated — re-auth prompt appears on the next action, same as a normally-worded 401 |
| D22 | Any module call fails with a genuine network error (`StatusCode 0`) | Session is also invalidated (by design, since `IsFatal` covers both cases) — re-auth prompt appears; confirm this is the intended tradeoff, not a regression |
| D23 | **(Findings F09)** Stay inside a single category and perform several actions in a row, spanning past a keepalive interval, without ever returning to the category menu | Inactivity check, proactive refresh, and token-expiry (`Expired`/`Warning`) handling all fire correctly from *inside* the action loop, not only when returning to the category menu — this is a fix made this session and was previously broken |
| D24 | **(Findings F08)** Trigger a keepalive (`Invoke-SelfHostedKeepalive`) by staying logged in past the keepalive threshold, then kill the process (e.g. close the console) without a clean exit, then relaunch | The reloaded token's expiry reflects the keepalive-extended session, not the original pre-keepalive expiry — confirms the extended expiry was actually persisted to disk, not just held in memory |
| D25 | Full session using a live Self-Hosted profile end-to-end: profile creation → auth → category menu → several module actions across categories → inactivity warning → idle past timeout → re-auth → exit | No unhandled exceptions; log file contains a coherent full-session narrative; summary block at exit reflects all actions taken |

---

## Self-Hosted Full Functional Checklist

This is the master checklist for the live functional pass against `https://pvwa.company.com`
(or whichever Self-Hosted lab host is in use). It enumerates every module action in the project.
For each, run it at least once against the live host with realistic input (including at least one
CSV-batch run where the module supports one), confirm the result matches what's actually in the
Vault/PVWA (not just that the tool reported success), and note the PVWA version under test — see
the caution section above for why version matters for Platforms/SafeMembers field-shape
differences.

Use a **dedicated test Safe and test accounts** for every write action (Add/Update/Delete/Change/
Reconcile/etc.) — never point a write action at production data.

### Auth (see the dedicated Self-Hosted Auth section above for the full A01-A18 procedures)
- [ ] All 8 auth methods: CyberArk, LDAP, RADIUS, Shared, PKI, PKIPN, SAML, OIDC
- [ ] Token save/load/refresh/keepalive/logoff lifecycle

### Accounts (17 actions)
- [ ] Add · [ ] CancelCpmTask (confirm the `/Cancel/` endpoint, Phase 1 this session — was
      `/StopImmediateAutoMgmtOperations` before; F14 this session added a 404 fallback to that
      same old endpoint for PVWA older than 15.2, unverified against a real pre-15.2 host) ·
      [ ] ChangeImmediate ·
      [x] ChangeInVault (F12's `Password/Update` endpoint correction **confirmed correct
      2026-09-03** — a live 400 against it turned out to be a legitimate `PASWS001W` account-lock
      error once F16 let Test API surface the real body, not a bug in the endpoint/body shape;
      still confirm F02 masking against a real successful change) · [ ] CheckIn ·
      [ ] Delete · [ ] Get ·
      [ ] GetActivity · [ ] GetCredential · [ ] LinkAccount ·
      [x] List (incl. By-Safe mode, confirm 20K cap behavior — **confirmed 2026-09-02**) · [ ] Reconcile ·
      [ ] ResumeAutoManagement (confirm `POST .../Resume/` on Self-Hosted, Phase 1 this session —
      was `PATCH .../` before; ISPSS was deliberately left unchanged/unconfirmed; F14 this
      session added a 404 fallback on Self-Hosted to the same PATCH `automaticManagementEnabled`
      approach for PVWA older than 15.2, unverified against a real pre-15.2 host) ·
      [ ] UnlinkAccount · [ ] Unlock · [ ] Update (JSON Patch) · [ ] Verify

  **For every `AccountName`+`Safe`-resolving action above:** confirm the `filter=safeName eq ...`
  lookup now works against a **safe name containing a space** (e.g. `"Prod Web Servers"`), not just
  a single-word safe name - this session fixed all 16 call sites of this bug (raw string
  interpolation never quoted the value; now routed through `New-CyberArkSearchFilter`, confirmed
  against psPAS's `ConvertTo-FilterString.ps1`), but none of the 16 fixes have been exercised
  against a real PVWA/ISPSS tenant yet. `List`'s By-Safe iteration mode needs the same check with
  at least one accessible safe whose name contains a space.

### Safes (8 actions)
- [ ] Add (F20 this session — Location no longer prompted interactively, confirm the default `\`
      is still used; ManagingCPM picker now matches AddFromTemplate, sourced from the new shared
      `Get-CpmOptions` — confirm the live CPM query populates it, and that a deliberately-broken
      query falls back to the profile's CPM_List) ·
      [ ] AddFromTemplate (T01-T24 scenarios; F20 this session — CPM picker now sourced from
      `Get-CpmOptions` instead of `CPM_List` only, confirm live query + fallback) ·
      [ ] AssignCPM (F20 this session — CPM picker now sourced from `Get-CpmOptions`, same
      live-query behavior as before but now with a CPM_List fallback on failure that didn't
      exist previously; confirm both paths) ·
      [ ] Delete · [ ] Get ·
      [x] List (confirm F05 ExtendedDetails CSV-boolean fix — **confirmed 2026-09-02**) ·
      [ ] UnassignCPM · [ ] Update

### SafeMembers (6 actions)
- [ ] Add (confirm SearchIn directory picker lists real LDAP directories) ·
      [ ] AddFromTemplateRole · [x] List (**confirmed 2026-09-02**) · [ ] Remove · [ ] Update ·
      [ ] UpdateFromTemplateRole

### Platforms (9 actions)
- [ ] Get ·
      [x] List (confirm F06 field-fallback fix and the new `SystemType` filter — **confirmed
      2026-09-02**) · [ ] Copy (Target platforms only — see `E2E-Automation-Design.md`) ·
      [ ] Disable · [ ] Enable ·
      [ ] Import (confirm the ZIP-as-byte-array request shape actually works) ·
      [ ] Remove (destructive — use a disposable sandbox platform) ·
      [ ] Rename (Self-Hosted only, PVWA 15.0+) · [ ] SetPSMConfig

### Policies (2 actions — Self-Hosted only, PVWA 14.6+)
- [ ] GetMasterPolicy · [ ] SetMasterPolicy (mutates tenant-wide config — use a dedicated lab host,
      never a shared/production one; confirm every field's validation range: `ConfirmersNumber`
      1-64, `PasswordChangeDays`/`PasswordVerificationDays` 1-3650, `RetentionPeriod` 0-3650)

### Users (2 actions)
- [ ] Get · [x] List (**confirmed 2026-09-02**)

### Groups (7 actions)
- [ ] Add · [ ] AddMember (confirm `MemberType` platform split: `Domain`/`Vault` on Self-Hosted) ·
      [ ] Delete · [ ] GetMembers (confirm the new `IncludeMembers` opt-in field) ·
      [x] List (confirm GroupType filter works correctly on Self-Hosted, unlike ISPSS —
      **confirmed 2026-09-02**) · [ ] RemoveMember · [ ] Update

### Applications (7 actions — dual-use, see caution section)
- [x] Add (confirm `Location` is now enforced as mandatory, Phase 1 this session — **confirmed
      2026-09-02**, the only Applications action visible on the ISPSS menu before this pass) ·
      [ ] AddAuthMethod · [ ] Delete · [ ] DeleteAuthMethod · [ ] Get ·
      [x] List (confirm F01 trailing-slash / PIMServices.svc routing fix — **confirmed
      2026-09-02**) ·
      [ ] ListAuthMethods (per user request, this session: leaving App ID blank now lists auth
      methods for every application instead of failing - **not** covered by the "List confirmed"
      status above, since its `Action` is `ListAuthMethods`; this new blank-App-ID behavior is
      unverified against a real host)
- AddAuthMethod, Delete, DeleteAuthMethod, Get, List, and ListAuthMethods were expanded from
  Self-Hosted-only to dual-use on 2026-09-02, after the user found only Add visible on the ISPSS
  Applications menu — confirming the other 6 had been Self-Hosted-only in error. Only ISPSS menu
  visibility has been confirmed for these 6; their actual ISPSS request/response behavior is
  unverified.

### Reports (1 action — Self-Hosted only, see caution section)
- [x] List (confirm F04 sparse-field guards against a real report with missing fields, if any
      exist — **confirmed 2026-09-02**, Self-Hosted only. Also confirmed 2026-09-02 that this
      endpoint 404s on ISPSS/Privilege Cloud — `SupportedSystems` reverted to Self-Hosted-only,
      reversing Phase 1's dual-use expansion)

### Custom (6 actions)
- [ ] ExportAll (per user request, this session, now also runs Applications/ListAuthMethods -
      that specific addition is unverified against a real host) ·
      [ ] ExportEntitlements (confirm the CSV now saves automatically with no `[y/N]` prompt) ·
      [ ] ExportGroupMembersLDAP (requires AD line-of-sight; confirm auto-save CSV) ·
      [ ] ExportGroupMembersLocal (confirm F07 groupType quirk fix, though Self-Hosted may not
      exhibit the ISPSS quirk at all — confirm normal local-group export still works; confirm
      auto-save CSV) ·
      [ ] TestApi (manual smoke test — no unit test exists for this module; confirm the base URL
      shown/used no longer includes `/PasswordVault`, widening what paths it can reach; **F15
      this session — needs live verification specifically with `IgnoreSSL` enabled and a token
      allowed to expire mid-session**, reported by the user as the whole process silently
      closing with no error shown; fixed by switching from a raw
      `ServerCertificateValidationCallback` scriptblock to the shared, already-safe
      `Disable-SSLValidation` helper, but not yet confirmed the crash is actually gone) ·
      [ ] TestConnectivity (confirm against a real Windows target: SMB admin-
      share auth on port 445; and a real Linux target: SSH auth via PS7 `-SSHTransport` and/or
      plink.exe if installed, and the "Plink or PS7 needed" message if neither is; confirm the
      vault password fallback resolves Address+Account correctly; confirm auto-save CSV; F22 this
      session — confirm the `Safe`/`Username`/`PasswordSource` output columns are populated
      correctly for a real vault-backed lookup, and stay blank when a password is supplied directly;
      **F23 this session — was a `[FATAL] PropertyNotFoundException` crash on every Linux SSH
      attempt, reported directly by the user; re-confirmed working against a real test host
      (172.21.20.14) with the fix applied, both for an unrecognized and an already-known host
      key**; F24 this session — confirm the Server Type prompt shows and accepts only `1`/`2`;
      F25 this session — confirmed live that the PS7 SSH transport path still times out on a
      real password attempt (a pre-existing, separate limitation, not fixed by the host-key
      change); F26 this session — confirm the auto-saved CSV filename includes the tested
      Address for a real single interactive run; **F27 this session — plink is now tried first
      and was confirmed live to fail fast (not hang) on an unrecognized host key, but a
      *correct*-password success case through plink was not confirmed live (no real credentials
      were available for the test host) - still needs that final confirmation**)

### Driver-level (Manage-Privilege.ps1)
- [ ] D01-D25 (see Manage-Privilege.ps1 manual test procedures above, including new D23-D25)
- [ ] CSV template generation for every module that accepts CSV input
- [ ] List drill-down (select a row number from any List result to open its Get/Details view)
- [ ] WhatIf mode toggled on, confirm every write action across every category is suppressed and logged
- [ ] Structured logging: confirm no secrets appear in the log file at any level (spot-check F02's fix)
- [ ] Run any `List` action against a real host where exactly one row is returned (F13, this
      session — was a `[FATAL] PropertyNotFoundException` on `.Count`, reported directly by the
      user against `Accounts / List`) — confirm the result table renders correctly with 1 row
- [ ] `Invoke-EntitySearch`'s interactive picker (used by several `Get`/`Delete`/etc. custom
      input functions) with a search term containing a period (e.g. a UPN-style username or a
      dotted IP) — confirm F21's `%2E` encoding fix actually returns matches now, per the user's
      live report that a literal period previously found nothing

---

## Revision Log

| Date | Change |
|---|---|
| 2026-08-14 | Initial version |
| 2026-08-20 | Added Invoke-SafesAddFromTemplate.ps1 to Component Test Matrix; added its Test Cases section (T01-T24) |
| 2026-08-20 | Corrected test-case ID prefix from AFT to T (matching the actual test file); updated T11 and added T11a-T11c for the OLACEnabled removal / retention mutual-exclusivity fix |
| 2026-08-20 | Added T09a-T09b for the new global $script:ExcludedTemplateMemberNames exclusion list |
| 2026-08-20 | Noted that the new HTTP 504 retry loop in Invoke-CyberArkAPI (CyberArkComms.psm1) is not covered by an automated unit test, for the same reason the 429 retry loop isn't - recommend manual verification |
| 2026-08-20 | Added Invoke-SafeMembersAddFromTemplateRole.ps1 and Invoke-SafeMembersUpdateFromTemplateRole.ps1 to Component Test Matrix (44 tests: ATR01-ATR23, UTR01-UTR21) |
| 2026-08-20 | Added A13 (Import-AuthToken Created field) and D19-D22 (logon-phase age refresh, unconditional 401 invalidation including network-error side effect) manual test procedures |
| 2026-09-02 | Full Self-Hosted-focused review and rewrite: added the Self-Hosted vs. ISPSS scope/caution section; replaced the stale Component Test Matrix with a complete matrix of every module in the project; added the Findings and Fixes section (F01-F11, covering the Join-CyberArkUrl trailing-slash fix, JSON-key secret-masking fix, ApplicationsAdd TryParse validation, ReportsList strict-mode property guards, five CSV-boolean cast fixes, PlatformsList field-fallback fix, ExportGroupMembersLocal ISPSS-groupType fix, two Manage-Privilege.ps1 driver fixes, and the dead Get-AuthToken.ps1 deletion); added the Known Issues / Risk Register (K01-K07, none fixed this pass); replaced the stale Get-AuthToken.ps1-referencing auth test section with a Self-Hosted Auth section covering all 8 auth methods (A01-A18); added D23-D25 driver test cases for the two new driver fixes; added the Self-Hosted Full Functional Checklist enumerating all ~55 module actions plus driver-level checks for the live test pass |
| 2026-09-02 | Updated for Phase 0-2 of `aPePAS-Improvement-Plan-2026-09-02.md` (same day, later revision): corrected the Self-Hosted vs. ISPSS caution section's now-stale claim that `Applications`/`Reports` are Self-Hosted-only (Phase 1 confirmed both work on ISPSS and expanded `SupportedSystems`); added the new Self-Hosted-only entries (`Platforms/Rename`, the new `Policies` category) to the Component Test Matrix; added all 7 new Phase 2 Platforms modules (`Copy`/`Disable`/`Enable`/`Import`/`Remove`/`Rename`/`SetPSMConfig`) and both new Policies modules to the matrix and the Full Functional Checklist; updated the Accounts/Groups/Custom checklist entries for Phase 1's confirmed endpoint/field changes (Cancel CPM Task, Resume Auto Management, Group Member `MemberType`/`IncludeMembers`, Applications `Location`, the three Custom export tools' new auto-save-CSV behavior, and Test API's widened base URL); added a cross-reference at the top to the new `E2E-Automation-Design.md`, which tracks progress toward automating this document's manual checklist |
| 2026-09-02 | Added the new `Custom/Invoke-CustomTestConnectivity.ps1` module (DNS resolution, port checks, and Windows SMB / Linux SSH authentication testing, with a vault password fallback) to the Component Test Matrix and the Full Functional Checklist (Custom now 6 actions); updated the dual-use module count to 62 of 65 total |
| 2026-09-02 | Added a note to the Accounts checklist flagging the `filter=safeName eq ...` space-quoting fix (16 files, confirmed against psPAS's `ConvertTo-FilterString.ps1`) as needing live verification against a safe name containing a space - not yet exercised against a real tenant |
| 2026-09-02 | Per user report, marked every `Action = 'List'` module (Accounts, Safes, SafeMembers, Platforms, Users, Groups, Applications, Reports - 8 modules) as confirmed against a real Self-Hosted host in both the Component Test Matrix and the Full Functional Checklist. `Applications/ListAuthMethods` and `Custom/ExportAll` were explicitly called out as **not** covered by this confirmation - `ListAuthMethods`'s `Action` isn't literally `List`, and both gained new, unverified behavior this same session (see next entry) |
| 2026-09-02 | Per user request: `Invoke-ApplicationsListAuthMethods.ps1`'s `AppID` is now optional - leaving it blank lists auth methods for every application instead of failing with "AppID is required". `Invoke-CustomExportAll.ps1` was updated to discover and run it alongside every `List` action, so Export All now includes it automatically. Both changes are new this session and unverified against a real host - added to the Applications and Custom checklist sections above |
| 2026-09-02 | Per user report from live ISPSS testing: `Reports/Invoke-ReportsList.ps1` 404s on ISPSS/Privilege Cloud, reversing Phase 1's dual-use expansion - `SupportedSystems` reverted to `@('SelfHosted')`. Separately, the user found only `Applications/Add` visible on the ISPSS Applications menu, confirming the other 6 Applications modules (`AddAuthMethod`, `Delete`, `DeleteAuthMethod`, `Get`, `List`, `ListAuthMethods`) had been left Self-Hosted-only in error - all 7 Applications modules now declare `SupportedSystems = @('ISPSS', 'SelfHosted')`. Updated the Self-Hosted vs. ISPSS caution section (SelfHosted-only count 3 -> 4, dual-use count 62 -> 61 of 65), the Component Test Matrix rows for Reports/List and all 7 Applications modules, and the Full Functional Checklist's Applications and Reports section headings and notes accordingly. Only ISPSS menu visibility has been confirmed for the 6 newly-expanded Applications modules; their actual ISPSS request/response behavior remains unverified |
| 2026-09-02 | Per user report: `Invoke-AccountsChangeInVault.ps1` was calling `POST /API/Accounts/{id}/SetNextPassword` (a queued-for-CPM change) instead of `POST /API/Accounts/{id}/Password/Update` (an immediate vault-only change, matching the module's own name and description). Confirmed the distinction against the local Swagger spec's descriptions for both paths and against psPAS's `Invoke-PASCPMOperation.ps1`, which treats them as two separate parameter sets. Fixed the endpoint (request body unchanged - both share the `NewCredentials` field); added Finding F12 and a regression test asserting the exact endpoint string |
| 2026-09-02 | Per user report (`[FATAL] PropertyNotFoundException` on `.Count`, hit against `Accounts / List` returning exactly one row): fixed `Manage-Privilege.ps1`'s `Invoke-ActionModule`, where `$tableData`/`$displayData` were each assigned from an `if/else` without an outer `@(...)` wrap - a one-item branch result collapsed to a bare scalar instead of a one-element array, the single-item counterpart of the already-documented Lessons-Learned 9.8 empty-collapses-to-`$null` bug. Wrapped both entire `if/else` expressions in `@(...)`. Added Finding F13, a driver-level checklist item, and a Lessons-Learned 9.8 addendum documenting the new manifestation and that reproducing it requires real `powershell.exe` (PS 5.1) - PowerShell 7/`pwsh` masks it via a synthetic scalar `.Count` |
| 2026-09-02 | Per user report and design direction: `Invoke-AccountsCancelCpmTask.ps1` and `Invoke-AccountsResumeAutoManagement.ps1` now fall back to a version-agnostic endpoint on an HTTP 404 from the newer, version-gated one (`/Cancel/` needs PVWA 15.2+, `/Resume/` needs 15.0-15.2+ depending on source - neither this project nor psPAS can query the actual version). `CancelCpmTask` falls back to the pre-Phase-1 `/StopImmediateAutoMgmtOperations` endpoint; `ResumeAutoManagement` (Self-Hosted only) falls back to the same PATCH `automaticManagementEnabled` approach already used for ISPSS. Only a 404 triggers the fallback - any other failure stays a real, non-fallback error. Added Finding F14, checklist notes, and regression tests covering the fallback-succeeds, no-fallback-on-non-404, and fallback-also-fails cases for both modules |
| 2026-09-02 | Per user report (Custom Test API: the whole process silently closes with no error shown when the session token expires): found `Invoke-CustomTestApi.ps1` was the only module enabling the `IgnoreSSL` bypass via a raw `ServerCertificateValidationCallback` scriptblock instead of `Invoke-CyberArkAPI`'s already-safe, compiled-class-based `Disable-SSLValidation` - a known hazard if .NET's TLS stack ever invokes that delegate off the runspace's own thread, which a fresh handshake during re-authentication could plausibly trigger. Exported `Disable-SSLValidation` from `CyberArkComms.psm1` and switched `Invoke-CustomTestApi.ps1` to use it. Added Finding F15 and a checklist note - **not yet confirmed this was the actual cause**, since no error was available to inspect; needs live verification with `IgnoreSSL` enabled and a token allowed to expire mid-session |
| 2026-09-03 | Added Finding F16 (Test API's `catch` block re-reading an already-consumed `WebException` response stream, discovered live via a real 400 whose body came back `null`) and Finding F17 (per user request: `Invoke-CyberArkAPI`'s `ErrorMessage` now includes the CyberArk `ErrorCode` prefix, e.g. `"PASWS001W: The account is locked by: [ca_jesse]."`, applied once in the shared helper so every module's own error text picks it up automatically; also fixed a latent `Parse-CyberArkError` bug where a body missing either field threw under strict mode and discarded both). Added Finding F18 (per user request: Test API no longer prompts for Query Params on any method other than `GET`). Added C29-C32 regression tests to `CyberArkComms.Tests.ps1` for F17 |
| 2026-09-03 | Added Finding F19 (per user request: `Invoke-CyberArkAPI`'s error message now falls back to the raw response body when structured `ErrorCode`/`ErrorMessage` parsing finds neither, rather than a generic HTTP-status-only message; updated C32 and added C33). Added Finding F20 (per user request: Add Safe no longer prompts for `Location` interactively; Add Safe's `ManagingCPM` prompt now matches Add Safe From Template's numbered picker; all three CPM-picker screens - Add, AddFromTemplate, AssignCPM - now share one `Get-CpmOptions` source in `Manage-Privilege.ps1`, live-query-first with a `CPM_List` fallback on failure, superseding the prior per-page split recorded in Architecture.md). Removed T32-T35 and A15-A17, which tested the two now-deleted per-module CPM-source functions; manually verified `Get-CpmOptions`'s four cases via a standalone `powershell.exe` repro instead, for the same reason `Invoke-EntitySearch` has no unit coverage of its own. Updated the Safes checklist for all three affected actions |
| 2026-09-03 | Added Finding F21 (per user report, live: `?search=` values containing a period fail to match on the CyberArk API unless the period is percent-encoded as `%2E` - `[Uri]::EscapeDataString` leaves `.` as a literal character per RFC 3986. Fixed once in `New-CyberArkQuery`, applied case-insensitively to the `search` key only, covering every module that routes through `Invoke-CyberArkAPI`'s `-QueryParams`). Added C34-C36 to `CyberArkComms.Tests.ps1`. Added Lessons-Learned Section 34 |
| 2026-09-03 | Added Finding F22 (per user request: `Custom/TestConnectivity` output now includes `Safe`, `Username`, and `PasswordSource` columns identifying which vaulted account, if any, was used to make the connection - `Resolve-VaultPassword` returns `SafeName`/`Username` alongside `Password` to support this). Updated TC11-TC12, TC20, TC21, TC27-TC29 in `Invoke-CustomTestConnectivity.Tests.ps1`; updated the Custom checklist |
| 2026-09-03 | Added Finding F23 (per user report, full stack trace: `[FATAL] PropertyNotFoundException` on `ProcessStartInfo.ArgumentList`, crashing every Linux SSH auth attempt - reproduced live with a different symptom on this dev machine too, confirming `ArgumentList` cannot be trusted across environments even when it appears present via reflection; fixed with a probed fallback to a manually-quoted `.Arguments` string). Added Finding F24 (per user request: the Server Type prompt now says "Enter 1 for Windows or 2 for Linux" instead of inviting a typed name, and its displayed default is translated to a number). Added the `ConvertTo-Win32QuotedArgument` `Describe` block (TC30-TC34) to `Invoke-CustomTestConnectivity.Tests.ps1`. Added Lessons-Learned Section 35 |
| 2026-09-03 | Added Finding F25 (per user report, correctly guessing the cause: a Linux SSH timeout was reproduced live against a real test host with its host key removed from `known_hosts`, confirming the PS7 SSH transport path hangs on the unanswerable "unknown host key" question in a non-interactive child process; fixed with `-Options @{StrictHostKeyChecking='no'}`, verified live to reduce the hang to under a second - also discovered, while verifying, that a *known* host key can still time out due to a separate, pre-existing password-prompt-without-a-console limitation). Added Finding F26 (per user request: Test Connectivity's auto-saved CSV filename now includes the tested Address, via a new generic, opt-in `ModuleMeta.CsvFilenameField`). Updated the Custom checklist and Component Test Matrix row |
| 2026-09-04 | Added Finding F27 (per user report and follow-up direction: F25's host-key fix wasn't enough - a real Linux SSH auth attempt via the PS7 path still timed out on the password prompt itself, a pre-existing limitation. The user installed `plink.exe` at the project root and asked for it to be tried instead, then also asked for the standard PuTTY install directories (x86 before x64) to be checked. `Test-LinuxSshAuth` now tries plink first via a new `Find-PlinkExecutable` helper checking PATH, the project root, then both Program Files locations. Verified live against the real test host with plink's own host-key cache genuinely empty: it fails in well under a second with a clear, actionable message rather than hanging - confirmed PuTTY has no CLI equivalent to `StrictHostKeyChecking=no`). Added the `Find-PlinkExecutable` `Describe` block (TC36-TC39). Updated the Custom checklist and Component Test Matrix row - a successful password auth via plink still needs live confirmation, since no real credentials were available for the test host |
