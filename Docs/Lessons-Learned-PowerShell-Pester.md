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
