# Lessons Learned — PowerShell 5.1 & Pester v6

Patterns discovered during unit test development for the Idira Unified Scripts project.
Each entry describes the root cause, the symptom, and the correct pattern.

---

## 1. PowerShell 5.1 Compatibility

### 1.1 `return if (...)` is not valid in PS 5.1

**Root cause:** In PowerShell 7+, `if` can be used as an expression (it returns a value).
In PS 5.1, `if` is a statement only — it cannot follow `return`.

**Symptom:** `ParserError: Unexpected token 'if'` when running under PS 5.1.

**Wrong:**
```powershell
return if ($map.ContainsKey($Code)) { $map[$Code] } else { "HTTP $Code" }
```

**Correct:**
```powershell
if ($map.ContainsKey($Code)) { return $map[$Code] } else { return "HTTP $Code" }
```

---

### 1.2 Ternary `?:`, null-coalescing `??`, and null-conditional `?.` are PS 7+ only

**Root cause:** These operators were introduced in PowerShell 7. PS 5.1 throws a parser error.

**Symptom:** `ParserError` or unexpected behavior on any host running PS 5.1 (Windows PowerShell).

**Wrong:**
```powershell
$value = $x ?? 'default'
$name  = $obj?.Name
$label = $flag ? 'yes' : 'no'
```

**Correct:**
```powershell
$value = if ($x) { $x } else { 'default' }
$name  = if ($obj) { $obj.Name } else { $null }
$label = if ($flag) { 'yes' } else { 'no' }
```

---

### 1.3 UTF-8 without BOM causes parse errors in PS 5.1

**Root cause:** PS 5.1 defaults to Windows-1252 encoding. If a `.psm1` or `.ps1` file is saved
as UTF-8 without BOM and contains non-ASCII characters (e.g. em dash `—`, ellipsis `…`),
PS 5.1 misreads the bytes and produces garbled tokens that cascade into parser errors.

**Symptom:** Cryptic parse errors on lines that look correct, especially near special characters.
The em dash `—` (U+2014, bytes E2 80 94) is decoded as `"` (right double-quote, U+201D) in
Windows-1252, which terminates double-quoted strings.

**Fix:** Save all `.ps1` and `.psm1` files as **UTF-8 with BOM**.
In VS Code: bottom-right encoding selector → "Save with Encoding" → UTF-8 with BOM.
In PowerShell: `$content | Set-Content -Path $file -Encoding UTF8` (PS 5.1 writes BOM with this flag).

---

## 2. Pester v6 Mock Patterns

### 2.1 `$PSBoundParameters` is empty in mock scriptblocks without `param()`

**Root cause:** Pester v6 does not populate `$PSBoundParameters` inside a mock scriptblock
unless parameters are explicitly declared with a `param()` block.

**Symptom:** Any assertion against `$PSBoundParameters.SomeParam` returns `$null`.
`$capturedCalls[n].Method | Should -Be 'PUT'` → got `$null`.

**Wrong:**
```powershell
Mock Invoke-CyberArkAPI {
    Set-Variable -Name capturedEndpoint -Value $PSBoundParameters.Endpoint -Scope Script
    [PSCustomObject]@{ IsSuccess = $true }
}
```

**Correct:**
```powershell
Mock Invoke-CyberArkAPI {
    param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams,
          [switch]$WhatIf, [switch]$IgnoreSSL,
          $PageSizeParam, $PageOffsetParam, $PageSize)
    Set-Variable -Name capturedEndpoint -Value $PSBoundParameters.Endpoint -Scope Script
    [PSCustomObject]@{ IsSuccess = $true }
}
```

The `param()` block must match the mocked function's signature. After adding it,
`$PSBoundParameters` is populated correctly and capture patterns work.

---

### 2.6 Variable assignment inside `{ } | Should -Not -Throw` does not escape to the `It` scope

**Root cause:** The scriptblock passed to `Should -Not -Throw` runs in its own child scope.
A variable assigned inside that block (`$r = Invoke-X`) is local to the scriptblock, not to
the surrounding `It` block. The outer `$r` remains `$null`.

**Symptom:** `PropertyNotFoundException: The property 'Successes' cannot be found` — `$r` is
`$null` in the `It` block even though the function succeeded inside the scriptblock.

**Wrong:**
```powershell
It 'does not throw on null input' {
    $r = $null
    { $r = Invoke-MyModule -Token $t -InputData $null } | Should -Not -Throw
    $r.Successes | Should -Be 0   # $r is still $null here
}
```

**Correct (option A — use `$script:` scope inside the block):**
```powershell
It 'does not throw on null input' {
    { Set-Variable -Name r -Value (Invoke-MyModule -Token $t -InputData $null) -Scope Script } |
        Should -Not -Throw
    $script:r.Successes | Should -Be 0
}
```

**Correct (option B — only test that it does not throw; drop the result assertion):**
```powershell
It 'does not throw on null input' {
    { Invoke-MyModule -Token $t -InputData $null } | Should -Not -Throw
}
```

Option B is simpler and sufficient when the goal is just to verify no exception is raised.
Behavior assertions (Successes, Failures, IsFatal) belong in separate tests with controlled
non-null InputData.

---

### 2.2 Helper functions defined outside `BeforeAll` are not accessible inside `It` blocks

**Root cause:** In Pester v6, the execution scope for `It` blocks is different from the file's
top-level scope. Functions defined at the top level with `script:` prefix are not reliably
accessible inside `It` blocks via `script:FunctionName` syntax.

**Symptom:** `CommandNotFoundException: The term 'script:MyHelper' is not recognized`.

**Wrong:**
```powershell
# top level of test file
function script:Get-LatestLog { ... }

It 'some test' {
    script:Get-LatestLog | Should -Not -BeNullOrEmpty
}
```

**Correct:**
```powershell
BeforeAll {
    function Get-LatestLog { ... }   # no script: prefix, inside BeforeAll
}

It 'some test' {
    Get-LatestLog | Should -Not -BeNullOrEmpty
}
```

---

### 2.3 `(Get-Function -split "\`n")` passes `-split` as an argument, not a binary operator

**Root cause:** Inside a parenthesized expression, PowerShell parses `Get-Function -split "\`n"`
in command mode. `-split` is treated as a named parameter to `Get-Function`, not as the binary
split operator. The function ignores the unknown parameter and returns the full result.
The subsequent `| Where-Object` receives the entire multi-line string as a single item,
so the filter matches the whole file instead of individual lines.

**Symptom:** `$line` contains the entire file content. Splitting `$line` by `|` gives segments
that span multiple log lines, producing unexpected lengths (e.g. 52 instead of 8).

**Wrong:**
```powershell
$line = (Get-LatestLogContent -split "`n") | Where-Object { $_ -match 'marker' }
```

**Correct:**
```powershell
$line = (Get-LatestLogContent) -split "`n" | Where-Object { $_ -match 'marker' }
```

The outer `(Get-LatestLogContent)` forces evaluation to a value first; `-split` then operates
on that value as the binary operator.

---

### 2.4 `[char]0x2026` in `Should -Match` is not evaluated as a cast

**Root cause:** `Should -Match` expects a regex pattern string. In command mode (after `|`),
`[char]0x2026` may not be parsed as a PowerShell type-cast expression. Pester receives the
literal string `[char]0x2026`, which is a valid regex character class (`[char]` = any of
c, h, a, r) followed by literal characters — it does not match the ellipsis character `…`.

**Symptom:** `Expected regular expression '[char]0x2026' to match '...…...', but it did not match.`

**Wrong:**
```powershell
$field | Should -Match [char]0x2026
```

**Correct:**
```powershell
$field.Contains([char]0x2026) | Should -BeTrue
# or force expression mode with parens:
$field | Should -Match ([char]0x2026)
```

---

### 2.5 Split by `|` includes the surrounding spaces from ` | ` separators

**Root cause:** If a log format uses ` | ` (space-pipe-space) as a field separator, splitting
by `\|` leaves one trailing space on the left segment and one leading space on the right segment.

**Example:** Format: `"$pidField | $tsField | $lvlField | ..."`
After `-split '\|'`:
- `[0]` = `"  18560 "` (7-char PID + 1 trailing space = 8 chars)
- `[1]` = `" 2026-08-15 10:00:00 "` (1 + 19 + 1 = 21 chars)
- `[2]` = `"  INFO   "` (1 + 7 + 1 = 9 chars)

**Fix:** Account for surrounding spaces in assertions, or trim before checking:
```powershell
# Check field width (subtracting 2 for the surrounding separator spaces):
($levelField.Length - 2) | Should -Be 7

# Or trim the trailing separator space before checking PID width:
$pidField.TrimEnd().Length | Should -Be 7

# Or trim completely and check the text value:
$levelField.Trim() | Should -Be 'WARN'
```

---

## 3. API Module Conventions

### 3.1 WhatIf check must come BEFORE calling `Invoke-CyberArkAPI`

**Root cause:** Tests assert `Should -Invoke Invoke-CyberArkAPI -Times 0` when WhatIf is active.
If the WhatIf check is AFTER the API call (even when passing `-WhatIf:$WhatIf.IsPresent`),
the mock records a call and the assertion fails.

**Symptom:** `Expected Invoke-CyberArkAPI to be called 0 times exactly, but was called 1 time`.

**Wrong:**
```powershell
$response = Invoke-CyberArkAPI -Token $Token -Method 'DELETE' -Endpoint $endpoint -WhatIf: $WhatIf.IsPresent

if ($WhatIf.IsPresent) {
    $result.Successes++
    return $result
}
```

**Correct:**
```powershell
if ($WhatIf.IsPresent) {
    Write-CyberArkLog -Level 'INFO' -Message "WhatIf: DELETE $endpoint would be performed."
    $result.Successes++
    $result.ItemsProcessed++
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}

$response = Invoke-CyberArkAPI -Token $Token -Method 'DELETE' -Endpoint $endpoint
```

---

### 3.2 `Add-CyberArkLogSummaryEntry` requires all four parameters

**Root cause:** All four parameters are mandatory: `-ModuleName`, `-ItemsProcessed`,
`-Successes`, `-Failures`. Omitting any one throws a `ParameterBindingException` at runtime,
even when the function is mocked (the real function may be called if the mock scope doesn't
intercept the call from a dot-sourced module).

**Symptom:** `ParameterBindingException: Cannot process command because of one or more missing
mandatory parameters: ItemsProcessed` — test fails with a terminating error.

**Wrong:**
```powershell
Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -Successes $result.Successes -Failures $result.Failures
```

**Correct:**
```powershell
Add-CyberArkLogSummaryEntry `
    -ModuleName     $ModuleMeta.Name `
    -ItemsProcessed $result.ItemsProcessed `
    -Successes      $result.Successes `
    -Failures       $result.Failures
```

Call this at every exit point that has incremented `$result.ItemsProcessed`: the WhatIf path,
the error path, and the success path.

---

### 3.3 Pagination mock must return a partial page to terminate the loop

**Root cause:** The pagination loop uses `$hasMoreByCount = ($collection.Count -eq $PageSize)`
as its continuation heuristic. If a mock always returns exactly `$PageSize` items, the loop
never terminates.

**Symptom:** Test hangs indefinitely (timeout or infinite loop).

**Fix:** The final mock response must return fewer items than `$PageSize` (including an empty
`value` array):

```powershell
$page1 = '{"value":[{"id":"1"},{"id":"2"}],"count":4}'   # 2 items = PageSize → more pages
$page2 = '{"value":[{"id":"3"},{"id":"4"}],"count":4}'   # 2 items = PageSize → more pages
$page3 = '{"value":[],"count":4}'                          # 0 items < PageSize → loop ends

Mock Invoke-WebRequest {
    $script:callCount++
    if     ($script:callCount -eq 1) { [PSCustomObject]@{ StatusCode = 200; Content = $page1 } }
    elseif ($script:callCount -eq 2) { [PSCustomObject]@{ StatusCode = 200; Content = $page2 } }
    else                             { [PSCustomObject]@{ StatusCode = 200; Content = $page3 } }
} -ModuleName 'CyberArkComms'
```

---

## 4. PS 5.1 Strict Mode (`Set-StrictMode -Version Latest`)

`Set-StrictMode -Version Latest` is active in both `CyberArkLogging.psm1` and `CyberArkComms.psm1`,
and is also set in `Run-Tests.ps1` before calling `Invoke-Pester`. Because Pester executes test
scriptblocks as child scopes, strict mode propagates into every `It`, `BeforeAll`, and `BeforeEach`
block. This surfaces latent bugs in module code when running tests, even if the code works at the
REPL without strict mode enabled.

---

### 4.1 Hashtable dot notation on missing keys throws `PropertyNotFoundException`

**Root cause:** Under `Set-StrictMode -Version Latest`, accessing a key that does not exist in a
hashtable via dot notation (`.`) throws `PropertyNotFoundException`. This affects every
`$InputData.KeyName` access where the key may be absent — including optional fields and the case
where `$InputData` was set to `@{}` from a null parameter.

**Symptom:** `PropertyNotFoundException: The property 'SafeName' cannot be found on this object.`
Usually at the line immediately after `if (-not $InputData) { $InputData = @{} }`.

**Wrong:**
```powershell
if (-not $InputData) { $InputData = @{} }
$safeName = if ($InputData.SafeName) { $InputData.SafeName } else { '' }
```

**Correct — always use bracket notation for hashtable key access:**
```powershell
if (-not $InputData) { $InputData = @{} }
$safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }
```

Bracket notation (`['Key']`) returns `$null` safely when the key is absent. Apply this to
**every** `$InputData` access — required fields, optional fields, and body-building expressions.

---

### 4.2 PSCustomObject optional property access throws `PropertyNotFoundException`

**Root cause:** API responses deserialized from JSON are `PSCustomObject` instances. If the API
omits an optional field (e.g. `createdTime` when no creation time is available), that property
does not exist on the object. Accessing it with dot notation under strict mode throws.

**Symptom:** `PropertyNotFoundException: The property 'createdTime' cannot be found on this object.`
Inside a response-mapping block, typically after a successful `IsSuccess` check.

**Wrong:**
```powershell
$createdDate = if ($acct.createdTime) {
    [DateTimeOffset]::FromUnixTimeSeconds($acct.createdTime).LocalDateTime.ToString('yyyy-MM-dd')
} else { '' }
```

**Correct — guard with `PSObject.Properties` before accessing:**
```powershell
$createdDate = if ($acct.PSObject.Properties['createdTime'] -and $acct.createdTime) {
    try { [DateTimeOffset]::FromUnixTimeSeconds($acct.createdTime).LocalDateTime.ToString('yyyy-MM-dd') }
    catch { '' }
} else { '' }
```

`$obj.PSObject.Properties['fieldName']` returns `$null` (not a throw) when the property is
absent, making the outer `if` safely falsy. The inner `try/catch` guards against malformed
epoch values.

---

### 4.3 `$collection.Count` on a potentially-null collection throws

**Root cause:** In PS 5.1, the result of `@($someExpression)` can be `$null` when the inner
expression evaluates to an empty array under certain conditions. `$null.Count` throws under
strict mode. `Get-ChildItem` also returns a single `FileInfo` object (not an array) when exactly
one file is found — `.Count` does not exist on `FileInfo`.

**Symptom:** `PropertyNotFoundException: The property 'Count' cannot be found on this object.`

**Wrong:**
```powershell
if ($items.Count -eq 0) { ... }
$files = Get-ChildItem $dir -Filter '*.log' -File
$files.Count | Should -BeGreaterThan 0
```

**Correct:**
```powershell
# Null-safe check — always use this pattern for collection-empty guards:
if ((-not $items) -or $items.Count -eq 0) { ... }

# Force array semantics with @() before calling .Count:
$files = Get-ChildItem $dir -Filter '*.log' -File
@($files).Count | Should -BeGreaterThan 0
```

The `@()` wrapper forces PowerShell to treat the result as an array regardless of how many items
`Get-ChildItem` returned (zero, one, or many).

---

### 4.4 `Run-Tests.ps1` propagates strict mode into Pester child scopes

**Root cause:** `Run-Tests.ps1` calls `Set-StrictMode -Version Latest` before `Invoke-Pester`.
Pester v6 executes `BeforeAll`, `BeforeEach`, `It`, and `AfterAll` scriptblocks as child scopes
of the calling scope, inheriting the strict mode setting. This means any latent strict-mode bug
in production module code is surfaced when that code runs inside a test.

**Implication:** A module that "works" at the REPL may fail in the test suite due to strict mode.
Treat all test failures as genuine bugs, not test-environment artifacts.

**Rule:** Write all module code as if `Set-StrictMode -Version Latest` is always active:
- Bracket notation for all hashtable key access
- `PSObject.Properties` guard for all optional PSCustomObject fields
- `(-not $x) -or $x.Count -eq 0` for all empty-collection checks

---

### 4.5 `$Defaults` hashtable in custom input functions also requires bracket notation

**Root cause:** The `$Defaults` parameter in `Get-<Category><Action>Input` functions is a
`[hashtable]`. When the driver calls a custom input function for the first time (no prior entry to
copy), it passes `$null`, which the function body converts to `@{}`. Under
`Set-StrictMode -Version Latest`, dot notation on that empty hashtable throws
`PropertyNotFoundException` for every key that doesn't exist — which is all of them on a fresh
interactive run.

**Symptom:** `PropertyNotFoundException: The property 'SafeName' cannot be found on this object.`
at the first `Show-FieldPrompt -Default $(if ($Defaults.SafeName) …)` call, even though the
guard `if (-not $Defaults) { $Defaults = @{} }` ran correctly.

**Wrong:**
```powershell
if (-not $Defaults) { $Defaults = @{} }
$safeName = Show-FieldPrompt -Label 'Safe Name' `
    -Default $(if ($Defaults.SafeName) { $Defaults.SafeName } else { '' })
```

**Correct:**
```powershell
if (-not $Defaults) { $Defaults = @{} }
$safeName = Show-FieldPrompt -Label 'Safe Name' `
    -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' })
```

This applies to **every** `$Defaults` key access — not just `SafeName`. The same
`$InputData['Key']` rule from 4.1 applies identically to `$Defaults`.

---

## 5. PowerShell Reserved and Automatic Variable Names

PowerShell maintains a set of automatic variables that the runtime owns. Assigning to them
(or declaring a parameter with the same name) either throws a runtime error or silently
corrupts the variable's expected behaviour. The PSScriptAnalyzer rule
`PSAvoidAssignmentToAutomaticVariable` flags these.

### 5.1 Never use automatic variable names as parameters or local variables

**Root cause:** PowerShell's automatic variables are populated by the runtime before your code
runs. Declaring `param([string]$Profile)` or writing `$input = ...` inside a function shadows
the automatic value for that scope. Under `Set-StrictMode -Version Latest`, attempting to read
the automatic variable later can also result in `PropertyNotFoundException` if the shadowed
value is not the expected type.

`$Profile` (the user's profile script path) is particularly dangerous: a function parameter
named `-Profile` will never bind correctly when called with `-Profile $obj` because PowerShell
cannot determine whether the caller meant the automatic variable or the parameter.

**Automatic variables never to use as variable or parameter names:**

| Variable | What it is |
|----------|------------|
| `$Profile` | Path to the current user's PowerShell profile script |
| `$Error` | Circular buffer of recent errors |
| `$Host` | Current `PSHost` object |
| `$input` | Pipeline input enumerator in `process {}` blocks |
| `$Args` | Array of unbound positional arguments |
| `$Matches` | Hash of named and positional regex capture groups |
| `$null` / `$true` / `$false` | Language literals — cannot be assigned |
| `$OFS` | Output Field Separator used by `-join` |
| `$foreach` / `$switch` | Active enumerators inside `foreach` / `switch` |
| `$PID` | Current process ID |
| `$PSScriptRoot` | Directory of the running script |
| `$PSCommandPath` | Full path of the running script |
| `$PSBoundParameters` | Bound parameters for the current function |
| `$MyInvocation` | Invocation metadata for the current command |
| `$ExecutionContext` | Current execution context |

Preference variables (`$ErrorActionPreference`, `$VerbosePreference`, etc.) **may** be assigned
intentionally at the top of a script to configure behaviour — that is their purpose. They must
**not** be used as function parameter names.

**Wrong:**
```powershell
function Save-DriverProfile {
    param([PSCustomObject]$Profile)   # shadows $PROFILE automatic variable
    ...
}

It 'validates input' {
    $input = $script:ValidInput.Clone()   # shadows $input pipeline enumerator
    $input.SafeName = ''
    ...
}
```

**Correct:**
```powershell
function Save-DriverProfile {
    param([PSCustomObject]$currentProfile)   # unambiguous name
    ...
}

It 'validates input' {
    $testInput = $script:ValidInput.Clone()   # unambiguous name
    $testInput.SafeName = ''
    ...
}
```

**Rule:** Run PSScriptAnalyzer with the `PSAvoidAssignmentToAutomaticVariable` rule enabled
on all `.ps1` and `.psm1` files. Any warning from this rule must be treated as an error and
resolved before merging.

---

## 6. Driver Scope and Module Loading

### 6.1 Functions dot-sourced inside a called function are lost when it returns

**Root cause:** In PowerShell, dot-sourcing a script (`. $path`) brings the definitions from
that script into the **current scope** — which, when called from inside a function, is that
function's **local scope**. When the function returns, its local scope is destroyed, taking all
dot-sourced definitions with it. Any other function that runs later cannot see them.

In `Driver.ps1`, `Import-APIModules` dot-sources every module file to read its `$ModuleMeta`.
This creates both `$ModuleMeta` and the module functions (`Invoke-SafeMembersList`,
`Get-SafeMembersListInput`, etc.) in `Import-APIModules`'s local scope. When
`Import-APIModules` returns to `Invoke-SessionLoop`, those function definitions vanish.

Later, `Invoke-ActionModule` (called from `Invoke-SessionLoop`) tries to call
`Get-SafeMembersListInput` by name. PowerShell searches the scope chain:
1. `Invoke-ActionModule`'s local scope
2. `Invoke-SessionLoop`'s local scope (the caller)
3. Script scope
4. Global scope

`Import-APIModules`'s scope is **not** in this chain — it returned before `Invoke-ActionModule`
was called. The function is not found.

**Symptom:** `CommandNotFoundException: The term 'Get-SafeMembersListInput' is not recognized`
at the driver's `& "Get-$($meta.Category)$($meta.Action)Input"` call. Modules without
`HasCustomInput = $true` are unaffected because they never invoke the custom input function
by name.

**Wrong — dot-source inside the discovery function (functions lost on return):**
```powershell
function Import-APIModules {
    foreach ($file in $files) {
        . $file.FullName           # functions go into Import-APIModules's local scope
        $script:LoadedModules += ...
    }
}

function Invoke-SessionLoop {
    Import-APIModules              # discovery runs, then returns — functions gone
    ...
    Invoke-ActionModule ...        # tries to call Get-SafeMembersListInput — not found
}
```

**Correct — re-dot-source in the scope that calls Invoke-ActionModule:**
```powershell
function Import-APIModules {
    foreach ($file in $files) {
        . $file.FullName           # still needed to read $ModuleMeta
        $script:LoadedModules += ...
    }
}

function Invoke-SessionLoop {
    Import-APIModules
    # Re-dot-source each file into Invoke-SessionLoop's scope so that child
    # callers (Invoke-ActionModule) can resolve module functions by name.
    foreach ($m in $script:LoadedModules) { . $m.FilePath }
    ...
    Invoke-ActionModule ...        # Get-SafeMembersListInput now in scope chain ✓
}
```

The double dot-source is intentional. `Import-APIModules` reads `$ModuleMeta` (data).
The second pass in `Invoke-SessionLoop` makes the **functions** available to all code that
runs within `Invoke-SessionLoop`'s lifetime, including child calls like `Invoke-ActionModule`.

**Rule:** If a function is called by name (via `& "FunctionName"`) from a scope that was
**not** the scope where the dot-source occurred, the function will not be found. Dot-source
at the scope level of the long-lived caller, not inside a helper that immediately returns.

---

## 7. Custom Input Functions and Cancellation

### 7.1 Return `$null` from a custom input function to signal cancellation

**Root cause:** Custom input functions (`Get-<Category><Action>Input`) are called from
`Invoke-ActionModule` in the driver. When the user searches for an entity and cancels (no selection
made, empty search, or nothing found), the module has no way to throw or set a flag — it must
communicate cancellation through its return value.

`Invoke-ActionModule` already checks:
```powershell
if ($null -eq $inputData) { return }   # User cancelled in custom input function
```

**Pattern:** If an ID search produces no result or the user explicitly cancels, return `$null` from the
input function to return to the action menu without running the module:

```powershell
function Get-AccountsGetInput {
    param([PSCustomObject]$Token, [hashtable]$Defaults)
    if (-not $Defaults) { $Defaults = @{} }

    $id = Show-FieldPrompt -Label 'Account ID' -Description 'ID or blank to search.'
    if (-not $id) {
        $id = Invoke-EntitySearch -Token $Token -Endpoint '/API/Accounts' `
            -SearchTerm (Show-FieldPrompt -Label 'Search') `
            -ResponseProperty 'value' -IdProperty 'id' `
            -DisplayProperties @('name','userName','address') -EntityLabel 'account'
        if (-not $id) { return $null }   # <-- cancellation signal
    }
    return @{ AccountID = $id }
}
```

**Rule:** Whenever a required field cannot be resolved (empty input + failed search), return
`$null` from the custom input function. Never call `exit` or `throw` — let the driver decide how
to handle the return.

---

### 7.2 Nested `PSObject.Properties` guard required for optional sub-fields

**Root cause:** The guard `if ($obj.PSObject.Properties['parent'])` confirms `parent` exists on
`$obj`, but does **not** confirm that sub-fields exist on `$obj.parent`. Under
`Set-StrictMode -Version Latest`, accessing `$obj.parent.child` when `child` is absent on the
nested PSCustomObject throws `PropertyNotFoundException`.

**Symptom:** `PropertyNotFoundException: The property 'email' cannot be found on this object.`
even though the outer guard `if ($user.personalDetails)` passed.

**Wrong:**
```powershell
Email = if ($user.personalDetails) { $user.personalDetails.email } else { '' }
```

**Correct — guard both levels:**
```powershell
Email = if ($user.personalDetails -and $user.personalDetails.PSObject.Properties['email']) {
    $user.personalDetails.email
} else { '' }
```

**Rule:** For any API response property accessed as `$obj.parent.child`, guard both levels:
1. `$obj.PSObject.Properties['parent']` (or simply `-and $obj.parent` as a truthiness check)
2. `$obj.parent.PSObject.Properties['child']`

This applies to all nested optional fields: `personalDetails.email`, `secretManagement.status`,
`directory.directoryType`, etc.

---

## 8. Orchestration Modules and External Queries

### 8.1 Orchestration modules can call other module entry-point functions directly

**Root cause:** All module files are re-dot-sourced into `Invoke-SessionLoop`'s scope, so
`Invoke-SafesList`, `Invoke-GroupsList`, etc. are all in the same scope at runtime. An orchestration
module (like `Invoke-CustomExportAll`) can call them with `& $fnName -Token $Token -InputData @{}`.

**Important:** `$ModuleMeta` in those called functions resolves to the last module loaded (a known
benign scope issue), so `$moduleResult.ModuleName` / `Category` / `Action` on the returned object
may be wrong. Use only `Results`, `Successes`, `Failures`, and `Errors` from the returned object.

**Pattern:**
```powershell
$fnName = "Invoke-$($module.Meta.Category)$($module.Meta.Action)"
$moduleResult = & $fnName -Token $Token -InputData @{}
# Use $moduleResult.Results, $moduleResult.Successes, $moduleResult.Failures
```

**Rule:** Orchestration modules iterate `$script:LoadedModules` (set by `Import-APIModules`). Skip
`Category = 'Custom'` to prevent recursive calls. Handle exceptions with try/catch per module so one
failure does not abort the entire export.

---

### 8.2 AD queries in PS 5.1 must use ADSI objects, not the ActiveDirectory module

**Root cause:** The ActiveDirectory PowerShell module (`Get-ADGroup`, `Get-ADGroupMember`, etc.) is
not available on all systems and is not required to be present. `System.DirectoryServices` ADSI
objects are part of .NET Framework and available in all PS 5.1 environments on domain-joined Windows.

**Symptom:** `CommandNotFoundException: Get-ADGroup` or dependency on optional RSAT tools.

**Wrong:**
```powershell
$members = Get-ADGroupMember -Identity $groupName -Recursive
```

**Correct — use DirectorySearcher:**
```powershell
$searcher = New-Object System.DirectoryServices.DirectorySearcher
$searcher.Filter = "(&(objectClass=group)(sAMAccountName=$groupSAM))"
$searcher.PropertiesToLoad.Add('distinguishedName') | Out-Null
$searcher.PropertiesToLoad.Add('member') | Out-Null
$entry = $searcher.FindOne()
if ($entry) {
    $dn  = "$($entry.Properties['distinguishedName'][0])"
    $dns = @($entry.Properties['member'])
}
```

**Property access:** `$entry.Properties['key'][0]` returns the value — ALWAYS access by bracket
index, as the value is a `ResultPropertyValueCollection`. String interpolation `"$(...)"` is needed
since `[0]` returns `[object]`, not `[string]`.

**Rule:** Use `New-Object System.DirectoryServices.DirectorySearcher` (or `DirectoryEntry`) for all
AD queries. Never use `Get-ADGroup`, `Get-ADGroupMember`, or other `ActiveDirectory` module cmdlets.
Wrap all ADSI operations in `try/catch` — domain connectivity failures must be caught gracefully.

---

### 8.3 Stack-based iteration avoids recursion depth limits for nested group traversal

**Root cause:** PowerShell's default call stack is limited (~500 frames). Recursive function calls
for deeply nested group structures (10+ levels) can exhaust the stack and throw a
`StackOverflowException`.

**Pattern — use an explicit stack instead of recursion:**
```powershell
$stack   = [System.Collections.Generic.Stack[hashtable]]::new()
$visited = [System.Collections.Generic.HashSet[string]]::new()

$stack.Push(@{ ID = $rootId; Path = $rootName; Depth = 1 })

while ($stack.Count -gt 0) {
    $current = $stack.Pop()
    if ($visited.Contains($current['ID'])) { continue }  # Prevents circular loops
    [void]$visited.Add($current['ID'])

    # Process current item, push children
    foreach ($child in $children) {
        if (-not $visited.Contains($child.ID)) {
            $stack.Push(@{
                ID    = $child.ID
                Path  = "$($current['Path']) > $($child.Name)"
                Depth = $current['Depth'] + 1
            })
        }
    }
}
```

**Rule:** For any traversal that may be more than ~3 levels deep or involves potentially circular
references, use a `Stack[hashtable]` with a `HashSet[string]` visited guard instead of recursive
function calls. This applies to both CyberArk group member traversal and AD nested group expansion.

---

### 8.4 Applications API uses legacy PIMServices endpoint and nested body wrapper

**Root cause:** The CyberArk Applications API (`WebServices/PIMServices.svc`) predates the modern
REST API (`/API/`) and uses different URL patterns and body shapes.

**Key differences from `/API/` modules:**
- Endpoint path: `/WebServices/PIMServices.svc/Applications` (not `/API/Applications`)
- List response: `{ "application": [ {...} ] }` — array under `application` key
- Get response: `{ "application": { ... } }` — single object under `application` key
- Auth methods list: `{ "authentication": [ {...} ] }` — under `authentication` key
- **Add body must be wrapped:** `@{ application = @{ AppID = ...; ... } }` (not a flat body)
- `SupportedSystems = @('SelfHosted')` — Privilege Cloud (ISPSS) does not expose this endpoint

**Correct body for Add Application:**
```powershell
$response = Invoke-CyberArkAPI `
    -Token    $Token `
    -Method   'POST' `
    -Endpoint '/WebServices/PIMServices.svc/Applications' `
    -Body     @{ application = @{ AppID = $appId; Description = $desc; Disabled = $false } }
```

**Rule:** When mapping API response fields, always check `PSObject.Properties['application']` or
`PSObject.Properties['authentication']` before accessing the inner object/array. The inner payload
may be a single object OR an array depending on the endpoint — cast with `@(...)` to normalize.

---

## 9. Pester v6 Test File Structure

Patterns discovered when fixing a systematic test regression across 22 test files (all new modules
created in the Custom, Applications, and extended Accounts categories). All 22 files failed with
`InvalidOperationException: A 'break' or 'continue' statement with a label that does not match any
enclosing loop escaped from your code` (Pester issue #2669).

### 9.1 `BeforeAll` must be at file level, not inside `Describe`

**Root cause:** In Pester v6.1+, a `BeforeAll` block nested **inside** a `Describe` runs inside
Pester's own internal `foreach` loop. Any `break` or `continue` statement encountered in user code
at that point — even one that lives inside a function body of an imported module and would never
execute at import time — can escape Pester's `foreach` and throw `InvalidOperationException`.
`CyberArkComms.psm1` contains `break` and `continue` inside `Invoke-CyberArkAPI`'s retry loop;
this triggered the error in every new-style test file.

**Symptom:** Every test in every new file fails immediately with the escape-loop error. Old-style
test files (that already had file-level `BeforeAll`) continue to pass unchanged.

**Wrong (all new test files had this pattern):**
```powershell
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath  = Join-Path (Split-Path (Split-Path $here)) 'APIModules\...'
$commsPath   = Join-Path (Split-Path (Split-Path $here)) 'Modules\CyberArkComms.psm1'
$loggingPath = Join-Path (Split-Path (Split-Path $here)) 'Modules\CyberArkLogging.psm1'

Describe 'Invoke-Xxx' {
    BeforeAll {                          # ← WRONG: BeforeAll inside Describe
        Import-Module $loggingPath -Force
        Import-Module $commsPath   -Force
        . $modulePath
    }
    ...
}
```

**Correct:**
```powershell
BeforeAll {                              # ← file level, before any Describe
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\...\Invoke-Xxx.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'XxxTests' -MinLevel 'ERROR'
}

Describe 'Invoke-Xxx' {
    ...
}
```

**Rule:** Always place the `BeforeAll` that imports modules at the **file level** (before any
`Describe` block). Use `$PSScriptRoot` (available in all scopes in Pester v6) instead of
`Split-Path -Parent $MyInvocation.MyCommand.Path`. Use `$script:` prefix for any variable set
in file-level `BeforeAll` that is needed inside `Describe` or `Context` blocks.

---

### 9.2 Always call `Initialize-CyberArkLog` in file-level `BeforeAll`

**Root cause:** All production modules call `Write-CyberArkLog` internally. Without initialising
the logging module, each test run spits log lines to the console and — if the default log folder
doesn't exist on the test machine — throws on first write.

**Rule:** Every test file must include `Initialize-CyberArkLog -Destination 'Console'
-ProfileName '<ModuleName>Tests' -MinLevel 'ERROR'` in the file-level `BeforeAll`, after the
module imports. Use a unique `ProfileName` per file to avoid cross-contamination of summary
entries between test files.

---

### 9.3 Driver-scope helper functions must be stubbed before Mocking

**Root cause:** Functions defined in `Driver.ps1` (e.g. `Get-CsvSavePath`) are not imported by
the unit test file. In Pester v6, you **cannot** call `Mock SomeFunction` if `SomeFunction` does
not already exist in the session — Pester will throw `CommandNotFoundException` before the test
even runs.

**Symptom:** `CommandNotFoundException: Could not find Command Get-CsvSavePath` inside Pester's
`Mock` setup, causing every test in the `Describe` to fail.

**Fix:** Define a minimal global stub in the file-level `BeforeAll` **before** any `Mock` calls:
```powershell
BeforeAll {
    ...
    # Stub for Driver helper — not available outside Driver.ps1
    function global:Get-CsvSavePath {
        param([string]$DefaultFolder, [string]$ModuleName)
        return $null
    }
}
```

The stub only needs to have the same parameter signature; its body can be a no-op. Pester's
`Mock` then replaces the stub in each test that needs it.

**Rule:** Any function that the module under test calls, but that lives in a file not imported by
the test, must be stubbed in `BeforeAll`. Check the module's code for `& $fnName` and bare
function calls to names not defined in `CyberArkComms.psm1` or `CyberArkLogging.psm1`.

---

### 9.4 Success tests must satisfy all module-level validation

**Root cause:** Several "Successful operation" tests only provided the minimum primary key
(`AccountID`) in `InputData` but forgot other fields the module validates as required before
calling the API. The module returned early with `Failures = 1`; the mocked API was never called.

**Symptom:** `$result.Successes | Should -BeGreaterThan 0` evaluates to 0 even though the mock
is set up correctly.

**Affected tests and the missing fields:**

| Test file | Missing required fields |
|---|---|
| `Invoke-AccountsChangeInVault.Tests.ps1` | `NewCredentials` |
| `Invoke-AccountsLinkAccount.Tests.ps1` | `ExtraPasswordIndex`, `Name`, `Safe` |
| `Invoke-AccountsUnlinkAccount.Tests.ps1` | `ExtraPasswordIndex` |

**Rule:** Before writing the success-path `It` block, read the module's validation section to
identify every field that causes an early-return failure. The success test's `InputData` must
include all required fields. The failure-path `It` blocks intentionally omit them — keep those
as-is.

---

### 9.5 `WhatIf` does not suppress `GET` operations

**Root cause:** `Invoke-CyberArkAPI` only suppresses the API call when `$WhatIfPreference` is set
**and** the HTTP method is one of `POST`, `PUT`, `PATCH`, or `DELETE`. `GET` calls execute
regardless of `-WhatIf`. `Invoke-AccountsGetActivity` uses `GET`; its test incorrectly asserted
that `-WhatIf` would prevent the API call.

**Symptom:** The mocked `Invoke-CyberArkAPI` throws `'Should not be called in WhatIf mode'`,
causing the `Should -Not -Throw` assertion to fail.

**Rule:** Only write a WhatIf test for modules that use a mutating HTTP method (`POST`, `PUT`,
`PATCH`, `DELETE`). Modules with `SupportsWhatIf = $false` in their metadata (or those that only
use `GET`) should not have a WhatIf `Context` block in their test file. If a module is read-only
(GET only), remove or omit the WhatIf context entirely — do not adjust the mock to make it pass,
because passing would mask the misunderstanding.
