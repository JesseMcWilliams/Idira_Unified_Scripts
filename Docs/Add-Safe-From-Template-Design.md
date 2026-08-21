# Add Safe From Template Design

Tracks the design decisions and implementation plan for a new `Safes/AddFromTemplate`
module that creates a safe by copying settings and non-role group members from an
existing "template" safe named in the active profile.

**Status:** Implemented
**Initiated:** 2026-08-20
**Completed:** 2026-08-20

---

## 1. Motivation

Today, creating a safe that follows a standard pattern (retention settings, CPM, and a
consistent set of non-role group memberships) requires running `Safes/Add` and then a
separate `SafeMembers/Add` for every group by hand. There is no way to say "make this
safe look like our standard template safe."

Two profile fields already exist for exactly this purpose but are currently unconsumed
by any module (confirmed by grep across `APIModules\`):

| Field | Declared in | Current consumers |
|---|---|---|
| `Role_Template_Safe` | `Manage-Privilege.ps1` (`New-BlankProfile`, profile normalization, `Show-ProfileDetail`, `Invoke-ProfileEditFlow`); documented in `Docs\Interfaces.md:399` | None |
| `Role_Group_Prefix` | Same touchpoints; documented in `Docs\Interfaces.md:400` | None |

`Docs\Interfaces.md` describes both fields as "Consumed by Add/Update Safe Member
role-assignment operations" — this feature is the first real consumer. Note:
`README.md`'s Configuration table describes them differently ("exporting role-based
entitlement templates" / "prefix filter for role-based group exports") — that wording
does not match any existing code path and should be corrected to match this feature
once implemented (see Section 6).

Problems this design solves:
- No repeatable way to stamp out safes that match an organizational standard.
- Manual `SafeMembers/Add` runs per group are error-prone and easy to miss one.
- `Role_Template_Safe` / `Role_Group_Prefix` are dead profile fields with conflicting docs.

---

## 2. Proposed Module Structure

```
APIModules\Safes\
  Invoke-SafesAddFromTemplate.ps1   # New — Category=Safes, Action=AddFromTemplate
```

One new file, following the exact convention of the other four `Safes\*.ps1` modules
(`$ModuleMeta` → `Get-SafesAddFromTemplateInput` → `Invoke-SafesAddFromTemplate`). Menu
registration needs no Manage-Privilege.ps1 changes — `Import-APIModules` already does that
automatically (dynamic dot-source + menu registration by `Category`, same as every other
module). Manage-Privilege.ps1 does gain one addition: a `$script:ExcludedTemplateMemberNames`
constant (see Decision D7), the same way other driver-wide constants like
`$script:PVWA_SESSION_EXPIRY_MIN` are declared and made visible to every dot-sourced
module without an explicit import.

The module reuses the same two REST endpoints already used elsewhere in the codebase —
it does not call `Invoke-SafesAdd` or `Invoke-SafeMembersAdd` as functions (those modules
don't export anything for others to call; they are self-contained `Invoke-<Category><Action>`
entry points), it builds equivalent request bodies directly, consistent with how
`Get-PermissionSet` is already duplicated between `Invoke-SafeMembersAdd.ps1` and
`Invoke-SafeMembersUpdate.ps1` rather than shared.

---

## 3. Public API Surface

### `$ModuleMeta`

```powershell
$ModuleMeta = @{
    Name             = 'Add Safe From Template'
    Category         = 'Safes'
    Action           = 'AddFromTemplate'
    Description      = 'Create a new safe by copying settings and non-role group members from the profile''s template safe.'
    SupportedSystems = @('ISPSS', 'SelfHosted')   # both /API/Safes and /API/Safes/{safe}/Members exist on both systems
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';    Required = $true;  Description = 'Unique name for the new safe (max 28 chars).' }
        @{ Column = 'Description'; Required = $false; Description = 'Description for the new safe. Never copied from the template — leave blank for no description.' }
    )
    Priority         = 15   # after Add(12)/Get(11)/Update(13)/Delete(14) in the existing Safes priority sequence
    Version          = '1.2.0'   # 1.1.0 dropped OLACEnabled and made retention fields mutually exclusive (D5/D6)
                              # 1.2.0 added the $script:ExcludedTemplateMemberNames filter (D7)
}
```

Only `SafeName` and `Description` are collected from the caller — `Description` is always
fresh (per D1 below), and every other safe property comes from reading the template safe
named in the profile's `Role_Template_Safe` field.

### Algorithm

1. Resolve the template safe name from the session profile's `Role_Template_Safe` field
   and the role-group prefix from `Role_Group_Prefix`. Both are **required** — if either
   is blank, fail fast with a clear, non-fatal validation error (`IsFatal = $false`), same
   pattern as the existing `SafeName is required` guard in `Invoke-SafesAdd.ps1`. (D4)
2. `GET /API/Safes/{urlencoded Role_Template_Safe}` (same call as `Invoke-SafesGet.ps1`)
   to read the template's settings: `location`, `managingCPM`, `numberOfVersionsRetention`,
   `numberOfDaysRetention`, `autoPurgeEnabled`. The template's `description` and
   `olacEnabled` are never read or used (D1 — description is always fresh from input;
   `OLACEnabled` is not a supported field for this module and must never be sent — see D5).
   - 404 here means the configured template safe doesn't exist — treat as a validation
     failure for this run (`IsFatal = $false`), not a fatal session error.
3. `GET /API/Safes/{urlencoded Role_Template_Safe}/Members` (same call as
   `Invoke-SafeMembersList.ps1`) to read the template's member list. Each member has
   `memberName`, `memberType`, `membershipExpirationDate`, and a `permissions` object with
   the same 22 camelCase booleans used by `Invoke-SafeMembersAdd.ps1`.
4. Filter the member list: exclude any member — regardless of `memberType` (User, Group,
   or Role) — whose `memberName` starts with `Role_Group_Prefix` (case-insensitive) (D2),
   **and** exclude any member whose `memberName` exactly matches (case-insensitive) an
   entry in the global `$script:ExcludedTemplateMemberNames` list defined in `Manage-Privilege.ps1`
   (D7). Every remaining member, of any type, is copied.
5. `POST /API/Safes` to create the new safe, body built the same way as
   `Invoke-SafesAdd.ps1`, with `SafeName` and `Description` from input (empty string if not
   supplied — `Description` is never taken from the template), and `Location`,
   `ManagingCPM`, `AutoPurgeEnabled` copied from the template safe read in step 2. (D1)
   `NumberOfVersionsRetention` and `NumberOfDaysRetention` are mutually exclusive on this
   API — only one is ever included in the body: the template's `NumberOfDaysRetention` is
   sent when it is greater than 0, otherwise the template's `NumberOfVersionsRetention` is
   sent. `OLACEnabled` is never included (D5).
   - If this fails, stop — do not attempt any member copy. Report as one failed item, same
     `IsFatal` rule as `Invoke-SafesAdd.ps1` (`StatusCode -in @(401, 0)`).
6. For each retained member from step 4, `POST /API/Safes/{urlencoded new SafeName}/Members`
   with the same `memberName`, `memberType` (when present), and `permissions` object taken
   verbatim from the template member, but `membershipExpirationDate` always set to `$null`
   — expiration is never copied from the template (D3). Same body shape as
   `Invoke-SafeMembersAdd.ps1:366-373`. Each member copy is one item in the result: a
   failure on one member does not stop the loop (consistent with how every other
   multi-item module in this codebase accumulates `Successes`/`Failures` per item and only
   sets `IsFatal` on 401/0).
7. Result: `ItemsProcessed` = 1 (safe creation) + N (members attempted); `Results` contains
   one row for the created safe and one row per copied member, mirroring the shape
   `Invoke-SafesAdd`/`Invoke-SafeMembersAdd` already use for their own `Results` rows.

`WhatIf` mode reports what would be created (the safe, and the filtered member list) without
calling `POST`, following the same synthetic-success pattern as `Invoke-SafesAdd.ps1`'s WhatIf branch.

---

## 4. Profile Field Consumption

No new profile fields are needed — `Role_Template_Safe` and `Role_Group_Prefix` already
exist end-to-end in `Manage-Privilege.ps1` (creation, normalization for older saved profiles, display,
and interactive edit) and are already documented in `Docs\Interfaces.md`. This feature is
their first real consumer.

Follow-up doc correction once implemented: `README.md`'s Configuration table currently
describes these two fields in terms of a "Custom export" / "role-based entitlement" use case
that doesn't exist in code. That description should be replaced with wording matching this
feature (see Section 7, step 9).

---

## 5. Decisions (resolved 2026-08-20)

| # | Question | Options | Decision |
|---|---|---|---|
| D1 | **Which template safe properties get copied?** | (a) All of `location`, `managingCPM`, `numberOfVersionsRetention`, `numberOfDaysRetention`, `autoPurgeEnabled`, `olacEnabled`, plus `description` unless the caller supplies one — (b) same but never copy `description` (always fresh, blank unless supplied) — (c) let the caller override any field via `InputSchema`, defaulting to the template's value | **(b)**, later amended by D5/D6 — `description` is always fresh input, never copied. `SafeName` is always new. `olacEnabled` was dropped entirely (D5) and the two retention fields were made mutually exclusive on the wire (D6) after initial implementation. |
| D2 | **What exactly counts as a "role group" to exclude?** | (a) `memberType -eq 'Group'` AND `memberName` starts with `Role_Group_Prefix` — everything else copied — (b) same prefix rule but applied to every member type (User/Group/Role) — (c) exclude any member (any type) whose name starts with the prefix, identical in effect to (b) | **(b)/(c)** — filter by `Role_Group_Prefix` against `memberName` across all member types; type is not a factor. Only the name-prefix match excludes a member. |
| D3 | **Copy `membershipExpirationDate` on copied members?** | (a) No — always create new memberships with no expiration — (b) Yes — copy verbatim | **(a)** — copied members always get `membershipExpirationDate = $null` on the new safe. |
| D4 | **Behavior when `Role_Template_Safe` or `Role_Group_Prefix` is blank on the active profile** | (a) Hard validation failure, module refuses to run — (b) Blank prefix falls back to "no groups excluded, copy everything" | **(a) for both fields** — `Role_Group_Prefix` is required, same as `Role_Template_Safe`. The module fails fast (non-fatal validation error) if either is blank, rather than silently copying role groups. |
| D5 | **Should `OLACEnabled` ever be read from the template or sent on `POST /API/Safes`?** (raised after initial implementation) | (a) Keep copying it from the template, as originally implemented — (b) Drop it entirely: never read, never asked, never sent | **(b)** — per direct correction: OLACEnabled should never be passed, asked, or used. Removed from `$safeBody`, from both `Results` shapes (WhatIf and real), and from the equivalent code in `Invoke-SafesAdd.ps1` / `Invoke-SafesUpdate.ps1`, which had the same issue. |
| D6 | **Should `NumberOfVersionsRetention` and `NumberOfDaysRetention` both be sent together?** (raised after initial implementation) | (a) Send both, as originally implemented — (b) Send only one; `NumberOfDaysRetention` wins when greater than 0, otherwise `NumberOfVersionsRetention` is sent | **(b)** — per direct correction: the two fields are mutually exclusive on this API. Applied the same rule to `Invoke-SafesAdd.ps1` and `Invoke-SafesUpdate.ps1` (post-merge value, in the Update case) for consistency across all three Safes write paths. |
| D7 | **Global member-name exclusion list** — where should it live, how should names match, and what's the initial content? | Location: (a) `$script:`-scoped constant in the module file only — (b) shared `$script:` constant in `Manage-Privilege.ps1`, visible to every dot-sourced module. Match: (a) exact, case-insensitive — (b) prefix, case-insensitive. Scope: (a) all `memberType`s — (b) `User` only. Seed content: (a) provided names — (b) empty | **Location (b)** — `$script:ExcludedTemplateMemberNames` in `Manage-Privilege.ps1`, alongside other driver-wide constants (`$script:PVWA_SESSION_EXPIRY_MIN` etc.), so any future Safes/SafeMembers module can reuse it without plumbing. **Match (a)** — exact, case-insensitive; no partial/prefix matching. **Scope (a)** — applies across all `memberType`s, consistent with the `Role_Group_Prefix` filter. **Seed content (b)** — starts empty; names to be added directly in `Manage-Privilege.ps1` as needed. |

---

## 6. File Layout After Implementation

```
APIModules\Safes\
  Invoke-SafesAdd.ps1
  Invoke-SafesGet.ps1
  Invoke-SafesList.ps1
  Invoke-SafesUpdate.ps1
  Invoke-SafesDelete.ps1
  Invoke-SafesAddFromTemplate.ps1   # New
```

---

## 7. Implementation Order

1. ~~Resolve Decisions D1–D4 above.~~ Done (2026-08-20).
2. ~~Create `APIModules\Safes\Invoke-SafesAddFromTemplate.ps1`.~~ Done — UTF-8 with BOM,
   `$ModuleMeta` → `Get-SafesAddFromTemplateInput` → `Invoke-SafesAddFromTemplate`.
3. ~~Implement the read-template → filter-members → create-safe → copy-members flow.~~ Done.
4. ~~Add `Tests\Unit\Invoke-SafesAddFromTemplate.Tests.ps1`.~~ Done — 24 tests (T01–T24),
   all passing; full existing Safes/SafeMembers suite re-run to confirm no regressions.
5. ~~Add a `Docs\Testing-Plan.md` entry.~~ Done — Component Test Matrix row plus
   `Invoke-SafesAddFromTemplate.ps1 — Test Cases` section (T01–T24).
6. ~~Update `Docs\Interfaces.md`.~~ Initially no change needed — the "Consumed by"
   description already matched what was implemented. Later (D7) added a
   `$script:ExcludedTemplateMemberNames` row to the Script-Level Configuration Variables
   table.
7. ~~Update `README.md`.~~ Done — corrected the `Role_Template_Safe` / `Role_Group_Prefix`
   Configuration-table descriptions; updated the Safes project-structure line.
8. ~~Update `Docs\Architecture.md`.~~ Done — two Design Decisions rows added.
9. ~~Add a `Docs\Documentation-Tracker.md` entry.~~ Done.
10. ~~Fix OLACEnabled / retention-exclusivity issues (D5/D6).~~ Done (2026-08-20) — removed
    `OLACEnabled` and made retention fields mutually exclusive in `Invoke-SafesAddFromTemplate.ps1`,
    `Invoke-SafesAdd.ps1`, and `Invoke-SafesUpdate.ps1`; added T11a–T11c and equivalent
    cases to the other two modules' test files; corrected the T-prefix in `Testing-Plan.md`
    (previously mislabeled AFT01–AFT24).
11. ~~Add the global exclusion list (D7).~~ Done (2026-08-20) — added
    `$script:ExcludedTemplateMemberNames = @()` to `Manage-Privilege.ps1`; filter step in
    `Invoke-SafesAddFromTemplate.ps1` now excludes exact (case-insensitive) name matches
    across all `memberType`s in addition to the `Role_Group_Prefix` filter; added T09a–T09b;
    documented in `Interfaces.md` and `Architecture.md`.

---

## 8. Revision Log

| Date | Change |
|---|---|
| 2026-08-20 | Document created — initial design draft; Decisions D1–D4 opened |
| 2026-08-20 | Decisions D1–D4 resolved; algorithm and `$ModuleMeta` updated accordingly |
| 2026-08-20 | Implementation complete — module, unit tests, and all doc updates done |
| 2026-08-20 | Decisions D5–D6 added and resolved: OLACEnabled removed entirely; NumberOfVersionsRetention/NumberOfDaysRetention made mutually exclusive. Same fix applied to Invoke-SafesAdd.ps1 and Invoke-SafesUpdate.ps1 |
| 2026-08-20 | Decision D7 added and resolved: added $script:ExcludedTemplateMemberNames global exclusion list in Manage-Privilege.ps1, consumed by Invoke-SafesAddFromTemplate.ps1's member filter |
