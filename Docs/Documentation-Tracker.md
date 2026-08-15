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
