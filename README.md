# Idira Unified Scripts

A PowerShell 5.1 interactive driver for CyberArk Privileged Access Security (PAS), supporting both **ISPSS (Privilege Cloud)** and **Self-Hosted PVWA** environments. Provides a menu-driven console interface for common administrative tasks — account management, safe management, user and group operations, platform administration, and bulk exports.

---

## Features

- **Profile management** — Store multiple named environments (PVWA URL, auth method, output folder, SSL settings). Profiles are encrypted and stored locally per user. One profile can be marked as default.
- **Multi-environment support** — ISPSS (Privilege Cloud) and Self-Hosted PVWA v12+.
- **Authentication methods** — CyberArk, LDAP, RADIUS, SAML, OIDC, Shared, PKI, PKIPN (Self-Hosted); ClientCredentials, Interactive, SSO (ISPSS).
- **Proactive token refresh** — Silently refreshes client-credentials tokens 10 minutes before expiry; prompts for re-auth on interactive session tokens. At logon, a saved token that's still valid but more than 15 minutes old is refreshed before the session starts.
- **Modular API actions** — Each operation is a standalone `.ps1` module loaded dynamically. The driver discovers and presents only the modules supported by the connected system type.
- **CSV batch processing** — Every write operation (Add, Update, Delete) can process a CSV file row-by-row, or collect input interactively.
- **CSV template generation** — Generate a header-only CSV template for any module's input schema.
- **Safe-scoped account lookup** — Account modules accept `AccountName` + `Safe` in CSV input and resolve the account ID server-side, avoiding the need to know internal account IDs.
- **List drill-down** — From any list result, enter a row number to open the corresponding Get/Details view pre-populated with that row's data.
- **WhatIf mode** — Toggle a session-wide dry-run flag; all write operations are suppressed and logged.
- **Interactive API tester** — Send raw requests to any CyberArk API endpoint, inspect request and response headers, and save full session details to JSON.
- **Token lifecycle management** — Automatic keepalive, expiry warnings, transparent re-authentication, and token persistence across sessions.
- **Structured logging** — All actions, errors, and summaries are written to a rotating log file. POST/PUT/PATCH bodies and error responses are written to the log file at DEBUG level.
- **Configurable display limit** — Profile setting controls how many rows are shown on screen for list results (default 20, 0 = unlimited).

---

## Requirements

| Requirement | Version |
|---|---|
| PowerShell | 5.1 (Windows PowerShell) |
| CyberArk PVWA | v12.0+ (Self-Hosted) |
| CyberArk ISPSS | Any current Privilege Cloud tenant |
| .NET Framework | 4.7.2+ (ships with Windows 10/Server 2019+) |
| Pester (tests only) | v6.x |

> **SAML / OIDC authentication** additionally requires the [Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/) and its WinForms assembly (`Microsoft.Web.WebView2.WinForms.dll`).

---

## Installation

1. **Clone or download** this repository to a local folder.

   ```powershell
   git clone <repo-url> C:\Tools\IdiraUnifiedScripts
   cd C:\Tools\IdiraUnifiedScripts
   ```

2. **Unblock files** if downloaded as a ZIP (Windows marks files from the internet as untrusted).

   ```powershell
   Get-ChildItem -Recurse | Unblock-File
   ```

3. **Run the driver** — no installation or import required. The driver dot-sources all modules on startup.

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\Manage-Privilege.ps1
   ```

   Or open a PowerShell 5.1 console and run:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\Manage-Privilege.ps1
   ```

---

## Quick Start

1. Launch `Manage-Privilege.ps1`.
2. At the **Profile Selection** screen, press **N** to create a new profile.
3. Enter a profile name, your PVWA URL (Self-Hosted) or Privilege Cloud subdomain (ISPSS), and choose your authentication method.
4. Authenticate when prompted. Your token is saved for future sessions.
5. Use the category and action menus to perform operations.

---

## Project Structure

```
IdiraUnifiedScripts/
- Manage-Privilege.ps1          # Main interactive driver
- Auth/
  - CyberArk.Auth.Common.psm1   # Shared auth utilities: token object, WebView2, profile I/O
  - CyberArk.Auth.ISPSS.psm1    # Privilege Cloud / CyberArk Identity authentication
  - CyberArk.Auth.SelfHosted.psm1 # Self-Hosted PVWA authentication
  - Get-AuthToken.ps1           # Legacy entry point (kept for compatibility)
- Modules/
  - CyberArkComms.psm1          # REST communication layer (pagination, rate limiting)
  - CyberArkLogging.psm1        # Structured log writer
- APIModules/
  - Accounts/                   # Add, Get, List, Update, Delete accounts
  - Safes/                      # Add, Get, List, Update, Delete, AddFromTemplate, AssignCPM, UnassignCPM safes
  - SafeMembers/                # Add, List, Update, Remove, AddFromTemplateRole, UpdateFromTemplateRole safe members
  - Platforms/                  # Get, List platforms
  - Users/                      # Get, List users
  - Groups/                     # Add, Get, List, Update, Delete groups; Add/Remove members
  - Applications/               # List, Add auth methods (Self-Hosted only)
  - Reports/                    # List reports (Self-Hosted only)
  - Custom/                     # Export All, Export Entitlements, Export Group Members (Local/LDAP), Test API
- Tests/
  - Unit/                       # Pester v6 unit tests
- Docs/
  - Architecture.md             # System design and data flow
  - API-Module-Development-Guide.md  # How to write new API modules
  - Lessons-Learned-PowerShell-Pester.md  # Notes on PS 5.1 gotchas
  - Documentation-Tracker.md
```

---

## Writing New API Modules

See [Docs/API-Module-Development-Guide.md](Docs/API-Module-Development-Guide.md) for the full guide. Key points:

- Every module is a `.ps1` file that defines `$ModuleMeta` (a hashtable), an optional `Get-<Category><Action>Input` function, and an `Invoke-<Category><Action>` function.
- Modules are dot-sourced by the driver at startup. The driver discovers and registers them automatically via `$ModuleMeta`.
- Save all `.ps1` / `.psm1` files as **UTF-8 with BOM** — PowerShell 5.1 requires the BOM to read files as Unicode. Files without BOM are read as Windows-1252, which silently corrupts non-ASCII characters in string literals.

---

## Running Tests

```powershell
# Requires Pester v6
Install-Module -Name Pester -RequiredVersion 6.x -Force -Scope CurrentUser

# Run all unit tests
Invoke-Pester .\Tests\Unit\ -Output Detailed
```

---

## Configuration

Profiles are stored as encrypted XML files under `%APPDATA%\IdiraUnifiedScripts\Profiles\`. Each profile contains:

| Field | Description |
|---|---|
| ProfileName | Friendly name shown in menus |
| SystemType | `ISPSS` or `SelfHosted` |
| AuthMethod | Auth method (e.g. `CyberArk`, `LDAP`, `ClientCredentials`) |
| PVWAUrl | Base URL for Self-Hosted (e.g. `https://pvwa.company.com`) |
| AppName | PVWA application name for Self-Hosted (default `PasswordVault`) |
| PCloudSubdomain | Subdomain for ISPSS (e.g. `acme`) |
| Username | Pre-populated username for auth prompts |
| OutputFolder | Default folder for CSV exports |
| LogFolder | Override for log file location |
| IgnoreSSL | Skip TLS certificate validation (not recommended for production) |
| Limit | Maximum API results to fetch (0 = no limit) |
| DisplayLimit | Maximum rows to display on screen (default 20, 0 = unlimited) |
| IsDefault | Marks this profile as the default selection on startup |
| Role_Template_Safe | Safe name used as a settings/membership template by Safes > Add Safe From Template |
| Role_Group_Prefix | Name prefix identifying role groups to exclude when copying members in Add Safe From Template |
| CPM_List | Comma-separated CPM usernames; shown as a picker (default: none) on pages that ask for a CPM, currently Safes > Add Safe From Template |
| TenantPortal | Auto-computed ISPSS portal URL (`{sub}.cyberark.com`) |
| TenantVault | Auto-computed ISPSS vault URL (`vault-{sub}.privilegecloud.cyberark.com`) |
| TenantAuth | Auto-computed CyberArk Identity tenant URL (discovered on first login, cached) |

---

## License

Internal tooling — all rights reserved. Not for redistribution without authorization.
