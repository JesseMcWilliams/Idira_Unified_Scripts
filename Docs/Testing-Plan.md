# Testing Plan

## Overview

This document describes the testing strategy for the Idira Unified Scripts project.
Tests are organized into **unit tests** (no live CyberArk connection required) and
**integration tests** (require a real CyberArk environment). All unit tests use
[Pester v5](https://pester.dev) and live under `Tests\Unit\`.

---

## Test Environments

| Environment | Purpose | Required For |
|---|---|---|
| Local (no network) | Unit tests, mocked API | All unit tests |
| CyberArk ISPSS (dev/lab) | Integration tests — ISPSS | Auth, API module integration |
| CyberArk SelfHosted (dev/lab) | Integration tests — SelfHosted | Auth, API module integration |

**Do not run integration tests against production environments.**

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

| Component | Unit Tests | Integration Tests | Test File |
|---|---|---|---|
| `CyberArkLogging.psm1` | Yes | No | `Unit\CyberArkLogging.Tests.ps1` |
| `CyberArkComms.psm1` | Partial (helpers + success path) | Yes | `Unit\CyberArkComms.Tests.ps1` |
| `Get-AuthToken.ps1` | No (UI / auth flows) | Yes (manual) | — |
| `Driver.ps1` — profile CRUD | Yes (filesystem) | No | `Unit\Driver.Profile.Tests.ps1` |
| `Driver.ps1` — session loop | No (UI) | Yes (manual) | — |
| `APIModules\Safes\Invoke-SafesList.ps1` | Yes | Yes | `Unit\Invoke-SafesList.Tests.ps1` |
| `APIModules\Safes\Invoke-SafesAddFromTemplate.ps1` | Yes | Yes | `Unit\Invoke-SafesAddFromTemplate.Tests.ps1` |
| `APIModules\SafeMembers\Invoke-SafeMembersAddFromTemplateRole.ps1` | Yes | Yes | `Unit\Invoke-SafeMembersAddFromTemplateRole.Tests.ps1` |
| `APIModules\SafeMembers\Invoke-SafeMembersUpdateFromTemplateRole.ps1` | Yes | Yes | `Unit\Invoke-SafeMembersUpdateFromTemplateRole.Tests.ps1` |
| _(future modules)_ | Yes | Yes | `Unit\Invoke-<Category><Action>.Tests.ps1` |

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

## Get-AuthToken.ps1 — Manual Integration Test Procedures

Unit testing is not feasible for this script (browser auth flows, DPAPI, interactive prompts).
Run these procedures manually against a lab environment.

| # | Test Case | Pass Criteria |
|---|---|---|
| A01 | ISPSS — ClientCredentials | Token returned; `SystemType=ISPSS`; Expiry ~1h from now |
| A02 | ISPSS — Interactive (WebView2) | Browser opens; login completes; token returned |
| A03 | SelfHosted — CyberArk auth | Token returned; `SystemType=SelfHosted` |
| A04 | SelfHosted — LDAP auth | Token returned with LDAP method |
| A05 | SelfHosted — PKI cert auth | Correct cert selected; token returned |
| A06 | Save-AuthToken | Profile XML created in `%APPDATA%\IdiraUnifiedScripts\Profiles\` |
| A07 | Import-AuthToken — valid token | Token object returned with all fields |
| A08 | Import-AuthToken — expired | `IsExpired` flag present |
| A09 | Import-AuthToken — AutoRefresh | New token obtained for ClientCredentials |
| A10 | Get-AuthTokenProfiles | All saved profiles listed |
| A11 | Remove-AuthTokenProfile | Both JSON and XML deleted |
| A12 | IgnoreSSL — self-signed cert environment | No SSL error |
| A13 | Import-AuthToken — Created field | Returned token's `Created` equals the `.cred` file's persisted `SavedAt`, not the load time; re-saving via `Save-AuthToken` after a refresh updates `SavedAt`/`Created` to the refresh time |

---

## Driver.ps1 — Manual Integration Test Procedures

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
